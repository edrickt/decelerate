import AppKit
import ServiceManagement
import SwiftUI

enum DebugLog {
    static func write(_ message: String) {
        guard ProcessInfo.processInfo.environment["DECELERATE_DEBUG"] == "1" else { return }
        FileHandle.standardError.write(Data("[Decelerate] \(message)\n".utf8))
    }
}

@main
struct DecelerateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(state)
        } label: {
            Image(systemName: state.menuBarSymbol)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var previewWindows: [NSWindow] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.start()
        handleDebugArguments()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.write("applicationWillTerminate")
        AppState.shared.prepareForTermination()
        DebugLog.write("applicationWillTerminate done")
    }

    // MARK: - Development previews
    //
    // Launching the app with one of these flags opens the UI in a plain window,
    // which makes it possible to iterate on the interface (and screenshot it)
    // without clicking through the menu bar item.
    //
    //   Decelerate.app/Contents/MacOS/Decelerate --preview-panel
    //   Decelerate.app/Contents/MacOS/Decelerate --preview-settings
    //   Decelerate.app/Contents/MacOS/Decelerate --show-settings

    private func handleDebugArguments() {
        let arguments = CommandLine.arguments
        // QA hook: terminate cleanly after N seconds so the restore-on-quit
        // path can be exercised from a script.
        if let index = arguments.firstIndex(of: "--quit-after"), index + 1 < arguments.count,
           let seconds = Double(arguments[index + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                NSApp.terminate(nil)
            }
        }
        if arguments.contains("--test-login-item") {
            testLoginItem()
            return
        }
        let wantsPreview = arguments.contains("--preview-panel") || arguments.contains("--preview-settings")
        let wantsSettings = arguments.contains("--show-settings")
        guard wantsPreview || wantsSettings else { return }

        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            if arguments.contains("--preview-panel") { self?.showPanelPreview() }
            if arguments.contains("--preview-settings") { self?.showSettingsPreview() }
            if wantsSettings { self?.openSettingsWindow() }
        }
    }

    /// QA hook: exercise SMAppService registration and report the result.
    private func testLoginItem() {
        DebugLog.write("loginItem status=\(SMAppService.mainApp.status.rawValue)")
        do {
            try SMAppService.mainApp.register()
            DebugLog.write("loginItem register OK, status=\(SMAppService.mainApp.status.rawValue)")
        } catch {
            DebugLog.write("loginItem register FAILED: \(error.localizedDescription)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            do {
                try SMAppService.mainApp.unregister()
                DebugLog.write("loginItem unregister OK, status=\(SMAppService.mainApp.status.rawValue)")
            } catch {
                DebugLog.write("loginItem unregister FAILED: \(error.localizedDescription)")
            }
        }
    }

    private func showPanelPreview() {
        presentPreview(title: "Decelerate Panel", width: 320, height: 0) {
            MenuBarPanel().environmentObject(AppState.shared)
        }
    }

    private func showSettingsPreview() {
        presentPreview(title: "Decelerate Settings", width: 560, height: 0) {
            SettingsView().environmentObject(AppState.shared)
        }
    }

    private func presentPreview<Content: View>(title: String, width: CGFloat, height: CGFloat,
                                               @ViewBuilder content: () -> Content) {
        let hosting = NSHostingController(rootView: AnyView(content()))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = title
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        if width > 0, height > 0 {
            window.setContentSize(NSSize(width: width, height: height))
        }
        previewWindows.append(window)
    }

    private func openSettingsWindow() {
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }
}
