import Foundation
import AppKit
import CoreGraphics
import CoreWLAN
import Darwin
import IOKit
import Network
import CampusNetCore

// MARK: - Wi-Fi（CoreWLAN）

/// CoreWLAN 实现。所有调用都放在串行队列上，避免与事件回调并发冲突。
final class WiFiService: WiFiControlling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.example.CampusNetPilot.wifi")
    private let client = CWWiFiClient.shared()

    func snapshot() async -> WiFiSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: WiFiService.readSnapshot(self.client))
            }
        }
    }

    func scan() async -> ScanOutcome {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let interface = self.client.interface() else {
                    continuation.resume(returning: .interfaceUnavailable)
                    return
                }
                guard interface.powerOn() else {
                    continuation.resume(returning: .interfaceUnavailable)
                    return
                }
                do {
                    let results = try interface.scanForNetworks(withSSID: nil)
                    let networks = results.compactMap { network -> ScannedNetwork? in
                        guard let ssid = network.ssid, !ssid.isEmpty else { return nil }
                        return ScannedNetwork(ssid: ssid, bssid: network.bssid, rssi: network.rssiValue)
                    }
                    if networks.isEmpty && !results.isEmpty {
                        // 扫描到了网络但读不到名字：几乎总是缺少定位权限。
                        continuation.resume(returning: .permissionDenied)
                    } else {
                        continuation.resume(returning: .success(networks))
                    }
                } catch {
                    continuation.resume(returning: .failed(error.localizedDescription))
                }
            }
        }
    }

    /// 使用本应用自己的 Keychain 口令关联目标网络。
    /// password 为 nil 时交给系统尝试复用已保存的凭据；失败则回报 needsPassword 由界面提示输入。
    func connect(ssid: String, bssid: String?, password: String?) async -> ConnectOutcome {
        guard let interface = client.interface(), interface.powerOn() else {
            return .failed("无线接口不可用")
        }
        let network: CWNetwork
        do {
            let candidates = try interface.scanForNetworks(withName: ssid)
            if let bssid, let exact = candidates.first(where: { $0.bssid?.caseInsensitiveCompare(bssid) == .orderedSame }) {
                network = exact
            } else if let first = candidates.first {
                network = first
            } else {
                return .failed("扫描不到目标网络 \(ssid)")
            }
        } catch {
            return .failed("扫描目标网络失败：\(error.localizedDescription)")
        }

        do {
            try interface.associate(to: network, password: password)
        } catch {
            if password == nil {
                return .needsPassword
            }
            return .failed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if Task.isCancelled { return .timedOut }
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return .timedOut }
            if interface.ssid() == ssid, interface.rssiValue() != 0 {
                return .connected(ssid: ssid)
            }
        }
        return .timedOut
    }

    /// 当前接口的 IPv4（用于识别"同 SSID 但重新拿地址/换接口"这类真实连接变化）。
    static func ipv4Address(interfaceName: String?) -> String? {
        guard let interfaceName, !interfaceName.isEmpty else { return nil }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            let entry = current.pointee
            if let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
               String(cString: entry.ifa_name) == interfaceName {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let length = socklen_t(address.pointee.sa_len)
                if getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(cString: host)
                }
                return nil
            }
            pointer = entry.ifa_next
        }
        return nil
    }

    static func readSnapshot(_ client: CWWiFiClient) -> WiFiSnapshot {
        guard let interface = client.interface() else {
            return WiFiSnapshot(power: .unknown, interfaceName: nil, interfaceAvailable: false, ssid: nil, readability: .unknown)
        }
        let name = interface.interfaceName
        guard interface.powerOn() else {
            return WiFiSnapshot(power: .off, interfaceName: name, interfaceAvailable: true, ssid: nil)
        }
        let ssid = interface.ssid()
        let bssid = interface.bssid()
        let rssi = interface.rssiValue()

        let readability: SSIDReadability
        if let ssid, !ssid.isEmpty {
            readability = .available
        } else if bssid != nil || rssi != 0 {
            // 已关联但读不到 SSID：macOS 因缺少定位授权而隐藏 SSID。
            readability = .permissionDenied
        } else {
            readability = .available
        }
        return WiFiSnapshot(
            power: .on,
            interfaceName: name,
            interfaceAvailable: true,
            ssid: ssid,
            bssid: bssid,
            readability: readability,
            ipv4: ipv4Address(interfaceName: name)
        )
    }
}

// MARK: - 网络变化监听

/// 事件源：
///  1. CWEventDelegate（SSID / BSSID / 链路 / 电源事件，带 1.5 秒防抖）；
///  2. NWPathMonitor（链路可用性变化，作为不依赖 CoreWLAN 私有行为的兜底）；
///  3. 电源/盖子事件由 PowerService 提供。
final class WiFiMonitor: NSObject, CWEventDelegate, @unchecked Sendable {
    private let client = CWWiFiClient.shared()
    private let pathMonitor = NWPathMonitor()
    private let debounceQueue = DispatchQueue(label: "com.example.CampusNetPilot.wifi.monitor")
    private var pending: DispatchWorkItem?
    private var started = false
    private let events: [CWEventType] = [.ssidDidChange, .bssidDidChange, .linkDidChange, .powerDidChange]

    var onChange: (@Sendable () -> Void)?

    func start() {
        guard !started else { return }
        started = true
        client.delegate = self
        for event in events {
            // 某些系统版本可能拒绝个别事件类型，失败不影响其它事件源。
            try? client.startMonitoringEvent(with: event)
        }
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            self?.scheduleNotify()
        }
        pathMonitor.start(queue: debounceQueue)
    }

    func stop() {
        guard started else { return }
        started = false
        for event in events {
            try? client.stopMonitoringEvent(with: event)
        }
        client.delegate = nil
        pathMonitor.cancel()
    }

    /// 去抖：连续的通知只在 1.5 秒后合并成一次评估。
    private func scheduleNotify() {
        // 所有对 pending 的读写都串行化到 debounceQueue，避免多事件源并发竞态。
        debounceQueue.async { [weak self] in
            guard let self else { return }
            self.pending?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.onChange?()
            }
            self.pending = work
            self.debounceQueue.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    // CWEventDelegate 的可选方法（签名以当前 SDK 为准；未命中的类型由 NWPathMonitor 兜底）
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) { scheduleNotify() }
    func bssidDidChangeForWiFiInterface(withName interfaceName: String) { scheduleNotify() }
    func linkDidChangeForWiFiInterface(withName interfaceName: String) { scheduleNotify() }
    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { scheduleNotify() }
    func clientConnectionInterrupted() { scheduleNotify() }
    func clientConnectionInvalidated() { scheduleNotify() }
}

// MARK: - 电源 / 盖子 / 屏幕

/// 物理盖子状态来自 IOPMrootDomain 的 AppleClamshellState（IORegistry 属性，
/// 非公开 API 但长期稳定，只读出 Bool，且需要 root 权限的可能性为零）。
///
/// 检测策略：
///  * 睡眠/唤醒/屏幕熄灭与点亮：NSWorkspace 通知（事件驱动，零轮询）；
///  * 物理开合盖（含外接显示器时不睡眠的"合盖不睡"场景）：15 秒一次的低频 IORegistry 读取兜底；
///  * 不注册任何电源断言，不阻止睡眠，不主动唤醒，也不改动机器的电源设置。
final class PowerService {
    /// 合盖状态变化
    var onLidChange: (@Sendable (Bool) -> Void)?
    /// 即将睡眠
    var onWillSleep: (@Sendable () -> Void)?
    /// 已唤醒；参数表示主显示器是否点亮（后台维护唤醒通常为 false）
    var onDidWake: (@Sendable (Bool) -> Void)?

    private var pollTimer: DispatchSourceTimer?
    private var pollInterval: TimeInterval = 0
    private var observers: [NSObjectProtocol] = []
    private var lastLidClosed: Bool?

    deinit { stop() }

    func start() {
        guard observers.isEmpty else { return }

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onWillSleep?()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleWake()
        })
        // 屏幕熄灭/点亮不是"唤醒"：只在此时顺带核一次盖子状态。
        // 熄屏与锁屏都不应暂停监控，因此不向状态机发任何事件。
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshLidState(force: true)
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshLidState(force: true)
        })

        refreshLidState(force: true)
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        pollInterval = 0
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    static func clamshellClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let property = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        let value = property.takeRetainedValue()
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    static func mainDisplayAwake() -> Bool {
        guard !NSScreen.screens.isEmpty else { return false }
        return CGDisplayIsAsleep(CGMainDisplayID()) == 0
    }

    private func refreshLidState(force: Bool = false) {
        guard let closed = PowerService.clamshellClosed() else {
            // 读不到盖子状态（非常罕见）：按"开盖"处理并保持低频检查，避免完全没有定时器。
            schedulePoll(closed: false)
            return
        }
        schedulePoll(closed: closed)
        if force || closed != lastLidClosed {
            lastLidClosed = closed
            onLidChange?(closed)
        }
    }

    /// 低频兜底检查：盖子打开时 10 秒一次（用于尽快发现合盖），
    /// 合上后降到 30 秒一次（合盖期间只需要发现"重新开盖"）。
    /// 只读 IORegistry 的一个 Bool，不涉及网络、不写日志。
    private func schedulePoll(closed: Bool) {
        let interval: TimeInterval = closed ? 30 : 10
        if pollTimer != nil, abs(pollInterval - interval) < 0.001 { return }
        pollTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.refreshLidState() }
        timer.resume()
        pollTimer = timer
        pollInterval = interval
    }

    private func handleWake() {
        refreshLidState(force: true)
        onDidWake?(PowerService.mainDisplayAwake())
    }
}