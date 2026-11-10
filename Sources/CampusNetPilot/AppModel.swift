import Foundation
import AppKit
import Combine
import CampusNetCore

// MARK: - 线程安全的小工具

/// 让平台无关的引擎回调安全地把配置/状态传给 UI。
final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppConfig

    init(_ config: AppConfig = AppConfig()) { self.value = config }

    var config: AppConfig {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}

final class StatusRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((AppStatus) -> Void)?

    func setHandler(_ handler: ((AppStatus) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func publish(_ status: AppStatus) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(status)
    }
}

/// 每次探测都读取当前配置里的探测端点。
final class DynamicProbe: ConnectivityProbing, @unchecked Sendable {
    private let transport: HTTPTransport
    private let box: ConfigBox

    init(transport: HTTPTransport, box: ConfigBox) {
        self.transport = transport
        self.box = box
    }

    func probe() async -> ProbeResult {
        let urls = box.config.probeURLs
        return await HTTPConnectivityProbe(transport: transport, urls: urls).probe()
    }
}

// MARK: - 应用模型

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var status = AppStatus()
    @Published var config = AppConfig()
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var issues: [ConfigIssue] = []
    @Published private(set) var hasCampusPassword = false
    @Published private(set) var wifiPasswordPresent: [String: Bool] = [:]
    @Published private(set) var launchAtLoginEnabled = false
    @Published var launchAtLoginError: String?
    @Published var campusPasswordDraft = ""
    @Published var wifiPasswordDrafts: [String: String] = [:]
    @Published var banner: String?

    private let logHub = LogHub()
    private let configBox = ConfigBox()
    private let keychain = KeychainStore()
    private let wifiService = WiFiService()
    private let wifiMonitor = WiFiMonitor()
    private let powerService = PowerService()
    private let relay = StatusRelay()
    private let transport = URLSessionTransport()
    private let scheduler = DispatchDeadlineScheduler()
    private var engine: CampusEngine?
    private var configStore: ConfigStore { ConfigStore(log: logHub) }
    private lazy var credentials = KeychainCredentialProvider(store: keychain)
    private lazy var probe = DynamicProbe(transport: transport, box: configBox)
    private lazy var authClient = CampusAuthClient(transport: transport, wifi: wifiService, log: logHub)
    private var started = false

    private init() {
        switch ConfigStore(log: nil).load() {
        case .loaded(let loaded):
            config = loaded
        case .createdDefault(let defaults):
            config = defaults
        case .recoveredDefault(let reason):
            config = ConfigValidation.normalize(AppConfig())
            logHub.log(.warn, "配置文件无法解析（\(reason)），已使用默认配置")
        }
        configBox.config = config
        issues = ConfigValidation.issues(config)
    }

    // MARK: 生命周期

    func launch() {
        guard !started else { return }
        started = true

        relay.setHandler { [weak self] status in
            Task { @MainActor in
                self?.status = status
                self?.refreshLogs()
            }
        }

        let engine = CampusEngine(
            config: config,
            wifi: wifiService,
            prober: probe,
            authenticator: authClient,
            credentials: credentials,
            scheduler: scheduler,
            log: logHub,
            onStatus: { [relay] status in relay.publish(status) },
            lidStateProvider: { PowerService.clamshellClosed() }
        )
        self.engine = engine

        wifiMonitor.onChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                await self.engine?.handle(.wifiChanged)
            }
        }
        wifiMonitor.start()

        powerService.onLidChange = { [weak self] closed in
            Task { @MainActor in
                guard let self else { return }
                self.logHub.log(.debug, "盖子状态：\(closed ? "已合上" : "已打开")")
                await self.engine?.handle(.lidChanged(closed: closed))
            }
        }
        powerService.onWillSleep = { [weak self] in
            Task { @MainActor in
                self?.logHub.suspendFileWriting()
                await self?.engine?.handle(.systemWillSleep)
            }
        }
        powerService.onDidWake = { [weak self] displayAwake in
            Task { @MainActor in
                await self?.engine?.handle(.systemDidWake(displayAwake: displayAwake))
            }
        }
        powerService.start()

        applyLaunchAtLoginPreference()
        refreshKeychainState()
        refreshLogs()

        Task {
            await engine.handle(.applicationStarted)
        }
    }

    func shutdown() {
        powerService.stop()
        wifiMonitor.stop()
        logHub.suspendFileWriting()
    }

    // MARK: 用户操作

    func reevaluate() {
        Task { await engine?.handle(.manualReevaluate) }
    }

    func applyConfig() {
        let normalized = ConfigValidation.normalize(config)
        config = normalized
        configBox.config = normalized
        issues = ConfigValidation.issues(normalized)
        do {
            try configStore.save(normalized)
            banner = nil
        } catch {
            banner = "保存配置失败：\(error.localizedDescription)"
            logHub.log(.error, banner ?? "")
        }
        Task { await engine?.updateConfig(normalized) }
        applyLaunchAtLoginPreference()
        refreshKeychainState()
        refreshLogs()
    }

    func refreshLogs() {
        logs = logHub.recent(150)
    }

    func clearLogs() {
        logHub.clear()
        refreshLogs()
    }

    func revealLogFolder() {
        NSWorkspace.shared.open(LogHub.defaultLogDirectory)
    }

    func openLocationPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") else { return }
        NSWorkspace.shared.open(url)
    }

    func setCampusPassword(_ value: String) {
        do {
            try keychain.set(value, for: KeychainAccounts.campusPassword)
            hasCampusPassword = true
            campusPasswordDraft = ""
            logHub.log(.info, "校园认证密码已写入钥匙串")
        } catch {
            banner = "写入钥匙串失败：\(error.localizedDescription)"
        }
    }

    func removeCampusPassword() {
        keychain.remove(account: KeychainAccounts.campusPassword)
        hasCampusPassword = false
        logHub.log(.info, "已删除校园认证密码")
    }

    func setWiFiPassword(_ value: String, for ssid: String) {
        guard !ssid.isEmpty else { return }
        do {
            try keychain.set(value, for: KeychainAccounts.wifiPassword(ssid))
            wifiPasswordDrafts[ssid] = ""
            refreshKeychainState()
            logHub.log(.info, "已保存 \(ssid) 的 Wi-Fi 密码")
        } catch {
            banner = "写入钥匙串失败：\(error.localizedDescription)"
        }
    }

    func removeWiFiPassword(for ssid: String) {
        keychain.remove(account: KeychainAccounts.wifiPassword(ssid))
        refreshKeychainState()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.setEnabled(enabled)
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
            launchAtLoginError = nil
            config.launchAtLogin = launchAtLoginEnabled
            applyConfig()
        } catch {
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
            launchAtLoginError = "设置登录项失败：\(error.localizedDescription)"
            logHub.log(.warn, launchAtLoginError ?? "")
        }
    }

    func quit() {
        shutdown()
        NSApp.terminate(nil)
    }

    // MARK: 派生状态

    var menuBarSymbol: String {
        if status.lidClosed || status.sleeping { return "moon.zzz" }
        switch status.phase {
        case .paused: return "pause.circle"
        case .whitelistSilent: return "checkmark.shield"
        case .campusOnline: return "wifi"
        case .authenticating: return "key.horizontal"
        case .switching: return "arrow.triangle.swap"
        case .otherNetworkSilent: return "wifi.slash"
        case .disconnected: return "bolt.horizontal.circle"
        case .blocked: return "exclamationmark.triangle"
        }
    }

    var statusLine: String {
        guard let ssid = status.ssid, !ssid.isEmpty else { return status.detail }
        return "\(status.detail)（\(ssid)）"
    }

    var blockerExplanation: String? {
        status.blocker == .none ? nil : status.blocker.explanation
    }

    var permissionLikelyMissing: Bool {
        status.blocker == .permission
    }

    var isConfigured: Bool {
        status.configured
    }

    // MARK: 内部

    private func refreshKeychainState() {
        hasCampusPassword = keychain.hasValue(for: KeychainAccounts.campusPassword)
        var map: [String: Bool] = [:]
        for dorm in config.dormNetworks {
            map[dorm.ssid] = keychain.hasValue(for: KeychainAccounts.wifiPassword(dorm.ssid))
        }
        wifiPasswordPresent = map
    }

    private func applyLaunchAtLoginPreference() {
        do {
            try LaunchAtLogin.setEnabled(config.launchAtLogin)
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
            launchAtLoginError = nil
        } catch {
            launchAtLoginEnabled = LaunchAtLogin.isEnabled
            launchAtLoginError = "设置登录项失败：\(error.localizedDescription)"
        }
    }
}
