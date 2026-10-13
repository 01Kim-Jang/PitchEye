import AVFoundation

/// 프레임 콜백으로 받은 버퍼를 그대로 .mov 파일로 쓴다. 프레임의 원래 타임스탬프가 보존된다.
/// 캡처 출력을 하나 더 붙이지 않으므로 측정과 동시에 녹화할 수 있고, 링버퍼도 이 경로를 쓸 예정이다.
/// 모든 메서드는 캡처 프레임 큐에서만 호출한다.
final class ClipRecorder {
    static let maxSeconds = 30.0

    static var folder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("clips")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var startTime = CMTime.zero
    private(set) var url: URL?
    private(set) var frames = 0
    /// 인코더가 따라오지 못해 파일에 쓰지 못한 프레임 수
    private(set) var skipped = 0
    private(set) var seconds = 0.0

    var isRecording: Bool { writer != nil }

    func begin(url: URL, settings: [String: Any]?, at time: CMTime) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: time)
        (self.writer, self.input, self.url, startTime) = (writer, input, url, time)
        (frames, skipped, seconds) = (0, 0, 0)
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let input else { return }
        if input.isReadyForMoreMediaData, input.append(sampleBuffer) {
            frames += 1
        } else {
            skipped += 1
        }
        seconds = (CMSampleBufferGetPresentationTimeStamp(sampleBuffer) - startTime).seconds
    }

    /// 파일을 닫는다. 실패하면 completion에 false가 간다.
    func finish(completion: @escaping (Bool) -> Void) {
        guard let writer, let input else { return completion(false) }
        (self.writer, self.input) = (nil, nil)
        input.markAsFinished()
        writer.finishWriting { completion(writer.status == .completed) }
    }
}
