import AppKit
import SwiftUI

/// Root of the main window: sidebar, traffic list, detail inspector and the quiet
/// status strip along the bottom.
struct ContentView: View {
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
        .sheet(item: Binding(
            get: { state.pendingBreakpoints.first },
            set: { _ in }
        )) { payload in
            BreakpointEditorView(payload: payload)
                .environmentObject(state)
                .id(payload.id)
        }
        .onAppear {
            SampleTraffic.bootstrapIfRequested(state: state)
            SampleTraffic.injectSampleBreakpointIfRequested(state: state)
            SampleTraffic.runDevProbesIfNeeded()
        }
    }
}
