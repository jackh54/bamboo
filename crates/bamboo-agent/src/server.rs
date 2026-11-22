//! The MCP server: socket listener, connections and JSON-RPC dispatch.
//!
//! Lock order: `Shared::notify` before `Shared::state` before any
//! connection lock. The host is never called while `state` is held.

use std::collections::{BTreeMap, HashSet};
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::unix::fs::{FileTypeExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::panic::{self, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, SyncSender, sync_channel};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::{self, JoinHandle};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Map, Value, json};

use crate::tools::{self, registry};
use crate::{AgentClient, AgentError, AgentHost, ToolContent, ToolOutcome};

/// Newest first.
const PROTOCOL_VERSIONS: [&str; 4] = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"];

const INSTRUCTIONS: &str = "Bamboo is a web browser the user is looking at. Call snapshot first to see a page as an outline with element refs, then act on elements by ref (click, type_text, fill_form, select_option). Use read_page to read articles and documents, and screenshot only when visuals matter. Refs go stale when a page changes, so snapshot again after acting. Tabs you open are outlined for the user, who can watch and take over at any time. Some tools may be disabled by the user in Bamboo's Settings.";

/// Longest accepted line from a client; longer ones close the connection.
const MAX_LINE_BYTES: usize = 8 * 1024 * 1024;

/// How long a client may leave a write unread before it is disconnected.
const WRITE_TIMEOUT: Duration = Duration::from_secs(30);

/// Messages queued for one client; a client that falls this far behind is disconnected.
const OUTGOING_QUEUE_LEN: usize = 64;

const ACCEPT_RETRY_DELAY: Duration = Duration::from_millis(100);

const PARSE_ERROR: i64 = -32700;
const INVALID_REQUEST: i64 = -32600;
const METHOD_NOT_FOUND: i64 = -32601;
const INVALID_PARAMS: i64 = -32602;
const INTERNAL_ERROR: i64 = -32603;

struct RpcError {
    code: i64,
    message: String,
}

fn rpc_error(code: i64, message: impl Into<String>) -> RpcError {
    RpcError {
        code,
        message: message.into(),
    }
}

fn response(id: &Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn error_response(id: &Value, error: &RpcError) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": error.code, "message": error.message}})
}

fn io_error(context: &str, error: &io::Error) -> AgentError {
    AgentError::Io {
        message: format!("{context}: {error}"),
    }
}

/// A poisoned lock only means another thread panicked; the data is still usable.
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn outcome_json(outcome: ToolOutcome) -> Value {
    let content: Vec<Value> = outcome
        .content
        .into_iter()
        .map(|content| match content {
            ToolContent::Text { text } => json!({"type": "text", "text": text}),
            ToolContent::Image {
                data_base64,
                mime_type,
            } => json!({"type": "image", "data": data_base64, "mimeType": mime_type}),
        })
        .collect();
    json!({"content": content, "isError": outcome.is_error})
}

fn error_result(message: &str) -> Value {
    json!({"content": [{"type": "text", "text": message}], "isError": true})
}

pub(crate) struct Shared {
    socket_path: PathBuf,
    host: Arc<dyn AgentHost>,
    version: String,
    state: Mutex<State>,
    /// Serializes `clients_changed` so the host always ends on the latest list.
    notify: Mutex<()>,
}

#[derive(Default)]
struct State {
    running: bool,
    accept: Option<JoinHandle<()>>,
    disabled: HashSet<String>,
    connections: BTreeMap<u64, Arc<Connection>>,
    next_connection: u64,
}

struct Connection {
    seq: u64,
    client_id: String,
    /// Used for reading and to shut the connection down.
    socket: UnixStream,
    /// Feeds the connection's writer thread, so no caller ever blocks on a slow client.
    outgoing: SyncSender<String>,
    client: Mutex<AgentClient>,
    initialized: AtomicBool,
    /// The client sent `notifications/initialized`.
    ready: AtomicBool,
    /// Ids of `tools/call` requests still running; cancelling removes one.
    pending: Mutex<HashSet<String>>,
}

impl Connection {
    fn send(&self, message: &Value) {
        let mut line = message.to_string();
        line.push('\n');
        // A full queue means the client stopped reading, a disconnected one
        // that the writer thread gave up. Closing ends the read loop, which
        // unregisters the client.
        if self.outgoing.try_send(line).is_err() {
            self.close();
        }
    }

    fn close(&self) {
        // Fails only when the socket is already closed, which is the goal.
        let _ = self.socket.shutdown(Shutdown::Both);
    }
}

/// Writes queued messages until the queue closes or the client stops
/// accepting data for `WRITE_TIMEOUT`, then closes the connection.
fn write_loop(mut stream: UnixStream, outgoing: Receiver<String>) {
    for line in outgoing {
        if stream.write_all(line.as_bytes()).is_err() {
            // Fails only when the socket is already closed, which is the goal.
            let _ = stream.shutdown(Shutdown::Both);
            return;
        }
    }
}

enum Frame {
    Eof,
    Line,
    TooLong,
}

fn read_frame(reader: &mut impl BufRead, line: &mut Vec<u8>) -> io::Result<Frame> {
    line.clear();
    let read = reader
        .by_ref()
        .take(MAX_LINE_BYTES as u64 + 1)
        .read_until(b'\n', line)?;
    Ok(if read == 0 {
        Frame::Eof
    } else if line.len() > MAX_LINE_BYTES {
        Frame::TooLong
    } else {
        Frame::Line
    })
}

impl Shared {
    pub(crate) fn new(
        socket_path: PathBuf,
        host: Arc<dyn AgentHost>,
        version: String,
    ) -> Arc<Self> {
        Arc::new(Self {
            socket_path,
            host,
            version,
            state: Mutex::new(State::default()),
            notify: Mutex::new(()),
        })
    }

    pub(crate) fn start(self: &Arc<Self>) -> Result<(), AgentError> {
        let mut state = lock(&self.state);
        if state.running {
            return Err(AgentError::Io {
                message: format!("already running at {}", self.socket_path.display()),
            });
        }
        self.clear_stale_socket()?;
        if let Some(parent) = self.socket_path.parent() {
            fs::create_dir_all(parent)
                .map_err(|error| io_error("create socket directory", &error))?;
        }
        let listener = UnixListener::bind(&self.socket_path)
            .map_err(|error| io_error("bind agent socket", &error))?;
        // Best-effort cleanup: the original error is what matters.
        if let Err(error) =
            fs::set_permissions(&self.socket_path, fs::Permissions::from_mode(0o600))
        {
            let _ = fs::remove_file(&self.socket_path);
            return Err(io_error("restrict agent socket to its owner", &error));
        }
        let shared = Arc::clone(self);
        let accept = thread::Builder::new()
            .name("bamboo-agent-accept".into())
            .spawn(move || shared.accept_loop(&listener));
        match accept {
            Ok(handle) => {
                state.running = true;
                state.accept = Some(handle);
                Ok(())
            }
            Err(error) => {
                let _ = fs::remove_file(&self.socket_path);
                Err(io_error("start accept thread", &error))
            }
        }
    }

    /// Fails if a live server owns the socket path; removes a stale socket file.
    fn clear_stale_socket(&self) -> Result<(), AgentError> {
        let metadata = match fs::symlink_metadata(&self.socket_path) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(io_error("inspect agent socket path", &error)),
        };
        if !metadata.file_type().is_socket() {
            return Err(AgentError::Io {
                message: format!("{} exists and is not a socket", self.socket_path.display()),
            });
        }
        match UnixStream::connect(&self.socket_path) {
            Ok(_) => Err(AgentError::Io {
                message: format!(
                    "already running: another Bamboo is serving {}",
                    self.socket_path.display()
                ),
            }),
            Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => {
                fs::remove_file(&self.socket_path)
                    .map_err(|error| io_error("remove stale agent socket", &error))
            }
            Err(error) => Err(io_error("probe agent socket", &error)),
        }
    }

    pub(crate) fn stop(&self) {
        let (accept, connections) = {
            let mut state = lock(&self.state);
            state.running = false;
            (state.accept.take(), std::mem::take(&mut state.connections))
        };
        if let Some(accept) = accept {
            // accept() blocks, so wake it with a connection; it sees `running`
            // is false, drops the listener and exits. If the socket file was
            // removed behind our back the wake-up fails and the thread is left
            // to exit with the process.
            if UnixStream::connect(&self.socket_path).is_ok() {
                let _ = accept.join();
            }
            // Only remove a socket this server bound.
            let _ = fs::remove_file(&self.socket_path);
        }
        for connection in connections.values() {
            connection.close();
        }
        if !connections.is_empty() {
            self.notify_clients_changed();
        }
    }

    pub(crate) fn is_running(&self) -> bool {
        lock(&self.state).running
    }

    pub(crate) fn clients(&self) -> Vec<AgentClient> {
        lock(&self.state)
            .connections
            .values()
            .map(|connection| lock(&connection.client).clone())
            .collect()
    }

    pub(crate) fn set_disabled_tools(&self, names: Vec<String>) {
        let ready: Vec<Arc<Connection>> = {
            let mut state = lock(&self.state);
            state.disabled = names.into_iter().collect();
            state
                .connections
                .values()
                .filter(|connection| connection.ready.load(Ordering::SeqCst))
                .cloned()
                .collect()
        };
        let notification = json!({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"});
        for connection in ready {
            connection.send(&notification);
        }
    }

    fn notify_clients_changed(&self) {
        let _serialized = lock(&self.notify);
        let clients = self.clients();
        self.host.clients_changed(clients);
    }

    fn accept_loop(self: Arc<Self>, listener: &UnixListener) {
        for incoming in listener.incoming() {
            if !lock(&self.state).running {
                return;
            }
            match incoming {
                Ok(stream) => self.register(stream),
                // Out of file descriptors or buffers is transient: wait for
                // clients to leave instead of ending the server for good.
                Err(_) => thread::sleep(ACCEPT_RETRY_DELAY),
            }
        }
    }

    /// Runs on the accept thread, so it must not call the host.
    fn register(self: &Arc<Self>, stream: UnixStream) {
        let (Ok(writer), Ok(reader)) = (stream.try_clone(), stream.try_clone()) else {
            return;
        };
        if writer.set_write_timeout(Some(WRITE_TIMEOUT)).is_err() {
            return;
        }
        let (outgoing, queue) = sync_channel(OUTGOING_QUEUE_LEN);
        let spawned_writer = thread::Builder::new()
            .name("bamboo-agent-writer".into())
            .spawn(move || write_loop(writer, queue));
        if spawned_writer.is_err() {
            return;
        }
        let connected_at_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|elapsed| elapsed.as_millis() as i64)
            .unwrap_or_default();

        let mut state = lock(&self.state);
        if !state.running {
            return;
        }
        let seq = state.next_connection;
        state.next_connection += 1;
        let client_id = format!("client-{seq}");
        let connection = Arc::new(Connection {
            seq,
            client_id: client_id.clone(),
            socket: stream,
            outgoing,
            client: Mutex::new(AgentClient {
                id: client_id,
                name: String::new(),
                version: String::new(),
                connected_at_ms,
            }),
            initialized: AtomicBool::new(false),
            ready: AtomicBool::new(false),
            pending: Mutex::new(HashSet::new()),
        });
        state.connections.insert(seq, Arc::clone(&connection));

        let shared = Arc::clone(self);
        let served = Arc::clone(&connection);
        let spawned = thread::Builder::new()
            .name(format!("bamboo-agent-client-{seq}"))
            .spawn(move || shared.serve(&served, reader));
        if spawned.is_err() {
            state.connections.remove(&seq);
        }
    }

    fn serve(self: &Arc<Self>, connection: &Arc<Connection>, reader: UnixStream) {
        self.notify_clients_changed();
        let mut reader = BufReader::new(reader);
        let mut line = Vec::new();
        loop {
            match read_frame(&mut reader, &mut line) {
                Ok(Frame::Line) => self.handle_line(connection, &line),
                Ok(Frame::TooLong) => {
                    let error = rpc_error(
                        INVALID_REQUEST,
                        format!("message longer than {MAX_LINE_BYTES} bytes"),
                    );
                    connection.send(&error_response(&Value::Null, &error));
                    break;
                }
                Ok(Frame::Eof) | Err(_) => break,
            }
        }
        connection.close();
        lock(&connection.pending).clear();
        let was_registered = lock(&self.state)
            .connections
            .remove(&connection.seq)
            .is_some();
        if was_registered {
            self.notify_clients_changed();
        }
    }

    fn handle_line(self: &Arc<Self>, connection: &Arc<Connection>, line: &[u8]) {
        if line.trim_ascii().is_empty() {
            return;
        }
        let message: Value = match serde_json::from_slice(line) {
            Ok(message) => message,
            Err(error) => {
                let error = rpc_error(PARSE_ERROR, format!("parse error: {error}"));
                connection.send(&error_response(&Value::Null, &error));
                return;
            }
        };
        let Some(method) = message.get("method").and_then(Value::as_str) else {
            // A response to a request we never sent; nothing to do.
            if message.get("result").is_some() || message.get("error").is_some() {
                return;
            }
            let error = rpc_error(
                INVALID_REQUEST,
                "expected a single JSON-RPC 2.0 request or notification object",
            );
            connection.send(&error_response(&Value::Null, &error));
            return;
        };
        let params = message.get("params");
        match message.get("id") {
            None => self.handle_notification(connection, method, params),
            Some(id) if id.is_string() || id.is_number() => {
                self.handle_request(connection, id, method, params);
            }
            Some(_) => {
                let error = rpc_error(INVALID_REQUEST, "id must be a string or a number");
                connection.send(&error_response(&Value::Null, &error));
            }
        }
    }

    fn handle_notification(&self, connection: &Connection, method: &str, params: Option<&Value>) {
        match method {
            "notifications/initialized" => {
                if connection.initialized.load(Ordering::SeqCst) {
                    connection.ready.store(true, Ordering::SeqCst);
                }
            }
            "notifications/cancelled" => {
                if let Some(request_id) = params.and_then(|params| params.get("requestId")) {
                    lock(&connection.pending).remove(&request_id.to_string());
                }
            }
            _ => {}
        }
    }

    fn handle_request(
        self: &Arc<Self>,
        connection: &Arc<Connection>,
        id: &Value,
        method: &str,
        params: Option<&Value>,
    ) {
        let initialized = connection.initialized.load(Ordering::SeqCst);
        let outcome = match method {
            "initialize" => self.initialize(connection, params).map(Some),
            "ping" => Ok(Some(json!({}))),
            _ if !initialized => Err(rpc_error(
                INVALID_REQUEST,
                format!("send initialize before {method}"),
            )),
            "tools/list" => Ok(Some(self.tools_list())),
            "tools/call" => self.tools_call(connection, id, params),
            _ => Err(rpc_error(
                METHOD_NOT_FOUND,
                format!("method not found: {method}"),
            )),
        };
        match outcome {
            Ok(Some(result)) => connection.send(&response(id, result)),
            // A worker thread answers later.
            Ok(None) => {}
            Err(error) => connection.send(&error_response(id, &error)),
        }
    }

    fn initialize(
        &self,
        connection: &Connection,
        params: Option<&Value>,
    ) -> Result<Value, RpcError> {
        let params = params.and_then(Value::as_object).ok_or_else(|| {
            rpc_error(
                INVALID_PARAMS,
                "initialize needs params with protocolVersion, capabilities and clientInfo",
            )
        })?;
        let requested = params
            .get("protocolVersion")
            .and_then(Value::as_str)
            .ok_or_else(|| rpc_error(INVALID_PARAMS, "protocolVersion must be a string"))?;
        let client_info = params.get("clientInfo").and_then(Value::as_object);
        let name = client_info
            .and_then(|info| info.get("name"))
            .and_then(Value::as_str)
            .ok_or_else(|| rpc_error(INVALID_PARAMS, "clientInfo.name must be a string"))?;
        let version = client_info
            .and_then(|info| info.get("version"))
            .and_then(Value::as_str)
            .unwrap_or_default();

        if connection.initialized.swap(true, Ordering::SeqCst) {
            return Err(rpc_error(INVALID_REQUEST, "already initialized"));
        }
        {
            let mut client = lock(&connection.client);
            client.name = name.to_owned();
            client.version = version.to_owned();
        }
        self.notify_clients_changed();

        let protocol_version = if PROTOCOL_VERSIONS.contains(&requested) {
            requested
        } else {
            PROTOCOL_VERSIONS[0]
        };
        Ok(json!({
            "protocolVersion": protocol_version,
            "capabilities": {"tools": {"listChanged": true}},
            "serverInfo": {"name": "bamboo", "title": "Bamboo Browser", "version": self.version},
            "instructions": INSTRUCTIONS,
        }))
    }

    fn tools_list(&self) -> Value {
        let state = lock(&self.state);
        let tools: Vec<Value> = registry()
            .iter()
            .filter(|tool| !state.disabled.contains(tool.name))
            .map(|tool| {
                json!({
                    "name": tool.name,
                    "title": tool.title,
                    "description": tool.description,
                    "inputSchema": tool.schema,
                    "annotations": tool.annotations(),
                })
            })
            .collect();
        json!({"tools": tools})
    }

    /// `Ok(None)` means a worker thread was started and will send the response.
    fn tools_call(
        self: &Arc<Self>,
        connection: &Arc<Connection>,
        id: &Value,
        params: Option<&Value>,
    ) -> Result<Option<Value>, RpcError> {
        let params = params.and_then(Value::as_object).ok_or_else(|| {
            rpc_error(
                INVALID_PARAMS,
                "tools/call needs params with name and arguments",
            )
        })?;
        let name = params
            .get("name")
            .and_then(Value::as_str)
            .ok_or_else(|| rpc_error(INVALID_PARAMS, "name must be a string"))?;
        let empty = Value::Object(Map::new());
        let arguments = match params.get("arguments") {
            None | Some(Value::Null) => &empty,
            Some(arguments) => arguments,
        };

        let validated = tools::validate(name, arguments);
        if let Err(AgentError::UnknownTool { name }) = &validated {
            return Err(rpc_error(INVALID_PARAMS, format!("unknown tool: {name}")));
        }
        if lock(&self.state).disabled.contains(name) {
            return Ok(Some(error_result(&format!(
                "The user turned off the \"{name}\" tool in Bamboo's Settings. Do not retry it; tell the user if you need it enabled."
            ))));
        }
        let arguments_json = match validated {
            Ok(arguments) => arguments.to_string(),
            Err(error) => return Ok(Some(error_result(&error.to_string()))),
        };

        let key = id.to_string();
        lock(&connection.pending).insert(key.clone());
        let shared = Arc::clone(self);
        let worker_connection = Arc::clone(connection);
        let worker_id = id.clone();
        let name = name.to_owned();
        let spawned = thread::Builder::new()
            .name(format!("bamboo-agent-tool-{name}"))
            .spawn(move || {
                let client_id = worker_connection.client_id.clone();
                let called = panic::catch_unwind(AssertUnwindSafe(|| {
                    shared.host.call_tool(client_id, name, arguments_json)
                }));
                let result = match called {
                    Ok(outcome) => outcome_json(outcome),
                    Err(_) => error_result("Bamboo failed while running this tool."),
                };
                // A cancelled request is no longer pending; its result is dropped.
                if lock(&worker_connection.pending).remove(&key) {
                    worker_connection.send(&response(&worker_id, result));
                }
            });
        if let Err(error) = spawned {
            lock(&connection.pending).remove(&id.to_string());
            return Err(rpc_error(
                INTERNAL_ERROR,
                format!("could not start a worker thread: {error}"),
            ));
        }
        Ok(None)
    }
}
