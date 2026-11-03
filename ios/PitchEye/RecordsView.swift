import AVKit
import PitchEyeCore
import SwiftUI

/// 지난 경기 목록.
struct GamesListView: View {
    private let store = GameStore(root: GameSession.storeRoot)
    @State private var games: [GameRecord] = []
    @State private var pendingDelete: GameRecord?

    var body: some View {
        Group {
            if games.isEmpty {
                VStack(spacing: 8) {
                    Text("저장된 경기가 없습니다").font(.headline).foregroundStyle(Theme.text)
                    Text("경기 시작에서 투구를 기록하면 여기에 쌓입니다.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(games) { game in
                        NavigationLink(value: Route.record(game.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(game.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.text)
                                Text("\(game.currentInning)회 · \(game.pitches.count)구 · " + VerdictCounts(game.pitches).text)
                                    .font(.footnote)
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Theme.background)
                        .swipeActions {
                            Button("삭제", role: .destructive) { pendingDelete = game }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Theme.background)
        .navigationTitle("경기 기록")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { games = store.games() }
        .confirmationDialog("이 경기 기록을 삭제할까요?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                if let game = pendingDelete { try? store.delete(game.id) }
                games = store.games()
            }
        } message: {
            Text("판정 기록과 투구 영상이 모두 지워지고 되돌릴 수 없습니다.")
        }
    }
}

/// 저장된 경기 하나를 불러와 보여 준다.
struct StoredGameView: View {
    let id: UUID
    private let store = GameStore(root: GameSession.storeRoot)

    var body: some View {
        if let game = try? store.load(id) {
            GameRecordView(game: game, store: store)
        } else {
            Text("경기 기록을 읽지 못했습니다").foregroundStyle(Theme.secondaryText)
        }
    }
}

struct VerdictCounts {
    var strikes = 0, balls = 0, holds = 0

    init(_ pitches: [PitchRecord]) {
        for p in pitches {
            switch p.judgement.verdict {
            case .strike: strikes += 1
            case .ball: balls += 1
            case .hold: holds += 1
            }
        }
    }

    var text: String { "스트라이크 \(strikes) · 볼 \(balls) · 보류 \(holds)" }
}

/// 경기 하나의 투구 기록. 회별 목록, 판정별 필터, "N회 M번째 투구" 찾기.
struct GameRecordView: View {
    let game: GameRecord
    let store: GameStore

    enum Filter: String, CaseIterable { case all = "전체", strike = "스트라이크", ball = "볼", hold = "보류" }
    @State private var filter = Filter.all
    @State private var findInning = 1
    @State private var findOrder = 1
    @State private var found: PitchRoute?
    @State private var findMessage = ""

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(game.currentInning)회 · \(game.pitches.count)구 · " + VerdictCounts(game.pitches).text)
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(Theme.secondaryText)
                    finder
                    Picker("판정", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Theme.background)
                .listRowSeparator(.hidden)
            }
            ForEach((1...max(game.currentInning, 1)).reversed(), id: \.self) { inning in
                let pitches = game.pitches(inInning: inning).filter(matches).reversed()
                if !pitches.isEmpty {
                    Section("\(inning)회") {
                        ForEach(Array(pitches)) { pitch in
                            NavigationLink(value: PitchRoute(game: game.id, number: pitch.number)) {
                                PitchRow(pitch: pitch, game: game)
                            }
                            .listRowBackground(Theme.background)
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle(game.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: PitchRoute.self) { route in
            PitchDetailView(game: game, store: store, number: route.number)
        }
        .navigationDestination(item: $found) { route in
            PitchDetailView(game: game, store: store, number: route.number)
        }
    }

    private var finder: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("회", selection: $findInning) {
                    ForEach(1...max(game.currentInning, 1), id: \.self) { Text("\($0)회") }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(Theme.text)
                Spacer(minLength: 0)
                Stepper("\(findOrder)번째 투구", value: $findOrder, in: 1...200)
                    .monospacedDigit()
            }
            Button {
                if let pitch = game.pitch(inning: findInning, order: findOrder) {
                    findMessage = ""
                    found = PitchRoute(game: game.id, number: pitch.number)
                } else {
                    let count = game.pitches(inInning: findInning).count
                    findMessage = "\(findInning)회에는 투구가 \(count)개뿐입니다"
                }
            } label: {
                Label("찾기", systemImage: "magnifyingglass")
            }
            .buttonStyle(SecondaryButtonStyle())
            if !findMessage.isEmpty {
                Text(findMessage).font(.footnote).foregroundStyle(Status.warning.foreground)
            }
        }
        .foregroundStyle(Theme.text)
    }

    private func matches(_ pitch: PitchRecord) -> Bool {
        switch filter {
        case .all: true
        case .strike: pitch.judgement.verdict == .strike
        case .ball: pitch.judgement.verdict == .ball
        case .hold: pitch.judgement.verdict == .hold
        }
    }
}

struct PitchRoute: Hashable, Identifiable {
    let game: UUID
    let number: Int
    var id: Int { number }
}

struct PitchRow: View {
    let pitch: PitchRecord
    let game: GameRecord

    var body: some View {
        HStack(spacing: 12) {
            Text("\(game.order(inInning: pitch.number))")
                .font(.headline)
                .monospacedDigit()
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(pitch.judgement.verdict.label)
                    .font(.body.weight(.bold))
                    .foregroundStyle(pitch.judgement.verdict == .hold ? Status.warning.foreground : Theme.text)
                Text("\(pitch.number)번 투구 · " + pitch.time.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            if pitch.clipFile != nil {
                Image(systemName: "film").foregroundStyle(Theme.secondaryText).accessibilityLabel("영상 있음")
            }
            if pitch.isDemo {
                Text("데모").font(.caption2.weight(.bold)).foregroundStyle(Status.warning.foreground)
            }
        }
        .foregroundStyle(Theme.text)
    }
}

extension Verdict {
    var label: String {
        switch self {
        case .strike: "STRIKE"
        case .ball: "BALL"
        case .hold: "판정 보류"
        }
    }
}

/// 투구 상세: 판정 카드와 투구 영상 다시 보기. 앞뒤 투구로 넘길 수 있다.
struct PitchDetailView: View {
    let game: GameRecord
    let store: GameStore
    @State var number: Int

    var body: some View {
        let pitch = game.pitches[number - 1]
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ClipPlayer(url: clipURL(pitch))
                PitchCard(pitch: pitch, game: game)
                HStack(spacing: 12) {
                    Button { number -= 1 } label: { Label("이전 투구", systemImage: "chevron.left") }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(number <= 1)
                    Button { number += 1 } label: { Label("다음 투구", systemImage: "chevron.right") }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(number >= game.pitches.count)
                }
            }
            .padding(16)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("\(game.inning(of: number))회 \(game.order(inInning: number))번째 투구")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func clipURL(_ pitch: PitchRecord) -> URL? {
        guard pitch.clipFile != nil else { return nil }
        let url = store.clipURL(game: game.id, pitch: pitch.number)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// 240fps 투구 영상을 느리게 반복 재생한다. 1/8배속이면 초당 30장으로 보인다.
struct ClipPlayer: View {
    let url: URL?
    @State private var player = AVPlayer()
    @State private var speed: Float = 0.125
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        VStack(spacing: 8) {
            if let url {
                VideoPlayer(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .onAppear { load(url) }
                    .onChange(of: url) { _, new in load(new) }
                    .onDisappear { player.pause() }
                Picker("재생 속도", selection: $speed) {
                    Text("1/8배").tag(Float(0.125))
                    Text("1/4배").tag(Float(0.25))
                    Text("실제 속도").tag(Float(1))
                }
                .pickerStyle(.segmented)
                .onChange(of: speed) { _, new in player.rate = new }
            } else {
                Text("이 투구는 영상이 없습니다 (시뮬레이터에서 기록했거나 저장에 실패함)")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 80)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
            }
        }
    }

    private func load(_ url: URL) {
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            player.seek(to: .zero)
            player.rate = speed
        }
        player.rate = speed
    }
}

/// 경기 중 촬영 폰에서 지금 경기의 기록을 본다. 새 투구가 들어오면 바로 반영된다.
struct LiveRecordSheet: View {
    @ObservedObject var session: GameSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            GameRecordView(game: session.game, store: session.store)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { Button("닫기") { dismiss() } }
                }
        }
    }
}
