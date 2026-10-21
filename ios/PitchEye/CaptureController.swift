import AVFoundation
import Combine
import UIKit

/// 측정 중 특정 시점의 결과. 화면을 캡처하지 않아도 기록이 남는다.
struct MeasurementRecord: Identifiable {
    let id = UUID()
    let label: String
    let stats: FrameStats
    let thermal: ProcessInfo.ThermalState
}

/// 1080p@240fps로 프레임을 실시간으로 받아 실제 프레임 간격을 잰다.
/// 파일 녹화가 아니라 프레임 콜백 방식이다(링버퍼·판정 파이프라인과 같은 경로).
final class CaptureController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var status = "대기"
    @Published var isRunning = false
    @Published var stats = FrameStats(fps: Requirements.fps)
    @Published var thermal = ProcessInfo.processInfo.thermalState
    @Published var activeFormat = "-"
    @Published var records: [MeasurementRecord] = []
    @Published var exposure = "-"
    @Published var isRecording = false
    @Published var recordingSeconds = 0.0
    @Published var clipMessage = ""

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "pitcheye.session")
    private let frameQueue = DispatchQueue(label: "pitcheye.frames")
    private var liveStats = FrameStats(fps: Requirements.fps) // frameQueue에서만 접근
    private var configured = false
    private var device: AVCaptureDevice?
    private var videoOutput: AVCaptureVideoDataOutput?
    // 아래 셋은 frameQueue에서만 접근
    private let recorder = ClipRecorder()
    /// 경기 모드에서 계속 녹화할 때 설정한다. 시작 전에 넣어야 한다.
    var segmentRecorder: SegmentRecorder?
    private var wantsRecording = false
    private var clipInfo: [String: Any] = [:]
    private var pendingCheckpoints: [Double] = [] // 초 단위, main에서만 접근

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { return self.publish(status: "카메라 권한이 없습니다") }
            self.sessionQueue.async {
                if !self.configured { self.configure() }
                guard self.configured else { return }
                self.frameQueue.sync { self.liveStats = FrameStats(fps: Requirements.fps) }
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.status = "촬영 중"
                    self.stats = FrameStats(fps: Requirements.fps)
                    self.records = []
                    self.pendingCheckpoints = [60, 600, 1800]
                    UIApplication.shared.isIdleTimerDisabled = true // 측정 중 화면이 꺼지면 캡처가 멈춘다
                }
            }
        }
    }

    /// 녹화를 시작하거나 끝낸다. memo는 파일 이름과 정보 파일에 들어간다(예: "3m").
    func toggleRecording(memo: String) {
        frameQueue.async {
            self.wantsRecording.toggle()
            self.clipInfo = ["memo": memo]
        }
    }

    func stop() {
        segmentRecorder?.stop()
        sessionQueue.async {
            self.session.stopRunning()
            let final: FrameStats = self.frameQueue.sync {
                self.wantsRecording = false
                if self.recorder.isRecording { self.finishClip() }
                return self.liveStats
            }
            DispatchQueue.main.async {
                self.stats = final
                self.isRunning = false
                self.status = "정지"
                self.record("종료", final)
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
    }

    private func configure() {
        guard let (device, format) = DeviceProbe.requiredFormat() else {
            return publish(status: "이 기기는 1080p@240fps 포맷을 제공하지 않습니다")
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)

            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard session.canAddInput(input), session.canAddOutput(output) else {
                return publish(status: "세션에 입력·출력을 추가할 수 없습니다")
            }
            session.addInput(input)
            session.addOutput(output)

            // activeFormat은 입력을 추가한 뒤에 설정해야 세션 프리셋에 덮이지 않는다.
            try device.lockForConfiguration()
            device.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(Requirements.fps))
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            // 빠른 공이 번지지 않게 노출 시간의 상한을 둘 수 있다(설정 화면). 0이면 자동.
            let denominator = UserDefaults.standard.integer(forKey: "maxExposureDenominator")
            if denominator > 0 {
                let limit = CMTime(value: 1, timescale: CMTimeScale(denominator))
                device.activeMaxExposureDuration = CMTimeMaximum(limit, format.minExposureDuration)
            }
            device.unlockForConfiguration()
            self.device = device
            self.videoOutput = output
            segmentRecorder?.configure(queue: frameQueue,
                                       settings: output.recommendedVideoSettings(forVideoCodecType: .hevc, assetWriterOutputFileType: .mov))

            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let description = "\(device.localizedName) \(dims.width)×\(dims.height) @ \(Int(DeviceProbe.maxFPS(format)))fps"
            DispatchQueue.main.async { self.activeFormat = description }
            configured = true
        } catch {
            publish(status: "카메라 설정 실패: \(error.localizedDescription)")
        }
    }

    private func publish(status: String) {
        DispatchQueue.main.async { self.status = status }
    }

    // MARK: 프레임 콜백 (frameQueue)

    // 프레임을 붙잡아 두면 캡처 버퍼 풀이 말라 드롭이 생긴다. 그래서 녹화는 받은 즉시 인코더로 넘긴다(ClipRecorder).
    // ponytail: 3초 링버퍼는 아직 없다. 녹화는 버튼을 누른 뒤부터만 저장한다. 링버퍼는 인코딩된 프레임을 보관하는 방식으로 별도 구현.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        liveStats.add(timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
        segmentRecorder?.append(sampleBuffer)
        if wantsRecording, !recorder.isRecording { beginClip(at: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) }
        if recorder.isRecording {
            recorder.append(sampleBuffer)
            if !wantsRecording || recorder.seconds >= ClipRecorder.maxSeconds { finishClip() }
        }
        if liveStats.frames % Int(Requirements.fps) == 0 { publishStats() } // 약 1초마다 화면 갱신
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        liveStats.addDrop()
    }

    private var exposureText: String {
        guard let device, device.exposureDuration.seconds > 0 else { return "-" }
        return "1/\(Int((1 / device.exposureDuration.seconds).rounded()))초 · ISO \(Int(device.iso))"
    }

    private func beginClip(at time: CMTime) {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let memo = (clipInfo["memo"] as? String ?? "").unicodeScalars.filter(CharacterSet.alphanumerics.contains)
        let name = stamp.string(from: Date()) + (memo.isEmpty ? "" : "-" + String(String.UnicodeScalarView(memo)))
        let settings = videoOutput?.recommendedVideoSettings(forVideoCodecType: .hevc, assetWriterOutputFileType: .mov)
        do {
            try recorder.begin(url: ClipRecorder.folder.appendingPathComponent(name + ".mov"), settings: settings, at: time)
        } catch {
            wantsRecording = false
            return DispatchQueue.main.async { self.clipMessage = "녹화를 시작하지 못했습니다: \(error.localizedDescription)" }
        }
        clipInfo["model_code"] = DeviceProbe.modelIdentifier
        clipInfo["os"] = DeviceProbe.osVersion
        clipInfo["exposure_seconds"] = device?.exposureDuration.seconds ?? 0
        clipInfo["iso"] = device?.iso ?? 0
        clipInfo["lens_position"] = device?.lensPosition ?? 0
        clipInfo["field_of_view_deg"] = device?.activeFormat.videoFieldOfView ?? 0
        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingSeconds = 0
            self.clipMessage = ""
        }
    }

    private func finishClip() {
        wantsRecording = false
        guard let url = recorder.url else { return }
        var info = clipInfo
        info["frames"] = recorder.frames
        info["frames_skipped_by_encoder"] = recorder.skipped
        info["seconds"] = recorder.seconds
        info["nominal_fps"] = Requirements.fps
        let (frames, skipped) = (recorder.frames, recorder.skipped)
        recorder.finish { ok in
            if ok, let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: url.deletingPathExtension().appendingPathExtension("json"))
            }
            DispatchQueue.main.async {
                self.isRecording = false
                self.clipMessage = ok
                    ? "저장했습니다: \(url.lastPathComponent) (\(frames)프레임" + (skipped > 0 ? ", \(skipped)프레임 누락)" : ")")
                    : "저장하지 못했습니다"
            }
        }
    }

    private func publishStats() {
        let snapshot = liveStats
        let (exposure, seconds) = (exposureText, recorder.seconds)
        DispatchQueue.main.async {
            self.stats = snapshot
            self.exposure = exposure
            if self.isRecording { self.recordingSeconds = seconds }
            self.thermal = ProcessInfo.processInfo.thermalState
            while let next = self.pendingCheckpoints.first, snapshot.elapsed >= next {
                self.pendingCheckpoints.removeFirst()
                self.record("\(Int(next / 60))분", snapshot)
            }
        }
    }

    private func record(_ label: String, _ stats: FrameStats) {
        records.append(MeasurementRecord(label: label, stats: stats, thermal: ProcessInfo.processInfo.thermalState))
    }
}
