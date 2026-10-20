import Foundation

// 좌표계는 docs/interface-spec.md와 같다 (단위 m).
// 원점: 홈플레이트 앞면(투수 쪽) 중앙의 지면 / x: 포수 시점 오른쪽 / y: 투수 방향 / z: 위
// 홈플레이트는 y = 0(앞면)에서 y = -plateDepth(뒤 꼭짓점)까지 있다.

public enum Plate {
    /// 앞면 폭 17인치
    public static let width = 0.4318
    /// 앞면에서 옆면이 끝나는 곳까지 8.5인치
    public static let sideLength = 0.2159
    /// 앞면에서 뒤 꼭짓점까지. 옆면 8.5인치 + 뒤쪽 삼각형 높이(빗변 12인치, 밑변 반 8.5인치)
    public static let depth = 0.2159 + (0.3048 * 0.3048 - 0.2159 * 0.2159).squareRoot()

    /// 앞면에서 y만큼(음수) 들어간 곳의 홈플레이트 절반 폭. 홈플레이트 밖이면 nil.
    public static func halfWidth(atY y: Double) -> Double? {
        guard y <= 1e-9, y >= -depth - 1e-9 else { return nil }
        if y >= -sideLength { return width / 2 }
        let intoTriangle = -sideLength - y
        let triangleDepth = depth - sideLength
        return max(0, width / 2 * (1 - intoTriangle / triangleDepth))
    }
}

public let ballRadius = 0.0366  // m. 규격 둘레 22.9~23.5cm의 중간값으로 계산한 지름 7.32cm의 절반

/// 스트라이크존 규칙. 값은 리그마다 다를 수 있어 묶어서 바꿀 수 있게 둔다.
public struct ZoneRule: Codable, Equatable, Sendable {
    public var name: String
    /// 지면에서 존 상단까지 높이 = 타자 신장 × topRatio
    public var topRatio: Double
    public var bottomRatio: Double
    /// 홈플레이트 폭에서 좌우로 더 넓히는 양 (m)
    public var sideMargin: Double
    /// 판정하는 평면들의 y (m). 이 중 한 곳에서라도 공이 존에 닿으면 스트라이크.
    public var planes: [Double]

    public init(name: String, topRatio: Double, bottomRatio: Double, sideMargin: Double, planes: [Double]) {
        (self.name, self.topRatio, self.bottomRatio, self.sideMargin, self.planes) = (name, topRatio, bottomRatio, sideMargin, planes)
    }

    /// KBO 2025시즌 이후 ABS. 상단 55.75%, 하단 27.04% (2024년 12월 실행위원회 발표 보도 기준),
    /// 판정면은 홈플레이트 중간면과 끝면, 좌우 2cm 확대. 2026시즌 값과 면의 정확한 정의는 공식 문서로 확인 필요 [__].
    public static let kbo = ZoneRule(name: "KBO ABS", topRatio: 0.5575, bottomRatio: 0.2704, sideMargin: 0.02,
                                     planes: [-Plate.depth / 2, -Plate.depth])

    /// 규칙서식: 홈플레이트 위 공간 전체. 앞면부터 뒤 꼭짓점까지 여러 면에서 본다. 높이 비율은 KBO 값을 빌려 쓴다.
    public static let rulebook = ZoneRule(name: "규칙서 (홈플레이트 전체)", topRatio: 0.5575, bottomRatio: 0.2704, sideMargin: 0,
                                          planes: stride(from: 0.0, through: 8.0, by: 1.0).map { -Plate.depth * $0 / 8 })
}

/// 한 판정면에서의 존 단면 (x 범위, z 범위).
public struct ZoneSection: Equatable, Sendable {
    public var y: Double
    public var xMin: Double, xMax: Double, zMin: Double, zMax: Double
}

public struct StrikeZone: Codable, Equatable, Sendable {
    public var rule: ZoneRule
    public var batterHeight: Double  // m

    public init(rule: ZoneRule = .kbo, batterHeight: Double) {
        self.rule = rule
        self.batterHeight = batterHeight
    }

    public var bottom: Double { batterHeight * rule.bottomRatio }
    public var top: Double { batterHeight * rule.topRatio }

    public var sections: [ZoneSection] {
        rule.planes.compactMap { y in
            guard let half = Plate.halfWidth(atY: y), half + rule.sideMargin > 0 else { return nil }
            let w = half + rule.sideMargin
            return ZoneSection(y: y, xMin: -w, xMax: w, zMin: bottom, zMax: top)
        }
    }
}

/// 공 가장자리가 존 단면에서 얼마나 안쪽인지 (m). 양수면 공 일부라도 존에 닿음 = 스트라이크.
/// axis는 가장 가까운 경계가 좌우(x)인지 상하(z)인지. 측정 오차를 어느 축으로 볼지 정할 때 쓴다.
public func margin(x: Double, z: Double, in s: ZoneSection, radius: Double = ballRadius) -> (value: Double, axis: Axis) {
    let dx = max(s.xMin - x, 0, x - s.xMax)  // 단면 밖으로 벗어난 거리
    let dz = max(s.zMin - z, 0, z - s.zMax)
    if dx == 0 && dz == 0 {
        let toSide = min(x - s.xMin, s.xMax - x)
        let toTopBottom = min(z - s.zMin, s.zMax - z)
        return toSide < toTopBottom ? (radius + toSide, .x) : (radius + toTopBottom, .z)
    }
    return (radius - (dx * dx + dz * dz).squareRoot(), dx >= dz ? .x : .z)
}

public enum Axis: String, Codable, Sendable { case x, z }
