import SwiftUI
import AppKit
import CampusNetCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            NetworkSettingsTab(model: model)
                .tabItem { Label("网络", systemImage: "wifi") }
            AuthSettingsTab(model: model)
                .tabItem { Label("认证", systemImage: "key") }
            BehaviorSettingsTab(model: model)
                .tabItem { Label("行为", systemImage: "slider.horizontal.3") }
            LogsSettingsTab(model: model)
                .tabItem { Label("日志", systemImage: "doc.text") }
            AboutTab(model: model)
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .padding(12)
        .frame(minWidth: 560, minHeight: 520)
        .onAppear { model.refreshLogs() }
    }
}

// MARK: - 网络

struct NetworkSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                StringListEditor(
                    items: Binding(get: { model.config.campusSSIDs }, set: { model.config.campusSSIDs = $0 }),
                    placeholder: "校园 Wi-Fi 名称"
                )
                Text("只有连接这些 SSID 时才可能提交校园认证；精确匹配，区分大小写。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("校园 Wi-Fi")
            }

            Section {
                StringListEditor(
                    items: Binding(get: { model.config.whitelistSSIDs }, set: { model.config.whitelistSSIDs = $0 }),
                    placeholder: "宿舍 Wi-Fi / 手机热点"
                )
                Text("连接后不扫描、不探测互联网、不认证。宿舍优先网络会自动并入此列表。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("静默白名单")
            }

            Section {
                DormNetworkEditor(model: model)
            } header: {
                Text("宿舍优先网络（顺序即优先级，不按信号强度）")
            }

            Section {
                if model.issues.isEmpty {
                    Label("配置没有明显问题", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                        Label(issue.message, systemImage: symbol(for: issue.level))
                            .font(.caption)
                    }
                }
            } header: {
                Text("配置检查")
            }

            Section {
                HStack {
                    Button("保存配置") { model.applyConfig() }
                    Spacer()
                    Text(model.isConfigured ? "已具备认证条件" : "尚未配置校园网络")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let banner = model.banner {
                    Text(banner).font(.caption).foregroundStyle(.red)
                }
                if let blocker = model.blockerExplanation {
                    Text(blocker).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func symbol(for level: ConfigIssue.Level) -> String {
        switch level {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.octagon"
        }
    }
}

struct StringListEditor: View {
    @Binding var items: [String]
    var placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    TextField(placeholder, text: Binding(
                        get: { items.indices.contains(index) ? items[index] : "" },
                        set: { if items.indices.contains(index) { items[index] = $0 } }
                    ))
                    Button {
                        guard items.indices.contains(index) else { return }
                        items.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            Button {
                items.append("")
            } label: {
                Label("添加", systemImage: "plus")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}

struct DormNetworkEditor: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(model.config.dormNetworks.enumerated()), id: \.offset) { index, dorm in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("优先级 \(index + 1)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            move(from: index, by: -1)
                        } label: { Image(systemName: "arrow.up") }
                            .buttonStyle(.borderless)
                            .disabled(index == 0)
                        Button {
                            move(from: index, by: 1)
                        } label: { Image(systemName: "arrow.down") }
                            .buttonStyle(.borderless)
                            .disabled(index >= model.config.dormNetworks.count - 1)
                        Button(role: .destructive) {
                            guard model.config.dormNetworks.indices.contains(index) else { return }
                            model.config.dormNetworks.remove(at: index)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }

                    TextField("SSID", text: Binding(
                        get: { currentDorm(at: index)?.ssid ?? "" },
                        set: { value in
                            guard model.config.dormNetworks.indices.contains(index) else { return }
                            model.config.dormNetworks[index].ssid = value
                        }
                    ))

                    TextField("BSSID（可选，填了只连这个 AP）", text: Binding(
                        get: { currentDorm(at: index)?.bssid ?? "" },
                        set: { value in
                            guard model.config.dormNetworks.indices.contains(index) else { return }
                            model.config.dormNetworks[index].bssid = value.isEmpty ? nil : value
                        }
                    ))

                    Toggle("需要密码", isOn: Binding(
                        get: { currentDorm(at: index)?.requiresPassword ?? true },
                        set: { value in
                            guard model.config.dormNetworks.indices.contains(index) else { return }
                            model.config.dormNetworks[index].requiresPassword = value
                        }
                    ))
                    .font(.caption)

                    passwordRow(for: currentDorm(at: index))
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
            }

            HStack {
                Button {
                    model.config.dormNetworks.append(DormNetwork(ssid: "", requiresPassword: true))
                } label: {
                    Label("添加宿舍网络", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func passwordRow(for dorm: DormNetwork?) -> some View {
        let ssid = dorm?.ssid ?? ""
        if dorm?.requiresPassword == false {
            EmptyView()
        } else if model.wifiPasswordPresent[ssid] == true {
            HStack(spacing: 6) {
                Label("密码已保存到钥匙串", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.green)
                Button("删除") { model.removeWiFiPassword(for: ssid) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        } else {
            HStack(spacing: 6) {
                SecureField("Wi-Fi 密码", text: Binding(
                    get: { model.wifiPasswordDrafts[ssid] ?? "" },
                    set: { model.wifiPasswordDrafts[ssid] = $0 }
                ))
                Button("保存") { model.setWiFiPassword(model.wifiPasswordDrafts[ssid] ?? "", for: ssid) }
                    .disabled(ssid.isEmpty || (model.wifiPasswordDrafts[ssid] ?? "").isEmpty)
            }
        }
    }

    private func currentDorm(at index: Int) -> DormNetwork? {
        guard model.config.dormNetworks.indices.contains(index) else { return nil }
        return model.config.dormNetworks[index]
    }

    private func move(from index: Int, by offset: Int) {
        let target = index + offset
        guard model.config.dormNetworks.indices.contains(index), model.config.dormNetworks.indices.contains(target) else { return }
        model.config.dormNetworks.swapAt(index, target)
    }
}

// MARK: - 认证

struct AuthSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("启用自动认证", isOn: Binding(
                    get: { model.config.autoAuthEnabled },
                    set: { model.config.autoAuthEnabled = $0 }
                ))
                Text("关闭后不会提交任何校园认证请求，也不会执行联网检测。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("总开关")
            }

            Section {
                TextField("校园认证账号", text: Binding(
                    get: { model.config.campusUsername },
                    set: { model.config.campusUsername = $0 }
                ))
                if model.hasCampusPassword {
                    HStack {
                        Label("密码已保存在钥匙串", systemImage: "checkmark.seal")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Spacer()
                        Button("删除密码") { model.removeCampusPassword() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                } else {
                    HStack {
                        SecureField("校园认证密码", text: Binding(
                            get: { model.campusPasswordDraft },
                            set: { model.campusPasswordDraft = $0 }
                        ))
                        Button("保存到钥匙串") { model.setCampusPassword(model.campusPasswordDraft) }
                            .disabled(model.campusPasswordDraft.isEmpty)
                    }
                }
                Text("密码只写入本应用自己的 Keychain 项，配置文件与日志中都不会出现。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("账号与密码")
            }

            Section {
                Picker("认证方式", selection: Binding(
                    get: { model.config.campusAuthMode },
                    set: { model.config.campusAuthMode = $0 }
                )) {
                    ForEach(CampusAuthMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                TextField("SRun 门户地址", text: Binding(
                    get: { model.config.srunBaseURL },
                    set: { model.config.srunBaseURL = $0 }
                ))
                TextField("ePortal 登录地址（可留空）", text: Binding(
                    get: { model.config.eportalLoginURL },
                    set: { model.config.eportalLoginURL = $0 }
                ))
                Picker("info 加密变体", selection: Binding(
                    get: { model.config.srunXXTEAVariant },
                    set: { model.config.srunXXTEAVariant = $0 }
                )) {
                    Text("reference（默认，与参考实现一致）").tag(XXTEAVariant.reference)
                    Text("standard（官方 XXTEA 宏）").tag(XXTEAVariant.standard)
                }
                Text("若认证服务器改名 / 更换加密变体，可在这里切换；默认值适用于深圳大学 SRun 门户。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("校园协议")
            }

            Section {
                HStack {
                    Button("保存配置") { model.applyConfig() }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 行为

struct BehaviorSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Stepper(value: Binding(
                    get: { model.config.connectivityInterval },
                    set: { model.config.connectivityInterval = $0 }
                ), in: 15...3600, step: 5) {
                    Text("校园网在线检测间隔：\(Int(model.config.connectivityInterval)) 秒")
                }
                Text("只在开盖且连接校园网时运行；在线时不重复登录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("联网检测")
            }

            Section {
                Toggle("连接校园网时，定时查找并切换到宿舍 Wi-Fi", isOn: Binding(
                    get: { model.config.scheduledScanEnabled },
                    set: { model.config.scheduledScanEnabled = $0 }
                ))
                .disabled(!model.config.hasDormTargets)
                Stepper(value: Binding(
                    get: { model.config.scheduledScanInterval },
                    set: { model.config.scheduledScanInterval = $0 }
                ), in: 60...3600, step: 30) {
                    Text("定时扫描间隔：\(Int(model.config.scheduledScanInterval)) 秒")
                }
                .disabled(!model.config.scheduledScanEnabled)
                Text("默认关闭。开启后仅在开盖且连接校园网时周期扫描；切换成功、合盖、睡眠或离开校园网都会立即停止。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("定时扫描（可选）")
            }

            Section {
                Toggle("登录后自启动", isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if let error = model.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Text("当前状态：\(LaunchAtLogin.description)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("启动")
            }

            Section {
                HStack {
                    Button("重新判断当前网络") { model.reevaluate() }
                    Button("保存配置") { model.applyConfig() }
                    Spacer()
                }
            }

            Section {
                StringListEditor(
                    items: Binding(get: { model.config.probeURLs }, set: { model.config.probeURLs = $0 }),
                    placeholder: "https://example.com/generate_204"
                )
                Text("多个端点全部失败才判定离线，避免系统代理/VPN 造成误判。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("联网检测端点")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 日志

struct LogsSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("刷新") { model.refreshLogs() }
                Button("清空缓存") { model.clearLogs() }
                Button("打开日志文件夹") { model.revealLogFolder() }
                Spacer()
            }
            .controlSize(.small)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    if model.logs.isEmpty {
                        Text("暂无日志").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.logs) { entry in
                        HStack(alignment: .top, spacing: 6) {
                            Text(entry.date, format: .dateTime.month().day().hour().minute().second())
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(entry.level.rawValue.uppercased())
                                .font(.caption2.monospaced())
                                .foregroundStyle(entry.level == .error ? Color.red : (entry.level == .warn ? Color.orange : Color.secondary))
                            Text(entry.message)
                                .font(.caption2)
                                .textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
        }
        .padding(8)
    }
}

// MARK: - 关于

struct AboutTab: View {
    @ObservedObject var model: AppModel

    private var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("版本", value: version)
                LabeledContent("最低系统", value: "macOS 14.0")
                LabeledContent("状态", value: model.status.phase.displayName)
                LabeledContent("配置目录", value: ConfigStore.defaultDirectory.path)
            } header: {
                Text("信息")
            }

            Section {
                Text("本应用只读取 Wi-Fi 名称来判断网络，不获取位置坐标；macOS 把 SSID 读取纳入「定位服务」权限，因此需要在系统设置中允许本应用访问定位服务。")
                Text("若状态显示「权限或配置问题」，请点击菜单栏面板里的「打开定位服务设置」。")
            } header: {
                Text("权限说明")
            }

            Section {
                Text("卸载：退出应用 → 删除 .app → 删除 ~/Library/Application Support/CampusNetPilot → 在「钥匙串访问」中删除 com.example.CampusNetPilot 条目 → 在「系统设置 → 通用 → 登录项」中移除。")
                    .font(.caption)
            } header: {
                Text("卸载")
            }
        }
        .formStyle(.grouped)
    }
}
