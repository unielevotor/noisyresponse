import AVFoundation
import Accelerate
import Combine

// MARK: - 检测模式

enum DetectionMode: String, CaseIterable, Identifiable {
    case impact
    case rms

    var id: String { rawValue }

    var label: String {
        switch self {
        case .impact: return "低音冲击"
        case .rms: return "普通音量"
        }
    }
}

// MARK: - 提示音类型

enum ToneType: String, CaseIterable, Identifiable {
    case dingdong
    case beep
    case click
    case chime

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dingdong: return "叮咚"
        case .beep: return "蜂鸣"
        case .click: return "短促滴"
        case .chime: return "钟琴"
        }
    }
}

// MARK: - 检测参数

struct DetectorParams {
    var mode: DetectionMode = .impact
    var sensitivityDb: Float = 8      // 低音冲击模式：低音高出背景多少 dB
    var thresholdDb: Float = -35      // 普通音量模式：整体音量阈值
    var hysteresisDb: Float = 6
    var cooldownSec: Float = 0.5
    var minDurationMs: Float = 80
    var gainDb: Float = 0
}

/// 供检测线程与主线程安全共享的实时参数
final class ParamsBox {
    private let lock = NSLock()
    private var value: DetectorParams

    init(_ v: DetectorParams) { value = v }

    func get() -> DetectorParams {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ v: DetectorParams) {
        lock.lock()
        defer { lock.unlock() }
        value = v
    }
}

// MARK: - 检测器

final class ImpactDetector: ObservableObject {
    @Published var levelDb: Float = -99
    @Published var isRunning = false
    @Published var triggerCount = 0
    @Published var lastTriggerText: String?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let processQueue = DispatchQueue(label: "NoiseAlert.Detector")

    private var fftSetup: FFTSetup?
    private var toneBuffer: AVAudioPCMBuffer?
    private var toneDuration: Float = 0.55
    private var interruptionObserver: NSObjectProtocol?
    private var playbackConfigured = false

    // 状态机（仅在 processQueue 上读写）
    private var baseline: Float?
    private var armed = true
    private var quietCount = 0
    private var overCount = 0
    private var lastTriggerTime: Double = 0
    private var playingUntil: Double = 0
    private var blockCount = 0

    // MARK: 启动 / 停止

    func start(params: ParamsBox, tone: ToneType,
               onTrigger: @escaping (String, Float) -> Void) throws {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
        try session.setActive(true)

        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        let sampleRate = inputFormat.sampleRate

        // 生成提示音（与检测共用同一个音频引擎，无需文件）
        toneBuffer = Self.makeTone(tone, sampleRate: sampleRate)
        toneDuration = Float(toneBuffer?.frameLength ?? 0) / Float(sampleRate)

        if !playbackConfigured {
            engine.attach(playerNode)
            let playFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                           channels: 1)!
            engine.connect(playerNode, to: engine.mainMixerNode, format: playFormat)
            playbackConfigured = true
        }

        // 在启动音频流之前重置状态机
        baseline = nil
        armed = true
        quietCount = 0
        overCount = 0
        lastTriggerTime = 0
        playingUntil = 0
        blockCount = 0
        triggerCount = 0
        lastTriggerText = nil

        let blockSize: AVAudioFrameCount = 1024
        engine.inputNode.installTap(onBus: 0, bufferSize: blockSize,
                                    format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.processQueue.async {
                self.process(buffer: buffer, params: params, onTrigger: onTrigger)
            }
        }

        engine.prepare()
        try engine.start()

        // 收到来电等中断后自动恢复
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.engine.pause()
            case .ended:
                try? self.engine.start()
            default:
                break
            }
        }

        isRunning = true
    }

    func stop() {
        if let obs = interruptionObserver {
            NotificationCenter.default.removeObserver(obs)
            interruptionObserver = nil
        }
        engine.inputNode.removeTap(onBus: 0)
        playerNode.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isRunning = false
    }

    // MARK: 处理音频块（与 PC 版算法一致）

    private func process(buffer: AVAudioPCMBuffer, params: ParamsBox,
                         onTrigger: @escaping (String, Float) -> Void) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let sr = Float(buffer.format.sampleRate)
        let count = min(Int(buffer.frameLength), 1024)
        guard count > 0 else { return }

        let p = params.get()
        let now = ProcessInfo.processInfo.systemUptime
        let blockSec = Float(count) / sr

        var lowDb: Float = -99
        var midDb: Float = -99
        var db: Float
        if p.mode == .impact {
            (lowDb, midDb) = bandDbs(data: data, count: count, sampleRate: sr)
            db = lowDb + p.gainDb
        } else {
            var sum: Float = 0
            for i in 0..<count {
                let v = data[i]
                sum += v * v
            }
            let rms = sqrt(sum / Float(count))
            db = 20 * log10(rms + 1e-12) + p.gainDb
        }

        blockCount += 1
        if blockCount % 5 == 0 {
            let level = db
            DispatchQueue.main.async { [weak self] in
                self?.levelDb = level
            }
        }

        // 提示音播放期间忽略麦克风，避免反馈循环
        if now < playingUntil { return }

        if !armed {
            let quietLine: Float
            if p.mode == .impact {
                quietLine = (baseline ?? db) + p.sensitivityDb - 4
            } else {
                quietLine = p.thresholdDb - p.hysteresisDb
            }
            if db < quietLine {
                quietCount += 1
                if quietCount >= rearmFrames(blockSec: blockSec) {
                    armed = true
                    quietCount = 0
                }
            } else {
                quietCount = 0
            }
        } else {
            let hit: Bool
            if p.mode == .impact {
                hit = impactHit(lowDb: lowDb, midDb: midDb, sensitivity: p.sensitivityDb)
            } else {
                hit = db >= p.thresholdDb
            }
            if hit {
                overCount += 1
                if overCount >= minFrames(p: p, blockSec: blockSec)
                    && now - lastTriggerTime >= Double(p.cooldownSec) {
                    lastTriggerTime = now
                    playingUntil = now + Double(toneDuration) + 0.3
                    overCount = 0
                    armed = false
                    playTone()
                    let text = Self.timeString()
                    DispatchQueue.main.async { [weak self] in
                        self?.triggerCount += 1
                        self?.lastTriggerText = text
                        onTrigger(text, db)
                    }
                }
            } else {
                overCount = 0
            }
        }

        // 基线自适应（仅低音冲击模式）：平时跟随，触发期间半速跟随，
        // 持续低频声几秒后被吸收，不再反复触发
        if p.mode == .impact {
            if let b = baseline {
                let th = b + p.sensitivityDb
                let rate = (db >= th ? 0.5 : 1.0) * (1 - exp(-blockSec / 2))
                baseline = b + rate * (db - b)
            } else {
                baseline = db
            }
        }
    }

    private func impactHit(lowDb: Float, midDb: Float, sensitivity: Float) -> Bool {
        guard let b = baseline else { return false }
        // 低频主导：低频不低于中频，用于过滤说话声
        return lowDb >= midDb && lowDb >= b + sensitivity
    }

    private func minFrames(p: DetectorParams, blockSec: Float) -> Int {
        max(1, Int((p.minDurationMs / 1000 / blockSec).rounded()))
    }

    private func rearmFrames(blockSec: Float) -> Int {
        max(2, Int((0.2 / blockSec).rounded()))
    }

    // MARK: FFT 频带能量

    private func fftSetupOrCreate() -> FFTSetup? {
        if let s = fftSetup { return s }
        let s = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2))  // 2^12 = 4096
        fftSetup = s
        return s
    }

    private func bandDbs(data: UnsafePointer<Float>, count: Int,
                         sampleRate: Float) -> (low: Float, mid: Float) {
        guard let setup = fftSetupOrCreate() else { return (-99, -99) }

        let fftSize = 4096
        var input = [Float](repeating: 0, count: fftSize)
        for i in 0..<count {
            // Hann 窗
            let h = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(count))
            input[i] = data[i] * h
        }

        var realp = [Float](repeating: 0, count: fftSize / 2)
        var imagp = [Float](repeating: 0, count: fftSize / 2)
        var split = DSPSplitComplex(realp: &realp, imagp: &imagp)

        input.withUnsafeMutableBufferPointer { buf in
            buf.baseAddress?.withMemoryRebound(to: DSPComplex.self,
                                               capacity: fftSize / 2) { cpx in
                vDSP_ctoz(cpx, 2, &split, 1, vDSP_Length(fftSize / 2))
            }
        }
        vDSP_fft_zrip(setup, &split, 1, 12, FFTDirection(FFT_FORWARD))

        let freqStep = sampleRate / Float(fftSize)
        let lowStart = Int(ceil(45 / freqStep))
        let lowEnd = Int(floor(200 / freqStep))
        let midStart = Int(ceil(300 / freqStep))
        let midEnd = Int(floor(2000 / freqStep))
        let limit = fftSize / 2 - 1

        func energy(_ a: Int, _ b: Int) -> Float {
            guard a <= b, b <= limit else { return 0 }
            var s: Float = 0
            for k in a...b {
                let r = realp[k]
                let im = imagp[k]
                s += r * r + im * im
            }
            return sqrt(s / Float(b - a + 1))
        }

        let low = 20 * log10(energy(lowStart, lowEnd) + 1e-15)
        let mid = 20 * log10(energy(midStart, midEnd) + 1e-15)
        return (low, mid)
    }

    // MARK: 提示音播放

    private func playTone() {
        guard let buf = toneBuffer else { return }
        playerNode.stop()
        playerNode.scheduleBuffer(buf, at: nil, options: .interrupts,
                                  completionHandler: nil)
        playerNode.play()
    }

    /// 在内存中合成提示音（无需打包音频文件）
    private static func makeTone(_ type: ToneType, sampleRate: Double) -> AVAudioPCMBuffer? {
        let sr = Float(sampleRate)
        let parts: [(freq: Float, start: Float, dur: Float)]
        let total: Float
        switch type {
        case .dingdong:
            parts = [(880, 0, 0.15), (1174.66, 0.18, 0.28)]
            total = 0.55
        case .beep:
            parts = [(1000, 0, 0.35)]
            total = 0.45
        case .click:
            parts = [(1500, 0, 0.08)]
            total = 0.18
        case .chime:
            parts = [(660, 0, 0.18), (990, 0.20, 0.35)]
            total = 0.62
        }

        let frameCount = AVAudioFrameCount(total * sr)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                                         channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        guard let ptr = buffer.floatChannelData?[0] else { return nil }

        for i in 0..<Int(frameCount) {
            let t = Float(i) / sr
            var s: Float = 0
            for part in parts {
                let t0 = t - part.start
                if t0 >= 0 && t0 < part.dur {
                    let attack = min(1, t0 / 0.008)
                    let env = attack * exp(-t0 / 0.10)
                    s += 0.35 * sin(2 * Float.pi * part.freq * t0) * env
                }
            }
            ptr[i] = s
        }
        return buffer
    }

    private static func timeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
