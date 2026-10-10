import SwiftUI

/// 촬영 전 안내. 내용은 docs/capture-protocol.md와 맞춘다.
struct GuideView: View {
    /// 촬영으로 이어지는 흐름이면 true (건너뛰기와 "다음부터 보지 않기"를 보여준다).
    let showsSkip: Bool
    let onFinish: () -> Void

    @AppStorage("showGuideBeforeCapture") private var showGuide = true
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var index = 0

    private struct Step {
        let icon: String
        let title: String
        let body: String
    }

    private let steps = [
        Step(icon: "camera.viewfinder", title: "설치 위치",
             body: "백네트 뒤, 약 3m 높이에 폰을 가로로 세웁니다. 홈플레이트 전체와 양쪽 타석이 화면에 들어와야 합니다."),
        Step(icon: "lock", title: "단단히 고정",
             body: "촬영 중 폰이 움직이면 그 촬영은 쓸 수 없습니다. 고정한 뒤에는 만지지 않습니다."),
        Step(icon: "thermometer.sun", title: "발열과 배터리",
             body: "직사광선을 피하고 외부 배터리를 연결합니다. 방해 금지 모드를 켭니다."),
        Step(icon: "checkmark.shield", title: "촬영 동의",
             body: "선수, 심판, 구장의 동의를 받았는지 확인합니다. 결과는 참고용이며 최종 판정은 심판이 합니다."),
    ]

    private var isLast: Bool { index == steps.count - 1 }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("\(index + 1) / \(steps.count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button(showsSkip ? "건너뛰기" : "닫기", action: onFinish)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .frame(minWidth: 44, minHeight: 44)
            }

            if verticalSizeClass == .compact {
                HStack(spacing: 24) {
                    illustration
                    text.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 24) {
                    illustration.frame(height: 220)
                    text
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? Theme.text : Theme.border)
                        .frame(width: i == index ? 20 : 6, height: 6)
                }
            }

            if isLast, showsSkip {
                Toggle("다음부터 보지 않기", isOn: Binding(get: { !showGuide }, set: { showGuide = !$0 }))
                    .font(.subheadline)
                    .foregroundStyle(Theme.text)
                    .tint(Theme.text)
            }

            HStack(spacing: 12) {
                if index > 0 {
                    Button("이전") { index -= 1 }
                        .buttonStyle(SecondaryButtonStyle())
                        .frame(maxWidth: 120)
                }
                Button(isLast ? (showsSkip ? "촬영 시작" : "확인") : "다음") {
                    if isLast { onFinish() } else { index += 1 }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
        }
        .padding(24)
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .animation(.easeOut(duration: 0.2), value: index)
    }

    private var illustration: some View {
        RoundedRectangle(cornerRadius: Theme.radius)
            .fill(Theme.surface)
            .overlay {
                Image(systemName: steps[index].icon)
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(Theme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(steps[index].title)
                .font(.title.weight(.bold))
                .foregroundStyle(Theme.text)
            Text(steps[index].body)
                .font(.body)
                .foregroundStyle(Theme.secondaryText)
                .lineSpacing(4)
        }
    }
}
