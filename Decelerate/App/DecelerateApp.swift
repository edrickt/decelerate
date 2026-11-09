import AppKit
import ServiceManagement
import SwiftUI

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

/// Brings the app's Settings window to the front.
///
/// Decelerate is an `LSUIElement` menu bar app: clicking its menu bar panel does
/// not activate the process, so SwiftUI's `openSettings` action can create the
/// Settings window *behind* the frontmost app. Activating the app and ordering
/// the window front fixes that. The window may be created a moment after the
/// action runs, so the activation is retried briefly.
@MainActor
enum SettingsPresenter {
    /// Opens the Settings scene and guarantees the app/window come to the front.
    /// The panel button is a user event, so the activation request is honoured.
    static func present(_ open: () -> Void) {
        activateNow()
        open()
        activate()
    }

    static func activate() {
        activateNow()
        for delay in [0.05, 0.2, 0.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                activateNow()
            }
        }
    }

    private static func activateNow() {
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        NSApp.activate(ignoringOtherApps: true)
        // The menu bar panel itself is a non-main window (canBecomeMain == false),
        // so this only raises the Settings window.
        for window in NSApp.windows where window.isVisible && window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
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
        if arguments.contains("--activate-test") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                SettingsPresenter.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    DebugLog.write("activate-test: active=\(NSApp.isActive) policy=\(NSApp.activationPolicy().rawValue) key=\(NSApp.keyWindow?.title ?? "nil")")
                }
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
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            _ = NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        SettingsPresenter.activate()
    }
}
