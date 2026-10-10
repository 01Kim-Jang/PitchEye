import SwiftUI

@main
struct PitchEyeApp: App {
    init() {
        #if DEBUG
        FrameStats.selfCheck()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(.light) // 야외 가독성을 위해 라이트 고정
                .tint(Theme.text)
        }
    }
}
