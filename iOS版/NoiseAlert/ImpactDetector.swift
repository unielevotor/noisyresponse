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

// MARK: - 提示音类型（内置合成音，作为未选文件时的备选）

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

    var totalSec: Float {
        switch self {
        case .dingdong: return 0.55
        case .beep: return 0.45
        case .click: return 0.18
        case .chime: return 0.62
        }
    }
}

// MARK: - 输入设备信息

struct InputDeviceInfo: Identifiable {
    let id: String
    let name: String
}

// MARK: - 输出路由（音箱）

enum OutputRoute: String, CaseIterable, Identifiable {
    case system
    case speaker
    case bluetooth

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "系统默认"
        case .speaker: return "内建扬声器"
        case .bluetooth: return "蓝牙音箱"
        }
    }
}

// MARK: - 检测参数

struct DetectorParams {
    var mode: DetectionMode = .impact
    var sensitivityDb: Float = 8
    var thresholdDb: Float = -35
    var confirmCount: Int = 3
    var windowSec: Float = 4
    var cooldownSec: Float = 2
    var gainDb: Float = 0
    var toneDurationSec: Float = 0.55
}

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
    @Published var lowRatio: Float = 0
    @Published var sharp: Float = 0
    @Published var score: Float = 0
    @Published var impactCount = 0
    @Published var confirmCount = 3
    @Published var isRunning = false
    @Published var triggerCount = 0
    @Published var lastTriggerText: String?
    @Published var customAudioName: String?
    @Published private(set) var customAudioDuration: Float = 0
    @Published var activeInputName: String?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let processQueue = DispatchQueue(label: "NoiseAlert.Detector")

    private var fftSetup: FFTSetup?
    private var toneBuffer: AVAudioPCMBuffer?
    private var customAudioPlayer: AVAudioPlayer?
    private var playerAttached = false
    private var tapInstalled = false
    private var outputRoute: OutputRoute = .system

    // 生命周期与运行状态（主线程写，processQueue 读）
    private var isMonitoring = false
    private var activeParams: ParamsBox?
    private var onTrigger: ((String, Float, Int) -> Void)?

    // 判定与防抖常量
    private let domMargin: Float = 8     // 低频需比中频强这么多 dB（抑制说话声）
    private let hiMargin: Float = 6      // 低频需明显高于高频
    private let peakDrop: Float = 8      // 从事件峰值回落多少 dB 才算结束
    private let eventGap: Float = 0.25   // 两次计数最小间隔（秒），合并快速音节
    private let maxSustainSec: Float = 0.5 // 连续高于阈值超过该时长视为持续声，整组清零

    // 状态机（仅在 processQueue 上读写）
    private var baseline: Float?
    private var inEvent = false
    private var peak: Float = -1e9
    private var eventCount = 0
    private var windowStart: Double = 0
    private var lastEventTime: Double = -1e9
    private var lastFireTime: Double = -1e9
    private var playingUntil: Double = 0
    private var blockCount = 0
    private var sustainSec: Float = 0
    private var sustainSuppress = false

    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var engineConfigObserver: NSObjectProtocol?
    private var mediaResetObserver: NSObjectProtocol?

    // MARK: 启动 / 停止

    func start(params: ParamsBox, tone: ToneType,
               onTrigger: @escaping (String, Float, Int) -> Void) throws {
        guard !isRunning else { return }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothHFP, .allowBluetoothA2DP]
        )
        try session.setActive(true)
        applyOutputRoute(outputRoute)

        let inputFormat = engine.inputNode.inputFormat(forBus: 0)
        toneBuffer = Self.makeTone(tone, sampleRate: inputFormat.sampleRate)

        activeParams = params
        self.onTrigger = onTrigger
        resetState()
        isMonitoring = true

        try ensureTapAndStart()
        registerObservers()
        updateActiveInputName()
        isRunning = true
    }

    func stop() {
        isMonitoring = false
        activeParams = nil
        onTrigger = nil
        removeObservers()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        playerNode.stop()
        customAudioPlayer?.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false,
            options: [.notifyOthersOnDeactivation])
        isRunning = false
    }

    private func resetState() {
        baseline = nil
        inEvent = false
        peak = -1e9
        eventCount = 0
        windowStart = 0
        lastEventTime = -1e9
        lastFireTime = -1e9
        playingUntil = 0
        blockCount = 0
        sustainSec = 0
        sustainSuppress = false
        triggerCount = 0
        lastTriggerText = nil
        impactCount = 0
    }

    // MARK: 音频管道（只安装一次 tap，通过暂停/启动引擎控制）

    private func ensureTapAndStart() throws {
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)
        let playFormat = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate,
                                       channels: 1)!

        if !playerAttached {
            engine.attach(playerNode)
            playerAttached = true
        }
        engine.connect(playerNode, to: engine.mainMixerNode, format: playFormat)

        if engine.isRunning { engine.stop() }
        if tapInstalled { inputNode.removeTap(onBus: 0) }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            self.processQueue.async { self.process(buffer: buffer) }
        }
        tapInstalled = true

        engine.prepare()
        try engine.start()
    }

    // MARK: 通知观察（中断 / 路由 / 引擎配置 / 媒体服务重置）

    private func registerObservers() {
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                guard self.isMonitoring else { return }
                self.engine.pause()
            case .ended:
                guard self.isMonitoring else { return }
                try? AVAudioSession.sharedInstance().setActive(true)
                if !self.engine.isRunning { try? self.ensureTapAndStart() }
            default:
                break
            }
        }

        routeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.isMonitoring else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            try? self.ensureTapAndStart()
            self.updateActiveInputName()
        }

        engineConfigObserver = center.addObserver(
            forName: Notification.Name("AVAudioEngineConfigurationChange"),
            object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.isMonitoring else { return }
            try? self.ensureTapAndStart()
        }

        mediaResetObserver = center.addObserver(
            forName: Notification.Name("AVAudioSessionMediaServicesWereResetNotification"),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.engine.stop()
            self.tapInstalled = false
            if self.isMonitoring { try? self.ensureTapAndStart() }
        }
    }

    private func removeObservers() {
        let center = NotificationCenter.default
        if let o = interruptionObserver { center.removeObserver(o); interruptionObserver = nil }
        if let o = routeObserver { center.removeObserver(o); routeObserver = nil }
        if let o = engineConfigObserver { center.removeObserver(o); engineConfigObserver = nil }
        if let o = mediaResetObserver { center.removeObserver(o); mediaResetObserver = nil }
    }

    // MARK: 处理音频块

    private func process(buffer: AVAudioPCMBuffer) {
        guard isMonitoring, let params = activeParams, let onTrigger = onTrigger else { return }
        guard let data = buffer.floatChannelData?[0] else { return }
        let sr = Float(buffer.format.sampleRate)
        let count = min(Int(buffer.frameLength), 1024)
        guard count > 0 else { return }

        let p = params.get()
        let now = ProcessInfo.processInfo.systemUptime
        let blockSec = Float(count) / sr

        let bands = bandDbs(data: data, count: count, sampleRate: sr)
        let lowDb = bands.low, midDb = bands.mid, hiDb = bands.hi
        let lowE = bands.lowE, midE = bands.midE, hiE = bands.hiE
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        let rmsDb = 20 * log10(sqrt(sum / Float(count)) + 1e-12) + p.gainDb
        let db = p.mode == .impact ? lowDb + p.gainDb : rmsDb
        blockCount += 1

        let totalE = lowE + midE + hiE + 1e-12
        let lowRatio = lowE / totalE
        let sharp = clamp01((hiE / totalE) * 1.4)
        let score: Float
        if p.mode == .impact {
            score = clamp01((db - (baseline ?? db)) / 30) * clamp01((lowDb - midDb) / 20)
        } else {
            score = clamp01((db - p.thresholdDb) / 30)
        }
        if blockCount % 5 == 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.levelDb = db
                self.lowRatio = lowRatio
                self.sharp = sharp
                self.score = score
                self.impactCount = self.eventCount
                self.confirmCount = p.confirmCount
            }
        }

        if now < playingUntil { return }

        if eventCount > 0 && now - windowStart > Double(p.windowSec) {
            eventCount = 0
            windowStart = now
        }

        let active: Float = p.mode == .impact
            ? (baseline != nil ? baseline! + p.sensitivityDb : .infinity)
            : p.thresholdDb
        let impactLike: Bool
        if p.mode == .impact {
            impactLike = baseline != nil
                && (lowDb - midDb) >= domMargin
                && (lowDb - hiDb) >= hiMargin
                && lowDb > active
        } else {
            impactLike = db >= active
        }

        // 持续声抑制：连续高于阈值超过 maxSustainSec 视为说话/嗡嗡声，整组清零
        if impactLike {
            sustainSec += blockSec
            if sustainSec > maxSustainSec {
                if eventCount > 0 { eventCount = 0 }
                windowStart = now
                sustainSuppress = true
                inEvent = false
                peak = -1e9
            }
        } else if lowDb < active - 4 {
            sustainSec = 0
            sustainSuppress = false
        }

        if !sustainSuppress {
            if inEvent {
                if lowDb < peak - peakDrop {
                    inEvent = false
                } else {
                    peak = max(peak, lowDb)
                }
            } else if impactLike {
                inEvent = true
                peak = lowDb
                if now >= lastFireTime + Double(p.cooldownSec)
                    && now - lastEventTime >= Double(eventGap) {
                    if eventCount == 0 { windowStart = now }
                    eventCount += 1
                    lastEventTime = now
                }
            }

            if eventCount >= p.confirmCount
                && now >= lastFireTime + Double(p.cooldownSec) {
                lastFireTime = now
                playingUntil = now + Double(p.toneDurationSec) + 0.3
                let fired = eventCount
                eventCount = 0
                windowStart = now
                playTone()
                let text = Self.timeString()
                let fireDb = db
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.triggerCount += 1
                    self.lastTriggerText = text
                    self.impactCount = 0
                    onTrigger(text, fireDb, fired)
                }
            }
        }

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

    // MARK: FFT 频带能量（低/中/高三段）

    private func fftSetupOrCreate() -> FFTSetup? {
        if let s = fftSetup { return s }
        let s = vDSP_create_fftsetup(12, FFTRadix(kFFTRadix2))
        fftSetup = s
        return s
    }

    private func bandDbs(data: UnsafePointer<Float>, count: Int,
                         sampleRate: Float) -> (low: Float, mid: Float, hi: Float,
                                                lowE: Float, midE: Float, hiE: Float) {
        guard let setup = fftSetupOrCreate() else {
            return (low: -99, mid: -99, hi: -99, lowE: 0, midE: 0, hiE: 0)
        }

        let fftSize = 4096
        var input = [Float](repeating: 0, count: fftSize)
        for i in 0..<count {
            let h = 0.5 - 0.5 * cos(2 * Float.pi * Float(i) / Float(count))
            input[i] = data[i] * h
        }

        var realp = [Float](repeating: 0, count: fftSize / 2)
        var imagp = [Float](repeating: 0, count: fftSize / 2)
        return realp.withUnsafeMutableBufferPointer { realpBuf in
            imagp.withUnsafeMutableBufferPointer { imagpBuf in
                var split = DSPSplitComplex(realp: realpBuf.baseAddress!,
                                            imagp: imagpBuf.baseAddress!)
                input.withUnsafeMutableBufferPointer { buf in
                    buf.baseAddress?.withMemoryRebound(to: DSPComplex.self,
                                                       capacity: fftSize / 2) { cpx in
                        vDSP_ctoz(cpx, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, 12, FFTDirection(FFT_FORWARD))

                let freqStep = sampleRate / Float(fftSize)
                func rg(_ loHz: Float, _ hiHz: Float) -> (Int, Int) {
                    let a = Int(ceil(loHz / freqStep))
                    let b = min(fftSize / 2 - 1, Int(floor(hiHz / freqStep)))
                    return (max(0, a), max(a, b))
                }
                let lowR = rg(45, 200)
                let midR = rg(300, 2000)
                let hiR = rg(2500, 8000)

                func energy(_ r: (Int, Int)) -> Float {
                    var s: Float = 0
                    for k in r.0...r.1 {
                        let re = realpBuf[k]
                        let im = imagpBuf[k]
                        s += re * re + im * im
                    }
                    return sqrt(s / Float(r.1 - r.0 + 1) + 1e-15)
                }
                let lowE = energy(lowR)
                let midE = energy(midR)
                let hiE = energy(hiR)
                let toDb = { (v: Float) -> Float in 20 * log10(v + 1e-15) }
                return (low: toDb(lowE), mid: toDb(midE), hi: toDb(hiE),
                        lowE: lowE, midE: midE, hiE: hiE)
            }
        }
    }

    // MARK: 提示音播放

    private func playTone() {
        if let player = customAudioPlayer {
            player.stop()
            player.currentTime = 0
            player.play()
        } else if let buf = toneBuffer {
            playerNode.stop()
            playerNode.scheduleBuffer(buf, at: nil, options: .interrupts,
                                      completionHandler: nil)
            playerNode.play()
        }
    }

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
                                            frameCapacity: frameCount) else { return nil }
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

    func setCustomAudio(url: URL) throws {
        let data = try Data(contentsOf: url)
        let player = try AVAudioPlayer(data: data)
        player.prepareToPlay()
        customAudioPlayer = player
        customAudioDuration = Float(player.duration)
        customAudioName = url.lastPathComponent
    }

    func clearCustomAudio() {
        customAudioPlayer = nil
        customAudioDuration = 0
        customAudioName = nil
    }

    func inputDevices() -> [InputDeviceInfo] {
        guard let inputs = AVAudioSession.sharedInstance().availableInputs else { return [] }
        return inputs.map { InputDeviceInfo(id: $0.uid, name: $0.portName) }
    }

    func setPreferredInput(uid: String?) {
        let session = AVAudioSession.sharedInstance()
        guard let inputs = session.availableInputs else { return }
        let target = uid.flatMap { id in inputs.first { $0.uid == id } }
        try? session.setPreferredInput(target)
        try? session.setActive(true)
        // 切换输入后重新应用输出，避免输出被顺带切换
        applyOutputRoute(outputRoute)
        updateActiveInputName()
    }

    private func updateActiveInputName() {
        let name = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
        DispatchQueue.main.async { [weak self] in self?.activeInputName = name }
    }

    // MARK: 输出路由控制

    func setOutputRoute(_ route: OutputRoute) {
        outputRoute = route
        applyOutputRoute(route)
    }

    private func applyOutputRoute(_ route: OutputRoute) {
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(true)
        switch route {
        case .system, .bluetooth:
            // 交给系统选择（若已连接蓝牙音箱且允许 A2DP，会优先走音箱）
            try? session.overrideOutputAudioPort(.none)
        case .speaker:
            // 强制使用内建扬声器（避免被接收器/蓝牙抢走输出）
            try? session.overrideOutputAudioPort(.speaker)
        }
    }

    private func clamp01(_ v: Float) -> Float { max(0, min(1, v)) }

    private static func timeString() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}
