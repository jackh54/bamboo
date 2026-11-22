use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bamboo_agent::{
    AgentClient, AgentError, AgentHost, AgentServer, ToolContent, ToolOutcome, tool_specs,
};
use serde_json::{Value, json};

/// Records what the server tells it. `wait_for` blocks until the test
/// releases it; `screenshot` returns an image; `snapshot` fails.
struct TestHost {
    calls: Mutex<Vec<(String, String, String)>>,
    client_updates: Mutex<Vec<Vec<AgentClient>>>,
    release_slow: Mutex<Receiver<()>>,
    finished_calls: AtomicUsize,
}

impl TestHost {
    fn new() -> (Arc<Self>, Sender<()>) {
        let (release, release_slow) = channel();
        let host = Arc::new(Self {
            calls: Mutex::new(vec![]),
            client_updates: Mutex::new(vec![]),
            release_slow: Mutex::new(release_slow),
            finished_calls: AtomicUsize::new(0),
        });
        (host, release)
    }

    fn latest_clients(&self) -> Option<Vec<AgentClient>> {
        self.client_updates.lock().unwrap().last().cloned()
    }
}

impl AgentHost for TestHost {
    fn call_tool(&self, client_id: String, name: String, arguments_json: String) -> ToolOutcome {
        self.calls
            .lock()
            .unwrap()
            .push((client_id, name.clone(), arguments_json));
        let outcome = match name.as_str() {
            "wait_for" => {
                self.release_slow.lock().unwrap().recv().unwrap();
                text("waited", false)
            }
            "screenshot" => ToolOutcome {
                content: vec![ToolContent::Image {
                    data_base64: "iVBORw0KGgo=".into(),
                    mime_type: "image/png".into(),
                }],
                is_error: false,
            },
            "snapshot" => text("no such tab", true),
            "read_page" => text(&"x".repeat(4 * 1024 * 1024), false),
            _ => text(&format!("ran {name}"), false),
        };
        self.finished_calls.fetch_add(1, Ordering::SeqCst);
        outcome
    }

    fn clients_changed(&self, clients: Vec<AgentClient>) {
        self.client_updates.lock().unwrap().push(clients);
    }
}

fn text(text: &str, is_error: bool) -> ToolOutcome {
    ToolOutcome {
        content: vec![ToolContent::Text { text: text.into() }],
        is_error,
    }
}

/// Socket paths are limited to about 100 bytes, so they live directly in /tmp.
fn temp_socket_path() -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    PathBuf::from(format!(
        "/tmp/bmb-{}-{}.sock",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::SeqCst)
    ))
}

struct TestServer {
    path: PathBuf,
    host: Arc<TestHost>,
    release_slow: Sender<()>,
    server: Arc<AgentServer>,
}

impl TestServer {
    fn start() -> Self {
        let (host, release_slow) = TestHost::new();
        let path = temp_socket_path();
        let server = AgentServer::new(path.to_str().unwrap().into(), host.clone(), "9.9.9".into());
        server.start().unwrap();
        Self {
            path,
            host,
            release_slow,
            server,
        }
    }

    fn connect(&self) -> Client {
        let stream = UnixStream::connect(&self.path).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(10)))
            .unwrap();
        Client {
            reader: BufReader::new(stream.try_clone().unwrap()),
            writer: stream,
        }
    }
}

impl Drop for TestServer {
    fn drop(&mut self) {
        self.server.stop();
    }
}

struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
}

impl Client {
    fn send_raw(&mut self, line: &str) {
        self.writer.write_all(line.as_bytes()).unwrap();
        self.writer.write_all(b"\n").unwrap();
    }

    fn send(&mut self, message: Value) {
        self.send_raw(&message.to_string());
    }

    /// `None` when the server closed the connection.
    fn try_read(&mut self) -> Option<Value> {
        let mut line = String::new();
        let read = self.reader.read_line(&mut line).unwrap();
        (read > 0).then(|| serde_json::from_str(&line).unwrap())
    }

    fn read(&mut self) -> Value {
        self.try_read().expect("connection closed")
    }

    fn request(&mut self, id: i64, method: &str, params: Value) -> Value {
        self.send(json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params}));
        let reply = self.read();
        assert_eq!(reply["id"], id, "{reply}");
        reply
    }

    fn initialize(&mut self) -> Value {
        let reply = self.request(
            1,
            "initialize",
            json!({
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "test-client", "version": "1.2"},
            }),
        );
        self.send(json!({"jsonrpc": "2.0", "method": "notifications/initialized"}));
        reply
    }

    fn call(&mut self, id: i64, name: &str, arguments: Value) -> Value {
        self.request(
            id,
            "tools/call",
            json!({"name": name, "arguments": arguments}),
        )
    }
}

fn wait_until(what: &str, condition: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !condition() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn full_session() {
    let server = TestServer::start();
    let mut client = server.connect();

    let reply = client.initialize();
    let result = &reply["result"];
    assert_eq!(result["protocolVersion"], "2025-06-18");
    assert_eq!(
        result["capabilities"],
        json!({"tools": {"listChanged": true}})
    );
    assert_eq!(
        result["serverInfo"],
        json!({"name": "bamboo", "title": "Bamboo Browser", "version": "9.9.9"})
    );
    assert!(
        result["instructions"]
            .as_str()
            .unwrap()
            .contains("snapshot")
    );

    let reply = client.request(2, "tools/list", json!({}));
    let tools = reply["result"]["tools"].as_array().unwrap();
    let names: Vec<&str> = tools.iter().map(|t| t["name"].as_str().unwrap()).collect();
    let specs = tool_specs();
    assert_eq!(
        names,
        specs.iter().map(|s| s.name.as_str()).collect::<Vec<_>>()
    );
    let snapshot = tools.iter().find(|t| t["name"] == "snapshot").unwrap();
    assert_eq!(snapshot["annotations"]["readOnlyHint"], true);
    assert_eq!(snapshot["inputSchema"]["type"], "object");
    assert!(snapshot["description"].as_str().unwrap().contains("ref="));

    let reply = client.call(3, "click", json!({"ref": "e12"}));
    assert_eq!(
        reply["result"],
        json!({"content": [{"type": "text", "text": "ran click"}], "isError": false})
    );
    let calls = server.host.calls.lock().unwrap().clone();
    assert_eq!(calls.len(), 1);
    assert!(calls[0].0.starts_with("client-"));
    assert_eq!(calls[0].1, "click");
    let arguments: Value = serde_json::from_str(&calls[0].2).unwrap();
    assert_eq!(
        arguments,
        json!({"ref": "e12", "button": "left", "double_click": false})
    );

    let reply = client.call(4, "screenshot", json!({}));
    assert_eq!(
        reply["result"]["content"],
        json!([{"type": "image", "data": "iVBORw0KGgo=", "mimeType": "image/png"}])
    );

    let reply = client.call(5, "snapshot", json!({}));
    assert_eq!(reply["result"]["isError"], true);
}

#[test]
fn negotiates_protocol_version() {
    let server = TestServer::start();
    for (requested, answered) in [
        ("2024-11-05", "2024-11-05"),
        ("2025-03-26", "2025-03-26"),
        ("2025-11-25", "2025-11-25"),
        ("2099-01-01", "2025-11-25"),
    ] {
        let mut client = server.connect();
        let reply = client.request(
            1,
            "initialize",
            json!({"protocolVersion": requested, "capabilities": {}, "clientInfo": {"name": "c", "version": "1"}}),
        );
        assert_eq!(reply["result"]["protocolVersion"], answered);
    }
}

#[test]
fn requests_before_initialize_are_rejected_but_ping_works() {
    let server = TestServer::start();
    let mut client = server.connect();
    assert_eq!(client.request(1, "ping", json!({}))["result"], json!({}));
    for method in ["tools/list", "tools/call"] {
        let reply = client.request(2, method, json!({}));
        assert_eq!(reply["error"]["code"], -32600, "{reply}");
        assert!(
            reply["error"]["message"]
                .as_str()
                .unwrap()
                .contains("initialize")
        );
    }
    assert!(server.host.calls.lock().unwrap().is_empty());
}

#[test]
fn protocol_errors() {
    let server = TestServer::start();
    let mut client = server.connect();

    client.send_raw("{not json");
    let reply = client.read();
    assert_eq!(reply["error"]["code"], -32700);
    assert_eq!(reply["id"], Value::Null);

    client.send_raw("[]");
    assert_eq!(client.read()["error"]["code"], -32600);

    let reply = client.request(1, "initialize", json!({"capabilities": {}}));
    assert_eq!(reply["error"]["code"], -32602);

    client.initialize();
    let reply = client.request(
        2,
        "initialize",
        json!({"protocolVersion": "2025-06-18", "clientInfo": {"name": "c"}}),
    );
    assert_eq!(reply["error"]["code"], -32600);

    assert_eq!(
        client.request(3, "resources/list", json!({}))["error"]["code"],
        -32601
    );
    assert_eq!(
        client.request(4, "tools/call", json!({}))["error"]["code"],
        -32602
    );
    let reply = client.call(5, "no_such_tool", json!({}));
    assert_eq!(reply["error"]["code"], -32602);
    assert!(
        reply["error"]["message"]
            .as_str()
            .unwrap()
            .contains("no_such_tool")
    );

    // Bad arguments are a tool error the model can read and fix.
    let reply = client.call(6, "click", json!({}));
    assert_eq!(reply["result"]["isError"], true);
    assert!(
        reply["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("missing required property \"ref\"")
    );
    assert!(server.host.calls.lock().unwrap().is_empty());

    // Unknown notifications are ignored and the connection stays usable.
    client.send(json!({"jsonrpc": "2.0", "method": "notifications/whatever"}));
    assert_eq!(client.request(7, "ping", json!({}))["result"], json!({}));
}

#[test]
fn disabling_tools_hides_them_and_notifies() {
    let server = TestServer::start();
    let mut client = server.connect();
    client.initialize();
    // Make sure the server processed notifications/initialized.
    client.request(2, "ping", json!({}));

    server
        .server
        .set_disabled_tools(vec!["evaluate".into(), "history_search".into()]);
    let notification = client.read();
    assert_eq!(notification["method"], "notifications/tools/list_changed");
    assert!(notification.get("id").is_none());

    let reply = client.request(3, "tools/list", json!({}));
    let names: Vec<&str> = reply["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert_eq!(names.len(), tool_specs().len() - 2);
    assert!(!names.contains(&"evaluate") && !names.contains(&"history_search"));

    let reply = client.call(4, "evaluate", json!({"expression": "1"}));
    assert_eq!(reply["result"]["isError"], true);
    assert!(
        reply["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("Settings")
    );
    assert!(server.host.calls.lock().unwrap().is_empty());

    server.server.set_disabled_tools(vec![]);
    assert_eq!(client.read()["method"], "notifications/tools/list_changed");
    let reply = client.call(5, "evaluate", json!({"expression": "1"}));
    assert_eq!(reply["result"]["isError"], false);
}

#[test]
fn uninitialized_clients_get_no_list_changed() {
    let server = TestServer::start();
    let mut silent = server.connect();
    let mut ready = server.connect();
    ready.initialize();
    ready.request(2, "ping", json!({}));

    server.server.set_disabled_tools(vec!["hover".into()]);
    assert_eq!(ready.read()["method"], "notifications/tools/list_changed");
    // The next thing the silent client sees is its own ping reply.
    let reply = silent.request(9, "ping", json!({}));
    assert_eq!(reply["result"], json!({}));
}

#[test]
fn ping_is_answered_while_a_tool_call_is_in_flight() {
    let server = TestServer::start();
    let mut client = server.connect();
    client.initialize();

    client.send(json!({"jsonrpc": "2.0", "id": 10, "method": "tools/call",
        "params": {"name": "wait_for", "arguments": {"seconds": 1}}}));
    wait_until("the slow call to start", || {
        !server.host.calls.lock().unwrap().is_empty()
    });

    let reply = client.request(11, "ping", json!({}));
    assert_eq!(reply["result"], json!({}));
    assert_eq!(server.host.finished_calls.load(Ordering::SeqCst), 0);

    server.release_slow.send(()).unwrap();
    let reply = client.read();
    assert_eq!(reply["id"], 10);
    assert_eq!(reply["result"]["content"][0]["text"], "waited");
}

#[test]
fn cancelled_calls_get_no_response() {
    let server = TestServer::start();
    let mut client = server.connect();
    client.initialize();

    client.send(json!({"jsonrpc": "2.0", "id": 20, "method": "tools/call",
        "params": {"name": "wait_for", "arguments": {"seconds": 1}}}));
    wait_until("the slow call to start", || {
        !server.host.calls.lock().unwrap().is_empty()
    });
    client.send(
        json!({"jsonrpc": "2.0", "method": "notifications/cancelled",
        "params": {"requestId": 20, "reason": "user"}}),
    );
    // Notifications are handled in order, so once this ping is answered the
    // cancellation has been processed.
    assert_eq!(client.request(21, "ping", json!({}))["result"], json!({}));

    server.release_slow.send(()).unwrap();
    wait_until("the call to finish", || {
        server.host.finished_calls.load(Ordering::SeqCst) == 1
    });
    std::thread::sleep(Duration::from_millis(100));
    let reply = client.request(22, "ping", json!({}));
    assert_eq!(reply["id"], 22);
}

#[test]
fn clients_are_tracked_and_reported_to_the_host() {
    let server = TestServer::start();
    assert!(server.server.clients().is_empty());

    let mut client = server.connect();
    wait_until("the connection to be reported", || {
        server.host.latest_clients().is_some_and(|c| c.len() == 1)
    });
    let connected = server.host.latest_clients().unwrap();
    assert_eq!(connected[0].name, "");
    assert!(connected[0].connected_at_ms > 0);

    client.initialize();
    wait_until("initialize to be reported", || {
        server
            .host
            .latest_clients()
            .is_some_and(|c| c.first().is_some_and(|c| c.name == "test-client"))
    });
    let initialized = server.host.latest_clients().unwrap();
    assert_eq!(initialized[0].version, "1.2");
    assert_eq!(initialized[0].id, connected[0].id);
    assert_eq!(server.server.clients(), initialized);

    let mut second = server.connect();
    second.initialize();
    wait_until("two clients", || server.server.clients().len() == 2);
    let ids: Vec<String> = server.server.clients().into_iter().map(|c| c.id).collect();
    assert_ne!(ids[0], ids[1]);

    drop(client);
    wait_until("the disconnect to be reported", || {
        server.host.latest_clients().is_some_and(|c| c.len() == 1)
    });
    drop(second);
    wait_until("the last disconnect to be reported", || {
        server.host.latest_clients().is_some_and(|c| c.is_empty())
    });
}

#[test]
fn a_client_that_stops_reading_never_blocks_the_app() {
    let server = TestServer::start();
    let mut stuck = server.connect();
    stuck.initialize();
    stuck.request(2, "ping", json!({}));
    // The 4 MB reply cannot fit in the socket buffers, and this client never reads it.
    stuck.send(json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call",
        "params": {"name": "read_page", "arguments": {}}}));
    wait_until("the tool call to finish", || {
        server.host.finished_calls.load(Ordering::SeqCst) == 1
    });

    let mut healthy = server.connect();
    healthy.initialize();
    healthy.request(2, "ping", json!({}));

    let started = Instant::now();
    server.server.set_disabled_tools(vec!["evaluate".into()]);
    server.server.set_disabled_tools(vec![]);
    assert!(
        started.elapsed() < Duration::from_secs(2),
        "set_disabled_tools blocked"
    );
    // Other clients still get their notifications.
    assert_eq!(healthy.read()["method"], "notifications/tools/list_changed");

    let started = Instant::now();
    server.server.stop();
    assert!(started.elapsed() < Duration::from_secs(2), "stop blocked");
    assert!(!server.server.is_running());
}

#[test]
fn stop_disconnects_clients_and_removes_the_socket() {
    let server = TestServer::start();
    assert!(server.server.is_running());
    let mode = std::fs::metadata(&server.path)
        .unwrap()
        .permissions()
        .mode();
    assert_eq!(mode & 0o777, 0o600);

    let mut client = server.connect();
    client.initialize();
    server.server.stop();

    assert!(!server.server.is_running());
    assert!(!server.path.exists());
    assert!(client.try_read().is_none());
    assert!(server.host.latest_clients().is_some_and(|c| c.is_empty()));
    assert!(server.server.clients().is_empty());

    // It can be started again.
    server.server.start().unwrap();
    assert!(server.server.is_running());
}

#[test]
fn stale_socket_file_is_replaced() {
    let path = temp_socket_path();
    drop(UnixListener::bind(&path).unwrap());
    assert!(path.exists());

    let (host, _release) = TestHost::new();
    let server = AgentServer::new(path.to_str().unwrap().into(), host, "1".into());
    server.start().unwrap();
    let mut stream = UnixStream::connect(&path).unwrap();
    stream
        .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}\n")
        .unwrap();
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).unwrap();
    assert!(line.contains("\"result\""));
    server.stop();
}

#[test]
fn a_live_server_is_never_replaced() {
    let first = TestServer::start();
    let (host, _release) = TestHost::new();
    let second = AgentServer::new(first.path.to_str().unwrap().into(), host, "1".into());

    let Err(AgentError::Io { message }) = second.start() else {
        panic!("second start must fail");
    };
    assert!(message.contains("already running"), "{message}");
    assert!(!second.is_running());

    // The loser's stop() must not tear down the winner's socket.
    second.stop();
    let mut client = first.connect();
    assert_eq!(client.request(1, "ping", json!({}))["result"], json!({}));
}

#[test]
fn starting_twice_and_regular_files_are_errors() {
    let server = TestServer::start();
    let Err(AgentError::Io { message }) = server.server.start() else {
        panic!("start while running must fail");
    };
    assert!(message.contains("already running"), "{message}");

    let path = temp_socket_path();
    std::fs::write(&path, "precious").unwrap();
    let (host, _release) = TestHost::new();
    let other = AgentServer::new(path.to_str().unwrap().into(), host, "1".into());
    let Err(AgentError::Io { message }) = other.start() else {
        panic!("start over a regular file must fail");
    };
    assert!(message.contains("not a socket"), "{message}");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "precious");
    std::fs::remove_file(&path).unwrap();
}
