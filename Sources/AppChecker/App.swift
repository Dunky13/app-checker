import AppCheckerCore
import Sparkle
import SwiftUI
import UserNotifications

extension Notification.Name {
    static let openMainWindow = Notification.Name("openMainWindow")
}

@main
enum Main {
    /// `AppChecker --list` prints one tab-separated line per item (status, id, version, explanation) and exits.
    static func main() {
        guard CommandLine.arguments.contains("--list") else { return AppCheckerApp.main() }
        let (snapshot, rules, saved) = (AppModel.scan(shell: nil), AppModel.loadRules(), AppModel.loadSaved())
        Probe.blockedFiles = Set(saved.blocked ?? [])
        let probe = Probe.live(env: snapshot.shell.env)
        for item in snapshot.items {
            let verdict = Verdict(item: item, rules: rules, aiRules: saved.aiRules, sdks: saved.sdks[AppModel.sdkKey(item)] ?? [], probe: probe)
            print([verdict.status.rawValue, item.id, item.version, verdict.state].joined(separator: "\t"))
        }
    }
}

struct AppCheckerApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()
    @State private var updater = Updater()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model, updater: updater)
        } label: {
            MenuBarLabel(attention: model.count(.bad) + model.count(.warn))
        }
        .menuBarExtraStyle(.window)

        Window("App Checker", id: "main") {
            MainView(model: model)
        }
        .defaultSize(width: 980, height: 640)
        // A login item should start silently in the menu bar.
        .defaultLaunchBehavior(.suppressed)
    }
}

/// Lives in the menu bar for the whole session, so it also owns opening the list window on request.
struct MenuBarLabel: View {
    var attention: Int
    @Environment(\.openWindow) private var openWindow
    @AppStorage("didShowWindow") private var didShowWindow = false

    var body: some View {
        Image(systemName: attention > 0 ? "exclamationmark.shield" : "checkmark.shield")
            .accessibilityLabel(attention > 0 ? "App Checker: \(attention) items may send telemetry" : "App Checker")
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in open() }
            .task {
                if !didShowWindow {
                    didShowWindow = true
                    open()
                }
            }
    }

    private func open() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    // Opening the app again from Finder shows the list.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NotificationCenter.default.post(name: .openMainWindow, object: nil)
        return false
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { NotificationCenter.default.post(name: .openMainWindow, object: nil) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}

/// Sparkle wiring. A menu bar app has no Dock icon, so scheduled update alerts are announced with a
/// notification and a button in the menu instead of a window that could open unseen behind other apps.
@MainActor @Observable
final class Updater: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    private(set) var updateAvailable = false
    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }

    // Sparkle shows its window only when the app is in front; otherwise the update is announced below.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        updateAvailable = true
        notify("App Checker \(update.displayVersionString) is available", "Open the menu bar icon to install the update.")
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        updateAvailable = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        updateAvailable = false
    }
}
