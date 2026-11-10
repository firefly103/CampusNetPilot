import Foundation

// MARK: - 网络条目

/// 宿舍优先网络（开盖后允许主动扫描并切换的目标）。
/// 优先级 = 在数组中的顺序，第一个即最高优先级；不按信号强度排序。
public struct DormNetwork: Codable, Equatable, Identifiable, Sendable {
    public var ssid: String
    /// 可选 BSSID 限定。留空表示接受该 SSID 下任意 AP（不破坏校园/宿舍 AP 漫游）。
    public var bssid: String?
    /// 连接该网络是否需要密码。需要时从本应用 Keychain 项读取，缺失则请求用户填写。
    public var requiresPassword: Bool

    public var id: String { ssid }

    public init(ssid: String, bssid: String? = nil, requiresPassword: Bool = true) {
        self.ssid = ssid
        self.bssid = bssid
        self.requiresPassword = requiresPassword
    }
}

public enum CampusAuthMode: String, Codable, Sendable, CaseIterable {
    case disabled
    case srun
    case eportal

    public var displayName: String {
        switch self {
        case .disabled: return "关闭"
        case .srun: return "SRun（深澜）"
        case .eportal: return "ePortal"
        }
    }
}

// MARK: - 配置

public struct AppConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int = AppConfig.currentVersion
    /// 自动认证总开关。关闭后不提交任何校园认证请求（联网检测也停止）。
    public var autoAuthEnabled: Bool = true
    /// 静默白名单：连接后不探测、不认证、不扫描。
    public var whitelistSSIDs: [String] = []
    /// 宿舍优先网络（含优先级）。
    public var dormNetworks: [DormNetwork] = []
    /// 校园 Wi-Fi SSID 列表（精确匹配）。
    public var campusSSIDs: [String] = []
    public var campusUsername: String = ""
    public var campusAuthMode: CampusAuthMode = .srun
    /// SRun 门户根地址（校园协议本身可能使用 HTTP；见 README 说明）。
    public var srunBaseURL: String = "https://net.szu.edu.cn"
    /// SRun info 加密的 XXTEA 变体；默认与参考实现一致。
    public var srunXXTEAVariant: XXTEAVariant = .reference
    /// ePortal 登录地址（含 query 之前的完整路径），留空表示不使用。
    public var eportalLoginURL: String = ""
    /// 校园网在线状态检测间隔（秒）。
    public var connectivityInterval: TimeInterval = 30
    /// 可选定时扫描开关，默认关闭。
    public var scheduledScanEnabled: Bool = false
    /// 定时扫描间隔（秒），默认 180。
    public var scheduledScanInterval: TimeInterval = 180
    /// 联网检测端点（HTTP/HTTPS），避免只看单个 DNS 端口。
    public var probeURLs: [String] = AppConfig.defaultProbeURLs
    /// 登录后自启动（SMAppService）。
    public var launchAtLogin: Bool = false

    public static let defaultProbeURLs: [String] = [
        "https://captive.apple.com/hotspot-detect.html",
        "https://connectivitycheck.gstatic.com/generate_204"
    ]

    public init() {}

    // 容错解码：缺字段时回落到默认值，避免旧配置导致启动失败。
    enum CodingKeys: String, CodingKey {
        case version, autoAuthEnabled, whitelistSSIDs, dormNetworks, campusSSIDs
        case campusUsername, campusAuthMode, srunBaseURL, eportalLoginURL
        case connectivityInterval, scheduledScanEnabled, scheduledScanInterval
        case probeURLs, launchAtLogin, srunXXTEAVariant
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        // Swift 5 起 `try?` 会拍平 throwing 调用的 Optional 返回值，这里直接用默认值兜底。
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? defaults.version
        autoAuthEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .autoAuthEnabled)) ?? defaults.autoAuthEnabled
        whitelistSSIDs = (try? c.decodeIfPresent([String].self, forKey: .whitelistSSIDs)) ?? defaults.whitelistSSIDs
        dormNetworks = (try? c.decodeIfPresent([DormNetwork].self, forKey: .dormNetworks)) ?? defaults.dormNetworks
        campusSSIDs = (try? c.decodeIfPresent([String].self, forKey: .campusSSIDs)) ?? defaults.campusSSIDs
        campusUsername = (try? c.decodeIfPresent(String.self, forKey: .campusUsername)) ?? defaults.campusUsername
        campusAuthMode = (try? c.decodeIfPresent(CampusAuthMode.self, forKey: .campusAuthMode)) ?? defaults.campusAuthMode
        srunBaseURL = (try? c.decodeIfPresent(String.self, forKey: .srunBaseURL)) ?? defaults.srunBaseURL
        eportalLoginURL = (try? c.decodeIfPresent(String.self, forKey: .eportalLoginURL)) ?? defaults.eportalLoginURL
        connectivityInterval = (try? c.decodeIfPresent(TimeInterval.self, forKey: .connectivityInterval)) ?? defaults.connectivityInterval
        scheduledScanEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .scheduledScanEnabled)) ?? defaults.scheduledScanEnabled
        scheduledScanInterval = (try? c.decodeIfPresent(TimeInterval.self, forKey: .scheduledScanInterval)) ?? defaults.scheduledScanInterval
        probeURLs = (try? c.decodeIfPresent([String].self, forKey: .probeURLs)) ?? defaults.probeURLs
        launchAtLogin = (try? c.decodeIfPresent(Bool.self, forKey: .launchAtLogin)) ?? defaults.launchAtLogin
        srunXXTEAVariant = (try? c.decodeIfPresent(XXTEAVariant.self, forKey: .srunXXTEAVariant)) ?? defaults.srunXXTEAVariant
    }
}

// MARK: - 匹配与派生

public extension AppConfig {
    /// 去掉首尾空白并丢弃空条目的 SSID 列表（SSID 本身允许中英文与空格，仅裁剪首尾）。
    static func cleaned(_ list: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in list {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            if seen.insert(value).inserted { result.append(value) }
        }
        return result
    }

    /// 宿舍优先网络自动纳入静默白名单（两者是"必要包含"关系）。
    var effectiveWhitelist: [String] {
        var list = AppConfig.cleaned(whitelistSSIDs)
        for dorm in dormNetworks {
            let ssid = dorm.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ssid.isEmpty, !list.contains(ssid) else { continue }
            list.append(ssid)
        }
        return list
    }

    var campusList: [String] { AppConfig.cleaned(campusSSIDs) }

    func isCampusSSID(_ ssid: String) -> Bool {
        campusList.contains(ssid)
    }

    /// 契约：校园 SSID 优先于白名单判定，避免同一 SSID 同时出现在两个列表时静默掉认证。
    func isWhitelistSSID(_ ssid: String) -> Bool {
        !isCampusSSID(ssid) && effectiveWhitelist.contains(ssid)
    }

    var hasDormTargets: Bool {
        !dormNetworks.filter { !$0.ssid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.isEmpty
    }

    /// 按配置优先级（数组顺序）选取第一个可见的宿舍网络；不比较信号强度。
    func matchDormTarget(in networks: [ScannedNetwork]) -> DormNetwork? {
        let bySSID = Dictionary(grouping: networks) { $0.ssid }
        for target in dormNetworks {
            let ssid = target.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ssid.isEmpty, let matches = bySSID[ssid], !matches.isEmpty else { continue }
            if let bssid = target.bssid?.trimmingCharacters(in: .whitespacesAndNewlines), !bssid.isEmpty {
                if matches.contains(where: { $0.bssid?.caseInsensitiveCompare(bssid) == .orderedSame }) {
                    return target
                }
                continue
            }
            return target
        }
        return nil
    }

    func dormNetwork(forSSID ssid: String) -> DormNetwork? {
        dormNetworks.first { $0.ssid.trimmingCharacters(in: .whitespacesAndNewlines) == ssid }
    }

    /// 是否具备执行校园认证的最小配置。
    var hasCampusCredentials: Bool {
        !campusUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && campusAuthMode != .disabled
            && !campusList.isEmpty
    }
}

// MARK: - 配置校验

public struct ConfigIssue: Equatable, Sendable {
    public enum Level: String, Sendable { case info, warning, error }
    public let level: Level
    public let message: String

    public init(_ level: Level, _ message: String) {
        self.level = level
        self.message = message
    }
}

public enum ConfigValidation {
    public static let connectivityRange: ClosedRange<TimeInterval> = 15...3600
    public static let scheduledScanRange: ClosedRange<TimeInterval> = 60...3600

    /// 规范化：裁剪空白、去重、宿舍网络并入白名单、修正越界间隔、丢弃非法 URL。
    public static func normalize(_ input: AppConfig) -> AppConfig {
        var config = input
        config.whitelistSSIDs = AppConfig.cleaned(input.whitelistSSIDs)
        config.campusSSIDs = AppConfig.cleaned(input.campusSSIDs)

        var dormSeen = Set<String>()
        config.dormNetworks = input.dormNetworks.compactMap { dorm -> DormNetwork? in
            let ssid = dorm.ssid.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ssid.isEmpty, dormSeen.insert(ssid).inserted else { return nil }
            var copy = dorm
            copy.ssid = ssid
            if let bssid = copy.bssid?.trimmingCharacters(in: .whitespacesAndNewlines), bssid.isEmpty {
                copy.bssid = nil
            }
            return copy
        }
        // 宿舍网络自动纳入白名单
        config.whitelistSSIDs = config.effectiveWhitelist

        // 校园 SSID 与白名单互斥：校园优先，从白名单里剔除
        let campus = Set(config.campusSSIDs)
        config.whitelistSSIDs = config.whitelistSSIDs.filter { !campus.contains($0) }

        config.campusUsername = input.campusUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        config.connectivityInterval = min(
            max(input.connectivityInterval, connectivityRange.lowerBound),
            connectivityRange.upperBound
        )
        config.scheduledScanInterval = min(
            max(input.scheduledScanInterval, scheduledScanRange.lowerBound),
            scheduledScanRange.upperBound
        )
        config.probeURLs = input.probeURLs.filter { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines))?.host != nil }
        if config.probeURLs.isEmpty { config.probeURLs = AppConfig.defaultProbeURLs }
        if URL(string: config.srunBaseURL)?.host == nil { config.srunBaseURL = "https://net.szu.edu.cn" }
        if config.scheduledScanEnabled && !config.hasDormTargets { config.scheduledScanEnabled = false }
        return config
    }

    public static func issues(_ raw: AppConfig) -> [ConfigIssue] {
        let config = normalize(raw)
        var issues: [ConfigIssue] = []

        if config.campusSSIDs.isEmpty {
            issues.append(ConfigIssue(.error, "未配置校园 Wi-Fi SSID：不会对任何网络提交校园认证。"))
        }
        if config.dormNetworks.isEmpty {
            issues.append(ConfigIssue(.info, "未配置宿舍优先网络：开盖后不会主动扫描切换。"))
        }
        if config.autoAuthEnabled && config.campusAuthMode != .disabled {
            if config.campusUsername.isEmpty {
                issues.append(ConfigIssue(.error, "未填写校园认证账号：无法自动认证。"))
            }
        }
        if config.campusAuthMode == .eportal && config.eportalLoginURL.isEmpty {
            issues.append(ConfigIssue(.warning, "认证方式为 ePortal 但未填写登录地址。"))
        }
        if config.campusAuthMode == .srun && URL(string: config.srunBaseURL)?.host == nil {
            issues.append(ConfigIssue(.error, "SRun 门户地址无效。"))
        }
        // 冲突检测基于"用户原始输入"（normalize 会把校园 SSID 从白名单里剔除）
        let declaredWhitelist = Set(AppConfig.cleaned(raw.whitelistSSIDs))
            .union(raw.dormNetworks.map { $0.ssid.trimmingCharacters(in: .whitespacesAndNewlines) })
        let overlaps = Set(AppConfig.cleaned(raw.campusSSIDs)).intersection(declaredWhitelist.filter { !$0.isEmpty })
        if !overlaps.isEmpty {
            issues.append(ConfigIssue(.warning, "以下 SSID 同时出现在校园与白名单列表，已按校园网处理：\(overlaps.sorted().joined(separator: "、"))"))
        }
        return issues
    }

    public static func isReadyForAuth(_ raw: AppConfig) -> Bool {
        normalize(raw).hasCampusCredentials
    }
}
