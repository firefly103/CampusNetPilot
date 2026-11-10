import Foundation

// MARK: - Wi-Fi 抽象
//
// 状态机只依赖这些协议，真实实现由 CampusNetPilot 用 CoreWLAN 提供，
// 测试用内存假实现驱动，因此可以在没有 Wi-Fi 硬件的环境里验证决策行为。

public enum WiFiPower: String, Sendable, Equatable {
    case on
    case off
    case unknown
}

public enum SSIDReadability: String, Sendable, Equatable {
    /// 正常读到 SSID，或确实未连接。
    case available
    /// 接口已连接但 SSID 不可读（常见原因：未授予定位权限 → TCC 拦截）。
    case permissionDenied
    case unknown
}

public struct WiFiSnapshot: Sendable, Equatable {
    public var power: WiFiPower
    public var interfaceName: String?
    public var interfaceAvailable: Bool
    public var ssid: String?
    public var bssid: String?
    /// 当前接口的 IPv4 地址（用于识别"同 SSID 但重新拿地址/换接口"这类真实连接变化）。
    public var ipv4: String?
    public var readability: SSIDReadability

    public init(
        power: WiFiPower = .unknown,
        interfaceName: String? = nil,
        interfaceAvailable: Bool = true,
        ssid: String? = nil,
        bssid: String? = nil,
        readability: SSIDReadability = .available,
        ipv4: String? = nil
    ) {
        self.power = power
        self.interfaceName = interfaceName
        self.interfaceAvailable = interfaceAvailable
        self.ssid = ssid
        self.bssid = bssid
        self.readability = readability
        self.ipv4 = ipv4
    }

    public static let unknown = WiFiSnapshot()
}

public struct ScannedNetwork: Sendable, Equatable {
    public var ssid: String
    public var bssid: String?
    public var rssi: Int

    public init(ssid: String, bssid: String? = nil, rssi: Int = -70) {
        self.ssid = ssid
        self.bssid = bssid
        self.rssi = rssi
    }
}

public enum ScanOutcome: Sendable, Equatable {
    case success([ScannedNetwork])
    case permissionDenied
    case interfaceUnavailable
    case failed(String)
}

public enum ConnectOutcome: Sendable, Equatable {
    case connected(ssid: String)
    case needsPassword
    case failed(String)
    case timedOut
}

public protocol WiFiControlling: Sendable {
    func snapshot() async -> WiFiSnapshot
    func scan() async -> ScanOutcome
    func connect(ssid: String, bssid: String?, password: String?) async -> ConnectOutcome
}

// MARK: - 连通性探测

public struct ProbeResult: Sendable, Equatable {
    public var reachable: Bool
    /// 是否观察到门户/拦截迹象（例如被重定向或返回非预期内容）。
    public var portalLikely: Bool
    public var detail: String
    /// 有多少端点返回了 HTTP 响应（而非纯传输层失败）。
    public var respondedEndpoints: Int

    public init(reachable: Bool, portalLikely: Bool, detail: String, respondedEndpoints: Int) {
        self.reachable = reachable
        self.portalLikely = portalLikely
        self.detail = detail
        self.respondedEndpoints = respondedEndpoints
    }
}

public protocol ConnectivityProbing: Sendable {
    func probe() async -> ProbeResult
}

// MARK: - 凭据

public protocol CredentialProviding: Sendable {
    func campusPassword() -> String?
    func wifiPassword(forSSID ssid: String) -> String?
}

// MARK: - 时间与定时

public protocol TimeSource: Sendable {
    func now() -> Date
}

public struct SystemTimeSource: TimeSource {
    public init() {}
    public func now() -> Date { Date() }
}

public enum ScheduleKey: String, Sendable, CaseIterable {
    case connectivity
    case periodicScan
    case scanRetry
    case autoConnectRetry
    case authBackoff
}

public protocol DeadlineScheduling: AnyObject, Sendable {
    func schedule(_ key: ScheduleKey, after: TimeInterval, _ body: @escaping @Sendable () -> Void)
    func cancel(_ key: ScheduleKey)
    func cancelAll()
}

/// 生产用定时器：串行队列上的 DispatchSourceTimer，不会泄漏已取消的定时器。
public final class DispatchDeadlineScheduler: DeadlineScheduling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "campusnet.scheduler")
    private var timers: [ScheduleKey: DispatchSourceTimer] = [:]

    public init() {}

    public func schedule(_ key: ScheduleKey, after: TimeInterval, _ body: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.timers[key]?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + max(0, after))
            timer.setEventHandler {
                self.queue.async {
                    self.timers[key]?.cancel()
                    self.timers[key] = nil
                }
                body()
            }
            self.timers[key] = timer
            timer.resume()
        }
    }

    public func cancel(_ key: ScheduleKey) {
        queue.async { [weak self] in
            guard let self else { return }
            self.timers[key]?.cancel()
            self.timers[key] = nil
        }
    }

    public func cancelAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for (_, timer) in self.timers { timer.cancel() }
            self.timers.removeAll()
        }
    }
}

// MARK: - 日志

public enum LogLevel: String, Sendable, Codable, CaseIterable {
    case debug
    case info
    case warn
    case error

    public var symbol: String {
        switch self {
        case .debug: return "·"
        case .info: return "→"
        case .warn: return "!"
        case .error: return "×"
        }
    }
}

public struct LogEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let date: Date
    public let level: LogLevel
    public let message: String

    public init(id: UUID = UUID(), date: Date, level: LogLevel, message: String) {
        self.id = id
        self.date = date
        self.level = level
        self.message = message
    }
}

public protocol LogSink: Sendable {
    func log(_ level: LogLevel, _ message: String)
}

public enum LogRedactor {
    /// 兜底脱敏：任何 password/token 之类的查询参数值都会被替换，避免凭据进入日志。
    private static let sensitiveKeys = ["password", "passwd", "pwd", "token", "user_password", "chksum"]

    public static func scrub(_ message: String) -> String {
        var result = message
        for key in sensitiveKeys {
            result = replaceValues(of: key, in: result)
        }
        return result
    }

    private static func replaceValues(of key: String, in text: String) -> String {
        let needle = key + "="
        var output = text
        var cursor = output.startIndex
        while let range = output.range(of: needle, range: cursor..<output.endIndex) {
            var end = range.upperBound
            while end < output.endIndex, !"& ".contains(output[end]) {
                end = output.index(after: end)
            }
            guard end > range.upperBound else {
                cursor = range.upperBound
                continue
            }
            output.replaceSubrange(range.upperBound..<end, with: "***")
            cursor = output.index(range.lowerBound, offsetBy: needle.count + 3, limitedBy: output.endIndex) ?? output.endIndex
        }
        return output
    }
}

/// 进程内日志中枢：环形缓存供设置页显示 + 按天写文件（合盖/睡眠期间不写）。
public final class LogHub: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private let capacity: Int
    private let time: TimeSource
    private let minimumLevel: LogLevel
    private var fileHandle: FileHandle?
    private var fileDay: String?
    private let fileURLProvider: @Sendable (String) -> URL

    public init(
        capacity: Int = 400,
        minimumLevel: LogLevel = .info,
        time: TimeSource = SystemTimeSource(),
        fileURLProvider: @escaping @Sendable (String) -> URL = { day in
            LogHub.defaultLogDirectory.appendingPathComponent("app-\(day).log")
        }
    ) {
        self.capacity = capacity
        self.minimumLevel = minimumLevel
        self.time = time
        self.fileURLProvider = fileURLProvider
    }

    public static var defaultLogDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CampusNetPilot/logs", isDirectory: true)
    }

    public func log(_ level: LogLevel, _ message: String) {
        guard level.rank >= minimumLevel.rank else { return }
        let scrubbed = LogRedactor.scrub(message)
        let date = time.now()
        let entry = LogEntry(date: date, level: level, message: scrubbed)
        lock.lock()
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
        let writer = makeWriterIfNeeded(for: date)
        lock.unlock()
        append(entry, to: writer)
    }

    public func recent(_ limit: Int = 120) -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.suffix(limit))
    }

    public func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    /// 合盖/睡眠时调用：关闭文件句柄，避免唤醒后继续追加旧文件句柄。
    public func suspendFileWriting() {
        lock.lock()
        try? fileHandle?.close()
        fileHandle = nil
        fileDay = nil
        lock.unlock()
    }

    private func makeWriterIfNeeded(for date: Date) -> FileHandle? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let day = formatter.string(from: date)
        if fileDay == day, let handle = fileHandle { return handle }
        try? fileHandle?.close()
        fileHandle = nil
        let url = fileURLProvider(day)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            fileHandle = handle
            fileDay = day
            return handle
        } catch {
            fileDay = day
            fileHandle = nil
            return nil
        }
    }

    private func append(_ entry: LogEntry, to handle: FileHandle?) {
        guard let handle else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
        let line = "[\(formatter.string(from: entry.date))] \(entry.level.rawValue.uppercased()) \(entry.message)\n"
        if let data = line.data(using: .utf8) {
            lock.lock()
            try? handle.write(contentsOf: data)
            lock.unlock()
        }
    }
}

public extension LogLevel {
    var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }
}

/// 测试与预览用的内存日志。
public final class MemoryLog: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(LogLevel, String)] = []

    public init() {}

    public func log(_ level: LogLevel, _ message: String) {
        lock.lock()
        storage.append((level, message))
        lock.unlock()
    }

    public var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage.map { $0.1 }
    }

    public var entries: [(LogLevel, String)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
