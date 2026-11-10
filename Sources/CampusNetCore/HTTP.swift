import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - HTTP 抽象
//
// 便于在测试里替换为假实现；真实实现使用 ephemeral URLSession（内存 Cookie），
// 保持 TLS 证书与主机名校验为系统默认行为，不提供关闭校验的开关。

public struct HTTPRequest: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?
    public var timeout: TimeInterval

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 12) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var body: Data
    public var url: URL?

    public init(statusCode: Int, body: Data, url: URL? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.url = url
    }

    public var text: String { String(decoding: body, as: UTF8.self) }
}

public enum HTTPError: Error, Sendable, Equatable {
    case invalidURL(String)
    case transport(String)
    case timeout
    case cancelled

    public var localizedDescription: String {
        switch self {
        case .invalidURL(let u): return "URL 无效：\(u)"
        case .transport(let m): return "网络错误：\(m)"
        case .timeout: return "请求超时"
        case .cancelled: return "请求已取消"
        }
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let userAgent: String

    public init(timeout: TimeInterval = 12, userAgent: String = URLSessionTransport.defaultUserAgent) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout, 20)
        configuration.httpShouldSetCookies = true
        configuration.httpCookieAcceptPolicy = .always
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        #if canImport(Darwin)
        // Linux Foundation 上 waitsForConnectivity / httpCookieStorage 不可写，
        // 这些差异只影响跨平台单元测试，不影响 macOS 运行行为。
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = HTTPCookieStorage()
        #endif
        // 不实现 URLSessionDelegate 的证书校验回调 —— 保持系统默认的证书与主机名校验。
        self.session = URLSession(configuration: configuration)
        self.userAgent = userAgent
    }

    public static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.timeoutInterval = request.timeout
        urlRequest.httpBody = request.body
        var headers = request.headers
        if headers["User-Agent"] == nil { headers["User-Agent"] = userAgent }
        for (key, value) in headers { urlRequest.setValue(value, forHTTPHeaderField: key) }

        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                let task = session.dataTask(with: urlRequest) { data, response, error in
                    if let error = error as NSError? {
                        if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled {
                            continuation.resume(throwing: HTTPError.cancelled)
                        } else if error.domain == NSURLErrorDomain, error.code == NSURLErrorTimedOut {
                            continuation.resume(throwing: HTTPError.timeout)
                        } else {
                            continuation.resume(throwing: HTTPError.transport(error.localizedDescription))
                        }
                        return
                    }
                    guard let http = response as? HTTPURLResponse else {
                        continuation.resume(throwing: HTTPError.transport("无 HTTP 响应"))
                        return
                    }
                    continuation.resume(returning: HTTPResponse(statusCode: http.statusCode, body: data ?? Data(), url: http.url))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    private final class TaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDataTask?
        private var cancelled = false

        func set(_ task: URLSessionDataTask) {
            lock.lock()
            self.task = task
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }
}

// MARK: - 文本工具

public enum TextTools {
    /// 剥掉 JSONP 外壳：`cb({...})` → `{...}`。
    public static func unwrapJSONP(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let open = trimmed.firstIndex(of: "("), let close = trimmed.lastIndex(of: ")"), open < close else {
            return nil
        }
        return String(trimmed[trimmed.index(after: open)..<close])
    }

    /// JSON 解析：优先整体解析，失败时按 JSONP 外壳再试一次。
    public static func decodeJSONObject(_ text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        if let inner = unwrapJSONP(text), let data = inner.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        return nil
    }

    /// 在文本中查找 `key=` 后紧跟的十进制数字（用于 ac_id 探测）。
    public static func firstInteger(after key: String, in text: String) -> String? {
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: key, range: searchRange) {
            var index = range.upperBound
            var digits = ""
            while index < text.endIndex, text[index].isNumber, text[index].isASCII {
                digits.append(text[index])
                index = text.index(after: index)
            }
            if !digits.isEmpty { return digits }
            searchRange = range.upperBound..<text.endIndex
        }
        return nil
    }
}

// MARK: - 认证请求 / 结果

public struct AuthRequest: Sendable {
    public var username: String
    public var password: String
    public var campusSSIDs: [String]
    public var mode: CampusAuthMode
    public var srunBaseURL: String
    public var eportalLoginURL: String?
    public var xxteaVariant: XXTEAVariant

    public init(
        username: String,
        password: String,
        campusSSIDs: [String],
        mode: CampusAuthMode,
        srunBaseURL: String,
        eportalLoginURL: String?,
        xxteaVariant: XXTEAVariant = .reference
    ) {
        self.username = username
        self.password = password
        self.campusSSIDs = campusSSIDs
        self.mode = mode
        self.srunBaseURL = srunBaseURL
        self.eportalLoginURL = eportalLoginURL
        self.xxteaVariant = xxteaVariant
    }
}

public enum AuthFailureKind: String, Sendable {
    case notCampus
    case badCredentials
    case network
    case portalRejected
    case invalidResponse
    case missingConfig
    case disabled
}

public struct AuthResult: Sendable, Equatable {
    public var success: Bool
    public var kind: AuthFailureKind?
    public var message: String

    public init(success: Bool, kind: AuthFailureKind? = nil, message: String) {
        self.success = success
        self.kind = kind
        self.message = message
    }

    public static func ok(_ message: String) -> AuthResult {
        AuthResult(success: true, kind: nil, message: message)
    }

    public static func failure(_ kind: AuthFailureKind, _ message: String) -> AuthResult {
        AuthResult(success: false, kind: kind, message: message)
    }
}

public protocol CampusAuthenticating: Sendable {
    func login(_ request: AuthRequest) async -> AuthResult
}
