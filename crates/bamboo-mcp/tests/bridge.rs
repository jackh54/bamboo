use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::Arc;

use bamboo_agent::{AgentClient, AgentHost, AgentServer, ToolContent, ToolOutcome};
use serde_json::{Value, json};

struct EchoHost;

impl AgentHost for EchoHost {
    fn call_tool(&self, _client_id: String, name: String, _arguments_json: String) -> ToolOutcome {
        ToolOutcome {
            content: vec![ToolContent::Text {
                text: format!("ran {name}"),
            }],
            is_error: false,
        }
    }

    fn clients_changed(&self, _clients: Vec<AgentClient>) {}
}

fn bridge(socket: &std::path::Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_bamboo-mcp"));
    command
        .env("BAMBOO_AGENT_SOCKET", socket)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    command
}

const INITIALIZE: &str = r#"{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"bridge-test","version":"0"}}}"#;

#[test]
fn bridges_a_session_to_the_server() {
    let socket = PathBuf::from(format!("/tmp/bmb-bridge-{}.sock", std::process::id()));
    let server = AgentServer::new(
        socket.to_str().unwrap().into(),
        Arc::new(EchoHost),
        "3.1.4".into(),
    );
    server.start().unwrap();

    let mut child = bridge(&socket).spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let mut read = move || {
        let mut line = String::new();
        stdout.read_line(&mut line).unwrap();
        serde_json::from_str::<Value>(&line).unwrap()
    };

    writeln!(stdin, "{INITIALIZE}").unwrap();
    let reply = read();
    assert_eq!(reply["id"], 7);
    assert_eq!(reply["result"]["serverInfo"]["version"], "3.1.4");
    assert_eq!(server.clients()[0].name, "bridge-test");

    writeln!(
        stdin,
        "{}",
        json!({"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "reload", "arguments": {}}})
    )
    .unwrap();
    assert_eq!(read()["result"]["content"][0]["text"], "ran reload");

    // Closing stdin ends the bridge cleanly.
    drop(stdin);
    assert!(child.wait().unwrap().success());
    server.stop();
}

#[test]
fn explains_why_it_cannot_connect() {
    // A path below a regular file fails with NotADirectory, so the bridge
    // reports it instead of trying to launch the real app.
    let file = tempfile_path("explain");
    std::fs::write(&file, "").unwrap();
    let socket = file.join("agent.sock");

    let mut child = bridge(&socket).spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    writeln!(stdin, "{INITIALIZE}").unwrap();
    let output = child.wait_with_output().unwrap();
    std::fs::remove_file(&file).unwrap();

    assert_eq!(output.status.code(), Some(1));
    let reply: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(reply["id"], 7);
    assert_eq!(reply["error"]["code"], -32000);
    let message = reply["error"]["message"].as_str().unwrap();
    assert!(
        message.starts_with("Bamboo is not running and could not be started: "),
        "{message}"
    );
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains(message), "{stderr}");
}

#[test]
fn other_first_messages_only_get_the_stderr_explanation() {
    let file = tempfile_path("other");
    std::fs::write(&file, "").unwrap();
    let socket = file.join("agent.sock");

    let mut child = bridge(&socket).spawn().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    writeln!(stdin, r#"{{"jsonrpc":"2.0","id":1,"method":"ping"}}"#).unwrap();
    let output = child.wait_with_output().unwrap();
    std::fs::remove_file(&file).unwrap();

    assert_eq!(output.status.code(), Some(1));
    assert!(output.stdout.is_empty());
    assert!(
        String::from_utf8(output.stderr)
            .unwrap()
            .contains("Bamboo is not running")
    );
}

fn tempfile_path(test: &str) -> PathBuf {
    PathBuf::from(format!("/tmp/bmb-{test}-{}", std::process::id()))
}
