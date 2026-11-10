import XCTest
@testable import CampusNetCore

final class ConfigTests: XCTestCase {
    func testNormalizeAddsDormToWhitelist() {
        var config = AppConfig()
        config.whitelistSSIDs = ["热点"]
        config.dormNetworks = [DormNetwork(ssid: "宿舍-WiFi", bssid: nil, requiresPassword: true)]
        let normalized = ConfigValidation.normalize(config)

        XCTAssertEqual(normalized.effectiveWhitelist, ["热点", "宿舍-WiFi"])
        XCTAssertTrue(normalized.isWhitelistSSID("宿舍-WiFi"))
        XCTAssertEqual(normalized.effectiveWhitelist, normalized.whitelistSSIDs)
    }

    func testCampusSSIDTakesPrecedenceOverWhitelist() {
        var config = AppConfig()
        config.campusSSIDs = ["Campus-WiFi"]
        config.whitelistSSIDs = ["Campus-WiFi", "热点"]
        let normalized = ConfigValidation.normalize(config)

        XCTAssertTrue(normalized.isCampusSSID("Campus-WiFi"))
        XCTAssertFalse(normalized.isWhitelistSSID("Campus-WiFi"), "校园网不能被当成静默白名单")
        XCTAssertEqual(normalized.whitelistSSIDs, ["热点"])

        let issues = ConfigValidation.issues(config)
        XCTAssertTrue(issues.contains { $0.message.contains("同时出现在校园与白名单") })
    }

    func testExactSSIDMatching() {
        var config = AppConfig()
        config.campusSSIDs = ["Campus-WiFi"]
        config.whitelistSSIDs = ["宿舍-WiFi"]
        let normalized = ConfigValidation.normalize(config)

        XCTAssertFalse(normalized.isCampusSSID("Campus-WiFi-5G"))
        XCTAssertFalse(normalized.isCampusSSID("My Campus-WiFi"))
        XCTAssertTrue(normalized.isCampusSSID("Campus-WiFi"))
        XCTAssertTrue(normalized.isWhitelistSSID("宿舍-WiFi"), "支持中文 SSID 精确匹配")
    }

    func testDormPriorityOrderNotSignalStrength() {
        var config = AppConfig()
        config.dormNetworks = [
            DormNetwork(ssid: "宿舍主路由", requiresPassword: true),
            DormNetwork(ssid: "宿舍备用", bssid: "aa:bb:cc:dd:ee:ff", requiresPassword: false)
        ]
        let normalized = ConfigValidation.normalize(config)

        // 备用网络信号更强，但主路由优先级更高
        let visible = [
            ScannedNetwork(ssid: "宿舍备用", bssid: "aa:bb:cc:dd:ee:ff", rssi: -40),
            ScannedNetwork(ssid: "宿舍主路由", bssid: nil, rssi: -85)
        ]
        XCTAssertEqual(normalized.matchDormTarget(in: visible)?.ssid, "宿舍主路由")

        // 主路由不可见时才退到备用
        let onlyBackup = [ScannedNetwork(ssid: "宿舍备用", bssid: "aa:bb:cc:dd:ee:ff", rssi: -40)]
        XCTAssertEqual(normalized.matchDormTarget(in: onlyBackup)?.ssid, "宿舍备用")

        // BSSID 限定不匹配时不切换（但仍不破坏同 SSID 的其它 AP 漫游判定）
        let wrongBSSID = [ScannedNetwork(ssid: "宿舍备用", bssid: "11:11:11:11:11:11", rssi: -40)]
        XCTAssertNil(normalized.matchDormTarget(in: wrongBSSID))
    }

    func testIntervalClamping() {
        var config = AppConfig()
        config.connectivityInterval = 1
        config.scheduledScanInterval = 10_000
        let normalized = ConfigValidation.normalize(config)
        XCTAssertEqual(normalized.connectivityInterval, 15)
        XCTAssertEqual(normalized.scheduledScanInterval, 3600)
    }

    func testScheduledScanDisabledWithoutDormTargets() {
        var config = AppConfig()
        config.scheduledScanEnabled = true
        let normalized = ConfigValidation.normalize(config)
        XCTAssertFalse(normalized.scheduledScanEnabled)
    }

    func testDuplicateAndBlankSSIDsAreCleaned() {
        var config = AppConfig()
        config.campusSSIDs = ["  Campus-WiFi  ", "", "Campus-WiFi", "   "]
        let normalized = ConfigValidation.normalize(config)
        XCTAssertEqual(normalized.campusSSIDs, ["Campus-WiFi"])
    }

    func testPartialJSONUsesDefaults() throws {
        let json = #"{"campusSSIDs":["Campus-WiFi"],"campusUsername":"2024000000"}"#
        let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.campusSSIDs, ["Campus-WiFi"])
        XCTAssertEqual(decoded.connectivityInterval, 30)
        XCTAssertFalse(decoded.scheduledScanEnabled)
        XCTAssertEqual(decoded.scheduledScanInterval, 180)
        XCTAssertEqual(decoded.srunXXTEAVariant, .reference)
        XCTAssertEqual(decoded.srunBaseURL, "https://net.szu.edu.cn")
    }

    func testConfigStoreRoundTripAndRecovery() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cnp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("config.json")
        let store = ConfigStore(fileURL: url)

        var config = AppConfig()
        config.campusSSIDs = ["Campus-WiFi"]
        config.campusUsername = "2024000000"
        config.dormNetworks = [DormNetwork(ssid: "宿舍-WiFi")]
        try store.save(config)

        guard case .loaded(let loaded) = store.load() else {
            return XCTFail("应当读回已保存的配置")
        }
        XCTAssertEqual(loaded.campusSSIDs, ["Campus-WiFi"])
        XCTAssertTrue(loaded.whitelistSSIDs.contains("宿舍-WiFi"))

        // 损坏文件回退默认值
        try Data("{ not json".utf8).write(to: url)
        guard case .recoveredDefault = store.load() else {
            return XCTFail("损坏配置应回退默认值")
        }

        // 不存在时创建默认配置
        try FileManager.default.removeItem(at: url)
        guard case .createdDefault(let defaults) = store.load() else {
            return XCTFail("缺失配置应创建默认值")
        }
        XCTAssertTrue(defaults.campusSSIDs.isEmpty, "未配置时不编造 SSID")
    }

    func testExampleJSONHasNoSecrets() {
        let json = ConfigStore.exampleJSON()
        XCTAssertFalse(json.contains("campusPassword"), "示例配置不得包含密码字段")
        XCTAssertFalse(json.contains("secret"))
        XCTAssertTrue(json.contains("2024000000"))
    }

    /// 仓库里的示例配置必须始终能被当前 AppConfig 解码（防止文档与代码脱节）。
    func testExampleConfigFileDecodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("examples/config.example.json")
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
        let normalized = ConfigValidation.normalize(decoded)

        XCTAssertEqual(normalized.campusSSIDs, ["Campus-WiFi"])
        XCTAssertEqual(normalized.campusUsername, "2024000000")
        XCTAssertEqual(normalized.dormNetworks.first?.ssid, "宿舍-WiFi")
        XCTAssertEqual(normalized.dormNetworks.count, 2)
        XCTAssertTrue(normalized.whitelistSSIDs.contains("宿舍-WiFi-备用"), "宿舍网络应自动并入白名单")
        XCTAssertEqual(normalized.srunXXTEAVariant, .reference)
        XCTAssertEqual(normalized.connectivityInterval, 30)
        XCTAssertFalse(normalized.scheduledScanEnabled)
    }
}
