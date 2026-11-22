import Foundation
import Observation

/// Runs the MCP server agents connect to and routes their tool calls to the
/// executor. The server starts and stops with `settings.agentServerEnabled`,
/// and hides tools the user hasn't allowed.
@MainActor
@Observable
final class AgentHub {
    let executor = BrowserToolExecutor()
    private(set) var clients: [AgentClient] = []
    private(set) var isRunning = false
    /// Why the server couldn't start, shown in Settings.
    private(set) var startError: String?

    @ObservationIgnored private var server: AgentServer?
    @ObservationIgnored private var sessions: [String: AgentSession] = [:]
    /// Server calls that write to every client (tool list changes, stopping)
    /// run here in order: a client that stops reading must not block the main thread.
    @ObservationIgnored private let serverQueue = DispatchQueue(label: "dev.pandascript.Bamboo.agent-server")

    var socketPath: String { AppPaths.agentSocket.path }

    func start() {
        let server = AgentServer(
            socketPath: socketPath, host: AgentHostBridge(),
            serverVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
        self.server = server
        applySettings()
    }

    /// At quit. Waits briefly so the socket file is removed, but a stuck
    /// client can't keep the app from quitting.
    func stop() {
        guard let server else { return }
        let stopped = DispatchSemaphore(value: 0)
        serverQueue.async {
            server.stop()
            stopped.signal()
        }
        _ = stopped.wait(timeout: .now() + 2)
        isRunning = false
        clients = []
    }

    /// Tools the user hasn't allowed; the server hides them and the executor refuses them.
    var disabledTools: [String] {
        let settings = AppServices.shared.settings
        var names: [String] = []
        if !settings.agentCanEvaluateJavaScript { names.append("evaluate") }
        if !settings.agentCanReadHistory { names += ["history_search", "bookmarks_search"] }
        return names
    }

    private func applySettings() {
        guard let server else { return }
        withObservationTracking {
            let disabled = disabledTools
            let enabled = AppServices.shared.settings.agentServerEnabled
            serverQueue.async {
                server.setDisabledTools(names: disabled)
                let failure: String?
                if enabled, !server.isRunning() {
                    do {
                        try server.start()
                        failure = nil
                    } catch {
                        failure = error.localizedDescription
                    }
                } else {
                    if !enabled, server.isRunning() { server.stop() }
                    failure = nil
                }
                let running = server.isRunning()
                Task { @MainActor in AppServices.shared.agent.serverChanged(isRunning: running, startError: failure) }
            }
        } onChange: {
            Task { @MainActor in AppServices.shared.agent.applySettings() }
        }
    }

    private func serverChanged(isRunning: Bool, startError: String?) {
        self.isRunning = isRunning
        self.startError = startError
        if !isRunning {
            clients = []
        }
    }

    // MARK: - Calls from the server

    fileprivate func callTool(clientID: String, name: String, argumentsJSON: String) async -> ToolOutcome {
        let arguments: JSONValue
        do {
            arguments = try JSONValue(parsing: argumentsJSON)
        } catch {
            return ToolOutcome(content: [.text(text: "The arguments are not valid JSON: \(error.localizedDescription)")], isError: true)
        }
        // Calls already queued when the user turned agents off don't run.
        guard AppServices.shared.settings.agentServerEnabled else {
            return ToolOutcome(content: [.text(text: "The user turned off agent access in Bamboo's settings.")], isError: true)
        }
        if disabledTools.contains(name) {
            return ToolOutcome(content: [.text(text: "\(name) is turned off in Bamboo's settings.")], isError: true)
        }
        return await executor.run(name, arguments: arguments, session: session(for: clientID))
    }

    fileprivate func clientsChanged(_ clients: [AgentClient]) {
        self.clients = clients
        let connected = Set(clients.map(\.id))
        sessions = sessions.filter { connected.contains($0.key) }
        for client in clients {
            sessions[client.id]?.name = client.name
        }
    }

    private func session(for clientID: String) -> AgentSession {
        if let session = sessions[clientID] { return session }
        let name = clients.first { $0.id == clientID }?.name ?? "Agent"
        let session = AgentSession(id: clientID, name: name)
        sessions[clientID] = session
        return session
    }
}

/// The server calls this on its own threads. Each call hops to the main actor
/// and blocks only that server thread until the tool finishes; the executor
/// bounds every tool with a time limit.
private final class AgentHostBridge: AgentHost {
    func callTool(clientId: String, name: String, argumentsJson: String) -> ToolOutcome {
        precondition(!Thread.isMainThread, "Agent tools must not be called on the main thread")
        let result = OutcomeBox()
        let done = DispatchSemaphore(value: 0)
        Task { @MainActor in
            result.set(await AppServices.shared.agent.callTool(clientID: clientId, name: name, argumentsJSON: argumentsJson))
            done.signal()
        }
        done.wait()
        return result.get()
    }

    func clientsChanged(clients: [AgentClient]) {
        Task { @MainActor in AppServices.shared.agent.clientsChanged(clients) }
    }
}

private final class OutcomeBox: @unchecked Sendable {
    // Written once on the main actor before the semaphore is signalled, read after the wait.
    private var outcome: ToolOutcome?
    private let lock = NSLock()

    func set(_ outcome: ToolOutcome) {
        lock.withLock { self.outcome = outcome }
    }

    func get() -> ToolOutcome {
        lock.withLock {
            guard let outcome else { preconditionFailure("Tool finished without an outcome") }
            return outcome
        }
    }
}
