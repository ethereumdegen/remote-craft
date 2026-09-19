//! All of the client's state, in one struct, owned by the draw loop.
//!
//! The loop is synchronous: `tick` drains whatever the async workers posted,
//! `ui::render` reads these fields directly, `handle` mutates them. Nothing
//! here awaits, locks, or reaches back into a worker except by pushing a
//! command down a channel. That constraint is what keeps a hung SSH connection
//! from freezing the interface — the transport can be wedged and the terminal
//! is still responsive enough to quit.

use std::collections::VecDeque;
use std::sync::mpsc::{self, Receiver, TryRecvError};

use anyhow::{Context, Result};
use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};
use tokio::runtime::Runtime;

use crate::agent;
use crate::config::{self, AgentKind, Config};
use crate::creds;
use crate::editor::Input;
use crate::event::{AgentHandle, LogLine, Msg, Scope, ShellHandle, ToolState, Ui};
use crate::ssh::{self, Target};
use crate::term::{self, Term};

/// How many transport log lines to keep. There is no log file; this ring and
/// the status bar are the entire diagnostic surface, so it has to be long
/// enough to hold a failed connection attempt and short enough to stay cheap.
const LOG_CAP: usize = 500;

/// The prefix key that escapes from the remote terminal, borrowed from screen
/// and tmux because the muscle memory already exists. Without it there is no
/// keystroke left to mean "stop sending keystrokes".
const PREFIX: char = 'a';

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Page {
    Hosts,
    Shell,
    Agent,
    Log,
}

impl Page {
    pub fn title(self) -> &'static str {
        match self {
            Page::Hosts => "HOSTS",
            Page::Shell => "SHELL",
            Page::Agent => "AGENT",
            Page::Log => "LOG",
        }
    }
}

/// Input mode, orthogonal to the page: which widget is eating keys.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// Keys drive the client.
    Normal,
    /// Keys are encoded and sent to the remote PTY.
    Capture,
    /// Keys go into the agent composer.
    Compose,
    /// A modal is waiting on a decision the remote turn is blocked on.
    Permission,
    Help,
}

/// One row on the connection screen.
#[derive(Debug, Clone)]
pub enum Entry {
    Host { name: String, detail: String },
    Agent { name: String, detail: String },
}

impl Entry {
    pub fn name(&self) -> &str {
        match self {
            Entry::Host { name, .. } | Entry::Agent { name, .. } => name,
        }
    }

    pub fn detail(&self) -> &str {
        match self {
            Entry::Host { detail, .. } | Entry::Agent { detail, .. } => detail,
        }
    }
}

/// One rendered unit of the agent conversation.
#[derive(Debug, Clone)]
pub enum Block {
    User(String),
    Assistant(String),
    Thought(String),
    Tool {
        id: String,
        name: String,
        state: ToolState,
        detail: String,
    },
    Notice(String),
}

/// An outstanding decision. The remote turn is stopped until it is answered,
/// which is why it takes over the whole input mode rather than sitting in a
/// corner waiting to be noticed.
#[derive(Debug, Clone)]
pub struct Permission {
    pub id: String,
    pub prompt: String,
    pub options: Vec<String>,
    pub selected: usize,
}

pub struct App {
    pub config: Config,
    pub page: Page,
    pub mode: Mode,
    pub should_quit: bool,
    pub status: String,
    pub status_is_error: bool,
    /// The last failure, kept whole. The status bar has about a third of one
    /// line; an error that names a command to run does not fit there, and
    /// truncating the command is worse than not showing it.
    pub last_error: Option<String>,

    /// Full terminal size in cells, kept current so a resize can be forwarded
    /// to the remote PTY without asking the backend twice.
    pub size: (u16, u16),

    pub entries: Vec<Entry>,
    pub selected: usize,

    pub term: Term,
    pub shell: Option<ShellHandle>,
    pub shell_host: Option<String>,
    pub shell_live: bool,
    /// The prefix key has been pressed and the next key is a command.
    pub prefix_armed: bool,

    pub agent: Option<AgentHandle>,
    pub agent_name: Option<String>,
    pub agent_session: Option<String>,
    pub agent_busy: bool,
    pub transcript: Vec<Block>,
    pub plan: Vec<String>,
    pub options: Vec<String>,
    pub composer: Input,
    pub permission: Option<Permission>,
    pub scroll: u16,
    pub follow: bool,

    pub log: VecDeque<LogLine>,
    pub log_scroll: usize,

    /// Frame counter for the spinner; only advances while something is in flight.
    pub spin: usize,

    runtime: Runtime,
    ui: Ui,
    inbox: Receiver<Msg>,
}

impl App {
    pub fn new(config: Config, size: (u16, u16)) -> Result<App> {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .context("starting the async runtime")?;
        let (ui, inbox) = mpsc::channel();
        let (cols, rows) = crate::ui::shell_size(size.0, size.1);

        let mut app = App {
            config,
            page: Page::Hosts,
            mode: Mode::Normal,
            should_quit: false,
            status: String::new(),
            status_is_error: false,
            last_error: None,
            size,
            entries: Vec::new(),
            selected: 0,
            term: Term::new(cols, rows),
            shell: None,
            shell_host: None,
            shell_live: false,
            prefix_armed: false,
            agent: None,
            agent_name: None,
            agent_session: None,
            agent_busy: false,
            transcript: Vec::new(),
            plan: Vec::new(),
            options: Vec::new(),
            composer: Input::new(),
            permission: None,
            scroll: 0,
            follow: true,
            log: VecDeque::new(),
            log_scroll: 0,
            spin: 0,
            runtime,
            ui,
            inbox,
        };
        app.reload();
        // Land on the configured default rather than whatever sorts first, so
        // the common case is Enter and nothing else.
        if let Some(name) = app.config.default_host.clone()
            && let Some(index) = app.entries.iter().position(|entry| entry.name() == name)
        {
            app.selected = index;
        }
        Ok(app)
    }

    /// Rebuild the connection list from the config on disk. Cheap, and it means
    /// editing `config.json` in another window shows up on `r`.
    pub fn reload(&mut self) {
        match config::load() {
            Ok(config) => self.config = config,
            Err(error) => {
                self.set_error(error);
                return;
            }
        }
        self.entries = Vec::new();
        for (name, host) in &self.config.hosts {
            self.entries.push(Entry::Host {
                name: name.clone(),
                detail: format!("{}@{}:{}", host.user, host.addr, host.port),
            });
        }
        for (name, spec) in &self.config.agents {
            let detail = match spec.kind {
                AgentKind::Acp => format!(
                    "acp · {} on {}",
                    spec.program(),
                    spec.host.as_deref().unwrap_or("?")
                ),
                AgentKind::Workshop => {
                    format!("workshop · {}", spec.url.as_deref().unwrap_or("?"))
                }
                AgentKind::Exec => format!(
                    "exec · {} on {}",
                    spec.program(),
                    spec.host.as_deref().unwrap_or("?")
                ),
            };
            self.entries.push(Entry::Agent {
                name: name.clone(),
                detail,
            });
        }
        self.selected = self.selected.min(self.entries.len().saturating_sub(1));
        if self.entries.is_empty() {
            self.set_status(format!(
                "no hosts configured — see {}",
                config::path().display()
            ));
        } else {
            self.set_status(format!(
                "{} hosts · {} agents",
                self.config.hosts.len(),
                self.config.agents.len()
            ));
        }
    }

    /// Drain the workers. Called once per frame, before drawing, and it is the
    /// only place a `Msg` is ever consumed.
    pub fn tick(&mut self) {
        loop {
            match self.inbox.try_recv() {
                Ok(msg) => self.apply(msg),
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => break,
            }
        }
        if self.agent_busy || (self.shell.is_some() && !self.shell_live) {
            self.spin = self.spin.wrapping_add(1);
        }
    }

    pub(crate) fn apply(&mut self, msg: Msg) {
        match msg {
            Msg::ShellOpened { host } => {
                self.shell_live = true;
                self.shell_host = Some(host.clone());
                self.set_status(format!("connected to {host}"));
                self.push_log(Scope::Shell, format!("shell open on {host}"));
            }
            Msg::ShellData(bytes) => self.term.feed(&bytes),
            Msg::ShellClosed { reason } => {
                self.shell_live = false;
                self.shell = None;
                self.push_log(Scope::Shell, format!("shell closed: {reason}"));
                // A failed connection posts the useful error first and the channel
                // closing behind it. Overwriting "run this command on the box" with
                // "shell closed" throws away the only sentence that said what to do.
                if !self.status_is_error {
                    self.set_status(format!("shell closed — {reason}"));
                }
                if self.mode == Mode::Capture {
                    self.mode = Mode::Normal;
                }
            }

            Msg::AgentConnected { agent, detail } => {
                self.push_log(Scope::Agent, format!("{agent}: {detail}"));
                self.transcript.push(Block::Notice(detail));
                self.set_status(format!("connected to {agent}"));
            }
            Msg::AgentSession { id } => {
                self.push_log(Scope::Agent, format!("session {id}"));
                self.agent_session = Some(id);
            }
            Msg::AgentDelta { text } => {
                // Streaming text extends the message already being written
                // rather than starting a new bubble every few tokens.
                if let Some(Block::Assistant(existing)) = self.transcript.last_mut() {
                    existing.push_str(&text);
                } else {
                    self.transcript.push(Block::Assistant(text));
                }
                self.stick();
            }
            Msg::AgentThought { text } => {
                if let Some(Block::Thought(existing)) = self.transcript.last_mut() {
                    existing.push_str(&text);
                } else {
                    self.transcript.push(Block::Thought(text));
                }
                self.stick();
            }
            Msg::AgentReply {
                text,
                awaiting,
                options,
            } => {
                self.transcript.push(Block::Assistant(text));
                self.options = options;
                if awaiting {
                    self.agent_busy = false;
                    self.set_status("the agent is waiting on an answer");
                }
                self.stick();
            }
            Msg::AgentTool {
                id,
                name,
                state,
                detail,
            } => {
                // Collapse a completion onto the row its own call started, so a
                // long tool run is one line that changes state. Matching on the
                // call id rather than the name matters the moment an agent runs
                // two `bash` calls at once: by name, the second completion would
                // land on the first row and one call would never resolve.
                let existing = self.transcript.iter_mut().rev().find(|block| {
                    matches!(block, Block::Tool { id: seen, state, .. }
                        if seen == &id && *state == ToolState::Started)
                });
                if let Some(Block::Tool {
                    state: seen_state,
                    detail: seen_detail,
                    ..
                }) = existing
                {
                    *seen_state = state;
                    if !detail.is_empty() {
                        *seen_detail = detail;
                    }
                } else {
                    self.transcript.push(Block::Tool {
                        id,
                        name,
                        state,
                        detail,
                    });
                }
                self.stick();
            }
            Msg::AgentPlan { steps } => self.plan = steps,
            Msg::AgentTurnEnd { reason } => {
                self.agent_busy = false;
                self.set_status(format!("turn {reason}"));
                self.stick();
            }
            Msg::AgentPermission {
                id,
                prompt,
                options,
            } => {
                self.permission = Some(Permission {
                    id,
                    prompt,
                    options,
                    selected: 0,
                });
                self.mode = Mode::Permission;
            }

            Msg::Failed { scope, error } => {
                self.push_log(scope, error.clone());
                if scope == Scope::Agent {
                    self.agent_busy = false;
                }
                self.status = error.clone();
                self.status_is_error = true;
                self.last_error = Some(error);
            }
            Msg::Log(line) => self.push(line),
        }
    }

    fn push_log(&mut self, scope: Scope, text: impl Into<String>) {
        self.push(LogLine {
            scope,
            text: text.into(),
        });
    }

    fn push(&mut self, line: LogLine) {
        self.log.push_front(line);
        self.log.truncate(LOG_CAP);
    }

    /// Keep the transcript pinned to the bottom unless the user scrolled away.
    fn stick(&mut self) {
        if self.follow {
            self.scroll = u16::MAX;
        }
    }

    pub fn set_status(&mut self, text: impl Into<String>) {
        self.status = text.into();
        self.status_is_error = false;
    }

    pub fn set_error(&mut self, error: anyhow::Error) {
        self.status = format!("{error:#}");
        self.status_is_error = true;
    }

    // ---- connection ----------------------------------------------------

    fn connect_host(&mut self, name: &str) {
        let host = match self.config.host(name) {
            Ok(host) => host.clone(),
            Err(error) => return self.set_error(error),
        };
        if let Some(shell) = self.shell.take() {
            shell.close();
        }
        let target = Target::from_host(&host);
        let (cols, rows) = crate::ui::shell_size(self.size.0, self.size.1);
        self.term = Term::new(cols, rows);
        self.shell_live = false;
        self.last_error = None;
        self.shell_host = Some(name.to_string());
        self.set_status(format!("connecting to {}…", target.label()));
        self.shell = Some(ssh::spawn_shell(
            self.runtime.handle(),
            target,
            cols,
            rows,
            self.ui.clone(),
        ));
        self.page = Page::Shell;
        self.mode = Mode::Capture;
        self.prefix_armed = false;
    }

    fn connect_agent(&mut self, name: &str) {
        let spec = match self.build_spec(name) {
            Ok(spec) => spec,
            Err(error) => return self.set_error(error),
        };
        if let Some(agent) = self.agent.take() {
            agent.close();
        }
        self.transcript.clear();
        self.plan.clear();
        self.options.clear();
        self.agent_session = None;
        self.agent_busy = false;
        self.agent_name = Some(name.to_string());
        self.set_status(format!("connecting to {name}…"));
        self.agent = Some(agent::spawn(self.runtime.handle(), spec, self.ui.clone()));
        self.page = Page::Agent;
        self.mode = Mode::Normal;
        self.follow = true;
    }

    fn build_spec(&self, name: &str) -> Result<agent::Spec> {
        let spec = self.config.agent(name)?;
        let target = match spec.kind {
            AgentKind::Workshop => None,
            _ => Some(Target::from_host(self.config.agent_host(spec)?)),
        };
        // The Workshop bearer never lives in config.json; it is looked up per
        // agent so two pods can hold different keys.
        let token = creds::get(&format!("agent:{name}")).map(|(secret, _)| secret);
        Ok(agent::Spec {
            name: name.to_string(),
            kind: spec.kind,
            target,
            url: spec.url.clone(),
            token,
            cwd: spec.cwd.clone(),
            program: spec.program().to_string(),
            args: spec.args.clone(),
            yolo: spec.yolo,
        })
    }

    fn open_selected(&mut self) {
        let Some(entry) = self.entries.get(self.selected).cloned() else {
            return;
        };
        match entry {
            Entry::Host { name, .. } => self.connect_host(&name),
            Entry::Agent { name, .. } => self.connect_agent(&name),
        }
    }

    /// Open a host or agent by name, for `--host` / `--agent` on the command
    /// line. Selecting the row first means the list lands on it too.
    pub fn open_named(&mut self, name: &str) {
        let Some(index) = self.entries.iter().position(|entry| entry.name() == name) else {
            self.status = format!("no host or agent named “{name}”");
            self.status_is_error = true;
            return;
        };
        self.selected = index;
        self.open_selected();
    }

    // ---- input ----------------------------------------------------------

    pub fn resize(&mut self, cols: u16, rows: u16) {
        self.size = (cols, rows);
        let (pane_cols, pane_rows) = crate::ui::shell_size(cols, rows);
        self.term.resize(pane_cols, pane_rows);
        if let Some(shell) = &self.shell {
            shell.resize(pane_cols, pane_rows);
        }
    }

    pub fn handle(&mut self, key: KeyEvent) {
        if !matches!(key.kind, KeyEventKind::Press | KeyEventKind::Repeat) {
            return;
        }
        match self.mode {
            Mode::Capture => self.handle_capture(key),
            Mode::Compose => self.handle_compose(key),
            Mode::Permission => self.handle_permission(key),
            Mode::Help => {
                self.mode = if self.shell_live && self.page == Page::Shell {
                    Mode::Capture
                } else {
                    Mode::Normal
                };
            }
            Mode::Normal => self.handle_normal(key),
        }
    }

    pub fn paste(&mut self, text: &str) {
        match self.mode {
            Mode::Capture => {
                if let Some(shell) = &self.shell {
                    shell.bytes(term::encode_paste(text, self.term.screen()));
                }
            }
            Mode::Compose => self.composer.insert_str(text),
            _ => {}
        }
    }

    fn handle_normal(&mut self, key: KeyEvent) {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Char('c') if ctrl => self.should_quit = true,
            KeyCode::Char('q') => self.should_quit = true,
            KeyCode::Char('?') => self.mode = Mode::Help,
            KeyCode::Tab => self.cycle_page(),
            _ => match self.page {
                Page::Hosts => self.handle_hosts(key),
                Page::Shell => self.handle_shell(key),
                Page::Agent => self.handle_agent(key),
                Page::Log => self.handle_log(key),
            },
        }
    }

    fn cycle_page(&mut self) {
        self.page = match self.page {
            Page::Hosts => Page::Shell,
            Page::Shell => Page::Agent,
            Page::Agent => Page::Log,
            Page::Log => Page::Hosts,
        };
        self.set_status(self.page.title().to_lowercase());
    }

    fn handle_hosts(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Char('j') | KeyCode::Down => {
                self.selected = (self.selected + 1).min(self.entries.len().saturating_sub(1));
            }
            KeyCode::Char('k') | KeyCode::Up => self.selected = self.selected.saturating_sub(1),
            KeyCode::Char('g') | KeyCode::Home => self.selected = 0,
            KeyCode::Char('G') | KeyCode::End => {
                self.selected = self.entries.len().saturating_sub(1);
            }
            KeyCode::Enter | KeyCode::Right => self.open_selected(),
            KeyCode::Char('r') => self.reload(),
            _ => {}
        }
    }

    fn handle_shell(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Enter | KeyCode::Char('i') => {
                if self.shell.is_some() {
                    self.mode = Mode::Capture;
                    self.set_status(format!(
                        "keys go to the remote shell — ctrl+{PREFIX} d to detach"
                    ));
                } else {
                    self.set_status("no shell — pick a host first");
                }
            }
            KeyCode::Esc | KeyCode::Left => {
                self.page = Page::Hosts;
            }
            KeyCode::Char('x') => {
                if let Some(shell) = self.shell.take() {
                    shell.close();
                    self.shell_live = false;
                    self.set_status("shell closed");
                }
            }
            _ => {}
        }
    }

    fn handle_capture(&mut self, key: KeyEvent) {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        if self.prefix_armed {
            self.prefix_armed = false;
            match key.code {
                // Send a literal prefix through, the screen/tmux convention.
                KeyCode::Char(PREFIX) => {
                    if let Some(shell) = &self.shell {
                        shell.bytes(vec![0x01]);
                    }
                }
                KeyCode::Char('d') => {
                    self.mode = Mode::Normal;
                    self.page = Page::Hosts;
                    self.set_status("detached — the shell is still open");
                }
                KeyCode::Char('q') => self.should_quit = true,
                KeyCode::Char('?') => self.mode = Mode::Help,
                KeyCode::Tab => {
                    self.mode = Mode::Normal;
                    self.cycle_page();
                }
                _ => self.set_status("prefix: d detach · a literal · tab pane · q quit"),
            }
            return;
        }
        if ctrl && key.code == KeyCode::Char(PREFIX) {
            self.prefix_armed = true;
            return;
        }
        let Some(shell) = &self.shell else {
            self.mode = Mode::Normal;
            self.set_status("the shell is gone — pick a host to reconnect");
            return;
        };
        if let Some(bytes) = term::encode_key(&key, self.term.screen()) {
            shell.bytes(bytes);
        }
    }

    fn handle_agent(&mut self, key: KeyEvent) {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        match key.code {
            KeyCode::Char('i') | KeyCode::Char('a') => {
                if self.agent.is_some() {
                    self.mode = Mode::Compose;
                } else {
                    self.set_status("no agent — pick one first");
                }
            }
            KeyCode::Esc | KeyCode::Left => self.page = Page::Hosts,
            KeyCode::Char('c') if ctrl => self.interrupt(),
            KeyCode::Char('s') => self.interrupt(),
            KeyCode::Char('j') | KeyCode::Down => {
                self.follow = false;
                self.scroll = self.scroll.saturating_add(1);
            }
            KeyCode::Char('k') | KeyCode::Up => {
                self.follow = false;
                self.scroll = self.scroll.saturating_sub(1);
            }
            KeyCode::Char('G') | KeyCode::End => {
                self.follow = true;
                self.scroll = u16::MAX;
            }
            KeyCode::Char(digit @ '1'..='9') => {
                // The agent offered choices; pick one without typing it out.
                let index = digit as usize - '1' as usize;
                if let Some(option) = self.options.get(index).cloned() {
                    self.send_prompt(option);
                }
            }
            _ => {}
        }
    }

    fn handle_compose(&mut self, key: KeyEvent) {
        let ctrl = key.modifiers.contains(KeyModifiers::CONTROL);
        let alt = key.modifiers.contains(KeyModifiers::ALT);
        match key.code {
            KeyCode::Esc => {
                self.mode = Mode::Normal;
            }
            // Alt+Enter is a newline; plain Enter submits. A multi-line prompt
            // is common enough to need an escape, rare enough not to be default.
            KeyCode::Enter if alt => self.composer.insert('\n'),
            KeyCode::Enter => {
                let text = self.composer.take();
                if text.trim().is_empty() {
                    self.mode = Mode::Normal;
                    return;
                }
                self.send_prompt(text);
                self.mode = Mode::Normal;
            }
            KeyCode::Char('u') if ctrl => self.composer.kill_to_start(),
            KeyCode::Char('w') if ctrl => self.composer.kill_word(),
            KeyCode::Char('c') if ctrl => {
                self.composer.clear();
                self.mode = Mode::Normal;
            }
            KeyCode::Char(value) => self.composer.insert(value),
            KeyCode::Backspace => self.composer.backspace(),
            KeyCode::Delete => self.composer.delete(),
            KeyCode::Left => self.composer.left(),
            KeyCode::Right => self.composer.right(),
            KeyCode::Home => self.composer.home(),
            KeyCode::End => self.composer.end(),
            _ => {}
        }
    }

    fn handle_permission(&mut self, key: KeyEvent) {
        let Some(permission) = &mut self.permission else {
            self.mode = Mode::Normal;
            return;
        };
        match key.code {
            KeyCode::Char('j') | KeyCode::Down | KeyCode::Tab => {
                permission.selected =
                    (permission.selected + 1).min(permission.options.len().saturating_sub(1));
            }
            KeyCode::Char('k') | KeyCode::Up => {
                permission.selected = permission.selected.saturating_sub(1);
            }
            KeyCode::Char(digit @ '1'..='9') => {
                let index = digit as usize - '1' as usize;
                if index < permission.options.len() {
                    permission.selected = index;
                    self.answer_permission();
                }
            }
            KeyCode::Enter => self.answer_permission(),
            KeyCode::Esc => {
                // Refusing is a decision too, and it is the safe one. Leaving
                // the modal without answering would hang the remote turn.
                permission.selected = permission
                    .options
                    .iter()
                    .position(|option| {
                        let lower = option.to_lowercase();
                        lower.contains("deny") || lower.contains("reject") || lower.contains("no")
                    })
                    .unwrap_or(permission.options.len().saturating_sub(1));
                self.answer_permission();
            }
            _ => {}
        }
    }

    fn answer_permission(&mut self) {
        let Some(permission) = self.permission.take() else {
            return;
        };
        let choice = permission
            .options
            .get(permission.selected)
            .cloned()
            .unwrap_or_else(|| "Deny".to_string());
        if let Some(agent) = &self.agent {
            agent.answer(permission.id, choice.clone());
        }
        self.transcript
            .push(Block::Notice(format!("permission: {choice}")));
        self.mode = Mode::Normal;
        self.stick();
    }

    fn send_prompt(&mut self, text: String) {
        let Some(agent) = &self.agent else {
            self.set_status("no agent connected");
            return;
        };
        agent.prompt(text.clone());
        self.transcript.push(Block::User(text));
        self.options.clear();
        self.agent_busy = true;
        self.follow = true;
        self.stick();
        self.set_status("thinking…");
    }

    fn interrupt(&mut self) {
        if let Some(agent) = &self.agent {
            agent.cancel();
            // The composer stays locked: the turn is only over when the agent
            // says so, and an interrupt request is not that confirmation.
            self.set_status("interrupting…");
        }
    }

    fn handle_log(&mut self, key: KeyEvent) {
        match key.code {
            KeyCode::Char('j') | KeyCode::Down => {
                self.log_scroll = (self.log_scroll + 1).min(self.log.len().saturating_sub(1));
            }
            KeyCode::Char('k') | KeyCode::Up => self.log_scroll = self.log_scroll.saturating_sub(1),
            KeyCode::Char('g') | KeyCode::Home => self.log_scroll = 0,
            KeyCode::Char('c') => {
                self.log.clear();
                self.log_scroll = 0;
            }
            KeyCode::Esc | KeyCode::Left => self.page = Page::Hosts,
            _ => {}
        }
    }

    /// Close everything on the way out so the remote side sees a clean
    /// disconnect instead of a dangling channel.
    pub fn shutdown(&mut self) {
        if let Some(shell) = self.shell.take() {
            shell.close();
        }
        if let Some(agent) = self.agent.take() {
            agent.close();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crossterm::event::KeyEvent;

    fn app() -> App {
        App::new(Config::default(), (120, 40)).expect("building the app")
    }

    fn press(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    #[test]
    fn tab_cycles_through_every_page_and_returns() {
        let mut app = app();
        assert_eq!(app.page, Page::Hosts);
        for expected in [Page::Shell, Page::Agent, Page::Log, Page::Hosts] {
            app.handle(press(KeyCode::Tab));
            assert_eq!(app.page, expected);
        }
    }

    #[test]
    fn streamed_deltas_extend_one_message_instead_of_stacking() {
        let mut app = app();
        app.apply(Msg::AgentDelta { text: "hel".into() });
        app.apply(Msg::AgentDelta { text: "lo".into() });
        assert_eq!(app.transcript.len(), 1);
        match &app.transcript[0] {
            Block::Assistant(text) => assert_eq!(text, "hello"),
            other => panic!("expected an assistant block, got {other:?}"),
        }
    }

    #[test]
    fn a_completed_tool_updates_its_own_row() {
        let mut app = app();
        app.apply(Msg::AgentTool {
            id: "1".into(),
            name: "bash".into(),
            state: ToolState::Started,
            detail: "ls".into(),
        });
        app.apply(Msg::AgentTool {
            id: "1".into(),
            name: "bash".into(),
            state: ToolState::Completed,
            detail: "3 files".into(),
        });
        assert_eq!(app.transcript.len(), 1);
        match &app.transcript[0] {
            Block::Tool { state, detail, .. } => {
                assert_eq!(*state, ToolState::Completed);
                assert_eq!(detail, "3 files");
            }
            other => panic!("expected a tool block, got {other:?}"),
        }
    }

    #[test]
    fn two_concurrent_calls_of_the_same_tool_resolve_independently() {
        let mut app = app();
        for id in ["a", "b"] {
            app.apply(Msg::AgentTool {
                id: id.into(),
                name: "bash".into(),
                state: ToolState::Started,
                detail: String::new(),
            });
        }
        // The second call finishes first. Matching by name would resolve row
        // one and leave row two spinning forever.
        app.apply(Msg::AgentTool {
            id: "b".into(),
            name: "bash".into(),
            state: ToolState::Completed,
            detail: "done".into(),
        });
        assert_eq!(app.transcript.len(), 2);
        let states: Vec<ToolState> = app
            .transcript
            .iter()
            .filter_map(|block| match block {
                Block::Tool { state, .. } => Some(*state),
                _ => None,
            })
            .collect();
        assert_eq!(states, vec![ToolState::Started, ToolState::Completed]);
    }

    #[test]
    fn a_permission_request_takes_over_input_until_answered() {
        let mut app = app();
        app.apply(Msg::AgentPermission {
            id: "ui_7".into(),
            prompt: "Allow tool: bash".into(),
            options: vec!["Approve".into(), "Deny".into()],
        });
        assert_eq!(app.mode, Mode::Permission);
        // Escaping a permission must still answer it — an unanswered request
        // hangs the remote turn — and it must answer with the safe option.
        app.handle(press(KeyCode::Esc));
        assert_eq!(app.mode, Mode::Normal);
        assert!(app.permission.is_none());
        match app.transcript.last() {
            Some(Block::Notice(text)) => assert!(text.contains("Deny")),
            other => panic!("expected a deny notice, got {other:?}"),
        }
    }

    #[test]
    fn a_turn_end_unlocks_the_composer_but_an_interrupt_does_not() {
        let mut app = app();
        app.agent_busy = true;
        app.interrupt();
        assert!(app.agent_busy, "an interrupt request is not a turn ending");
        app.apply(Msg::AgentTurnEnd {
            reason: "interrupted".into(),
        });
        assert!(!app.agent_busy);
    }

    #[test]
    fn the_transport_log_is_bounded() {
        let mut app = app();
        for index in 0..LOG_CAP + 50 {
            app.push_log(Scope::Shell, format!("line {index}"));
        }
        assert_eq!(app.log.len(), LOG_CAP);
    }
}
