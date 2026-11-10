import Foundation

/// 配置文件读写（~/Library/Application Support/CampusNetPilot/config.json）。
/// 只保存非敏感配置；密码一律放 Keychain。
public struct ConfigStore: Sendable {
    public let fileURL: URL
    private let log: LogSink?

    public init(fileURL: URL = ConfigStore.defaultURL, log: LogSink? = nil) {
        self.fileURL = fileURL
        self.log = log
    }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("CampusNetPilot", isDirectory: true)
    }

    public static var defaultURL: URL {
        defaultDirectory.appendingPathComponent("config.json")
    }

    public enum LoadResult: Sendable {
        case loaded(AppConfig)
        case createdDefault(AppConfig)
        case recoveredDefault(String)
    }

    public func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .createdDefault(ConfigValidation.normalize(AppConfig()))
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            return .loaded(ConfigValidation.normalize(decoded))
        } catch {
            log?.log(.warn, "配置文件损坏，已回退默认值：\(error.localizedDescription)")
            return .recoveredDefault(error.localizedDescription)
        }
    }

    public func save(_ config: AppConfig) throws {
        let normalized = ConfigValidation.normalize(config)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(normalized)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 原子写入后收紧权限，避免其他用户读取（其中不含密码，但仍按最小暴露处理）。
        try data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// 供 README / 示例文件使用的模板（不含任何真实账号密码）。
    public static func exampleJSON() -> String {
        let example = AppConfig()
        var config = example
        config.whitelistSSIDs = ["宿舍-Wi-Fi", "iPhone 热点"]
        config.dormNetworks = [DormNetwork(ssid: "宿舍-Wi-Fi", bssid: nil, requiresPassword: true)]
        config.campusSSIDs = ["Campus-WiFi"]
        config.campusUsername = "2024000000"
        config.campusAuthMode = .srun
        config.srunBaseURL = "https://net.szu.edu.cn"
        config.connectivityInterval = 30
        config.scheduledScanEnabled = false
        config.scheduledScanInterval = 180
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(ConfigValidation.normalize(config)) {
            return String(decoding: data, as: UTF8.self)
        }
        return "{}"
    }
}
