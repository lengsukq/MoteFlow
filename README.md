<p align="center">
  <img src="GoogleRemote/Assets.xcassets/AppIcon.appiconset/mote-flow-256.png" width="112" alt="MoteFlow icon" />
</p>

<h1 align="center">MoteFlow</h1>
<p align="center"><strong>让遥控器，成为你的 Mac 快捷控制台。</strong></p>
<p align="center">Native macOS remote control · Key mapping · Voice input · Automation</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-202433?style=flat-square&logo=apple" />
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-F05138?style=flat-square&logo=swift&logoColor=white" />
  <img alt="SwiftUI" src="https://img.shields.io/badge/UI-SwiftUI-5B61F6?style=flat-square" />
  <img alt="Development status" src="https://img.shields.io/badge/status-active%20development-4B93D5?style=flat-square" />
  <img alt="Google remote voice tested" src="https://img.shields.io/badge/Google%20ATVV-voice%20tested-237B71?style=flat-square" />
</p>

<p align="center">
  <a href="#功能亮点">功能亮点</a> ·
  <a href="#支持的遥控器">设备支持</a> ·
  <a href="#快速开始">快速开始</a> ·
  <a href="#语音输入">语音输入</a> ·
  <a href="#语音故障排查">故障排查</a> ·
  <a href="#开发与测试">开发与测试</a>
</p>

---

MoteFlow 是一款 **纯原生 Swift / SwiftUI macOS 应用**：将支持的蓝牙遥控器映射成键盘快捷键、应用启动器与可复用动作，也能通过虚拟麦克风将 Google 遥控器语音送给 Mac 应用。无需 WebView、Electron 或云端控制后台。

> **实测进展（2026-11-06）：** Google Chromecast Voice Remote → ATVV → BlackHole 2ch → 豆包的语音输入链路，已在项目使用者的 Mac 上实测打通。此结论仅代表该套设备和环境；其他 macOS 版本、Google 遥控器固件及第三方 App 尚未做兼容性矩阵验证。项目仍在开发中，小米遥控器 2 / 2 Pro **未完成实机语音适配**。

## 功能亮点

| 可视化遥控器 | 自由绑定快捷键 |
| :--- | :--- |
| 使用可点击的遥控器图示测试高亮、配置单击与长按。Google 和小米拥有独立布局与配置。 | 支持单键、组合键以及左右 Command / Option / Control / Shift；可以录制或用可视化键盘设置。 |
| **统一动作库** | **ATVV 语音与虚拟麦克风** |
| 将「打开应用、发送快捷键、执行脚本、等待」组合成可复用动作。 | Google 遥控器的 ATVV 接收、PCM 解码与 BlackHole 2ch → 豆包语音输入已在一套真实环境下验证。 |
| **多设备预设** | **菜单栏轻量运行** |
| 不同型号分别保存动作；支持已知 HID 匹配、高级学习和 JSON 备份。 | 收起主窗口后继续监听，菜单栏可查看状态、暂停动作、重新打开设置。 |


## 支持的遥控器

| 设备 | 图形化按键图 | HID 按键 | BLE / 语音 |
| :-- | :--: | :-- | :-- |
| **Google Chromecast Voice Remote (G9N9N)** | ✅ | 已有真机映射；部分特殊键可能由系统接管 | **ATVV → BlackHole 2ch → 豆包实测通过（2026-11-06，单环境）** |
| **小米蓝牙遥控器 2 (RC001)** | ✅ | VID/PID 识别、标准 HID Usage 候选；**待实机确认** | **待验证** |
| **小米蓝牙遥控器 2 Pro (RC003)** | ✅ | 独立预设与候选码；**待实机确认** | **待验证** |
| **通用遥控器** | ✅ | 提供布局及高级学习入口；不自动接管未知设备 | 依具体硬件协议 |

**注意：** 蓝牙连接成功不代表 macOS 已注册 HID；预设识别也不等于该固件所有按键都可用。未知键需要真实日志与设备适配。

## 快速开始

### 系统要求

- macOS **14 Sonoma 或更新版本**
- Xcode（可编译 SwiftUI macOS 工程；建议使用适配本机 macOS 的版本）
- 支持的蓝牙遥控器，或先在图形预览中体验绑定流程
- 需要实体 HID 监听时，授权 **系统设置 → 隐私与安全性 → 输入监控**；执行键盘快捷动作可能还需要**辅助功能**权限

### 从源码运行

```bash
git clone https://github.com/lengsukq/MoteFlow.git
cd MoteFlow
open GoogleRemote.xcodeproj
```

打开 Xcode 后选择 **GoogleRemote** Scheme 构建运行（旧工程名为兼容历史配置而保留；最终 App 显示为 **MoteFlow**）。

命令行仅编译检查：

```bash
xcodebuild -project GoogleRemote.xcodeproj \
  -scheme GoogleRemote -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

使用你的 Apple Developer Team ID 签名并安装到 `~/Applications`：

```bash
MOTEFLOW_DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  bash scripts/install_signed_mac.command
```

> 默认只提供源代码，不保证有预编译的二进制安装包。签名、蓝牙及输入监控授权与用户本机环境有关。

### 第一次使用

1. 在 macOS 蓝牙设置中配对遥控器，打开 MoteFlow 的「遥控器 → 连接设备」确认状态。
2. 从内置 **Google / 小米 2 / 小米 2 Pro / 通用** 图形预设中选择对应型号。匹配到可信 HID 设备时会自动切换。
3. 进入「按键测试」按实体键核对高亮；未匹配的键在「诊断 / 高级学习」中采集真实报告。
4. 在「按键配置」给**单击**或**长按**绑定快捷键、应用或动作库模板。普通长按快捷键可选择「固定时长」或「跟随实体按住」：后者超过长按判定阈值后开始按住 Mac 目标键，松开实体键立即释放（支持单步骤键盘动作库）。**Delete、方向键等普通键在保持按住时主动发送 macOS 自动重复按键事件**，速度跟随系统键盘重复设置；带 Command / Option / Control 的快捷键不会自动重复，以免持续触发系统操作。很短的按下/松开会按单击触发，连续快速单击通过有界队列逐一执行，不会因上一条快捷键尚未结束而直接丢弃。需要时再打开实体按键执行开关。
5. 在「设置」启用菜单栏轻量模式，可将窗口收起，不必保持控制台始终显示。

## 语音输入

MoteFlow 的语音功能分为两个独立环节：

```mermaid
flowchart LR
    A["遥控器 ATVV 音频"] --> B["BLE 接收 / PCM 解码"]
    B --> C["BlackHole 2ch 虚拟麦克风"]
    C --> D["豆包 / 其他选择该麦克风的 App"]
    A -. "语音键事件" .-> E["已绑定快捷键"]
    E -. "唤起听写" .-> D
```

**仅触发听写快捷键不会传输遥控器声音。** 要让豆包等应用听见遥控器，必须同时完成遥控器音频采集、PCM 解码、虚拟设备输出与目标应用输入选择。上述链路已在一台 Mac 上实测打通，**不等同于所有设备/应用都已经验收**。

### 按需使用语音（推荐）

1. **连接与监听：** 配对 Google 遥控器，在「语音」页面连接 ATVV 并启用语音键监听；核对协议协商与按键触发状态。
2. **准备虚拟设备：** 安装 [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole)，进入「语音 → 麦克风设备」，刷新设备并选中 BlackHole 2ch，开启实时路由。
3. **配置自动切换：** 点击「一键启用按需语音输入」，保持「仅在按语音键时切换到 BlackHole」开启。空闲时系统默认输入应是 MacBook Pro 麦克风或你平时使用的实体麦克风。
4. **配置豆包：** 让豆包跟随 macOS 系统默认输入，或者在语音会话期间使用 BlackHole 2ch；另将遥控器语音键绑定到豆包的语音输入快捷动作。
5. **实测：** 按下并说话，观察语音诊断的 ATVV 音频、PCM 解码与 CoreAudio 输出状态，再以豆包实际识别结果确认链路工作；松开后应停止遥控器音频采集，并恢复平时的系统麦克风。

### 按键与设备的生命周期

| 阶段 | 实际行为 |
| :-- | :-- |
| **待机** | 保留 ATVV Audio / Control 的**被动 BLE 通知订阅**，为能力协商做准备；**不代表麦克风正在采集**，也不向 BlackHole 输送语音。 |
| **按下语音键** | 收到 START_SEARCH 后发送 MIC_OPEN；收到 AUDIO_START 才进入真实录音，解码 ATVV ADPCM 并送入 BlackHole 输出队列，按设置临时选择虚拟麦克风。 |
| **松开 / 音频结束** | 关闭本次音频会话、释放 AudioQueue；如启用自动切换，默认**延迟 1 秒**恢复原实体输入，以便输入法处理末尾语音。可在设置中调整为 **0–3 秒**；再次按键会取消待执行的恢复。 |
| **停用语音监听 / 断开** | 关闭 ATVV 监听并立即执行输入恢复流程；如果原设备已断开或用户另行切换了输入设备，不强行覆盖当前设置。 |

**与早期版本的区别：** 不能为了「待机不占用麦克风」而关闭 ATVV Audio 的 BLE 通知；部分固件需要 Audio 和 Control 通知都已订阅才能完成 GET_CAPS / MIC_OPEN。真正需要关闭的是麦克风采集与 CoreAudio 输出，而不是协议就绪订阅。另外，过早的 AUDIO_STOP 或重复 START_SEARCH 不应直接取消刚开始的语音会话。

### 语音故障排查

| 现象 | 检查与处理 |
| :-- | :-- |
| 豆包被唤起，但没有语音 | 进入「语音链路诊断」核对 AUDIO_START、音频包数、解码帧、PCM 入队与 CoreAudio 是否启动。快捷键触发成功**不代表**声音送达豆包。 |
| 音频包一直为零 | 核对 ATVV Audio / Control 通知与 GET_CAPS、MIC_OPEN 的先后顺序；不要把待机的被动音频通知误当作占用而关闭。 |
| PCM 已提交，豆包仍无声 | 核对 BlackHole 路由开关、CoreAudio 输出状态，以及豆包实际使用的麦克风；部分应用会**自行锁定输入设备**，不会跟随 macOS 默认输入改变。 |
| 松开后系统仍默认 BlackHole | 打开「语音 → 麦克风设备」，将**空闲麦克风**选回 MacBook Pro 麦克风或其他实体设备，再启用按需切换。新版本会尝试识别旧配置遗留的 BlackHole 默认输入并恢复实体设备，但无法安全确认目标时需要人工选择。 |
| 第一次按下立刻停止 / 长按中断 | 检查 ATVV 控制日志中是否出现过期 AUDIO_STOP 或重复 START_SEARCH；当前逻辑不将其直接视为有效停止。仅长按已建立的录音会话才应受有效停止指令控制。 |
| 频繁按键时音频设备来回跳 | 调整「松开后延迟恢复」到合适值（默认 1 秒），下一次按键会取消尚未执行的输入恢复。 |

> **验收边界：** 2026-11-06 的成功结论来自项目使用者在真实 Google 遥控器、Mac 和豆包环境下的手动测试。自动化测试可以验证数据帧、映射与状态策略，但无法代替不同版本 macOS、蓝牙固件、系统权限以及第三方输入法的端到端验证。请勿把诊断中「PCM 入队」单独解读成豆包一定已接收到声音。

## 开发与测试

| 组件 | 技术 |
| :-- | :-- |
| 界面和菜单栏 | SwiftUI、AppKit |
| 蓝牙及 ATVV | CoreBluetooth、ADPCM 解码 |
| 按键采样 | IOKit / IOHIDManager |
| 快捷键与动作 | CoreGraphics、原生进程 |
| 音频路由 | CoreAudio AudioQueue、BlackHole |
| 自动测试 | Swift Package Manager / XCTest |

```bash
swift test
```

当前代码包含协议处理、按键映射、设备预设、动作库和 PCM 转换的测试。**单元测试通过不等同于 HID 独占、音频设备切换或实体遥控器端到端验收通过。**

### 项目结构

```text
GoogleRemote/
  Assets.xcassets/       AppIcon、菜单栏图标与品牌资源
  Sources/              SwiftUI、蓝牙、HID、音频及动作执行
GoogleRemote.xcodeproj/ Xcode macOS App 工程
Tests/                  Swift Package Manager 测试
scripts/                图标生成与签名安装脚本
docs/                   公开的设备预设、HID 学习及品牌文档
Package.swift           可独立测试的协议/映射核心
```

更多细节：
[遥控器型号与适配边界](docs/REMOTE-PROFILES.md) ·
[HID 学习与映射导入](docs/HID-MAPPING-PROFILES.md) ·
[品牌与图标](docs/BRANDING.md)

## 安全与隐私

- 仅对识别并允许的 HID 遥控器接口尝试独占，避免误接管 Mac 键盘与鼠标。
- 本机学习结果、按键动作配置默认存放在用户本机；日志和 WAV 由用户主动导出。
- 录音文件转写请求使用支持的 macOS 本机识别模式，不自动回退在线识别。
- 脚本执行、系统权限、BlackHole 安装或卸载需要用户主动配置/确认。

## 路线图

- [x] 原生 macOS 控制台、图形化快捷键和动作库
- [x] Google G9N9N HID 默认映射和 ATVV 接收代码
- [x] 小米 RC001 / RC003 图示和设备预设隔离
- [x] BlackHole 设备管理与 PCM 路由代码
- [x] 菜单栏轻量模式
- [ ] 小米遥控器 2 / 2 Pro 实体 HID 与语音通道验收
- [x] Google 遥控器 → ATVV → BlackHole 2ch → 豆包语音输入单环境实测（2026-11-06）
- [ ] 其他 Mac / macOS 版本、遥控器固件及第三方语音应用兼容性验收
- [ ] 休眠唤醒、蓝牙重连和长时间轻量模式稳定性验收
- [ ] 完整的安装发布、设备兼容性测试矩阵

---

<p align="center">
  <strong>MoteFlow</strong> — One remote. More possibilities.
</p>

<p align="center">
  本项目不是 Google、小米、豆包或 BlackHole 官方产品，与上述品牌无隶属关系。
</p>

**许可说明：** 当前代码库未附开源许可证。公开可见不等于自动授予复制、修改或商业使用权限；若后续计划开放使用，请由项目所有者明确选择并添加许可证。
