import Foundation

public enum RuntimePhase: String, Codable, Sendable, CaseIterable {
    case paused
    case whitelistSilent
    case campusOnline
    case authenticating
    case switching
    case otherNetworkSilent
    case disconnected
    case blocked

    public var displayName: String {
        switch self {
        case .paused: return "合盖／睡眠暂停"
        case .whitelistSilent: return "白名单静默"
        case .campusOnline: return "校园网在线"
        case .authenticating: return "正在认证"
        case .switching: return "正在切换"
        case .otherNetworkSilent: return "其他网络静默"
        case .disconnected: return "未连接"
        case .blocked: return "权限或配置问题"
        }
    }

    public var symbolName: String {
        switch self {
        case .paused: return "moon.zzz"
        case .whitelistSilent: return "checkmark.shield"
        case .campusOnline: return "wifi"
        case .authenticating: return "key.horizontal"
        case .switching: return "arrow.triangle.swap"
        case .otherNetworkSilent: return "wifi.slash"
        case .disconnected: return "bolt.horizontal.circle"
        case .blocked: return "exclamationmark.triangle"
        }
    }
}

public enum StatusBlocker: String, Codable, Sendable {
    case none
    case permission
    case missingConfig
    case badCredentials
    case interfaceUnavailable
    case wifiOff

    public var explanation: String {
        switch self {
        case .none: return ""
        case .permission: return "读取 SSID／扫描需要定位权限：请在「系统设置 → 隐私与安全性 → 定位服务」中允许本应用。"
        case .missingConfig: return "配置不完整：请在设置中填写校园 SSID、认证账号与密码。"
        case .badCredentials: return "认证服务器拒绝了账号或密码，已停止自动重试；修改密码后可手动重新判断。"
        case .interfaceUnavailable: return "无线接口当前不可用（可能被关闭或正被其他进程占用）。"
        case .wifiOff: return "Wi-Fi 已关闭：应用不会替你打开。"
        }
    }
}

public enum PauseReason: String, Codable, Sendable {
    case notStarted
    case lidClosed
    case systemSleep

    public var detail: String {
        switch self {
        case .notStarted: return "尚未启动"
        case .lidClosed: return "合盖暂停"
        case .systemSleep: return "系统睡眠暂停"
        }
    }
}

public struct AppStatus: Equatable, Sendable {
    public var phase: RuntimePhase
    public var detail: String
    public var blocker: StatusBlocker
    public var ssid: String?
    public var bssid: String?
    public var lidClosed: Bool
    public var sleeping: Bool
    public var pauseReason: PauseReason?
    public var autoAuthEnabled: Bool
    public var scheduledScanEnabled: Bool
    public var configured: Bool
    public var lastUpdated: Date
    public var epoch: Int

    public init(
        phase: RuntimePhase = .paused,
        detail: String = "尚未启动",
        blocker: StatusBlocker = .none,
        ssid: String? = nil,
        bssid: String? = nil,
        lidClosed: Bool = false,
        sleeping: Bool = false,
        pauseReason: PauseReason? = .notStarted,
        autoAuthEnabled: Bool = true,
        scheduledScanEnabled: Bool = false,
        configured: Bool = false,
        lastUpdated: Date = Date(),
        epoch: Int = 0
    ) {
        self.phase = phase
        self.detail = detail
        self.blocker = blocker
        self.ssid = ssid
        self.bssid = bssid
        self.lidClosed = lidClosed
        self.sleeping = sleeping
        self.pauseReason = pauseReason
        self.autoAuthEnabled = autoAuthEnabled
        self.scheduledScanEnabled = scheduledScanEnabled
        self.configured = configured
        self.lastUpdated = lastUpdated
        self.epoch = epoch
    }

    /// 用于抑制重复推送的稳定签名（不含时间戳）。
    public var changeSignature: String {
        [
            phase.rawValue,
            detail,
            blocker.rawValue,
            ssid ?? "-",
            lidClosed ? "1" : "0",
            sleeping ? "1" : "0",
            pauseReason?.rawValue ?? "-",
            autoAuthEnabled ? "1" : "0",
            scheduledScanEnabled ? "1" : "0",
            configured ? "1" : "0"
        ].joined(separator: "|")
    }
}
