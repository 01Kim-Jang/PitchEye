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

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "pitcheye.session")
    private let frameQueue = DispatchQueue(label: "pitcheye.frames")
    private var liveStats = FrameStats(fps: Requirements.fps) // frameQueue에서만 접근
    private var configured = false
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

    func stop() {
        sessionQueue.async {
            self.session.stopRunning()
            let final = self.frameQueue.sync { self.liveStats }
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
            device.unlockForConfiguration()

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

    // ponytail: 여기서는 타임스탬프만 기록한다. 프레임을 붙잡아 두면 캡처 버퍼 풀이 말라 드롭이 생기므로,
    // 실제 3초 링버퍼는 압축 저장(예: VideoToolbox) 방식으로 별도 PR에서 구현한다.
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        liveStats.add(timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds)
        if liveStats.frames % Int(Requirements.fps) == 0 { publishStats() } // 약 1초마다 화면 갱신
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        liveStats.addDrop()
    }

    private func publishStats() {
        let snapshot = liveStats
        DispatchQueue.main.async {
            self.stats = snapshot
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
