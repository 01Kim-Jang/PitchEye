import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var capture = CaptureController()
    private let formats = DeviceProbe.highSpeedFormats()
    private let supported = DeviceProbe.requiredFormat() != nil

    var body: some View {
        NavigationStack {
            List {
                Section("최소 사양") {
                    row("해상도", "\(Requirements.width)×\(Requirements.height)")
                    row("프레임레이트", "\(Int(Requirements.fps))fps")
                    row("링버퍼", "최근 약 \(Int(Requirements.ringBufferSeconds))초")
                    row("OS", "\(Requirements.minimumOS) 이상")
                    row("기준 테스트 기기", Requirements.testDevice)
                }

                Section("이 기기") {
                    row("모델", DeviceProbe.modelIdentifier)
                    row("OS", DeviceProbe.osVersion)
                    row("1080p@240fps", supported ? "지원" : "미지원")
                        .foregroundStyle(supported ? .green : .red)
                }

                Section("캡처 측정") {
                    if capture.isRunning {
                        CameraPreview(session: capture.session)
                            .aspectRatio(16.0 / 9.0, contentMode: .fit)
                            .listRowInsets(EdgeInsets())
                    }
                    row("상태", capture.status)
                    row("사용 포맷", capture.activeFormat)
                    row("실측 fps", String(format: "%.1f", capture.stats.measuredFPS))
                    row("경과", String(format: "%.0f초", capture.stats.elapsed))
                    row("프레임 수", "\(capture.stats.frames)")
                    row("간격 이상(타임스탬프)", "\(capture.stats.gaps)")
                    row("드롭(시스템 보고)", "\(capture.stats.dropped)")
                    row("최대 간격", String(format: "%.2fms", capture.stats.maxInterval * 1000))
                    row("발열 상태", capture.thermal.label)
                    Button(capture.isRunning ? "정지" : "측정 시작") {
                        capture.isRunning ? capture.stop() : capture.start()
                    }
                    .disabled(!supported)
                }

                Section("고속 포맷 (120fps 이상)") {
                    if formats.isEmpty { Text("없음 (시뮬레이터에는 카메라가 없습니다)") }
                    ForEach(formats) { format in
                        VStack(alignment: .leading) {
                            Text("\(format.width)×\(format.height) @ \(Int(format.maxFPS))fps")
                            Text("\(format.camera) · \(format.pixelFormat) · 화각 \(String(format: "%.0f", format.fieldOfView))°")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("PitchEye 캡처 점검")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
    }
}

private extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: "정상"
        case .fair: "약간 높음"
        case .serious: "높음"
        case .critical: "위험"
        @unknown default: "알 수 없음"
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
