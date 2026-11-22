import AppKit
import SwiftUI

/// The "Claude" settings section (Brave calls its equivalent "Leo"): the side
/// panel's key and model first, then what outside agents may do. Embedded by SettingsView.
struct AgentSettingsView: View {
    @Bindable private var settings = AppServices.shared.settings
    private let hub = AppServices.shared.agent

    var body: some View {
        Form {
            AssistantSettingsSection(settings: settings)
            serverSection
            accessSection
            ConnectSection()
            activitySection
        }
        .formStyle(.grouped)
        .navigationTitle("Claude")
    }

    private var serverSection: some View {
        Section {
            Toggle(isOn: $settings.agentServerEnabled) {
                Text("Let AI agents control Bamboo")
                Text("Claude Code, Claude Desktop and other MCP clients connect through a socket only your user account can open.")
            }
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Circle()
                        .fill(hub.isRunning ? Color.green : hub.startError == nil ? Color.secondary : Color.red)
                        .frame(width: 7, height: 7)
                    Text(hub.isRunning ? "Running" : hub.startError.map { "Couldn't start: \($0)" } ?? "Off")
                }
            }
            LabeledContent("Socket") {
                Text(hub.socketPath)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if hub.clients.isEmpty {
                LabeledContent("Connected agents", value: "None")
            } else {
                ForEach(hub.clients, id: \.id) { client in
                    LabeledContent(client.name.isEmpty ? "Unnamed client" : client.name) {
                        Text("\(client.version) · since \(Date(timeIntervalSince1970: Double(client.connectedAtMs) / 1000).formatted(date: .omitted, time: .shortened))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Agents")
        }
    }

    private var accessSection: some View {
        Section("What agents can use") {
            Picker("Agents can use", selection: $settings.agentAccess) {
                Text("Only tabs they open or you hand over").tag(AgentAccess.agentTabsOnly)
                Text("Every tab except private windows").tag(AgentAccess.allTabs)
            }
            .pickerStyle(.radioGroup)
            Toggle(isOn: $settings.agentCanEvaluateJavaScript) {
                Text("Run JavaScript on pages")
                Text("Lets agents use the evaluate tool, which can read and change anything on a page they control.")
            }
            Toggle(isOn: $settings.agentCanReadHistory) {
                Text("Search history and bookmarks")
            }
        }
    }

    private var activitySection: some View {
        Section("Recent activity") {
            if hub.executor.recentActivity.isEmpty {
                Text("Nothing yet. Tool calls from agents and Claude appear here.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(hub.executor.recentActivity.prefix(20)) { activity in
                    HStack(spacing: 8) {
                        Image(systemName: activity.isError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                            .foregroundStyle(activity.isError ? Color.red : Color.secondary)
                        Text(activity.actor)
                            .fontWeight(.medium)
                        Text(activity.tool)
                            .font(.system(.body, design: .monospaced))
                        Text(activity.summary)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(activity.date, style: .time)
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

// MARK: - Connecting MCP clients

private struct ConnectSection: View {
    @State private var claudeCodeOutput: String?
    @State private var isAddingToClaudeCode = false
    @State private var desktopInstalled = false
    @State private var desktopMessage: String?

    private static let serverName = "bamboo"
    private static let claudeCodeCandidates = ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]

    private var bridgePath: String {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/bamboo-mcp").path
    }

    private var claudeCodeCommand: String {
        "claude mcp add --scope user \(Self.serverName) -- \"\(bridgePath)\""
    }

    private var desktopConfigPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Claude/claude_desktop_config.json").path
    }

    private var claudeBinary: String? {
        Self.claudeCodeCandidates
            .map { NSString(string: $0).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private var genericConfig: String {
        """
        {
          "mcpServers": {
            "\(Self.serverName)": {
              "command": "\(bridgePath)"
            }
          }
        }
        """
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude Code")
                    .font(.headline)
                CopyableCode(text: claudeCodeCommand)
                HStack {
                    if let claudeBinary {
                        Button(isAddingToClaudeCode ? "Adding…" : "Add to Claude Code") {
                            addToClaudeCode(claudeBinary)
                        }
                        .disabled(isAddingToClaudeCode)
                    } else {
                        Text("Install Claude Code, then run this command in Terminal.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let claudeCodeOutput {
                    Text(claudeCodeOutput)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Claude Desktop")
                        .font(.headline)
                    Spacer()
                    if desktopInstalled {
                        Button("Remove", action: removeFromDesktop)
                    } else {
                        Button("Add to Claude Desktop", action: addToDesktop)
                    }
                }
                Text(desktopInstalled
                     ? "Bamboo is in Claude Desktop's MCP servers. Restart Claude Desktop after any change."
                     : "Adds Bamboo to Claude Desktop's MCP servers and keeps your other settings. Restart Claude Desktop afterwards.")
                    .foregroundStyle(.secondary)
                if let desktopMessage {
                    Text(desktopMessage)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Other MCP clients")
                    .font(.headline)
                Text("Add Bamboo as a stdio server:")
                    .foregroundStyle(.secondary)
                CopyableCode(text: genericConfig)
            }
        } header: {
            Text("Connect an agent")
        }
        .onAppear(perform: refreshDesktopStatus)
    }

    private func addToClaudeCode(_ binary: String) {
        isAddingToClaudeCode = true
        claudeCodeOutput = nil
        let arguments = ["mcp", "add", "--scope", "user", Self.serverName, "--", bridgePath]
        Task {
            claudeCodeOutput = await Self.run(binary, arguments)
            isAddingToClaudeCode = false
        }
    }

    private static func run(_ binary: String, _ arguments: [String]) async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                return "Couldn't run \(binary): \(error.localizedDescription)"
            }
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return process.terminationStatus == 0
                ? (trimmed.isEmpty ? "Added." : trimmed)
                : "claude exited with status \(process.terminationStatus): \(trimmed)"
        }.value
    }

    private func refreshDesktopStatus() {
        do {
            desktopInstalled = try claudeDesktopServerInstalled(configPath: desktopConfigPath, serverName: Self.serverName)
        } catch {
            desktopMessage = "Couldn't read Claude Desktop's settings: \(error.localizedDescription)"
        }
    }

    private func addToDesktop() {
        do {
            try installClaudeDesktopServer(configPath: desktopConfigPath, serverName: Self.serverName, commandPath: bridgePath)
            desktopMessage = nil
        } catch {
            desktopMessage = "Couldn't update Claude Desktop's settings: \(error.localizedDescription)"
        }
        refreshDesktopStatus()
    }

    private func removeFromDesktop() {
        do {
            try removeClaudeDesktopServer(configPath: desktopConfigPath, serverName: Self.serverName)
            desktopMessage = nil
        } catch {
            desktopMessage = "Couldn't update Claude Desktop's settings: \(error.localizedDescription)"
        }
        refreshDesktopStatus()
    }
}

private struct CopyableCode: View {
    let text: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
    }
}

// MARK: - The Claude panel

private struct AssistantSettingsSection: View {
    @Bindable var settings: AppSettings
    private var keyStore: AnthropicKeyStore { .shared }
    @State private var newKey = ""
    @State private var keyError: String?
    @State private var connectionResult: (ok: Bool, message: String)?
    @State private var isTesting = false

    var body: some View {
        Section {
            if let masked = keyStore.maskedKey {
                LabeledContent("API key") {
                    HStack {
                        Text(masked)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Button("Remove", role: .destructive, action: removeKey)
                    }
                }
            } else {
                LabeledContent("API key") {
                    HStack {
                        SecureField("API key", text: $newKey, prompt: Text("sk-ant-…"))
                            .labelsHidden()
                            .frame(minWidth: 240)
                            .onSubmit(saveKey)
                        Button("Save", action: saveKey)
                            .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Text("Create a key in the Claude Console (platform.claude.com). Bamboo keeps it in your Keychain and sends it only to api.anthropic.com.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = keyError ?? keyStore.readError {
                Text(error)
                    .foregroundStyle(.red)
            }
            Picker("Model", selection: $settings.assistantModel) {
                ForEach(ClaudeClient.models, id: \.self) { model in
                    Text(AssistantPanel.modelName(model)).tag(model)
                }
            }
            Picker("Effort", selection: $settings.assistantEffort) {
                ForEach(ClaudeClient.efforts, id: \.self) { effort in
                    Text(effort == "xhigh" ? "Extra high" : effort.capitalized).tag(effort)
                }
            }
            HStack {
                Button(isTesting ? "Testing…" : "Test Connection", action: testConnection)
                    .disabled(!keyStore.hasKey || isTesting)
                if let connectionResult {
                    Label(connectionResult.message, systemImage: connectionResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(connectionResult.ok ? Color.green : Color.red)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Assistant")
        } footer: {
            Text("Higher effort thinks longer and costs more. Medium suits most questions about a page.")
        }
    }

    private func saveKey() {
        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try keyStore.save(key)
            newKey = ""
            keyError = nil
            connectionResult = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func removeKey() {
        do {
            try keyStore.delete()
            keyError = nil
            connectionResult = nil
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func testConnection() {
        isTesting = true
        connectionResult = nil
        let model = settings.assistantModel
        Task {
            defer { isTesting = false }
            do {
                guard let key = try keyStore.key() else { return }
                let name = try await ClaudeClient(apiKey: key).testConnection(model: model)
                connectionResult = (true, "Connected to \(name)")
            } catch {
                connectionResult = (false, error.localizedDescription)
            }
        }
    }
}
