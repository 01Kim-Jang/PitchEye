import PitchEyeCore
import SwiftUI

/// 경기 모드 촬영 화면. 경기 내내 촬영하고, 투구마다 판정과 투구 영상을 기록한다.
/// 공 검출과 투구 감지가 완성되기 전까지는 "데모 투구" 버튼이 투구를 대신한다.
struct GameView: View {
    let onDone: () -> Void
    @StateObject private var capture = CaptureController()
    @StateObject private var session: GameSession
    @State private var confirmEnd = false
    @State private var showRecords = false

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
        let height = UserDefaults.standard.object(forKey: "batterHeightCm") as? Int ?? 175
        _session = StateObject(wrappedValue: GameSession(batterHeight: Double(height) / 100))
    }

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            let layout = wide ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 16))
            layout {
                CameraPreview(session: capture.session)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(Theme.text)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                    .overlay(alignment: .topLeading) { recordingBadge.padding(10) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ScrollView(showsIndicators: false) { panel }
                    .frame(width: wide ? 300 : nil)
            }
            .padding(16)
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            capture.segmentRecorder = session.recorder
            capture.start()
        }
        .onDisappear { if capture.isRunning { capture.stop() } }
        .sheet(isPresented: $showRecords) { LiveRecordSheet(session: session) }
        .confirmationDialog("경기를 끝낼까요?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("경기 끝내기", role: .destructive) {
                capture.stop()
                onDone()
            }
        } message: {
            Text("지금까지의 판정과 투구 영상은 저장되어 있습니다.")
        }
    }

    private var recordingBadge: some View {
        HStack(spacing: 6) {
            Circle().fill(capture.isRunning ? Color.red : Theme.secondaryText).frame(width: 8, height: 8)
            Text(capture.isRunning ? "촬영 중 \(clock(capture.stats.elapsed))" : capture.status)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(session.currentInning)회")
                    .font(.system(size: 34, weight: .bold))
                Text("이번 회 \(session.pitchesThisInning)구 · 전체 \(session.game.pitches.count)구")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
            .foregroundStyle(Theme.text)

            Button { session.demoPitch() } label: { Label("데모 투구", systemImage: "baseball") }
                .buttonStyle(PrimaryButtonStyle())
            Button { session.nextInning() } label: { Label("다음 이닝", systemImage: "arrow.forward.circle") }
                .buttonStyle(SecondaryButtonStyle())

            if let pitch = session.lastPitch {
                PitchCard(pitch: pitch, game: session.game)
            } else {
                Text("아직 기록된 투구가 없습니다. 데모 투구를 눌러 판정이 어떻게 기록되는지 볼 수 있습니다.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border, lineWidth: 1))
            }
            if !session.clipStatus.isEmpty {
                Text(session.clipStatus).font(.caption).foregroundStyle(Theme.secondaryText)
            }

            Button { showRecords = true } label: { Label("이번 경기 기록", systemImage: "list.bullet.rectangle") }
                .buttonStyle(SecondaryButtonStyle())
            Button { confirmEnd = true } label: { Label("경기 끝내기", systemImage: "stop.fill") }
                .buttonStyle(SecondaryButtonStyle())

            Text(String(format: "%.0ffps · 빠진 프레임 %d · 버려진 프레임 %d · 녹화 누락 %d · 발열 %@",
                        capture.stats.measuredFPS, capture.stats.gaps, capture.stats.dropped,
                        session.recorder.skipped, capture.thermal.label))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
        }
    }
}

/// 투구 하나의 판정 카드.
struct PitchCard: View {
    let pitch: PitchRecord
    let game: GameRecord

    private var judgement: Judgement { pitch.judgement }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(game.inning(of: pitch.number))회 \(game.order(inInning: pitch.number))번째 투구")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if pitch.isDemo {
                    Text("데모")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Status.warning.foreground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Status.warning.background, in: Capsule())
                }
            }
            Text(verdictText)
                .font(.system(size: 40, weight: .heavy))
                .foregroundStyle(judgement.verdict == .hold ? Status.warning.foreground : Theme.text)
            Text(detailText)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryText)
            ZoneDiagram(judgement: judgement).frame(height: 140)
            Text("참고용 · 최종 판정은 심판").font(.caption2).foregroundStyle(Theme.secondaryText)
        }
        .foregroundStyle(Theme.text)
        .padding(14)
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.border, lineWidth: 1))
    }

    private var verdictText: String {
        switch judgement.verdict {
        case .strike: "STRIKE"
        case .ball: "BALL"
        case .hold: "판정 보류"
        }
    }

    private var detailText: String {
        if judgement.verdict == .hold {
            let reason = switch judgement.holdReason {
            case .occlusion: "공이 가려져서 충분히 보지 못했습니다"
            case .tooFewDetections: "공을 찾은 프레임이 너무 적습니다"
            case .nearEdge: "존 경계에 너무 가까워 확신할 수 없습니다"
            case .calibration: "카메라 보정이 필요합니다"
            case nil: "판정할 수 없습니다"
            }
            return reason
        }
        let camera = judgement.usedAuxCamera ? "카메라 2대" : "카메라 1대"
        let loop = judgement.loopSteps > 0 ? " · 판단 루프 \(judgement.loopSteps)회" : ""
        // 100%로 보이면 오판이 없다는 뜻으로 읽히므로 99%에서 자른다.
        let sure = judgement.confidence >= 0.99 ? "99% 이상" : String(format: "%.0f%%", judgement.confidence * 100)
        return "확신 \(sure) · \(camera)\(loop)"
    }
}

/// 포수 뒤에서 본 스트라이크존과 공이 지난 위치.
struct ZoneDiagram: View {
    let judgement: Judgement

    var body: some View {
        Canvas { context, size in
            let zone = judgement.zone
            guard let section = zone.sections.first else { return }
            // 보여 줄 범위: 존 좌우·상하로 공 지름 4개만큼 여유
            let pad = 4 * 2 * ballRadius
            let (minX, maxX) = (section.xMin - pad, section.xMax + pad)
            let (minZ, maxZ) = (section.zMin - pad, section.zMax + pad)
            let scale = min(size.width / (maxX - minX), size.height / (maxZ - minZ))
            let ox = (size.width - (maxX - minX) * scale) / 2
            let oy = (size.height - (maxZ - minZ) * scale) / 2
            func point(_ x: Double, _ z: Double) -> CGPoint {
                CGPoint(x: ox + (x - minX) * scale, y: oy + (maxZ - z) * scale)
            }
            let topLeft = point(section.xMin, section.zMax)
            let bottomRight = point(section.xMax, section.zMin)
            let rect = CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
            context.fill(Path(rect), with: .color(Theme.surface))
            context.stroke(Path(rect), with: .color(Theme.text), lineWidth: 1.5)
            for i in 1...2 {  // 3x3 칸
                let fx = rect.minX + rect.width * Double(i) / 3, fy = rect.minY + rect.height * Double(i) / 3
                context.stroke(Path { p in p.move(to: CGPoint(x: fx, y: rect.minY)); p.addLine(to: CGPoint(x: fx, y: rect.maxY)) },
                               with: .color(Theme.border), lineWidth: 1)
                context.stroke(Path { p in p.move(to: CGPoint(x: rect.minX, y: fy)); p.addLine(to: CGPoint(x: rect.maxX, y: fy)) },
                               with: .color(Theme.border), lineWidth: 1)
            }
            guard let estimate = judgement.estimate, let ball = estimate.points.first else { return }
            let c = point(ball.x, ball.z)
            // 불확실성(표준편차 2배) 타원
            let ew = 2 * 2 * estimate.sigmaX * scale, eh = 2 * 2 * estimate.sigmaZ * scale
            context.stroke(Path(ellipseIn: CGRect(x: c.x - ew / 2, y: c.y - eh / 2, width: ew, height: eh)),
                           with: .color(Theme.secondaryText), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            let r = ballRadius * scale
            let color: Color = judgement.verdict == .strike ? Theme.text : judgement.verdict == .ball ? Theme.secondaryText : Status.warning.foreground
            context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), with: .color(color.opacity(0.85)))
        }
        .accessibilityLabel("스트라이크존과 공이 지난 위치")
    }
}
