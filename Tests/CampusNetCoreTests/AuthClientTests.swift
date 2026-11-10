import XCTest
@testable import CampusNetCore

final class AuthClientTests: XCTestCase {
    private func campusWiFi(ssid: String = "Campus-WiFi") -> FakeWiFi {
        FakeWiFi(snapshot: WiFiSnapshot(power: .on, interfaceName: "en0", interfaceAvailable: true, ssid: ssid))
    }

    private func request(mode: CampusAuthMode = .srun, eportal: String? = nil) -> AuthRequest {
        AuthRequest(
            username: "2024000000",
            password: "p@ss w0rd!",
            campusSSIDs: ["Campus-WiFi"],
            mode: mode,
            srunBaseURL: "https://net.szu.edu.cn",
            eportalLoginURL: eportal
        )
    }

    func testSRunLoginFlow() async {
        let transport = ScriptedTransport(responses: [
            "get_challenge": .success(httpResponse(#"_({"challenge":"abc123","client_ip":"10.1.2.3"})"#)),
            "srun_portal": .success(httpResponse(#"_({"error":"ok","res":"ok"})"#))
        ], fallback: .success(httpResponse("<html><script>var ac_id=88;</script></html>")))

        let client = CampusAuthClient(transport: transport, wifi: campusWiFi(), log: MemoryLog())
        let result = await client.login(request())

        XCTAssertTrue(result.success, result.message)
        XCTAssertEqual(transport.requests.count, 3)

        guard let portalURL = transport.requests.last?.url, let components = URLComponents(url: portalURL, resolvingAgainstBaseURL: false) else {
            return XCTFail("未捕获登录请求")
        }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        XCTAssertEqual(items["action"], "login")
        XCTAssertEqual(items["ac_id"], "88")
        XCTAssertEqual(items["ip"], "10.1.2.3")
        XCTAssertEqual(items["n"], "200")
        XCTAssertEqual(items["type"], "1")

        let passwordDigest = SRunCrypto.passwordDigest(password: "p@ss w0rd!", challenge: "abc123")
        XCTAssertEqual(items["password"], "{MD5}" + passwordDigest)
        XCTAssertFalse(items["password"]!.contains("p@ss"), "登录请求里不得出现明文密码")

        let infoJSON = SRunCrypto.infoJSON(username: "2024000000", password: "p@ss w0rd!", ip: "10.1.2.3", acid: "88")
        let expectedInfo = SRunCrypto.encodeInfo(json: infoJSON, challenge: "abc123")
        XCTAssertEqual(items["info"], expectedInfo)
        XCTAssertEqual(
            items["chksum"],
            SRunCrypto.checksum(
                challenge: "abc123",
                username: "2024000000",
                passwordMD5: passwordDigest,
                acID: "88",
                clientIP: "10.1.2.3",
                info: expectedInfo
            )
        )
    }

    func testSRunBadPasswordIsClassified() async {
        let transport = ScriptedTransport(responses: [
            "get_challenge": .success(httpResponse(#"_({"challenge":"abc123","client_ip":"10.1.2.3"})"#)),
            "srun_portal": .success(httpResponse(#"_({"error":"E2553","error_msg":"密码错误"})"#))
        ], fallback: .success(httpResponse("<html>ac_id=1</html>")))

        let client = CampusAuthClient(transport: transport, wifi: campusWiFi(), log: MemoryLog())
        let result = await client.login(request())

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.kind, .badCredentials)
    }

    func testSRunChallengeErrorIsReported() async {
        let transport = ScriptedTransport(responses: [
            "get_challenge": .success(httpResponse(#"_({"error":"E1001","error_msg":"账号不存在"})"#))
        ], fallback: .success(httpResponse("<html>ac_id=1</html>")))

        let client = CampusAuthClient(transport: transport, wifi: campusWiFi(), log: MemoryLog())
        let result = await client.login(request())
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.kind, .portalRejected)
        XCTAssertTrue(result.message.contains("账号不存在"))
    }

    func testSRunNetworkFailureIsNetworkKind() async {
        let transport = ScriptedTransport(responses: [
            "get_challenge": .failure(HTTPError.timeout)
        ], fallback: .success(httpResponse("<html>ac_id=1</html>")))

        let client = CampusAuthClient(transport: transport, wifi: campusWiFi(), log: MemoryLog())
        let result = await client.login(request())
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.kind, .network)
    }

    func testEPortalLoginFlow() async {
        let transport = ScriptedTransport(responses: [:], fallback: .success(httpResponse(#"({"result":"0","msg":"认证成功"})"#)))
        let client = CampusAuthClient(transport: transport, wifi: campusWiFi(), log: MemoryLog())
        let result = await client.login(request(mode: .eportal, eportal: "http://10.0.0.1:801/eportal/portal/login"))

        XCTAssertTrue(result.success, result.message)
        let url = try? XCTUnwrap(transport.requests.first?.url)
        let items = URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let dict = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(dict["user_account"], ",0,2024000000")
        XCTAssertEqual(dict["user_password"], "p@ss w0rd!")
    }

    func testEPortalMissingURL() async {
        let transport = ScriptedTransport(responses: [:])
        let client = CampusAuthClient(transport: transport, wifi: campusWiFi(), log: MemoryLog())
        let result = await client.login(request(mode: .eportal, eportal: nil))
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.kind, .missingConfig)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testDisabledModeSendsNothing() async {
        let transport = ScriptedTransport(responses: [:])
        let client = CampusAuthClient(transport: transport, wifi: campusWiFi(), log: MemoryLog())
        let result = await client.login(request(mode: .disabled))
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.kind, .disabled)
        XCTAssertTrue(transport.requests.isEmpty)
    }
}

final class ProbeTests: XCTestCase {
    func testReachableOn204() async {
        let transport = ScriptedTransport(responses: [:], fallback: .success(HTTPResponse(statusCode: 204, body: Data())))
        let probe = HTTPConnectivityProbe(transport: transport, urls: ["https://connectivitycheck.gstatic.com/generate_204"])
        let result = await probe.probe()
        XCTAssertTrue(result.reachable)
    }

    func testReachableOnPortalProbeSuccessBody() async {
        let transport = ScriptedTransport(responses: [:], fallback: .success(httpResponse("<HTML><BODY>Success</BODY></HTML>")))
        let probe = HTTPConnectivityProbe(transport: transport, urls: ["https://captive.apple.com/hotspot-detect.html"])
        let result = await probe.probe()
        XCTAssertTrue(result.reachable)
    }

    func testRedirectCountsAsPortal() async {
        let transport = ScriptedTransport(responses: [:], fallback: .success(HTTPResponse(statusCode: 302, body: Data())))
        let probe = HTTPConnectivityProbe(transport: transport, urls: ["https://captive.apple.com/hotspot-detect.html"])
        let result = await probe.probe()
        XCTAssertFalse(result.reachable)
        XCTAssertTrue(result.portalLikely)
        XCTAssertEqual(result.respondedEndpoints, 1)
    }

    func testAllTransportFailuresAreNotPortal() async {
        let transport = ScriptedTransport(responses: [:], fallback: .failure(HTTPError.transport("no route to host")))
        let probe = HTTPConnectivityProbe(
            transport: transport,
            urls: [
                "https://captive.apple.com/hotspot-detect.html",
                "https://connectivitycheck.gstatic.com/generate_204"
            ]
        )
        let result = await probe.probe()
        XCTAssertFalse(result.reachable)
        XCTAssertFalse(result.portalLikely)
        XCTAssertEqual(result.respondedEndpoints, 0)
        XCTAssertEqual(transport.requests.count, 2, "多端点都必须探测过")
    }
}
