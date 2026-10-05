import AVFoundation
import UIKit

/// 앱이 요구하는 최소 사양. 사양 화면과 포맷 선택이 모두 이 값을 쓴다.
enum Requirements {
    static let width: Int32 = 1920
    static let height: Int32 = 1080
    static let fps: Double = 240
    static let ringBufferSeconds: Double = 3
    static let minimumOS = "iOS 17.0"
    static let testDevice = "iPhone 17"
}

struct FormatInfo: Identifiable {
    let id = UUID()
    let camera: String
    let width: Int32
    let height: Int32
    let maxFPS: Double
    let pixelFormat: String
    let fieldOfView: Float
}

enum DeviceProbe {
    /// 예: "iPhone18,3". 기종명 대신 식별자를 그대로 보여준다(매핑표를 유지하지 않기 위해).
    static var modelIdentifier: String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    static var osVersion: String { "iOS \(UIDevice.current.systemVersion)" }

    /// 기종마다 후면 카메라 구성이 다르므로(일반 2개, Pro 3개) 있는 것을 모두 찾는다. 광각이 먼저 온다.
    static func backCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .back
        ).devices
    }

    static func maxFPS(_ format: AVCaptureDevice.Format) -> Double {
        format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
    }

    /// 120fps 이상 포맷 목록 (사양 화면 표시용).
    static func highSpeedFormats() -> [FormatInfo] {
        backCameras().flatMap { camera in
            camera.formats.filter { maxFPS($0) >= 120 }.map { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return FormatInfo(
                    camera: camera.localizedName,
                    width: dims.width,
                    height: dims.height,
                    maxFPS: maxFPS(format),
                    pixelFormat: fourCC(CMFormatDescriptionGetMediaSubType(format.formatDescription)),
                    fieldOfView: format.videoFieldOfView
                )
            }
        }
    }

    /// 요구 사양(1080p@240fps)을 만족하는 카메라·포맷. 없으면 nil.
    /// 특정 기종을 가정하지 않고 해상도·fps로만 고른다. 8비트 포맷을 우선한다(처리 부하가 낮음).
    static func requiredFormat() -> (device: AVCaptureDevice, format: AVCaptureDevice.Format)? {
        for camera in backCameras() {
            let candidates = camera.formats.filter { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return dims.width == Requirements.width
                    && dims.height == Requirements.height
                    && maxFPS(format) >= Requirements.fps
            }
            let eightBit = candidates.first { is8Bit($0) }
            if let format = eightBit ?? candidates.first {
                return (camera, format)
            }
        }
        return nil
    }

    private static func is8Bit(_ format: AVCaptureDevice.Format) -> Bool {
        let type = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        return type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }
}
