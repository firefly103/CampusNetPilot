import Foundation
import ServiceManagement

/// 登录后自启动：使用 macOS 13+ 的 SMAppService（需要 .app 位于 /Applications 等稳定位置）。
/// 若当前构建未满足条件（例如在只读卷或临时目录里运行），这里会返回具体错误，
/// 由设置页原样显示，不静默失败。
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var description: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "已启用"
        case .notRegistered: return "未启用"
        case .notFound: return "系统未找到应用（请先放入「应用程序」目录）"
        case .requiresApproval: return "需要在「系统设置 → 登录项」中允许"
        @unknown default: return "未知状态"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        let status = SMAppService.mainApp.status
        if enabled {
            guard status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard status != .notRegistered else { return }
            try SMAppService.mainApp.unregister()
        }
    }
}
