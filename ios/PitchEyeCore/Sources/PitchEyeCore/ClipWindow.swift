import Foundation

/// 계속 촬영하면서 짧은 조각 파일(세그먼트)을 이어 쓰고, 투구 시각 주변만 잘라 붙여 투구 영상을 만든다.
/// 여기는 "어느 조각의 어느 구간을 쓸지"와 "어떤 조각을 지워도 되는지"만 계산한다(영상 처리는 앱 쪽).
public struct Segment: Equatable, Sendable {
    public var file: String
    /// 촬영 시계 기준 시작·끝 (초)
    public var start: Double
    public var end: Double

    public init(file: String, start: Double, end: Double) {
        (self.file, self.start, self.end) = (file, start, end)
    }
}

public struct ClipPiece: Equatable, Sendable {
    public var file: String
    /// 조각 파일 안에서의 시작·끝 (초, 조각 시작 = 0)
    public var from: Double
    public var to: Double
}

public enum ClipWindow {
    /// 투구 시각 기준 앞뒤로 몇 초를 남길지. 투구 감지 시각은 공이 홈플레이트를 지나는 순간이라고 본다.
    public static let before = 1.5
    public static let after = 0.5

    /// [from, to] 구간을 덮는 조각들의 잘라 쓸 부분. 구간이 아직 다 촬영되지 않았거나 중간에 빠진 조각이 있으면 nil.
    public static func pieces(from: Double, to: Double, in segments: [Segment], tolerance: Double = 0.02) -> [ClipPiece]? {
        let sorted = segments.sorted { $0.start < $1.start }
        var cursor = from
        var result: [ClipPiece] = []
        for s in sorted where s.end > cursor && s.start < to {
            guard s.start <= cursor + tolerance else { return nil }  // 사이가 비었다
            let a = max(cursor, s.start)
            let b = min(to, s.end)
            result.append(ClipPiece(file: s.file, from: a - s.start, to: b - s.start))
            cursor = b
            if cursor >= to - tolerance { return result }
        }
        return nil
    }

    /// 지금 시각 기준으로 더 이상 필요 없는 조각들. keep초 이전에 끝난 조각은 지워도 된다.
    /// 아직 영상을 만들지 않은 투구가 있으면 그 투구가 쓸 조각은 남긴다.
    public static func expired(_ segments: [Segment], now: Double, keep: Double, pendingPitchTimes: [Double] = []) -> [Segment] {
        let earliestNeeded = (pendingPitchTimes.map { $0 - before } + [now - keep]).min()!
        return segments.filter { $0.end < earliestNeeded }
    }
}
