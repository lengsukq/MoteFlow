import SwiftUI

struct BlackHoleDriverManagementCard: View {
    @ObservedObject var router: RemoteVirtualMicrophoneRouter
    @StateObject private var manager = BlackHoleDriverManager()
    @State private var confirmInstall = false
    @State private var confirmUninstall = false

    private var loaded: Bool {
        router.devices.contains { $0.name.localizedCaseInsensitiveContains("BlackHole 2ch") }
    }

    var body: some View {
        RemoteCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    RemoteSectionTitle(
                        title: "BlackHole 2ch · 虚拟声卡驱动管理",
                        subtitle: "仅在将遥控器麦克风接入豆包等第三方语音工具时需要；离线直接语音打字无需安装",
                        symbol: "waveform.path"
                    )
                    Spacer(minLength: 8)
                    RemoteStatusPill(
                        title: loaded ? "已加载" :
                            (manager.driverOnDisk || manager.isHomebrewInstalled ? "待激活" : "未安装"),
                        symbol: loaded ? "checkmark.circle.fill" : "circle.dotted",
                        tint: loaded ? RemotePalette.positive : RemotePalette.amber
                    )
                }

                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(RemotePalette.indigo)
                    Text(manager.statusMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Label(manager.homebrewPath == nil ? "Homebrew 未找到" : "Homebrew 可用",
                          systemImage: manager.homebrewPath == nil ? "xmark.circle" : "checkmark.circle")
                    if let version = manager.caskVersion {
                        Label("已安装 \(version)", systemImage: "shippingbox")
                    }
                    if manager.driverOnDisk {
                        Label("驱动文件存在", systemImage: "externaldrive")
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

                HStack(spacing: 9) {
                    Button {
                        manager.refresh(using: router)
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(RemoteActionButtonStyle())
                    .disabled(manager.checking)

                    if manager.canInstallWithHomebrew {
                        if !manager.isHomebrewInstalled && !loaded && !manager.driverOnDisk {
                            Button("一键安装 BlackHole 2ch", systemImage: "arrow.down.circle") {
                                confirmInstall = true
                            }
                            .buttonStyle(RemoteActionButtonStyle(emphasized: true))
                            .disabled(manager.checking)
                        } else if manager.isHomebrewInstalled {
                            Button("卸载 BlackHole 2ch", systemImage: "trash") {
                                confirmUninstall = true
                            }
                            .buttonStyle(RemoteActionButtonStyle())
                            .disabled(manager.checking)
                        }
                    } else {
                        Link("获取 Homebrew", destination: URL(string: "https://brew.sh/")!)
                    }
                    Spacer(minLength: 0)
                }

                if (loaded || manager.driverOnDisk) && !manager.isHomebrewInstalled {
                    Text("检测到系统中的驱动并非 Homebrew 管理。为避免误删其他安装来源，请使用 BlackHole 官方卸载工具。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Link("官方卸载说明", destination: URL(string: "https://github.com/ExistentialAudio/BlackHole")!)
                }
                if let message = manager.lastCommandMessage {
                    Label(message, systemImage: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(RemotePalette.indigo)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("操作会在 Terminal 中执行 Homebrew 命令，并可能请求管理员密码；MoteFlow 不读取或保存密码。安装后按提示重启，再点击「重新检测」。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            manager.refresh(using: router)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            manager.refresh(using: router)
        }
        .confirmationDialog("安装 BlackHole 2ch 虚拟音频驱动？", isPresented: $confirmInstall) {
            Button("打开终端安装") {
                manager.launch(.install, router: router)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将运行官方 Homebrew 命令：brew install --cask blackhole-2ch。安装可能需要管理员授权和重启；MoteFlow 不会静默提权。")
        }
        .confirmationDialog("卸载 BlackHole 2ch？", isPresented: $confirmUninstall) {
            Button("停止路由并打开终端卸载", role: .destructive) {
                manager.launch(.uninstall, router: router)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将停止 MoteFlow 的虚拟麦克风路由，运行 brew uninstall --cask blackhole-2ch。")
        }
    }
}

/// Streamlined UI panel for configuring push-to-talk virtual microphone routing and anti-echo protection.
struct RemoteVirtualMicrophoneSettings: View {
    @ObservedObject var router: RemoteVirtualMicrophoneRouter

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if router.outputPointedToVirtualMic {
                RemoteOutputEchoWarningBanner(router: router)
            }

            BlackHoleDriverManagementCard(router: router)

            RemoteCard {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 10) {
                        RemoteSectionTitle(
                            title: "遥控器虚拟麦克风与防回音保护",
                            subtitle: "ATVV PCM → BlackHole 输出 → 豆包麦克风输入（内置屏幕共享防回音静音）",
                            symbol: "waveform"
                        )
                        Spacer(minLength: 0)
                        Button("刷新设备", systemImage: "arrow.clockwise") {
                            router.refreshDevices()
                        }
                        .buttonStyle(RemoteActionButtonStyle())
                    }

                    if router.devices.isEmpty {
                        Label("没有发现 BlackHole 等虚拟音频驱动。若要喂给豆包语音，请先在上方一键安装 BlackHole 2ch。",
                              systemImage: "exclamationmark.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(RemotePalette.amber)
                        Link("BlackHole 官方安装说明", destination:
                                URL(string: "https://github.com/ExistentialAudio/BlackHole")!)
                            .font(.system(size: 12))
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 9)], spacing: 9) {
                            ForEach(router.devices) { device in
                                RemoteVisualOption(
                                    title: device.name,
                                    subtitle: "专用音频输出 → 同名麦克风输入",
                                    symbol: "waveform.badge.mic",
                                    selected: router.selectedUID == device.id,
                                    compact: true,
                                    action: { router.selectedUID = device.id }
                                )
                            }
                        }
                        Toggle("允许按语音键时使用虚拟麦克风（待机不占用）", isOn: $router.isEnabled)
                            .toggleStyle(.switch)
                            .disabled(router.selectedUID.isEmpty ||
                                      !router.devices.contains(where: { $0.id == router.selectedUID }))
                    }

                    Toggle("按住语音说话期间自动静音扬声器（消除 macOS 屏幕共享回音，松开即恢复）",
                           isOn: $router.suppressSpeakerEchoDuringVoice)
                        .toggleStyle(.switch)
                        .font(.system(size: 12, weight: .medium))

                    HStack(spacing: 9) {
                        Image(systemName: router.isRouting ? "waveform" : "info.circle")
                            .foregroundStyle(router.isRouting ? RemotePalette.positive : RemotePalette.indigo)
                        Text(router.status)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !router.devices.isEmpty {
                        onDemandInputSwitchBox
                    }
                }
            }
        }
    }

    private var onDemandInputSwitchBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "mic.circle")
                    .foregroundStyle(RemotePalette.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text("系统当前麦克风：\(router.systemInputName) · 当前声音输出：\(router.systemOutputName)")
                        .font(.system(size: 12, weight: .semibold))
                    Text(router.selectedIsDefaultInput
                         ? "当前系统输入正处于虚拟声卡"
                         : "平时保留原麦克风，仅在按住遥控器说话时自动临时切换到 BlackHole")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Toggle("仅在按语音键时切换到 BlackHole，松开后自动恢复原麦克风（推荐开启）",
                   isOn: $router.autoSwitchInputForVoice)
                .toggleStyle(.switch)
                .disabled(!router.isEnabled || router.selectedUID.isEmpty)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("松开语音键后，延迟恢复原麦克风")
                        .font(.system(size: 11, weight: .medium))
                    Spacer(minLength: 8)
                    Text("\(router.inputRestoreDelaySeconds, specifier: "%.2f") 秒")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(RemotePalette.indigo)
                }
                Slider(value: $router.inputRestoreDelaySeconds, in: 0...3, step: 0.25)
                    .disabled(!router.autoSwitchInputForVoice || !router.isEnabled)
                Text("默认 1 秒。松开后暂时保留 BlackHole 作为输入，让豆包完成末尾字词识别。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if router.selectedIsDefaultInput && !router.isVoiceInputTemporarilySwitched && !router.isRouting {
                Label("当前系统默认输入仍停留在 BlackHole。点击下方日常麦克风即可恢复，以免影响微信或会议软件：",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(RemotePalette.amber)
                    .fixedSize(horizontal: false, vertical: true)
                if !router.physicalInputs.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 8)], spacing: 8) {
                        ForEach(router.physicalInputs) { device in
                            RemoteVisualOption(
                                title: device.name,
                                subtitle: "恢复为空闲默认输入",
                                symbol: "mic",
                                selected: false,
                                compact: true,
                                action: { router.chooseIdleSystemInput(device.id) }
                            )
                        }
                    }
                }
            }
            Text(router.inputStatus)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RemotePalette.indigo.opacity(0.045), in: RoundedRectangle(cornerRadius: 13))
    }
}

/// Reusable alert banner whenever macOS System Output is mistakenly set to BlackHole.
struct RemoteOutputEchoWarningBanner: View {
    @ObservedObject var router: RemoteVirtualMicrophoneRouter

    var body: some View {
        RemoteCard(padding: 14) {
            HStack(spacing: 12) {
                Image(systemName: "speaker.wave.2.exclamationmark.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(RemotePalette.amber)
                VStack(alignment: .leading, spacing: 3) {
                    Text("检测到系统「声音输出」误设为了 \(router.systemOutputName)")
                        .font(.system(size: 13, weight: .bold))
                    Text("这会导致「屏幕共享」把你对着遥控器说的话当成电脑外放传回另一台 Mac 产生回音！BlackHole 只需作为麦克风输入，声音输出应切回扬声器。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("一键切回扬声器") {
                    router.switchDefaultOutputAwayFromVirtualMic()
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
    }
}
