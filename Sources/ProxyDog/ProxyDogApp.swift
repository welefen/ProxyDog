import AppKit
import SwiftUI

struct ProxyDogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared
    @StateObject private var updater = UpdateManager.shared

    var body: some Scene {
        WindowGroup {
            AppRootView(state: state, settings: state.settings)
        }
        .defaultSize(width: AppDefaults.defaultWindowWidth, height: AppDefaults.defaultWindowHeight)
        .windowToolbarStyle(.unified)
        .commands {
            appCommands
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    NSApp.activate(ignoringOtherApps: true)
                    if updater.canInstall {
                        updater.installDownloadedUpdate()
                        return
                    }
                    if updater.phase.isBusy {
                        Self.presentUpdateAlert(
                            title: String(localized: "Update in progress"),
                            message: String(localized: "ProxyDog is already checking for or downloading an update.")
                        )
                        return
                    }
                    NotificationCenter.default.post(name: .openUpdatesSettings, object: nil)
                    Task {
                        await updater.check(manual: true)
                        switch updater.phase {
                        case .upToDate:
                            Self.presentUpdateAlert(
                                title: String(localized: "You’re up to date"),
                                message: String(format: String(localized: "ProxyDog v%@ is the latest version."), updater.currentVersion)
                            )
                        case .failed(let message):
                            Self.presentUpdateAlert(
                                title: String(localized: "Update check failed"),
                                message: message
                            )
                        default:
                            break
                        }
                    }
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])

                Button("Feedback") {
                    if let url = URL(string: "https://github.com/welefen/ProxyDog/") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }

        Settings {
            SettingsRootView(state: state, settings: state.settings)
        }
    }

    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appInfo) {
            Button("About ProxyDog") {
                AboutWindow.show()
            }
        }
        CommandMenu("Proxy") {
            Button(LocalizedStringKey(state.isProxyRunning ? "Stop Proxy" : "Start Proxy")) {
                state.toggleProxy()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button(LocalizedStringKey(state.store.isPaused ? "Resume Capturing" : "Pause Capturing")) {
                state.togglePause()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button("Set as System Proxy") {
                state.setSystemProxy(enabled: !state.isSystemProxyEnabled)
            }
            .disabled(!state.isProxyRunning)
        }
        CommandGroup(after: .saveItem) {
            Button("Clear Traffic") {
                state.clearRequests()
            }
            .keyboardShortcut("k", modifiers: .command)

            Button("Export HAR…") {
                state.presentHARExportPanel()
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Button("Import HAR…") {
                state.presentHARImportPanel()
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
    }
}

extension ProxyDogApp {
    @MainActor
    static func presentUpdateAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}


/// Root view of the main window. Observing both AppState and AppSettings keeps the
/// appearance switch (Light / Dark / Follow system) live without a relaunch.
struct AppRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings

    var body: some View {
        ContentView()
            .environmentObject(state)
            .environmentObject(settings)
            .environmentObject(state.store)
            .environmentObject(UpdateManager.shared)
            .preferredColorScheme(settings.appearance.colorScheme)
            .frame(
                minWidth: 980,
                idealWidth: AppDefaults.defaultWindowWidth,
                maxWidth: .infinity,
                minHeight: 620,
                idealHeight: AppDefaults.defaultWindowHeight,
                maxHeight: .infinity
            )
            .onAppear { state.bootstrap() }
            .task {
                await UpdateManager.shared.startOnLaunch(
                    isDemo: ProcessInfo.processInfo.arguments.contains("--sample-traffic")
                )
            }
    }
}

struct SettingsRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsView()
            .environmentObject(state)
            .environmentObject(settings)
            .environmentObject(UpdateManager.shared)
            .preferredColorScheme(settings.appearance.colorScheme)
            .frame(width: 760)
    }
}
