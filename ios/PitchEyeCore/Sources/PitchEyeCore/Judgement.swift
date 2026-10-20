import Foundation

public enum Verdict: String, Codable, Sendable { case strike = "STRIKE", ball = "BALL", hold = "HOLD" }

public enum HoldReason: String, Codable, Sendable {
    case occlusion          // 가려져서 공을 충분히 못 봄
    case tooFewDetections   // 검출된 프레임이 너무 적음
    case nearEdge           // 판단 루프를 돌아도 경계에서 결론이 안 남
    case calibration        // 카메라 보정이 안 됨
}

public enum EstimateSource: String, Codable, Sendable {
    case mainCamera    // 백네트 뒤 촬영 폰
    case auxCamera     // 1루·3루 쪽 보조 카메라
    case combined      // 판단 루프에서 합친 결과
}

/// 판정면마다 추정한 공 중심 위치와 그 불확실성 (표준편차, m).
public struct CrossingEstimate: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var y, x, z: Double
        public init(y: Double, x: Double, z: Double) { (self.y, self.x, self.z) = (y, x, z) }
    }

    public var points: [Point]
    public var sigmaX: Double
    public var sigmaZ: Double
    public var source: EstimateSource

    public init(points: [Point], sigmaX: Double, sigmaZ: Double, source: EstimateSource) {
        (self.points, self.sigmaX, self.sigmaZ, self.source) = (points, sigmaX, sigmaZ, source)
    }

    /// 일정 가속도 궤적 p(t) = p0 + v0·t + a·t²/2 를 각 판정면에서 자른 점들.
    public static func from(p0: [Double], v0: [Double], a: [Double], planes: [Double],
                            sigmaX: Double, sigmaZ: Double, source: EstimateSource) -> CrossingEstimate? {
        var points: [Point] = []
        for y in planes {
            // y(t) = y0 + vy·t + ay·t²/2 = 판정면 y. 공은 y가 줄어드는 방향(포수 쪽)으로 온다.
            let (qa, qb, qc) = (0.5 * a[1], v0[1], p0[1] - y)
            let t: Double
            if abs(qa) < 1e-12 {
                guard abs(qb) > 1e-12 else { return nil }
                t = -qc / qb
            } else {
                let disc = qb * qb - 4 * qa * qc
                guard disc >= 0 else { return nil }
                let roots = [(-qb - disc.squareRoot()) / (2 * qa), (-qb + disc.squareRoot()) / (2 * qa)].filter { $0 >= 0 }
                guard let first = roots.min() else { return nil }
                t = first
            }
            points.append(Point(y: y, x: p0[0] + v0[0] * t + 0.5 * a[0] * t * t, z: p0[2] + v0[2] * t + 0.5 * a[2] * t * t))
        }
        return CrossingEstimate(points: points, sigmaX: sigmaX, sigmaZ: sigmaZ, source: source)
    }
}

public struct Judgement: Codable, Equatable, Sendable {
    public var verdict: Verdict
    /// 판정이 맞을 확률 추정 (0.5~1). 보류면 경계 기준으로 계산한 값.
    public var confidence: Double
    /// 공 가장자리가 존 안쪽으로 들어간 깊이 (m). 음수면 존 밖.
    public var margin: Double?
    public var holdReason: HoldReason?
    /// 판정에 쓴 추정 (판단 루프를 돌았으면 합친 결과)
    public var estimate: CrossingEstimate?
    /// 판단 루프에서 추가로 본 추정 개수. 0이면 첫 추정만으로 결론.
    public var loopSteps: Int
    /// 판정에 실제로 쓴 추정의 출처들
    public var sources: [EstimateSource]
    public var zone: StrikeZone

    public var usedAuxCamera: Bool { sources.contains(.auxCamera) }
}

public struct Judge: Sendable {
    public var zone: StrikeZone
    /// 경계에서 이 배수(표준편차)만큼 떨어져야 결론을 낸다. 2면 한쪽으로 틀릴 확률이 약 2.3%.
    public var certainty: Double

    public init(zone: StrikeZone, certainty: Double = 2.0) {
        self.zone = zone
        self.certainty = certainty
    }

    /// 판정. primary가 없으면 이유와 함께 보류.
    /// 판단 루프: 첫 추정이 경계 근처라 결론이 안 나면, refinements(보조 카메라, 앞뒤 프레임 등)를 하나씩 합쳐 다시 본다.
    /// 모두 합쳐도 경계 근처면 보류.
    public func judge(_ primary: CrossingEstimate?, refinements: [CrossingEstimate] = [],
                      missingReason: HoldReason = .tooFewDetections) -> Judgement {
        guard let primary, !primary.points.isEmpty else {
            return Judgement(verdict: .hold, confidence: 0.5, margin: nil, holdReason: missingReason,
                             estimate: nil, loopSteps: 0, sources: [], zone: zone)
        }
        var current = primary
        var steps = 0
        var sources = [primary.source]
        var queue = refinements[...]
        while true {
            let (value, sigma) = evaluate(current)
            let confidence = normalCDF(abs(value) / max(sigma, 1e-9))
            if abs(value) >= certainty * sigma {
                return Judgement(verdict: value > 0 ? .strike : .ball, confidence: confidence, margin: value,
                                 holdReason: nil, estimate: current, loopSteps: steps, sources: sources, zone: zone)
            }
            guard let next = queue.popFirst() else {
                return Judgement(verdict: .hold, confidence: confidence, margin: value, holdReason: .nearEdge,
                                 estimate: current, loopSteps: steps, sources: sources, zone: zone)
            }
            current = combine(current, next)
            sources.append(next.source)
            steps += 1
        }
    }

    /// 모든 판정면 중 가장 깊이 들어간 곳의 깊이와, 그 경계 방향의 표준편차.
    func evaluate(_ e: CrossingEstimate) -> (margin: Double, sigma: Double) {
        let sections = zone.sections
        var best = (margin: -Double.infinity, sigma: max(e.sigmaX, e.sigmaZ))
        for point in e.points {
            guard let section = sections.min(by: { abs($0.y - point.y) < abs($1.y - point.y) }),
                  abs(section.y - point.y) < 1e-6 else { continue }
            let m = margin(x: point.x, z: point.z, in: section)
            if m.value > best.margin { best = (m.value, m.axis == .x ? e.sigmaX : e.sigmaZ) }
        }
        return best
    }
}

/// 두 추정을 오차의 역분산으로 가중 평균한다. 같은 판정면끼리만 합친다.
func combine(_ a: CrossingEstimate, _ b: CrossingEstimate) -> CrossingEstimate {
    func merge(_ u: Double, _ su: Double, _ v: Double, _ sv: Double) -> (Double, Double) {
        let (wu, wv) = (1 / (su * su), 1 / (sv * sv))
        return ((u * wu + v * wv) / (wu + wv), (1 / (wu + wv)).squareRoot())
    }
    var points: [CrossingEstimate.Point] = []
    for p in a.points {
        guard let q = b.points.first(where: { abs($0.y - p.y) < 1e-6 }) else { points.append(p); continue }
        points.append(.init(y: p.y, x: merge(p.x, a.sigmaX, q.x, b.sigmaX).0, z: merge(p.z, a.sigmaZ, q.z, b.sigmaZ).0))
    }
    return CrossingEstimate(points: points, sigmaX: merge(0, a.sigmaX, 0, b.sigmaX).1,
                            sigmaZ: merge(0, a.sigmaZ, 0, b.sigmaZ).1, source: .combined)
}

func normalCDF(_ x: Double) -> Double { 0.5 * (1 + erf(x / 2.0.squareRoot())) }
