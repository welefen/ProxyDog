import AppKit
import SwiftUI

/// Root of the main window: sidebar, traffic list, detail inspector and the quiet
/// status strip along the bottom.
struct ContentView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var state: AppState
    @State private var sidebarWidth: CGFloat = DS.Metric.sidebarIdeal

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(
                        min: DS.Metric.sidebarMin,
                        ideal: DS.Metric.sidebarIdeal,
                        max: DS.Metric.sidebarMax
                    )
            } content: {
                TrafficListView()
                    .navigationSplitViewColumnWidth(
                        min: DS.Metric.listMin,
                        ideal: DS.Metric.listIdeal
                    )
            } detail: {
                RequestDetailView()
                    .navigationSplitViewColumnWidth(
                        min: DS.Metric.detailMin,
                        ideal: DS.Metric.detailIdeal
                    )
            }
            .navigationSplitViewStyle(.balanced)
            .navigationTitle("")
            .toolbarBackground(DSColor.chrome, for: .windowToolbar)

            StatusBarView(leadingInset: sidebarWidth)
        }
        .onPreferenceChange(SidebarWidthPreferenceKey.self) { width in
            if width > 0 {
                sidebarWidth = width
            }
        }
        .background(DSColor.base)
        .sheet(isPresented: $state.isOnboardingPresented) {
            OnboardingView()
                .environmentObject(state)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openUpdatesSettings)) { _ in
            state.requestSettings(destination: .appearance)
            openSettings()
        }
        .sheet(item: $state.rewriteRuleDraft) { rule in
            RewriteRuleEditorView(rule: rule, isNew: true, store: state.rewriteRules)
        }
        .sheet(item: $state.breakpointRuleDraft) { rule in
            BreakpointRuleEditorView(rule: rule, isNew: true, store: state.breakpoints)
        }
        .sheet(item: Binding(
            get: { state.pendingBreakpoints.first },
            set: { _ in }
        )) { payload in
            BreakpointEditorView(payload: payload)
                .environmentObject(state)
                .id(payload.id)
        }
        .onAppear {
            SampleTraffic.seedRulesIfRequested(state: state)
            SampleTraffic.bootstrapIfRequested(state: state)
            SampleTraffic.injectSampleBreakpointIfRequested(state: state)
            SampleTraffic.runDevProbesIfNeeded()
            if let search = DevLaunchOptions.sampleSearch {
                state.searchText = search
            }
            if let path = DevLaunchOptions.sampleHARImport {
                state.importHAR(from: URL(fileURLWithPath: path))
            }
            SampleTraffic.openSettingsIfRequested(state: state, openSettings: openSettings)
            if ProcessInfo.processInfo.arguments.contains("--sample-about") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    AboutWindow.show()
                }
            }
            if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--sample-update-phase"),
               ProcessInfo.processInfo.arguments.indices.contains(index + 1) {
                let raw = ProcessInfo.processInfo.arguments[index + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    switch raw {
                    case "downloading": UpdateManager.shared.qaSetPhase(.downloading("1.1.0"))
                    case "ready": UpdateManager.shared.qaSetPhase(.ready("1.1.0"))
                    case "available": UpdateManager.shared.qaSetPhase(.available("1.1.0"))
                    default: break
                    }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--sample-update-check") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    Task { await UpdateManager.shared.check(manual: true) }
                }
            }
            SampleTraffic.presentSampleRuleDraftIfRequested(state: state)
        }
    }
}
