import AppKit
import SwiftUI

/// Card content of the Rewrite section in Settings: a short hint, the rule list with an
/// internal scroll cap, an empty state and the "Add rule" action. The rule editor is
/// presented from here so the section owns its own sheet.
struct RewriteRulesSectionView: View {
    @ObservedObject var store: RewriteRuleStore
    @State private var editingRule: RewriteRule?

    private let maxListHeight: CGFloat = 240

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Static rules that rewrite requests and responses as they pass through the proxy, without writing code.")
                .font(DS.Typography.ui(11))
                .foregroundStyle(DSColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Space.x4)
                .padding(.vertical, DS.Space.x3)

            RewriteHairline()

            if store.rules.isEmpty {
                emptyState
            } else {
                rulesList
            }

            RewriteHairline()
            addButton
        }
        .sheet(item: $editingRule) { rule in
            RewriteRuleEditorView(
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
                        RewriteHairline()
                    }
                }
            }
        }
        .frame(height: min(CGFloat(store.rules.count) * 52, maxListHeight))
        .scrollIndicators(store.rules.count > 4 ? .visible : .hidden)
    }

    private func ruleRow(_ rule: RewriteRule) -> some View {
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
                    actionBadge(rule.action)
                }
                Text(rule.summary)
                    .font(DS.Typography.mono(10.5))
                    .foregroundStyle(DSColor.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: DS.Space.x2)

            RewriteIconButton(systemName: "pencil", help: "Edit rule") {
                editingRule = rule
            }
            RewriteIconButton(systemName: "trash", help: "Delete rule") {
                store.remove(id: rule.id)
            }
        }
        .padding(.horizontal, DS.Space.x4)
        .padding(.vertical, 9)
    }

    private func actionBadge(_ action: RewriteAction) -> some View {
        Text(action.label)
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
            Text("No rules yet")
                .font(DS.Typography.ui(12))
                .foregroundStyle(DSColor.textPrimary)
            Text("Add a rule to redirect requests or patch request and response bodies.")
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
            editingRule = RewriteRule()
        } label: {
            Label("Add rule", systemImage: "plus")
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

// MARK: - Rule editor

/// Sheet editor for a single rewrite rule. Validation is inline and quiet: the first
/// problem is shown as red helper text above the action buttons.
struct RewriteRuleEditorView: View {
    let isNew: Bool
    @ObservedObject var store: RewriteRuleStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: RewriteRule
    @State private var statusText: String
    @State private var errorText: String?

    init(rule: RewriteRule, isNew: Bool, store: RewriteRuleStore) {
        self.isNew = isNew
        self._store = ObservedObject(wrappedValue: store)
        self._draft = State(initialValue: rule)
        self._statusText = State(initialValue: String(rule.responseStatus))
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
                    actionCard
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
        .frame(width: 560, height: 620)
        .background(DSColor.chrome)
    }

    private var editorTitle: LocalizedStringKey {
        isNew ? "New rule" : "Edit rule"
    }

    // MARK: - Cards

    private var matchCard: some View {
        RewriteEditorCard {
            RewriteEditorRow(label: "Enabled") {
                Toggle("", isOn: $draft.isEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(DSColor.accent)
                    .accessibilityLabel("Enabled")
            }
            RewriteHairline()
            RewriteEditorRow(label: "Name") {
                RewriteTextField(text: $draft.name, mono: false)
                    .frame(width: 300)
            }
            RewriteHairline()
            RewriteEditorRow(label: "Method", hint: "Empty matches any method.") {
                RewriteTextField(text: methodBinding, mono: true, alignment: .leading)
                    .frame(width: 90)
            }
            RewriteHairline()
            RewriteEditorRow(label: "URL pattern", hint: "Matched against the full URL; regular expression or plain text.") {
                RewriteTextField(text: $draft.urlPattern, mono: true)
                    .frame(width: 300)
            }
        }
    }

    private var actionCard: some View {
        RewriteEditorCard {
            RewriteEditorRow(label: "Action") {
                Picker("", selection: $draft.action) {
                    ForEach(RewriteAction.allCases) { action in
                        Text(action.label).tag(action)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 190)
                .accessibilityLabel("Action")
            }

            switch draft.action {
            case .redirect:
                RewriteHairline()
                RewriteEditorRow(label: "Redirect URL", hint: "Absolute URL to send the request to.") {
                    RewriteTextField(text: $draft.redirectURL, mono: true)
                        .frame(width: 300)
                }
            case .replaceRequest, .replaceResponse:
                RewriteHairline()
                RewriteBodyRow(label: "Replacement body", text: $draft.replacementBody)
                if draft.action == .replaceResponse {
                    RewriteHairline()
                    RewriteEditorRow(label: "Status code") {
                        RewriteTextField(text: $statusText, mono: true, alignment: .trailing)
                            .frame(width: 70)
                            .onChange(of: statusText) { _, newValue in
                                let filtered = String(newValue.filter(\.isNumber).prefix(3))
                                if filtered != newValue { statusText = filtered }
                            }
                    }
                    RewriteHairline()
                    RewriteEditorRow(label: "Content type") {
                        RewriteTextField(text: $draft.responseContentType, mono: true)
                            .frame(width: 210)
                    }
                }
            case .modifyRequest, .modifyResponse:
                RewriteHairline()
                RewriteEditorRow(label: "Find", hint: "Regular expression; plain text is replaced literally.") {
                    RewriteTextField(text: $draft.findText, mono: true)
                        .frame(width: 260)
                }
                RewriteHairline()
                RewriteEditorRow(label: "Replace") {
                    RewriteTextField(text: $draft.replaceText, mono: true)
                        .frame(width: 260)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            RewriteHairline(fullWidth: true)
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

    /// `nil` means "any method", which the text field shows as an empty string.
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
        rule.redirectURL = rule.redirectURL.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.findText = rule.findText.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.responseContentType = rule.responseContentType.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !rule.urlPattern.isEmpty else {
            errorText = String(localized: "Enter a URL pattern.")
            return
        }

        switch rule.action {
        case .redirect:
            guard !rule.redirectURL.isEmpty else {
                errorText = String(localized: "Enter a redirect URL.")
                return
            }
        case .replaceRequest, .replaceResponse:
            guard !rule.replacementBody.isEmpty else {
                errorText = String(localized: "Enter a replacement body.")
                return
            }
            if rule.action == .replaceResponse {
                guard let status = Int(statusText.trimmingCharacters(in: .whitespaces)),
                      (100...599).contains(status) else {
                    errorText = String(localized: "Enter a valid status code.")
                    return
                }
                rule.responseStatus = status
                if rule.responseContentType.isEmpty {
                    rule.responseContentType = "application/json"
                }
            }
        case .modifyRequest, .modifyResponse:
            guard !rule.findText.isEmpty else {
                errorText = String(localized: "Enter the text to find.")
                return
            }
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

private struct RewriteEditorCard<Content: View>: View {
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

private struct RewriteEditorRow<Control: View>: View {
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

private struct RewriteBodyRow: View {
    let label: LocalizedStringKey
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            Text(label)
                .font(DS.Typography.ui(12))
                .foregroundStyle(DSColor.textPrimary)
            TextEditor(text: $text)
                .font(DS.Typography.mono(11))
                .foregroundStyle(DSColor.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(height: 88)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .fill(DSColor.sunken)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                                .strokeBorder(focused ? DSColor.accent : DSColor.border, lineWidth: 1)
                        )
                )
        }
        .padding(.horizontal, DS.Space.x4)
        .padding(.vertical, DS.Space.x3)
    }
}

private struct RewriteTextField: View {
    @Binding var text: String
    var mono: Bool = false
    var alignment: TextAlignment = .leading
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.plain)
            .font(mono ? DS.Typography.mono(12) : DS.Typography.ui(12))
            .foregroundStyle(DSColor.textPrimary)
            .multilineTextAlignment(alignment)
            .focused($focused)
            .padding(.horizontal, DS.Space.x2)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(DSColor.sunken)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .strokeBorder(focused ? DSColor.accent : DSColor.border, lineWidth: 1)
                    )
            )
    }
}

private struct RewriteHairline: View {
    var fullWidth: Bool = false

    var body: some View {
        Rectangle()
            .fill(DSColor.border)
            .frame(height: 1)
            .padding(.leading, fullWidth ? 0 : DS.Space.x4)
    }
}

private struct RewriteIconButton: View {
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
