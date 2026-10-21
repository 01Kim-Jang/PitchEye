import Foundation

/// 경기 기록을 폰에 저장한다.
///
///     <root>/<경기 id>/game.json          경기 기록 (투구별 판정 포함)
///     <root>/<경기 id>/clips/pitch-0001.mov  투구별 짧은 영상
///
/// 투구 하나가 끝날 때마다 game.json을 통째로 다시 쓴다(임시 파일에 쓰고 바꿔치기).
/// 경기 중 앱이 꺼져도 직전 투구까지는 남는다.
public struct GameStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func folder(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public func clipsFolder(for id: UUID) -> URL { folder(for: id).appendingPathComponent("clips", isDirectory: true) }

    public static func clipName(for number: Int) -> String { String(format: "pitch-%04d.mov", number) }

    public func clipURL(game id: UUID, pitch number: Int) -> URL {
        clipsFolder(for: id).appendingPathComponent(Self.clipName(for: number))
    }

    public func save(_ game: GameRecord) throws {
        try FileManager.default.createDirectory(at: clipsFolder(for: game.id), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(game).write(to: folder(for: game.id).appendingPathComponent("game.json"), options: .atomic)
    }

    public func load(_ id: UUID) throws -> GameRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GameRecord.self, from: Data(contentsOf: folder(for: id).appendingPathComponent("game.json")))
    }

    /// 저장된 경기들. 최근 경기가 먼저. 읽지 못하는 폴더는 건너뛴다.
    public func games() -> [GameRecord] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { UUID(uuidString: $0.lastPathComponent).flatMap { try? load($0) } }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func delete(_ id: UUID) throws {
        try FileManager.default.removeItem(at: folder(for: id))
    }
}
