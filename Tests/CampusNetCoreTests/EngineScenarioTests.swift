import XCTest
@testable import CampusNetCore

/// 与系统接口分离后的状态机行为测试：合盖/开盖、扫描、切换、认证、定时器。
/// 这些用例全部在无 Wi-Fi 硬件、无校园网的环境下可重复执行（Linux CI 也能跑）。
final class EngineScenarioTests: XCTestCase {

    // MARK: 1. 合盖后停止产生新任务

    func testLidClosedStopsProbingAndScheduling() async {
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .offline())
        await harness.engine.handle(.applicationStarted)

        var status = await harness.status()
        XCTAssertEqual(status.phase, .campusOnline)
        XCTAssertTrue(harness.scheduler.has(.connectivity))

        let probesBefore = harness.probe.count
        let scansBefore = harness.wifi.scanCount

        await harness.engine.handle(.lidChanged(closed: true))
        status = await harness.status()
        XCTAssertEqual(status.phase, .paused)
        XCTAssertEqual(status.pauseReason, .lidClosed)
        XCTAssertGreaterThan(harness.scheduler.totalCancelAll, 0)
        XCTAssertFalse(harness.scheduler.has(.connectivity))

        // 即使有残留的定时器回调被触发，也不会再探测/认证/扫描
        await harness.engine.handle(.deadline(.connectivity))
        XCTAssertEqual(harness.probe.count, probesBefore)
        XCTAssertEqual(harness.wifi.scanCount, scansBefore)
        XCTAssertEqual(harness.auth.count, 1)
    }

    // MARK: 2. 合盖前启动的任务不会在合盖后继续触发操作

    func testInFlightScanResultDiscardedAfterLidClose() async {
        let harness = Harness.make(
            scanOutcomes: [.success([ScannedNetwork(ssid: "宿舍-WiFi")])],
            connectOutcome: .connected(ssid: "宿舍-WiFi")
        )
        let gate = Gate()
        harness.wifi.scanGate = gate

        let startTask = Task { await harness.engine.handle(.applicationStarted) }
        await waitUntil { harness.wifi.scanCount == 1 }
        XCTAssertEqual(harness.wifi.scanCount, 1)

        await harness.engine.handle(.lidChanged(closed: true))
        await gate.open()
        _ = await startTask.value

        XCTAssertEqual(harness.wifi.connectCount, 0, "合盖后收到的旧扫描结果不能再触发切换")
        XCTAssertEqual(harness.probe.count, 0)
        XCTAssertEqual(harness.auth.count, 0)
        let status = await harness.status()
        XCTAssertEqual(status.phase, .paused)
    }

    // MARK: 3. 开盖已连接白名单：零扫描、零探测、零认证

    func testOpenLidOnWhitelistIsCompletelySilent() async {
        let harness = Harness.make(
            snapshot: WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: "宿舍-WiFi")
        )
        await harness.engine.handle(.applicationStarted)

        let status = await harness.status()
        XCTAssertEqual(status.phase, .whitelistSilent)
        XCTAssertEqual(harness.wifi.scanCount, 0)
        XCTAssertEqual(harness.wifi.connectCount, 0)
        XCTAssertEqual(harness.probe.count, 0)
        XCTAssertEqual(harness.auth.count, 0)
        XCTAssertTrue(harness.scheduler.scheduledKeys.isEmpty)
    }

    // MARK: 4. 校园网 + 宿舍网络可见：扫描一次 → 切换 → 静默

    func testCampusWithDormVisibleSwitchesOnceThenSilent() async {
        let harness = Harness.make(
            scanOutcomes: [.success([ScannedNetwork(ssid: "宿舍-WiFi", bssid: "aa:bb:cc:dd:ee:ff", rssi: -48)])],
            connectOutcome: .connected(ssid: "宿舍-WiFi")
        )
        await harness.engine.handle(.applicationStarted)

        let status = await harness.status()
        XCTAssertEqual(status.phase, .whitelistSilent)
        XCTAssertEqual(status.ssid, "宿舍-WiFi")
        XCTAssertEqual(harness.wifi.scanCount, 1)
        XCTAssertEqual(harness.wifi.connectCount, 1)
        XCTAssertEqual(harness.wifi.lastConnectPassword, "dorm-secret", "宿舍网络密码应来自本应用 Keychain 项")
        XCTAssertEqual(harness.probe.count, 0, "切换成功后不再探测互联网")
        XCTAssertEqual(harness.auth.count, 0, "切换成功后不执行校园认证")
        XCTAssertFalse(harness.scheduler.has(.connectivity))
        XCTAssertFalse(harness.scheduler.has(.periodicScan))
    }

    // MARK: 5. 校园网 + 宿舍网络不可见：扫描结束后按需认证，默认不周期扫描

    func testCampusWithoutDormScansThenAuthenticatesOnce() async {
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .offline())
        await harness.engine.handle(.applicationStarted)

        let status = await harness.status()
        XCTAssertEqual(status.phase, .campusOnline)
        XCTAssertEqual(harness.wifi.scanCount, 1, "一次开盖只做一次有界扫描")
        XCTAssertEqual(harness.probe.count, 1)
        XCTAssertEqual(harness.auth.count, 1)
        XCTAssertEqual(harness.auth.requests.first?.username, "2024000000")
        XCTAssertEqual(harness.scheduler.delay(for: .connectivity), 30)
        XCTAssertFalse(harness.scheduler.has(.periodicScan), "定时扫描默认关闭")
    }

    // MARK: 6. 切换失败：不循环跳网，按实际连接状态恢复处理

    func testSwitchFailureDoesNotLoop() async {
        var config = Harness.defaultConfig()
        config.scheduledScanEnabled = true
        let harness = Harness.make(
            config: config,
            scanOutcomes: [.success([ScannedNetwork(ssid: "宿舍-WiFi")]), .success([ScannedNetwork(ssid: "宿舍-WiFi")])],
            connectOutcome: .failed("模拟关联超时"),
            probeResult: .offline()
        )
        await harness.engine.handle(.applicationStarted)

        XCTAssertEqual(harness.wifi.scanCount, 1)
        XCTAssertEqual(harness.wifi.connectCount, 1)
        XCTAssertEqual(harness.auth.count, 1, "切换失败后仍连接校园网，应执行校园网处理")
        var status = await harness.status()
        XCTAssertEqual(status.phase, .campusOnline)

        // 冷却期内即使定时扫描到点，也不再扫描/切换
        await harness.engine.handle(.deadline(.periodicScan))
        XCTAssertEqual(harness.wifi.scanCount, 1)
        XCTAssertEqual(harness.wifi.connectCount, 1)
        XCTAssertTrue(harness.scheduler.has(.periodicScan))

        // 冷却结束后允许再次定时扫描（180 秒间隔，不是连续重试）
        harness.time.advance(200)
        await harness.engine.handle(.deadline(.periodicScan))
        XCTAssertEqual(harness.wifi.scanCount, 2)
        XCTAssertEqual(harness.wifi.connectCount, 2)
        status = await harness.status()
        XCTAssertEqual(status.phase, .campusOnline)
    }

    // MARK: 7. 校园网已在线：不重复登录

    func testCampusOnlineDoesNotLoginAgain() async {
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .online())
        await harness.engine.handle(.applicationStarted)

        let status = await harness.status()
        XCTAssertEqual(status.phase, .campusOnline)
        XCTAssertEqual(harness.auth.count, 0)
        XCTAssertEqual(harness.probe.count, 1)
        XCTAssertTrue(harness.scheduler.has(.connectivity))
    }

    // MARK: 8. 认证失效：按需重新认证并验证结果

    func testSessionExpiryTriggersReauthentication() async {
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .online())
        await harness.engine.handle(.applicationStarted)
        XCTAssertEqual(harness.auth.count, 0)

        harness.probe.setResult(.offline())
        await harness.engine.handle(.deadline(.connectivity))

        XCTAssertEqual(harness.auth.count, 1)
        let status = await harness.status()
        XCTAssertEqual(status.phase, .campusOnline)
        XCTAssertTrue(harness.scheduler.has(.connectivity))
    }

    // MARK: 9. 手动切到白名单/其他网络：校园任务停止，旧结果作废

    func testSwitchingToWhitelistStopsCampusWork() async {
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .online())
        await harness.engine.handle(.applicationStarted)
        let probesBefore = harness.probe.count

        harness.wifi.setSnapshot(
            WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: "热点")
        )
        await harness.engine.handle(.wifiChanged)

        let status = await harness.status()
        XCTAssertEqual(status.phase, .whitelistSilent)
        XCTAssertEqual(harness.probe.count, probesBefore, "切到白名单后不再探测")
        XCTAssertFalse(harness.scheduler.has(.connectivity))
        XCTAssertEqual(harness.auth.count, 0)
    }

    // MARK: 10. 漫游与重复通知不产生重复任务

    func testSameSSIDRoamingDoesNotRescan() async {
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .online())
        await harness.engine.handle(.applicationStarted)
        let scansBefore = harness.wifi.scanCount
        let probesBefore = harness.probe.count

        harness.wifi.setSnapshot(
            WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: "Campus-WiFi", bssid: "11:22:33:44:55:66")
        )
        await harness.engine.handle(.wifiChanged)

        let status = await harness.status()
        XCTAssertEqual(status.phase, .campusOnline)
        XCTAssertEqual(harness.wifi.scanCount, scansBefore, "同 SSID 漫游不需要重新扫描宿舍网络")
        XCTAssertEqual(harness.probe.count, probesBefore)
        XCTAssertTrue(harness.scheduler.has(.connectivity))
    }

    func testDuplicateLidNotificationsAreIdempotent() async {
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .online())
        await harness.engine.handle(.applicationStarted)

        await harness.engine.handle(.lidChanged(closed: true))
        let cancelAllAfterFirst = harness.scheduler.totalCancelAll
        await harness.engine.handle(.lidChanged(closed: true))
        XCTAssertEqual(harness.scheduler.totalCancelAll, cancelAllAfterFirst, "重复的合盖通知不应重复清理")
        let status = await harness.status()
        XCTAssertEqual(status.phase, .paused)
    }

    // MARK: 11. 定时扫描开关与定时器生命周期

    func testPeriodicScanToggleManagesTimer() async {
        var config = Harness.defaultConfig()
        config.scheduledScanEnabled = false
        let harness = Harness.make(config: config, scanOutcomes: [.success([])], probeResult: .online())
        await harness.engine.handle(.applicationStarted)
        XCTAssertFalse(harness.scheduler.has(.periodicScan))

        var enabled = config
        enabled.scheduledScanEnabled = true
        await harness.engine.updateConfig(enabled)
        XCTAssertTrue(harness.scheduler.has(.periodicScan))
        XCTAssertEqual(harness.scheduler.delay(for: .periodicScan), 180)

        // 离开校园网后立即停止
        harness.wifi.setSnapshot(
            WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: "宿舍-WiFi")
        )
        await harness.engine.handle(.wifiChanged)
        XCTAssertFalse(harness.scheduler.has(.periodicScan))

        // 关闭开关后不残留定时器
        harness.wifi.setSnapshot(
            WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: "Campus-WiFi")
        )
        await harness.engine.handle(.wifiChanged)
        await harness.engine.updateConfig(config)
        XCTAssertFalse(harness.scheduler.has(.periodicScan))
    }

    // MARK: 12. 各种异常状态

    func testWiFiOffIsRespected() async {
        let harness = Harness.make(
            snapshot: WiFiSnapshot(power: .off, interfaceName: nil, interfaceAvailable: true, ssid: nil)
        )
        await harness.engine.handle(.applicationStarted)
        let status = await harness.status()
        XCTAssertEqual(status.phase, .disconnected)
        XCTAssertEqual(status.blocker, .wifiOff)
        XCTAssertEqual(harness.wifi.scanCount, 0)
        XCTAssertEqual(harness.probe.count, 0)
    }

    func testSSIDUnreadableBlocksEverything() async {
        let harness = Harness.make(
            snapshot: WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: nil, readability: .permissionDenied)
        )
        await harness.engine.handle(.applicationStarted)
        let status = await harness.status()
        XCTAssertEqual(status.phase, .blocked)
        XCTAssertEqual(status.blocker, .permission)
        XCTAssertEqual(harness.wifi.scanCount, 0)
        XCTAssertEqual(harness.auth.count, 0)
    }

    func testInterfaceUnavailableIsReported() async {
        let harness = Harness.make(
            snapshot: WiFiSnapshot(power: .on, interfaceName: nil, interfaceAvailable: false, ssid: nil)
        )
        await harness.engine.handle(.applicationStarted)
        let status = await harness.status()
        XCTAssertEqual(status.phase, .blocked)
        XCTAssertEqual(status.blocker, .interfaceUnavailable)
        XCTAssertEqual(harness.wifi.scanCount, 0)
    }

    func testScanFailuresAreBounded() async {
        let harness = Harness.make(
            scanOutcomes: [.failed("模拟扫描失败")],
            probeResult: .offline()
        )
        await harness.engine.handle(.applicationStarted)
        XCTAssertEqual(harness.wifi.scanCount, 1)
        XCTAssertTrue(harness.scheduler.has(.scanRetry))
        XCTAssertEqual(harness.scheduler.delay(for: .scanRetry), 2.5)

        await harness.engine.handle(.deadline(.scanRetry))
        XCTAssertEqual(harness.wifi.scanCount, 2)

        await harness.engine.handle(.deadline(.scanRetry))
        XCTAssertEqual(harness.wifi.scanCount, 3, "扫描重试必须有上限")
        XCTAssertFalse(harness.scheduler.has(.scanRetry))
        XCTAssertEqual(harness.auth.count, 1, "扫描失败上限后仍按校园网流程处理")
    }

    func testPasswordErrorStopsRetries() async {
        let harness = Harness.make(
            scanOutcomes: [.success([])],
            probeResult: .offline(),
            authResult: .failure(.badCredentials, "密码错误")
        )
        await harness.engine.handle(.applicationStarted)

        var status = await harness.status()
        XCTAssertEqual(status.phase, .blocked)
        XCTAssertEqual(status.blocker, .badCredentials)
        XCTAssertEqual(harness.auth.count, 1)
        XCTAssertFalse(harness.scheduler.has(.authBackoff))

        // 明确密码错误后不再自动重试
        await harness.engine.handle(.deadline(.connectivity))
        await harness.engine.handle(.deadline(.authBackoff))
        XCTAssertEqual(harness.auth.count, 1)
        XCTAssertEqual(harness.probe.count, 1)

        // 手动重新判断会清除封锁
        harness.auth.setResult(.ok("模拟认证成功"))
        await harness.engine.handle(.manualReevaluate)
        status = await harness.status()
        XCTAssertEqual(status.phase, .campusOnline)
        XCTAssertEqual(harness.auth.count, 2)
    }

    func testMissingCredentialsBlockAuthentication() async {
        var config = Harness.defaultConfig()
        config.campusUsername = ""
        let harness = Harness.make(config: config, scanOutcomes: [.success([])], probeResult: .offline())
        await harness.engine.handle(.applicationStarted)

        let status = await harness.status()
        XCTAssertEqual(status.phase, .blocked)
        XCTAssertEqual(status.blocker, .missingConfig)
        XCTAssertEqual(harness.auth.count, 0, "配置缺失时绝不提交认证")
        XCTAssertFalse(harness.scheduler.has(.connectivity))
    }

    // MARK: 13. 后台维护唤醒：只看盖子与睡眠状态

    func testMaintenanceWakeWithLidClosedStaysPaused() async {
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .online())
        await harness.engine.handle(.applicationStarted)
        await harness.engine.handle(.lidChanged(closed: true))
        let scans = harness.wifi.scanCount
        let probes = harness.probe.count

        await harness.engine.handle(.systemWillSleep)
        await harness.engine.handle(.systemDidWake(displayAwake: false))

        let status = await harness.status()
        XCTAssertEqual(status.phase, .paused)
        XCTAssertEqual(status.pauseReason, .lidClosed)
        XCTAssertEqual(harness.wifi.scanCount, scans)
        XCTAssertEqual(harness.probe.count, probes)
    }

    // MARK: 14. 熄屏 / 锁屏但盖子打开：继续校园网监控

    func testScreenOffWithLidOpenKeepsMonitoring() async {
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .online())
        await harness.engine.handle(.applicationStarted)
        XCTAssertEqual(harness.probe.count, 1)

        // 系统睡眠 → 唤醒，但屏幕尚未点亮（盖子仍是打开的）
        await harness.engine.handle(.systemWillSleep)
        await harness.engine.handle(.systemDidWake(displayAwake: false))

        let status = await harness.status()
        XCTAssertNil(status.pauseReason, "盖子打开时，熄屏/锁屏不应进入暂停")
        XCTAssertFalse(status.lidClosed)
        XCTAssertEqual(status.phase, .campusOnline, "唤醒后应继续校园网监控")
        XCTAssertGreaterThanOrEqual(harness.probe.count, 2, "恢复后应重新评估联网状态")
    }

    func testConnectivityTimerStillRunsWhileDisplayIsOff() async {
        // "仅熄屏"不会给状态机任何事件：定时器与监控保持不变。
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .online())
        await harness.engine.handle(.applicationStarted)
        XCTAssertTrue(harness.scheduler.has(.connectivity))

        await harness.engine.handle(.deadline(.connectivity))
        XCTAssertEqual(harness.probe.count, 2, "熄屏期间到点仍照常检测")
        let status = await harness.status()
        XCTAssertEqual(status.phase, .campusOnline)
        XCTAssertTrue(harness.scheduler.has(.connectivity))
    }
    // MARK: 16. 重复网络事件不得打断进行中的认证

    func testRepeatedNetworkEventsDoNotCancelInFlightAuth() async {
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .offline())
        let gate = Gate()
        harness.auth.authGate = gate

        let startTask = Task { await harness.engine.handle(.applicationStarted) }
        await waitUntil { harness.auth.count == 1 }

        // 认证进行中，连发多次"同 SSID"的网络变化（漫游/门户抖动）
        await harness.engine.handle(.wifiChanged)
        await harness.engine.handle(.wifiChanged)
        await harness.engine.handle(.wifiChanged)

        await gate.open()
        _ = await startTask.value

        let status = await harness.status()

        XCTAssertEqual(status.phase, .campusOnline)
        XCTAssertEqual(harness.auth.count, 1, "同 SSID 通知不应重发认证")
        XCTAssertEqual(harness.probe.count, 1, "也不应重复探测")
    }

    // MARK: 15. "合盖但未睡眠"：轮询发现之前也不允许发出网络请求

    func testLidClosedBeforeScanAbortsEverything() async {
        let lid = LidStateBox(closed: true)
        let harness = Harness.make(
            scanOutcomes: [.success([ScannedNetwork(ssid: "宿舍-WiFi")])],
            probeResult: .offline(),
            lidState: lid
        )
        await harness.engine.handle(.applicationStarted)

        XCTAssertEqual(harness.wifi.scanCount, 0, "盖子合上时不得扫描")
        XCTAssertEqual(harness.wifi.connectCount, 0)
        XCTAssertEqual(harness.probe.count, 0)
        XCTAssertEqual(harness.auth.count, 0)
        let status = await harness.status()
        XCTAssertEqual(status.phase, .paused)
        XCTAssertEqual(status.pauseReason, .lidClosed)
    }

    func testLidClosedMidFlowAbortsAuth() async {
        let lid = LidStateBox(closed: false)
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .offline(), lidState: lid)
        // 探测返回的瞬间模拟"合盖但系统还没睡"（低频轮询尚未发现）
        harness.probe.onProbe = { lid.value = true }

        await harness.engine.handle(.applicationStarted)

        XCTAssertEqual(harness.wifi.scanCount, 1)
        XCTAssertEqual(harness.probe.count, 1)
        XCTAssertEqual(harness.auth.count, 0, "盖子已合上时不得提交校园认证")
        let status = await harness.status()
        XCTAssertEqual(status.phase, .paused)
        XCTAssertEqual(status.pauseReason, .lidClosed)
        XCTAssertFalse(harness.scheduler.has(.connectivity))
    }

    // MARK: 17. 同 SSID 的真实连接变化必须重新评估

    func testSameSSIDIPChangeTriggersReevaluation() async {
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .online())
        await harness.engine.handle(.applicationStarted)
        XCTAssertEqual(harness.probe.count, 1)
        let epochBefore = await harness.status().epoch

        harness.wifi.setSnapshot(
            WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: "Campus-WiFi", ipv4: "10.1.2.3")
        )
        await harness.engine.handle(.wifiChanged)

        let status = await harness.status()
        XCTAssertEqual(status.phase, .campusOnline)
        XCTAssertEqual(harness.probe.count, 2, "IP 变化属于真实连接变化，必须重新评估")
        XCTAssertGreaterThan(status.epoch, epochBefore)
    }

    func testSameSSIDInterfaceChangeTriggersReevaluation() async {
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .online())
        await harness.engine.handle(.applicationStarted)
        XCTAssertEqual(harness.probe.count, 1)

        harness.wifi.setSnapshot(
            WiFiSnapshot(power: .on, interfaceName: "en7", interfaceAvailable: true, ssid: "Campus-WiFi")
        )
        await harness.engine.handle(.wifiChanged)

        XCTAssertEqual(harness.probe.count, 2, "接口变化必须重新评估")
        let status = await harness.status()
        XCTAssertEqual(status.phase, .campusOnline)
    }

    func testDisconnectReconnectSameSSIDReevaluates() async {
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .online())
        await harness.engine.handle(.applicationStarted)

        harness.wifi.setSnapshot(
            WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: nil)
        )
        await harness.engine.handle(.wifiChanged)
        var status = await harness.status()
        XCTAssertEqual(status.phase, .disconnected)

        harness.wifi.setSnapshot(
            WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: "Campus-WiFi")
        )
        await harness.engine.handle(.wifiChanged)
        status = await harness.status()
        XCTAssertEqual(status.phase, .campusOnline)
        XCTAssertEqual(harness.probe.count, 2, "断开重连后必须重新评估")
    }

    func testRoamingBSSIDChangeDoesNotCancelAuth() async {
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .offline())
        let gate = Gate()
        harness.auth.authGate = gate
        let startTask = Task { await harness.engine.handle(.applicationStarted) }
        await waitUntil { harness.auth.count == 1 }

        // 同 SSID 换 AP（BSSID 变化）：不属于连接变化，不应打断认证
        harness.wifi.setSnapshot(
            WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: "Campus-WiFi", bssid: "aa:bb:cc:dd:ee:01")
        )
        await harness.engine.handle(.wifiChanged)
        await gate.open()
        _ = await startTask.value

        let status = await harness.status()
        XCTAssertEqual(status.phase, .campusOnline)
        XCTAssertEqual(harness.auth.count, 1, "漫游不应取消或重发认证")
    }
    // MARK: 附加：未连接时的开盖流程

    func testDisconnectedOpenLidConnectsDormOnce() async {
        let harness = Harness.make(
            snapshot: WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: nil),
            scanOutcomes: [.success([ScannedNetwork(ssid: "宿舍-WiFi")])],
            connectOutcome: .connected(ssid: "宿舍-WiFi")
        )
        await harness.engine.handle(.applicationStarted)

        let status = await harness.status()
        XCTAssertEqual(status.phase, .whitelistSilent)
        XCTAssertEqual(harness.wifi.scanCount, 1)
        XCTAssertEqual(harness.wifi.connectCount, 1)
        XCTAssertEqual(harness.auth.count, 0)
    }

    func testDisconnectedWithoutDormWaitsForSystemAutoConnect() async {
        let harness = Harness.make(
            snapshot: WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: nil),
            scanOutcomes: [.success([])]
        )
        await harness.engine.handle(.applicationStarted)

        var status = await harness.status()
        XCTAssertEqual(status.phase, .disconnected)
        XCTAssertTrue(harness.scheduler.has(.autoConnectRetry))

        // 有界等待：最多 2 次
        await harness.engine.handle(.deadline(.autoConnectRetry))
        XCTAssertTrue(harness.scheduler.has(.autoConnectRetry))
        await harness.engine.handle(.deadline(.autoConnectRetry))
        XCTAssertFalse(harness.scheduler.has(.autoConnectRetry))

        // 系统自动连上白名单后照常静默
        harness.wifi.setSnapshot(
            WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: "宿舍-WiFi")
        )
        await harness.engine.handle(.deadline(.autoConnectRetry))
        status = await harness.status()
        XCTAssertEqual(status.phase, .whitelistSilent)
    }

    // MARK: 附加：其他网络与未配置网络

    func testUnknownNetworkStaysSilentAndNeverAuthenticates() async {
        let harness = Harness.make(
            snapshot: WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: "Coffee-Shop")
        )
        await harness.engine.handle(.applicationStarted)

        let status = await harness.status()
        XCTAssertEqual(status.phase, .otherNetworkSilent)
        XCTAssertEqual(harness.auth.count, 0)
        XCTAssertEqual(harness.probe.count, 0)
        XCTAssertEqual(harness.wifi.scanCount, 0)
    }

    func testManualReevaluateWhilePausedDoesNothing() async {
        let harness = Harness.make(scanOutcomes: [.success([])], probeResult: .online())
        await harness.engine.handle(.applicationStarted)
        await harness.engine.handle(.lidChanged(closed: true))
        let scansBefore = harness.wifi.scanCount

        await harness.engine.handle(.manualReevaluate)
        XCTAssertEqual(harness.wifi.scanCount, scansBefore)
        let status = await harness.status()
        XCTAssertEqual(status.phase, .paused)
    }

    func testAuthNotSubmittedWhenSSIDChangedRightBeforeLogin() async {
        // 认证客户端自身的二次校验：状态机判断为校园网，但提交前 Wi-Fi 已切走。
        let config = Harness.defaultConfig()
        let wifi = FakeWiFi(
            snapshot: WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: "Campus-WiFi")
        )
        let transport = ScriptedTransport(responses: [:])
        let client = CampusAuthClient(transport: transport, wifi: wifi, log: MemoryLog())
        wifi.setSnapshot(WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: "宿舍-WiFi"))

        let result = await client.login(
            AuthRequest(
                username: "2024000000",
                password: "secret",
                campusSSIDs: config.campusList,
                mode: .srun,
                srunBaseURL: config.srunBaseURL,
                eportalLoginURL: nil
            )
        )
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.kind, .notCampus)
        XCTAssertTrue(transport.requests.isEmpty, "不在校园网时不得发出任何认证请求")
    }
}
