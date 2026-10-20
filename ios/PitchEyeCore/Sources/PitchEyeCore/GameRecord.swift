import Foundation

/// 투구 하나의 기록.
public struct PitchRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// 경기 전체에서 몇 번째 투구인지 (1부터)
    public var number: Int
    public var time: Date
    public var judgement: Judgement
    /// 촬영 폰에 저장된 짧은 영상 파일 이름. 아직 없으면 nil.
    public var clipFile: String?
    /// 데모 데이터면 true. 화면에 반드시 표시한다.
    public var isDemo: Bool

    public init(id: UUID = UUID(), number: Int, time: Date, judgement: Judgement, clipFile: String? = nil, isDemo: Bool) {
        (self.id, self.number, self.time, self.judgement, self.clipFile, self.isDemo) = (id, number, time, judgement, clipFile, isDemo)
    }
}

/// 경기 기록. 회는 "다음 이닝"을 누른 시점으로만 나눈다(타자 단위는 나누지 않는다).
public struct GameRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public private(set) var pitches: [PitchRecord] = []
    /// 각 회의 첫 투구 번호. 1회는 항상 1번 투구부터.
    public private(set) var inningStarts: [Int] = [1]

    public init(id: UUID = UUID(), startedAt: Date = Date()) {
        (self.id, self.startedAt) = (id, startedAt)
    }

    public var currentInning: Int { inningStarts.count }

    @discardableResult
    public mutating func add(judgement: Judgement, time: Date = Date(), clipFile: String? = nil, isDemo: Bool) -> PitchRecord {
        let record = PitchRecord(number: pitches.count + 1, time: time, judgement: judgement, clipFile: clipFile, isDemo: isDemo)
        pitches.append(record)
        return record
    }

    /// 다음 투구부터 다음 회로 친다. 직전에 이미 눌렀으면(그 회에 투구가 없으면) 무시한다.
    public mutating func nextInning() {
        let next = pitches.count + 1
        if inningStarts.last != next { inningStarts.append(next) }
    }

    /// 투구 번호가 몇 회인지 (1부터)
    public func inning(of number: Int) -> Int {
        inningStarts.lastIndex(where: { $0 <= number }).map { $0 + 1 } ?? 1
    }

    /// 그 회에서 몇 번째 투구인지 (1부터)
    public func order(inInning number: Int) -> Int {
        number - inningStarts[inning(of: number) - 1] + 1
    }

    /// "3회 2번째 투구" 찾기. 없으면 nil.
    public func pitch(inning: Int, order: Int) -> PitchRecord? {
        guard inning >= 1, inning <= inningStarts.count, order >= 1 else { return nil }
        let number = inningStarts[inning - 1] + order - 1
        let end = inning < inningStarts.count ? inningStarts[inning] : pitches.count + 1
        guard number < end, number <= pitches.count else { return nil }
        return pitches[number - 1]
    }

    public func pitches(inInning inning: Int) -> [PitchRecord] {
        pitches.filter { self.inning(of: $0.number) == inning }
    }
}
