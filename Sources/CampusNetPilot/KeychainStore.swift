import Foundation
import Security

// MARK: - Keychain
//
// 校园密码与（可选的）宿舍 Wi-Fi 密码都保存在本应用自己的 Keychain 项里，
// 配置文件（JSON）中不出现任何口令。ad-hoc 签名重新打包后，系统可能重新询问
// Keychain 访问权限 —— 详见 README「签名与权限持久化」一节。

enum KeychainError: LocalizedError {
    case unexpectedStatus(OSStatus)
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
            return "钥匙串操作失败（\(status)）：\(message)"
        case .encodingFailed:
            return "无法把口令转换为 UTF-8 数据"
        }
    }
}

enum KeychainAccounts {
    static let campusPassword = "campus.password"
    static func wifiPassword(_ ssid: String) -> String { "wifi.password.\(ssid)" }
}

final class KeychainStore: @unchecked Sendable {
    static let defaultService = "com.example.CampusNetPilot"

    private let service: String
    private let lock = NSLock()

    init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    func string(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    func hasValue(for account: String) -> Bool { string(for: account) != nil }

    func set(_ value: String, for account: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.encodingFailed }
        lock.lock()
        defer { lock.unlock() }

        let query = baseQuery(account: account)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError.unexpectedStatus(updateStatus) }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
    }

    func remove(account: String) {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }
}

/// 只读凭据提供者，交给平台无关的状态机使用。
final class KeychainCredentialProvider: CredentialProviding, @unchecked Sendable {
    private let store: KeychainStore

    init(store: KeychainStore) {
        self.store = store
    }

    func campusPassword() -> String? { store.string(for: KeychainAccounts.campusPassword) }

    func wifiPassword(forSSID ssid: String) -> String? { store.string(for: KeychainAccounts.wifiPassword(ssid)) }
}
