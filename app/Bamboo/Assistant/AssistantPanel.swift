import SwiftUI

/// The Claude side panel. BrowserWindowView shows it when `window.isAssistantVisible`.
struct AssistantPanel: View {
    let window: BrowserWindowModel
    private var keyStore: AnthropicKeyStore { .shared }

    var body: some View {
        let conversation = AssistantConversation.conversation(for: window)
        let accent = Theme.palette(window.selectedSpace.tint).accent
        VStack(spacing: 0) {
            AssistantHeader(window: window, conversation: conversation)
            Divider()
            Group {
                if !keyStore.hasKey {
                    MissingKeyView(accent: accent)
                } else if conversation.entries.isEmpty {
                    WelcomeView(window: window, conversation: conversation, accent: accent)
                } else {
                    ConversationView(conversation: conversation, accent: accent)
                }
            }
            .frame(maxHeight: .infinity)
            Composer(window: window, conversation: conversation, accent: accent, enabled: keyStore.hasKey)
        }
        .tint(accent)
        .background(.background)
        .environment(\.openURL, OpenURLAction { url in
            window.newTab(url: url, after: window.selectedTab)
            return .handled
        })
        .onChange(of: window.pendingAssistantPrompt, initial: true) { _, prompt in
            guard let prompt else { return }
            window.pendingAssistantPrompt = nil
            if keyStore.hasKey, !conversation.isRunning {
                conversation.send(prompt, in: window)
            } else {
                conversation.draft = prompt
            }
        }
    }

    static func modelName(_ id: String) -> String {
        let parts = id.replacingOccurrences(of: "claude-", with: "").split(separator: "-")
        guard let family = parts.first else { return id }
        return ([family.capitalized] + [parts.dropFirst().joined(separator: ".")]).joined(separator: " ")
    }

    static func effortName(_ effort: String) -> String {
        effort == "xhigh" ? "Extra high effort" : "\(effort.capitalized) effort"
    }
}

/// Like Brave's Leo: the name, a model menu, a new-conversation button and a
/// menu with the panel's settings.
private struct AssistantHeader: View {
    let window: BrowserWindowModel
    let conversation: AssistantConversation
    @Bindable private var settings = AppServices.shared.settings

    var body: some View {
        HStack(spacing: 6) {
            Text("Claude")
                .font(.headline)
            Menu {
                Picker("Model", selection: $settings.assistantModel) {
                    ForEach(ClaudeClient.models, id: \.self) { model in
                        Text(AssistantPanel.modelName(model)).tag(model)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(AssistantPanel.modelName(settings.assistantModel))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("Choose the model")
            Spacer()
            Button("New Conversation", systemImage: "square.and.pencil") {
                conversation.reset()
            }
            .disabled(conversation.entries.isEmpty || conversation.isRunning)
            .help("New conversation")
            Menu("More", systemImage: "ellipsis") {
                Picker("Effort", selection: $settings.assistantEffort) {
                    ForEach(ClaudeClient.efforts, id: \.self) { effort in
                        Text(AssistantPanel.effortName(effort)).tag(effort)
                    }
                }
                Divider()
                Button("Claude Settings…") {
                    SettingsWindowController.shared.show(section: .agents)
                }
                Button("Hide Claude") {
                    withAnimation(Theme.Motion.quick) { window.isAssistantVisible = false }
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .frame(height: 40)
    }
}

// MARK: - Empty states

private struct MissingKeyView: View {
    let accent: Color

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.horizontal")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(accent)
            Text("Connect Claude")
                .font(.title3.weight(.semibold))
            Text("Add your Anthropic API key to ask Claude about the pages you visit, or let it work in a tab for you.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 260)
            Button("Add API Key in Settings") {
                SettingsWindowController.shared.show(section: .agents)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(24)
    }
}

private struct WelcomeView: View {
    let window: BrowserWindowModel
    let conversation: AssistantConversation
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            Text("How can I help?")
                .font(.title2.weight(.semibold))
            Text("Ask about the page you're on, or turn on Agent and Claude will click, type and navigate in this tab while you watch.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if conversation.attachablePage(in: window) != nil {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Self.suggestions, id: \.self) { question in
                        Button(question) {
                            conversation.send(question, in: window)
                        }
                        .buttonStyle(SuggestionButtonStyle(accent: accent))
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let suggestions = [
        "Summarize this page",
        "What are the key points?",
        "Explain this in simple terms",
        "What should I double-check here?",
    ]
}

private struct SuggestionButtonStyle: ButtonStyle {
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(accent.opacity(configuration.isPressed ? 0.2 : 0.1), in: .capsule)
            .overlay(Capsule().strokeBorder(accent.opacity(0.25)))
            .contentShape(.capsule)
    }
}

// MARK: - Conversation

private struct ConversationView: View {
    let conversation: AssistantConversation
    let accent: Color

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(conversation.entries) { entry in
                    switch entry.role {
                    case .user:
                        UserMessageView(entry: entry, accent: accent)
                    case .assistant:
                        let isActive = conversation.isRunning && entry === conversation.entries.last
                        AssistantReplyView(entry: entry, accent: accent, isActive: isActive)
                    }
                }
            }
            .padding(16)
        }
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
    }
}

private struct UserMessageView: View {
    let entry: AssistantEntry
    let accent: Color

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            if let page = entry.page {
                Label(page.title, systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(entry.text)
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(accent.opacity(0.14), in: .rect(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 36)
    }
}

private struct AssistantReplyView: View {
    let entry: AssistantEntry
    let accent: Color
    /// The reply Claude is still working on.
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(groups, id: \.first?.id) { group in
                if case .tool = group[0].kind {
                    ToolStalk(steps: group, accent: accent)
                } else {
                    ForEach(group) { part in
                        PartView(part: part)
                    }
                }
            }
            // Between streamed blocks (waiting for the first token, or for the next request) nothing else moves.
            if isActive, !entry.parts.contains(where: \.isStreaming) {
                WorkingIndicator(accent: accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Consecutive tool steps share one stalk.
    private var groups: [[AssistantPart]] {
        var groups: [[AssistantPart]] = []
        for part in entry.parts {
            let isTool = if case .tool = part.kind { true } else { false }
            if isTool, let last = groups.last?.first, case .tool = last.kind {
                groups[groups.count - 1].append(part)
            } else {
                groups.append([part])
            }
        }
        return groups
    }
}

private struct PartView: View {
    let part: AssistantPart

    var body: some View {
        switch part.kind {
        case .text:
            MarkdownText(text: part.text)
                .textSelection(.enabled)
        case .thinking:
            ThinkingView(part: part)
        case .notice(let isError):
            Label(part.text, systemImage: isError ? "exclamationmark.triangle" : "info.circle")
                .font(.callout)
                .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .textSelection(.enabled)
        case .tool:
            EmptyView()
        }
    }
}

private struct ThinkingView: View {
    let part: AssistantPart
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(Theme.Motion.quick) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(title)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(part.text.isEmpty)
            if isExpanded {
                Text(part.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .padding(.leading, 14)
                    .transition(.opacity)
            }
        }
    }

    private var title: String {
        if part.isStreaming { return "Thinking…" }
        guard let seconds = part.finishedAt.map({ Int($0.timeIntervalSince(part.startedAt).rounded()) }), seconds >= 1 else {
            return "Thought briefly"
        }
        return "Thought for \(seconds) s"
    }
}

/// Consecutive tool steps drawn as a bamboo stalk: one stem, a node per step.
private struct ToolStalk: View {
    let steps: [AssistantPart]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(steps) { step in
                ToolStepRow(step: step, accent: accent)
            }
        }
        .background(alignment: .leading) {
            Capsule()
                .fill(accent.opacity(0.28))
                .frame(width: 3)
                .padding(.leading, 7.5)
                .padding(.vertical, 6)
        }
    }
}

private struct ToolStepRow: View {
    let step: AssistantPart
    let accent: Color
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(Theme.Motion.quick) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    node
                        .frame(width: 18)
                    Text(title)
                        .fontWeight(.medium)
                    Text(step.text)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(step.toolResult == nil)
            if isExpanded, let result = step.toolResult {
                VStack(alignment: .leading, spacing: 6) {
                    if let image = step.toolImage {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(.rect(cornerRadius: 6))
                    }
                    Text(result.count > 1200 ? String(result.prefix(1200)) + "…" : result)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.leading, 28)
                .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var node: some View {
        switch step.toolStatus {
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .succeeded:
            Capsule()
                .fill(accent)
                .frame(width: 13, height: 5)
        case .failed:
            Capsule()
                .fill(.red)
                .frame(width: 13, height: 5)
        }
    }

    private var title: String {
        guard case .tool(let name) = step.kind else { return "" }
        return Self.titles[name] ?? name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private static let titles = [
        "tabs_list": "List tabs", "tab_open": "Open tab", "tab_select": "Switch tab", "tab_close": "Close tab",
        "navigate": "Go to", "go_back": "Back", "go_forward": "Forward", "reload": "Reload",
        "snapshot": "Read layout", "click": "Click", "type_text": "Type", "fill_form": "Fill form",
        "select_option": "Choose", "hover": "Hover", "press_key": "Press", "scroll": "Scroll",
        "screenshot": "Screenshot", "read_page": "Read page", "wait_for": "Wait", "dialog_respond": "Answer dialog",
        "evaluate": "Run script", "history_search": "Search history", "bookmarks_search": "Search bookmarks",
    ]
}

private struct WorkingIndicator: View {
    let accent: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(accent)
            .frame(width: 8, height: 8)
            .opacity(pulse ? 0.25 : 0.9)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
            .accessibilityLabel("Claude is working")
    }
}

// MARK: - Composer

private struct Composer: View {
    let window: BrowserWindowModel
    @Bindable var conversation: AssistantConversation
    let accent: Color
    let enabled: Bool
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let page = conversation.currentPage(in: window) {
                PageContentToggle(page: page, favicon: window.selectedTab?.favicon, isShared: Binding {
                    conversation.detachedURL != page.url
                } set: { shared in
                    conversation.detachedURL = shared ? nil : page.url
                })
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField(placeholder, text: $conversation.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...8)
                    .focused($isFocused)
                    .onSubmit(send)
                    .disabled(!enabled)
                HStack(spacing: 8) {
                    agentToggle
                    Spacer()
                    Group {
                        if conversation.isRunning {
                            Button("Stop", systemImage: "stop.fill") { conversation.stop() }
                                .help("Stop Claude")
                        } else {
                            Button("Send", systemImage: "arrow.up", action: send)
                                .disabled(!enabled || conversation.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                .keyboardShortcut(.return, modifiers: .command)
                                .help("Send (Return)")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                }
                .labelStyle(.iconOnly)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.background, in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isFocused ? accent.opacity(0.6) : Color.secondary.opacity(0.25), lineWidth: 1)
            }
        }
        .padding(12)
        .background(.bar)
        .onAppear { isFocused = enabled }
        .onChange(of: window.isPrivate || window.selectedTab == nil, initial: true) { _, unavailable in
            if unavailable { conversation.agentMode = false }
        }
    }

    private var placeholder: String {
        conversation.agentMode ? "Tell Claude what to do in this tab…" : "Ask Claude…"
    }

    private var agentToggle: some View {
        Toggle(isOn: $conversation.agentMode) {
            Label("Agent", systemImage: "cursorarrow.click.2")
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.medium))
        }
        .toggleStyle(.button)
        .buttonStyle(.borderless)
        .foregroundStyle(conversation.agentMode ? accent : .secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(conversation.agentMode ? accent.opacity(0.14) : .clear, in: .capsule)
        .disabled(conversation.isRunning || window.isPrivate || window.selectedTab == nil)
        .help(window.isPrivate ? "Agent mode isn't available in private windows" : "Let Claude use this tab: click, type, navigate")
    }

    private func send() {
        guard enabled, !conversation.isRunning else { return }
        let prompt = conversation.draft
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        conversation.draft = ""
        conversation.send(prompt, in: window)
    }
}

/// Like Leo's "Shared page content": which page Claude can read, with a switch to leave it out.
private struct PageContentToggle: View {
    let page: AttachedPage
    let favicon: NSImage?
    @Binding var isShared: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let favicon {
                    Image(nsImage: favicon).resizable()
                } else {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                }
            }
            .frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(page.title)
                    .lineLimit(1)
                Text(isShared ? "Shared page content" : "Page content not shared")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Toggle("Share page content", isOn: $isShared)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: Theme.Metrics.controlCornerRadius))
        .help(isShared ? "Claude can read \(page.url.absoluteString)" : "Claude won't see this page")
    }
}
