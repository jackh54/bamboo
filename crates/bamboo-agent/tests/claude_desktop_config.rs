use std::fs;

use bamboo_agent::{
    AgentError, claude_desktop_server_installed, install_claude_desktop_server,
    remove_claude_desktop_server,
};

const COMMAND: &str = "/Applications/Bamboo.app/Contents/MacOS/bamboo-mcp";

fn path_string(path: &std::path::Path) -> String {
    path.to_str().unwrap().to_owned()
}

#[test]
fn creates_the_file_and_parent_directory() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("Claude/claude_desktop_config.json");

    install_claude_desktop_server(path_string(&config), "bamboo".into(), COMMAND.into()).unwrap();

    let written: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&config).unwrap()).unwrap();
    assert_eq!(
        written,
        serde_json::json!({"mcpServers": {"bamboo": {"command": COMMAND, "args": []}}})
    );
    assert!(
        !dir.path()
            .join("Claude/claude_desktop_config.json.bamboo-backup")
            .exists()
    );
}

#[test]
fn merges_keeping_order_unrelated_keys_and_writing_a_backup() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("claude_desktop_config.json");
    let original = r#"{
  "zeta": {"keep": [1, 2, 3]},
  "mcpServers": {
    "other": {"command": "node", "args": ["server.js"]},
    "bamboo": {"command": "/old/path", "args": ["--old"]},
    "last": {"command": "last"}
  },
  "alpha": true
}"#;
    fs::write(&config, original).unwrap();

    install_claude_desktop_server(path_string(&config), "bamboo".into(), COMMAND.into()).unwrap();

    let backup = dir.path().join("claude_desktop_config.json.bamboo-backup");
    assert_eq!(fs::read_to_string(&backup).unwrap(), original);

    let text = fs::read_to_string(&config).unwrap();
    let written: serde_json::Value = serde_json::from_str(&text).unwrap();
    let top: Vec<&String> = written.as_object().unwrap().keys().collect();
    assert_eq!(top, ["zeta", "mcpServers", "alpha"]);
    let servers: Vec<&String> = written["mcpServers"].as_object().unwrap().keys().collect();
    assert_eq!(servers, ["other", "bamboo", "last"]);
    assert_eq!(
        written["mcpServers"]["bamboo"],
        serde_json::json!({"command": COMMAND, "args": []})
    );
    assert_eq!(
        written["mcpServers"]["other"]["args"],
        serde_json::json!(["server.js"])
    );
    assert_eq!(written["zeta"], serde_json::json!({"keep": [1, 2, 3]}));
    assert_eq!(written["alpha"], true);
}

#[test]
fn adds_mcp_servers_when_the_file_has_none() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("claude_desktop_config.json");
    fs::write(&config, r#"{"theme": "dark"}"#).unwrap();

    install_claude_desktop_server(path_string(&config), "bamboo".into(), COMMAND.into()).unwrap();

    let written: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&config).unwrap()).unwrap();
    assert_eq!(written["theme"], "dark");
    assert_eq!(written["mcpServers"]["bamboo"]["command"], COMMAND);
}

#[test]
fn malformed_files_are_reported_and_left_alone() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("claude_desktop_config.json");
    let cases = ["{ \"mcpServers\": ", "", "[1, 2]", r#"{"mcpServers": []}"#];
    for content in cases {
        fs::write(&config, content).unwrap();
        let installed =
            install_claude_desktop_server(path_string(&config), "bamboo".into(), COMMAND.into());
        assert!(
            matches!(installed, Err(AgentError::Config { .. })),
            "{content:?}: {installed:?}"
        );
        let removed = remove_claude_desktop_server(path_string(&config), "bamboo".into());
        assert!(
            matches!(removed, Err(AgentError::Config { .. })),
            "{content:?}: {removed:?}"
        );
        let present = claude_desktop_server_installed(path_string(&config), "bamboo".into());
        assert!(
            matches!(present, Err(AgentError::Config { .. })),
            "{content:?}: {present:?}"
        );
        assert_eq!(fs::read_to_string(&config).unwrap(), content);
        assert!(
            !dir.path()
                .join("claude_desktop_config.json.bamboo-backup")
                .exists()
        );
    }
}

#[test]
fn remove_and_installed() {
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("claude_desktop_config.json");
    let name = || "bamboo".to_owned();

    assert!(!claude_desktop_server_installed(path_string(&config), name()).unwrap());
    remove_claude_desktop_server(path_string(&config), name()).unwrap();
    assert!(!config.exists());

    fs::write(
        &config,
        r#"{"b": 1, "mcpServers": {"x": {"command": "x"}, "bamboo": {"command": "b"}, "y": {"command": "y"}}, "a": 2}"#,
    )
    .unwrap();
    assert!(claude_desktop_server_installed(path_string(&config), name()).unwrap());

    remove_claude_desktop_server(path_string(&config), name()).unwrap();
    assert!(!claude_desktop_server_installed(path_string(&config), name()).unwrap());
    let written: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&config).unwrap()).unwrap();
    let servers: Vec<&String> = written["mcpServers"].as_object().unwrap().keys().collect();
    assert_eq!(servers, ["x", "y"]);
    assert_eq!(written["a"], 2);
    assert!(
        dir.path()
            .join("claude_desktop_config.json.bamboo-backup")
            .exists()
    );

    // Removing something that is not there changes nothing.
    let before = fs::read_to_string(&config).unwrap();
    remove_claude_desktop_server(path_string(&config), name()).unwrap();
    assert_eq!(fs::read_to_string(&config).unwrap(), before);
}
