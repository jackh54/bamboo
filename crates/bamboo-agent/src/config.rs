//! Edits to Claude Desktop's `claude_desktop_config.json`.

use std::ffi::OsString;
use std::fs;
use std::io::{self, Write};
use std::path::Path;

use serde_json::{Map, Value, json};

use crate::AgentError;

pub(crate) fn install(
    config_path: &Path,
    server_name: &str,
    command_path: &str,
) -> Result<(), AgentError> {
    let existing = read(config_path)?;
    let existed = existing.is_some();
    let mut root = existing.unwrap_or_default();
    let servers = root
        .entry("mcpServers")
        .or_insert_with(|| Value::Object(Map::new()))
        .as_object_mut()
        .ok_or_else(|| not_an_object(config_path))?;
    servers.insert(
        server_name.to_owned(),
        json!({"command": command_path, "args": []}),
    );
    write(config_path, &root, existed)
}

pub(crate) fn remove(config_path: &Path, server_name: &str) -> Result<(), AgentError> {
    let Some(mut root) = read(config_path)? else {
        return Ok(());
    };
    let Some(servers) = root.get_mut("mcpServers") else {
        return Ok(());
    };
    let servers = servers
        .as_object_mut()
        .ok_or_else(|| not_an_object(config_path))?;
    // shift_remove keeps the remaining servers in their original order.
    if servers.shift_remove(server_name).is_none() {
        return Ok(());
    }
    write(config_path, &root, true)
}

pub(crate) fn installed(config_path: &Path, server_name: &str) -> Result<bool, AgentError> {
    let Some(root) = read(config_path)? else {
        return Ok(false);
    };
    match root.get("mcpServers") {
        None => Ok(false),
        Some(Value::Object(servers)) => Ok(servers.contains_key(server_name)),
        Some(_) => Err(not_an_object(config_path)),
    }
}

/// `None` when the file does not exist.
fn read(path: &Path) -> Result<Option<Map<String, Value>>, AgentError> {
    let text = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(io_error(path, &error)),
    };
    match serde_json::from_str(&text) {
        Ok(Value::Object(root)) => Ok(Some(root)),
        Ok(_) => Err(AgentError::Config {
            message: format!(
                "{} must contain a JSON object; it was left unchanged",
                path.display()
            ),
        }),
        Err(error) => Err(AgentError::Config {
            message: format!(
                "{} is not valid JSON ({error}); it was left unchanged",
                path.display()
            ),
        }),
    }
}

fn write(path: &Path, root: &Map<String, Value>, backup: bool) -> Result<(), AgentError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| io_error(parent, &error))?;
    }
    // A symlinked config (dotfiles) must stay a symlink, so replace what it points to.
    let target = if backup {
        fs::canonicalize(path).map_err(|error| io_error(path, &error))?
    } else {
        path.to_path_buf()
    };
    if backup {
        let mut backup_path = OsString::from(path);
        backup_path.push(".bamboo-backup");
        fs::copy(&target, &backup_path)
            .map_err(|error| io_error(Path::new(&backup_path), &error))?;
    }
    let mut text = serde_json::to_string_pretty(root).map_err(|error| AgentError::Config {
        message: error.to_string(),
    })?;
    text.push('\n');

    // Write beside the target and rename, so a full disk or crash never leaves a truncated config.
    let mut temp_path = OsString::from(&target);
    temp_path.push(".bamboo-tmp");
    let temp_path = Path::new(&temp_path);
    let written = (|| {
        let mut file = fs::File::create(temp_path)?;
        if backup {
            file.set_permissions(fs::metadata(&target)?.permissions())?;
        }
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        fs::rename(temp_path, &target)
    })();
    written.map_err(|error| {
        // Best-effort cleanup; the write error is what matters.
        let _ = fs::remove_file(temp_path);
        io_error(&target, &error)
    })
}

fn not_an_object(path: &Path) -> AgentError {
    AgentError::Config {
        message: format!(
            "\"mcpServers\" in {} is not a JSON object; it was left unchanged",
            path.display()
        ),
    }
}

fn io_error(path: &Path, error: &io::Error) -> AgentError {
    AgentError::Io {
        message: format!("{}: {error}", path.display()),
    }
}
