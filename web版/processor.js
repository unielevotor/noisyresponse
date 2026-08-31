// 噪音提示 —— 低音冲击检测 AudioWorklet 处理器
// 区分楼上脚步/敲击 vs 说话声：
//   - 需要低频(45-200Hz)明显强于中频(300-2000Hz)和高频(2500-8000Hz)（说话声中频更强，被拒掉）
//   - 峰值回落触发 + 最小事件间隔，避免同一声被重复计数、以及语音音节导致的误触发
// 触发策略：每记一次冲击，在 T 秒窗口内凑满 N 次才播放；播放后进入冷却清零。

const FFT_SIZE = 4096;
const BLOCK = 1024;

function fft(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      [re[i], re[j]] = [re[j], re[i]];
      [im[i], im[j]] = [im[j], im[i]];
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = -2 * Math.PI / len;
    const wRe = Math.cos(ang), wIm = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let curRe = 1, curIm = 0;
      for (let j = 0; j < len / 2; j++) {
        const uRe = re[i + j], uIm = im[i + j];
        const vRe = re[i + j + len / 2] * curRe - im[i + j + len / 2] * curIm;
        const vIm = re[i + j + len / 2] * curIm + im[i + j + len / 2] * curRe;
        re[i + j] = uRe + vRe;
        im[i + j] = uIm + vIm;
        re[i + j + len / 2] = uRe - vRe;
        im[i + j + len / 2] = uIm - vIm;
        const nr = curRe * wRe - curIm * wIm;
        curIm = curRe * wIm + curIm * wRe;
        curRe = nr;
      }
    }
  }
}

const clamp01 = (v) => Math.max(0, Math.min(1, v));

// 判定与防抖参数
const DOM_MARGIN = 4;        // 低频需比中频强这么多 dB（中频更强通常是说话声）
const HI_MARGIN = 0;         // 低频需不低于高频（抑制尖锐宽带声）
const PEAK_DROP = 6;         // 从事件峰值回落多少 dB 才算一次事件结束（防止抖动重复计数）
const EVENT_GAP = 0.15;      // 两次计数的最小间隔（秒），抑制语音音节、稳定累积

registerProcessor('impact-processor', class extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buf = new Float32Array(BLOCK);
    this.bufLen = 0;
    this.re = new Float64Array(FFT_SIZE);
    this.im = new Float64Array(FFT_SIZE);
    this.hann = new Float32Array(BLOCK);
    for (let i = 0; i < BLOCK; i++) {
      this.hann[i] = 0.5 - 0.5 * Math.cos(2 * Math.PI * i / BLOCK);
    }
    this.freqStep = sampleRate / FFT_SIZE;
    this.lowRange = this.range(45, 200);
    this.midRange = this.range(300, 2000);
    this.hiRange = this.range(2500, 8000);

    this.params = {
      mode: 'impact',
      sensitivityDb: 8,
      thresholdDb: -35,
      cooldownSec: 2,
      confirmCount: 3,
      windowSec: 4,
      gainDb: 0,
      toneDurationSec: 0.55
    };

    this.baseline = null;
    this.inEvent = false;
    this.peak = -Infinity;      // 当前事件峰值
    this.eventCount = 0;        // 当前窗口内已计冲击数（整数，不再来回递减）
    this.windowStart = 0;       // 当前计数组的起始时刻
    this.lastEventTime = -1e9;
    this.lastFireTime = -1e9;
    this.playingUntil = 0;
    this.blockCount = 0;

    this.port.onmessage = (e) => {
      const d = e.data;
      if (!d) return;
      if (d.params) this.params = Object.assign(this.params, d.params);
      if (d.reset) {
        // 重启监听时清空状态，避免旧基线/计数导致立刻误触发
        this.baseline = null;
        this.inEvent = false;
        this.peak = -Infinity;
        this.eventCount = 0;
        this.windowStart = 0;
        this.lastEventTime = -1e9;
        this.lastFireTime = -1e9;
        this.playingUntil = 0;
        this.blockCount = 0;
      }
    };
  }

  range(loHz, hiHz) {
    const lo = Math.max(0, Math.ceil(loHz / this.freqStep));
    const hi = Math.min(FFT_SIZE / 2 - 1, Math.floor(hiHz / this.freqStep));
    return [lo, hi];
  }

  process(inputs) {
    const ch = inputs[0] && inputs[0][0];
    if (!ch || ch.length === 0) return true;
    for (let i = 0; i < ch.length; i++) {
      this.buf[this.bufLen++] = ch[i];
      if (this.bufLen === BLOCK) {
        this.handleBlock();
        this.bufLen = 0;
      }
    }
    return true;
  }

  handleBlock() {
    const p = this.params;
    const now = currentTime;
    const blockSec = BLOCK / sampleRate;

    const b = this.bandDbs();
    const lowDb = b.low, midDb = b.mid, hiDb = b.hi;
    const lowE = b.lowE, midE = b.midE, hiE = b.hiE;
    let sum = 0;
    for (let i = 0; i < BLOCK; i++) sum += this.buf[i] * this.buf[i];
    const rmsDb = 20 * Math.log10(Math.sqrt(sum / BLOCK) + 1e-12) + p.gainDb;
    const db = p.mode === 'impact' ? lowDb + p.gainDb : rmsDb;
    this.blockCount++;

    // 状态指标
    const totalE = lowE + midE + hiE + 1e-12;
    const lowRatio = lowE / totalE;
    const sharp = clamp01((hiE / totalE) * 1.4);
    let score = 0;
    if (p.mode === 'impact') {
      score = clamp01((db - (this.baseline ?? db)) / 30) * clamp01((lowDb - midDb) / 20);
    } else {
      score = clamp01((db - p.thresholdDb) / 30);
    }
    if (this.blockCount % 5 === 0) {
      this.port.postMessage({
        type: 'status',
        lowDb, midDb, hiDb, lowRatio, sharp, score,
        impactCount: this.eventCount,
        confirmCount: p.confirmCount,
        mode: p.mode
      });
    }

    // 提示音播放期间忽略麦克风，避免反馈循环
    if (now < this.playingUntil) return;

    // 计数窗口超时则整组清零（固定窗口，不再来回递减）
    if (this.eventCount > 0 && now - this.windowStart > p.windowSec) {
      this.eventCount = 0;
      this.windowStart = now;
    }

    const active = p.mode === 'impact'
      ? (this.baseline !== null ? this.baseline + p.sensitivityDb : Infinity)
      : p.thresholdDb;
    const impactLike = p.mode === 'impact'
      ? (this.baseline !== null
         && (lowDb - midDb) >= DOM_MARGIN
         && (lowDb - hiDb) >= HI_MARGIN
         && lowDb > active)
      : db >= active;

    if (this.inEvent) {
      if (lowDb < this.peak - PEAK_DROP) {
        this.inEvent = false;            // 已回落，结束本次事件，准备下一次
      } else {
        this.peak = Math.max(this.peak, lowDb);
      }
    } else if (impactLike) {
      this.inEvent = true;
      this.peak = lowDb;
      // 冷却结束且距上次计数足够久，才计入；否则视为同一次或冷却中
      if (now >= this.lastFireTime + p.cooldownSec
          && now - this.lastEventTime >= EVENT_GAP) {
        if (this.eventCount === 0) this.windowStart = now;
        this.eventCount += 1;
        this.lastEventTime = now;
      }
    }

    // 触发：T 秒内凑满 N 次才播放
    if (this.eventCount >= p.confirmCount
        && now >= this.lastFireTime + p.cooldownSec) {
      this.lastFireTime = now;
      this.playingUntil = now + p.toneDurationSec + 0.3;
      const fired = this.eventCount;
      this.eventCount = 0;
      this.windowStart = now;
      this.port.postMessage({ type: 'trigger', db, mode: p.mode, count: fired });
    }

    // 背景基线自适应（仅低音模式）：触发期间半速跟随，持续声几秒后被吸收
    if (p.mode === 'impact') {
      if (this.baseline !== null) {
        const th = this.baseline + p.sensitivityDb;
        const rate = (db >= th ? 0.5 : 1.0) * (1 - Math.exp(-blockSec / 2));
        this.baseline += rate * (db - this.baseline);
      } else {
        this.baseline = db;
      }
    }
  }

  bandDbs() {
    this.re.fill(0);
    this.im.fill(0);
    for (let i = 0; i < BLOCK; i++) {
      this.re[i] = this.buf[i] * this.hann[i];
    }
    fft(this.re, this.im);

    const e = (range) => {
      let s = 0;
      for (let k = range[0]; k <= range[1]; k++) {
        s += this.re[k] * this.re[k] + this.im[k] * this.im[k];
      }
      return Math.sqrt(s / (range[1] - range[0] + 1) + 1e-15);
    };
    const lowE = e(this.lowRange);
    const midE = e(this.midRange);
    const hiE = e(this.hiRange);
    const toDb = (v) => 20 * Math.log10(v + 1e-15);
    return { low: toDb(lowE), mid: toDb(midE), hi: toDb(hiE), lowE, midE, hiE };
  }
});
