import Foundation
@testable import CampusNetCore

/// 可编排的 HTTP 假实现：按 URL 路径关键字返回脚本化响应，并记录收到的请求。
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    private let lock = ScopedLock()
    private var rules: [(match: String, response: Result<HTTPResponse, Error>)]
    private var _requests: [HTTPRequest] = []
    private var fallback: Result<HTTPResponse, Error>

    init(
        responses: [String: Result<HTTPResponse, Error>],
        fallback: Result<HTTPResponse, Error> = .failure(HTTPError.transport("未配置的端点"))
    ) {
        self.rules = responses.map { ($0.key, $0.value) }
        self.fallback = fallback
    }

    var requests: [HTTPRequest] { lock.sync { _requests } }

    func setResponse(for match: String, _ result: Result<HTTPResponse, Error>) {
        lock.sync {
            rules.removeAll { $0.match == match }
            rules.append((match, result))
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let result = lock.sync { () -> Result<HTTPResponse, Error> in
            _requests.append(request)
            let path = request.url.absoluteString
            let matched = rules.last { path.contains($0.match) }
            return matched?.response ?? fallback
        }
        return try result.get()
    }
}
func httpResponse(_ body: String, status: Int = 200) -> HTTPResponse {
    HTTPResponse(statusCode: status, body: Data(body.utf8))
}
