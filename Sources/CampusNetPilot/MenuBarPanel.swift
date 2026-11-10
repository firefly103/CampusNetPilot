import SwiftUI
import AppKit
import CampusNetCore

struct MenuBarPanel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            if let blocker = model.blockerExplanation {
                VStack(alignment: .leading, spacing: 4) {
                    Text(blocker)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.permissionLikelyMissing {
                        Button("打开「定位服务」设置") { model.openLocationPrivacySettings() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            if !model.isConfigured {
                Text("尚未配置校园 Wi-Fi SSID 与认证账号：不会对任何网络提交认证。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Toggle(isOn: Binding(
                    get: { model.config.autoAuthEnabled },
                    set: { model.config.autoAuthEnabled = $0; model.applyConfig() }
                )) {
                    Text("自动认证").font(.callout)
                }
                Toggle(isOn: Binding(
                    get: { model.config.scheduledScanEnabled },
                    set: { model.config.scheduledScanEnabled = $0; model.applyConfig() }
                )) {
                    Text("连接校园网时定时查找宿舍 Wi-Fi").font(.callout)
                }
                .disabled(!model.config.hasDormTargets)
            }

            Divider()

            HStack(spacing: 8) {
                Button("重新判断") { model.reevaluate() }
                Button("设置…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("退出") { model.quit() }
            }
            .controlSize(.small)

            Divider()

            Text("最近日志")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if model.logs.isEmpty {
                        Text("暂无日志").font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(model.logs.suffix(25)) { entry in
                        HStack(alignment: .top, spacing: 5) {
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(entry.level.symbol)
                                .font(.caption2)
                                .foregroundStyle(color(for: entry.level))
                            Text(entry.message)
                                .font(.caption2)
                                .lineLimit(2)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
        }
        .padding(12)
        .frame(width: 350)
        .onAppear { model.refreshLogs() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: model.menuBarSymbol)
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.status.phase.displayName)
                    .font(.headline)
                Text(model.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if model.status.lidClosed { parts.append("合盖") }
        if model.status.sleeping { parts.append("睡眠") }
        if !model.config.autoAuthEnabled { parts.append("自动认证已关闭") }
        if model.config.scheduledScanEnabled {
            parts.append("定时扫描 \(Int(model.config.scheduledScanInterval))s")
        }
        if parts.isEmpty { parts.append("检测间隔 \(Int(model.config.connectivityInterval))s") }
        return parts.joined(separator: " · ")
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warn: return .orange
        case .error: return .red
        }
    }
}
