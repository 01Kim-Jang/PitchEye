import Foundation

/// 프레임 타임스탬프로 실제 fps와 누락을 잰다. fps 설정값이 아니라 실측 간격을 본다.
struct FrameStats {
    let expectedInterval: Double
    private(set) var frames = 0
    /// 시스템이 버렸다고 알려준 프레임 수
    private(set) var dropped = 0
    /// 간격이 기대값의 1.5배를 넘은 횟수 (타임스탬프로 검출한 누락)
    private(set) var gaps = 0
    private(set) var maxInterval = 0.0
    private var first: Double?
    private var last: Double?

    init(fps: Double) {
        expectedInterval = 1 / fps
    }

    mutating func add(timestamp: Double) {
        if let last {
            let interval = timestamp - last
            maxInterval = max(maxInterval, interval)
            if interval > expectedInterval * 1.5 { gaps += 1 }
        } else {
            first = timestamp
        }
        last = timestamp
        frames += 1
    }

    mutating func addDrop() {
        dropped += 1
    }

    var elapsed: Double {
        guard let first, let last else { return 0 }
        return last - first
    }

    var measuredFPS: Double {
        elapsed > 0 ? Double(frames - 1) / elapsed : 0
    }

    #if DEBUG
    /// 로직이 깨지면 디버그 실행 시 바로 멈춘다.
    static func selfCheck() {
        var clean = FrameStats(fps: 240)
        for i in 0...240 { clean.add(timestamp: Double(i) / 240) }
        assert(abs(clean.measuredFPS - 240) < 0.001 && clean.gaps == 0 && clean.frames == 241)

        var missing = FrameStats(fps: 240)
        for i in 0...240 where i != 100 { missing.add(timestamp: Double(i) / 240) }
        assert(missing.gaps == 1 && abs(missing.maxInterval - 2.0 / 240) < 1e-9)
    }
    #endif
}
