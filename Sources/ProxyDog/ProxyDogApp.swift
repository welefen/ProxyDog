import AppKit
import SwiftUI

struct ProxyDogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup {
            AppRootView(state: state, settings: state.settings)
        }
        .defaultSize(width: AppDefaults.defaultWindowWidth, height: AppDefaults.defaultWindowHeight)
        .windowToolbarStyle(.unified)
        .commands { appCommands }

        Settings {
            SettingsRootView(state: state, settings: state.settings)
        }
    }

    @CommandsBuilder
    private var appCommands: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Proxy") {
            Button(state.isProxyRunning ? "Stop Proxy" : "Start Proxy") {
                state.toggleProxy()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Button(state.store.isPaused ? "Resume Capturing" : "Pause Capturing") {
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
        }
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
    }
}

struct SettingsRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsView()
            .environmentObject(state)
            .environmentObject(settings)
            .preferredColorScheme(settings.appearance.colorScheme)
            .frame(width: 560)
    }
}
