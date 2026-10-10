import AVFoundation
import SwiftUI

/// 촬영 화면과, 촬영을 끝낸 뒤의 결과 화면.
struct CaptureView: View {
    let onDone: () -> Void
    @StateObject private var capture = CaptureController()

    private var finished: Bool { !capture.isRunning && !capture.records.isEmpty }

    var body: some View {
        Group {
            if finished { result } else { live }
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { capture.start() }
        .onDisappear { if capture.isRunning { capture.stop() } }
    }

    // MARK: 촬영 중

    private var live: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            let layout = wide ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 16))
            layout {
                CameraPreview(session: capture.session)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(Theme.text)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView(showsIndicators: false) { panel }
                    .frame(width: wide ? 260 : nil)
            }
            .padding(16)
        }
    }

    private var panel: some View {
        VStack(spacing: 10) {
            Text(clock(capture.stats.elapsed))
                .font(.system(size: 44, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
            verdict(capture.stats, capture.thermal)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    tile("실측 fps", String(format: "%.1f", capture.stats.measuredFPS))
                    tile("빠진 프레임", "\(capture.stats.gaps)")
                }
                GridRow {
                    tile("버려진 프레임", "\(capture.stats.dropped)")
                    tile("발열", capture.thermal.label)
                }
            }
            if !capture.isRunning, capture.status != "대기" {
                Text(capture.status).font(.footnote).foregroundStyle(Status.danger.foreground)
            }
            Button {
                capture.isRunning ? capture.stop() : onDone()
            } label: {
                Label(capture.isRunning ? "촬영 끝내기" : "홈으로", systemImage: capture.isRunning ? "stop.fill" : "house")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
    }

    private func verdict(_ stats: FrameStats, _ thermal: ProcessInfo.ThermalState) -> StatusLabel {
        let lost = stats.gaps + stats.dropped
        if thermal == .serious || thermal == .critical {
            return StatusLabel(text: "발열이 높습니다 (\(thermal.label))", status: .danger)
        }
        if lost > 0 {
            return StatusLabel(text: "프레임이 \(lost)번 빠졌습니다", status: .warning)
        }
        return StatusLabel(text: "빠진 프레임 없음", status: .good)
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Theme.secondaryText)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                .foregroundStyle(Theme.text).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 결과

    private var result: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("촬영 결과")
                    .font(.title.weight(.bold))
                    .foregroundStyle(Theme.text)
                Text(resultSummary)
                    .font(.body)
                    .foregroundStyle(Theme.secondaryText)
                verdict(capture.stats, capture.thermal)

                VStack(spacing: 0) {
                    ForEach(capture.records) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(record.label) (\(clock(record.stats.elapsed)))")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.text)
                            Text(summary(record))
                                .font(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        if record.id != capture.records.last?.id {
                            Rectangle().fill(Theme.border).frame(height: 1)
                        }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border, lineWidth: 1))

                ShareLink(item: report) {
                    Label("결과 보내기", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(PrimaryButtonStyle())
                Button(action: onDone) {
                    Label("홈으로", systemImage: "house")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
    }

    private var resultSummary: String {
        let lost = capture.stats.gaps + capture.stats.dropped
        let time = clock(capture.stats.elapsed)
        return lost == 0
            ? "\(time) 동안 빠진 프레임 없이 촬영했습니다."
            : "\(time) 동안 프레임이 \(lost)번 빠졌습니다."
    }

    private func summary(_ record: MeasurementRecord) -> String {
        let s = record.stats
        return String(format: "%.1ffps · 빠짐 %d · 버림 %d · 최대 간격 %.2fms · 발열 %@",
                      s.measuredFPS, s.gaps, s.dropped, s.maxInterval * 1000, record.thermal.label)
    }

    private var report: String {
        (["PitchEye 240fps 캡처 점검",
          "모델 코드: \(DeviceProbe.modelIdentifier) / \(DeviceProbe.osVersion)",
          "포맷: \(capture.activeFormat)"]
            + capture.records.map { "\($0.label) (\(clock($0.stats.elapsed))): \(summary($0))" })
            .joined(separator: "\n")
    }
}

extension ProcessInfo.ThermalState {
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

        // 폰을 돌리면 미리보기도 따라 돌린다. 후면 카메라 센서는 가로(홈 버튼 오른쪽)가 0도다.
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let connection = previewLayer.connection,
                  let orientation = window?.windowScene?.interfaceOrientation else { return }
            let angle: CGFloat = switch orientation {
            case .landscapeRight: 0
            case .landscapeLeft: 180
            case .portraitUpsideDown: 270
            default: 90
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }
}
