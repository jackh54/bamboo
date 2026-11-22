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

    var socketPath: String { AppPaths.agentSocket.path }

    func start() {
        let server = AgentServer(
            socketPath: socketPath, host: AgentHostBridge(),
            serverVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
        self.server = server
        applySettings()
    }

    func stop() {
        server?.stop()
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
            server.setDisabledTools(names: disabledTools)
            let enabled = AppServices.shared.settings.agentServerEnabled
            if enabled, !server.isRunning() {
                do {
                    try server.start()
                    startError = nil
                } catch {
                    startError = error.localizedDescription
                    AppServices.shared.reportNonFatal(error, "Starting the agent server")
                }
            } else if !enabled, server.isRunning() {
                stop()
            }
            isRunning = server.isRunning()
        } onChange: {
            Task { @MainActor in AppServices.shared.agent.applySettings() }
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
