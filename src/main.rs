//! remote-craft — a thin client for a box you are not sitting at.
//!
//! Two things, one binary: an SSH terminal onto an Omarchy machine over a
//! tailnet, and a chat surface onto whatever coding agent is running there.
//! The interesting decision is that both ride the same SSH connection, because
//! the agents worth talking to either have no network protocol at all (OMP
//! speaks only over stdio; starkbot-neo speaks only by exiting) or have one
//! that is already reachable over the tailnet without our help.

mod acp;
mod agent;
mod app;
mod config;
mod creds;
mod editor;
mod event;
mod ssh;
mod term;
mod ui;
mod workshop;

use std::io::{self, IsTerminal, Read, Write, stdout};
use std::time::Duration;

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use crossterm::event::{DisableBracketedPaste, EnableBracketedPaste, Event};
use crossterm::execute;
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;

#[derive(Parser)]
#[command(
    name = "rcraft",
    version,
    about = "Remote terminal and agent client for Omarchy boxes over Tailscale"
)]
struct Cli {
    /// Connect to this host on startup.
    #[arg(long, value_name = "NAME")]
    host: Option<String>,
    /// Open this agent on startup.
    #[arg(long, value_name = "NAME")]
    agent: Option<String>,
    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// List the configured hosts and agents.
    Hosts,
    /// Store an agent's bearer token, read from stdin.
    ///
    /// Pipe it (`pass show pod | rcraft token mypod`) rather than typing it:
    /// there is no hidden-input prompt here, and a token typed at a shell ends
    /// up in the history file.
    Token {
        /// The agent name, as it appears in config.json.
        agent: String,
    },
    /// Store the passphrase for an encrypted SSH key, read from stdin.
    Passphrase {
        /// Path to the private key, exactly as written in config.json.
        key: String,
    },
    /// Forget a stored secret.
    Forget {
        /// `agent:<name>` or `key:<path>`.
        account: String,
    },
}

fn main() {
    if let Err(error) = run() {
        eprintln!("rcraft: {error}");
        for cause in error.chain().skip(1) {
            eprintln!("  caused by: {cause}");
        }
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Some(Command::Hosts) => list(),
        Some(Command::Token { agent }) => store(&format!("agent:{agent}"), "token"),
        Some(Command::Passphrase { key }) => store(&format!("key:{key}"), "passphrase"),
        Some(Command::Forget { account }) => {
            creds::delete(&account)?;
            println!("forgot {account}");
            Ok(())
        }
        None => tui(cli.host.as_deref(), cli.agent.as_deref()),
    }
}

fn list() -> Result<()> {
    let config = config::load()?;
    if config.hosts.is_empty() && config.agents.is_empty() {
        println!("nothing configured — write {}", config::path().display());
        return Ok(());
    }
    for (name, host) in &config.hosts {
        let identity = match &host.identity {
            Some(path) => path.display().to_string(),
            None => "ssh-agent".to_string(),
        };
        println!(
            "host   {name:<16} {}@{}:{}  {identity}",
            host.user, host.addr, host.port
        );
    }
    for (name, agent) in &config.agents {
        let token = match creds::get(&format!("agent:{name}")) {
            Some((secret, store)) => format!("{} in {}", creds::redact(&secret), store.describe()),
            None => "no token".to_string(),
        };
        println!(
            "agent  {name:<16} {:?} {}  {token}",
            agent.kind,
            agent
                .host
                .as_deref()
                .or(agent.url.as_deref())
                .unwrap_or("?")
        );
    }
    Ok(())
}

/// Read one secret from stdin. Refusing an interactive terminal is deliberate:
/// a value typed here would be echoed, and an echoed secret is a leaked one.
fn store(account: &str, label: &str) -> Result<()> {
    if io::stdin().is_terminal() {
        bail!("pipe the {label} in on stdin, e.g. `printf %s \"$SECRET\" | rcraft …`");
    }
    let mut secret = String::new();
    io::stdin()
        .read_to_string(&mut secret)
        .with_context(|| format!("reading the {label} from stdin"))?;
    let secret = secret.trim_end_matches(['\n', '\r']);
    if secret.is_empty() {
        bail!("the {label} was empty");
    }
    let store = creds::set(account, secret)?;
    println!("stored {account} in {}", store.describe());
    Ok(())
}

fn tui(host: Option<&str>, agent: Option<&str>) -> Result<()> {
    let config = config::load()?;
    let size = crossterm::terminal::size().context("measuring the terminal")?;
    let mut app = app::App::new(config, size)?;
    if let Some(name) = host {
        app.open_named(name);
    }
    if let Some(name) = agent {
        app.open_named(name);
    }

    let mut terminal = start()?;
    let _guard = Guard;
    let result = pump(&mut terminal, &mut app);
    app.shutdown();
    result
}

fn pump(terminal: &mut Terminal<CrosstermBackend<io::Stdout>>, app: &mut app::App) -> Result<()> {
    loop {
        app.tick();
        terminal
            .draw(|frame| ui::render(frame, app))
            .context("drawing the terminal")?;
        if app.should_quit {
            return Ok(());
        }
        // 50 ms: fast enough that remote output feels live, slow enough that
        // an idle client is not a space heater.
        if !crossterm::event::poll(Duration::from_millis(50)).context("polling terminal events")? {
            continue;
        }
        match crossterm::event::read().context("reading a terminal event")? {
            Event::Key(key) => app.handle(key),
            Event::Paste(text) => app.paste(&text),
            Event::Resize(cols, rows) => app.resize(cols, rows),
            _ => {}
        }
    }
}

fn start() -> Result<Terminal<CrosstermBackend<io::Stdout>>> {
    enable_raw_mode().context("enabling raw terminal mode")?;
    let mut output = stdout();
    if let Err(error) = execute!(output, EnterAlternateScreen, EnableBracketedPaste) {
        let _ = disable_raw_mode();
        return Err(error).context("entering the alternate screen");
    }
    Terminal::new(CrosstermBackend::new(output)).context("creating the terminal")
}

/// Restoring the terminal has to happen even on a panic: a client that leaves
/// raw mode on has turned the user's shell into a puzzle.
struct Guard;

impl Drop for Guard {
    fn drop(&mut self) {
        let _ = disable_raw_mode();
        let _ = execute!(stdout(), DisableBracketedPaste, LeaveAlternateScreen);
        let _ = stdout().flush();
    }
}
