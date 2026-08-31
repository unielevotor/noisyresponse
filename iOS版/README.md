# 噪音提示工具（iOS 版）

与 PC 版（`../noise_alert.py`）同一套检测算法的 iPhone 应用，SwiftUI 编写。默认**低音冲击模式**：通过麦克风实时分析 45–200 Hz 低频能量，检测脚步踩地、硬物戳地这类低沉冲击声，检测到后在当前输出设备（连接蓝牙音箱后即为音箱）播放提示音。

## 文件结构

```
iOS版/
├── project.yml                      # XcodeGen 工程定义（生成 .xcodeproj）
├── NoiseAlert/
│   ├── NoiseAlertApp.swift          # 应用入口
│   ├── ContentView.swift            # SwiftUI 界面
│   ├── ImpactDetector.swift         # 音频引擎 + FFT 检测 + 提示音合成
│   ├── Info.plist                   # 麦克风权限、后台音频
│   └── Assets.xcassets              # 应用图标 / 主题色占位
└── README.md
```

## 为什么需要 Mac？

iOS 应用只能在 macOS 上用 Xcode 编译、签名、安装到真机。Windows 上无法直接构建，本目录提供的是完整源码工程，在 Mac 上按下面步骤即可运行。

## 构建步骤（Mac + Xcode 15+）

方式一（推荐）：使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成工程

```bash
brew install xcodegen
cd "iOS版"
xcodegen generate
open NoiseAlert.xcodeproj
```

方式二（不用 XcodeGen）：Xcode → File → New → Project → iOS → App（SwiftUI），把 `NoiseAlert/` 下的 `.swift` 文件拖入工程，再把 `Info.plist` 设为工程的 Info.plist，并加入 `Assets.xcassets`。

然后：

1. 在 Xcode 中打开工程，选择 `NoiseAlert` target → Signing & Capabilities。
2. 选择你的开发者账号（Team）；如果 `com.example.NoiseAlert` 被占用，改成你自己的 Bundle ID。
3. 用数据线连接 iPhone，在顶部设备栏选择真机（**模拟器没有麦克风，无法测试**）。
4. 点 Run。首次启动会请求麦克风权限，允许即可。

## 零 Mac 部署（GitHub Actions + Sideloadly）

不买 Mac、不装 Xcode，也能编译并装到你的 iPhone 上，分三步：云端编译 → Windows 签安装装。

### 第 1 步：把工程推到 GitHub

1. 建一个 GitHub 仓库（建议设为**公开**，这样 macOS 构建机免费；源码不敏感即可）。
2. 把整个项目（含 `iOS版/`、`web版/`、PC 版源码、`.github/`）推到仓库根目录。
3. 仓库根目录已带 `.github/workflows/build-ios.yml`（会自动进入 `iOS版/` 编译），无需改动。

### 第 2 步：在 GitHub 上编译出 IPA

1. 打开仓库 → Actions 标签页。
2. 左侧选中 **Build iOS IPA**，右侧点 **Run workflow**（手动触发）。
3. 等约几分钟，跑完后在结果页面下载名为 `NoiseAlert-ipa` 的构建产物（一个 `.ipa` 文件）。

### 第 3 步：用 Sideloadly 签名安装到 iPhone（Windows）

1. 在 Windows 上安装 [Sideloadly](https://sideloadly.io)。
2. 数据线连接 iPhone，信任此电脑。
3. iPhone 上开启「开发者模式」：设置 → 隐私与安全性 → 开发者模式 → 打开并重启。
4. 打开 Sideloadly，拖入下载的 `NoiseAlert.ipa`，填写你的 Apple ID 账号（若开了双重验证，用 App 专用密码），点安装。
5. 安装后，在 iPhone 上首次打开时到「设置 → 通用 → VPN 与设备管理」里信任你的开发者证书。
6. 首次进入 App 权限麦克风即可。

### 签名有效期与续期

- 免费 Apple ID 签名的应用 **7 天后过期**：到时重连 iPhone，用 Sideloadly 重新安装一次即可续期。
- 交 $99/年 Apple Developer 会员后，签名有效期 1 年，且可使用 TestFlight 等正式分发方式。

> 温馨提示：iOS 应用必须实名/开发者账号签名；直插 iPhone 的领夹麦接收器若占用音频输出路由，提示音可能不走蓝牙音箱，可在 App 里观察或改回手机自带麦。

## 功能

- 两种检测模式：**低音冲击**（默认，抓脚步/敲击，过滤说话声）和**普通音量**
- 自适应背景基线：安静环境下轻轻的“咚”也能触发，空调等持续声音几秒后被吸收
- 灵敏度 / 最短持续 / 触发冷却 / 麦克风增益实时可调
- 4 种内置提示音（叮咚、蜂鸣、短促滴、钟琴），内存合成、无需音频文件
- 提示音播放期间自动忽略麦克风，防循环；来电等音频中断后自动恢复
- 触发次数、运行日志、实时电平条
- 后台音频模式：锁屏/切后台后仍可继续监听（会持续耗电，注意电量）

## 参数说明

| 参数 | 含义 |
| --- | --- |
| 检测模式 | 低音冲击（默认）或普通音量 |
| 灵敏度 | 低音能量高出环境背景多少 dB 触发，4–20 dB，越小越灵敏 |
| 触发阈值 | 普通音量模式下整体音量的触发线（-60～0 dB） |
| 最短持续 | 声音需持续超过该时长才触发，默认 80ms |
| 触发冷却 | 两次触发最小间隔，默认 0.5 秒 |
| 麦克风增益 | 麦克风声音偏小/偏大时补偿，±30 dB |

## 使用技巧

- 麦克风尽量**贴近地面或靠近声源**：脚步的“咚咚”主要是地板振动，贴近地面灵敏度明显更高。
- 说话声基本不会误报（低频主导判定 + 自适应背景）；若误报，调高灵敏度。
- 蓝牙音箱请先与 iPhone 配对，并在控制中心/系统设置里把音频输出切到音箱。

## 已知限制

- 提示音目前为内置合成音。后续版本可加入从“文件”App 导入自定义 WAV 的功能。
- 后台持续监听会明显增加耗电；长时间无人时可手动停止。
- 应用商店审核对后台麦克风使用有额外要求，本项目按个人真机调试使用设计。
