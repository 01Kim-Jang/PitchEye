import Foundation

/// 화면 시연용 가짜 투구. 공 검출과 투구 감지가 완성되기 전까지 판정 흐름을 보여 주는 데만 쓴다.
/// 수치(오차 크기 등)는 실측이 아닌 가정이다.
public struct DemoPitchGenerator: Sendable {
    public enum Kind: CaseIterable, Sendable {
        case clearStrike, clearBall, edge, occluded
    }

    public var zone: StrikeZone
    /// 카메라 1대 추정의 표준편차 (m). 카메라 1대 복원 합성 실험의 상하 오차 규모를 참고한 가정값.
    public var mainSigma = (x: 0.01, z: 0.03)
    /// 보조 카메라 추정의 표준편차 (m). 옆에서 보면 높이를 더 잘 본다는 가정.
    public var auxSigma = (x: 0.02, z: 0.01)
    public var hasAuxCamera: Bool
    private var state: UInt64

    public init(zone: StrikeZone, hasAuxCamera: Bool, seed: UInt64 = 1) {
        self.zone = zone
        self.hasAuxCamera = hasAuxCamera
        self.state = seed &* 6364136223846793005 &+ 1442695040888963407
    }

    private mutating func uniform(_ range: ClosedRange<Double>) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Double(state >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    private mutating func gaussian() -> Double {
        let (u1, u2) = (max(uniform(0...1), 1e-12), uniform(0...1))
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }

    /// 실제 통과 지점을 정하고, 거기에 측정 오차를 더한 추정을 만든다.
    public mutating func next(_ kind: Kind? = nil) -> (judgement: Judgement, truth: CrossingEstimate.Point) {
        let kind = kind ?? Kind.allCases[Int(uniform(0...3.999))]
        let w = Plate.width / 2 + zone.rule.sideMargin + ballRadius
        let (lo, hi) = (zone.bottom - ballRadius, zone.top + ballRadius)
        let (x, z): (Double, Double)
        switch kind {
        case .clearStrike, .occluded:
            (x, z) = (uniform(-w * 0.6...w * 0.6), uniform(lo + (hi - lo) * 0.25...lo + (hi - lo) * 0.75))
        case .clearBall:
            (x, z) = uniform(0...1) < 0.5 ? ((uniform(0...1) < 0.5 ? -1 : 1) * uniform(w + 0.12...w + 0.3), uniform(lo...hi))
                                         : (uniform(-w...w), uniform(0...1) < 0.5 ? lo - uniform(0.12...0.3) : hi + uniform(0.12...0.3))
        case .edge:
            (x, z) = uniform(0...1) < 0.5 ? ((uniform(0...1) < 0.5 ? -1 : 1) * (w + uniform(-0.03...0.03)), uniform(lo...hi))
                                         : (uniform(-w...w), (uniform(0...1) < 0.5 ? lo : hi) + uniform(-0.03...0.03))
        }
        // 공은 판정면 근처에서 거의 일직선으로 지난다고 보고, 모든 판정면에 같은 x, z를 둔다.
        let truth = CrossingEstimate.Point(y: zone.rule.planes.first ?? 0, x: x, z: z)
        func measured(_ s: (x: Double, z: Double), _ source: EstimateSource) -> CrossingEstimate {
            let (ex, ez) = (gaussian() * s.x, gaussian() * s.z)
            return CrossingEstimate(points: zone.rule.planes.map { .init(y: $0, x: x + ex, z: z + ez) },
                                    sigmaX: s.x, sigmaZ: s.z, source: source)
        }
        let judge = Judge(zone: zone)
        if kind == .occluded {
            return (judge.judge(nil, missingReason: .occlusion), truth)
        }
        let aux = hasAuxCamera ? [measured(auxSigma, .auxCamera)] : []
        return (judge.judge(measured(mainSigma, .mainCamera), refinements: aux), truth)
    }
}
