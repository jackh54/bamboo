//! Bridges an MCP client's stdio to Bamboo's agent socket.
//!
//! The socket carries newline-delimited JSON-RPC, the same framing as stdio,
//! so the bridge copies bytes in both directions without parsing them.

use std::env;
use std::io::{self, BufRead, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, ExitCode};
use std::thread;
use std::time::{Duration, Instant};

const BUNDLE_ID: &str = "dev.pandascript.Bamboo";
const LAUNCH_TIMEOUT: Duration = Duration::from_secs(20);
const RETRY_INTERVAL: Duration = Duration::from_millis(250);

fn main() -> ExitCode {
    match connect() {
        Ok(stream) => {
            eprintln!("bamboo-mcp: {}", pipe(stream));
            ExitCode::FAILURE
        }
        Err(reason) => {
            explain(&format!(
                "Bamboo is not running and could not be started: {reason}"
            ));
            ExitCode::FAILURE
        }
    }
}

fn socket_path() -> Result<PathBuf, String> {
    if let Some(path) = env::var_os("BAMBOO_AGENT_SOCKET") {
        return Ok(path.into());
    }
    let home = env::var_os("HOME").ok_or("HOME is not set")?;
    Ok(PathBuf::from(home).join("Library/Application Support/Bamboo/agent.sock"))
}

/// Connects to the agent socket, launching Bamboo in the background if it is not running.
fn connect() -> Result<UnixStream, String> {
    let path = socket_path()?;
    let not_running = |error: &io::Error| {
        matches!(
            error.kind(),
            io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
        )
    };
    match UnixStream::connect(&path) {
        Ok(stream) => return Ok(stream),
        Err(error) if not_running(&error) => {}
        Err(error) => return Err(format!("cannot connect to {}: {error}", path.display())),
    }

    let status = Command::new("/usr/bin/open")
        .args(["-g", "-b", BUNDLE_ID])
        .status()
        .map_err(|error| format!("cannot run /usr/bin/open: {error}"))?;
    if !status.success() {
        return Err(format!("`open -b {BUNDLE_ID}` failed ({status})"));
    }

    let deadline = Instant::now() + LAUNCH_TIMEOUT;
    loop {
        match UnixStream::connect(&path) {
            Ok(stream) => return Ok(stream),
            Err(error) if not_running(&error) => {}
            Err(error) => return Err(format!("cannot connect to {}: {error}", path.display())),
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "{} did not appear within {} seconds",
                path.display(),
                LAUNCH_TIMEOUT.as_secs()
            ));
        }
        thread::sleep(RETRY_INTERVAL);
    }
}

/// Copies stdin to the socket and the socket to stdout until either side
/// closes. Returns why it stopped; never returns on a clean stdin close
/// because the process exits then.
fn pipe(stream: UnixStream) -> io::Error {
    let to_socket = match stream.try_clone() {
        Ok(clone) => clone,
        Err(error) => return error,
    };
    let spawned = thread::Builder::new()
        .name("stdin-to-socket".into())
        .spawn(move || match copy(io::stdin().lock(), to_socket) {
            Ok(()) => std::process::exit(0),
            Err(error) => {
                eprintln!("bamboo-mcp: {error}");
                std::process::exit(1)
            }
        });
    if let Err(error) = spawned {
        return error;
    }
    match copy(stream, io::stdout().lock()) {
        Ok(()) => io::Error::new(io::ErrorKind::UnexpectedEof, "Bamboo closed the connection"),
        Err(error) => error,
    }
}

/// Copies until `from` reaches end of file, flushing after every chunk so
/// messages are never held back.
fn copy(mut from: impl Read, mut to: impl Write) -> io::Result<()> {
    let mut buffer = [0u8; 64 * 1024];
    loop {
        let read = match from.read(&mut buffer) {
            Ok(0) => return Ok(()),
            Ok(read) => read,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => return Err(error),
        };
        to.write_all(&buffer[..read])?;
        to.flush()?;
    }
}

/// Lets an MCP client see why there is no server: answers its `initialize`
/// request with an error, and always reports on stderr.
fn explain(message: &str) {
    let mut line = String::new();
    // Unreadable or missing input just means there is no request to answer.
    if io::stdin().lock().read_line(&mut line).is_ok()
        && let Some(id) = initialize_id(&line)
    {
        let _ = writeln!(
            io::stdout(),
            r#"{{"jsonrpc":"2.0","id":{id},"error":{{"code":-32000,"message":{}}}}}"#,
            json_string(message)
        );
    }
    eprintln!("bamboo-mcp: {message}");
}

/// The raw JSON `id` of an `initialize` request line.
fn initialize_id(line: &str) -> Option<&str> {
    if !line.trim_end().ends_with('}') || top_level_value(line, "method")? != r#""initialize""# {
        return None;
    }
    let id = top_level_value(line, "id")?;
    let is_string = id.starts_with('"');
    let is_number = id
        .bytes()
        .all(|byte| byte.is_ascii_digit() || b"+-.eE".contains(&byte));
    (is_string || is_number).then_some(id)
}

/// The raw text of `key`'s value in a one-line JSON object, without
/// interpreting anything below the top level.
fn top_level_value<'a>(line: &'a str, key: &str) -> Option<&'a str> {
    let bytes = line.as_bytes();
    let mut at = skip_whitespace(bytes, 0);
    if bytes.get(at) != Some(&b'{') {
        return None;
    }
    at += 1;
    loop {
        at = skip_whitespace(bytes, at);
        if bytes.get(at) != Some(&b'"') {
            return None;
        }
        let key_end = skip_value(bytes, at)?;
        let matches = &line[at + 1..key_end - 1] == key;
        at = skip_whitespace(bytes, key_end);
        if bytes.get(at) != Some(&b':') {
            return None;
        }
        let start = skip_whitespace(bytes, at + 1);
        let end = skip_value(bytes, start)?;
        if matches {
            return Some(&line[start..end]);
        }
        at = skip_whitespace(bytes, end);
        if bytes.get(at) != Some(&b',') {
            return None;
        }
        at += 1;
    }
}

fn skip_whitespace(bytes: &[u8], mut at: usize) -> usize {
    while bytes.get(at).is_some_and(u8::is_ascii_whitespace) {
        at += 1;
    }
    at
}

/// Index just past the JSON value starting at `start`.
fn skip_value(bytes: &[u8], start: usize) -> Option<usize> {
    match *bytes.get(start)? {
        b'"' => {
            let mut at = start + 1;
            while let Some(&byte) = bytes.get(at) {
                match byte {
                    b'\\' => at += 2,
                    b'"' => return Some(at + 1),
                    _ => at += 1,
                }
            }
            None
        }
        b'{' | b'[' => {
            let mut depth = 0usize;
            let mut at = start;
            while let Some(&byte) = bytes.get(at) {
                match byte {
                    b'"' => {
                        at = skip_value(bytes, at)?;
                        continue;
                    }
                    b'{' | b'[' => depth += 1,
                    b'}' | b']' => {
                        depth -= 1;
                        if depth == 0 {
                            return Some(at + 1);
                        }
                    }
                    _ => {}
                }
                at += 1;
            }
            None
        }
        _ => {
            let length = bytes[start..]
                .iter()
                .position(|byte| matches!(byte, b',' | b'}' | b']') || byte.is_ascii_whitespace())
                .unwrap_or(bytes.len() - start);
            (length > 0).then_some(start + length)
        }
    }
}

fn json_string(text: &str) -> String {
    let mut quoted = String::from('"');
    for character in text.chars() {
        match character {
            '"' => quoted.push_str("\\\""),
            '\\' => quoted.push_str("\\\\"),
            control if control.is_control() => {
                quoted.push_str(&format!("\\u{:04x}", u32::from(control)));
            }
            other => quoted.push(other),
        }
    }
    quoted.push('"');
    quoted
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_id_of_an_initialize_request() {
        let line = r#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"x","id":9}}}"#;
        assert_eq!(initialize_id(line), Some("0"));
        let line = r#" { "method" : "initialize" , "id" : "abc-1" , "params" : { "a": [1, "}", {"b": "\""}] } } "#;
        assert_eq!(initialize_id(line), Some(r#""abc-1""#));
    }

    #[test]
    fn ignores_everything_else() {
        assert_eq!(
            initialize_id(r#"{"jsonrpc":"2.0","method":"initialize"}"#),
            None
        );
        assert_eq!(
            initialize_id(r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#),
            None
        );
        assert_eq!(initialize_id(r#"{"method":"initialize","id":null}"#), None);
        assert_eq!(
            initialize_id(r#"{"method":"initialize","id":{"a":1}}"#),
            None
        );
        assert_eq!(
            initialize_id(r#"{"method":"initialize","params":{"id":3}}"#),
            None
        );
        assert_eq!(initialize_id("[1,2]"), None);
        assert_eq!(initialize_id("not json"), None);
        assert_eq!(initialize_id(""), None);
        assert_eq!(initialize_id(r#"{"method":"initialize","id":1"#), None);
    }

    #[test]
    fn escapes_messages() {
        assert_eq!(json_string("a \"b\"\\\n"), r#""a \"b\"\\\u000a""#);
    }
}
