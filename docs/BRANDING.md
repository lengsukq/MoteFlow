# MoteFlow · 品牌与 App 图标

## 命名

**MoteFlow**（遥控工作台）：Mote 取自 remote，Flow 表示快捷动作、语音输入与自动化的流转。名称不绑定某一遥控器品牌，因此未来可兼容其他蓝牙输入设备。

用户可见位置统一使用 `MoteFlow`：主窗口标题、侧边栏、菜单栏和 Finder/Dock 的 App 名称。设备型号与协议中的 Google TV、ATVV 保留原始技术名称，避免引起误解。

## 图标

- 主图标：圆角紫蓝背景、青色流线、白色遥控器与无线信号；用于 Finder、Dock、启动器及系统权限窗口。
- 页面标志：与 AppIcon 同源的小图，资源名 `MoteFlowMark`。
- 菜单栏：无彩色背景的单色模板，资源名 `MoteFlowStatusIcon`，支持系统菜单栏明暗主题。
- 高分辨率 AppIcon：16、32、128、256、512 pt 的 1x / 2x PNG，最高 1024 × 1024，编译为 `Assets.car`。源文件位于 `GoogleRemote/Assets.xcassets/`。
- 重生成命令：`python3 scripts/generate_brand_assets.py`。只依赖系统 AppKit/Quartz，不下载字体或第三方图标。

## 构建与旧版本

原有 Xcode target / scheme 仍叫 `GoogleRemote`，兼容现有自动化脚本；签名产物改为 `MoteFlow.app`，`CFBundleDisplayName = MoteFlow`，`CFBundleIconName = AppIcon`。

**保留旧 Bundle ID `app.google-remote.mac`**，尽量避免重置已有的蓝牙与输入监控系统授权和本机用户数据。用户未来想改产品包标识时，需另行规划授权迁移。

默认安装路径：`~/Applications/MoteFlow.app`。开发者可运行 `MOTEFLOW_DEVELOPMENT_TEAM=你的开发团队ID bash scripts/install_signed_mac.command` 构建并安装签名版本。仓库不包括开发机器上的旧版迁移工具；如曾使用旧名安装，请先完全退出旧进程，再打开新 App。

真实 Finder/Dock 图标需要检查已启动 App 与 LaunchServices 资源缓存；若图标没有更新，先完全退出旧进程，再打开 `MoteFlow.app`。
