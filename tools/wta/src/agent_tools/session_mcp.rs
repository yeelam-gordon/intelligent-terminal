use std::future::Future;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

use super::action_proposal::channel::ProposalValidationStatus;
use super::action_proposal::pipe::ProposalValidationResponse;
use crate::agent_tools::user_input::UserInputResponse;

const MCP_PROTOCOL_VERSION: &str = "2025-06-18";
const SUPPORTED_MCP_PROTOCOL_VERSIONS: &[&str] =
    &["2024-11-05", "2025-03-26", MCP_PROTOCOL_VERSION];
const TERMINAL_ACTION_TOOL_NAME: &str = "request_terminal_actions";
const USER_INPUT_TOOL_NAME: &str = "request_user_input";
pub const SERVER_NAME_PREFIX: &str = "intellterm_";
pub const SERVER_ID_HEX_LEN: usize = 20;
pub const HELPER_REQUEST_METHOD: &str = "_intellterm.wta/request_terminal_actions";
pub const USER_INPUT_HELPER_REQUEST_METHOD: &str = "_intellterm.wta/request_user_input";
pub const CANCEL_USER_INPUT_HELPER_REQUEST_METHOD: &str = "_intellterm.wta/cancel_user_input";

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HelperRequest {
    pub session_id: String,
    pub arguments: Value,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UserInputHelperRequest {
    pub request_id: String,
    pub session_id: String,
    pub request: crate::agent_tools::user_input::UserInputRequest,
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CancelUserInputHelperRequest {
    pub request_id: String,
    pub session_id: String,
}

pub fn helper_method_matches(method: &str) -> bool {
    method.trim_start_matches('_') == HELPER_REQUEST_METHOD.trim_start_matches('_')
}

pub fn user_input_helper_method_matches(method: &str) -> bool {
    method.trim_start_matches('_') == USER_INPUT_HELPER_REQUEST_METHOD.trim_start_matches('_')
}

pub fn cancel_user_input_helper_method_matches(method: &str) -> bool {
    method.trim_start_matches('_')
        == CANCEL_USER_INPUT_HELPER_REQUEST_METHOD.trim_start_matches('_')
}

pub fn server_name_matches(name: &str) -> bool {
    if name == "intelligent_terminal" {
        return true;
    }
    name.strip_prefix(SERVER_NAME_PREFIX)
        .is_some_and(|server_id| {
            server_id.len() == SERVER_ID_HEX_LEN
                && server_id
                    .chars()
                    .all(|ch| ch.is_ascii_digit() || ('a'..='f').contains(&ch))
        })
}

pub async fn dispatch<A, ActionFuture, U, UserInputFuture>(
    request: Value,
    submit_action: A,
    request_user_input: U,
) -> Option<Value>
where
    A: FnOnce(Value) -> ActionFuture,
    ActionFuture: Future<Output = anyhow::Result<ProposalValidationResponse>>,
    U: FnOnce(Value) -> UserInputFuture,
    UserInputFuture: Future<Output = anyhow::Result<UserInputResponse>>,
{
    let id = request.get("id").cloned();
    let method = request.get("method").and_then(Value::as_str).unwrap_or("");
    if id.is_none() {
        return None;
    }
    let id = id.unwrap();
    let result = match method {
        "initialize" => {
            let version = request
                .pointer("/params/protocolVersion")
                .and_then(Value::as_str)
                .filter(|version| SUPPORTED_MCP_PROTOCOL_VERSIONS.contains(version))
                .unwrap_or(MCP_PROTOCOL_VERSION);
            json!({
                "protocolVersion": version,
                "capabilities": { "tools": {} },
                "serverInfo": {
                    "name": "intelligent-terminal",
                    "version": env!("CARGO_PKG_VERSION")
                }
            })
        }
        "ping" => json!({}),
        "tools/list" => {
            let mut tools: Vec<Value> = super::action_proposal::schema::McpActionTool::ALL
                .into_iter()
                .map(|tool| {
                    json!({
                        "name": tool.tool_name(),
                        "description": super::action_proposal::schema::mcp_action_description(tool),
                        "inputSchema": super::action_proposal::schema::mcp_action_input_schema(tool)
                    })
                })
                .collect();
            tools.push(json!({
                "name": USER_INPUT_TOOL_NAME,
                "description": "Ask the user a blocking clarification question in Intelligent Terminal. Supply up to 8 choices, set allow_freeform to true, or both; a call with neither is rejected. Use only when the answer is required to continue the current task.",
                "inputSchema": {
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["question"],
                    "properties": {
                        "question": {
                            "type": "string",
                            "minLength": 1,
                            "maxLength": 2000
                        },
                        "choices": {
                            "type": "array",
                            "minItems": 1,
                            "maxItems": 8,
                            "items": {
                                "type": "string",
                                "minLength": 1,
                                "maxLength": 200
                            }
                        },
                        "allow_freeform": {
                            "type": "boolean",
                            "default": false
                        }
                    }
                }
            }));
            json!({ "tools": tools })
        }
        "tools/call" => {
            let name = request.pointer("/params/name").and_then(Value::as_str);
            let arguments = request
                .pointer("/params/arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            match name {
                Some(TERMINAL_ACTION_TOOL_NAME) => {
                    // Superseded single-tool name: the payload already carries
                    // its own `type`, so forward it untouched.
                    terminal_action_result(submit_action(arguments).await)
                }
                Some(name)
                    if super::action_proposal::schema::McpActionTool::from_tool_name(name)
                        .is_some() =>
                {
                    let Some(tool) =
                        super::action_proposal::schema::McpActionTool::from_tool_name(name)
                    else {
                        unreachable!("guarded by the match arm")
                    };
                    terminal_action_result(submit_action(with_action_type(arguments, tool)).await)
                }
                Some(USER_INPUT_TOOL_NAME) => {
                    user_input_result(request_user_input(arguments).await)
                }
                _ => return Some(error_response(id, -32602, "unknown tool")),
            }
        }
        _ => return Some(error_response(id, -32601, "method not found")),
    };
    Some(json!({ "jsonrpc": "2.0", "id": id, "result": result }))
}

/// Map the selected action tool back to the `type` discriminator the internal
/// helper pipe expects. Server-generated from the matched tool name, so it is
/// always consistent with the schema the payload was validated against.
fn with_action_type(
    arguments: Value,
    tool: super::action_proposal::schema::McpActionTool,
) -> Value {
    use super::action_proposal::schema::McpActionTool;
    let action_type = match tool {
        McpActionTool::Send => "send",
        McpActionTool::Open => "open",
        McpActionTool::OpenAndSend => "open_and_send",
    };
    let mut arguments = arguments;
    if let Some(object) = arguments.as_object_mut() {
        object.insert("type".to_string(), Value::String(action_type.to_string()));
    }
    arguments
}

fn terminal_action_result(response: anyhow::Result<ProposalValidationResponse>) -> Value {
    match response {
        Ok(response) => {
            let status = response.status;
            let status_text = match status {
                ProposalValidationStatus::Accepted => "accepted",
                ProposalValidationStatus::AlreadyConsumed => "duplicate",
                ProposalValidationStatus::Stale
                | ProposalValidationStatus::UnknownChannel
                | ProposalValidationStatus::HelperMismatch
                | ProposalValidationStatus::Superseded => "stale",
                ProposalValidationStatus::InvalidSchema | ProposalValidationStatus::Rejected => {
                    "rejected"
                }
                ProposalValidationStatus::Unavailable => "unavailable",
            };
            let structured = json!({
                "status": status_text,
                "reason": response.reason,
                "retryable": response.retryable
            });
            let text = if status == ProposalValidationStatus::Accepted {
                "Terminal actions accepted. End the turn without additional text.".to_string()
            } else {
                format!(
                    "Terminal action request {status_text}: {}",
                    structured["reason"]
                        .as_str()
                        .unwrap_or("no reason provided")
                )
            };
            json!({
                "content": [{ "type": "text", "text": text }],
                "structuredContent": structured,
                "isError": status != ProposalValidationStatus::Accepted
            })
        }
        Err(error) => json!({
            "content": [{
                "type": "text",
                "text": format!("Terminal action request unavailable: {error:#}")
            }],
            "structuredContent": {
                "status": "unavailable",
                "reason": format!("{error:#}"),
                "retryable": false
            },
            "isError": true
        }),
    }
}

fn user_input_result(response: anyhow::Result<UserInputResponse>) -> Value {
    match response {
        Ok(UserInputResponse::Answered {
            answer,
            selected_index,
        }) => json!({
            "content": [{ "type": "text", "text": answer }],
            "structuredContent": {
                "outcome": "answered",
                "answer": answer,
                "selected_index": selected_index
            },
            "isError": false
        }),
        Ok(UserInputResponse::Cancelled) => json!({
            "content": [{ "type": "text", "text": "The user cancelled the question." }],
            "structuredContent": { "outcome": "cancelled" },
            "isError": false
        }),
        Err(error) => json!({
            "content": [{
                "type": "text",
                "text": format!("User input request unavailable: {error:#}")
            }],
            "structuredContent": {
                "outcome": "unavailable",
                "reason": format!("{error:#}")
            },
            "isError": true
        }),
    }
}

pub fn error_response(id: Value, code: i64, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": code, "message": message }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn lists_session_tools() {
        let response = dispatch(
            json!({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}),
            |_| async { unreachable!() },
            |_| async { unreachable!() },
        )
        .await
        .unwrap();
        let names: Vec<&str> = response
            .pointer("/result/tools")
            .and_then(Value::as_array)
            .expect("tools")
            .iter()
            .filter_map(|tool| tool.get("name").and_then(Value::as_str))
            .collect();
        assert_eq!(
            names,
            vec![
                "terminal_send",
                "terminal_open",
                "terminal_open_and_send",
                USER_INPUT_TOOL_NAME
            ]
        );
        // The superseded single-tool name is still accepted by tools/call, but
        // must not be advertised — advertising both would double the cost.
        assert!(!names.contains(&TERMINAL_ACTION_TOOL_NAME));
        let user_input_schema = response
            .pointer("/result/tools/3/inputSchema")
            .expect("user input schema");
        assert_eq!(
            user_input_schema.get("type").and_then(Value::as_str),
            Some("object")
        );
        for keyword in ["oneOf", "anyOf", "allOf", "enum", "const", "not"] {
            assert!(
                user_input_schema.get(keyword).is_none(),
                "top-level {keyword} is rejected by strict OpenAI-compatible providers"
            );
        }
        // An empty choice list is never meaningful — omit the field instead.
        // Constraining it here stops a model from emitting `choices: []` and
        // then tripping `UserInputRequest::validate()` when it also leaves
        // `allow_freeform` at its default of false.
        assert_eq!(
            user_input_schema
                .pointer("/properties/choices/minItems")
                .and_then(Value::as_u64),
            Some(1)
        );
    }

    /// Prints the serialized `tools/list` size so the cost of the tool surface
    /// can be compared across revisions with a real number rather than an
    /// estimate. Run with `-- --nocapture`.
    #[tokio::test]
    async fn measure_tools_list_size() {
        let response = dispatch(
            json!({"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}),
            |_| async { unreachable!() },
            |_| async { unreachable!() },
        )
        .await
        .unwrap();
        let tools = response.pointer("/result/tools").expect("tools");
        let serialized = serde_json::to_string(tools).expect("serialize");
        println!(
            "MEASURE tools={} chars={} approx_tokens={}",
            tools.as_array().map(Vec::len).unwrap_or(0),
            serialized.len(),
            serialized.len() / 4
        );
    }

    #[tokio::test]
    async fn initialize_negotiates_a_supported_protocol_version() {
        let request = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": { "protocolVersion": "unsupported" }
        });
        let response = dispatch(
            request,
            |_| async { unreachable!() },
            |_| async { unreachable!() },
        )
        .await
        .unwrap();

        assert_eq!(
            response
                .pointer("/result/protocolVersion")
                .and_then(Value::as_str),
            Some(MCP_PROTOCOL_VERSION)
        );
    }

    #[tokio::test]
    async fn returns_structured_user_answer() {
        let response = dispatch(
            json!({
                "jsonrpc":"2.0",
                "id":1,
                "method":"tools/call",
                "params":{
                    "name":"request_user_input",
                    "arguments":{"question":"Choose","choices":["A","B"]}
                }
            }),
            |_| async { unreachable!() },
            |_| async {
                Ok(UserInputResponse::Answered {
                    answer: "B".into(),
                    selected_index: Some(1),
                })
            },
        )
        .await
        .unwrap();

        assert_eq!(
            response
                .pointer("/result/structuredContent/answer")
                .and_then(Value::as_str),
            Some("B")
        );
        assert_eq!(
            response
                .pointer("/result/structuredContent/selected_index")
                .and_then(Value::as_u64),
            Some(1)
        );
    }
}
