# MoteFlow · 多遥控器设备预设

## 已内置设备

| 预设 | 型号证据与候选识别 | 图示 | HID / 语音状态 |
|---|---|---|---|
| Google Chromecast Voice Remote | G9N9N / 已有真机匹配 | 白色遥控器、侧面音量与 YouTube/Netflix 键 | 现有 Google HID 2 字节报告与 ATVV 不变 |
| 小米蓝牙遥控器 2 | RC001；VID `0x2717` / PID `0x32B8` | 深灰遥控器、上方电源/语音、方向圆盘、返回/主页/菜单/音量/TV | **新增**标准 HID Keyboard/Consumer Usage 试配；需要实机确认语音 |
| 小米蓝牙遥控器 2 Pro | RC003；候选 VID `0x2717` / PID `0x32B0` | 深灰同系列示意图，独立预设数据 | **新增**候选设备识别；ATVV 及 HID 报告需要对应固件真机验证 |
| 通用遥控器 | 未知型号，手动预览 | 通用简化遥控器示意 | 不会自动独占或猜测 HID 码；必须先建立受信任的硬件适配 |

*重要：RC001 与 RC003 不可混成一个硬件型号；以上小米 VID/PID、使用码来自公开项目的参考实现，不代表本机已完成验证。*

参考：

- https://github.com/wyuzhi/MiVibe-Remote ：小米蓝牙遥控器 2（README 中报告 RC001，VID `2717` PID `32B8`）；
- https://github.com/dmq1219/VibeRemote ：另一小米遥控器参考实现（VID `2717` PID `32B0`）；
- https://github.com/fanxeon/mi-ao ：RC003 / 小米 2 Pro 的 BLE ATVV 16 kHz ADPCM 方案和真机信息；
- https://github.com/godarrenw/mi_remote_control/blob/main/DESIGN.md ：小米远程控制按键与标准 HID usage 候选；
- https://www.mi.com/service/mitv/firstuse ：小米电视/盒子蓝牙遥控器配对指引（通常主页+菜单长按）。

不复制其他仓库的 GPL 代码，只引用公开硬件参数与行为描述；MoteFlow 的型号资料、SwiftUI 可交互图形和使用码映射为独立实现。

## 默认初始化

打开「遥控器」页面即可选择四套图形化内置预设。在已获准的系统 HID 候选唯一、且设备 VID/PID 被严格识别时，会自动选中对应型号。没有硬件时可纯 UI 预览。

首次选择小米 2/2 Pro 时**仅初始化该型号自己的动作模板**：

- 方向盘：上/下/左/右 → Mac 对应方向键；
- OK → Return；返回 → Esc；
- 主页 → 动作库内置的「ChatGPT · 打开并聚焦输入栏」；
- 语音、电源、音量、菜单、TV 等预留为可编辑动作，不假装已验证原始硬件码。

这些预设只保存动作，不自动启用「允许实体按键执行绑定动作」。原有 Google 按键和语音快捷键不会被覆盖。首次迁移从 `GoogleRemote.keyBindings.v1` 读取旧资料，新模型数据独立持久化为 `MoteFlow.remoteModels.v1`，当前选择保存在 `MoteFlow.selectedRemoteModel.v1`。重置某个模型后再次切换不会自动重建已清除的数据。

## 新的硬件接入边界

1. `RemoteDeviceProfileRegistry.identify`：只匹配严格已知的小米 VID/PID，拒绝名字含 keyboard/mouse/trackpad 的设备。无法识别的普通 Mac 输入设备不能被独占。
2. `SystemHIDProbe`：枚举所有候选，但只有安全的模型才会被列为可独占。存在多个接口且无法确定目标时，自动捕获不会任选一个，用户在高级诊断里核对。
3. `HIDCaptureManager`：已有 Google 用独立 2 字节 report 解码；小米则尝试读取标准键盘页 0x07、消费者控制页 0x0C 的 HID Value。两套解析不混用。小米语音 F5 候选和 BLE ATVV 共享开始/结束状态防止重复触发。
4. 物理按键 → 动作执行前检查当前实际接管的 HID 身份与页面所选模型相符。若用户正在预览另一款遥控器，不会把已连接设备的按钮错误地映射到其他模型动作。
5. 小米默认码是**候选标准 HID Usage**，不是已真实采样的 RC001/RC003 原始 Report；固件差异可能导致只有部分键能识别。未匹配的键保持日志可见，可在高级诊断中收集数据。
6. BLE 麦克风与 HID 是两条不同链路。现有 ATVV / BlackHole 路由能够用于符合相同协议的设备，但没有小米实机就不能承诺语音端到端可用。

## 验收步骤

1. 用「遥控器预设」在 Google 与小米 2 之间切换：遥控器 SVG 风格图示应不同，Google 原来的所有快捷键应仍在，小米动作只在小米存储空间生效。
2. 未连接设备时点击小米示意图：仅切换选中与高亮，不得执行真实动作。检查菜单、TV、音量按键可独立选择。
3. 实体小米 RC001 连接 Mac 后，核对 HID 枚举结果确实是厂商 `0x2717` / 产品 `0x32B8`；确认「输入监控」授权；只有安全候选才能启动独占。
4. 按方向键、OK、返回、主页、菜单、音量、语音并查看原始事件与高亮；验证当前 HID 码表是否与固件吻合。未知码留待补充，而不是把图示点击当作实机成功。
5. 打开语音页，验证小米型号是否实际暴露兼容的 ATVV GATT 服务与控制通知，再测试 PCM → BlackHole → 豆包的完整链路。未验证之前不可标注「语音已完整适配」。
6. 检查切换模型后恢复、应用重启后的持久化、关闭窗口轻量模式的监听，以及设备断线后不持续按住合成快捷键。

自动测试覆盖模型识别、识别拒绝条件、小米候选 HID usage、默认动作初始化、跨型号独立持久化和旧 Google 数据迁移。Xcode 构建仅证明工程可编译，实机 HID/ATVV 验收另行记录。
