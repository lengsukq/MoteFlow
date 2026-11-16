# AGENTS.md — MoteFlow (Google-remote) 架构与协作契约

本文档定义了 MoteFlow 项目的模块分层边界、Clean Code 护栏、UI/UX 设计准则及本地构建验证规范。任何功能新增或重构必须严格遵守以下约束。

## 1. 模块分层与单向依赖规则

所有源码位于 `GoogleRemote/Sources/` 下，按职责划分为五大目录，依赖方向严格自上而下（禁止反向引用）：

- **`Core/`（纯领域模型与协议层）**
  - 包含精简 4 类绑定模型（`none` / `keyboardShortcut` / `systemAction` / `libraryAction`，兼容解码旧版 `script` 与 `voiceInput`）、设备 Profile、绑定与动作库持久化 Store、统一全量备份（含自定义硬件码 `learnedHIDProfile` 与旧版硬件码文件升级）、HID 报文解码、ATVV 音频解码、局域网帧协议及显式状态机 `VoiceSessionStateMachine`。
  - **强约束**：严禁 `import SwiftUI`、`import AppKit`、`import CoreBluetooth`、`import CoreAudio` 或 `import IOKit`。所有新增到 `Core/` 的文件自动纳入 `Package.swift` 的 `ATVVCore` 目标。
- **`Hardware/`（macOS 硬件与系统能力适配层）**
  - 封装 `IOHIDManager` 持久独占捕获（默认开启按键生效 `executeHardwareActions = true`）、`CoreBluetooth` 纯粹的 ATVV 语音采集、`CoreAudio` 按需临时切换虚拟声卡（`BlackHole 2ch`）与物理扬声器防回音静音、`Speech` 本地离线识别、`CGEvent` 按键注入与全局热键监听。
  - **强约束**：禁止引用任何 SwiftUI 页面类型；禁止添加永久篡改系统默认麦克风或 `0x1812` BLE 非独占 HID 探测逻辑。
- **`Relay/`（双机局域网发现与加密中继层）**
  - 负责 Bonjour 发现、配对信任白名单、并发重连防撞仲裁、跨机按键/语音流收发与配置拉取。切换提醒统一使用免系统权限的屏幕顶部灵动胶囊（`RemoteSwitchHUDController`）加可选轻音效。
- **`Coordinator/`（应用运行时与会话编排中枢）**
  - `RemoteAppRuntime` 负责菜单栏常驻生命周期与退出清理；`RemoteSessionCoordinator` 作为唯一编排中枢连接 `Hardware`、`Relay` 与 `Core`，并在启动时自动将历史单步脚本绑定无损迁移至动作库。
- **`UI/`（设计系统、可复用组件与用户界面层）**
  - 统一使用 `RemoteDesignSystem.swift` 中的颜色、卡片、胶囊与微交互令牌；`RemoteDiagnosticsPage.swift` 统一承载硬件指标、分类筛选日志中心与折叠式未知遥控器采样。

## 2. Clean Code 文件规模与质量护栏

- **视图瘦身原则**：单个 SwiftUI 页面文件建议控制在 **350 行以内**；可复用的弹窗（如合并/覆盖同步确认 Sheet）、拓扑卡片、动作抽屉拆分为独立组件文件。
- **单一概念原则**：本地脚本统一收归「动作库」管理；配置备份统一使用单一 `RemoteConfigBackupDocument` JSON；菜单栏只保留单一「暂停 / 恢复遥控器控制」总开关；连接实体遥控器时工作台自动跟随真机型号。
- **兼容性铁律**：应用的 Bundle ID（`app.google-remote.mac`）及已有 `UserDefaults` / `Application Support` 存储键名保持向后兼容，确保老版本升级不断失 macOS TCC 权限与自定义配置。

## 3. 构建与回归验证命令

1. **核心模块编译检查**：`swift build`
2. **完整应用签名构建验证（不覆盖运行中进程）**：`MOTEFLOW_BUILD_ONLY=1 bash scripts/install_signed_mac.command`
3. **检查 Xcode 工程有效性**：确认 `GoogleRemote.xcodeproj/project.pbxproj` 通过 `plutil -lint` 校验。
