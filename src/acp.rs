//! ACP over an SSH exec channel: the only way to reach OMP from another box.
//!
//! OMP has no network listener. Its machine-readable protocol is Agent Client
//! Protocol — JSON-RPC 2.0, one object per line — and it speaks it on stdin
//! and stdout, nothing else. So the "transport" here is `omp acp` running on
//! the far end of an SSH exec channel (no PTY: terminal echo would corrupt the
//! framing), and this module is a JSON-RPC peer that happens to read and write
//! through russh.
//!
//! Two things this module refuses to do. It never matches a response by
//! arrival order — every response is matched on its `id`, because a prompt can
//! finish minutes after the `session/new` that followed it. And it never
//! advertises `fs` or `terminal` client capabilities: doing so would make OMP
//! politely ask *us* to read and write files and run terminals, over a laptop
//! link, when the entire point is that the work happens on the box.

use std::collections::{HashMap, VecDeque};

use anyhow::{Context, Result};
use russh::{ChannelMsg, ChannelWriteHalf};
use serde_json::{Value, json};

use crate::agent::{Spec, shell_quote};
use crate::event::{AgentCmd, Msg, Scope, ToolState, Ui, fail};
use crate::ssh::SshClient;

/// What a response we are still waiting for will mean when it arrives.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Want {
    Initialize,
    NewSession,
    Prompt,
}

/// An unanswered `session/request_permission`. Holding the original JSON-RPC
/// id verbatim matters: the agent's turn stays parked until a response with
/// exactly that id comes back.
#[derive(Debug, Clone)]
struct Permission {
    id: Value,
    /// `(label shown to the human, optionId the agent expects back)`.
    options: Vec<(String, String)>,
}

pub async fn run(
    spec: Spec,
    ui: Ui,
    mut commands: tokio::sync::mpsc::UnboundedReceiver<AgentCmd>,
) -> Result<()> {
    let target = spec.target.clone().with_context(|| {
        format!(
            "agent `{}` is kind `acp` but has no host; set `host` on it in config.json",
            spec.name
        )
    })?;
    let client = SshClient::connect(&target)
        .await
        .with_context(|| format!("connecting to {} for agent `{}`", target.label(), spec.name))?;
    let label = target.label();

    let command = crate::agent::login_shell(&remote_command(&spec));
    let _ = ui.send(Msg::log(Scope::Agent, format!("{label}: {command}")));

    let channel = client
        .exec(&command)
        .await
        .with_context(|| format!("starting `{command}` on {label}"))?;
    // Split so a long-running read can never block a write: an unanswered
    // permission request would otherwise deadlock both halves.
    let (mut reader, writer) = channel.split();

    let mut acp = Acp::new(spec, ui.clone(), writer);
    acp.initialize().await?;

    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let mut stderr_tail = String::new();
    let mut exit: Option<u32> = None;
    let mut closed_by_us = false;

    loop {
        tokio::select! {
            incoming = reader.wait() => {
                let Some(incoming) = incoming else { break };
                match incoming {
                    ChannelMsg::Data { data } => {
                        stdout.extend_from_slice(&data);
                        for line in take_lines(&mut stdout) {
                            acp.handle_line(&line).await?;
                        }
                    }
                    // ext 1 is stderr. This is where a missing binary, a bad
                    // `--cwd` or a panic shows up; discarding it would turn
                    // every startup failure into a silent hang.
                    ChannelMsg::ExtendedData { data, ext: 1 } => {
                        stderr.extend_from_slice(&data);
                        for line in take_lines(&mut stderr) {
                            let line = line.trim().to_string();
                            if line.is_empty() {
                                continue;
                            }
                            let _ = ui.send(Msg::log(
                                Scope::Agent,
                                format!("{}: {line}", acp.spec.program),
                            ));
                            stderr_tail = line;
                        }
                    }
                    ChannelMsg::ExitStatus { exit_status } => exit = Some(exit_status),
                    ChannelMsg::Eof | ChannelMsg::Close => break,
                    _ => {}
                }
            }
            cmd = commands.recv() => {
                let Some(cmd) = cmd else { break };
                if !acp.handle_cmd(cmd).await? {
                    closed_by_us = true;
                    break;
                }
            }
        }
    }

    if !closed_by_us {
        let status = match exit {
            Some(code) => format!("exit status {code}"),
            None => "no exit status".to_string(),
        };
        if acp.session.is_none() {
            let detail = if stderr_tail.is_empty() {
                "it printed nothing on stderr".to_string()
            } else {
                stderr_tail.clone()
            };
            fail(
                &ui,
                Scope::Agent,
                format!(
                    "`{command}` ended before an ACP session started ({status}): {detail}; \
                     check that `{}` runs on {label} from a login shell",
                    acp.spec.program
                ),
            );
        } else {
            let _ = ui.send(Msg::log(
                Scope::Agent,
                format!("agent channel closed ({status})"),
            ));
        }
        if acp.turn {
            let _ = ui.send(Msg::AgentTurnEnd {
                reason: "failed".into(),
            });
        }
    }

    acp.shutdown().await;
    client.close().await;
    Ok(())
}

/// Build the remote command line.
///
/// `program` is not quoted — it is the operator's own config string and may
/// legitimately be a prefix like `env RUST_LOG=debug omp`. Everything after it
/// is quoted, because a path with a space in it should not silently become two
/// arguments.
fn remote_command(spec: &Spec) -> String {
    let mut command = spec.program.clone();
    command.push_str(" acp");
    if let Some(cwd) = &spec.cwd
        && !cwd.is_empty()
    {
        command.push_str(" --cwd ");
        command.push_str(&shell_quote(cwd));
    }
    if spec.yolo {
        command.push_str(" --yolo");
    }
    for arg in &spec.args {
        command.push(' ');
        command.push_str(&shell_quote(arg));
    }
    command
}

/// Split every complete line out of `buffer`, leaving any partial tail behind.
/// A 40 KB tool result arrives in several TCP reads; parsing before the
/// newline would corrupt it.
fn take_lines(buffer: &mut Vec<u8>) -> Vec<String> {
    let mut lines = Vec::new();
    while let Some(index) = buffer.iter().position(|byte| *byte == b'\n') {
        let line: Vec<u8> = buffer.drain(..=index).collect();
        lines.push(String::from_utf8_lossy(&line[..line.len() - 1]).into_owned());
    }
    lines
}

/// ACP `stopReason`s are protocol words; the UI shows turn outcomes. Anything
/// unrecognised passes through untouched rather than being flattened into
/// "completed", which would hide a refusal.
fn stop_reason(raw: &str) -> String {
    match raw {
        "end_turn" => "completed".to_string(),
        "cancelled" | "canceled" => "interrupted".to_string(),
        other => other.to_string(),
    }
}

/// Flatten an ACP content block (or a list of them) into plain text.
fn content_text(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Array(blocks) => blocks.iter().map(content_text).collect(),
        Value::Object(_) => value
            .get("text")
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| value.get("content").map(content_text))
            .unwrap_or_default(),
        _ => String::new(),
    }
}

/// A one-line digest of arbitrary JSON, for the tool row in the transcript.
/// Bounded, because `rawInput` can hold an entire file.
fn digest(value: &Value) -> String {
    let text = match value {
        Value::Null => String::new(),
        Value::String(text) => text.clone(),
        Value::Object(fields) => fields
            .iter()
            .map(|(key, field)| format!("{key}={}", digest(field)))
            .collect::<Vec<_>>()
            .join(" "),
        Value::Array(items) => items.iter().map(digest).collect::<Vec<_>>().join(", "),
        other => other.to_string(),
    };
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() > 160 {
        let cut: String = flat.chars().take(157).collect();
        format!("{cut}...")
    } else {
        flat
    }
}

/// Where outgoing JSON-RPC lines go.
///
/// The state machine below is the part of this module most likely to be
/// wrong, and it is unreachable without an SSH server unless the one line it
/// writes can be redirected. Hence this trait: one implementation is the real
/// channel, the other is a `Vec<String>` in the tests. The explicit `+ Send`
/// is required because the worker is spawned onto the multi-threaded runtime.
trait Sink {
    fn write_line(&self, line: Vec<u8>) -> impl Future<Output = Result<()>> + Send;
    fn shutdown(&self) -> impl Future<Output = ()> + Send;
}

impl Sink for ChannelWriteHalf<russh::client::Msg> {
    async fn write_line(&self, line: Vec<u8>) -> Result<()> {
        self.data_bytes(line)
            .await
            .context("writing to the agent's stdin; the process has probably exited")
    }

    async fn shutdown(&self) {
        // Best effort: if the process is already gone both of these fail, and
        // there is nothing useful left to say about it.
        let _ = self.eof().await;
        let _ = self.close().await;
    }
}

struct Acp<W: Sink> {
    spec: Spec,
    ui: Ui,
    writer: W,
    next_id: i64,
    pending: HashMap<i64, Want>,
    permissions: HashMap<String, Permission>,
    session: Option<String>,
    /// Prompts typed before `session/new` came back. Dropping them would make
    /// the first message after connecting disappear.
    queued: VecDeque<String>,
    turn: bool,
}

impl<W: Sink> Acp<W> {
    fn new(spec: Spec, ui: Ui, writer: W) -> Self {
        Self {
            spec,
            ui,
            writer,
            next_id: 1,
            pending: HashMap::new(),
            permissions: HashMap::new(),
            session: None,
            queued: VecDeque::new(),
            turn: false,
        }
    }

    async fn write(&self, value: &Value) -> Result<()> {
        let mut line = serde_json::to_vec(value).context("encoding a JSON-RPC message")?;
        line.push(b'\n');
        self.writer.write_line(line).await
    }

    async fn request(&mut self, method: &str, params: Value, want: Want) -> Result<()> {
        let id = self.next_id;
        self.next_id += 1;
        self.pending.insert(id, want);
        self.write(&json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        }))
        .await
    }

    async fn notify(&self, method: &str, params: Value) -> Result<()> {
        self.write(&json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        }))
        .await
    }

    async fn initialize(&mut self) -> Result<()> {
        // `fs` and `terminal` are declared and declared *false*. Omitting them
        // would mean the same thing, but saying it out loud is the point: with
        // either one true, OMP delegates file writes and PTYs back across the
        // SSH link to this client instead of doing them on the box.
        let params = json!({
            "protocolVersion": 1,
            "clientCapabilities": {
                "fs": { "readTextFile": false, "writeTextFile": false },
                "terminal": false,
            },
            "clientInfo": {
                "name": "remote-craft",
                "version": env!("CARGO_PKG_VERSION"),
            },
        });
        self.request("initialize", params, Want::Initialize).await
    }

    async fn handle_line(&mut self, line: &str) -> Result<()> {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            return Ok(());
        }
        let Ok(value) = serde_json::from_str::<Value>(trimmed) else {
            // Anything a shell profile prints lands here. It is noise, not a
            // protocol violation, so it goes to the log and the loop survives.
            let _ = self.ui.send(Msg::log(
                Scope::Agent,
                format!("{}: {trimmed}", self.spec.program),
            ));
            return Ok(());
        };

        let method = value.get("method").and_then(Value::as_str);
        let id = value.get("id").cloned();

        match (method, id) {
            (Some(method), Some(id)) => self.handle_request(method, id, &value).await,
            (Some(method), None) => {
                self.handle_notification(method, value.get("params").unwrap_or(&Value::Null));
                Ok(())
            }
            (None, Some(id)) => {
                // Some agents echo the id back as a string. Dropping such a
                // response would leave the turn running forever.
                let key = id
                    .as_i64()
                    .or_else(|| id.as_str().and_then(|text| text.parse().ok()));
                self.handle_response(key, &value).await
            }
            (None, None) => Ok(()),
        }
    }

    async fn handle_response(&mut self, id: Option<i64>, value: &Value) -> Result<()> {
        // Matched on id, never on order: a `session/prompt` response can and
        // does arrive after later requests have already been answered.
        let Some(want) = id.and_then(|id| self.pending.remove(&id)) else {
            return Ok(());
        };

        if let Some(error) = value.get("error") {
            let message = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("the agent returned an error with no message");
            let context = match want {
                Want::Initialize => "the ACP handshake failed",
                Want::NewSession => "the agent refused to open a session",
                Want::Prompt => "the prompt failed",
            };
            fail(&self.ui, Scope::Agent, format!("{context}: {message}"));
            if want == Want::Prompt {
                self.turn = false;
                let _ = self.ui.send(Msg::AgentTurnEnd {
                    reason: "failed".into(),
                });
            }
            return Ok(());
        }

        let result = value.get("result").unwrap_or(&Value::Null);
        match want {
            Want::Initialize => {
                let info = result.get("agentInfo");
                let name = info
                    .and_then(|info| info.get("name"))
                    .and_then(Value::as_str)
                    .unwrap_or(&self.spec.program)
                    .to_string();
                let version = info
                    .and_then(|info| info.get("version"))
                    .and_then(Value::as_str)
                    .unwrap_or("unknown version")
                    .to_string();
                let protocol = result
                    .get("protocolVersion")
                    .map(digest)
                    .unwrap_or_else(|| "1".to_string());
                let _ = self.ui.send(Msg::AgentConnected {
                    agent: name,
                    detail: format!("{version} · ACP v{protocol}"),
                });
                let cwd = self.spec.cwd.clone().unwrap_or_else(|| ".".to_string());
                self.request(
                    "session/new",
                    json!({ "cwd": cwd, "mcpServers": [] }),
                    Want::NewSession,
                )
                .await
            }
            Want::NewSession => {
                let Some(id) = result.get("sessionId").and_then(Value::as_str) else {
                    fail(
                        &self.ui,
                        Scope::Agent,
                        "the agent opened a session but did not name it; the remote `omp` is too old for this client",
                    );
                    return Ok(());
                };
                self.session = Some(id.to_string());
                let _ = self.ui.send(Msg::AgentSession { id: id.to_string() });
                while let Some(text) = self.queued.pop_front() {
                    self.send_prompt(text).await?;
                }
                Ok(())
            }
            Want::Prompt => {
                // The turn is over *here*, on the response — not when the
                // request was acknowledged, and not on the last text chunk.
                self.turn = false;
                let reason = result
                    .get("stopReason")
                    .and_then(Value::as_str)
                    .map(stop_reason)
                    .unwrap_or_else(|| "completed".to_string());
                let _ = self.ui.send(Msg::AgentTurnEnd { reason });
                Ok(())
            }
        }
    }

    /// Agent→client requests. Everything we do not implement gets a proper
    /// JSON-RPC error rather than silence: an unanswered request parks the
    /// remote turn forever.
    async fn handle_request(&mut self, method: &str, id: Value, value: &Value) -> Result<()> {
        let params = value.get("params").unwrap_or(&Value::Null);
        if method != "session/request_permission" {
            return self
                .write(&json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": {
                        "code": -32601,
                        "message": format!(
                            "remote-craft does not implement {method}; it does not advertise fs or terminal capabilities"
                        ),
                    },
                }))
                .await;
        }

        let options: Vec<(String, String)> = params
            .get("options")
            .and_then(Value::as_array)
            .map(|options| {
                options
                    .iter()
                    .filter_map(|option| {
                        let option_id = option.get("optionId").and_then(Value::as_str)?;
                        let label = option
                            .get("name")
                            .and_then(Value::as_str)
                            .unwrap_or(option_id);
                        Some((label.to_string(), option_id.to_string()))
                    })
                    .collect()
            })
            .unwrap_or_default();

        let tool = params.get("toolCall");
        let prompt = tool
            .and_then(|tool| tool.get("title"))
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or_else(|| "the agent is asking for permission".to_string());

        let key = id.to_string();
        self.permissions.insert(
            key.clone(),
            Permission {
                id,
                options: options.clone(),
            },
        );
        let _ = self.ui.send(Msg::AgentPermission {
            id: key,
            prompt,
            options: options.into_iter().map(|(label, _)| label).collect(),
        });
        Ok(())
    }

    fn handle_notification(&mut self, method: &str, params: &Value) {
        if method != "session/update" {
            return;
        }
        let update = params.get("update").unwrap_or(params);
        let kind = update
            .get("sessionUpdate")
            .or_else(|| update.get("kind"))
            .and_then(Value::as_str)
            .unwrap_or_default();

        match kind {
            "agent_message_chunk" => {
                let text = content_text(update.get("content").unwrap_or(&Value::Null));
                if !text.is_empty() {
                    let _ = self.ui.send(Msg::AgentDelta { text });
                }
            }
            "agent_thought_chunk" => {
                let text = content_text(update.get("content").unwrap_or(&Value::Null));
                if !text.is_empty() {
                    let _ = self.ui.send(Msg::AgentThought { text });
                }
            }
            "tool_call" => {
                let _ = self.ui.send(tool_msg(update, ToolState::Started));
            }
            "tool_call_update" => {
                let state = match update.get("status").and_then(Value::as_str) {
                    Some("completed") => ToolState::Completed,
                    Some("failed") => ToolState::Failed,
                    // `pending` / `in_progress` / anything new: still running.
                    _ => ToolState::Started,
                };
                let _ = self.ui.send(tool_msg(update, state));
            }
            "plan" => {
                let steps = update
                    .get("entries")
                    .and_then(Value::as_array)
                    .map(|entries| entries.iter().map(plan_step).collect())
                    .unwrap_or_default();
                let _ = self.ui.send(Msg::AgentPlan { steps });
            }
            // New update kinds are added to ACP regularly. Ignoring one costs
            // a missing line; treating it as fatal costs the session.
            _ => {}
        }
    }

    /// Returns false when the worker should stop.
    async fn handle_cmd(&mut self, cmd: AgentCmd) -> Result<bool> {
        match cmd {
            AgentCmd::Prompt(text) => {
                if self.session.is_some() {
                    self.send_prompt(text).await?;
                } else {
                    self.queued.push_back(text);
                }
            }
            AgentCmd::Cancel => {
                if let Some(session) = self.session.clone() {
                    // A notification, not a request: the acknowledgement is
                    // the prompt response coming back with `cancelled`.
                    self.notify("session/cancel", json!({ "sessionId": session }))
                        .await?;
                }
            }
            AgentCmd::Answer { id, choice } => self.answer(&id, &choice).await?,
            AgentCmd::Close => return Ok(false),
        }
        Ok(true)
    }

    async fn send_prompt(&mut self, text: String) -> Result<()> {
        let Some(session) = self.session.clone() else {
            self.queued.push_back(text);
            return Ok(());
        };
        self.turn = true;
        self.request(
            "session/prompt",
            json!({
                "sessionId": session,
                "prompt": [{ "type": "text", "text": text }],
            }),
            Want::Prompt,
        )
        .await
    }

    async fn answer(&mut self, id: &str, choice: &str) -> Result<()> {
        let Some(permission) = self.permissions.remove(id) else {
            // Already answered, or the agent gave up on it. Saying so beats
            // sending a response for an id the agent has forgotten.
            let _ = self.ui.send(Msg::log(
                Scope::Agent,
                format!("no outstanding permission request {id}"),
            ));
            return Ok(());
        };

        let selected = permission
            .options
            .iter()
            .find(|(label, _)| label.eq_ignore_ascii_case(choice))
            .or_else(|| {
                permission
                    .options
                    .iter()
                    .find(|(_, option_id)| option_id.eq_ignore_ascii_case(choice))
            })
            .map(|(_, option_id)| option_id.clone());

        let outcome = match selected {
            Some(option_id) => json!({ "outcome": "selected", "optionId": option_id }),
            // Refusing explicitly is still an answer; the turn unblocks.
            None => json!({ "outcome": "cancelled" }),
        };
        self.write(&json!({
            "jsonrpc": "2.0",
            "id": permission.id,
            "result": { "outcome": outcome },
        }))
        .await
    }

    async fn shutdown(&mut self) {
        self.writer.shutdown().await;
    }
}

fn tool_msg(update: &Value, state: ToolState) -> Msg {
    let id = update
        .get("toolCallId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let name = update
        .get("title")
        .and_then(Value::as_str)
        .or_else(|| update.get("kind").and_then(Value::as_str))
        .unwrap_or("tool")
        .to_string();
    let detail = match state {
        ToolState::Started => update.get("rawInput").map(digest).unwrap_or_default(),
        _ => {
            let content = content_text(update.get("content").unwrap_or(&Value::Null));
            if content.is_empty() {
                update.get("rawOutput").map(digest).unwrap_or_default()
            } else {
                digest(&Value::String(content))
            }
        }
    };
    Msg::AgentTool {
        id,
        name,
        state,
        detail,
    }
}

/// `AgentPlan` carries plain strings, so progress has to be encoded in the
/// text or lost. A plan with no progress in it is not worth drawing.
fn plan_step(entry: &Value) -> String {
    let text = content_text(entry.get("content").unwrap_or(entry));
    match entry.get("status").and_then(Value::as_str) {
        Some("completed") => format!("[x] {text}"),
        Some("in_progress") => format!("[>] {text}"),
        _ => format!("[ ] {text}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::AgentKind;

    fn spec() -> Spec {
        Spec {
            name: "omp".into(),
            kind: AgentKind::Acp,
            target: None,
            url: None,
            token: None,
            cwd: None,
            program: "omp".into(),
            args: Vec::new(),
            yolo: false,
        }
    }

    /// A `Sink` that keeps what was written, so the state machine can be
    /// driven without an SSH server on the other end.
    /// The lock is `tokio::sync::Mutex` because this is async coordination and
    /// `parking_lot` is not a dependency of this crate.
    #[derive(Clone, Default)]
    struct Recorder {
        sent: std::sync::Arc<tokio::sync::Mutex<Vec<Value>>>,
    }

    impl Recorder {
        async fn drain(&self) -> Vec<Value> {
            std::mem::take(&mut *self.sent.lock().await)
        }
    }

    impl Sink for Recorder {
        async fn write_line(&self, line: Vec<u8>) -> Result<()> {
            let text = String::from_utf8(line).expect("frames are utf-8");
            assert!(text.ends_with('\n'), "frames must be newline-delimited");
            assert_eq!(text.matches('\n').count(), 1, "one object per line: {text}");
            self.sent
                .lock()
                .await
                .push(serde_json::from_str(text.trim_end()).expect("frames are json"));
            Ok(())
        }

        async fn shutdown(&self) {}
    }

    fn harness() -> (Acp<Recorder>, Recorder, std::sync::mpsc::Receiver<Msg>) {
        let (tx, rx) = std::sync::mpsc::channel();
        let recorder = Recorder::default();
        (Acp::new(spec(), tx, recorder.clone()), recorder, rx)
    }

    fn seen(rx: &std::sync::mpsc::Receiver<Msg>) -> Vec<Msg> {
        rx.try_iter().collect()
    }

    #[tokio::test]
    async fn the_handshake_refuses_fs_and_terminal_capabilities() {
        let (mut acp, sent, _rx) = harness();
        acp.initialize().await.unwrap();

        let frames = sent.drain().await;
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0]["jsonrpc"], "2.0");
        assert_eq!(frames[0]["method"], "initialize");
        assert_eq!(frames[0]["params"]["protocolVersion"], 1);
        let caps = &frames[0]["params"]["clientCapabilities"];
        // The whole point: OMP must do its own file and terminal work on the
        // box rather than calling back across the SSH link.
        assert_eq!(caps["terminal"], false);
        assert_eq!(caps["fs"]["readTextFile"], false);
        assert_eq!(caps["fs"]["writeTextFile"], false);
    }

    #[tokio::test]
    async fn a_prompt_sent_while_connecting_survives_and_ends_on_its_stop_reason() {
        let (mut acp, sent, rx) = harness();
        acp.initialize().await.unwrap();
        let init_id = sent.drain().await[0]["id"].clone();

        // Typed before the session exists: queued, not dropped, not sent.
        acp.handle_cmd(AgentCmd::Prompt("hello".into()))
            .await
            .unwrap();
        assert!(sent.drain().await.is_empty());

        acp.handle_line(
            &json!({
                "jsonrpc": "2.0",
                "id": init_id,
                "result": {
                    "protocolVersion": 1,
                    "agentInfo": { "name": "omp", "version": "0.9.1" },
                },
            })
            .to_string(),
        )
        .await
        .unwrap();
        let frames = sent.drain().await;
        assert_eq!(frames[0]["method"], "session/new");
        assert_eq!(frames[0]["params"]["mcpServers"], json!([]));
        let new_id = frames[0]["id"].clone();
        assert!(
            matches!(&seen(&rx)[..], [Msg::AgentConnected { agent, detail }]
            if agent == "omp" && detail.contains("0.9.1"))
        );

        acp.handle_line(
            &json!({ "jsonrpc": "2.0", "id": new_id, "result": { "sessionId": "sess-1" } })
                .to_string(),
        )
        .await
        .unwrap();
        assert!(matches!(&seen(&rx)[..], [Msg::AgentSession { id }] if id == "sess-1"));

        // The queued prompt goes out as soon as there is a session to put it in.
        let frames = sent.drain().await;
        assert_eq!(frames[0]["method"], "session/prompt");
        assert_eq!(frames[0]["params"]["sessionId"], "sess-1");
        assert_eq!(frames[0]["params"]["prompt"][0]["text"], "hello");
        let prompt_id = frames[0]["id"].clone();

        acp.handle_line(
            &json!({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {
                    "sessionId": "sess-1",
                    "update": {
                        "sessionUpdate": "agent_message_chunk",
                        "content": { "type": "text", "text": "hi" },
                    },
                },
            })
            .to_string(),
        )
        .await
        .unwrap();
        // An update kind this client has never heard of is not fatal.
        acp.handle_line(
            &json!({
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": { "update": { "sessionUpdate": "vibe_shift", "mood": "blue" } },
            })
            .to_string(),
        )
        .await
        .unwrap();
        assert!(matches!(&seen(&rx)[..], [Msg::AgentDelta { text }] if text == "hi"));

        // Only the response to the prompt ends the turn.
        acp.handle_line(
            &json!({ "jsonrpc": "2.0", "id": prompt_id, "result": { "stopReason": "end_turn" } })
                .to_string(),
        )
        .await
        .unwrap();
        assert!(matches!(&seen(&rx)[..], [Msg::AgentTurnEnd { reason }] if reason == "completed"));
    }

    #[tokio::test]
    async fn a_permission_request_is_answered_with_its_own_id_and_option() {
        let (mut acp, sent, rx) = harness();
        acp.handle_line(
            &json!({
                "jsonrpc": "2.0",
                "id": 42,
                "method": "session/request_permission",
                "params": {
                    "sessionId": "sess-1",
                    "toolCall": { "toolCallId": "t1", "title": "rm -rf /tmp/x" },
                    "options": [
                        { "optionId": "allow-once", "name": "Allow once", "kind": "allow_once" },
                        { "optionId": "reject", "name": "Reject", "kind": "reject_once" },
                    ],
                },
            })
            .to_string(),
        )
        .await
        .unwrap();

        let id = match &seen(&rx)[..] {
            [
                Msg::AgentPermission {
                    id,
                    prompt,
                    options,
                },
            ] => {
                assert_eq!(prompt, "rm -rf /tmp/x");
                assert_eq!(
                    options,
                    &vec!["Allow once".to_string(), "Reject".to_string()]
                );
                id.clone()
            }
            other => panic!("{other:?}"),
        };
        assert!(
            sent.drain().await.is_empty(),
            "a request is not answered on arrival"
        );

        acp.handle_cmd(AgentCmd::Answer {
            id,
            choice: "Allow once".into(),
        })
        .await
        .unwrap();
        let frames = sent.drain().await;
        // The id must be the agent's own, or the remote turn stays parked.
        assert_eq!(frames[0]["id"], 42);
        assert_eq!(frames[0]["result"]["outcome"]["outcome"], "selected");
        assert_eq!(frames[0]["result"]["outcome"]["optionId"], "allow-once");
    }

    #[tokio::test]
    async fn an_unimplemented_agent_request_gets_an_error_not_silence() {
        let (mut acp, sent, _rx) = harness();
        acp.handle_line(
            &json!({
                "jsonrpc": "2.0",
                "id": 9,
                "method": "fs/write_text_file",
                "params": { "path": "/tmp/x", "content": "y" },
            })
            .to_string(),
        )
        .await
        .unwrap();

        let frames = sent.drain().await;
        assert_eq!(frames[0]["id"], 9);
        assert_eq!(frames[0]["error"]["code"], -32601);
    }

    #[tokio::test]
    async fn tool_calls_and_plans_map_across() {
        let (mut acp, _sent, rx) = harness();
        for update in [
            json!({ "sessionUpdate": "tool_call", "toolCallId": "t1", "title": "read file",
                    "rawInput": { "path": "/etc/hosts" } }),
            json!({ "sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "failed",
                    "content": [{ "type": "content", "content": { "type": "text", "text": "denied" } }] }),
            json!({ "sessionUpdate": "plan", "entries": [
                { "content": "look", "status": "completed" },
                { "content": "leap", "status": "pending" }] }),
        ] {
            acp.handle_line(
                &json!({ "jsonrpc": "2.0", "method": "session/update",
                         "params": { "sessionId": "s", "update": update } })
                .to_string(),
            )
            .await
            .unwrap();
        }

        match &seen(&rx)[..] {
            [
                Msg::AgentTool {
                    id,
                    name,
                    state: ToolState::Started,
                    detail,
                },
                Msg::AgentTool {
                    state: ToolState::Failed,
                    detail: why,
                    ..
                },
                Msg::AgentPlan { steps },
            ] => {
                assert_eq!(id, "t1");
                assert_eq!(name, "read file");
                assert_eq!(detail, "path=/etc/hosts");
                assert_eq!(why, "denied");
                assert_eq!(steps, &vec!["[x] look".to_string(), "[ ] leap".to_string()]);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn command_is_bare_without_cwd_or_yolo() {
        assert_eq!(remote_command(&spec()), "omp acp");
    }

    #[test]
    fn command_quotes_cwd_and_args_but_not_the_program() {
        let mut spec = spec();
        spec.cwd = Some("/home/andrew/my projects".into());
        spec.yolo = true;
        spec.args = vec!["--model".into(), "opus".into()];
        assert_eq!(
            remote_command(&spec),
            "omp acp --cwd '/home/andrew/my projects' --yolo '--model' 'opus'"
        );
    }

    #[test]
    fn lines_are_split_only_on_complete_newlines() {
        let mut buffer = Vec::new();
        buffer.extend_from_slice(b"{\"a\":1}\n{\"b\"");
        let lines = take_lines(&mut buffer);
        assert_eq!(lines, vec!["{\"a\":1}".to_string()]);
        assert_eq!(buffer, b"{\"b\"");

        buffer.extend_from_slice(b":2}\n");
        assert_eq!(take_lines(&mut buffer), vec!["{\"b\":2}".to_string()]);
        assert!(buffer.is_empty());
    }

    #[test]
    fn stop_reasons_become_turn_outcomes() {
        assert_eq!(stop_reason("end_turn"), "completed");
        assert_eq!(stop_reason("cancelled"), "interrupted");
        assert_eq!(stop_reason("refusal"), "refusal");
    }

    #[test]
    fn content_blocks_flatten_to_text() {
        assert_eq!(content_text(&json!({"type":"text","text":"hi"})), "hi");
        assert_eq!(
            content_text(&json!([{"type":"text","text":"a"},{"type":"text","text":"b"}])),
            "ab"
        );
        assert_eq!(content_text(&json!({"type":"image"})), "");
        assert_eq!(content_text(&Value::Null), "");
    }

    #[test]
    fn digest_is_bounded_and_single_line() {
        let long = digest(&json!({ "text": "x".repeat(500) }));
        assert!(long.chars().count() <= 160, "{}", long.chars().count());
        assert!(long.ends_with("..."));
        assert_eq!(digest(&json!({"path":"a\n  b"})), "path=a b");
    }
}
