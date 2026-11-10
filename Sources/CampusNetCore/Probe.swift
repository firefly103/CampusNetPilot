import Foundation

/// 多端点 HTTP 连通性探测。
///
/// 设计要点（对应需求"联网检测不能只看外部 DNS 的 TCP 53"）：
///  * 默认同时探测 Apple 门户探测端点与 Google 204 端点；任一判定在线即在线；
///  * 只有"所有端点都不可用"才认为离线，避免单点故障或系统代理/VPN 抖动被当成掉线；
///  * 记录是否有端点返回了 HTTP 响应，用于区分"被门户拦截"与"纯传输层失败"。
public struct HTTPConnectivityProbe: ConnectivityProbing {
    private let transport: HTTPTransport
    private let urls: [URL]
    private let timeout: TimeInterval

    public init(transport: HTTPTransport, urls: [String] = AppConfig.defaultProbeURLs, timeout: TimeInterval = 6) {
        self.transport = transport
        self.urls = urls.compactMap(URL.init(string:))
        self.timeout = timeout
    }

    public func probe() async -> ProbeResult {
        guard !urls.isEmpty else {
            return ProbeResult(reachable: false, portalLikely: false, detail: "未配置探测端点", respondedEndpoints: 0)
        }

        var responded = 0
        var portalLikely = false
        var details: [String] = []

        for url in urls {
            do {
                let response = try await transport.send(HTTPRequest(url: url, timeout: timeout))
                responded += 1
                if response.statusCode == 204 {
                    return ProbeResult(reachable: true, portalLikely: false, detail: "HTTP 204", respondedEndpoints: responded)
                }
                let text = response.text.lowercased()
                if response.statusCode == 200, text.contains("success") {
                    return ProbeResult(reachable: true, portalLikely: false, detail: "门户探测端点返回成功", respondedEndpoints: responded)
                }
                if (300..<400).contains(response.statusCode) {
                    portalLikely = true
                    details.append("\(url.host ?? "端点") 重定向（\(response.statusCode)）")
                } else {
                    portalLikely = true
                    details.append("\(url.host ?? "端点") 返回异常内容（\(response.statusCode)）")
                }
            } catch {
                details.append("\(url.host ?? "端点") 不可达：\(error.localizedDescription)")
            }
        }

        return ProbeResult(
            reachable: false,
            portalLikely: portalLikely,
            detail: details.joined(separator: "；"),
            respondedEndpoints: responded
        )
    }
}
