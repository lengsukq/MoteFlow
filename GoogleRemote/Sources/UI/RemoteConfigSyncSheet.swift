import SwiftUI

/// Unified, reusable confirmation sheet for Merge vs. Overwrite configuration
/// sync or backup restoration—shared across Dual-Mac Sync and Local Backup Import
/// to eliminate duplicate confirmation dialog code.
struct RemoteConfigSyncStrategySheet: View {
    let title: String
    let sourceLabel: String
    let summaryDetail: String
    var preselectedStrategy: RemoteConfigSyncStrategy = .merge
    let onConfirm: (RemoteConfigSyncStrategy) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: RemoteConfigSyncStrategy = .merge

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(RemotePalette.indigo, in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("数据来源：\(sourceLabel) · \(summaryDetail)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }

            VStack(spacing: 10) {
                RemoteVisualOption(
                    title: "合并补全（推荐 · 不改动本机已有按键）",
                    subtitle: "只填补本机尚未配置的空按键，并导入新的命名方案与动作库条目",
                    symbol: "arrow.down.doc",
                    selected: chosen == .merge,
                    action: { chosen = .merge }
                )

                RemoteVisualOption(
                    title: "完整覆盖（两台电脑完全一致 · 自动创建保护快照）",
                    subtitle: "用导入配置替换本机按键方案；覆盖前会自动备份当前配置，随时可一键回滚",
                    symbol: "square.stack.3d.down.right",
                    selected: chosen == .overwrite,
                    action: { chosen = .overwrite }
                )
            }

            HStack(spacing: 10) {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(RemoteActionButtonStyle())

                Button {
                    let selected = chosen
                    dismiss()
                    onConfirm(selected)
                } label: {
                    Label(
                        chosen == .merge ? "执行合并补全" : "自动备份并执行覆盖",
                        systemImage: chosen == .merge ? "checkmark.circle.fill" : "exclamationmark.arrow.triangle.2.circlepath"
                    )
                }
                .buttonStyle(RemoteActionButtonStyle(emphasized: true))
            }
        }
        .padding(22)
        .frame(width: 490)
        .onAppear {
            chosen = preselectedStrategy
        }
    }
}
