import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var capture = CaptureController()
    private let formats = DeviceProbe.highSpeedFormats()
    private let supported = DeviceProbe.requiredFormat() != nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    supportCard
                    if capture.isRunning {
                        liveSection
                    } else {
                        startSection
                    }
                    if !capture.records.isEmpty { recordsSection }
                    detailsSection
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("240fps 캡처 점검")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 1. 이 기기가 되는가

    private var supportCard: some View {
        HStack(spacing: 12) {
            Image(systemName: supported ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(supported ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(supported ? "이 기기는 1080p 240fps를 지원합니다" : "이 기기는 1080p 240fps를 지원하지 않습니다")
                    .font(.headline)
                Text("모델 코드 \(DeviceProbe.modelIdentifier) · \(DeviceProbe.osVersion)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .card()
    }

    // MARK: 2. 측정 전

    private var startSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("무엇을 재나요?").font(.headline)
            Text("카메라를 켜고, 프레임이 1초에 240장씩 빠짐없이 들어오는지 확인합니다. 버튼을 누른 뒤 폰을 세워 두면 됩니다.")
            Text("1분·10분·30분 결과는 자동으로 기록되니 화면을 캡처하지 않아도 됩니다. 측정 중에는 화면이 꺼지지 않습니다.")
                .foregroundStyle(.secondary)
            if capture.status != "대기", capture.status != "정지" {
                Text(capture.status).foregroundStyle(.red)
            }
            Button {
                capture.start()
            } label: {
                Label("측정 시작", systemImage: "play.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!supported)
        }
        .font(.subheadline)
        .card()
    }

    // MARK: 3. 측정 중

    private var liveSection: some View {
        VStack(spacing: 12) {
            CameraPreview(session: capture.session)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(clock(capture.stats.elapsed))
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text("측정 시간 · \(capture.activeFormat)")
                .font(.caption)
                .foregroundStyle(.secondary)

            verdictBanner(capture.stats, capture.thermal)

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    tile("실측 fps", String(format: "%.1f", capture.stats.measuredFPS), "240에 가까울수록 좋음")
                    tile("빠진 프레임", "\(capture.stats.gaps)", "프레임 사이 간격이 벌어진 횟수")
                }
                GridRow {
                    tile("버려진 프레임", "\(capture.stats.dropped)", "처리가 늦어 시스템이 버린 수")
                    tile("발열", capture.thermal.label, "높음 이상이면 성능이 떨어짐")
                }
            }

            Button(role: .destructive) {
                capture.stop()
            } label: {
                Label("측정 끝내기", systemImage: "stop.fill")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.bordered)
        }
        .card()
    }

    private func verdictBanner(_ stats: FrameStats, _ thermal: ProcessInfo.ThermalState) -> some View {
        let lost = stats.gaps + stats.dropped
        let hot = thermal == .serious || thermal == .critical
        let (text, color, icon): (String, Color, String) =
            hot ? ("발열이 높습니다 (\(thermal.label))", .red, "thermometer.high")
            : lost > 0 ? ("프레임이 \(lost)번 빠졌습니다", .orange, "exclamationmark.triangle.fill")
            : ("빠진 프레임 없이 들어오고 있습니다", .green, "checkmark.circle.fill")
        return Label(text, systemImage: icon)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(.white)
            .background(color, in: RoundedRectangle(cornerRadius: 10))
    }

    private func tile(_ title: String, _ value: String, _ hint: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title.bold()).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
            Text(hint).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 4. 기록

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("기록").font(.headline)
            ForEach(capture.records) { record in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(record.label) (\(clock(record.stats.elapsed)))").font(.subheadline.bold())
                    Text(summary(record)).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                }
                Divider()
            }
            ShareLink(item: report) {
                Label("결과 보내기", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .card()
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

    // MARK: 5. 자세히

    private var detailsSection: some View {
        DisclosureGroup("자세히 (최소 사양, 지원 포맷)") {
            VStack(alignment: .leading, spacing: 6) {
                Text("최소 사양").font(.subheadline.bold()).padding(.top, 8)
                detail("해상도", "\(Requirements.width)×\(Requirements.height)")
                detail("프레임레이트", "\(Int(Requirements.fps))fps")
                detail("링버퍼", "최근 약 \(Int(Requirements.ringBufferSeconds))초 (미구현)")
                detail("OS", "\(Requirements.minimumOS) 이상")
                detail("기준 테스트 기기", Requirements.testDevice)

                Text("이 기기의 고속 포맷 (120fps 이상)").font(.subheadline.bold()).padding(.top, 8)
                if formats.isEmpty { Text("없음 (시뮬레이터에는 카메라가 없습니다)").font(.footnote) }
                ForEach(formats) { format in
                    detail("\(format.width)×\(format.height) @ \(Int(format.maxFPS))fps",
                           "\(format.camera) · \(format.pixelFormat) · \(String(format: "%.0f", format.fieldOfView))°")
                }
            }
        }
        .font(.subheadline)
        .card()
    }

    private func detail(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value).font(.footnote)
    }

    private func clock(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

private extension View {
    func card() -> some View {
        padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
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
    }
}
