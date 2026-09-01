import SwiftUI
import Combine
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var detector = ImpactDetector()
    @State private var params = ParamsBox(DetectorParams())

    @AppStorage("mode") private var modeRaw = DetectionMode.impact.rawValue
    @AppStorage("sensitivity") private var sensitivity = 8.0
    @AppStorage("threshold") private var threshold = -35.0
    @AppStorage("confirmCount") private var confirmCount = 3.0
    @AppStorage("windowSec") private var windowSec = 4.0
    @AppStorage("cooldown") private var cooldown = 2.0
    @AppStorage("gain") private var gain = 0.0
    @AppStorage("tone") private var toneRaw = ToneType.dingdong.rawValue
    @AppStorage("outputRoute") private var outputRouteRaw = OutputRoute.system.rawValue

    @State private var logLines: [String] = []
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showFileImporter = false
    @State private var runSeconds = 0
    @State private var inputDevices: [InputDeviceInfo] = []
    @State private var selectedInputUID = ""

    private var mode: DetectionMode { DetectionMode(rawValue: modeRaw) ?? .impact }
    private var selectedTone: ToneType { ToneType(rawValue: toneRaw) ?? .dingdong }
    private var toneDurationSec: Float {
        if detector.customAudioName != nil {
            return detector.customAudioDuration > 0 ? detector.customAudioDuration : 0.5
        }
        return selectedTone.totalSec
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    deviceSection
                    modeSection
                    audioSection
                    meterSection
                    settingsSection
                    logSection
                }
                .padding()
            }
            .navigationTitle("噪音提示")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(detector.isRunning ? "停止" : "开始监听") { toggle() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .onAppear {
            syncParams()
            refreshInputs()
            detector.setOutputRoute(OutputRoute(rawValue: outputRouteRaw) ?? .system)
        }
        .onChange(of: modeRaw) { _ in syncParams() }
        .onChange(of: sensitivity) { _ in syncParams() }
        .onChange(of: threshold) { _ in syncParams() }
        .onChange(of: confirmCount) { _ in syncParams() }
        .onChange(of: windowSec) { _ in syncParams() }
        .onChange(of: cooldown) { _ in syncParams() }
        .onChange(of: gain) { _ in syncParams() }
        .onChange(of: toneRaw) { _ in syncParams() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if detector.isRunning { runSeconds += 1 }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.audio, .mp3, .wav, .mpeg4Audio]) { result in
            switch result {
            case .success(let url):
                _ = url.startAccessingSecurityScopedResource()
                defer { url.stopAccessingSecurityScopedResource() }
                do {
                    try detector.setCustomAudio(url: url)
                    syncParams()
                } catch {
                    errorMessage = "读取音频失败：\(error.localizedDescription)"
                    showError = true
                }
            case .failure(let e):
                errorMessage = e.localizedDescription
                showError = true
            }
        }
        .alert("操作失败", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - 输入设备

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("输入设备（麦克风）").font(.headline)
            HStack {
                Picker("输入设备", selection: $selectedInputUID) {
                    Text("系统默认").tag("")
                    ForEach(inputDevices) { d in
                        Text(d.name).tag(d.id)
                    }
                }
                .pickerStyle(.menu)
                Button("刷新") { refreshInputs() }
            }

            HStack {
                Picker("输出设备（音箱）", selection: $outputRouteRaw) {
                    ForEach(OutputRoute.allCases) { r in
                        Text(r.label).tag(r.rawValue)
                    }
                }
                .pickerStyle(.menu)
            }
            Text("输入与输出独立控制：切换输入设备不会影响你选的输出。iPhone 由系统决定输入路由，通常只有内置麦克风；需外接麦请连蓝牙耳机或标准 USB 声卡。蓝牙 Hands-Free 麦克风会顺带占用输出，建议用 USB/直插接收器做输入、蓝牙音箱做输出。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(cardBackground)
        .onChange(of: selectedInputUID) { uid in
            detector.setPreferredInput(uid: uid.isEmpty ? nil : uid)
        }
        .onChange(of: outputRouteRaw) { _ in
            detector.setOutputRoute(OutputRoute(rawValue: outputRouteRaw) ?? .system)
        }
    }

    // MARK: - 检测模式与参数

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("检测模式").font(.headline)

            Picker("检测模式", selection: $modeRaw) {
                ForEach(DetectionMode.allCases) { m in
                    Text(m.label).tag(m.rawValue)
                }
            }
            .pickerStyle(.segmented)

            if mode == .impact {
                HStack {
                    Text("灵敏度")
                    Spacer()
                    Text("\(Int(sensitivity)) dB").foregroundStyle(.secondary)
                }
                Slider(value: $sensitivity, in: 4...20, step: 1)
            } else {
                HStack {
                    Text("触发阈值")
                    Spacer()
                    Text("\(Int(threshold)) dB").foregroundStyle(.secondary)
                }
                Slider(value: $threshold, in: -60...0, step: 1)
            }

            HStack {
                Text("确认次数")
                Spacer()
                Text("\(Int(confirmCount))次").foregroundStyle(.secondary)
            }
            Slider(value: $confirmCount, in: 1...10, step: 1)

            HStack {
                Text("时间窗口")
                Spacer()
                Text("\(Int(windowSec))秒").foregroundStyle(.secondary)
            }
            Slider(value: $windowSec, in: 1...10, step: 1)

            Text("低频需明显强于中频/高频才算冲击（说话声会被过滤）；需在时间窗口 T 秒内凑满 N 次才播放。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(cardBackground)
    }

    // MARK: - 报警音频

    private var audioSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("报警音频").font(.headline)

            HStack {
                VStack(alignment: .leading) {
                    Text(detector.customAudioName ?? "未选择文件（使用内置音）")
                        .font(.subheadline)
                        .lineLimit(1)
                    if detector.customAudioName != nil {
                        Button("移除自选音频") { detector.clearCustomAudio(); syncParams() }
                            .font(.caption)
                    }
                }
                Spacer()
                Button("选择文件…") { showFileImporter = true }
                    .font(.caption)
            }

            Picker("内置提示音（无自选文件时使用）", selection: $toneRaw) {
                ForEach(ToneType.allCases) { t in
                    Text(t.label).tag(t.rawValue)
                }
            }
            .pickerStyle(.menu)

            Text("支持 mp3 / wav / m4a；选了文件后优先播放它。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(cardBackground)
    }

    // MARK: - 电平与状态

    private var meterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(mode == .impact ? "低频冲击电平（45–200 Hz）" : "环境噪音电平")
                    .font(.headline)
                Spacer()
                Text(String(format: "%.1f dB", detector.levelDb))
                    .monospacedDigit().foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(levelColor)
                        .frame(width: max(8, geo.size.width * levelFraction))
                }
            }
            .frame(height: 14)

            MetricRow(label: "低频能量", value: String(format: "%.0f dB", detector.levelDb),
                      frac: CGFloat(max(0, min(1, (detector.levelDb + 60) / 60))))
            MetricRow(label: "尖锐度", value: "\(Int(detector.sharp * 100))%",
                      frac: CGFloat(detector.sharp))
            MetricRow(label: "冲击累积",
                      value: "\(detector.impactCount)/\(detector.confirmCount)",
                      frac: detector.confirmCount > 0
                        ? CGFloat(detector.impactCount) / CGFloat(detector.confirmCount) : 0)
            MetricRow(label: "低频占比", value: "\(Int(detector.lowRatio * 100))%",
                      frac: CGFloat(detector.lowRatio))
            MetricRow(label: "综合评分", value: "\(Int(detector.score * 100))%",
                      frac: CGFloat(detector.score))

            HStack {
                Text("触发次数：\(detector.triggerCount)")
                Spacer()
                Text(runTimeText).monospacedDigit().foregroundStyle(.secondary)
                if let t = detector.lastTriggerText {
                    Text("最近 \(t)").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding()
        .background(cardBackground)
    }

    // MARK: - 反馈参数

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("反馈参数").font(.headline)

            HStack {
                Text("触发冷却")
                Spacer()
                Text(String(format: "%.1f s", cooldown)).foregroundStyle(.secondary)
            }
            Slider(value: $cooldown, in: 0.3...30, step: 0.5)

            HStack {
                Text("麦克风增益")
                Spacer()
                Text("\(Int(gain)) dB").foregroundStyle(.secondary)
            }
            Slider(value: $gain, in: -30...30, step: 1)

            Text("提示音通过系统当前输出播放；连接蓝牙音箱后自动走音箱。麦克风贴近地面更灵敏。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .background(cardBackground)
    }

    // MARK: - 日志

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("运行日志").font(.headline)
                Spacer()
                if !logLines.isEmpty {
                    Button("清空") { logLines.removeAll() }.font(.caption)
                }
            }
            if logLines.isEmpty {
                Text("暂无记录，点击右上角“开始监听”。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(logLines, id: \.self) { line in
                    Text(line).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
        .background(cardBackground)
    }

    // MARK: - 辅助

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground))
    }

    private var levelFraction: CGFloat {
        CGFloat(max(0, min(1, (detector.levelDb + 60) / 60)))
    }

    private var levelColor: Color {
        if mode == .impact { return .teal }
        let db = detector.levelDb
        if db > -15 { return .red }
        if db > -30 { return .orange }
        return .green
    }

    private var runTimeText: String {
        let h = runSeconds / 3600
        let m = (runSeconds % 3600) / 60
        let s = runSeconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private func refreshInputs() {
        inputDevices = detector.inputDevices()
    }

    private func syncParams() {
        var p = params.get()
        p.mode = mode
        p.sensitivityDb = Float(sensitivity)
        p.thresholdDb = Float(threshold)
        p.confirmCount = Int(confirmCount)
        p.windowSec = Float(windowSec)
        p.cooldownSec = Float(cooldown)
        p.gainDb = Float(gain)
        p.toneDurationSec = toneDurationSec
        params.set(p)
    }

    private func toggle() {
        syncParams()
        if detector.isRunning {
            detector.stop()
        } else {
            runSeconds = 0
            do {
                try detector.start(params: params, tone: selectedTone) { text, db, count in
                    let kind = db >= -30 ? "低频冲击" : "噪音"
                    let line = "[\(text)] 确认到 \(count) 次\(kind)（\(String(format: "%.0f", db)) dB）→ 已播放"
                    logLines.insert(line, at: 0)
                    if logLines.count > 50 { logLines.removeLast() }
                }
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

private struct MetricRow: View {
    let label: String
    let value: String
    let frac: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 72, alignment: .leading)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(.tertiarySystemFill))
                    Capsule().fill(Color.accentColor)
                        .frame(width: max(4, g.size.width * frac))
                }
            }
            .frame(height: 8)
            Text(value).font(.caption).monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 60, alignment: .trailing)
        }
    }
}

#Preview {
    ContentView()
}
