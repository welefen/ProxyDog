import AppKit
import SwiftUI

struct ProxyDogApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .environmentObject(state.settings)
                .environmentObject(state.store)
                .preferredColorScheme(state.settings.appearance.colorScheme)
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
        .defaultSize(width: AppDefaults.defaultWindowWidth, height: AppDefaults.defaultWindowHeight)
        .windowToolbarStyle(.unified)
        .commands { appCommands }

        Settings {
            SettingsView()
                .environmentObject(state)
                .environmentObject(state.settings)
                .preferredColorScheme(state.settings.appearance.colorScheme)
                .frame(width: 560)
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
