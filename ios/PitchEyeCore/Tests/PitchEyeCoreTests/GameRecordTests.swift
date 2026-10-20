import Foundation
import Testing
@testable import PitchEyeCore

func demoJudgement() -> Judgement { Judge(zone: zone).judge(estimate(x: 0, z: 0.75)) }

@Test func inningsSplitOnlyWhenNextInningIsPressed() {
    var game = GameRecord()
    for _ in 0..<3 { game.add(judgement: demoJudgement(), isDemo: true) }  // 1회: 1~3번
    game.nextInning()
    game.nextInning()  // 두 번 눌러도 빈 회가 생기지 않는다
    for _ in 0..<2 { game.add(judgement: demoJudgement(), isDemo: true) }  // 2회: 4~5번
    #expect(game.currentInning == 2)
    #expect(game.inning(of: 3) == 1 && game.inning(of: 4) == 2)
    #expect(game.order(inInning: 5) == 2)
    #expect(game.pitch(inning: 2, order: 1)?.number == 4)
    #expect(game.pitch(inning: 1, order: 3)?.number == 3)
    #expect(game.pitch(inning: 1, order: 4) == nil)  // 1회에는 3구뿐
    #expect(game.pitch(inning: 3, order: 1) == nil)
    #expect(game.pitches(inInning: 2).map(\.number) == [4, 5])
}

@Test func nextInningBeforeAnyPitchKeepsFirstInning() {
    var game = GameRecord()
    game.nextInning()
    #expect(game.currentInning == 1)
}

@Test func gameRecordSurvivesJSONRoundTrip() throws {
    var game = GameRecord()
    game.add(judgement: demoJudgement(), isDemo: true)
    game.nextInning()
    game.add(judgement: demoJudgement(), clipFile: "p2.mov", isDemo: true)
    let decoded = try JSONDecoder().decode(GameRecord.self, from: JSONEncoder().encode(game))
    #expect(decoded == game)
}

@Test func demoGeneratorProducesEveryKind() {
    var withoutAux = DemoPitchGenerator(zone: zone, hasAuxCamera: false, seed: 7)
    #expect(withoutAux.next(.clearStrike).judgement.verdict == .strike)
    #expect(withoutAux.next(.clearBall).judgement.verdict == .ball)
    let occluded = withoutAux.next(.occluded).judgement
    #expect(occluded.verdict == .hold && occluded.holdReason == .occlusion)

    // 경계 공: 보조 카메라가 있으면 보류가 줄어야 한다 (같은 씨앗으로 200구 비교)
    var main = DemoPitchGenerator(zone: zone, hasAuxCamera: false, seed: 3)
    var both = DemoPitchGenerator(zone: zone, hasAuxCamera: true, seed: 3)
    let holdsMain = (0..<200).filter { _ in main.next(.edge).judgement.verdict == .hold }.count
    let holdsBoth = (0..<200).filter { _ in both.next(.edge).judgement.verdict == .hold }.count
    #expect(holdsBoth < holdsMain)
}
