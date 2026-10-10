import SwiftUI

enum Route: Hashable {
    case guide(thenCapture: Bool)
    case capture
    case settings
}

struct HomeView: View {
    @AppStorage("showGuideBeforeCapture") private var showGuide = true
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var path: [Route] = []
    @State private var showUnsupported = false
    private let supported = DeviceProbe.requiredFormat() != nil

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                // 가로로 든 폰(세로 공간이 좁음)에서는 좌우로 나눈다.
                if verticalSizeClass == .compact {
                    HStack(alignment: .center, spacing: 32) {
                        header.frame(maxWidth: .infinity, alignment: .leading)
                        buttons.frame(maxWidth: 360)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        header.padding(.top, 32)
                        Spacer(minLength: 24)
                        buttons
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .guide(let thenCapture):
                    GuideView(showsSkip: thenCapture) {
                        path = thenCapture ? [.capture] : []
                    }
                case .capture:
                    CaptureView { path = [] }
                case .settings:
                    SettingsView()
                }
            }
            .alert("이 기기로는 촬영할 수 없습니다", isPresented: $showUnsupported) {
                Button("확인", role: .cancel) {}
            } message: {
                Text("1080p 240fps 촬영을 지원하는 아이폰이 필요합니다. 시뮬레이터에는 카메라가 없습니다.")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PitchEye")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Theme.text)
            Text("사회인야구 볼·스트라이크 판정 보조")
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
            Text(supported ? "240fps 촬영 지원 기기" : "240fps 촬영 미지원 기기")
                .font(.footnote.weight(.semibold))
                .foregroundStyle((supported ? Status.good : Status.danger).foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background((supported ? Status.good : Status.danger).background, in: Capsule())
                .padding(.top, 8)
        }
    }

    private var buttons: some View {
        VStack(spacing: 12) {
            Button {
                if !supported {
                    showUnsupported = true
                } else {
                    path = [showGuide ? .guide(thenCapture: true) : .capture]
                }
            } label: {
                Label("촬영 시작", systemImage: "play.fill")
            }
            .buttonStyle(PrimaryButtonStyle())

            Button {
                path = [.settings]
            } label: {
                Label("촬영 설정", systemImage: "gearshape")
            }
            .buttonStyle(SecondaryButtonStyle())

            Button {
                path = [.guide(thenCapture: false)]
            } label: {
                Label("사용 안내", systemImage: "book")
            }
            .buttonStyle(SecondaryButtonStyle())

            Text("참고용 도구입니다. 최종 판정은 심판이 합니다.")
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
    }
}
