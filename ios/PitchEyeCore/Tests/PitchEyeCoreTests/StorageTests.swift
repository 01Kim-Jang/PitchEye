import Foundation
import Testing
@testable import PitchEyeCore

func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("pitcheye-test-\(UUID().uuidString)")
}

@Test func storeSavesAndLoadsGames() throws {
    let store = GameStore(root: tempRoot())
    defer { try? FileManager.default.removeItem(at: store.root) }
    var older = GameRecord(startedAt: Date(timeIntervalSince1970: 1_000))
    older.add(judgement: demoJudgement(), time: Date(timeIntervalSince1970: 1_010), isDemo: true)
    var newer = GameRecord(startedAt: Date(timeIntervalSince1970: 2_000))
    newer.add(judgement: demoJudgement(), time: Date(timeIntervalSince1970: 2_010),
              clipFile: GameStore.clipName(for: 1), isDemo: true)
    newer.nextInning()
    try store.save(older)
    try store.save(newer)

    #expect(try store.load(newer.id) == newer)
    #expect(store.games().map(\.id) == [newer.id, older.id])
    #expect(FileManager.default.fileExists(atPath: store.clipsFolder(for: newer.id).path))
    #expect(store.clipURL(game: newer.id, pitch: 12).lastPathComponent == "pitch-0012.mov")

    try store.delete(older.id)
    #expect(store.games().map(\.id) == [newer.id])
}

@Test func storeSkipsBrokenFolders() throws {
    let store = GameStore(root: tempRoot())
    defer { try? FileManager.default.removeItem(at: store.root) }
    try FileManager.default.createDirectory(at: store.folder(for: UUID()), withIntermediateDirectories: true)  // game.json 없음
    try store.save(GameRecord())
    #expect(store.games().count == 1)
}

let segments = [Segment(file: "a", start: 10, end: 11), Segment(file: "b", start: 11, end: 12), Segment(file: "c", start: 12, end: 13)]

@Test func clipSpanningTwoSegments() {
    let pieces = ClipWindow.pieces(from: 10.5, to: 12.5, in: segments)
    #expect(pieces == [ClipPiece(file: "a", from: 0.5, to: 1.0), ClipPiece(file: "b", from: 0, to: 1.0),
                       ClipPiece(file: "c", from: 0, to: 0.5)])
}

@Test func clipNotYetRecordedOrWithGapIsNil() {
    #expect(ClipWindow.pieces(from: 12.5, to: 13.5, in: segments) == nil)  // 13.5초는 아직 안 찍힘
    let gap = [segments[0], segments[2]]
    #expect(ClipWindow.pieces(from: 10.5, to: 12.5, in: gap) == nil)
}

@Test func tinyGapBetweenSegmentsIsTolerated() {
    // 조각을 바꿀 때 한 프레임(약 4ms) 정도 비는 것은 허용
    let s = [Segment(file: "a", start: 0, end: 1.0), Segment(file: "b", start: 1.004, end: 2.0)]
    #expect(ClipWindow.pieces(from: 0.5, to: 1.5, in: s)?.count == 2)
}

@Test func expiredKeepsSegmentsForPendingPitches() {
    // 지금 13초, 4초만 남김 → 9초 이전에 끝난 것만 삭제 대상. 여기서는 없음.
    #expect(ClipWindow.expired(segments, now: 13, keep: 4).isEmpty)
    // 지금 20초 → 전부 오래됨. 단 10.8초 투구의 영상을 아직 못 만들었으면 9.3초 이후 조각은 남긴다.
    #expect(ClipWindow.expired(segments, now: 20, keep: 4).map(\.file) == ["a", "b", "c"])
    #expect(ClipWindow.expired(segments, now: 20, keep: 4, pendingPitchTimes: [10.8]).isEmpty)
}
