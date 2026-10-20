import Foundation
import Testing
@testable import PitchEyeCore

// 180cm 타자, KBO 규칙: 존 높이 0.4867~1.0035m, 판정면은 홈플레이트 중간면과 끝면.
let zone = StrikeZone(rule: .kbo, batterHeight: 1.80)

func estimate(x: Double, z: Double, sigma: Double = 0.01, source: EstimateSource = .mainCamera,
              in zone: StrikeZone = zone) -> CrossingEstimate {
    CrossingEstimate(points: zone.rule.planes.map { .init(y: $0, x: x, z: z) }, sigmaX: sigma, sigmaZ: sigma, source: source)
}

@Test func plateGeometry() {
    #expect(abs(Plate.depth - 0.4318) < 0.001)  // 17인치 정사각형을 잘라 만든 오각형이라 깊이도 약 17인치
    #expect(Plate.halfWidth(atY: 0) == Plate.width / 2)
    #expect(Plate.halfWidth(atY: -Plate.sideLength) == Plate.width / 2)
    #expect(abs(Plate.halfWidth(atY: -Plate.depth)!) < 1e-9)
    #expect(Plate.halfWidth(atY: 0.1) == nil)
}

@Test func zoneHeightFollowsBatterHeight() {
    #expect(abs(zone.top - 1.0035) < 1e-4)
    #expect(abs(zone.bottom - 0.48672) < 1e-4)
    // 끝면(뒤 꼭짓점)은 폭이 0이라 좌우 확대분(2cm)만 남는다
    #expect(zone.sections.count == 2)
}

@Test func ballThatTouchesTheEdgeIsAStrike() {
    // 공 중심이 존 오른쪽 경계 바깥 3cm여도, 공 반지름(3.66cm) 때문에 공 가장자리가 닿는다 → 스트라이크
    let middle = zone.sections[0]
    let m = margin(x: middle.xMax + 0.03, z: 0.75, in: middle)
    #expect(m.value > 0 && m.axis == .x)
    // 4cm 바깥이면 닿지 않는다 → 볼
    #expect(margin(x: middle.xMax + 0.04, z: 0.75, in: middle).value < 0)
}

@Test func clearCasesNeedNoLoop() {
    let judge = Judge(zone: zone)
    let strike = judge.judge(estimate(x: 0, z: 0.75))
    #expect(strike.verdict == .strike && strike.loopSteps == 0 && strike.confidence > 0.99)
    let ball = judge.judge(estimate(x: 0.5, z: 0.75))
    #expect(ball.verdict == .ball && ball.loopSteps == 0)
}

@Test func nearEdgeWithoutMoreEvidenceIsHeld() {
    let judge = Judge(zone: zone)
    let edgeX = zone.sections[0].xMax + ballRadius  // 공 가장자리가 경계에 딱 닿는 위치
    let result = judge.judge(estimate(x: edgeX + 0.005, z: 0.75, sigma: 0.02))
    #expect(result.verdict == .hold && result.holdReason == .nearEdge)
}

@Test func auxCameraResolvesTheLoop() {
    let judge = Judge(zone: zone)
    let edgeX = zone.sections[0].xMax + ballRadius
    // 메인 카메라는 경계 근처(애매), 보조 카메라가 더 정확히 경계 안쪽 1.5cm를 본 경우
    let main = estimate(x: edgeX + 0.005, z: 0.75, sigma: 0.02)
    let aux = estimate(x: edgeX - 0.015, z: 0.75, sigma: 0.004, source: .auxCamera)
    let result = judge.judge(main, refinements: [aux])
    #expect(result.verdict == .strike)
    #expect(result.loopSteps == 1 && result.usedAuxCamera && result.estimate?.source == .combined)
}

@Test func missingEstimateIsHeldWithReason() {
    let result = Judge(zone: zone).judge(nil, missingReason: .occlusion)
    #expect(result.verdict == .hold && result.holdReason == .occlusion && result.margin == nil)
}

@Test func strikeAtEitherPlaneCounts() {
    // 중간면에서는 낮아서 존 밖, 끝면에서는 존 안 → 스트라이크 (한 면이라도 닿으면)
    let planes = zone.rule.planes
    let e = CrossingEstimate(points: [.init(y: planes[0], x: 0, z: zone.bottom - 0.1),
                                      .init(y: planes[1], x: 0, z: zone.bottom + 0.05)],
                             sigmaX: 0.005, sigmaZ: 0.005, source: .mainCamera)
    #expect(Judge(zone: zone).judge(e).verdict == .strike)
}

@Test func crossingFromTrajectory() {
    // 등속 직선: x = 0.1, z = 1.0 - 0.05t, y = 16 - 30t
    let e = CrossingEstimate.from(p0: [0.1, 16, 1.0], v0: [0, -30, -0.05], a: [0, 0, 0],
                                  planes: [0, -0.3], sigmaX: 0.01, sigmaZ: 0.01, source: .mainCamera)!
    #expect(abs(e.points[0].z - (1.0 - 0.05 * 16 / 30)) < 1e-9)
    #expect(abs(e.points[1].z - (1.0 - 0.05 * 16.3 / 30)) < 1e-9)
    #expect(e.points.allSatisfy { abs($0.x - 0.1) < 1e-12 })
}

@Test func judgementSurvivesJSONRoundTrip() throws {
    let j = Judge(zone: zone).judge(estimate(x: 0, z: 0.75))
    let decoded = try JSONDecoder().decode(Judgement.self, from: JSONEncoder().encode(j))
    #expect(decoded == j)
}
