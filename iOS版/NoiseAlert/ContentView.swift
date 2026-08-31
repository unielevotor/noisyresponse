import SwiftUI

struct ContentView: View {
    @StateObject private var detector = ImpactDetector()
    @State private var params = ParamsBox(DetectorParams())

    @AppStorage("mode") private var modeRaw = DetectionMode.impact.rawValue
    @AppStorage("sensitivity") private var sensitivity = 8.0
    @AppStorage("threshold") private var threshold = -35.0
    @AppStorage("cooldown") private var cooldown = 0.5
    @AppStorage("minDuration") private var minDuration = 80.0
    @AppStorage("gain") private var gain = 0.0
    @AppStorage("tone") private var toneRaw = ToneType.dingdong.rawValue

    @State private var logLines: [String] = []
    @State private var showError = false
    @State private var errorMessage = ""

    private var mode: DetectionMode {
        DetectionMode(rawValue: modeRaw) ?? .impact
    }

    private var selectedTone: ToneType {
        ToneType(rawValue: toneRaw) ?? .dingdong
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    modeSection
                    meterSection
                    settingsSection
                    logSection
                }
                .padding()
            }
            .navigationTitle("噪音提示")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(detector.isRunning ? "停止" : "开始监听") {
                        toggle()
                    }
                    .font(.body.weight(.semibold))
                }
            }
        }
        .onAppear { syncParams() }
        .onChange(of: modeRaw) { _ in syncParams() }
        .onChange(of: sensitivity) { _ in syncParams() }
        .onChange(of: threshold) { _ in syncParams() }
        .onChange(of: cooldown) { _ in syncParams() }
        .onChange(of: minDuration) { _ in syncParams() }
        .onChange(of: gain) { _ in syncParams() }
        .alert("无法启动", isPresented: $showError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - 检测模式

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
                Text("低频能量高出环境背景多少 dB 才触发，越小越灵敏")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("触发阈值")
                    Spacer()
                    Text("\(Int(threshold)) dB").foregroundStyle(.secondary)
                }
                Slider(value: $threshold, in: -60...0, step: 1)
                Text("整体音量达到该值才触发，越大越迟钝")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(cardBackground)
    }

    // MARK: - 电平表

    private var meterSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(mode == .impact ? "低频冲击电平（45–200 Hz）" : "环境噪音电平")
                    .font(.headline)
                Spacer()
                Text(String(format: "%.1f dB", detector.levelDb))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.tertiarySystemFill))
                    Capsule()
                        .fill(levelColor)
                        .frame(width: max(8, geo.size.width * levelFraction))
                }
            }
            .frame(height: 18)

            HStack {
                Text("触发次数：\(detector.triggerCount)")
                Spacer()
                if let t = detector.lastTriggerText {
                    Text("最近触发：\(t)").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .padding()
        .background(cardBackground)
    }

    // MARK: - 提示音与反馈

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("提示音与反馈").font(.headline)

            Picker("提示音", selection: $toneRaw) {
                ForEach(ToneType.allCases) { t in
                    Text(t.label).tag(t.rawValue)
                }
            }
            .pickerStyle(.menu)

            HStack {
                Text("最短持续")
                Spacer()
                Text("\(Int(minDuration)) ms").foregroundStyle(.secondary)
            }
            Slider(value: $minDuration, in: 50...500, step: 10)

            HStack {
                Text("触发冷却")
                Spacer()
                Text(String(format: "%.1f s", cooldown)).foregroundStyle(.secondary)
            }
            Slider(value: $cooldown, in: 0.3...5, step: 0.1)

            HStack {
                Text("麦克风增益")
                Spacer()
                Text("\(Int(gain)) dB").foregroundStyle(.secondary)
            }
            Slider(value: $gain, in: -30...30, step: 1)

            Text("提示音通过系统当前输出播放，连接蓝牙音箱后会自动走音箱。麦克风尽量贴近地面——脚步的“咚咚”主要是地板振动，贴近地面灵敏度明显更高。")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    Button("清空") { logLines.removeAll() }
                        .font(.caption)
                }
            }

            if logLines.isEmpty {
                Text("暂无记录。点击右上角“开始监听”。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(logLines, id: \.self) { line in
                    Text(line)
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
        .background(cardBackground)
    }

    // MARK: - 逻辑

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(.secondarySystemBackground))
    }

    private var levelFraction: CGFloat {
        CGFloat(max(0, min(1, (detector.levelDb + 60) / 60)))
    }

    private var levelColor: Color {
        if mode == .impact {
            return .teal  // 低音模式看的是相对背景的抬升，绝对电平不标红绿灯
        }
        let db = detector.levelDb
        if db > -15 { return .red }
        if db > -30 { return .orange }
        return .green
    }

    private func syncParams() {
        var p = params.get()
        p.mode = mode
        p.sensitivityDb = Float(sensitivity)
        p.thresholdDb = Float(threshold)
        p.cooldownSec = Float(cooldown)
        p.minDurationMs = Float(minDuration)
        p.gainDb = Float(gain)
        params.set(p)
    }

    private func toggle() {
        syncParams()
        if detector.isRunning {
            detector.stop()
        } else {
            do {
                try detector.start(params: params, tone: selectedTone) { text, db in
                    let line = "[\(text)] 检测到 \(db >= -30 ? "低频冲击" : "噪音") \(String(format: "%.0f", db)) dB → 已播放提示音"
                    logLines.insert(line, at: 0)
                    if logLines.count > 50 {
                        logLines.removeLast()
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }
}

#Preview {
    ContentView()
}
