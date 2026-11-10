import Foundation

// MARK: - 事件

public enum EngineEvent: Sendable {
    case applicationStarted
    case lidChanged(closed: Bool)
    case systemWillSleep
    case systemDidWake(displayAwake: Bool)
    case wifiChanged
    case manualReevaluate
    case configChanged(AppConfig)
    case deadline(ScheduleKey)
}

/// 触发来源。只有开盖、开盖状态下启动、手动操作允许主动扫描宿舍网络；
/// 普通网络变化不重复执行"开盖扫描"。
public enum EvaluationTrigger: Sendable {
    case launch
    case openLid
    case manual
    case networkChange

    public var allowsDormScan: Bool {
        switch self {
        case .launch, .openLid, .manual: return true
        case .networkChange: return false
        }
    }
}

/// 连接指纹：用于区分"同一条连接的重复通知/漫游"与"真正的连接变化"。
/// 断线重连、接口变化、IP 变化都会体现为指纹变化，从而触发重新评估。
struct ConnectionFingerprint: Equatable, Sendable {
    var ssid: String?
    var bssid: String?
    var interfaceName: String?
    var ipv4: String?
    var connected: Bool
}

enum DormScanContext: Sendable, Equatable {
    case none
    case fromCampus
    case fromDisconnected
    case fromPeriodic
}

// MARK: - 统一状态机
//
// 单一 actor 协调扫描、切换、联网检测与认证，避免并发冲突：
//  * 每个事件先自增 epoch，所有长任务结果都带 epoch 校验，过期结果直接丢弃；
//  * 合盖/睡眠会 cancelAll 定时器并取消进行中的请求；
//  * 定时由 DeadlineScheduling 注入，测试用可控时钟推进，不依赖真实等待。

public actor CampusEngine {
    public static let maxScanAttempts = 3
    public static let scanRetryDelay: TimeInterval = 2.5
    public static let switchCooldown: TimeInterval = 90
    public static let autoConnectRetryDelay: TimeInterval = 8
    public static let maxAutoConnectRetries = 2
    public static let authBackoff: [TimeInterval] = [10, 30, 120, 300, 600]

    private let wifi: WiFiControlling
    private let prober: ConnectivityProbing
    private let authenticator: CampusAuthenticating
    private let credentials: CredentialProviding
    private let scheduler: DeadlineScheduling
    private let log: LogSink
    private let time: TimeSource
    private let onStatus: (@Sendable (AppStatus) -> Void)?
    /// 读取物理盖子状态（true = 已合上）。平台上由 IOPMrootDomain 提供；
    /// 每次提交网络动作前都会再问一次，避免"合盖但未睡眠"时漏判。
    private let lidStateProvider: (@Sendable () async -> Bool?)?

    private(set) var config: AppConfig

    private var phase: RuntimePhase = .paused
    private var detail = "尚未启动"
    private var blocker: StatusBlocker = .none
    private var lidClosed = false
    private var sleeping = false
    private var pauseReason: PauseReason? = .notStarted
    private var started = false
    private var epoch = 0
    private var lastSSID: String?
    private var lastFingerprint: ConnectionFingerprint?
    private var scanContext: DormScanContext = .none
    private var scanAttempts = 0
    private var switchCooldownUntil: Date?
    private var authFailureCount = 0
    /// 账号/密码被明确拒绝后置位：不再自动重试，直到网络变化、手动操作或配置更新。
    private var authBlocked = false
    private var periodicScanFailures = 0
    private var autoConnectRetries = 0
    private var lastEmittedSignature = ""
    private var cancelCurrentOperation: (@Sendable () -> Void)?

    public init(
        config: AppConfig,
        wifi: WiFiControlling,
        prober: ConnectivityProbing,
        authenticator: CampusAuthenticating,
        credentials: CredentialProviding,
        scheduler: DeadlineScheduling,
        log: LogSink = MemoryLog(),
        time: TimeSource = SystemTimeSource(),
        onStatus: (@Sendable (AppStatus) -> Void)? = nil,
        lidStateProvider: (@Sendable () async -> Bool?)? = nil
    ) {
        self.config = ConfigValidation.normalize(config)
        self.wifi = wifi
        self.prober = prober
        self.authenticator = authenticator
        self.credentials = credentials
        self.scheduler = scheduler
        self.log = log
        self.time = time
        self.onStatus = onStatus
        self.lidStateProvider = lidStateProvider
    }

    // MARK: 查询

    public func statusSnapshot() -> AppStatus {
        AppStatus(
            phase: phase,
            detail: detail,
            blocker: blocker,
            ssid: lastSSID,
            bssid: nil,
            lidClosed: lidClosed,
            sleeping: sleeping,
            pauseReason: pauseReason,
            autoAuthEnabled: config.autoAuthEnabled,
            scheduledScanEnabled: config.scheduledScanEnabled,
            configured: config.hasCampusCredentials,
            lastUpdated: time.now(),
            epoch: epoch
        )
    }

    public func currentConfig() -> AppConfig { config }

    var isActive: Bool { started && !lidClosed && !sleeping && pauseReason == nil }

    // MARK: 生命周期

    public func start() async {
        guard !started else { return }
        started = true
        log.log(.info, "引擎启动（合盖：\(lidClosed ? "是" : "否")，睡眠：\(sleeping ? "是" : "否")）")
        if lidClosed || sleeping {
            pauseReason = lidClosed ? .lidClosed : .systemSleep
            phase = .paused
            detail = (pauseReason ?? .lidClosed).detail
            emit()
            return
        }
        pauseReason = nil
        await evaluate(.launch)
    }

    public func handle(_ event: EngineEvent) async {
        switch event {
        case .applicationStarted:
            await start()
        case .lidChanged(let closed):
            await handleLidChanged(closed)
        case .systemWillSleep:
            sleeping = true
            pause(.systemSleep)
        case .systemDidWake(let displayAwake):
            await handleWake(displayAwake: displayAwake)
        case .wifiChanged:
            await handleNetworkChanged()
        case .manualReevaluate:
            await handleManualReevaluate()
        case .configChanged(let newConfig):
            await apply(newConfig)
        case .deadline(let key):
            await handleDeadline(key)
        }
    }

    public func updateConfig(_ newConfig: AppConfig) async {
        await apply(newConfig)
    }

    // MARK: 电源 / 盖子

    private func handleLidChanged(_ closed: Bool) async {
        if closed {
            guard !lidClosed else { return }
            lidClosed = true
            pause(.lidClosed)
            log.log(.debug, "检测到物理合盖，暂停全部活动")
            return
        }
        guard lidClosed else { return }
        lidClosed = false
        guard !sleeping else { return }
        resume(reason: "开盖")
        await evaluate(.openLid)
    }

    private func handleWake(displayAwake: Bool) async {
        sleeping = false
        // 判断依据是"物理盖子 + 系统睡眠状态"，屏幕是否点亮只用于日志：
        //  * 盖子合上 → 后台维护唤醒，保持暂停（不扫描、不认证）
        //  * 盖子打开 → 即使屏幕还没亮也继续校园网监控（熄屏/锁屏不是暂停理由）
        if lidClosed {
            pause(.lidClosed)
            log.log(.debug, "唤醒但盖子仍合上（后台维护唤醒）：保持暂停")
            return
        }
        resume(reason: "系统唤醒（屏幕\(displayAwake ? "已亮" : "未亮")，盖子已打开）")
        await evaluate(.openLid)
    }

    private func pause(_ reason: PauseReason) {
        let alreadyPaused = pauseReason != nil
        pauseReason = reason
        epoch += 1
        scheduler.cancelAll()
        cancelCurrentOperation?()
        cancelCurrentOperation = nil
        scanContext = .none
        scanAttempts = 0
        autoConnectRetries = 0
        switchCooldownUntil = nil
        lastSSID = nil
        lastFingerprint = nil
        phase = .paused
        detail = reason.detail
        blocker = .none
        if !alreadyPaused {
            log.log(.info, "暂停：\(reason.detail)")
        }
        emit()
    }

    private func resume(reason: String) {
        pauseReason = nil
        sleeping = false
        epoch += 1
        scheduler.cancelAll()
        cancelCurrentOperation?()
        cancelCurrentOperation = nil
        scanContext = .none
        scanAttempts = 0
        authFailureCount = 0
        authBlocked = false
        periodicScanFailures = 0
        autoConnectRetries = 0
        switchCooldownUntil = nil
        log.log(.info, "恢复：\(reason)")
    }

    // MARK: 评估入口

    private func evaluate(_ trigger: EvaluationTrigger) async {
        guard isActive else { return }
        let startEpoch = epoch
        let snapshot = await captureSnapshot()
        guard isActive, startEpoch == epoch else { return }
        await route(snapshot: snapshot, trigger: trigger)
    }

    private func route(snapshot: WiFiSnapshot, trigger: EvaluationTrigger) async {
        guard isActive else { return }
        lastFingerprint = fingerprint(of: snapshot)

        if snapshot.power == .off {
            lastSSID = nil
            settle(.disconnected, detail: "Wi-Fi 已关闭（本应用不会替你打开）", blocker: .wifiOff)
            stopAllWork()
            return
        }
        if snapshot.readability == .permissionDenied {
            lastSSID = nil
            settle(.blocked, detail: "SSID 不可读：缺少定位/无线权限", blocker: .permission)
            stopAllWork()
            log.log(.warn, "SSID 不可读，已停止自动扫描与认证")
            return
        }
        guard snapshot.interfaceAvailable else {
            lastSSID = nil
            settle(.blocked, detail: "无线接口不可用", blocker: .interfaceUnavailable)
            stopAllWork()
            return
        }

        let ssid = (snapshot.ssid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !ssid.isEmpty {
            lastSSID = ssid
            if config.isCampusSSID(ssid) {
                await enterCampus(ssid: ssid, trigger: trigger)
            } else if config.isWhitelistSSID(ssid) {
                settle(.whitelistSilent, detail: "已连接静默网络：\(ssid)")
                stopAllWork()
            } else {
                settle(.otherNetworkSilent, detail: "已连接其他网络：\(ssid)（保持静默）")
                stopAllWork()
            }
            return
        }

        lastSSID = nil
        settle(.disconnected, detail: "未连接 Wi-Fi")
        stopAllWork()
        guard trigger.allowsDormScan else { return }
        guard config.hasDormTargets else {
            scheduleAutoConnectRetry()
            return
        }
        if isSwitchCoolingDown() {
            log.log(.debug, "切换冷却中，暂不扫描宿舍网络")
            scheduleAutoConnectRetry()
            return
        }
        await beginDormScan(context: .fromDisconnected)
    }

    private func enterCampus(ssid: String, trigger: EvaluationTrigger) async {
        guard isActive else { return }
        if trigger.allowsDormScan, config.hasDormTargets {
            if isSwitchCoolingDown() {
                log.log(.debug, "切换冷却中，保留校园网连接")
            } else {
                log.log(.info, "已连接校园网 \(ssid)，执行一次宿舍优先网络扫描")
                await beginDormScan(context: .fromCampus)
                return
            }
        }
        await startCampusMonitoring(ssid: ssid)
    }

    // MARK: 扫描 / 切换

    private func beginDormScan(context: DormScanContext) async {
        guard isActive else { return }
        scanContext = context
        scanAttempts = 0
        await runScanIteration()
    }

    private func runScanIteration() async {
        guard isActive, scanContext != .none else { return }
        guard scanAttempts < Self.maxScanAttempts else {
            await finishScan()
            return
        }
        if await abortIfLidClosed() { return }
        scanAttempts += 1
        let startEpoch = epoch
        settle(.switching, detail: "扫描宿舍优先网络（第 \(scanAttempts)/\(Self.maxScanAttempts) 次）")
        let outcome = await captureScan()
        guard isActive, startEpoch == epoch else {
            log.log(.debug, "丢弃过期扫描结果")
            return
        }

        switch outcome {
        case .success(let networks):
            if let target = config.matchDormTarget(in: networks) {
                await attemptSwitch(to: target)
            } else {
                await finishScan()
            }
        case .permissionDenied:
            settle(.blocked, detail: "扫描失败：权限不足（定位/无线）", blocker: .permission)
            scanContext = .none
            stopAllWork()
        case .interfaceUnavailable:
            await retryScanOrFinish(reason: "无线接口不可用")
        case .failed(let reason):
            await retryScanOrFinish(reason: reason)
        }
    }

    private func retryScanOrFinish(reason: String) async {
        guard isActive else { return }
        if scanAttempts < Self.maxScanAttempts {
            log.log(.debug, "扫描失败（\(reason)），\(Int(Self.scanRetryDelay)) 秒后重试")
            scheduler.cancel(.scanRetry)
            scheduler.schedule(.scanRetry, after: Self.scanRetryDelay) { [weak self] in
                guard let self else { return }
                Task { await self.handle(.deadline(.scanRetry)) }
            }
        } else {
            log.log(.warn, "扫描失败次数已达上限（\(reason)）")
            await finishScan()
        }
    }

    private func finishScan() async {
        let context = scanContext
        scanContext = .none
        scanAttempts = 0
        scheduler.cancel(.scanRetry)
        guard isActive else { return }
        let startEpoch = epoch
        let snapshot = await captureSnapshot()
        guard isActive, startEpoch == epoch else { return }

        switch context {
        case .none:
            return
        case .fromCampus:
            if let ssid = snapshot.ssid, config.isCampusSSID(ssid) {
                log.log(.info, "未发现宿舍优先网络，保留校园网并按需认证")
                await startCampusMonitoring(ssid: ssid)
            } else {
                await route(snapshot: snapshot, trigger: .networkChange)
            }
        case .fromDisconnected:
            if let ssid = snapshot.ssid, !ssid.isEmpty {
                await route(snapshot: snapshot, trigger: .networkChange)
            } else {
                settle(.disconnected, detail: "未发现宿舍优先网络，等待系统自动连接")
                scheduleAutoConnectRetry()
            }
        case .fromPeriodic:
            periodicScanFailures += 1
            if let ssid = snapshot.ssid, config.isCampusSSID(ssid) {
                settle(.campusOnline, detail: "定时扫描未发现宿舍网络，继续校园网监控")
                scheduleConnectivityCheck()
                schedulePeriodicScanIfNeeded()
            } else {
                await route(snapshot: snapshot, trigger: .networkChange)
            }
        }
    }

    private func attemptSwitch(to target: DormNetwork) async {
        guard isActive else { return }
        if await abortIfLidClosed() { return }
        let startEpoch = epoch
        settle(.switching, detail: "正在切换到 \(target.ssid)")
        log.log(.info, "尝试切换到宿舍优先网络 \(target.ssid)")

        let password = target.requiresPassword ? credentials.wifiPassword(forSSID: target.ssid) : nil
        let outcome = await captureConnect(ssid: target.ssid, bssid: target.bssid, password: password)
        guard isActive, startEpoch == epoch else {
            log.log(.debug, "丢弃过期切换结果")
            return
        }

        switch outcome {
        case .connected(let ssid):
            let snapshot = await captureSnapshot()
            guard isActive, startEpoch == epoch else { return }
            let actual = snapshot.ssid?.trimmingCharacters(in: .whitespacesAndNewlines)
            if actual == ssid {
                switchCooldownUntil = nil
                periodicScanFailures = 0
                authFailureCount = 0
                autoConnectRetries = 0
                lastSSID = actual
                settle(.whitelistSilent, detail: "已切换到 \(ssid)，进入静默")
                stopAllWork()
                log.log(.info, "切换成功：\(ssid)")
            } else {
                await handleSwitchFailure(
                    reason: "切换后实际连接为 \(actual ?? "未连接")",
                    snapshot: snapshot
                )
            }
        case .needsPassword:
            let snapshot = await captureSnapshot()
            await handleSwitchFailure(reason: "缺少 \(target.ssid) 的 Wi-Fi 密码（请在设置中填写）", snapshot: snapshot)
        case .failed(let reason):
            let snapshot = await captureSnapshot()
            await handleSwitchFailure(reason: reason, snapshot: snapshot)
        case .timedOut:
            let snapshot = await captureSnapshot()
            await handleSwitchFailure(reason: "连接 \(target.ssid) 超时", snapshot: snapshot)
        }
    }

    private func handleSwitchFailure(reason: String, snapshot: WiFiSnapshot) async {
        switchCooldownUntil = time.now().addingTimeInterval(Self.switchCooldown)
        periodicScanFailures += 1
        log.log(.warn, "切换失败：\(reason)（\(Int(Self.switchCooldown)) 秒内不再尝试）")
        guard isActive else { return }

        if let ssid = snapshot.ssid, config.isCampusSSID(ssid) {
            log.log(.info, "切换失败后仍连接校园网 \(ssid)，转入校园网处理")
            await startCampusMonitoring(ssid: ssid)
        } else if (snapshot.ssid ?? "").isEmpty {
            settle(.disconnected, detail: "切换失败且未连接网络")
            scheduleAutoConnectRetry()
        } else {
            await route(snapshot: snapshot, trigger: .networkChange)
        }
    }

    // MARK: 校园网监控与认证

    private func startCampusMonitoring(ssid: String) async {
        guard isActive else { return }
        guard config.autoAuthEnabled, config.campusAuthMode != .disabled else {
            settle(.campusOnline, detail: "已连接校园网 \(ssid)（自动认证已关闭）")
            scheduler.cancelAll()
            schedulePeriodicScanIfNeeded()
            return
        }
        await runConnectivityCycle()
    }

    private func runConnectivityCycle() async {
        guard isActive else { return }
        guard !authBlocked else {
            log.log(.debug, "账号密码错误后已停止自动认证，等待网络变化或手动重新判断")
            return
        }
        let startEpoch = epoch
        let snapshot = await captureSnapshot()
        guard isActive, startEpoch == epoch else { return }
        guard let ssid = snapshot.ssid, config.isCampusSSID(ssid) else {
            log.log(.debug, "当前不在校园网，停止校园认证流程")
            await route(snapshot: snapshot, trigger: .networkChange)
            return
        }

        if await abortIfLidClosed() { return }
        scheduler.cancel(.connectivity)
        let probe = await captureProbe()
        guard isActive, startEpoch == epoch else {
            log.log(.debug, "丢弃过期联网检测结果")
            return
        }

        if probe.reachable {
            authFailureCount = 0
            settle(.campusOnline, detail: "校园网在线（\(ssid)）")
            scheduleConnectivityCheck()
            schedulePeriodicScanIfNeeded()
            return
        }

        log.log(.info, "联网检测未通过：\(probe.detail)")
        await performAuth(ssid: ssid, probe: probe)
    }

    private func performAuth(ssid: String, probe: ProbeResult) async {
        guard isActive else { return }
        let username = config.campusUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, let password = credentials.campusPassword(), !password.isEmpty else {
            settle(.blocked, detail: "缺少校园认证账号或密码", blocker: .missingConfig)
            stopAllWork()
            log.log(.warn, "认证配置缺失，已停止自动认证")
            return
        }
        guard config.campusAuthMode != .disabled else {
            settle(.blocked, detail: "认证方式为关闭", blocker: .missingConfig)
            stopAllWork()
            return
        }

        if await abortIfLidClosed() { return }
        let startEpoch = epoch
        settle(.authenticating, detail: "正在提交校园认证（\(probe.portalLikely ? "门户拦截" : "联网失败")）")
        log.log(.info, "提交校园认证：\(config.campusAuthMode.displayName)（SSID：\(ssid)）")

        let request = AuthRequest(
            username: username,
            password: password,
            campusSSIDs: config.campusList,
            mode: config.campusAuthMode,
            srunBaseURL: config.srunBaseURL,
            eportalLoginURL: config.eportalLoginURL.isEmpty ? nil : config.eportalLoginURL,
            xxteaVariant: config.srunXXTEAVariant
        )
        let result = await captureLogin(request)
        guard isActive, startEpoch == epoch else {
            log.log(.debug, "丢弃过期认证结果")
            return
        }

        if result.success {
            authFailureCount = 0
            settle(.campusOnline, detail: "认证成功：\(result.message)")
            scheduleConnectivityCheck()
            schedulePeriodicScanIfNeeded()
            return
        }

        switch result.kind {
        case .notCampus:
            let snapshot = await captureSnapshot()
            guard isActive, startEpoch == epoch else { return }
            await route(snapshot: snapshot, trigger: .networkChange)
        case .badCredentials:
            authBlocked = true
            settle(.blocked, detail: "认证失败：账号或密码错误（已停止重试）", blocker: .badCredentials)
            stopAllWork()
            log.log(.error, "认证失败：账号或密码错误")
        case .missingConfig, .disabled:
            settle(.blocked, detail: "认证配置缺失或已关闭", blocker: .missingConfig)
            stopAllWork()
        case .network, .portalRejected, .invalidResponse, .none:
            authFailureCount = min(authFailureCount + 1, Self.authBackoff.count)
            let delay = Self.authBackoff[authFailureCount - 1]
            settle(.authenticating, detail: "认证失败，\(Int(delay)) 秒后重试：\(result.message)")
            log.log(.warn, "认证失败：\(result.message)")
            scheduler.cancel(.connectivity)
            scheduler.schedule(.authBackoff, after: delay) { [weak self] in
                guard let self else { return }
                Task { await self.handle(.deadline(.authBackoff)) }
            }
        }
    }

    // MARK: 定时任务

    private func scheduleConnectivityCheck() {
        scheduler.cancel(.connectivity)
        guard isActive, config.autoAuthEnabled, config.campusAuthMode != .disabled else { return }
        let interval = max(15, config.connectivityInterval)
        scheduler.schedule(.connectivity, after: interval) { [weak self] in
            guard let self else { return }
            Task { await self.handle(.deadline(.connectivity)) }
        }
    }

    private func schedulePeriodicScanIfNeeded() {
        scheduler.cancel(.periodicScan)
        guard isActive, config.scheduledScanEnabled, config.hasDormTargets else { return }
        switch phase {
        case .campusOnline, .authenticating:
            break
        default:
            return
        }
        let factor = pow(2.0, Double(min(periodicScanFailures, 3)))
        let interval = max(60, config.scheduledScanInterval) * factor
        scheduler.schedule(.periodicScan, after: interval) { [weak self] in
            guard let self else { return }
            Task { await self.handle(.deadline(.periodicScan)) }
        }
    }

    private func scheduleAutoConnectRetry() {
        guard isActive else { return }
        guard autoConnectRetries < Self.maxAutoConnectRetries else {
            scheduler.cancel(.autoConnectRetry)
            log.log(.debug, "已放弃等待系统自动连接（重试次数上限）")
            return
        }
        autoConnectRetries += 1
        scheduler.cancel(.autoConnectRetry)
        scheduler.schedule(.autoConnectRetry, after: Self.autoConnectRetryDelay) { [weak self] in
            guard let self else { return }
            Task { await self.handle(.deadline(.autoConnectRetry)) }
        }
    }

    private func handleDeadline(_ key: ScheduleKey) async {
        guard isActive else { return }
        switch key {
        case .connectivity, .authBackoff:
            await runConnectivityCycle()
        case .scanRetry:
            guard scanContext != .none else { return }
            await runScanIteration()
        case .autoConnectRetry:
            await handleAutoConnectTick()
        case .periodicScan:
            await handlePeriodicScanTick()
        }
    }

    private func handleAutoConnectTick() async {
        guard isActive else { return }
        let startEpoch = epoch
        let snapshot = await captureSnapshot()
        guard isActive, startEpoch == epoch else { return }
        if let ssid = snapshot.ssid, !ssid.isEmpty {
            await route(snapshot: snapshot, trigger: .networkChange)
            return
        }
        scheduleAutoConnectRetry()
    }

    private func handlePeriodicScanTick() async {
        guard isActive, config.scheduledScanEnabled, config.hasDormTargets else { return }
        let startEpoch = epoch
        let snapshot = await captureSnapshot()
        guard isActive, startEpoch == epoch else { return }
        guard let ssid = snapshot.ssid, config.isCampusSSID(ssid) else { return }
        guard !isSwitchCoolingDown() else {
            log.log(.debug, "切换冷却中，跳过本次定时扫描")
            schedulePeriodicScanIfNeeded()
            return
        }
        log.log(.info, "定时扫描：查找宿舍优先网络")
        await beginDormScan(context: .fromPeriodic)
    }

    // MARK: 网络变化 / 手动 / 配置

    private func fingerprint(of snapshot: WiFiSnapshot) -> ConnectionFingerprint {
        let ssid = (snapshot.ssid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return ConnectionFingerprint(
            ssid: ssid.isEmpty ? nil : ssid,
            bssid: snapshot.bssid?.lowercased(),
            interfaceName: snapshot.interfaceName,
            ipv4: snapshot.ipv4,
            connected: snapshot.power == .on && snapshot.interfaceAvailable && !ssid.isEmpty
        )
    }

    private func handleNetworkChanged() async {
        guard isActive else {
            epoch += 1
            emit()
            return
        }

        // 先读实际状态，再决定是否作废旧任务。
        let snapshot = await captureSnapshot()
        guard isActive else { return }
        let current = fingerprint(of: snapshot)
        let previous = lastFingerprint

        // 只有"连接本身变了"才作废任务：
        //   断开/重连（connected 翻转）、换 SSID、换接口、换 IP。
        // 同 SSID 的 BSSID 变化（漫游）与纯重复通知不算，避免打断进行中的认证。
        let connectionChanged: Bool
        if let previous {
            connectionChanged = previous.connected != current.connected
                || previous.ssid != current.ssid
                || previous.interfaceName != current.interfaceName
                || previous.ipv4 != current.ipv4
        } else {
            connectionChanged = true
        }

        if !connectionChanged {
            lastFingerprint = current
            if previous?.bssid != current.bssid {
                log.log(.debug, "同 SSID 漫游（BSSID 变化），不打断进行中的任务")
            } else {
                log.log(.debug, "网络状态未变化，忽略重复通知")
            }
            if let ssid = current.ssid, config.isCampusSSID(ssid), phase == .campusOnline {
                scheduleConnectivityCheck()
                schedulePeriodicScanIfNeeded()
            }
            emit()
            return
        }

        log.log(.info, "连接变化：\(previous?.ssid ?? "无") → \(current.ssid ?? "无")，接口 \(current.interfaceName ?? "-")，IP \(current.ipv4 ?? "-")")
        authBlocked = false
        epoch += 1
        cancelCurrentOperation?()
        cancelCurrentOperation = nil
        scheduler.cancel(.scanRetry)
        await route(snapshot: snapshot, trigger: .networkChange)
    }
    private func handleManualReevaluate() async {
        guard started else { return }
        guard isActive else {
            log.log(.info, "当前为暂停状态（\(pauseReason?.detail ?? "未启动")），不改动网络")
            emit()
            return
        }
        epoch += 1
        cancelCurrentOperation?()
        cancelCurrentOperation = nil
        scheduler.cancelAll()
        scanContext = .none
        scanAttempts = 0
        switchCooldownUntil = nil
        authFailureCount = 0
        authBlocked = false
        periodicScanFailures = 0
        autoConnectRetries = 0
        log.log(.info, "手动重新判断当前网络")
        await evaluate(.manual)
    }

    private func apply(_ newConfig: AppConfig) async {
        let normalized = ConfigValidation.normalize(newConfig)
        let changed = normalized != config
        config = normalized
        guard changed else { return }
        log.log(.info, "配置已更新")
        epoch += 1
        cancelCurrentOperation?()
        cancelCurrentOperation = nil
        scheduler.cancelAll()
        scanContext = .none
        scanAttempts = 0
        authFailureCount = 0
        authBlocked = false
        periodicScanFailures = 0
        guard isActive else {
            emit()
            return
        }
        lastSSID = nil
        await evaluate(.networkChange)
    }

    // MARK: 内部工具

    // 依赖通过局部常量捕获，避免在 @Sendable 闭包里访问 actor 隔离属性。
    /// 读快照是廉价且幂等的操作：不走 perform 的取消句柄，避免把进行中认证的
    /// 取消句柄覆盖掉（否则暂停时会取消错的任务）。
    private func captureSnapshot() async -> WiFiSnapshot {
        let wifi = self.wifi
        return await wifi.snapshot()
    }

    private func captureScan() async -> ScanOutcome {
        let wifi = self.wifi
        return await perform { await wifi.scan() }
    }

    private func captureProbe() async -> ProbeResult {
        let prober = self.prober
        return await perform { await prober.probe() }
    }

    private func captureLogin(_ request: AuthRequest) async -> AuthResult {
        let authenticator = self.authenticator
        return await perform { await authenticator.login(request) }
    }

    private func captureConnect(ssid: String, bssid: String?, password: String?) async -> ConnectOutcome {
        let wifi = self.wifi
        return await perform { await wifi.connect(ssid: ssid, bssid: bssid, password: password) }
    }

    /// 提交任何网络动作前重新确认物理盖子状态；已合上则立即暂停并放弃本次动作。
    /// 这样即使"合盖但系统未睡眠"（外接显示器），也不会在轮询发现之前把认证请求发出去。
    private func abortIfLidClosed() async -> Bool {
        guard let provider = lidStateProvider else { return false }
        let closed = await provider()
        guard closed == true else { return false }
        log.log(.info, "盖子处于合上状态，已取消本次网络操作")
        pause(.lidClosed)
        return true
    }

    private func perform<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let task = Task { await operation() }
        cancelCurrentOperation = { task.cancel() }
        let value = await task.value
        cancelCurrentOperation = nil
        return value
    }

    private func stopAllWork() {
        scheduler.cancelAll()
        cancelCurrentOperation?()
        cancelCurrentOperation = nil
        scanContext = .none
        scanAttempts = 0
        autoConnectRetries = 0
    }

    private func isSwitchCoolingDown() -> Bool {
        guard let until = switchCooldownUntil else { return false }
        return time.now() < until
    }

    private func settle(_ newPhase: RuntimePhase, detail text: String, blocker newBlocker: StatusBlocker = .none) {
        let changed = phase != newPhase
        phase = newPhase
        detail = text
        blocker = newBlocker
        if changed {
            log.log(.info, "状态：\(newPhase.displayName) — \(text)")
        }
        emit()
    }

    private func emit() {
        let status = statusSnapshot()
        guard status.changeSignature != lastEmittedSignature else { return }
        lastEmittedSignature = status.changeSignature
        onStatus?(status)
    }
}
