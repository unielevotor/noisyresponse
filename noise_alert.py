# -*- coding: utf-8 -*-
"""
噪音提示工具
-----------
通过无线麦克风实时检测环境噪音，一旦音量超过阈值，
就在蓝牙音箱上自动播放指定的提示音。

运行：python noise_alert.py
依赖：pip install -r requirements.txt
"""

import json
import math
import os
import queue
import threading
import time
import wave

import numpy as np
import sounddevice as sd
import tkinter as tk
from tkinter import filedialog, messagebox, ttk


BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "config.json")
DEFAULT_ALERT = os.path.join(BASE_DIR, "alert.wav")

DEFAULT_CONFIG = {
    "input_device": "",       # 麦克风设备名（空 = 系统默认）
    "output_device": "",      # 蓝牙音箱设备名（空 = 系统默认）
    "mode": "impact",         # 检测模式：impact=低音冲击（脚步声/敲击），rms=普通音量
    "sensitivity_db": 8.0,    # 低音冲击模式灵敏度：低音能量超过背景多少 dB 触发
    "threshold_db": -35.0,    # 触发阈值（dB，越大越难触发）
    "hysteresis_db": 6.0,     # 滞后：音量降到 阈值-滞后 以下才重新武装
    "cooldown_sec": 0.5,      # 两次触发的最小间隔（秒）
    "min_duration_ms": 80,    # 噪音至少持续该时长才触发（毫秒）
    "gain_db": 0.0,           # 麦克风增益（dB）
    "alert_file": "alert.wav" # 提示音文件（16bit WAV）
}

BLOCK_MS = 50  # 分析窗口：每 50ms 计算一次音量
MODES = {
    "impact": "低音冲击（脚步声/敲击）",
    "rms": "普通音量",
}
MODE_DEFAULTS = {
    "impact": {"min_duration_ms": 80, "cooldown_sec": 0.5},
    "rms": {"min_duration_ms": 150, "cooldown_sec": 2.0},
}


# ---------------------------------------------------------------- 工具函数

def load_config():
    cfg = dict(DEFAULT_CONFIG)
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                cfg.update(json.load(f))
        except Exception:
            pass
    return cfg


def save_config(cfg):
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)


def list_devices(kind):
    """按名称去重列出输入/输出设备，返回 {名称: 设备序号}。"""
    result = {}
    try:
        for i, dev in enumerate(sd.query_devices()):
            if kind == "in" and dev["max_input_channels"] > 0:
                pass
            elif kind == "out" and dev["max_output_channels"] > 0:
                pass
            else:
                continue
            if dev["name"] not in result:
                result[dev["name"]] = i
    except Exception:
        pass
    return result


def load_wav(path):
    """读取 16/32bit 的 WAV，返回 (float32 单声道数据, 采样率)。"""
    with wave.open(path, "rb") as w:
        nch, sw, sr, nframes = (
            w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        )
        raw = w.readframes(nframes)
    if sw == 2:
        data = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
    elif sw == 4:
        data = np.frombuffer(raw, dtype=np.int32).astype(np.float32) / 2147483648.0
    else:
        raise ValueError(f"不支持的 WAV 位深（{sw * 8}bit），请使用 16/32bit")
    if nch == 2:
        data = data.reshape(-1, 2).mean(axis=1)
    elif nch != 1:
        raise ValueError("不支持的声道数")
    return data, sr


def ensure_alert_wav(path=DEFAULT_ALERT):
    """如果提示音文件不存在，生成一个默认的双音提示音。"""
    if os.path.exists(path):
        return
    sr = 44100
    n = int(sr * 0.55)
    t = np.arange(n) / sr
    sig = np.zeros(n)
    for freq, start, dur in ((880.0, 0.0, 0.15), (1174.7, 0.18, 0.28)):
        i0 = int(start * sr)
        i1 = min(n, int((start + dur) * sr))
        tt = t[i0:i1] - t[i0]
        env = np.minimum(1.0, tt / 0.008) * np.exp(-tt / 0.10)
        sig[i0:i1] += 0.35 * np.sin(2 * np.pi * freq * tt) * env
    pcm = (np.clip(sig, -1.0, 1.0) * 32767).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(pcm.tobytes())


# ---------------------------------------------------------------- 检测线程

class Detector(threading.Thread):
    """后台线程：持续读取麦克风、计算音量、判断是否触发提示音。"""

    def __init__(self, in_idx, out_idx, alert_data, alert_sr,
                 get_params, on_level, on_event):
        super().__init__(daemon=True)
        self.in_idx = in_idx
        self.out_idx = out_idx
        self.alert_data = alert_data
        self.alert_sr = alert_sr
        self.get_params = get_params
        self.on_level = on_level
        self.on_event = on_event
        self.stop_event = threading.Event()

    def run(self):
        try:
            p = self.get_params()
            sr = int(sd.query_devices(self.in_idx, "input")["default_samplerate"])
            dev_name = sd.query_devices(self.in_idx, "input")["name"]
            alert_len = len(self.alert_data) / self.alert_sr
            if p["mode"] == "rms":
                self._run_rms(sr, p, dev_name, alert_len)
            else:
                self._run_impact(sr, p, dev_name, alert_len)
        except Exception as exc:
            self.on_event(("error", f"监听出错：{exc}"))
        finally:
            self.on_event(("stopped",))

    def _run_rms(self, sr, p, dev_name, alert_len):
        """普通音量模式：整体音量超过阈值即触发。"""
        block = max(256, int(round(sr * BLOCK_MS / 1000)))
        min_frames = max(1, int(round(p["min_duration"] / BLOCK_MS)))
        rearm_frames = max(2, int(round(0.2 * 1000 / BLOCK_MS)))  # 连续安静约 0.2 秒才重新武装
        armed = True
        quiet_count = 0
        over_count = 0
        last_trigger = 0.0
        playing_until = 0.0

        self.on_event(("log", f"开始监听（普通音量模式）：{dev_name}，阈值 {p['threshold']:.0f} dB"))

        with sd.InputStream(samplerate=sr, device=self.in_idx, channels=1,
                            dtype="float32", blocksize=block) as stream:
            while not self.stop_event.is_set():
                data, _ = stream.read(block)
                p = self.get_params()
                gain = 10.0 ** (p["gain"] / 20.0)
                rms = float(np.sqrt(np.mean(data * data) + 1e-12))
                db = 20.0 * math.log10(rms) + p["gain"]
                self.on_level(db)

                now = time.monotonic()
                # 提示音播放期间忽略麦克风，避免音箱声音被麦克风听到造成“循环触发”
                if now < playing_until:
                    continue

                if not armed:
                    if db < p["threshold"] - p["hysteresis"]:
                        quiet_count += 1
                        if quiet_count >= rearm_frames:
                            armed = True
                            quiet_count = 0
                    else:
                        quiet_count = 0
                    continue

                if db >= p["threshold"]:
                    over_count += 1
                    if (over_count >= min_frames
                            and now - last_trigger >= p["cooldown"]):
                        last_trigger = now
                        playing_until = now + alert_len + 0.3
                        over_count = 0
                        armed = False
                        self.on_event(("trigger", time.time(), db))
                        try:
                            sd.play(self.alert_data, self.alert_sr,
                                    device=self.out_idx)
                        except Exception as exc:
                            self.on_event(("error", f"播放提示音失败：{exc}"))
                else:
                    over_count = 0

    def _run_impact(self, sr, p, dev_name, alert_len):
        """低音冲击模式：检测低频（45–200 Hz）能量突然高出背景基线，
        专门针对脚步踩地、硬物戳地这类低沉的冲击声。"""
        block = 1024
        fft_n = 4096
        block_sec = block / sr
        window = np.hanning(block).astype(np.float32)
        freqs = np.fft.rfftfreq(fft_n, 1.0 / sr)
        low_mask = (freqs >= 45.0) & (freqs <= 200.0)
        mid_mask = (freqs >= 300.0) & (freqs <= 2000.0)
        alpha = 1.0 - math.exp(-block_sec / 2.0)   # 背景基线自适应速度（约 2 秒）
        min_frames = max(1, int(round(p["min_duration"] / (block_sec * 1000.0))))
        rearm_frames = max(2, int(round(0.2 / block_sec)))  # 连续安静约 0.2 秒才重新武装
        baseline = None
        armed = True
        quiet_count = 0
        over_count = 0
        last_trigger = 0.0
        playing_until = 0.0

        self.on_event(("log",
                       f"开始监听（低音冲击模式）：{dev_name}，灵敏度 {p['sensitivity']:.0f} dB"))

        with sd.InputStream(samplerate=sr, device=self.in_idx, channels=1,
                            dtype="float32", blocksize=block) as stream:
            while not self.stop_event.is_set():
                data, _ = stream.read(block)
                p = self.get_params()
                spec = np.abs(np.fft.rfft(data[:, 0] * window, fft_n))
                low_rms = float(np.sqrt(np.mean(spec[low_mask] ** 2) + 1e-15))
                mid_rms = float(np.sqrt(np.mean(spec[mid_mask] ** 2) + 1e-15))
                low_db = 20.0 * math.log10(low_rms + 1e-12) + p["gain"]
                mid_db = 20.0 * math.log10(mid_rms + 1e-12) + p["gain"]
                self.on_level(low_db)

                if baseline is None:
                    baseline = low_db
                    continue

                now = time.monotonic()
                if now < playing_until:
                    continue

                dominant = low_db >= mid_db  # 低频不比中频弱（区分说话声；脚步/戳地余量很大）
                if not armed:
                    if low_db < baseline + p["sensitivity"] - 4.0:
                        quiet_count += 1
                        if quiet_count >= rearm_frames:
                            armed = True
                            quiet_count = 0
                    else:
                        quiet_count = 0
                else:
                    if low_db >= baseline + p["sensitivity"] and dominant:
                        over_count += 1
                        if (over_count >= min_frames
                                and now - last_trigger >= p["cooldown"]):
                            last_trigger = now
                            playing_until = now + alert_len + 0.3
                            over_count = 0
                            armed = False
                            self.on_event(("trigger", time.time(), low_db))
                            try:
                                sd.play(self.alert_data, self.alert_sr,
                                        device=self.out_idx)
                            except Exception as exc:
                                self.on_event(("error", f"播放提示音失败：{exc}"))
                    else:
                        over_count = 0

                # 基线自适应：平时正常跟随；触发期间以一半速度跟随，
                # 短暂冲击几乎不影响基线，持续低频声（如电器嗡嗡声）几秒后被吸收、不再反复触发
                rate = alpha * (0.5 if low_db >= baseline + p["sensitivity"] else 1.0)
                baseline += rate * (low_db - baseline)

    def stop(self):
        self.stop_event.set()
        if self.is_alive():
            self.join(timeout=2.0)
        sd.stop()


# ---------------------------------------------------------------- 主界面

class App:
    def __init__(self, root):
        self.root = root
        self.cfg = load_config()
        self.detector = None
        self.events = queue.Queue()
        self.latest_level = -99.0
        self.trigger_count = 0
        self.in_devs = {}
        self.out_devs = {}

        root.title("噪音提示工具 — 麦克风检测 → 蓝牙音箱播放")
        root.geometry("780x660")
        root.minsize(720, 600)
        root.option_add("*Font", ("Microsoft YaHei UI", 10))

        self.build_ui()
        self.refresh_devices(keep_selection=True)
        root.after(60, self.poll_events)
        root.protocol("WM_DELETE_WINDOW", self.on_close)

    # ------------------------------------------------------ 界面构建
    def build_ui(self):
        frm = ttk.Frame(self.root, padding=12)
        frm.pack(fill="both", expand=True)

        # 设备选择
        row = ttk.Frame(frm)
        row.pack(fill="x")
        ttk.Label(row, text="输入设备（无线麦克风）").pack(side="left")
        self.in_combo = ttk.Combobox(row, state="readonly", width=28)
        self.in_combo.pack(side="left", padx=(6, 16))
        ttk.Label(row, text="输出设备（蓝牙音箱）").pack(side="left")
        self.out_combo = ttk.Combobox(row, state="readonly", width=28)
        self.out_combo.pack(side="left", padx=(6, 10))
        self.refresh_btn = ttk.Button(row, text="刷新设备", command=self.refresh_devices)
        self.refresh_btn.pack(side="left")

        # 电平表
        row = ttk.Frame(frm)
        row.pack(fill="x", pady=(14, 4))
        self.meter_title = ttk.Label(row, text="低音冲击电平（45–200 Hz）")
        self.meter_title.pack(side="left")
        self.level_label = ttk.Label(row, text="-99.0 dB", width=10)
        self.level_label.pack(side="right")
        self.meter = tk.Canvas(frm, height=44, bg="#111111", highlightthickness=0)
        self.meter.pack(fill="x", pady=(0, 8))
        self.draw_meter_grid()

        # 检测模式 + 参数
        row = ttk.Frame(frm)
        row.pack(fill="x", pady=2)
        ttk.Label(row, text="检测模式").pack(side="left")
        self.mode_var = tk.StringVar(value=MODES.get(self.cfg.get("mode", "impact"), MODES["impact"]))
        self.mode_combo = ttk.Combobox(row, state="readonly", width=24,
                                       textvariable=self.mode_var,
                                       values=list(MODES.values()))
        self.mode_combo.pack(side="left", padx=(6, 16))
        self.mode_combo.bind("<<ComboboxSelected>>", lambda _: self.on_mode_change())
        self.param_frame = ttk.Frame(row)
        self.param_frame.pack(side="left", fill="x", expand=True)
        self.calibrate_btn = ttk.Button(row, text="自动校准（3 秒）", command=self.calibrate)
        self.calibrate_btn.pack(side="left", padx=(10, 0))

        self.threshold_var = tk.DoubleVar(value=float(self.cfg.get("threshold_db", -35.0)))
        self.sensitivity_var = tk.DoubleVar(value=float(self.cfg.get("sensitivity_db", 8.0)))
        self.build_param_slider()

        # 提示音文件
        row = ttk.Frame(frm)
        row.pack(fill="x", pady=6)
        ttk.Label(row, text="提示音文件").pack(side="left")
        self.alert_path_var = tk.StringVar(value=self.cfg.get("alert_file", "alert.wav"))
        entry = ttk.Entry(row, textvariable=self.alert_path_var)
        entry.pack(side="left", fill="x", expand=True, padx=10)
        ttk.Button(row, text="浏览…", command=self.browse_alert).pack(side="left")
        ttk.Button(row, text="试听", command=self.preview_alert).pack(side="left", padx=(6, 0))

        # 参数
        row = ttk.Frame(frm)
        row.pack(fill="x", pady=6)
        ttk.Label(row, text="最短持续").pack(side="left")
        self.dur_var = tk.IntVar(value=int(self.cfg.get("min_duration_ms", 150)))
        ttk.Spinbox(row, from_=50, to=2000, increment=50, width=6,
                    textvariable=self.dur_var).pack(side="left", padx=(6, 16))
        ttk.Label(row, text="触发冷却").pack(side="left")
        self.cd_var = tk.DoubleVar(value=float(self.cfg.get("cooldown_sec", 3.0)))
        ttk.Spinbox(row, from_=0.5, to=30, increment=0.5, width=6,
                    textvariable=self.cd_var).pack(side="left", padx=(6, 16))
        ttk.Label(row, text="麦克风增益").pack(side="left")
        self.gain_var = tk.DoubleVar(value=float(self.cfg.get("gain_db", 0.0)))
        ttk.Spinbox(row, from_=-30, to=30, increment=1, width=6,
                    textvariable=self.gain_var).pack(side="left", padx=(6, 0))

        # 开始/停止
        row = ttk.Frame(frm)
        row.pack(fill="x", pady=(10, 4))
        self.start_btn = ttk.Button(row, text="开始监听", command=self.start)
        self.start_btn.pack(side="left")
        ttk.Label(row, text="触发次数：").pack(side="left", padx=(20, 4))
        self.count_label = ttk.Label(row, text="0")
        self.count_label.pack(side="left")
        ttk.Label(row, text="（提示音播放期间自动忽略麦克风，避免反馈循环）",
                  foreground="#666666").pack(side="right")

        # 日志
        ttk.Label(frm, text="运行日志").pack(anchor="w", pady=(8, 2))
        self.log = tk.Text(frm, height=12, state="disabled", bg="#f7f7f7")
        self.log.pack(fill="both", expand=True)
        self.update_param_label()

    def draw_meter_grid(self):
        c = self.meter
        w = int(c["width"])
        h = int(c["height"])
        for g in range(-60, 1, 10):
            x = 10 + (g + 60) / 60.0 * (w - 20)
            c.create_line(x, 6, x, h - 12, fill="#333333")
            c.create_text(x, h - 4, text=str(g), fill="#888888", font=("Microsoft YaHei UI", 8))

    def draw_meter(self):
        c = self.meter
        c.delete("bar")
        c.delete("th")
        w = int(c["width"])
        h = int(c["height"])

        def x_of(db):
            return 10 + max(0.0, min(1.0, (db + 60) / 60.0)) * (w - 20)

        db = max(-60.0, min(0.0, self.latest_level))
        th = self.param_marker_db()
        if th is None:
            color = "#3498db"
        elif db >= th + 3:
            color = "#e74c3c"
        elif db >= th - 8:
            color = "#f39c12"
        else:
            color = "#2ecc71"
        x = x_of(db)
        c.create_rectangle(10, 6, x, h - 12, fill=color, outline="", tags="bar")
        if th is not None:
            c.create_line(x_of(th), 2, x_of(th), h - 8, fill="#ffffff", width=2, tags="th")
        self.level_label.config(text=f"{self.latest_level:.1f} dB")
        self.update_param_label()

    def is_impact(self):
        return self.mode_var.get() == MODES["impact"]

    def mode_key(self):
        return "impact" if self.is_impact() else "rms"

    def on_mode_change(self):
        d = MODE_DEFAULTS[self.mode_key()]
        if self.dur_var.get() in (80, 150):
            self.dur_var.set(d["min_duration_ms"])
        if self.cd_var.get() in (0.5, 1.0, 2.0, 3.0):
            self.cd_var.set(d["cooldown_sec"])
        self.build_param_slider()
        self.draw_meter()
        self.meter_title.config(text=("低音冲击电平（45–200 Hz）"
                                      if self.is_impact() else "环境噪音电平（全频）"))
        self.log_line(f"检测模式：{self.mode_var.get()}")

    def build_param_slider(self):
        for w in self.param_frame.winfo_children():
            w.destroy()
        if self.is_impact():
            ttk.Label(self.param_frame, text="灵敏度").pack(side="left")
            self.param_slider = ttk.Scale(self.param_frame, from_=4, to=20,
                                          variable=self.sensitivity_var,
                                          command=lambda _: self.draw_meter())
        else:
            ttk.Label(self.param_frame, text="触发阈值").pack(side="left")
            self.param_slider = ttk.Scale(self.param_frame, from_=-60, to=0,
                                          variable=self.threshold_var,
                                          command=lambda _: self.draw_meter())
        self.param_slider.pack(side="left", fill="x", expand=True, padx=10)
        self.param_label = ttk.Label(self.param_frame, width=16)
        self.param_label.pack(side="left")
        self.update_param_label()

    def param_marker_db(self):
        """电平表上的白色标记线位置（dB）。"""
        if self.is_impact():
            return None  # 冲击模式是相对背景的，不画绝对标记线
        return float(self.threshold_var.get())

    def update_param_label(self):
        if not hasattr(self, "param_label"):
            return
        if self.is_impact():
            self.param_label.config(text=f"低音超背景 {self.sensitivity_var.get():.0f} dB")
        else:
            self.param_label.config(text=f"{self.threshold_var.get():.0f} dB")

    # ------------------------------------------------------ 设备
    def refresh_devices(self, keep_selection=True):
        old_in = self.in_combo.get()
        old_out = self.out_combo.get()
        self.in_devs = list_devices("in")
        self.out_devs = list_devices("out")
        in_names = list(self.in_devs)
        out_names = list(self.out_devs)
        self.in_combo["values"] = ["（系统默认）"] + in_names
        self.out_combo["values"] = ["（系统默认）"] + out_names

        def select(combo, names, cfg_key, old):
            if keep_selection and old and old in names:
                combo.set(old)
            elif self.cfg.get(cfg_key) in names:
                combo.set(self.cfg[cfg_key])
            else:
                combo.set("（系统默认）")

        select(self.in_combo, in_names, "input_device", old_in)
        select(self.out_combo, out_names, "output_device", old_out)
        self.log_line(f"已刷新设备：{len(in_names)} 个输入，{len(out_names)} 个输出")

    def resolve_dev(self, combo, devs, cfg_key):
        name = combo.get()
        if not name or name == "（系统默认）":
            return None
        if name in devs:
            self.cfg[cfg_key] = name
            return devs[name]
        self.log_line(f"设备「{name}」当前不可用，改用系统默认")
        return None

    # ------------------------------------------------------ 操作
    def start(self):
        if self.detector is not None and self.detector.is_alive():
            return
        in_idx = self.resolve_dev(self.in_combo, self.in_devs, "input_device")
        out_idx = self.resolve_dev(self.out_combo, self.out_devs, "output_device")

        alert_path = self.alert_path_var.get().strip()
        if not alert_path:
            alert_path = DEFAULT_ALERT
        if not os.path.exists(alert_path):
            ensure_alert_wav(DEFAULT_ALERT)
            alert_path = DEFAULT_ALERT
        try:
            alert_data, alert_sr = load_wav(alert_path)
        except Exception as exc:
            messagebox.showerror("提示音文件无效", f"无法读取提示音文件：\n{exc}")
            return

        self.cfg.update({
            "input_device": self.in_combo.get(),
            "output_device": self.out_combo.get(),
            "mode": self.mode_key(),
            "sensitivity_db": self.sensitivity_var.get(),
            "threshold_db": self.threshold_var.get(),
            "cooldown_sec": self.cd_var.get(),
            "min_duration_ms": self.dur_var.get(),
            "gain_db": self.gain_var.get(),
            "alert_file": alert_path,
        })
        save_config(self.cfg)

        self.detector = Detector(
            in_idx, out_idx, alert_data, alert_sr,
            get_params=self.current_params,
            on_level=lambda db: setattr(self, "latest_level", db),
            on_event=self.events.put,
        )
        self.detector.start()
        self.set_running(True)

    def stop(self):
        if self.detector is not None:
            self.detector.stop()
            self.detector = None
        sd.stop()
        self.log_line("已停止监听")

    def current_params(self):
        return {
            "mode": self.mode_key(),
            "sensitivity": float(self.sensitivity_var.get()),
            "threshold": float(self.threshold_var.get()),
            "hysteresis": float(self.cfg.get("hysteresis_db", 6.0)),
            "cooldown": float(self.cd_var.get()),
            "min_duration": int(self.dur_var.get()),
            "gain": float(self.gain_var.get()),
        }

    def set_running(self, running):
        state = "disabled" if running else "normal"
        for w in (self.in_combo, self.out_combo, self.refresh_btn,
                  self.calibrate_btn, self.mode_combo):
            w.config(state=state)
        self.start_btn.config(text="停止监听" if running else "开始监听",
                              command=self.stop if running else self.start)
        if not running:
            self.start_btn.config(state="normal")

    def calibrate(self):
        in_idx = self.resolve_dev(self.in_combo, self.in_devs, "input_device")
        mode_key = self.mode_key()
        self.log_line("正在采样环境底噪（3 秒），请保持安静…")
        self.calibrate_btn.config(state="disabled")

        def work():
            try:
                sr = int(sd.query_devices(in_idx, "input")["default_samplerate"])
                with sd.InputStream(samplerate=sr, device=in_idx, channels=1,
                                    dtype="float32") as s:
                    data, _ = s.read(int(sr * 3))
                if mode_key == "impact":
                    block = 1024
                    fft_n = 4096
                    window = np.hanning(block).astype(np.float32)
                    freqs = np.fft.rfftfreq(fft_n, 1.0 / sr)
                    low_mask = (freqs >= 45.0) & (freqs <= 200.0)
                    dbs = []
                    for i in range(0, len(data) - block, block):
                        spec = np.abs(np.fft.rfft(data[i:i + block, 0] * window, fft_n))
                        rms = float(np.sqrt(np.mean(spec[low_mask] ** 2) + 1e-15))
                        dbs.append(20.0 * math.log10(rms + 1e-12))
                    floor = float(np.median(dbs))
                    self.events.put(("calibrated", floor, 8.0, "impact"))
                else:
                    rms = float(np.sqrt(np.mean(data * data) + 1e-12))
                    floor = 20.0 * math.log10(rms)
                    threshold = min(0.0, floor + 12.0)
                    self.events.put(("calibrated", floor, threshold, "rms"))
            except Exception as exc:
                self.events.put(("error", f"校准失败：{exc}"))
            finally:
                self.events.put(("calib_done",))

        threading.Thread(target=work, daemon=True).start()

    def browse_alert(self):
        path = filedialog.askopenfilename(
            title="选择提示音文件（WAV）",
            filetypes=[("WAV 音频", "*.wav"), ("所有文件", "*.*")],
            initialdir=BASE_DIR)
        if path:
            self.alert_path_var.set(path)

    def preview_alert(self):
        path = self.alert_path_var.get().strip()
        if not os.path.exists(path):
            ensure_alert_wav(DEFAULT_ALERT)
            path = DEFAULT_ALERT
        try:
            data, sr = load_wav(path)
            out_idx = self.resolve_dev(self.out_combo, self.out_devs, "output_device")
            sd.play(data, sr, device=out_idx)
        except Exception as exc:
            messagebox.showerror("试听失败", str(exc))

    # ------------------------------------------------------ 事件循环
    def poll_events(self):
        try:
            while True:
                kind, *args = self.events.get_nowait()
                if kind == "log":
                    self.log_line(args[0])
                elif kind == "trigger":
                    ts, db = args
                    self.trigger_count += 1
                    self.count_label.config(text=str(self.trigger_count))
                    tstr = time.strftime("%H:%M:%S", time.localtime(ts))
                    self.log_line(f"[{tstr}] 检测到噪音 {db:.1f} dB → 已播放提示音")
                elif kind == "error":
                    self.log_line("⚠ " + args[0])
                elif kind == "calibrated":
                    floor, value, m = args
                    if m == "impact":
                        self.sensitivity_var.set(value)
                        self.log_line(
                            f"校准完成：低音底噪 {floor:.1f} dB，灵敏度设为 {value:.0f} dB（可微调）")
                    else:
                        self.threshold_var.set(value)
                        self.log_line(
                            f"校准完成：环境底噪 {floor:.1f} dB，已把阈值设为 {value:.1f} dB")
                elif kind == "calib_done":
                    self.calibrate_btn.config(state="normal")
                elif kind == "stopped":
                    if self.detector is None or not self.detector.is_alive():
                        self.set_running(False)
        except queue.Empty:
            pass
        self.draw_meter()
        self.root.after(60, self.poll_events)

    def log_line(self, text):
        self.log.config(state="normal")
        self.log.insert("end", time.strftime("[%H:%M:%S] ") + text + "\n")
        self.log.see("end")
        self.log.config(state="disabled")

    def on_close(self):
        self.cfg.update({
            "input_device": self.in_combo.get(),
            "output_device": self.out_combo.get(),
            "mode": self.mode_key(),
            "sensitivity_db": self.sensitivity_var.get(),
            "threshold_db": self.threshold_var.get(),
            "cooldown_sec": self.cd_var.get(),
            "min_duration_ms": self.dur_var.get(),
            "gain_db": self.gain_var.get(),
            "alert_file": self.alert_path_var.get().strip(),
        })
        save_config(self.cfg)
        self.stop()
        self.root.destroy()


def main():
    ensure_alert_wav()
    root = tk.Tk()
    App(root)
    root.mainloop()


if __name__ == "__main__":
    main()
