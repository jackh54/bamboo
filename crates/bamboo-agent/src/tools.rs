//! The browser tool registry and the argument validator that goes with it.
//!
//! The validator implements exactly the JSON Schema keywords the registry
//! uses: `type` (object, array, string, boolean, integer, number), `enum`,
//! `minimum`, `maximum`, `minItems`, `items`, `properties`, `required`,
//! `additionalProperties: false`, `default`, and `anyOf` made only of
//! `required` alternatives.

use std::sync::OnceLock;

use serde_json::{Map, Value, json};

use crate::AgentError;

pub(crate) struct Tool {
    pub name: &'static str,
    pub title: &'static str,
    pub description: &'static str,
    pub read_only: bool,
    pub schema: Value,
}

impl Tool {
    /// MCP tool annotations.
    pub fn annotations(&self) -> Value {
        let destructive = !self.read_only
            && matches!(
                self.name,
                "tab_close"
                    | "click"
                    | "type_text"
                    | "fill_form"
                    | "select_option"
                    | "press_key"
                    | "dialog_respond"
                    | "evaluate"
            );
        // Tools that only touch Bamboo's own state never reach out to a site.
        let open_world = !matches!(
            self.name,
            "tabs_list" | "tab_select" | "tab_close" | "history_search" | "bookmarks_search"
        );
        json!({
            "readOnlyHint": self.read_only,
            "destructiveHint": destructive,
            "openWorldHint": open_world,
        })
    }
}

pub(crate) fn registry() -> &'static [Tool] {
    static TOOLS: OnceLock<Vec<Tool>> = OnceLock::new();
    TOOLS.get_or_init(build_registry)
}

fn object(properties: Value, required: &[&str]) -> Value {
    json!({
        "type": "object",
        "properties": properties,
        "required": required,
        "additionalProperties": false,
    })
}

fn tab_id() -> Value {
    json!({
        "type": "string",
        "description": "Tab to act on, as returned by tabs_list or tab_open. Omit to use your current tab (the one you most recently opened or selected).",
    })
}

fn element_ref() -> Value {
    json!({
        "type": "string",
        "description": "Element reference from the most recent snapshot of this tab, for example \"e12\" for a line marked [ref=e12]. Refs go stale when the page changes; take a new snapshot if an action reports an unknown ref.",
    })
}

fn search_properties(what: &str) -> Value {
    json!({
        "query": {"type": "string", "description": format!("Text to look for in the {what} title or URL.")},
        "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 20, "description": "Maximum number of results."},
    })
}

fn build_registry() -> Vec<Tool> {
    vec![
        Tool {
            name: "tabs_list",
            title: "List tabs",
            description: "List the browser tabs you can control. Returns each tab's id, title, url, whether it is the active tab the user is looking at, and whether it is still loading. Use it to find a tab_id or to check what is open. You only see tabs you opened or that the user handed over to agents.",
            read_only: true,
            schema: object(json!({}), &[]),
        },
        Tool {
            name: "tab_open",
            title: "Open a tab",
            description: "Open a new tab, optionally loading a URL, and make it your current tab. By default the tab opens in the background so the user's own tab stays in front; set focus to true only when the user should see it now. Returns the new tab's id. Use this instead of navigate when you want to keep the existing tab as it is.",
            read_only: false,
            schema: object(
                json!({
                    "url": {"type": "string", "description": "Address to load, for example \"https://example.com\". Omit for a blank tab."},
                    "focus": {"type": "boolean", "default": false, "description": "Bring the new tab to the front of the user's window."},
                }),
                &[],
            ),
        },
        Tool {
            name: "tab_select",
            title: "Select a tab",
            description: "Make a tab your current tab and show it to the user. Later tools that omit tab_id act on it. Use it to switch between tabs you opened; it also changes which tab the user sees, so avoid it when you can pass tab_id instead.",
            read_only: false,
            schema: object(
                json!({"tab_id": {"type": "string", "description": "Tab to select, as returned by tabs_list or tab_open."}}),
                &["tab_id"],
            ),
        },
        Tool {
            name: "tab_close",
            title: "Close a tab",
            description: "Close a tab. Use it to clean up tabs you opened once you are done with them. Unsaved page state, such as a half-filled form, is lost.",
            read_only: false,
            schema: object(
                json!({"tab_id": {"type": "string", "description": "Tab to close, as returned by tabs_list or tab_open."}}),
                &["tab_id"],
            ),
        },
        Tool {
            name: "navigate",
            title: "Go to a URL",
            description: "Load a URL in a tab and wait for the page to finish loading. Use it to visit a page in an existing tab. Take a snapshot afterwards, because all earlier element refs are invalid on the new page. Returns the final URL and title.",
            read_only: false,
            schema: object(
                json!({
                    "url": {"type": "string", "description": "Address to load, for example \"https://example.com\"."},
                    "tab_id": tab_id(),
                }),
                &["url"],
            ),
        },
        Tool {
            name: "go_back",
            title: "Go back",
            description: "Go back one step in the tab's history, like the browser's Back button. Take a snapshot afterwards; earlier refs are invalid. Errors if there is no earlier page.",
            read_only: false,
            schema: object(json!({"tab_id": tab_id()}), &[]),
        },
        Tool {
            name: "go_forward",
            title: "Go forward",
            description: "Go forward one step in the tab's history, like the browser's Forward button. Take a snapshot afterwards; earlier refs are invalid. Errors if there is no later page.",
            read_only: false,
            schema: object(json!({"tab_id": tab_id()}), &[]),
        },
        Tool {
            name: "reload",
            title: "Reload",
            description: "Reload the tab's current page. Use it when a page looks stale or failed to load. Take a snapshot afterwards; earlier refs are invalid.",
            read_only: false,
            schema: object(json!({"tab_id": tab_id()}), &[]),
        },
        Tool {
            name: "snapshot",
            title: "Snapshot the page",
            description: "Return an accessibility-style outline of the page: headings, links, buttons, form fields and text, each interactive element marked with a ref such as [ref=e12]. This is the preferred way to see a page before acting on it; pass the refs to click, type_text, fill_form, select_option, hover and scroll. Much cheaper than a screenshot. Take a new snapshot after anything that changes the page.",
            read_only: true,
            schema: object(json!({"tab_id": tab_id()}), &[]),
        },
        Tool {
            name: "click",
            title: "Click an element",
            description: "Click an element by its ref from the latest snapshot. Use it for links, buttons, checkboxes and other clickable things. Pages often change after a click, so take a new snapshot before the next action.",
            read_only: false,
            schema: object(
                json!({
                    "ref": element_ref(),
                    "tab_id": tab_id(),
                    "button": {"type": "string", "enum": ["left", "right", "middle"], "default": "left", "description": "Mouse button to click with."},
                    "double_click": {"type": "boolean", "default": false, "description": "Double-click instead of a single click."},
                }),
                &["ref"],
            ),
        },
        Tool {
            name: "type_text",
            title: "Type text",
            description: "Type text into an input, textarea or editable element. By default the field is cleared first and nothing is submitted. Use fill_form instead when filling several fields at once.",
            read_only: false,
            schema: object(
                json!({
                    "ref": element_ref(),
                    "text": {"type": "string", "description": "Text to type."},
                    "tab_id": tab_id(),
                    "submit": {"type": "boolean", "default": false, "description": "Press Enter after typing, for example to submit a search box."},
                    "clear": {"type": "boolean", "default": true, "description": "Replace the existing content. Set to false to append to it."},
                }),
                &["ref", "text"],
            ),
        },
        Tool {
            name: "fill_form",
            title: "Fill form fields",
            description: "Set several form fields in one call. Works on text inputs and textareas (the value is the text), checkboxes (\"true\" or \"false\") and selects (the option label or value). Does not submit the form; click the submit button afterwards.",
            read_only: false,
            schema: object(
                json!({
                    "fields": {
                        "type": "array",
                        "minItems": 1,
                        "description": "Fields to set, in order.",
                        "items": object(
                            json!({
                                "ref": element_ref(),
                                "value": {"type": "string", "description": "Text, \"true\" or \"false\" for a checkbox, or the option label or value for a select."},
                            }),
                            &["ref", "value"],
                        ),
                    },
                    "tab_id": tab_id(),
                }),
                &["fields"],
            ),
        },
        Tool {
            name: "select_option",
            title: "Select dropdown option",
            description: "Choose one or more options in a select element by label or value. Pass several values only for a multiple-select. Use it for a single dropdown; fill_form handles dropdowns together with other fields.",
            read_only: false,
            schema: object(
                json!({
                    "ref": element_ref(),
                    "values": {
                        "type": "array",
                        "minItems": 1,
                        "items": {"type": "string"},
                        "description": "Option labels or values to select.",
                    },
                    "tab_id": tab_id(),
                }),
                &["ref", "values"],
            ),
        },
        Tool {
            name: "hover",
            title: "Hover over an element",
            description: "Move the pointer over an element by ref. Use it to open hover menus and tooltips; take a snapshot afterwards to see what appeared.",
            read_only: false,
            schema: object(json!({"ref": element_ref(), "tab_id": tab_id()}), &["ref"]),
        },
        Tool {
            name: "press_key",
            title: "Press a key",
            description: "Press a keyboard key on the focused element, optionally with modifiers held. Use it for Enter, Escape, Tab, arrow keys and shortcuts. Click or type into an element first if it needs focus.",
            read_only: false,
            schema: object(
                json!({
                    "key": {"type": "string", "description": "Key name such as \"Enter\", \"Escape\", \"Tab\", \"ArrowDown\", or a single character such as \"a\"."},
                    "tab_id": tab_id(),
                    "modifiers": {
                        "type": "array",
                        "items": {"type": "string", "enum": ["Shift", "Control", "Alt", "Meta"]},
                        "description": "Modifier keys to hold while pressing the key. Meta is Command.",
                    },
                }),
                &["key"],
            ),
        },
        Tool {
            name: "scroll",
            title: "Scroll the page",
            description: "Scroll the page by a number of pixels, or scroll a specific element into view by ref. Use it to reach content below the fold or to trigger lazy loading; take a new snapshot afterwards if new content should have appeared.",
            read_only: false,
            schema: object(
                json!({
                    "tab_id": tab_id(),
                    "direction": {"type": "string", "enum": ["up", "down", "left", "right"], "default": "down", "description": "Direction to scroll."},
                    "amount": {"type": "integer", "minimum": 1, "maximum": 10000, "default": 600, "description": "Distance in pixels."},
                    "ref": {"type": "string", "description": "Scroll this element into view instead of scrolling by amount. Element reference from the most recent snapshot."},
                }),
                &[],
            ),
        },
        Tool {
            name: "screenshot",
            title: "Take a screenshot",
            description: "Capture the tab as a PNG image. Use it when layout, images, charts or colors matter; prefer snapshot or read_page for text. By default only the visible area is captured.",
            read_only: true,
            schema: object(
                json!({
                    "tab_id": tab_id(),
                    "full_page": {"type": "boolean", "default": false, "description": "Capture the whole scrollable page instead of the visible area."},
                }),
                &[],
            ),
        },
        Tool {
            name: "read_page",
            title: "Read the page",
            description: "Return the page's main content as Markdown, with its title and URL, leaving out navigation, ads and other chrome. Use it to read articles, documentation and search results. It carries no refs; use snapshot when you need to interact.",
            read_only: true,
            schema: object(json!({"tab_id": tab_id()}), &[]),
        },
        Tool {
            name: "wait_for",
            title: "Wait for the page",
            description: "Wait until text appears on the page, until text disappears, or for a number of seconds. Provide at least one of text, text_gone or seconds. Use it after actions that load content asynchronously. Errors if the condition is not met in time.",
            read_only: true,
            schema: {
                let mut schema = object(
                    json!({
                        "tab_id": tab_id(),
                        "text": {"type": "string", "description": "Wait until this text is visible on the page."},
                        "text_gone": {"type": "string", "description": "Wait until this text is no longer on the page."},
                        "seconds": {"type": "number", "minimum": 0, "maximum": 30, "description": "Seconds to wait; also the time limit when combined with text or text_gone."},
                    }),
                    &[],
                );
                schema["anyOf"] = json!([
                    {"required": ["text"]},
                    {"required": ["text_gone"]},
                    {"required": ["seconds"]},
                ]);
                schema
            },
        },
        Tool {
            name: "dialog_respond",
            title: "Answer a dialog",
            description: "Answer a pending JavaScript alert, confirm or prompt dialog in the tab. Pages are blocked until their dialog is answered, so use it when a tool reports that a dialog is open. Accept to press OK, or set accept to false to cancel.",
            read_only: false,
            schema: object(
                json!({
                    "tab_id": tab_id(),
                    "accept": {"type": "boolean", "description": "true to accept (OK), false to dismiss (Cancel)."},
                    "text": {"type": "string", "description": "Text to enter for a prompt dialog."},
                }),
                &["accept"],
            ),
        },
        Tool {
            name: "evaluate",
            title: "Run JavaScript",
            description: "Run a JavaScript expression in the page and return its JSON-serialized result. Use it only when snapshot, read_page and the interaction tools cannot do the job. It runs with the page's own privileges and can change the page. The user can turn this tool off in Settings.",
            read_only: false,
            schema: object(
                json!({
                    "expression": {"type": "string", "description": "JavaScript expression to evaluate, for example \"document.title\"."},
                    "tab_id": tab_id(),
                }),
                &["expression"],
            ),
        },
        Tool {
            name: "history_search",
            title: "Search history",
            description: "Search the user's browsing history by title or URL and return matching pages with their visit times, newest first. Use it to find a page the user visited before. The user can turn this tool off in Settings.",
            read_only: true,
            schema: object(search_properties("page"), &["query"]),
        },
        Tool {
            name: "bookmarks_search",
            title: "Search bookmarks",
            description: "Search the user's bookmarks by title or URL and return matching bookmarks. Use it to find a page the user saved. The user can turn this tool off in Settings.",
            read_only: true,
            schema: object(search_properties("bookmark"), &["query"]),
        },
    ]
}

/// Checks `arguments` against the tool's schema and returns them with
/// defaults filled in.
pub(crate) fn validate(name: &str, arguments: &Value) -> Result<Value, AgentError> {
    let tool = registry()
        .iter()
        .find(|tool| tool.name == name)
        .ok_or_else(|| AgentError::UnknownTool {
            name: name.to_owned(),
        })?;
    normalize(&tool.schema, arguments, "arguments").map_err(|message| {
        AgentError::InvalidArguments {
            message: format!("{name}: {message}"),
        }
    })
}

fn normalize(schema: &Value, value: &Value, path: &str) -> Result<Value, String> {
    match schema["type"].as_str() {
        Some("object") => normalize_object(schema, value, path),
        Some("array") => normalize_array(schema, value, path),
        Some("string") => {
            if !value.is_string() {
                return Err(type_error("string", value, path));
            }
            check_enum(schema, value, path)?;
            Ok(value.clone())
        }
        Some("boolean") => {
            if !value.is_boolean() {
                return Err(type_error("boolean", value, path));
            }
            Ok(value.clone())
        }
        Some("integer") => {
            let number = value
                .as_i64()
                .ok_or_else(|| type_error("integer", value, path))?;
            check_range(schema, number as f64, path)?;
            Ok(value.clone())
        }
        Some("number") => {
            let number = value
                .as_f64()
                .ok_or_else(|| type_error("number", value, path))?;
            check_range(schema, number, path)?;
            Ok(value.clone())
        }
        other => Err(format!(
            "{path}: the tool schema uses an unsupported type {other:?}"
        )),
    }
}

fn normalize_object(schema: &Value, value: &Value, path: &str) -> Result<Value, String> {
    let object = value
        .as_object()
        .ok_or_else(|| type_error("object", value, path))?;
    let properties = schema["properties"]
        .as_object()
        .ok_or_else(|| format!("{path}: the tool schema has an object without properties"))?;

    if let Some(unknown) = object.keys().find(|key| !properties.contains_key(*key)) {
        let allowed: Vec<&str> = properties.keys().map(String::as_str).collect();
        return Err(format!(
            "{path}: unknown property \"{unknown}\"; allowed properties are {}",
            allowed.join(", ")
        ));
    }
    if let Some(missing) = first_missing(schema, object) {
        return Err(format!("{path}: missing required property \"{missing}\""));
    }
    if let Some(alternatives) = schema["anyOf"].as_array()
        && !alternatives
            .iter()
            .any(|alternative| first_missing(alternative, object).is_none())
    {
        let names: Vec<&str> = alternatives
            .iter()
            .filter_map(|alternative| alternative["required"][0].as_str())
            .collect();
        return Err(format!(
            "{path}: provide at least one of {}",
            names.join(", ")
        ));
    }

    let mut normalized = Map::new();
    for (key, property_schema) in properties {
        match object.get(key) {
            Some(property) => {
                let property = normalize(property_schema, property, &format!("{path}.{key}"))?;
                normalized.insert(key.clone(), property);
            }
            None => {
                if let Some(default) = property_schema.get("default") {
                    normalized.insert(key.clone(), default.clone());
                }
            }
        }
    }
    Ok(Value::Object(normalized))
}

fn normalize_array(schema: &Value, value: &Value, path: &str) -> Result<Value, String> {
    let items = value
        .as_array()
        .ok_or_else(|| type_error("array", value, path))?;
    if let Some(min) = schema["minItems"].as_u64()
        && (items.len() as u64) < min
    {
        return Err(format!(
            "{path}: needs at least {min} item(s), got {}",
            items.len()
        ));
    }
    items
        .iter()
        .enumerate()
        .map(|(index, item)| normalize(&schema["items"], item, &format!("{path}[{index}]")))
        .collect::<Result<Vec<_>, _>>()
        .map(Value::Array)
}

/// First name in the schema's `required` list that `object` lacks.
fn first_missing<'a>(schema: &'a Value, object: &Map<String, Value>) -> Option<&'a str> {
    schema["required"]
        .as_array()?
        .iter()
        .filter_map(Value::as_str)
        .find(|name| !object.contains_key(*name))
}

fn type_error(wanted: &str, value: &Value, path: &str) -> String {
    let got = match value {
        Value::Null => "null (omit the property instead)",
        Value::Bool(_) => "boolean",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    };
    format!("{path}: expected {wanted}, got {got}")
}

fn check_enum(schema: &Value, value: &Value, path: &str) -> Result<(), String> {
    let Some(allowed) = schema["enum"].as_array() else {
        return Ok(());
    };
    if allowed.contains(value) {
        return Ok(());
    }
    let allowed: Vec<String> = allowed.iter().map(Value::to_string).collect();
    Err(format!(
        "{path}: must be one of {}, got {value}",
        allowed.join(", ")
    ))
}

fn check_range(schema: &Value, number: f64, path: &str) -> Result<(), String> {
    match (schema["minimum"].as_f64(), schema["maximum"].as_f64()) {
        (Some(min), Some(max)) if number < min || number > max => Err(format!(
            "{path}: must be between {min} and {max}, got {number}"
        )),
        (Some(min), _) if number < min => {
            Err(format!("{path}: must be at least {min}, got {number}"))
        }
        (_, Some(max)) if number > max => {
            Err(format!("{path}: must be at most {max}, got {number}"))
        }
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn check(name: &str, arguments: Value) -> Result<Value, String> {
        validate(name, &arguments).map_err(|error| match error {
            AgentError::InvalidArguments { message } => message,
            other => panic!("unexpected error {other:?}"),
        })
    }

    #[test]
    fn names_are_unique_and_schemas_are_closed_objects() {
        let mut names: Vec<&str> = registry().iter().map(|tool| tool.name).collect();
        let count = names.len();
        names.sort_unstable();
        names.dedup();
        assert_eq!(names.len(), count);
        assert_eq!(count, 23);
        for tool in registry() {
            assert_eq!(tool.schema["type"], "object", "{}", tool.name);
            assert_eq!(tool.schema["additionalProperties"], false, "{}", tool.name);
            assert!(!tool.description.is_empty() && !tool.title.is_empty());
        }
    }

    #[test]
    fn every_schema_uses_only_supported_keywords() {
        fn walk(schema: &Value, tool: &str) {
            let Some(schema) = schema.as_object() else {
                panic!("{tool}: schema node is not an object");
            };
            for key in schema.keys() {
                assert!(
                    [
                        "type",
                        "description",
                        "enum",
                        "minimum",
                        "maximum",
                        "minItems",
                        "items",
                        "properties",
                        "required",
                        "additionalProperties",
                        "default",
                        "anyOf",
                    ]
                    .contains(&key.as_str()),
                    "{tool}: unsupported keyword {key}"
                );
            }
            if let Some(properties) = schema.get("properties").and_then(Value::as_object) {
                properties
                    .values()
                    .for_each(|property| walk(property, tool));
            }
            if let Some(items) = schema.get("items") {
                walk(items, tool);
            }
        }
        for tool in registry() {
            walk(&tool.schema, tool.name);
        }
    }

    #[test]
    fn defaults_are_filled_in() {
        assert_eq!(
            check("click", json!({"ref": "e1"})).unwrap(),
            json!({"ref": "e1", "button": "left", "double_click": false})
        );
        assert_eq!(
            check("scroll", json!({})).unwrap(),
            json!({"direction": "down", "amount": 600})
        );
        assert_eq!(
            check("type_text", json!({"ref": "e2", "text": "hi"})).unwrap(),
            json!({"ref": "e2", "text": "hi", "submit": false, "clear": true})
        );
        assert_eq!(
            check("history_search", json!({"query": "rust"})).unwrap(),
            json!({"query": "rust", "limit": 20})
        );
        assert_eq!(
            check("tab_open", json!({})).unwrap(),
            json!({"focus": false})
        );
    }

    #[test]
    fn explicit_values_win_over_defaults() {
        assert_eq!(
            check(
                "click",
                json!({"ref": "e1", "button": "right", "double_click": true, "tab_id": "t1"})
            )
            .unwrap(),
            json!({"ref": "e1", "tab_id": "t1", "button": "right", "double_click": true})
        );
    }

    #[test]
    fn unknown_tool() {
        assert!(matches!(
            validate("rm_rf", &json!({})),
            Err(AgentError::UnknownTool { name }) if name == "rm_rf"
        ));
    }

    #[test]
    fn missing_required_property() {
        let message = check("click", json!({})).unwrap_err();
        assert_eq!(
            message,
            "click: arguments: missing required property \"ref\""
        );
    }

    #[test]
    fn unknown_property_lists_the_allowed_ones() {
        let message = check("navigate", json!({"url": "https://a.test", "link": 1})).unwrap_err();
        assert!(message.contains("unknown property \"link\""), "{message}");
        assert!(message.contains("url, tab_id"), "{message}");
    }

    #[test]
    fn wrong_types() {
        let message = check("navigate", json!({"url": 5})).unwrap_err();
        assert_eq!(
            message,
            "navigate: arguments.url: expected string, got number"
        );
        let message = check("tab_open", json!({"focus": "yes"})).unwrap_err();
        assert!(
            message.contains("expected boolean, got string"),
            "{message}"
        );
        let message = check("navigate", json!({"url": "x", "tab_id": null})).unwrap_err();
        assert!(message.contains("got null"), "{message}");
        let message = check("scroll", json!({"amount": 1.5})).unwrap_err();
        assert!(message.contains("expected integer"), "{message}");
        let message = check("tabs_list", json!([])).unwrap_err();
        assert!(message.contains("expected object, got array"), "{message}");
    }

    #[test]
    fn enums() {
        let message = check("click", json!({"ref": "e1", "button": "back"})).unwrap_err();
        assert!(
            message.contains("must be one of \"left\", \"right\", \"middle\""),
            "{message}"
        );
        let message = check("press_key", json!({"key": "a", "modifiers": ["Super"]})).unwrap_err();
        assert!(message.contains("arguments.modifiers[0]"), "{message}");
        assert!(
            check(
                "press_key",
                json!({"key": "a", "modifiers": ["Meta", "Shift"]})
            )
            .is_ok()
        );
    }

    #[test]
    fn integer_bounds() {
        assert!(check("scroll", json!({"amount": 1})).is_ok());
        assert!(check("scroll", json!({"amount": 10000})).is_ok());
        let message = check("scroll", json!({"amount": 0})).unwrap_err();
        assert!(message.contains("between 1 and 10000"), "{message}");
        let message = check("scroll", json!({"amount": 10001})).unwrap_err();
        assert!(message.contains("between 1 and 10000"), "{message}");
        assert!(check("bookmarks_search", json!({"query": "a", "limit": 101})).is_err());
        assert!(check("bookmarks_search", json!({"query": "a", "limit": 100})).is_ok());
        assert!(check("scroll", json!({"amount": u64::MAX})).is_err());
    }

    #[test]
    fn one_sided_bounds() {
        let schema = json!({"minimum": 2});
        assert!(check_range(&schema, 2.0, "n").is_ok());
        assert!(
            check_range(&schema, 1.0, "n")
                .unwrap_err()
                .contains("at least 2")
        );
        let schema = json!({"maximum": 2});
        assert!(
            check_range(&schema, 3.0, "n")
                .unwrap_err()
                .contains("at most 2")
        );
    }

    #[test]
    fn number_bounds() {
        assert!(check("wait_for", json!({"seconds": 0})).is_ok());
        assert!(check("wait_for", json!({"seconds": 2.5})).is_ok());
        assert!(check("wait_for", json!({"seconds": 30})).is_ok());
        assert!(check("wait_for", json!({"seconds": 30.5})).is_err());
        assert!(check("wait_for", json!({"seconds": -1})).is_err());
    }

    #[test]
    fn wait_for_needs_a_condition() {
        let message = check("wait_for", json!({"tab_id": "t1"})).unwrap_err();
        assert_eq!(
            message,
            "wait_for: arguments: provide at least one of text, text_gone, seconds"
        );
        assert!(check("wait_for", json!({"text": "Done"})).is_ok());
        assert!(check("wait_for", json!({"text_gone": "Loading"})).is_ok());
    }

    #[test]
    fn arrays_of_objects() {
        let ok = check(
            "fill_form",
            json!({"fields": [{"ref": "e1", "value": "a"}, {"ref": "e2", "value": "true"}]}),
        );
        assert!(ok.is_ok());
        let message = check("fill_form", json!({"fields": []})).unwrap_err();
        assert!(message.contains("at least 1 item"), "{message}");
        let message = check(
            "fill_form",
            json!({"fields": [{"ref": "e1", "value": "a"}, {"ref": "e2"}]}),
        )
        .unwrap_err();
        assert!(
            message.contains("arguments.fields[1]: missing required property \"value\""),
            "{message}"
        );
        let message = check(
            "fill_form",
            json!({"fields": [{"ref": "e1", "value": "a", "extra": 1}]}),
        )
        .unwrap_err();
        assert!(message.contains("unknown property \"extra\""), "{message}");
        assert!(check("select_option", json!({"ref": "e1", "values": []})).is_err());
        assert!(check("select_option", json!({"ref": "e1", "values": [1]})).is_err());
    }

    #[test]
    fn annotations_describe_the_tool() {
        let find = |name: &str| registry().iter().find(|tool| tool.name == name).unwrap();
        let snapshot = find("snapshot").annotations();
        assert_eq!(snapshot["readOnlyHint"], true);
        assert_eq!(snapshot["destructiveHint"], false);
        let evaluate = find("evaluate").annotations();
        assert_eq!(evaluate["readOnlyHint"], false);
        assert_eq!(evaluate["destructiveHint"], true);
        assert_eq!(find("history_search").annotations()["openWorldHint"], false);
        assert_eq!(find("navigate").annotations()["openWorldHint"], true);
    }
}
