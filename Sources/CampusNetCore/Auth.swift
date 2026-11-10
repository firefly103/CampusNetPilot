import Foundation

/// SRun（深澜）/ ePortal 认证客户端。
///
/// 移植自参考项目 AutoSZUWeb（MIT）的 SRun 流程：ac_id 探测 → get_challenge →
/// XXTEA+定制 Base64 info → SHA1 chksum → srun_portal 登录。
/// 与参考实现的差异（有意为之）：
///  * 保留系统默认的 TLS 证书与主机名校验（参考实现关闭了校验）；
///  * 提交前再次校验当前 SSID 仍属于允许认证的校园网络；
///  * 不记录任何含密码/Token 的完整 URL。
public struct CampusAuthClient: CampusAuthenticating {
    private let transport: HTTPTransport
    private let wifi: WiFiControlling
    private let log: LogSink
    private let timeout: TimeInterval

    public init(transport: HTTPTransport, wifi: WiFiControlling, log: LogSink, timeout: TimeInterval = 12) {
        self.transport = transport
        self.wifi = wifi
        self.log = log
        self.timeout = timeout
    }

    public func login(_ request: AuthRequest) async -> AuthResult {
        // 双保险：即便状态机已经判断过，提交请求前再读一次真实连接。
        let snapshot = await wifi.snapshot()
        guard let ssid = snapshot.ssid, request.campusSSIDs.contains(ssid) else {
            return .failure(.notCampus, "当前未连接允许认证的校园 Wi-Fi，已放弃本次认证请求")
        }
        guard request.mode != .disabled else {
            return .failure(.disabled, "自动认证已关闭")
        }
        switch request.mode {
        case .disabled:
            return .failure(.disabled, "自动认证已关闭")
        case .srun:
            return await loginSRun(request, ssid: ssid)
        case .eportal:
            return await loginEPortal(request)
        }
    }

    // MARK: SRun

    private func loginSRun(_ request: AuthRequest, ssid: String) async -> AuthResult {
        guard let base = URL(string: request.srunBaseURL) else {
            return .failure(.missingConfig, "SRun 门户地址无效")
        }
        log.log(.info, "开始 SRun 认证（SSID：\(ssid)）")

        // 1) 访问门户首页：建立会话 Cookie 并探测 ac_id（失败回退 "1"）。
        var acID = "1"
        if let page = try? await transport.send(HTTPRequest(url: base, timeout: timeout)) {
            if let found = TextTools.firstInteger(after: "ac_id=", in: page.text) {
                acID = found
            }
        }

        // 2) 获取 challenge 与客户端 IP。
        var challengeComponents = URLComponents(
            url: base.appendingPathComponent("cgi-bin/get_challenge"),
            resolvingAgainstBaseURL: false
        )
        challengeComponents?.queryItems = [
            URLQueryItem(name: "callback", value: "_"),
            URLQueryItem(name: "username", value: request.username),
            URLQueryItem(name: "ip", value: "")
        ]
        guard let challengeURL = challengeComponents?.url else {
            return .failure(.invalidResponse, "无法构造 challenge 请求地址")
        }

        let challengeResponse: HTTPResponse
        do {
            challengeResponse = try await transport.send(HTTPRequest(url: challengeURL, timeout: timeout))
        } catch {
            return .failure(.network, "获取 challenge 失败：\(error.localizedDescription)")
        }

        guard let challengeObject = TextTools.decodeJSONObject(challengeResponse.text) else {
            return .failure(.invalidResponse, "challenge 响应不是合法 JSON")
        }
        let challengeError = (challengeObject["error"] as? String) ?? ""
        if !challengeError.isEmpty, challengeError != "ok" {
            let message = (challengeObject["error_msg"] as? String) ?? challengeError
            return .failure(mapPortalError(challengeError, message: message), "获取 challenge 失败：\(message)")
        }
        guard let challenge = challengeObject["challenge"] as? String, !challenge.isEmpty,
              let clientIP = challengeObject["client_ip"] as? String, !clientIP.isEmpty else {
            return .failure(.invalidResponse, "认证服务器未返回 challenge 或客户端 IP")
        }

        // 3) 构造加密载荷与校验串。
        let passwordMD5 = SRunCrypto.passwordDigest(password: request.password, challenge: challenge)
        let infoJSON = SRunCrypto.infoJSON(
            username: request.username,
            password: request.password,
            ip: clientIP,
            acid: acID
        )
        let info = SRunCrypto.encodeInfo(json: infoJSON, challenge: challenge, variant: request.xxteaVariant)
        let checksum = SRunCrypto.checksum(
            challenge: challenge,
            username: request.username,
            passwordMD5: passwordMD5,
            acID: acID,
            clientIP: clientIP,
            info: info
        )

        // 4) 提交登录。
        var portalComponents = URLComponents(
            url: base.appendingPathComponent("cgi-bin/srun_portal"),
            resolvingAgainstBaseURL: false
        )
        portalComponents?.queryItems = [
            URLQueryItem(name: "callback", value: "_"),
            URLQueryItem(name: "action", value: "login"),
            URLQueryItem(name: "username", value: request.username),
            URLQueryItem(name: "password", value: "{MD5}" + passwordMD5),
            URLQueryItem(name: "os", value: "macOS"),
            URLQueryItem(name: "name", value: "macOS"),
            URLQueryItem(name: "double_stack", value: "0"),
            URLQueryItem(name: "info", value: info),
            URLQueryItem(name: "chksum", value: checksum),
            URLQueryItem(name: "ac_id", value: acID),
            URLQueryItem(name: "ip", value: clientIP),
            URLQueryItem(name: "n", value: "200"),
            URLQueryItem(name: "type", value: "1")
        ]
        guard let portalURL = portalComponents?.url else {
            return .failure(.invalidResponse, "无法构造登录请求地址")
        }

        let portalResponse: HTTPResponse
        do {
            portalResponse = try await transport.send(HTTPRequest(url: portalURL, timeout: timeout))
        } catch {
            return .failure(.network, "提交认证失败：\(error.localizedDescription)")
        }

        guard let result = TextTools.decodeJSONObject(portalResponse.text) else {
            return .failure(.invalidResponse, "认证响应不是合法 JSON")
        }
        if isSRunSuccess(result) {
            log.log(.info, "SRun 认证成功（ac_id=\(acID)）")
            return .ok("SRun 认证成功")
        }

        let error = (result["error"] as? String) ?? ""
        let message = (result["error_msg"] as? String) ?? (result["res"] as? String) ?? "认证失败"
        return .failure(mapPortalError(error, message: message), message)
    }

    private func isSRunSuccess(_ object: [String: Any]) -> Bool {
        if let value = object["error"] as? String, value == "ok" { return true }
        if let value = object["res"] as? String, value == "ok" { return true }
        if let st = object["st"] {
            if let number = st as? Int { return number == 1 }
            if let number = st as? NSNumber { return number.intValue == 1 }
            if let flag = st as? Bool { return flag }
            if let text = st as? String { return text == "1" || text.lowercased() == "true" }
        }
        return false
    }

    private func mapPortalError(_ code: String, message: String) -> AuthFailureKind {
        let lowered = message.lowercased()
        if code.contains("E2553") || lowered.contains("密码") || lowered.contains("password") || lowered.contains("passwd") {
            return .badCredentials
        }
        return .portalRejected
    }

    // MARK: ePortal

    private func loginEPortal(_ request: AuthRequest) async -> AuthResult {
        guard let raw = request.eportalLoginURL, !raw.isEmpty,
              var components = URLComponents(string: raw) else {
            return .failure(.missingConfig, "ePortal 登录地址未配置")
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "user_account", value: ",0," + request.username))
        items.append(URLQueryItem(name: "user_password", value: request.password))
        components.queryItems = items
        guard let url = components.url else {
            return .failure(.missingConfig, "ePortal 登录地址无效")
        }

        log.log(.info, "开始 ePortal 认证")
        let response: HTTPResponse
        do {
            response = try await transport.send(HTTPRequest(url: url, timeout: timeout))
        } catch {
            return .failure(.network, "ePortal 请求失败：\(error.localizedDescription)")
        }

        guard let object = TextTools.decodeJSONObject(response.text) else {
            return .failure(.invalidResponse, "ePortal 响应不是合法 JSON")
        }
        let message = (object["msg"] as? String) ?? ""
        let result = (object["result"] as? String) ?? ""
        if result == "0" || result == "1" || message.contains("认证成功") {
            log.log(.info, "ePortal 认证成功")
            return .ok("ePortal 认证成功")
        }
        if message.contains("密码") { return .failure(.badCredentials, message) }
        log.log(.warn, "ePortal 认证被拒绝：\(message)")
        return .failure(.portalRejected, message.isEmpty ? "ePortal 认证失败" : message)
    }
}
