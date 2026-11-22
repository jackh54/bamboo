import XCTest
@testable import Bamboo

/// Parses recorded Messages API event streams the way ClaudeClient does.
@MainActor
final class ClaudeStreamTests: XCTestCase {
    func testTextStream() throws {
        let builder = try replay("""
            event: message_start
            data: {"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"usage":{"input_tokens":25,"output_tokens":1}}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

            event: ping
            data: {"type": "ping"}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":", world"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":0}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":5}}

            event: message_stop
            data: {"type":"message_stop"}
            """)
        XCTAssertEqual(builder.model, "claude-opus-5-5")
        XCTAssertEqual(builder.stopReason, "end_turn")
        XCTAssertTrue(builder.isFinished)
        XCTAssertEqual(builder.usage["output_tokens"], 5)
        XCTAssertEqual(builder.usage["input_tokens"], 25)
        XCTAssertEqual(builder.content, [["type": "text", "text": "Hello, world"]])
    }

    func testThinkingKeepsSummaryAndSignature() throws {
        let builder = try replay("""
            event: message_start
            data: {"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":10}}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"The user wants a summary."}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCkgIARABGAIiQL1"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":0}

            event: content_block_start
            data: {"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"EmwKAhgBEgy3va3pzix"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":1}

            event: content_block_start
            data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"Here it is."}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":2}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":40}}

            event: message_stop
            data: {"type":"message_stop"}
            """)
        XCTAssertEqual(builder.content, [
            ["type": "thinking", "thinking": "The user wants a summary.", "signature": "EqQBCkgIARABGAIiQL1"],
            ["type": "redacted_thinking", "data": "EmwKAhgBEgy3va3pzix"],
            ["type": "text", "text": "Here it is."],
        ])
    }

    func testToolUseInputArrivesInFragments() throws {
        let builder = try replay("""
            event: message_start
            data: {"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":300}}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Clicking Sign in."}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":0}

            event: content_block_start
            data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_01","name":"click","input":{}}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"ref\\": \\"e1"}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"2\\", \\"double_click\\": false}"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":1}

            event: content_block_start
            data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_02","name":"snapshot","input":{}}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":2}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":60}}

            event: message_stop
            data: {"type":"message_stop"}
            """)
        XCTAssertEqual(builder.stopReason, "tool_use")
        XCTAssertEqual(builder.content[1], [
            "type": "tool_use", "id": "toolu_01", "name": "click", "input": ["ref": "e12", "double_click": false],
        ])
        XCTAssertEqual(builder.content[2]["input"], [:], "a tool with no input fragments gets an empty object")
        let calls = AssistantConversation.callableToolBlocks(builder)
        XCTAssertEqual(calls.map { $0.1.json["id"]?.string }, ["toolu_01", "toolu_02"])
        XCTAssertNil(calls[0].1.inputError)
    }

    func testInvalidToolInputIsReportedNotRun() throws {
        let builder = try replay("""
            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01","name":"type_text","input":{}}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"ref\\": \\"e3\\", \\"text\\": \\"unfinish"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":0}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":64000}}

            event: message_stop
            data: {"type":"message_stop"}
            """)
        let block = try XCTUnwrap(builder.blocks[0])
        XCTAssertNotNil(block.inputError)
        XCTAssertEqual(block.json["input"], [:])
        XCTAssertEqual(builder.stopReason, "max_tokens")
    }

    func testFallbackAndUnknownBlocksAreKeptInPlace() throws {
        let builder = try replay("""
            event: message_start
            data: {"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":12}}}

            event: content_block_start
            data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-a"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":0}

            event: content_block_start
            data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_declined","name":"navigate","input":{}}}

            event: content_block_delta
            data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"url\\": \\"https://example.com\\"}"}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":1}

            event: content_block_start
            data: {"type":"content_block_start","index":2,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-4-8"}}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":2}

            event: content_block_start
            data: {"type":"content_block_start","index":3,"content_block":{"type":"future_block","payload":{"kept":true}}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":3}

            event: content_block_start
            data: {"type":"content_block_start","index":4,"content_block":{"type":"text","text":"Continuing."}}

            event: content_block_stop
            data: {"type":"content_block_stop","index":4}

            event: message_delta
            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}

            event: message_stop
            data: {"type":"message_stop"}
            """)
        XCTAssertEqual(builder.content[2], ["type": "fallback", "from": ["model": "claude-opus-5-5"], "to": ["model": "claude-opus-4-8"]])
        XCTAssertEqual(builder.content[3], ["type": "future_block", "payload": ["kept": true]])

        // Echoed back: everything in place except the declined attempt's tool call.
        let echoed = AssistantConversation.echoed(builder)
        XCTAssertEqual(echoed.map { $0["type"]?.string }, ["thinking", "fallback", "future_block", "text"])
        XCTAssertEqual(echoed[0], ["type": "thinking", "thinking": "", "signature": "sig-a"])
        XCTAssertTrue(AssistantConversation.callableToolBlocks(builder).isEmpty)
    }

    func testErrorEvent() throws {
        let builder = try replay("""
            event: message_start
            data: {"type":"message_start","message":{"model":"claude-opus-5-5","usage":{"input_tokens":12}}}

            event: error
            data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
            """)
        let error = try XCTUnwrap(builder.error)
        XCTAssertEqual(error.type, "overloaded_error")
        XCTAssertTrue(error.isRetryable)
        XCTAssertEqual(error.localizedDescription, "Overloaded")
        XCTAssertFalse(builder.isFinished)
    }

    func testParserHandlesLinesWithoutBlankSeparators() {
        // URLSession's `bytes.lines` drops blank lines, so events run together.
        var parser = ServerSentEventParser()
        var events: [ServerSentEvent] = []
        for line in ["event: ping", "data: {\"type\":\"ping\"}", ": comment", "event: message_stop", "data: {\"type\":\"message_stop\"}"] {
            events += parser.feed(line)
        }
        events += parser.finish()
        XCTAssertEqual(events, [
            ServerSentEvent(name: "ping", data: "{\"type\":\"ping\"}"),
            ServerSentEvent(name: "message_stop", data: "{\"type\":\"message_stop\"}"),
        ])
    }

    func testHTTPErrorMessages() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens: too large"}}"#.utf8)
        let badRequest = ClaudeAPIError(status: 400, body: body, retryAfter: nil)
        XCTAssertEqual(badRequest.localizedDescription, "HTTP 400: max_tokens: too large")
        XCTAssertFalse(badRequest.isRetryable)
        let unauthorized = ClaudeAPIError(status: 401, body: Data(), retryAfter: nil)
        XCTAssertTrue(unauthorized.localizedDescription.contains("valid key"))
        XCTAssertTrue(ClaudeAPIError(status: 529, body: Data(), retryAfter: 2).isRetryable)
        XCTAssertTrue(ClaudeAPIError(status: 429, body: Data(), retryAfter: 2).isRetryable)
    }

    private func replay(_ stream: String) throws -> ClaudeMessageBuilder {
        var parser = ServerSentEventParser()
        var builder = ClaudeMessageBuilder()
        let lines = stream.components(separatedBy: "\n")
        for event in lines.flatMap({ parser.feed($0) }) + parser.finish() {
            builder.apply(try ClaudeStreamEvent(event))
        }
        return builder
    }
}
