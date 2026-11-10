import AppKit
import SwiftUI

/// Card content of the Breakpoints section in Settings: hint, rule list with a small
/// internal scroll cap, empty state and the "Add breakpoint" action. The editor sheet is
/// owned by this view, mirroring the rewrite-rules section.
struct BreakpointsSectionView: View {
    @ObservedObject var store: BreakpointRuleStore
    @State private var editingRule: BreakpointRule?

    private let maxListHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Matching exchanges pause and open an editor so you can tweak the body before resuming or dropping. Only applies while the proxy is running.")
                .font(DS.Typography.ui(11))
                .foregroundStyle(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Space.x4)
                .padding(.vertical, DS.Space.x3)

            BreakpointHairline()

            if store.rules.isEmpty {
                emptyState
            } else {
                rulesList
            }

            BreakpointHairline()
            addButton
        }
        .sheet(item: $editingRule) { rule in
            BreakpointRuleEditorView(
                rule: rule,
                isNew: !store.rules.contains(where: { $0.id == rule.id }),
                store: store
            )
        }
    }

    // MARK: - List

    private var rulesList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(store.rules) { rule in
                    ruleRow(rule)
                    if rule.id != store.rules.last?.id {
                        BreakpointHairline()
                    }
                }
            }
        }
        .frame(height: min(CGFloat(store.rules.count) * 52, maxListHeight))
        .scrollIndicators(store.rules.count > 3 ? .visible : .hidden)
    }

    private func ruleRow(_ rule: BreakpointRule) -> some View {
        HStack(alignment: .center, spacing: DS.Space.x2) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { store.setEnabled($0, id: rule.id) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(DSColor.accent)
            .accessibilityLabel("Enabled")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.x2) {
                    Text(rule.displayName)
                        .font(DS.Typography.ui(12))
                        .foregroundStyle(DSColor.textPrimary)
                        .lineLimit(1)
                    if rule.breakOnRequest {
                        phaseBadge(.request)
                    }
                    if rule.breakOnResponse {
                        phaseBadge(.response)
                    }
                }
                Text(rule.summary)
                    .font(DS.Typography.mono(10.5))
                    .foregroundStyle(DSColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: DS.Space.x2)

            BreakpointIconButton(systemName: "pencil", help: "Edit breakpoint") {
                editingRule = rule
            }
            BreakpointIconButton(systemName: "trash", help: "Delete breakpoint") {
                store.remove(id: rule.id)
            }
        }
        .padding(.horizontal, DS.Space.x4)
        .padding(.vertical, 9)
    }

    private func phaseBadge(_ phase: BreakpointPhase) -> some View {
        Text(phase.label)
            .font(DS.Typography.ui(10, .medium))
            .foregroundStyle(DSColor.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule(style: .continuous)
                    .fill(DSColor.sunken)
            )
    }

    // MARK: - Empty state and add action

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("No breakpoints yet")
                .font(DS.Typography.ui(12))
                .foregroundStyle(DSColor.textPrimary)
            Text("Add a breakpoint to pause matching requests or responses.")
                .font(DS.Typography.ui(11))
                .foregroundStyle(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.x4)
        .padding(.vertical, DS.Space.x3)
    }

    private var addButton: some View {
        Button {
            editingRule = BreakpointRule()
        } label: {
            Label("Add breakpoint", systemImage: "plus")
                .font(DS.Typography.ui(12, .medium))
                .foregroundStyle(DSColor.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.x4)
                .padding(.vertical, DS.Space.x3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Breakpoint editor

/// Sheet editor for a single breakpoint rule. Validation is inline: the URL pattern is
/// required and at least one phase has to be selected.
struct BreakpointRuleEditorView: View {
    let isNew: Bool
    @ObservedObject var store: BreakpointRuleStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: BreakpointRule
    @State private var errorText: String?

    init(rule: BreakpointRule, isNew: Bool, store: BreakpointRuleStore) {
        self.isNew = isNew
        self._store = ObservedObject(wrappedValue: store)
        self._draft = State(initialValue: rule)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(editorTitle)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DSColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.x5)
                .padding(.top, DS.Space.x5)
                .padding(.bottom, DS.Space.x2)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.x4) {
                    matchCard
                    phasesCard
                    if let errorText {
                        Text(verbatim: errorText)
                            .font(DS.Typography.ui(11))
                            .foregroundStyle(DSColor.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, DS.Space.x1)
                    }
                }
                .padding(.horizontal, DS.Space.x5)
                .padding(.vertical, DS.Space.x3)
            }
            .scrollIndicators(.hidden)

            footer
        }
        .frame(width: 560, height: 560)
        .background(DSColor.chrome)
    }

    private var editorTitle: LocalizedStringKey {
        isNew ? "New breakpoint" : "Edit breakpoint"
    }

    // MARK: - Cards

    private var matchCard: some View {
        BreakpointEditorCard {
            BreakpointEditorRow(label: "Enabled") {
                Toggle("", isOn: $draft.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(DSColor.accent)
                    .accessibilityLabel("Enabled")
            }
            BreakpointHairline()
            BreakpointEditorRow(label: "Name") {
                BreakpointTextField(text: $draft.name)
                    .frame(width: 300)
            }
            BreakpointHairline()
            BreakpointEditorRow(label: "Method", hint: "Empty matches any method.") {
                BreakpointTextField(text: methodBinding, mono: true)
                    .frame(width: 90)
            }
            BreakpointHairline()
            BreakpointEditorRow(label: "URL pattern", hint: "Matched against the full URL; regular expression or plain text.") {
                BreakpointTextField(text: $draft.urlPattern, mono: true)
                    .frame(width: 300)
            }
        }
    }

    private var phasesCard: some View {
        BreakpointEditorCard {
            BreakpointEditorRow(label: "Pause on request") {
                Toggle("", isOn: $draft.breakOnRequest)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(DSColor.accent)
                    .accessibilityLabel("Pause on request")
            }
            BreakpointHairline()
            BreakpointEditorRow(label: "Pause on response") {
                Toggle("", isOn: $draft.breakOnResponse)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(DSColor.accent)
                    .accessibilityLabel("Pause on response")
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            BreakpointHairline(fullWidth: true)
            HStack(spacing: DS.Space.x3) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(DS.Typography.ui(12))
                .foregroundStyle(DSColor.textSecondary)
                .keyboardShortcut(.cancelAction)

                Spacer(minLength: 0)

                Button(action: save) {
                    Text("Save")
                        .font(DS.Typography.ui(12, .medium))
                        .foregroundStyle(.white)
                        .frame(minWidth: 56)
                        .padding(.horizontal, DS.Space.x4)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                                .fill(DSColor.accent)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, DS.Space.x5)
            .padding(.vertical, DS.Space.x4)
        }
    }

    // MARK: - Bindings

    private var methodBinding: Binding<String> {
        Binding(
            get: { draft.method ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.method = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    // MARK: - Save

    private func save() {
        var rule = draft
        rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = (rule.method ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        rule.method = method.isEmpty ? nil : method.uppercased()
        rule.urlPattern = rule.urlPattern.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rule.urlPattern.isEmpty else {
            errorText = String(localized: "Enter a URL pattern.")
            return
        }
        guard rule.breakOnRequest || rule.breakOnResponse else {
            errorText = String(localized: "Select at least one phase.")
            return
        }

        errorText = nil
        if isNew {
            store.add(rule)
        } else {
            store.update(rule)
        }
        dismiss()
    }
}

// MARK: - Small building blocks

private struct BreakpointEditorCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .fill(DSColor.raised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .strokeBorder(DSColor.border, lineWidth: 1)
        )
    }
}

private struct BreakpointEditorRow<Control: View>: View {
    let label: LocalizedStringKey
    let hint: LocalizedStringKey?
    @ViewBuilder let control: () -> Control

    init(
        label: LocalizedStringKey,
        hint: LocalizedStringKey? = nil,
        @ViewBuilder control: @escaping () -> Control
    ) {
        self.label = label
        self.hint = hint
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: DS.Space.x4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(DS.Typography.ui(12))
                    .foregroundStyle(DSColor.textPrimary)
                if let hint {
                    Text(hint)
                        .font(DS.Typography.ui(10.5))
                        .foregroundStyle(DSColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.x2)
            control()
        }
        .padding(.horizontal, DS.Space.x4)
        .padding(.vertical, DS.Space.x3)
    }
}

private struct BreakpointTextField: View {
    @Binding var text: String
    var mono: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(mono ? DS.Typography.mono(12) : DS.Typography.ui(12))
            .foregroundStyle(DSColor.textPrimary)
            .focused($focused)
            .padding(.horizontal, DS.Space.x2)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(DSColor.raised)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .strokeBorder(focused ? DSColor.accent : DSColor.border, lineWidth: focused ? 1.5 : 1)
                    )
            )
    }
}

private struct BreakpointHairline: View {
    var fullWidth: Bool = false

    var body: some View {
        Rectangle()
            .fill(DSColor.border)
            .frame(height: 1)
            .padding(.leading, fullWidth ? 0 : DS.Space.x4)
    }
}

private struct BreakpointIconButton: View {
    let systemName: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(DSColor.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
