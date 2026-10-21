import AVFoundation
import PitchEyeCore

/// 경기 내내 들어오는 프레임을 1초짜리 조각 파일로 이어 쓴다. 최근 몇 초만 남기고 지운다.
/// 투구 영상은 이 조각들을 잘라 붙여 만든다(ClipExporter). 어느 조각을 쓸지는 PitchEyeCore의 ClipWindow가 계산한다.
///
/// 프레임은 캡처 프레임 큐에서 append로 들어온다. 조각을 바꿀 때 새 파일 준비로 프레임이 밀리지 않도록
/// 다음 조각의 writer를 다른 큐에서 미리 만들어 둔다.
final class SegmentRecorder {
    static let segmentSeconds = 1.0
    static let keepSeconds = 6.0

    let folder: URL
    private var queue: DispatchQueue?
    private var settings: [String: Any]?
    private let prepareQueue = DispatchQueue(label: "pitcheye.segments.prepare")

    // 아래는 캡처 프레임 큐에서만 접근
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var currentName = ""
    private var currentStart = 0.0
    private var lastFrame = 0.0
    private var prepared: (writer: AVAssetWriter, input: AVAssetWriterInput, name: String)?
    private var preparing = false
    private var counter = 0

    // 아래는 다른 스레드에서도 읽으므로 lock으로 보호
    private let lock = NSLock()
    private var finished: [Segment] = []
    private var pendingPitchTimes: [Double] = []
    private var latest: Double?
    private var skippedFrames = 0

    init(folder: URL) {
        self.folder = folder
        try? FileManager.default.removeItem(at: folder)  // 지난 경기의 조각은 필요 없다
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// 카메라 설정이 끝난 뒤 캡처 쪽에서 부른다.
    func configure(queue: DispatchQueue, settings: [String: Any]?) {
        self.queue = queue
        self.settings = settings
    }

    // MARK: 다른 스레드에서 쓰는 것

    /// 마지막으로 받은 프레임의 시각 (촬영 시계, 초). 아직 프레임이 없으면 nil.
    var latestTime: Double? { lock.withLock { latest } }
    var skipped: Int { lock.withLock { skippedFrames } }
    func segments() -> [Segment] { lock.withLock { finished } }

    /// 이 시각의 투구 영상을 만들 때까지 관련 조각을 지우지 않는다.
    func hold(_ time: Double) { lock.withLock { pendingPitchTimes.append(time) } }
    func release(_ time: Double) {
        lock.withLock {
            if let i = pendingPitchTimes.firstIndex(of: time) { pendingPitchTimes.remove(at: i) }
        }
    }

    // MARK: 캡처 프레임 큐

    func append(_ sampleBuffer: CMSampleBuffer) {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let t = time.seconds
        if writer == nil || t - currentStart >= Self.segmentSeconds { rotate(at: time) }
        if let input, input.isReadyForMoreMediaData, input.append(sampleBuffer) {
            lastFrame = t
            lock.withLock { latest = t }
        } else {
            lock.withLock { skippedFrames += 1 }
        }
    }

    func stop() {
        queue?.async {
            if let writer = self.writer, let input = self.input { self.close(writer, input) }
            (self.writer, self.input) = (nil, nil)
            if let p = self.prepared {
                p.writer.cancelWriting()
                try? FileManager.default.removeItem(at: self.folder.appendingPathComponent(p.name))
            }
            self.prepared = nil
        }
    }

    private func rotate(at time: CMTime) {
        if let writer, let input { close(writer, input) }
        guard let next = prepared ?? makeWriter(name: nextName()) else { (writer, input) = (nil, nil); return }
        prepared = nil
        next.writer.startSession(atSourceTime: time)
        (writer, input, currentName, currentStart) = (next.writer, next.input, next.name, time.seconds)
        prepareNext()
    }

    private func close(_ writer: AVAssetWriter, _ input: AVAssetWriterInput) {
        let segment = Segment(file: currentName, start: currentStart, end: lastFrame + 1 / 240)
        input.markAsFinished()
        writer.finishWriting { [weak self] in
            guard let self, writer.status == .completed else { return }
            self.lock.withLock { self.finished.append(segment) }
            self.prune(now: segment.end)
        }
    }

    private func prune(now: Double) {
        let expired: [Segment] = lock.withLock {
            let old = ClipWindow.expired(finished, now: now, keep: Self.keepSeconds, pendingPitchTimes: pendingPitchTimes)
            finished.removeAll { s in old.contains(s) }
            return old
        }
        for s in expired { try? FileManager.default.removeItem(at: folder.appendingPathComponent(s.file)) }
    }

    private func nextName() -> String {
        counter += 1
        return String(format: "seg-%06d.mov", counter)
    }

    private func prepareNext() {
        guard !preparing, let queue else { return }
        preparing = true
        let name = nextName()
        prepareQueue.async {
            let made = self.makeWriter(name: name)
            queue.async {
                self.prepared = made
                self.preparing = false
            }
        }
    }

    private func makeWriter(name: String) -> (writer: AVAssetWriter, input: AVAssetWriterInput, name: String)? {
        guard let writer = try? AVAssetWriter(outputURL: folder.appendingPathComponent(name), fileType: .mov) else { return nil }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        return (writer, input, name)
    }
}

/// 조각 파일들의 구간을 잘라 이어 붙여 투구 영상 하나로 만든다. 다시 압축하지 않는다(passthrough).
enum ClipExporter {
    struct ExportError: Error {}

    static func export(_ pieces: [ClipPiece], from folder: URL, to url: URL) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError()
        }
        var cursor = CMTime.zero
        for piece in pieces {
            let asset = AVURLAsset(url: folder.appendingPathComponent(piece.file))
            guard let source = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError() }
            let range = CMTimeRange(start: CMTime(seconds: piece.from, preferredTimescale: 24_000),
                                    end: CMTime(seconds: piece.to, preferredTimescale: 24_000))
            try track.insertTimeRange(range, of: source, at: cursor)
            cursor = cursor + range.duration
        }
        try? FileManager.default.removeItem(at: url)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError()
        }
        session.outputURL = url
        session.outputFileType = .mov
        await session.export()
        guard session.status == .completed else { throw session.error ?? ExportError() }
    }
}
