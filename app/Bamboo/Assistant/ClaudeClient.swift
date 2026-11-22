import Foundation

/// Calls the Claude Messages API over HTTPS with streaming (there is no
/// official Swift SDK). Never logs the API key or request bodies.
struct ClaudeClient: Sendable {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    static let maxTokens = 64000
    static let models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]
    private static let maxRetries = 3

    var apiKey: String
    var session: URLSession = .shared

    /// The request body. Sampling parameters (`temperature`, `top_p`, `top_k`)
    /// are rejected on this API version, and these models reject disabled
    /// thinking and `budget_tokens`, so neither is ever sent.
    static func requestBody(
        model: String, effort: String, system: String, messages: [JSONValue], tools: [ToolSpec]
    ) throws -> JSONValue {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
            "stream": true,
            "thinking": ["type": "adaptive", "display": "summarized"],
            "output_config": ["effort": .string(effort)],
            "fallbacks": "default",
            "system": .string(system),
            "messages": .array(messages),
        ]
        if !tools.isEmpty {
            body["tools"] = .array(try tools.map { spec in
                [
                    "name": .string(spec.name),
                    "description": .string(spec.description),
                    "input_schema": try JSONValue(parsing: spec.inputSchemaJson),
                    "eager_input_streaming": true,
                ]
            })
        }
        return .object(body)
    }

    func makeRequest(body: JSONValue) -> URLRequest {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta")
        request.httpBody = Data(body.jsonString.utf8)
        request.timeoutInterval = 600
        return request
    }

    /// Streams one response. Rate-limit and overload errors are retried (up to
    /// three times, honouring `retry-after`) while nothing has streamed yet.
    func stream(body: JSONValue) -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        let request = makeRequest(body: body)
        let session = session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var attempt = 0
                    while true {
                        do {
                            try await Self.streamOnce(request, session: session) { continuation.yield($0) }
                            continuation.finish()
                            return
                        } catch let error as ClaudeAPIError where error.isRetryable && attempt < Self.maxRetries {
                            attempt += 1
                            let delay = error.retryAfter ?? pow(2, Double(attempt))
                            try await Task.sleep(for: .seconds(min(delay, 60)))
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Checks the key and model with `GET /v1/models/{model}`, which costs no tokens.
    func testConnection(model: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models/\(model)")!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { throw ClaudeAPIError(status: http.statusCode, body: data, retryAfter: nil) }
        return (try? JSONValue(parsing: String(decoding: data, as: UTF8.self)))?["display_name"]?.string ?? model
    }

    private static func streamOnce(
        _ request: URLRequest, session: URLSession, yield: (ClaudeStreamEvent) -> Void
    ) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
                if body.count > 65_536 { break }
            }
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
            throw ClaudeAPIError(status: http.statusCode, body: body, retryAfter: retryAfter)
        }
        var parser = ServerSentEventParser()
        var streamedContent = false
        for try await line in bytes.lines {
            for event in parser.feed(line) {
                let decoded = try ClaudeStreamEvent(event)
                if case .error(let error) = decoded {
                    // An overload before any content can be retried as a whole request.
                    if !streamedContent, error.isRetryable { throw error }
                }
                if case .blockStart = decoded { streamedContent = true }
                yield(decoded)
            }
        }
        for event in parser.finish() {
            yield(try ClaudeStreamEvent(event))
        }
    }
}

struct ClaudeAPIError: LocalizedError, Sendable {
    var status: Int?
    var type: String?
    var message: String
    var retryAfter: Double?

    init(status: Int, body: Data, retryAfter: Double?) {
        self.status = status
        self.retryAfter = retryAfter
        let json = try? JSONValue(parsing: String(decoding: body, as: UTF8.self))
        type = json?["error"]?["type"]?.string
        message = json?["error"]?["message"]?.string ?? HTTPURLResponse.localizedString(forStatusCode: status)
    }

    init(event: JSONValue) {
        type = event["error"]?["type"]?.string
        message = event["error"]?["message"]?.string ?? "The stream reported an error."
    }

    var isRetryable: Bool {
        status == 429 || status == 529 || type == "overloaded_error" || type == "rate_limit_error"
    }

    var errorDescription: String? {
        if status == 401 {
            return "Anthropic rejected the API key (401). Add a valid key in Settings ▸ Claude."
        }
        let code = status.map { "HTTP \($0): " } ?? ""
        return code + message
    }
}

// MARK: - Server-sent events

struct ServerSentEvent: Equatable, Sendable {
    var name: String
    var data: String
}

/// Splits an SSE stream into events. Accepts the lines of `URLSession.bytes`,
/// which drops blank lines, so a new `event:` line also ends the previous event.
struct ServerSentEventParser {
    private var name = ""
    private var data: [String] = []

    mutating func feed(_ line: String) -> [ServerSentEvent] {
        if line.isEmpty { return flush() }
        if line.hasPrefix(":") { return [] }
        let (field, value) = Self.split(line)
        switch field {
        case "event":
            let pending = flush()
            name = value
            return pending
        case "data":
            data.append(value)
            return []
        default:
            return []
        }
    }

    mutating func finish() -> [ServerSentEvent] {
        flush()
    }

    private mutating func flush() -> [ServerSentEvent] {
        defer {
            name = ""
            data = []
        }
        guard !data.isEmpty else { return [] }
        return [ServerSentEvent(name: name.isEmpty ? "message" : name, data: data.joined(separator: "\n"))]
    }

    private static func split(_ line: String) -> (String, String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        var value = line[line.index(after: colon)...]
        if value.first == " " { value = value.dropFirst() }
        return (String(line[..<colon]), String(value))
    }
}

enum ClaudeStreamEvent: Sendable {
    case messageStart(JSONValue)
    case blockStart(index: Int, block: JSONValue)
    case delta(index: Int, delta: JSONValue)
    case blockStop(index: Int)
    case messageDelta(JSONValue)
    case messageStop
    case ping
    case error(ClaudeAPIError)
    /// Event types added after this code was written.
    case unknown(String)

    init(_ event: ServerSentEvent) throws {
        let json = try JSONValue(parsing: event.data)
        let type = json["type"]?.string ?? event.name
        let index = Int(json["index"]?.number ?? 0)
        switch type {
        case "message_start": self = .messageStart(json["message"] ?? .null)
        case "content_block_start": self = .blockStart(index: index, block: json["content_block"] ?? .null)
        case "content_block_delta": self = .delta(index: index, delta: json["delta"] ?? .null)
        case "content_block_stop": self = .blockStop(index: index)
        case "message_delta": self = .messageDelta(json)
        case "message_stop": self = .messageStop
        case "ping": self = .ping
        case "error": self = .error(ClaudeAPIError(event: json))
        default: self = .unknown(type)
        }
    }
}

// MARK: - Rebuilding the message

/// Rebuilds the assistant message from stream events. Blocks are kept as
/// JSON so thinking blocks (with signatures), `fallback` blocks and block
/// types this code doesn't know are sent back exactly as received.
struct ClaudeMessageBuilder {
    struct Block {
        var json: [String: JSONValue]
        /// Accumulated `input_json_delta` fragments of a tool_use block.
        var partialInput = ""
        /// Set when a tool_use block's input isn't valid JSON.
        var inputError: String?
        var isComplete = false

        var type: String { json["type"]?.string ?? "" }
    }

    private(set) var blocks: [Int: Block] = [:]
    private(set) var model: String?
    private(set) var stopReason: String?
    private(set) var stopDetails: JSONValue?
    private(set) var usage: [String: JSONValue] = [:]
    private(set) var error: ClaudeAPIError?
    private(set) var isFinished = false

    /// Applies one event and returns the index of the block it changed, if any.
    @discardableResult
    mutating func apply(_ event: ClaudeStreamEvent) -> Int? {
        switch event {
        case .messageStart(let message):
            model = message["model"]?.string
            usage = message["usage"]?.object ?? [:]
        case .blockStart(let index, let block):
            var start = Block(json: block.object ?? [:])
            if start.type == "tool_use" {
                // The input arrives as JSON fragments; the start carries an empty object.
                start.json["input"] = nil
            }
            blocks[index] = start
            return index
        case .delta(let index, let delta):
            guard var block = blocks[index] else { return nil }
            switch delta["type"]?.string {
            case "text_delta":
                block.json["text"] = .string((block.json["text"]?.string ?? "") + (delta["text"]?.string ?? ""))
            case "thinking_delta":
                block.json["thinking"] = .string((block.json["thinking"]?.string ?? "") + (delta["thinking"]?.string ?? ""))
            case "signature_delta":
                block.json["signature"] = .string((block.json["signature"]?.string ?? "") + (delta["signature"]?.string ?? ""))
            case "input_json_delta":
                block.partialInput += delta["partial_json"]?.string ?? ""
            case "citations_delta":
                if let citation = delta["citation"] {
                    block.json["citations"] = .array((block.json["citations"]?.array ?? []) + [citation])
                }
            default:
                break
            }
            blocks[index] = block
            return index
        case .blockStop(let index):
            guard var block = blocks[index] else { return nil }
            if block.type == "tool_use" {
                let text = block.partialInput.isEmpty ? "{}" : block.partialInput
                do {
                    let input = try JSONValue(parsing: text)
                    guard input.object != nil else { throw ToolFailure("the input is not a JSON object") }
                    block.json["input"] = input
                } catch {
                    block.inputError = "The tool input is not valid JSON (\(error.localizedDescription))."
                    // The message must still carry an object for this tool_use.
                    block.json["input"] = .object([:])
                }
            }
            block.isComplete = true
            blocks[index] = block
            return index
        case .messageDelta(let json):
            stopReason = json["delta"]?["stop_reason"]?.string ?? stopReason
            if let details = json["delta"]?["stop_details"], details != .null { stopDetails = details }
            for (key, value) in json["usage"]?.object ?? [:] {
                usage[key] = value
            }
        case .messageStop:
            isFinished = true
        case .error(let apiError):
            error = apiError
        case .ping, .unknown:
            break
        }
        return nil
    }

    /// The content blocks in order, as they go back into the conversation.
    var content: [JSONValue] {
        blocks.keys.sorted().compactMap { blocks[$0] }.map { .object($0.json) }
    }

    var orderedBlocks: [Block] {
        blocks.keys.sorted().compactMap { blocks[$0] }
    }
}
