import SwiftUI
import AppKit
import CampusNetCore

@main
@MainActor
struct CampusNetPilotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            Image(systemName: model.menuBarSymbol)
                .accessibilityLabel(Text(model.status.phase.displayName))
        }
        .menuBarExtraStyle(.window)

        Window("校园网助手设置", id: "settings") {
            SettingsView(model: model)
        }
        .defaultSize(width: 580, height: 600)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏应用：不显示 Dock 图标（Info.plist 里也设置了 LSUIElement）。
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
