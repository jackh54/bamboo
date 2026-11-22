//! Agent access to Bamboo.
//!
//! [`AgentServer`] speaks the Model Context Protocol (JSON-RPC 2.0, one
//! message per line) on a Unix domain socket that only the current user can
//! open. The `bamboo-mcp` binary bridges an MCP client's stdio to that socket,
//! so Claude Code, Claude Desktop and other clients launch it as a normal
//! stdio server. Tool calls are forwarded to the app through [`AgentHost`].
//!
//! The same tool registry ([`tool_specs`]) is used by the built-in Claude
//! assistant, so both paths offer identical tools.

use std::path::Path;
use std::sync::Arc;

mod config;
mod server;
mod tools;

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum AgentError {
    #[error("io error: {message}")]
    Io { message: String },
    #[error("unknown tool: {name}")]
    UnknownTool { name: String },
    #[error("invalid arguments: {message}")]
    InvalidArguments { message: String },
    #[error("config error: {message}")]
    Config { message: String },
}

/// A browser tool. `input_schema_json` is a JSON Schema object.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ToolSpec {
    pub name: String,
    pub title: String,
    pub description: String,
    pub input_schema_json: String,
    /// Does not change any page or browser state.
    pub read_only: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ToolContent {
    Text {
        text: String,
    },
    Image {
        data_base64: String,
        mime_type: String,
    },
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ToolOutcome {
    pub content: Vec<ToolContent>,
    pub is_error: bool,
}

/// An MCP client connected through the socket.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct AgentClient {
    pub id: String,
    /// From the client's `initialize` request, e.g. "claude-code".
    pub name: String,
    pub version: String,
    pub connected_at_ms: i64,
}

/// Implemented by the app. Called on server threads, never the main thread;
/// implementations may block while the main thread does the work.
#[uniffi::export(with_foreign)]
pub trait AgentHost: Send + Sync {
    /// Runs a tool whose arguments already passed [`validate_tool_input`].
    fn call_tool(&self, client_id: String, name: String, arguments_json: String) -> ToolOutcome;
    /// Called whenever a client connects, finishes initializing or disconnects.
    fn clients_changed(&self, clients: Vec<AgentClient>);
}

#[derive(uniffi::Object)]
pub struct AgentServer {
    shared: Arc<server::Shared>,
}

#[uniffi::export]
impl AgentServer {
    #[uniffi::constructor]
    pub fn new(socket_path: String, host: Arc<dyn AgentHost>, server_version: String) -> Arc<Self> {
        Arc::new(Self {
            shared: server::Shared::new(socket_path.into(), host, server_version),
        })
    }

    /// Binds the socket (mode 0600, replacing a stale socket file) and starts
    /// accepting clients on a background thread. Errors if already running.
    pub fn start(&self) -> Result<(), AgentError> {
        self.shared.start()
    }

    /// Disconnects all clients and removes the socket file.
    pub fn stop(&self) {
        self.shared.stop();
    }

    pub fn is_running(&self) -> bool {
        self.shared.is_running()
    }

    pub fn clients(&self) -> Vec<AgentClient> {
        self.shared.clients()
    }

    /// Hides tools from `tools/list` and rejects calls to them, then notifies
    /// connected clients with `notifications/tools/list_changed`.
    pub fn set_disabled_tools(&self, names: Vec<String>) {
        self.shared.set_disabled_tools(names);
    }
}

/// Every browser tool, in a stable order.
#[uniffi::export]
pub fn tool_specs() -> Vec<ToolSpec> {
    tools::registry()
        .iter()
        .map(|tool| ToolSpec {
            name: tool.name.to_owned(),
            title: tool.title.to_owned(),
            description: tool.description.to_owned(),
            input_schema_json: tool.schema.to_string(),
            read_only: tool.read_only,
        })
        .collect()
}

/// Validates `arguments_json` against the tool's schema and returns it
/// normalized (defaults filled in).
#[uniffi::export]
pub fn validate_tool_input(name: String, arguments_json: String) -> Result<String, AgentError> {
    let arguments =
        serde_json::from_str(&arguments_json).map_err(|error| AgentError::InvalidArguments {
            message: format!("arguments are not valid JSON: {error}"),
        })?;
    tools::validate(&name, &arguments).map(|arguments| arguments.to_string())
}

/// Adds (or replaces) `server_name` under `mcpServers` in Claude Desktop's
/// `claude_desktop_config.json`, keeping every other key. Creates the file if
/// missing and writes `<config>.bamboo-backup` before changing an existing one.
#[uniffi::export]
pub fn install_claude_desktop_server(
    config_path: String,
    server_name: String,
    command_path: String,
) -> Result<(), AgentError> {
    config::install(Path::new(&config_path), &server_name, &command_path)
}

/// Removes `server_name` from Claude Desktop's config, keeping every other key.
#[uniffi::export]
pub fn remove_claude_desktop_server(
    config_path: String,
    server_name: String,
) -> Result<(), AgentError> {
    config::remove(Path::new(&config_path), &server_name)
}

/// Whether `server_name` is present in Claude Desktop's config.
#[uniffi::export]
pub fn claude_desktop_server_installed(
    config_path: String,
    server_name: String,
) -> Result<bool, AgentError> {
    config::installed(Path::new(&config_path), &server_name)
}
