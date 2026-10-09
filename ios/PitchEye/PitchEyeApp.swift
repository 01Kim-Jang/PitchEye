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
            ContentView()
        }
    }
}
