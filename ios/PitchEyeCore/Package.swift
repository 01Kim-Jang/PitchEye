// swift-tools-version: 6.0
// 판정 엔진과 경기 기록. 카메라·화면과 무관한 순수 계산이라 앱과 분리해 Mac에서 `swift test`로 검증한다.
import PackageDescription

let package = Package(
    name: "PitchEyeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "PitchEyeCore", targets: ["PitchEyeCore"])],
    targets: [
        .target(name: "PitchEyeCore"),
        .testTarget(name: "PitchEyeCoreTests", dependencies: ["PitchEyeCore"]),
    ]
)
