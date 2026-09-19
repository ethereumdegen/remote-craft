//! The Workshop back end: metalcraft-agent over plain HTTP on the tailnet.
//!
//! This is the one agent that has a real API, so this module is the one place
//! in the crate that does not go through SSH. It talks to `:3002`, carries a
//! bearer token on every request, and reads Server-Sent Events off the turn
//! response.
//!
//! Two shapes of the same protocol have to be handled and the difference is
//! invisible in the body: `POST /turn` answers **200 with the SSE stream
//! itself** when the agent was free, and **202 `{queued:true,position}`** when
//! it was not — in which case the frames for that turn come out of the
//! long-lived `/events` watch instead. A client that only handled 200 would
//! appear to hang whenever the agent was already busy.
//!
//! The stream parser is deliberately forgiving: a frame it cannot decode, or a
//! `kind` it has never heard of, is dropped. metalcraft-agent gains frame
//! kinds faster than this client does, and none of them are worth a crash.

use std::collections::VecDeque;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use futures_util::StreamExt;
use reqwest::header::ACCEPT;
use reqwest::{Client, Response, StatusCode};
use serde_json::{Value, json};
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};
use tokio::task::JoinHandle;

use crate::agent::Spec;
use crate::event::{AgentCmd, Msg, Scope, ToolState, Ui, fail};

/// metalcraft-agent's fixed port; the config may name a host and nothing else.
const DEFAULT_PORT: u16 = 3002;
/// Non-streaming calls are small and local; hanging on one is worse than
/// failing it, because the UI has no other way to find out.
const CALL_TIMEOUT: Duration = Duration::from_secs(20);
/// How long to wait before re-opening the idle watch stream. Long enough not
/// to hammer a box that is rebooting, short enough that an agent-initiated
/// turn is not missed for a whole minute.
const WATCH_RETRY: Duration = Duration::from_secs(3);

/// What the background streaming tasks report back to the command loop.
enum Wire {
    Frame(Value),
    /// A turn's own stream finished (any reason). The idle watch has to be
    /// restarted and any locally queued prompt can now go out.
    TurnEnded,
}

pub async fn run(spec: Spec, ui: Ui, mut commands: UnboundedReceiver<AgentCmd>) -> Result<()> {
    let raw = spec.url.clone().with_context(|| {
        format!(
            "agent `{}` is kind `workshop` but has no url; set it to the box's address, e.g. http://box.tailnet.ts.net:3002",
            spec.name
        )
    })?;
    let base = normalize_base(&raw)?;
    let token = spec.token.clone().unwrap_or_default();
    if token.is_empty() {
        bail!(
            "agent `{}` has no API token stored; metalcraft-agent rejects unauthenticated requests, so add its API key before connecting",
            spec.name
        );
    }

    let http = Client::builder()
        .user_agent(concat!("remote-craft/", env!("CARGO_PKG_VERSION")))
        .build()
        .context("building the HTTP client")?;

    // `/info` is the probe: it proves the address resolves, the port is open
    // and the token is accepted, before any chat state exists to clean up.
    let response = http
        .get(format!("{base}/info"))
        .bearer_auth(&token)
        .timeout(CALL_TIMEOUT)
        .send()
        .await
        .with_context(|| {
            format!("reaching {base}/info; is metalcraft-agent running on that box?")
        })?;
    let info = decode(response, "asking the agent who it is").await?;
    let _ = ui.send(Msg::AgentConnected {
        agent: info
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or(&spec.name)
            .to_string(),
        detail: format!(
            "{} · {base}",
            info.get("version")
                .and_then(Value::as_str)
                .unwrap_or("unknown version")
        ),
    });

    let response = http
        .post(format!("{base}/chats"))
        .bearer_auth(&token)
        .json(&json!({ "agent_preset": "general-agent" }))
        .timeout(CALL_TIMEOUT)
        .send()
        .await
        .with_context(|| format!("creating a chat at {base}/chats"))?;
    let chat = decode(response, "creating a chat").await?;
    let chat_id = identifier(&chat).context(
        "the agent created a chat without an id; this client needs a metalcraft-agent that returns {id} from POST /chats",
    )?;
    let _ = ui.send(Msg::AgentSession {
        id: chat_id.clone(),
    });

    // One sender stays here for the whole run so `rx.recv()` can never return
    // None and disable the select arm.
    let (tx, mut rx) = unbounded_channel::<Wire>();
    let mut watch: Option<JoinHandle<()>> = Some(start_watch(
        http.clone(),
        base.clone(),
        token.clone(),
        chat_id.clone(),
        tx.clone(),
    ));
    let mut turn: Option<JoinHandle<()>> = None;
    let mut queued: VecDeque<String> = VecDeque::new();

    loop {
        tokio::select! {
            wire = rx.recv() => {
                let Some(wire) = wire else { break };
                match wire {
                    Wire::Frame(frame) => {
                        for msg in map_frame(&frame) {
                            let _ = ui.send(msg);
                        }
                    }
                    Wire::TurnEnded => {
                        turn = None;
                        match queued.pop_front() {
                            Some(text) => {
                                turn = Some(start_turn(
                                    http.clone(),
                                    base.clone(),
                                    token.clone(),
                                    chat_id.clone(),
                                    text,
                                    ui.clone(),
                                    tx.clone(),
                                ));
                            }
                            // Nothing of ours is running, so go back to
                            // watching: the agent can start a turn on its own.
                            None => {
                                watch = Some(start_watch(
                                    http.clone(),
                                    base.clone(),
                                    token.clone(),
                                    chat_id.clone(),
                                    tx.clone(),
                                ));
                            }
                        }
                    }
                }
            }
            cmd = commands.recv() => {
                let Some(cmd) = cmd else { break };
                match cmd {
                    // `Answer` exists for ACP's permission gate. Workshop asks
                    // its questions as `reply{awaiting_reply:true}`, and the
                    // answer to one of those is simply the next message.
                    AgentCmd::Prompt(text) | AgentCmd::Answer { choice: text, .. } => {
                        if turn.is_some() {
                            queued.push_back(text);
                            let _ = ui.send(Msg::log(
                                Scope::Agent,
                                "queued until the running turn finishes",
                            ));
                        } else {
                            // The watch would otherwise deliver every frame of
                            // this turn a second time.
                            if let Some(handle) = watch.take() {
                                handle.abort();
                            }
                            turn = Some(start_turn(
                                http.clone(),
                                base.clone(),
                                token.clone(),
                                chat_id.clone(),
                                text,
                                ui.clone(),
                                tx.clone(),
                            ));
                        }
                    }
                    AgentCmd::Cancel => {
                        // Fire and forget: the turn is over when a `done`
                        // frame says so, never because /interrupt answered.
                        let interrupt = http
                            .post(format!("{base}/chats/{chat_id}/interrupt"))
                            .bearer_auth(&token)
                            .timeout(CALL_TIMEOUT)
                            .send();
                        let ui = ui.clone();
                        tokio::spawn(async move {
                            match interrupt.await {
                                Ok(response) if response.status().is_success() => {
                                    let _ = ui.send(Msg::log(Scope::Agent, "interrupt sent"));
                                }
                                Ok(response) => fail(
                                    &ui,
                                    Scope::Agent,
                                    format!("the agent refused to interrupt: HTTP {}", response.status().as_u16()),
                                ),
                                Err(error) => fail(
                                    &ui,
                                    Scope::Agent,
                                    format!("sending the interrupt: {error}"),
                                ),
                            }
                        });
                    }
                    AgentCmd::Close => break,
                }
            }
        }
    }

    if let Some(handle) = watch.take() {
        handle.abort();
    }
    if let Some(handle) = turn.take() {
        handle.abort();
    }
    Ok(())
}

/// Accept the three shapes an operator will actually type: a bare host, a
/// host with scheme and port, and a URL that already ends in `/api/v1`.
///
/// The port is only defaulted for `http`, because a `https://` URL without a
/// port means 443 and adding 3002 to it would be a surprise, not a service.
pub fn normalize_base(raw: &str) -> Result<String> {
    let trimmed = raw.trim().trim_end_matches('/');
    if trimmed.is_empty() {
        bail!(
            "the agent's url is empty; set it to the box's address, e.g. http://box.tailnet.ts.net:3002"
        );
    }

    let (scheme, rest) = match trimmed.split_once("://") {
        Some((scheme, rest)) => (scheme.to_string(), rest.to_string()),
        None => ("http".to_string(), trimmed.to_string()),
    };
    if rest.is_empty() {
        bail!("the agent's url has a scheme but no host: `{raw}`");
    }

    let (authority, path) = match rest.find('/') {
        Some(index) => (
            rest[..index].to_string(),
            rest[index..].trim_end_matches('/').to_string(),
        ),
        None => (rest, String::new()),
    };

    // `[::1]:3002` has a port; `[::1]` does not, and both contain colons.
    let has_port = match authority.rfind(']') {
        Some(bracket) => authority[bracket + 1..].starts_with(':'),
        None => authority.contains(':'),
    };
    let authority = if has_port || scheme != "http" {
        authority
    } else {
        format!("{authority}:{DEFAULT_PORT}")
    };

    let path = if path.ends_with("/api/v1") {
        path
    } else {
        format!("{path}/api/v1")
    };

    Ok(format!("{scheme}://{authority}{path}"))
}

/// Read a JSON body, turning the two failures an operator can actually fix —
/// a bad token and a refused request — into sentences instead of numbers.
async fn decode(response: Response, what: &str) -> Result<Value> {
    let status = response.status();
    if status == StatusCode::UNAUTHORIZED || status == StatusCode::FORBIDDEN {
        bail!(
            "{what}: metalcraft-agent rejected the API token (HTTP {}); the stored token is not the box's current API key",
            status.as_u16()
        );
    }
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        let detail = summarize(&body);
        bail!("{what}: HTTP {}{detail}", status.as_u16());
    }
    response
        .json::<Value>()
        .await
        .with_context(|| format!("{what}: the response was not JSON"))
}

/// Start (and keep) the idle watch stream, so a turn the agent begins on its
/// own — a scheduled job, another client — still shows up here.
fn start_watch(
    http: Client,
    base: String,
    token: String,
    chat: String,
    tx: UnboundedSender<Wire>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let url = format!("{base}/chats/{chat}/events");
        loop {
            let opened = http
                .get(&url)
                .bearer_auth(&token)
                .header(ACCEPT, "text/event-stream")
                .send()
                .await;
            if let Ok(response) = opened
                && response.status().is_success()
            {
                // `done` is not terminal here: the watch outlives every turn.
                let _ = pump(response, &tx, false).await;
            }
            if tx.is_closed() {
                return;
            }
            tokio::time::sleep(WATCH_RETRY).await;
        }
    })
}

/// Send one prompt and consume whichever of the two response shapes comes
/// back. Always ends with `Wire::TurnEnded`, and always makes sure the UI sees
/// a turn end even when the request never got off the ground.
fn start_turn(
    http: Client,
    base: String,
    token: String,
    chat: String,
    text: String,
    ui: Ui,
    tx: UnboundedSender<Wire>,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let sent = http
            .post(format!("{base}/chats/{chat}/turn"))
            .bearer_auth(&token)
            .header(ACCEPT, "text/event-stream")
            .json(&json!({ "message": text }))
            .send()
            .await;

        match sent {
            Ok(response) if response.status() == StatusCode::OK => {
                // 200: the body *is* the stream for this turn.
                if let Err(error) = pump(response, &tx, true).await {
                    fail(&ui, Scope::Agent, format!("{error:#}"));
                    let _ = tx.send(Wire::Frame(json!({ "kind": "done", "status": "failed" })));
                }
            }
            Ok(response) if response.status() == StatusCode::ACCEPTED => {
                // 202: the agent was busy. The frames for this turn will come
                // out of the watch stream, which TurnEnded restarts below.
                let queued = response.json::<Value>().await.unwrap_or(Value::Null);
                let position = queued
                    .get("position")
                    .map(|position| position.to_string())
                    .unwrap_or_else(|| "?".to_string());
                let _ = ui.send(Msg::log(
                    Scope::Agent,
                    format!("the agent is busy; this turn is queued at position {position}"),
                ));
            }
            Ok(response) => {
                let status = response.status();
                let body = response.text().await.unwrap_or_default();
                let detail = summarize(&body);
                let error = if status == StatusCode::UNAUTHORIZED || status == StatusCode::FORBIDDEN
                {
                    format!(
                        "sending the prompt: metalcraft-agent rejected the API token (HTTP {}); the stored token is not the box's current API key",
                        status.as_u16()
                    )
                } else {
                    format!("sending the prompt: HTTP {}{detail}", status.as_u16())
                };
                fail(&ui, Scope::Agent, error);
                let _ = tx.send(Wire::Frame(json!({ "kind": "done", "status": "failed" })));
            }
            Err(error) => {
                fail(&ui, Scope::Agent, format!("sending the prompt: {error}"));
                let _ = tx.send(Wire::Frame(json!({ "kind": "done", "status": "failed" })));
            }
        }

        let _ = tx.send(Wire::TurnEnded);
    })
}

/// Read an SSE body to its end, forwarding every decodable frame.
async fn pump(response: Response, tx: &UnboundedSender<Wire>, stop_on_done: bool) -> Result<()> {
    // `bytes_stream` (the `stream` feature) is not Unpin, so it has to be
    // pinned before `StreamExt::next` will touch it.
    let mut stream = Box::pin(response.bytes_stream());
    let mut buffer = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.context("reading the agent's event stream")?;
        buffer.extend_from_slice(&chunk);
        for frame in take_frames(&mut buffer) {
            let done = frame.get("kind").and_then(Value::as_str) == Some("done");
            if tx.send(Wire::Frame(frame)).is_err() {
                return Ok(());
            }
            if done && stop_on_done {
                return Ok(());
            }
        }
    }
    Ok(())
}

/// Pull every complete SSE frame out of `buffer`, leaving a partial line
/// behind. Keep-alive comments (`:`), blank separators and any field other
/// than `data:` are dropped, and so is anything that will not decode — a new
/// frame kind must never take the stream down.
fn take_frames(buffer: &mut Vec<u8>) -> Vec<Value> {
    let mut frames = Vec::new();
    while let Some(index) = buffer.iter().position(|byte| *byte == b'\n') {
        let raw: Vec<u8> = buffer.drain(..=index).collect();
        let line = String::from_utf8_lossy(&raw[..raw.len() - 1]);
        let line = line.trim_end_matches('\r');
        if line.is_empty() || line.starts_with(':') {
            continue;
        }
        let Some(payload) = line.strip_prefix("data:") else {
            continue;
        };
        let payload = payload.trim();
        if payload.is_empty() || payload == "[DONE]" {
            continue;
        }
        if let Ok(value) = serde_json::from_str::<Value>(payload) {
            frames.push(value);
        }
    }
    frames
}

/// The frame → `Msg` table. Pure, so the mapping can be tested without a
/// server; an unmapped `kind` yields nothing at all.
fn map_frame(frame: &Value) -> Vec<Msg> {
    let kind = frame
        .get("kind")
        .and_then(Value::as_str)
        .unwrap_or_default();
    match kind {
        // `reply.content` is the user-visible answer. `llm_completed` carries
        // the raw model output and must never be shown in its place.
        "reply" => vec![Msg::AgentReply {
            text: frame
                .get("content")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
            awaiting: frame
                .get("awaiting_reply")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            options: frame
                .get("options")
                .and_then(Value::as_array)
                .map(|options| {
                    options
                        .iter()
                        .map(|option| match option.as_str() {
                            Some(text) => text.to_string(),
                            None => option.to_string(),
                        })
                        .collect()
                })
                .unwrap_or_default(),
        }],
        "tool_started" => vec![Msg::AgentTool {
            id: tool_id(frame),
            name: tool_name(frame),
            state: ToolState::Started,
            detail: summary(frame.get("args")),
        }],
        "tool_completed" => {
            let failed = frame.get("error").is_some_and(|error| !error.is_null())
                || frame.get("success").and_then(Value::as_bool) == Some(false);
            let mut detail = summary(frame.get("result"));
            if let Some(ms) = frame.get("duration_ms").and_then(Value::as_u64) {
                detail = if detail.is_empty() {
                    format!("{ms}ms")
                } else {
                    format!("{detail} ({ms}ms)")
                };
            }
            vec![Msg::AgentTool {
                id: tool_id(frame),
                name: tool_name(frame),
                state: if failed {
                    ToolState::Failed
                } else {
                    ToolState::Completed
                },
                detail,
            }]
        }
        "plan" => vec![Msg::AgentPlan {
            steps: frame
                .get("steps")
                .and_then(Value::as_array)
                .map(|steps| {
                    steps
                        .iter()
                        .map(|step| match step.as_str() {
                            Some(text) => text.to_string(),
                            None => summary(Some(step)),
                        })
                        .collect()
                })
                .unwrap_or_default(),
        }],
        "phase" => vec![Msg::log(
            Scope::Agent,
            format!(
                "phase: {}",
                frame
                    .get("phase")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown")
            ),
        )],
        "queued" => vec![Msg::log(
            Scope::Agent,
            format!(
                "queued at position {}",
                frame
                    .get("position")
                    .map(|position| position.to_string())
                    .unwrap_or_else(|| "?".to_string())
            ),
        )],
        "injected" => vec![Msg::log(
            Scope::Agent,
            "a message was injected into the turn",
        )],
        "error" => {
            let message = frame
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("the agent reported an error with no message");
            let code = frame
                .get("code")
                .and_then(Value::as_str)
                .map(|code| format!(" [{code}]"))
                .unwrap_or_default();
            let mut msgs = vec![Msg::Failed {
                scope: Scope::Agent,
                error: format!("{message}{code}"),
            }];
            // A retryable error is followed by more frames and, eventually, a
            // `done`; ending the turn here would unlock the composer early.
            if frame.get("retryable").and_then(Value::as_bool) != Some(true) {
                msgs.push(Msg::AgentTurnEnd {
                    reason: "failed".into(),
                });
            }
            msgs
        }
        "done" => {
            let reason = frame
                .get("status")
                .and_then(Value::as_str)
                .unwrap_or("completed")
                .to_string();
            let mut msgs = Vec::new();
            if let Some(detail) = frame.get("reason").and_then(Value::as_str)
                && !detail.is_empty()
            {
                msgs.push(Msg::log(Scope::Agent, format!("turn ended: {detail}")));
            }
            msgs.push(Msg::AgentTurnEnd { reason });
            msgs
        }
        // turn_started, llm_started, llm_completed and whatever ships next
        // week: nothing the transcript needs, and never an error.
        _ => Vec::new(),
    }
}

fn tool_id(frame: &Value) -> String {
    frame
        .get("tool_call_id")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn tool_name(frame: &Value) -> String {
    frame
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("tool")
        .to_string()
}

/// Chat ids have been both strings and numbers across versions; either is fine
/// as long as it round-trips into a URL.
fn identifier(value: &Value) -> Option<String> {
    let id = value.get("id")?;
    match id {
        Value::String(text) if !text.is_empty() => Some(text.clone()),
        Value::Number(number) => Some(number.to_string()),
        _ => None,
    }
}

/// One bounded, single-line digest of arbitrary JSON for a tool row.
fn summary(value: Option<&Value>) -> String {
    let Some(value) = value else {
        return String::new();
    };
    let text = match value {
        Value::Null => String::new(),
        Value::String(text) => text.clone(),
        other => match human(other) {
            Some(Value::String(text)) => text.clone(),
            Some(inner) => inner.to_string(),
            None => other.to_string(),
        },
    };
    clamp(&text)
}

/// Pull the readable field out of a wire object before giving up and dumping
/// the whole thing.
///
/// The pod's tool results are a `ChatMessageWire`
/// (`{role, id, name, result}`) and its plan steps are a `PlanStep`
/// (`{step, persona, …}`). Serialising those verbatim puts JSON braces in the
/// middle of a conversation, which is the difference between a client and a
/// packet dump. Anything without a known field still falls back to the object,
/// because a visible unknown beats a silent empty row.
fn human(value: &Value) -> Option<&Value> {
    const KEYS: [&str; 6] = ["result", "step", "command", "content", "text", "message"];
    let object = value.as_object()?;
    KEYS.iter()
        .find_map(|key| object.get(*key))
        .filter(|found| !found.is_null())
}

/// The same, for an error body that may be HTML, JSON or a stack trace.
fn summarize(body: &str) -> String {
    let flat = clamp(body);
    if flat.is_empty() {
        String::new()
    } else {
        format!(" — {flat}")
    }
}

fn clamp(text: &str) -> String {
    let flat = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if flat.chars().count() > 160 {
        let cut: String = flat.chars().take(157).collect();
        format!("{cut}...")
    } else {
        flat
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_bare_host_gets_scheme_port_and_prefix() {
        assert_eq!(
            normalize_base("box.tailnet.ts.net").unwrap(),
            "http://box.tailnet.ts.net:3002/api/v1"
        );
    }

    #[test]
    fn a_scheme_and_port_only_gains_the_prefix() {
        assert_eq!(
            normalize_base("http://box:3002").unwrap(),
            "http://box:3002/api/v1"
        );
    }

    #[test]
    fn an_already_prefixed_url_is_left_alone() {
        assert_eq!(
            normalize_base("http://box:3002/api/v1/").unwrap(),
            "http://box:3002/api/v1"
        );
        assert_eq!(
            normalize_base("http://box:3002/api/v1").unwrap(),
            "http://box:3002/api/v1"
        );
    }

    #[test]
    fn https_keeps_its_default_port() {
        assert_eq!(
            normalize_base("https://workshop.example.com/api/v1").unwrap(),
            "https://workshop.example.com/api/v1"
        );
    }

    #[test]
    fn ipv6_literals_are_not_mistaken_for_a_port() {
        assert_eq!(
            normalize_base("http://[::1]").unwrap(),
            "http://[::1]:3002/api/v1"
        );
        assert_eq!(
            normalize_base("http://[::1]:3002").unwrap(),
            "http://[::1]:3002/api/v1"
        );
    }

    #[test]
    fn an_empty_url_names_what_to_type() {
        let error = normalize_base("   ").unwrap_err().to_string();
        assert!(error.contains("3002"), "{error}");
    }

    #[test]
    fn frames_survive_keepalives_blanks_and_junk() {
        let mut buffer = Vec::new();
        buffer.extend_from_slice(
            b": keep-alive\n\
              \n\
              data: {\"kind\":\"reply\",\"content\":\"hi\"}\n\
              \n\
              data: not json at all\n\
              event: ignored\n\
              data: {\"kind\":\"mystery_meat\",\"x\":1}\n",
        );
        let frames = take_frames(&mut buffer);
        assert_eq!(frames.len(), 2, "{frames:?}");
        assert_eq!(frames[0]["kind"], "reply");
        assert_eq!(frames[1]["kind"], "mystery_meat");
        assert!(buffer.is_empty());
    }

    #[test]
    fn a_partial_frame_waits_for_its_newline() {
        let mut buffer = Vec::new();
        buffer.extend_from_slice(b"data: {\"kind\":\"re");
        assert!(take_frames(&mut buffer).is_empty());
        buffer.extend_from_slice(b"ply\",\"content\":\"hi\"}\n");
        let frames = take_frames(&mut buffer);
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0]["content"], "hi");
    }

    #[test]
    fn an_unknown_kind_maps_to_nothing() {
        assert!(map_frame(&json!({ "kind": "mystery_meat" })).is_empty());
        assert!(map_frame(&json!({ "kind": "llm_completed", "content": "raw" })).is_empty());
        assert!(map_frame(&json!({})).is_empty());
    }

    #[test]
    fn a_reply_carries_its_options_and_awaiting_flag() {
        let msgs = map_frame(&json!({
            "kind": "reply",
            "content": "pick one",
            "awaiting_reply": true,
            "options": ["yes", "no"],
        }));
        match &msgs[..] {
            [
                Msg::AgentReply {
                    text,
                    awaiting,
                    options,
                },
            ] => {
                assert_eq!(text, "pick one");
                assert!(*awaiting);
                assert_eq!(options, &vec!["yes".to_string(), "no".to_string()]);
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_failed_tool_completion_is_not_a_success() {
        let msgs = map_frame(&json!({
            "kind": "tool_completed",
            "tool_call_id": "t1",
            "name": "shell",
            "duration_ms": 12,
            "error": "boom",
        }));
        match &msgs[..] {
            [
                Msg::AgentTool {
                    id,
                    name,
                    state,
                    detail,
                },
            ] => {
                assert_eq!(id, "t1");
                assert_eq!(name, "shell");
                assert_eq!(*state, ToolState::Failed);
                assert!(detail.contains("12ms"), "{detail}");
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_tool_result_shows_its_text_not_the_wire_object() {
        // The pod wraps results in a ChatMessageWire. Rendering the envelope
        // puts `{"role":"tool_result",…}` in the transcript.
        let msgs = map_frame(&json!({
            "kind": "tool_completed",
            "tool_call_id": "t1",
            "name": "bash",
            "result": { "role": "tool_result", "id": "t1", "name": "bash", "result": "3 files" },
        }));
        match &msgs[..] {
            [Msg::AgentTool { detail, .. }] => {
                assert!(detail.starts_with("3 files"), "{detail}");
                assert!(!detail.contains("tool_result"), "{detail}");
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn plan_steps_show_their_step_text() {
        let msgs = map_frame(&json!({
            "kind": "plan",
            "steps": [{ "step": "look around", "persona": "orchestrator-agent" }, "answer"],
        }));
        match &msgs[..] {
            [Msg::AgentPlan { steps }] => assert_eq!(steps, &["look around", "answer"]),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn an_object_with_no_readable_field_is_still_shown() {
        let msgs = map_frame(&json!({
            "kind": "tool_started",
            "tool_call_id": "t2",
            "name": "weird",
            "args": { "shape": 3 },
        }));
        match &msgs[..] {
            [Msg::AgentTool { detail, .. }] => assert!(detail.contains("shape"), "{detail}"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn done_ends_the_turn_and_a_retryable_error_does_not() {
        match &map_frame(&json!({ "kind": "done", "status": "completed" }))[..] {
            [Msg::AgentTurnEnd { reason }] => assert_eq!(reason, "completed"),
            other => panic!("{other:?}"),
        }
        let retryable = map_frame(&json!({
            "kind": "error",
            "code": "rate_limit",
            "message": "slow down",
            "retryable": true,
        }));
        assert_eq!(retryable.len(), 1);
        assert!(matches!(retryable[0], Msg::Failed { .. }));

        let fatal = map_frame(&json!({ "kind": "error", "message": "no" }));
        assert_eq!(fatal.len(), 2);
        assert!(matches!(fatal[1], Msg::AgentTurnEnd { .. }));
    }
}
