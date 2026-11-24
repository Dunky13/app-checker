import KanarieCore
import Sparkle
import SwiftUI
import UserNotifications

extension Notification.Name {
    static let openMainWindow = Notification.Name("openMainWindow")
}

@main
enum Main {
    /// `Kanarie --list` prints one tab-separated line per item (status, id, version, explanation) and exits.
    static func main() {
        guard CommandLine.arguments.contains("--list") else { return KanarieApp.main() }
        let (snapshot, rules, saved) = (AppModel.scan(shell: nil), AppModel.loadFindings().rules, AppModel.loadSaved())
        Probe.blockedFiles = Set(saved.blocked ?? [])
        let probe = Probe.live(env: snapshot.shell.env)
        for item in snapshot.items {
            let verdict = Verdict(item: item, rules: rules, aiRules: saved.aiRules, sdks: saved.sdks[AppModel.sdkKey(item)] ?? [], probe: probe)
            print([verdict.status.rawValue, item.id, item.version, verdict.state].joined(separator: "\t"))
        }
    }
}

struct KanarieApp: App {
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

        Window("Kanarie", id: "main") {
            MainView(model: model)
                // With the list open the app is an ordinary one, in the app switcher and the Dock. Closed, it is menu bar only again.
                .onAppear { NSApp.setActivationPolicy(.regular) }
                .onDisappear { NSApp.setActivationPolicy(.accessory) }
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
        Image(systemName: attention > 0 ? "bird.fill" : "bird")
            .accessibilityLabel(attention > 0 ? "Kanarie: \(attention) items may send telemetry" : "Kanarie")
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
        notify("Kanarie \(update.displayVersionString) is available", "Open the menu bar icon to install the update.")
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        updateAvailable = false
    }

    func standardUserDriverWillFinishUpdateSession() {
        updateAvailable = false
    }
}
