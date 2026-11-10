import Foundation
@testable import CampusNetCore

// MARK: - 同步作用域锁

/// 异步函数里不能直接调用 `NSLock.lock()/unlock()`（Swift 6 下是错误、5.x 下是警告）。
/// 这里把临界区放进串行队列的同步执行块：锁内不含 `await`，也不会跨挂起点持锁。
final class ScopedLock: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.example.CampusNetPilot.tests.lock")

    func sync<T>(_ body: () throws -> T) rethrows -> T {
        try queue.sync(execute: body)
    }
}

// MARK: - 测试替身

/// 可编程的 Wi-Fi 假实现：记录调用次数，支持用 Gate 卡住扫描以模拟"合盖时仍在进行"的任务。
final class FakeWiFi: WiFiControlling, @unchecked Sendable {
    private let lock = ScopedLock()
    private var _snapshot: WiFiSnapshot
    private var _scanOutcomes: [ScanOutcome]
    private var _connectOutcome: ConnectOutcome
    private var _scanCount = 0
    private var _connectCount = 0
    private var _snapshotCount = 0
    private var _lastConnectPassword: String?

    var scanGate: Gate?

    init(
        snapshot: WiFiSnapshot,
        scanOutcomes: [ScanOutcome] = [],
        connectOutcome: ConnectOutcome = .failed("模拟连接失败")
    ) {
        self._snapshot = snapshot
        self._scanOutcomes = scanOutcomes
        self._connectOutcome = connectOutcome
    }

    var scanCount: Int { lock.sync { _scanCount } }
    var connectCount: Int { lock.sync { _connectCount } }
    var snapshotCount: Int { lock.sync { _snapshotCount } }
    var lastConnectPassword: String? { lock.sync { _lastConnectPassword } }

    func setSnapshot(_ snapshot: WiFiSnapshot) {
        lock.sync { _snapshot = snapshot }
    }

    func setScanOutcomes(_ outcomes: [ScanOutcome]) {
        lock.sync { _scanOutcomes = outcomes }
    }

    func setConnectOutcome(_ outcome: ConnectOutcome) {
        lock.sync { _connectOutcome = outcome }
    }

    func snapshot() async -> WiFiSnapshot {
        lock.sync {
            _snapshotCount += 1
            return _snapshot
        }
    }

    func scan() async -> ScanOutcome {
        let gate = lock.sync { () -> Gate? in
            _scanCount += 1
            return scanGate
        }
        if let gate { await gate.wait() }
        return lock.sync {
            guard !_scanOutcomes.isEmpty else { return .success([]) }
            if _scanOutcomes.count == 1 { return _scanOutcomes[0] }
            return _scanOutcomes.removeFirst()
        }
    }

    func connect(ssid: String, bssid: String?, password: String?) async -> ConnectOutcome {
        lock.sync {
            _connectCount += 1
            _lastConnectPassword = password
            let outcome = _connectOutcome
            if case .connected = outcome {
                _snapshot.ssid = ssid
                _snapshot.bssid = bssid ?? _snapshot.bssid
                _snapshot.readability = .available
            }
            return outcome
        }
    }
}

final class FakeProbe: ConnectivityProbing, @unchecked Sendable {
    private let lock = ScopedLock()
    private var _result: ProbeResult
    private var _count = 0

    init(result: ProbeResult = ProbeResult(reachable: false, portalLikely: true, detail: "模拟门户拦截", respondedEndpoints: 1)) {
        self._result = result
    }

    var onProbe: (@Sendable () -> Void)?

    var count: Int { lock.sync { _count } }

    func setResult(_ result: ProbeResult) {
        lock.sync { _result = result }
    }

    func probe() async -> ProbeResult {
        let (value, hook) = lock.sync { () -> (ProbeResult, (@Sendable () -> Void)?) in
            _count += 1
            return (_result, onProbe)
        }
        hook?()
        return value
    }
}

final class FakeAuth: CampusAuthenticating, @unchecked Sendable {
    private let lock = ScopedLock()
    private var _result: AuthResult
    private var _requests: [AuthRequest] = []

    init(result: AuthResult = .ok("模拟认证成功")) {
        self._result = result
    }

    var authGate: Gate?

    var count: Int { lock.sync { _requests.count } }
    var requests: [AuthRequest] { lock.sync { _requests } }

    func setResult(_ result: AuthResult) {
        lock.sync { _result = result }
    }

    func login(_ request: AuthRequest) async -> AuthResult {
        let (result, gate) = lock.sync { () -> (AuthResult, Gate?) in
            _requests.append(request)
            return (_result, authGate)
        }
        if let gate { await gate.wait() }
        return result
    }
}
final class FakeCredentials: CredentialProviding, @unchecked Sendable {
    var campusPasswordValue: String? = "campus-secret"
    var wifiPasswords: [String: String] = ["宿舍-WiFi": "dorm-secret"]

    func campusPassword() -> String? { campusPasswordValue }
    func wifiPassword(forSSID ssid: String) -> String? { wifiPasswords[ssid] }
}

/// 可手动触发的定时器，替代真实 DispatchSourceTimer，让测试不依赖 sleep。
final class ManualScheduler: DeadlineScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [ScheduleKey: @Sendable () -> Void] = [:]
    private var delays: [ScheduleKey: TimeInterval] = [:]
    private var cancellationCount = 0
    private var cancelAllCount = 0

    var scheduledKeys: [ScheduleKey] { lock.lock(); defer { lock.unlock() }; return Array(bodies.keys) }
    var totalCancellations: Int { lock.lock(); defer { lock.unlock() }; return cancellationCount }
    var totalCancelAll: Int { lock.lock(); defer { lock.unlock() }; return cancelAllCount }

    func has(_ key: ScheduleKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return bodies[key] != nil
    }

    func delay(for key: ScheduleKey) -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return delays[key]
    }

    func schedule(_ key: ScheduleKey, after: TimeInterval, _ body: @escaping @Sendable () -> Void) {
        lock.lock()
        bodies[key] = body
        delays[key] = after
        lock.unlock()
    }

    func cancel(_ key: ScheduleKey) {
        lock.lock()
        bodies[key] = nil
        delays[key] = nil
        cancellationCount += 1
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        bodies.removeAll()
        delays.removeAll()
        cancelAllCount += 1
        lock.unlock()
    }

    /// 模拟定时器到点：执行回调（回调内部会再投递事件到引擎）。
    func fire(_ key: ScheduleKey) {
        lock.lock()
        let body = bodies[key]
        bodies[key] = nil
        delays[key] = nil
        lock.unlock()
        body?()
    }
}

/// 可编程的盖子状态（nil 表示系统不提供该信息）。
final class LidStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _closed: Bool?

    init(closed: Bool? = false) { _closed = closed }

    var value: Bool? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _closed
        }
        set {
            lock.lock()
            _closed = newValue
            lock.unlock()
        }
    }
}

final class VirtualTime: TimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

// MARK: - 场景脚手架

struct Harness {
    let config: AppConfig
    let wifi: FakeWiFi
    let probe: FakeProbe
    let auth: FakeAuth
    let credentials: FakeCredentials
    let scheduler: ManualScheduler
    let time: VirtualTime
    let log: MemoryLog
    let engine: CampusEngine

    static func make(
        config: AppConfig = Harness.defaultConfig(),
        snapshot: WiFiSnapshot = WiFiSnapshot(
            power: .on,
            interfaceName: "en0",
            interfaceAvailable: true,
            ssid: "Campus-WiFi",
            readability: .available
        ),
        scanOutcomes: [ScanOutcome] = [.success([])],
        connectOutcome: ConnectOutcome = .failed("模拟失败"),
        probeResult: ProbeResult = ProbeResult(reachable: false, portalLikely: true, detail: "模拟门户拦截", respondedEndpoints: 1),
        authResult: AuthResult = .ok("模拟认证成功"),
        lidState: LidStateBox = LidStateBox(closed: false)
    ) -> Harness {
        let wifi = FakeWiFi(snapshot: snapshot, scanOutcomes: scanOutcomes, connectOutcome: connectOutcome)
        let probe = FakeProbe(result: probeResult)
        let auth = FakeAuth(result: authResult)
        let credentials = FakeCredentials()
        let scheduler = ManualScheduler()
        let time = VirtualTime()
        let log = MemoryLog()
        let engine = CampusEngine(
            config: config,
            wifi: wifi,
            prober: probe,
            authenticator: auth,
            credentials: credentials,
            scheduler: scheduler,
            log: log,
            time: time,
            lidStateProvider: { lidState.value }
        )
        return Harness(
            config: config,
            wifi: wifi,
            probe: probe,
            auth: auth,
            credentials: credentials,
            scheduler: scheduler,
            time: time,
            log: log,
            engine: engine
        )
    }

    static func defaultConfig() -> AppConfig {
        var config = AppConfig()
        config.campusSSIDs = ["Campus-WiFi"]
        config.campusUsername = "2024000000"
        config.campusAuthMode = .srun
        config.whitelistSSIDs = ["宿舍-WiFi", "热点"]
        config.dormNetworks = [DormNetwork(ssid: "宿舍-WiFi", requiresPassword: true)]
        config.connectivityInterval = 30
        config.scheduledScanEnabled = false
        config.scheduledScanInterval = 180
        return config
    }

    func status() async -> AppStatus {
        await engine.statusSnapshot()
    }
}

extension ProbeResult {
    static func online() -> ProbeResult {
        ProbeResult(reachable: true, portalLikely: false, detail: "模拟在线", respondedEndpoints: 2)
    }

    static func offline() -> ProbeResult {
        ProbeResult(reachable: false, portalLikely: true, detail: "模拟需要认证", respondedEndpoints: 1)
    }
}

func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}
