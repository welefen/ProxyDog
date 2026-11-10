import AppKit
import SwiftUI

// MARK: - Traffic list pane

/// Center column: capture toolbar, aligned column rhythm, custom rows and the
/// keyboard affordances (Cmd+F, arrows, Delete).
struct TrafficListView: View {
    @EnvironmentObject private var state: AppState

    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool
    @State private var searchShortcutMonitor: Any?

    private var requests: [CapturedRequest] { state.filteredRequests }

    private var isCapturing: Bool { state.isProxyRunning && !state.store.isPaused }

    private var captureDotColor: Color {
        if state.store.isPaused && state.isProxyRunning { return DSColor.amber }
        return DSColor.green
    }

    var body: some View {
        VStack(spacing: 0) {
            if state.allRequests.isEmpty {
                TrafficEmptyStateView()
            } else {
                typeFilterBar
                PDHairline()
                if requests.isEmpty {
                    TrafficNoMatchesView(reason: emptyReason)
                } else {
                    columnHeader
                    list
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSColor.base)
        .toolbar { toolbarContent }
        .onAppear {
            installSearchShortcut()
            listFocused = true
        }
        .onDisappear { removeSearchShortcut() }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: DS.Space.x2) {
                PDLiveDot(
                    active: isCapturing,
                    color: captureDotColor,
                    idleColor: state.store.isPaused && state.isProxyRunning ? DSColor.amber : DSColor.textMuted
                )
                PDSearchField(
                    text: $state.searchText,
                    isFocused: $searchFocused,
                    placeholder: String(localized: "Search requests"),
                    width: 220
                )
            }
            .padding(.trailing, DS.Space.x2)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            PDIconButton(
                symbol: state.store.isPaused ? "play.fill" : "pause.fill",
                help: state.store.isPaused
                    ? String(localized: "Resume capturing")
                    : String(localized: "Pause capturing"),
                role: state.store.isPaused ? .warning : .normal
            ) {
                state.togglePause()
            }

            PDIconButton(symbol: "trash", help: String(localized: "Clear traffic")) {
                state.clearRequests()
            }

            PDIconButton(symbol: "square.and.arrow.up", help: String(localized: "Export HAR")) {
                state.presentHARExportPanel()
            }

            Rectangle()
                .fill(DSColor.border)
                .frame(width: 1, height: 14)
                .padding(.horizontal, DS.Space.x1)

            PDIconButton(
                symbol: state.isProxyRunning ? "power.circle.fill" : "power",
                help: state.isProxyRunning
                    ? String(localized: "Stop proxy")
                    : String(localized: "Start proxy"),
                role: state.isProxyRunning ? .accent : .normal
            ) {
                state.toggleProxy()
            }
        }
    }

    // MARK: Type filter

    /// Chrome-style request type chips, horizontally scrollable so the bar works
    /// even at the minimum column width.
    private var typeFilterBar: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.x2 - 2) {
                    ForEach(RequestCategory.allCases) { category in
                        TypeFilterChip(
                            category: category,
                            isSelected: state.typeFilter == category
                        ) {
                            state.typeFilter = category
                            listFocused = true
                        }
                        .id(category.id)
                    }
                }
                .padding(.horizontal, DS.Space.x3)
                .frame(height: 32)
            }
            .frame(height: 32)
            .background(DSColor.base)
            .onAppear { scrollToSelectedTypeFilter(proxy) }
            .onChange(of: state.typeFilter) { _, _ in
                scrollToSelectedTypeFilter(proxy)
            }
        }
    }

    private func scrollToSelectedTypeFilter(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo(state.typeFilter.id, anchor: .center)
        }
    }

    /// Tells the empty state whether search or the type filter emptied the list.
    private var emptyReason: TrafficNoMatchesView.Reason {
        let hasQuery = !state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasQuery { return .search }
        return state.typeFilter.isFiltering ? .typeFilter : .search
    }

    // MARK: Column header

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: DS.Metric.iconColumnWidth + DS.Metric.methodColumnWidth)
            Text("Request")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Status")
                .frame(width: DS.Metric.statusColumnWidth, alignment: .trailing)
            Text("Size")
                .frame(width: DS.Metric.sizeColumnWidth, alignment: .trailing)
            Text("Time")
                .frame(width: DS.Metric.durationColumnWidth, alignment: .trailing)
            Color.clear
                .frame(width: DS.Metric.pinColumnWidth)
        }
        .font(DS.Typography.mono(10, .medium))
        .foregroundStyle(DSColor.textMuted)
        .padding(.horizontal, DS.Space.x3)
        .frame(height: DS.Metric.rowHeight)
        .background(DSColor.base)
        .overlay(alignment: .bottom) { PDHairline() }
    }

    // MARK: Rows

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(requests) { request in
                        TrafficRowView(
                            request: request,
                            isSelected: request.id == state.selectionID
                        ) {
                            select(request.id)
                        }
                        .contextMenu {
                            Button(request.isPinned ? String(localized: "Unpin") : String(localized: "Pin")) {
                                state.togglePin(request.id)
                            }
                            Button("Copy URL") {
                                PDPasteboard.copy(request.urlString)
                            }
                            Button("Copy as cURL") {
                                state.copyCurl(for: request)
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                delete(request.id)
                            }
                        }
                    }
                }
                .padding(.bottom, DS.Space.x4)
            }
            .onChange(of: state.selectionID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: nil)
            }
        }
        .focusable()
        .focused($listFocused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) {
            moveSelection(-1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(1)
            return .handled
        }
        .onKeyPress(.delete) {
            deleteSelection()
            return .handled
        }
        .onKeyPress(.deleteForward) {
            deleteSelection()
            return .handled
        }
        .onTapGesture { listFocused = true }
    }

    // MARK: Actions

    private func select(_ id: CapturedRequest.ID) {
        state.selectionID = id
        listFocused = true
    }

    private func moveSelection(_ delta: Int) {
        let items = requests
        guard !items.isEmpty else { return }
        if let index = items.firstIndex(where: { $0.id == state.selectionID }) {
            let next = min(max(index + delta, 0), items.count - 1)
            state.selectionID = items[next].id
        } else {
            state.selectionID = delta > 0 ? items[0].id : items[items.count - 1].id
        }
    }

    private func deleteSelection() {
        guard let id = state.selectionID else { return }
        delete(id)
    }

    private func delete(_ id: CapturedRequest.ID) {
        let items = requests
        let index = items.firstIndex { $0.id == id }
        if let index, state.selectionID == id {
            if index + 1 < items.count {
                state.selectionID = items[index + 1].id
            } else if index > 0 {
                state.selectionID = items[index - 1].id
            }
        }
        state.removeRequest(id)
    }

    // MARK: Cmd+F

    private func installSearchShortcut() {
        guard searchShortcutMonitor == nil else { return }
        searchShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard modifiers == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "f",
                  NSApp.keyWindow?.attachedSheet == nil
            else { return event }
            DispatchQueue.main.async {
                searchFocused = true
            }
            return nil
        }
    }

    private func removeSearchShortcut() {
        if let monitor = searchShortcutMonitor {
            NSEvent.removeMonitor(monitor)
            searchShortcutMonitor = nil
        }
    }
}

// MARK: - Traffic row

private struct TrafficRowView: View {
    let request: CapturedRequest
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovering = false

    private var background: Color {
        if isSelected { return DSColor.selection }
        return isHovering ? DSColor.hover : .clear
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 0) {
                Image(systemName: request.contentKind.symbolName)
                    // Keep SF Symbol letterform variants in the Latin form (Aa, not 格式/甲乙丙).
                    .environment(\.locale, Locale(identifier: "en_US"))
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(isSelected ? DSColor.textSecondary : DSColor.textMuted)
                    .frame(width: DS.Metric.iconColumnWidth, alignment: .leading)

                MethodBadge(method: request.method)
                    .frame(width: DS.Metric.methodColumnWidth, alignment: .leading)

                urlLine
                    .padding(.trailing, DS.Space.x3)

                Text(PDStatus.compactLabel(for: request))
                    .font(DS.Typography.mono(11, .semibold))
                    .foregroundStyle(PDStatus.color(for: request))
                    .monospacedDigit()
                    .frame(width: DS.Metric.statusColumnWidth, alignment: .trailing)

                Text(PDFormat.bytes(request.responseBytes))
                    .font(DS.Typography.mono(11))
                    .foregroundStyle(DSColor.textMuted)
                    .monospacedDigit()
                    .frame(width: DS.Metric.sizeColumnWidth, alignment: .trailing)

                Text(PDFormat.duration(request.duration))
                    .font(DS.Typography.mono(11))
                    .foregroundStyle(DSColor.textMuted)
                    .monospacedDigit()
                    .frame(width: DS.Metric.durationColumnWidth, alignment: .trailing)

                pinIndicator
                    .frame(width: DS.Metric.pinColumnWidth, alignment: .trailing)
            }
            .padding(.horizontal, DS.Space.x3)
            .frame(height: DS.Metric.rowHeight)
            .background(background)
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(DSColor.accent)
                        .frame(width: 2, height: 16)
                        .padding(.leading, 2)
                }
            }
            .overlay(alignment: .bottom) { PDHairline() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(request.urlString)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var urlLine: some View {
        // A single concatenated Text keeps host and path on one baseline and lets
        // the line truncate in the middle: the host stays readable, the path tail
        // stays recognizable.
        (
            Text(request.hostLabel)
                .font(DS.Typography.ui(12))
                .foregroundColor(isSelected ? DSColor.textPrimary : DSColor.textSecondary)
            + Text(request.displayPath)
                .font(DS.Typography.mono(11.5))
                .foregroundColor(DSColor.textPrimary)
        )
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var pinIndicator: some View {
        if request.isPinned {
            Image(systemName: "pin.fill")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(DSColor.textMuted)
        }
    }

    private var accessibilityLabel: String {
        var parts = [request.method, request.urlString, PDStatus.fullLabel(for: request)]
        if let duration = request.duration {
            parts.append(PDFormat.duration(duration))
        }
        if request.isPinned {
            parts.append(String(localized: "Pinned"))
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Type filter chip

private struct TypeFilterChip: View {
    let category: RequestCategory
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(category.label)
                .font(DS.Typography.ui(12, isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? DSColor.textPrimary : DSColor.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: isSelected ? 1 : DS.Metric.separator)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(category.label)
        .accessibilityLabel(category.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var background: Color {
        if isSelected { return DSColor.accent.opacity(0.11) }
        return isHovering ? DSColor.hover : DSColor.sunken
    }

    private var borderColor: Color {
        isSelected ? DSColor.accent.opacity(0.85) : DSColor.border
    }
}
