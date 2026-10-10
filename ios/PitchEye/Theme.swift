import SwiftUI

/// 화면 공통 규칙. docs/ui-redesign-plan.md 5장.
/// 흰 바탕, 그림자 없음, 강조색 없음. 색은 상태 표시에만 쓴다.
enum Theme {
    static let background = Color.white
    static let surface = Color(red: 0.969, green: 0.969, blue: 0.961) // #F7F7F5
    static let text = Color(red: 0.067, green: 0.067, blue: 0.067) // #111111
    static let secondaryText = Color(red: 0.471, green: 0.467, blue: 0.455) // #787774
    static let border = Color(red: 0.918, green: 0.918, blue: 0.918) // #EAEAEA
    static let radius: CGFloat = 16
}

enum Status {
    case good, warning, danger

    var background: Color {
        switch self {
        case .good: Color(red: 0.929, green: 0.953, blue: 0.925) // #EDF3EC
        case .warning: Color(red: 0.984, green: 0.953, blue: 0.859) // #FBF3DB
        case .danger: Color(red: 0.992, green: 0.922, blue: 0.925) // #FDEBEC
        }
    }

    var foreground: Color {
        switch self {
        case .good: Color(red: 0.204, green: 0.396, blue: 0.220) // #346538
        case .warning: Color(red: 0.584, green: 0.392, blue: 0.0) // #956400
        case .danger: Color(red: 0.624, green: 0.184, blue: 0.176) // #9F2F2D
        }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Theme.text, in: RoundedRectangle(cornerRadius: Theme.radius))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.text)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct StatusLabel: View {
    let text: String
    let status: Status

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(status.foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(status.background, in: RoundedRectangle(cornerRadius: 10))
    }
}

func clock(_ seconds: Double) -> String {
    String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
}
