import Foundation
import PitchEyeCore

/// 경기 하나. 투구가 들어오면 판정을 기록하고, 영상 조각이 다 모이면 투구 영상을 만들어 붙인다.
@MainActor
final class GameSession: ObservableObject {
    @Published private(set) var game = GameRecord()
    @Published private(set) var lastPitch: PitchRecord?
    @Published private(set) var clipStatus = ""

    let recorder: SegmentRecorder
    let store: GameStore
    private var demo: DemoPitchGenerator

    static var storeRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("games")
    }

    init(batterHeight: Double) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        recorder = SegmentRecorder(folder: caches.appendingPathComponent("segments"))
        store = GameStore(root: Self.storeRoot)
        // ponytail: 공 검출과 투구 감지가 생기기 전까지 판정은 데모 생성기에서 온다. 보조 카메라는 아직 없다.
        demo = DemoPitchGenerator(zone: StrikeZone(rule: .kbo, batterHeight: batterHeight), hasAuxCamera: false,
                                  seed: UInt64(Date().timeIntervalSince1970))
    }

    var currentInning: Int { game.currentInning }
    var pitchesThisInning: Int { game.pitches(inInning: game.currentInning).count }

    /// 데모 투구. 버튼을 누른 순간을 공이 홈플레이트를 지난 시각으로 본다.
    func demoPitch() {
        let judgement = demo.next().judgement
        let record = game.add(judgement: judgement, isDemo: true)
        lastPitch = record
        save()
        guard let time = recorder.latestTime else {
            clipStatus = "카메라 프레임이 없어 영상은 저장하지 않았습니다"
            return
        }
        recorder.hold(time)
        clipStatus = "\(record.number)번 투구 영상 저장 중"
        Task { await makeClip(number: record.number, at: time) }
    }

    func nextInning() {
        game.nextInning()
        save()
    }

    private func makeClip(number: Int, at time: Double) async {
        defer { recorder.release(time) }
        // 투구 뒤 0.5초까지 찍히고 그 조각이 닫힐 때까지 기다린다(조각이 1초라 보통 2초 안).
        for _ in 0..<20 {
            if let pieces = ClipWindow.pieces(from: time - ClipWindow.before, to: time + ClipWindow.after,
                                              in: recorder.segments()) {
                let name = GameStore.clipName(for: number)
                do {
                    try await ClipExporter.export(pieces, from: recorder.folder, to: store.clipURL(game: game.id, pitch: number))
                    game.setClip(name, for: number)
                    if lastPitch?.number == number { lastPitch = game.pitches[number - 1] }
                    save()
                    clipStatus = "\(number)번 투구 영상 저장됨"
                } catch {
                    clipStatus = "\(number)번 투구 영상 저장 실패: \(error.localizedDescription)"
                }
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        clipStatus = "\(number)번 투구 영상을 만들지 못했습니다 (영상 조각 부족)"
    }

    private func save() {
        guard !game.pitches.isEmpty else { return }  // 투구 없이 끝난 경기는 남기지 않는다
        do { try store.save(game) } catch { clipStatus = "경기 기록 저장 실패: \(error.localizedDescription)" }
    }
}
