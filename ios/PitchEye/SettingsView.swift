import SwiftUI

/// 지금 실제로 의미가 있는 설정만 둔다. 링버퍼 길이 등은 해당 기능을 만들 때 추가한다.
struct SettingsView: View {
    @AppStorage("showGuideBeforeCapture") private var showGuide = true
    private let formats = DeviceProbe.highSpeedFormats()
    private let supported = DeviceProbe.requiredFormat() != nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                section("안내") {
                    Toggle("촬영 전 안내 표시", isOn: $showGuide)
                        .tint(Theme.text)
                        .padding(14)
                }
                section("촬영 사양") {
                    row("해상도", "\(Requirements.width)×\(Requirements.height)")
                    divider
                    row("프레임레이트", "\(Int(Requirements.fps))fps")
                    divider
                    row("최소 OS", Requirements.minimumOS)
                }
                section("이 기기") {
                    row("모델 코드", DeviceProbe.modelIdentifier)
                    divider
                    row("OS", DeviceProbe.osVersion)
                    divider
                    row("1080p 240fps", supported ? "지원" : "미지원")
                }
                section("지원 포맷 (120fps 이상)") {
                    DisclosureGroup("\(formats.count)개") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(formats) { format in
                                Text("\(format.width)×\(format.height) @ \(Int(format.maxFPS))fps · \(format.camera) · \(format.pixelFormat) · \(String(format: "%.0f", format.fieldOfView))°")
                                    .font(.footnote)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.secondaryText)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                    }
                    .tint(Theme.text)
                    .padding(14)
                }
            }
            .foregroundStyle(Theme.text)
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("촬영 설정")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.secondaryText)
            VStack(spacing: 0) { content() }
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border, lineWidth: 1))
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(Theme.secondaryText).monospacedDigit()
        }
        .padding(14)
    }

    private var divider: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }
}
