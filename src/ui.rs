//! Every pixel the client draws, in free functions over `&App`.
//!
//! Rendering never mutates and never decides: if a frame needs a fact, the
//! fact belongs on `App`. The palette is Tokyo Night because that is what the
//! Omarchy box on the other end of the wire is probably wearing, and because a
//! terminal client that does not look like a terminal is lying about what it is.

use ratatui::Frame;
use ratatui::layout::{Alignment, Constraint, Layout, Position, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span, Text};
use ratatui::widgets::{
    Block, BorderType, Borders, Clear, List, ListItem, ListState, Padding, Paragraph, Wrap,
};
use tui_term::widget::PseudoTerminal;

use crate::app::{App, Block as Chunk, Entry, Mode, Page};
use crate::event::{Scope, ToolState};

const BG: Color = Color::Rgb(0x1a, 0x1b, 0x26);
const SURFACE: Color = Color::Rgb(0x1f, 0x23, 0x35);
const LINE: Color = Color::Rgb(0x3b, 0x42, 0x61);
const FAINT: Color = Color::Rgb(0x56, 0x5f, 0x89);
const BODY: Color = Color::Rgb(0xa9, 0xb1, 0xd6);
const INK: Color = Color::Rgb(0xc0, 0xca, 0xf5);
const ACCENT: Color = Color::Rgb(0x7a, 0xa2, 0xf7);
const GREEN: Color = Color::Rgb(0x9e, 0xce, 0x6a);
const YELLOW: Color = Color::Rgb(0xe0, 0xaf, 0x68);
const RED: Color = Color::Rgb(0xf7, 0x76, 0x8e);
const CYAN: Color = Color::Rgb(0x7d, 0xcf, 0xff);
const PURPLE: Color = Color::Rgb(0xbb, 0x9a, 0xf7);

const BRAILLE: [&str; 8] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"];

/// Width at which the agent page earns a plan sidebar.
const WIDE: u16 = 96;

/// The PTY size implied by a terminal of `width` × `height`.
///
/// `app.rs` calls this on every resize to tell the remote side how big its
/// window is, so the arithmetic has to match `render_shell`'s layout exactly:
/// one header row, two footer rows, and the pane's own border.
pub fn shell_size(width: u16, height: u16) -> (u16, u16) {
    (
        width.saturating_sub(2).max(20),
        height.saturating_sub(5).max(5),
    )
}

pub fn render(frame: &mut Frame<'_>, app: &App) {
    frame.render_widget(
        Block::default().style(Style::default().bg(BG)),
        frame.area(),
    );
    let [header, body, footer] = Layout::vertical([
        Constraint::Length(1),
        Constraint::Min(4),
        Constraint::Length(2),
    ])
    .areas(frame.area());

    render_header(frame, header, app);
    match app.page {
        Page::Hosts => render_hosts(frame, body, app),
        Page::Shell => render_shell(frame, body, app),
        Page::Agent => render_agent(frame, body, app),
        Page::Log => render_log(frame, body, app),
    }
    render_footer(frame, footer, app);

    if app.mode == Mode::Permission
        && let Some(permission) = &app.permission
    {
        render_permission(frame, permission);
    }
    if app.mode == Mode::Help {
        render_help(frame);
    }
}

fn render_header(frame: &mut Frame<'_>, area: Rect, app: &App) {
    let mut spans = vec![
        Span::styled(
            " remote-craft ",
            Style::default()
                .bg(ACCENT)
                .fg(BG)
                .add_modifier(Modifier::BOLD),
        ),
        Span::raw(" "),
    ];
    for page in [Page::Hosts, Page::Shell, Page::Agent, Page::Log] {
        let selected = page == app.page;
        spans.push(Span::styled(
            format!(" {} ", page.title()),
            if selected {
                Style::default().fg(INK).add_modifier(Modifier::BOLD)
            } else {
                Style::default().fg(FAINT)
            },
        ));
    }
    spans.push(Span::styled(" · ", Style::default().fg(LINE)));
    match (&app.shell_host, app.shell_live) {
        (Some(host), true) => spans.push(Span::styled(
            format!("● {host}"),
            Style::default().fg(GREEN),
        )),
        (Some(host), false) => spans.push(Span::styled(
            format!("○ {host}"),
            Style::default().fg(YELLOW),
        )),
        (None, _) => spans.push(Span::styled("○ no shell", Style::default().fg(FAINT))),
    }
    if let Some(agent) = &app.agent_name {
        spans.push(Span::styled(" · ", Style::default().fg(LINE)));
        spans.push(Span::styled(
            format!("◆ {agent}"),
            Style::default().fg(if app.agent_busy { YELLOW } else { PURPLE }),
        ));
    }
    frame.render_widget(
        Paragraph::new(Line::from(spans)).style(Style::default().bg(SURFACE)),
        area,
    );
}

fn render_hosts(frame: &mut Frame<'_>, area: Rect, app: &App) {
    if app.entries.is_empty() {
        let text = Text::from(vec![
            Line::from(""),
            Line::styled("Nothing configured yet.", Style::default().fg(INK)),
            Line::from(""),
            Line::styled(
                format!("Write {}", crate::config::path().display()),
                Style::default().fg(BODY),
            ),
            Line::from(""),
            Line::styled(
                r#"{ "hosts": { "box": { "addr": "box.tailnet.ts.net","#,
                Style::default().fg(FAINT),
            ),
            Line::styled(
                r#"    "fallback_addr": "100.64.0.1", "user": "you" } },"#,
                Style::default().fg(FAINT),
            ),
            Line::styled(
                r#"  "agents": { "omp": { "kind": "acp", "host": "box" } } }"#,
                Style::default().fg(FAINT),
            ),
            Line::from(""),
            Line::styled("then press r to reload.", Style::default().fg(BODY)),
        ]);
        frame.render_widget(
            Paragraph::new(text)
                .alignment(Alignment::Center)
                .block(panel(" CONNECT ", ACCENT)),
            area,
        );
        return;
    }

    let items: Vec<ListItem> = app
        .entries
        .iter()
        .map(|entry| {
            let (glyph, colour, kind) = match entry {
                Entry::Host { .. } => ("▸", CYAN, "host"),
                Entry::Agent { .. } => ("◆", PURPLE, "agent"),
            };
            ListItem::new(vec![
                Line::from(vec![
                    Span::styled(format!("{glyph} "), Style::default().fg(colour)),
                    Span::styled(
                        entry.name().to_string(),
                        Style::default().fg(INK).add_modifier(Modifier::BOLD),
                    ),
                    Span::styled(format!("  {kind}"), Style::default().fg(LINE)),
                ]),
                Line::from(Span::styled(
                    format!("   {}", entry.detail()),
                    Style::default().fg(FAINT),
                )),
            ])
        })
        .collect();

    let list = List::new(items)
        .block(panel(" CONNECT ", ACCENT).padding(Padding::new(1, 1, 1, 0)))
        .highlight_style(Style::default().bg(SURFACE))
        .highlight_symbol("▌");
    let mut state = ListState::default().with_selected(Some(app.selected));
    frame.render_stateful_widget(list, area, &mut state);
}

fn render_shell(frame: &mut Frame<'_>, area: Rect, app: &App) {
    let live = app.shell_live;
    let failed = app.shell.is_none() && !live && app.last_error.is_some();
    let title = match (&app.shell_host, live, failed) {
        (Some(host), true, _) => format!(" {host} "),
        (Some(host), false, true) => format!(" {host} — failed "),
        (Some(host), false, false) => format!(" {host} — connecting "),
        (None, _, _) => " SHELL ".to_string(),
    };
    let colour = match (failed, app.shell.is_some(), live, app.mode == Mode::Capture) {
        (true, ..) => RED,
        (_, _, true, true) => GREEN,
        (_, _, true, false) => LINE,
        (_, true, false, _) => YELLOW,
        _ => LINE,
    };
    let block = panel(&title, colour);
    if app.shell.is_none() && !live {
        // The pane is empty anyway, and a connection error is usually a command
        // somebody has to run on the box. This is the only place with the width
        // to print it whole.
        let mut lines = vec![Line::from("")];
        match &app.last_error {
            Some(error) => {
                lines.push(Line::styled(
                    "Could not connect.",
                    Style::default().fg(RED).add_modifier(Modifier::BOLD),
                ));
                lines.push(Line::from(""));
                lines.push(Line::styled(error.clone(), Style::default().fg(BODY)));
            }
            None => {
                lines.push(Line::styled("No shell open.", Style::default().fg(INK)));
                lines.push(Line::from(""));
                lines.push(Line::styled(
                    "Tab back to HOSTS and press Enter on a host.",
                    Style::default().fg(FAINT),
                ));
            }
        }
        frame.render_widget(
            Paragraph::new(Text::from(lines))
                .wrap(Wrap { trim: true })
                .block(block.padding(Padding::new(2, 2, 1, 1))),
            area,
        );
        return;
    }
    let screen = app.term.screen();
    frame.render_widget(PseudoTerminal::new(screen).block(block), area);

    // Put the real cursor where the remote shell thinks it is, so the terminal
    // emulator hosting *us* draws a caret in the right cell.
    if app.mode == Mode::Capture && !screen.hide_cursor() {
        let (row, column) = screen.cursor_position();
        let x = area.x + 1 + column;
        let y = area.y + 1 + row;
        if x < area.right().saturating_sub(1) && y < area.bottom().saturating_sub(1) {
            frame.set_cursor_position(Position::new(x, y));
        }
    }
}

fn render_agent(frame: &mut Frame<'_>, area: Rect, app: &App) {
    let composer_height = if app.mode == Mode::Compose { 4 } else { 3 };
    let [transcript_area, composer_area] =
        Layout::vertical([Constraint::Min(4), Constraint::Length(composer_height)]).areas(area);

    let show_plan = area.width >= WIDE && !app.plan.is_empty();
    let [main, side] = if show_plan {
        Layout::horizontal([Constraint::Min(40), Constraint::Length(34)])
            .spacing(1)
            .areas(transcript_area)
    } else {
        Layout::horizontal([Constraint::Percentage(100), Constraint::Length(0)])
            .areas(transcript_area)
    };

    let mut lines: Vec<Line> = Vec::new();
    for block in &app.transcript {
        match block {
            Chunk::User(text) => {
                lines.push(Line::from(Span::styled(
                    "› you",
                    Style::default().fg(CYAN).add_modifier(Modifier::BOLD),
                )));
                for row in text.lines() {
                    lines.push(Line::from(Span::styled(
                        format!("  {row}"),
                        Style::default().fg(INK),
                    )));
                }
            }
            Chunk::Assistant(text) => {
                lines.push(Line::from(Span::styled(
                    "◆ agent",
                    Style::default().fg(PURPLE).add_modifier(Modifier::BOLD),
                )));
                for row in text.lines() {
                    lines.push(Line::from(Span::styled(
                        format!("  {row}"),
                        Style::default().fg(BODY),
                    )));
                }
            }
            Chunk::Thought(text) => {
                for row in text.lines() {
                    lines.push(Line::from(Span::styled(
                        format!("  {row}"),
                        Style::default().fg(FAINT).add_modifier(Modifier::ITALIC),
                    )));
                }
            }
            Chunk::Tool {
                name,
                state,
                detail,
                ..
            } => {
                let (glyph, colour) = match state {
                    ToolState::Started => ("◇", YELLOW),
                    ToolState::Completed => ("◆", GREEN),
                    ToolState::Failed => ("✗", RED),
                };
                let mut spans = vec![
                    Span::styled(format!("  {glyph} "), Style::default().fg(colour)),
                    Span::styled(name.clone(), Style::default().fg(INK)),
                ];
                if !detail.is_empty() {
                    spans.push(Span::styled(
                        format!("  {}", truncate(detail, 60)),
                        Style::default().fg(FAINT),
                    ));
                }
                lines.push(Line::from(spans));
            }
            Chunk::Notice(text) => lines.push(Line::from(Span::styled(
                format!("· {text}"),
                Style::default().fg(LINE),
            ))),
        }
        lines.push(Line::from(""));
    }
    if lines.is_empty() {
        lines.push(Line::from(""));
        lines.push(Line::from(Span::styled(
            "  Press i to write a prompt.",
            Style::default().fg(FAINT),
        )));
    }
    if !app.options.is_empty() {
        lines.push(Line::from(Span::styled(
            "  the agent offered:",
            Style::default().fg(FAINT),
        )));
        for (index, option) in app.options.iter().enumerate() {
            lines.push(Line::from(vec![
                Span::styled(
                    format!("  {} ", index + 1),
                    Style::default().bg(SURFACE).fg(INK),
                ),
                Span::styled(format!(" {option}"), Style::default().fg(YELLOW)),
            ]));
        }
    }

    let view = main.height.saturating_sub(2);
    let total = lines.len() as u16;
    let offset = total.saturating_sub(view).min(app.scroll);
    let title = match &app.agent_name {
        Some(name) => format!(" {name} "),
        None => " AGENT ".to_string(),
    };
    frame.render_widget(
        Paragraph::new(Text::from(lines))
            .wrap(Wrap { trim: false })
            .scroll((offset, 0))
            .block(panel(&title, PURPLE).padding(Padding::new(1, 1, 0, 0))),
        main,
    );

    if show_plan {
        let steps: Vec<Line> = app
            .plan
            .iter()
            .enumerate()
            .map(|(index, step)| {
                Line::from(vec![
                    Span::styled(format!("{:>2}. ", index + 1), Style::default().fg(LINE)),
                    Span::styled(step.clone(), Style::default().fg(BODY)),
                ])
            })
            .collect();
        frame.render_widget(
            Paragraph::new(Text::from(steps))
                .wrap(Wrap { trim: true })
                .block(panel(" PLAN ", LINE).padding(Padding::new(1, 1, 0, 0))),
            side,
        );
    }

    let composing = app.mode == Mode::Compose;
    let composer_colour = if composing { ACCENT } else { LINE };
    let content = if app.composer.is_empty() && !composing {
        Text::from(Line::from(Span::styled(
            if app.agent_busy {
                "working — s or ctrl+c to stop"
            } else {
                "i to write · s to stop · G to follow"
            },
            Style::default().fg(FAINT),
        )))
    } else {
        Text::from(app.composer.text().to_string())
    };
    frame.render_widget(
        Paragraph::new(content)
            .wrap(Wrap { trim: false })
            .style(Style::default().fg(INK))
            .block(panel(" PROMPT ", composer_colour).padding(Padding::new(1, 1, 0, 0))),
        composer_area,
    );
    if composing {
        let inner_width = composer_area.width.saturating_sub(4).max(1);
        let columns = app.composer.cursor_columns();
        let x = composer_area.x + 2 + (columns % inner_width);
        let y = composer_area.y + 1 + (columns / inner_width);
        if y < composer_area.bottom().saturating_sub(1) {
            frame.set_cursor_position(Position::new(x, y));
        }
    }
}

fn render_log(frame: &mut Frame<'_>, area: Rect, app: &App) {
    let lines: Vec<Line> = app
        .log
        .iter()
        .skip(app.log_scroll)
        .map(|entry| {
            let colour = match entry.scope {
                Scope::Shell => CYAN,
                Scope::Agent => PURPLE,
            };
            Line::from(vec![
                Span::styled(
                    format!("{:<6} ", entry.scope.label()),
                    Style::default().fg(colour),
                ),
                Span::styled(entry.text.clone(), Style::default().fg(BODY)),
            ])
        })
        .collect();
    let body = if lines.is_empty() {
        Text::from(Line::from(Span::styled(
            "  nothing yet",
            Style::default().fg(FAINT),
        )))
    } else {
        Text::from(lines)
    };
    frame.render_widget(
        Paragraph::new(body)
            .wrap(Wrap { trim: false })
            .block(panel(" TRANSPORT LOG ", LINE).padding(Padding::new(1, 1, 0, 0))),
        area,
    );
}

fn render_footer(frame: &mut Frame<'_>, area: Rect, app: &App) {
    let [left, right] =
        Layout::horizontal([Constraint::Percentage(64), Constraint::Percentage(36)]).areas(area);

    let shortcuts: Vec<Span> = match (app.page, app.mode) {
        (_, Mode::Capture) => vec![
            key("ctrl+a d"),
            hint(" detach  "),
            key("ctrl+a tab"),
            hint(" pane  "),
            key("ctrl+a ?"),
            hint(" help"),
        ],
        (_, Mode::Compose) => vec![
            key("enter"),
            hint(" send  "),
            key("alt+enter"),
            hint(" newline  "),
            key("ctrl+u"),
            hint(" clear  "),
            key("esc"),
            hint(" cancel"),
        ],
        (Page::Hosts, _) => vec![
            key("j/k"),
            hint(" move  "),
            key("enter"),
            hint(" connect  "),
            key("r"),
            hint(" reload  "),
            key("tab"),
            hint(" pane  "),
            key("q"),
            hint(" quit"),
        ],
        (Page::Shell, _) => vec![
            key("i"),
            hint(" capture keys  "),
            key("x"),
            hint(" close  "),
            key("tab"),
            hint(" pane"),
        ],
        (Page::Agent, _) => vec![
            key("i"),
            hint(" prompt  "),
            key("s"),
            hint(" stop  "),
            key("j/k"),
            hint(" scroll  "),
            key("G"),
            hint(" follow"),
        ],
        (Page::Log, _) => vec![
            key("j/k"),
            hint(" scroll  "),
            key("c"),
            hint(" clear  "),
            key("tab"),
            hint(" pane"),
        ],
    };
    frame.render_widget(Paragraph::new(Line::from(shortcuts)), left);

    let mut status = Vec::new();
    if app.agent_busy || (app.shell.is_some() && !app.shell_live) {
        status.push(Span::styled(
            format!("{} ", BRAILLE[app.spin % BRAILLE.len()]),
            Style::default().fg(ACCENT),
        ));
    }
    if app.prefix_armed {
        status.push(Span::styled(
            " PREFIX ",
            Style::default()
                .bg(YELLOW)
                .fg(BG)
                .add_modifier(Modifier::BOLD),
        ));
        status.push(Span::raw(" "));
    }
    status.push(Span::styled(
        app.status.clone(),
        Style::default().fg(if app.status_is_error { RED } else { FAINT }),
    ));
    frame.render_widget(
        Paragraph::new(Line::from(status)).alignment(Alignment::Right),
        right,
    );
}

fn render_permission(frame: &mut Frame<'_>, permission: &crate::app::Permission) {
    let height = (permission.options.len() as u16).saturating_add(7).min(20);
    let area = centered(frame.area(), 68, height);
    frame.render_widget(Clear, area);

    let mut lines = vec![
        Line::from(""),
        Line::from(Span::styled(
            truncate(&permission.prompt, 60),
            Style::default().fg(INK).add_modifier(Modifier::BOLD),
        )),
        Line::from(""),
    ];
    for (index, option) in permission.options.iter().enumerate() {
        let chosen = index == permission.selected;
        lines.push(Line::from(vec![
            Span::styled(
                if chosen { "▌ " } else { "  " },
                Style::default().fg(YELLOW),
            ),
            Span::styled(
                format!(" {} ", index + 1),
                Style::default().bg(SURFACE).fg(INK),
            ),
            Span::styled(
                format!("  {option}"),
                if chosen {
                    Style::default().fg(INK).add_modifier(Modifier::BOLD)
                } else {
                    Style::default().fg(BODY)
                },
            ),
        ]));
    }
    lines.push(Line::from(""));
    lines.push(Line::from(Span::styled(
        "  the remote turn is blocked until you answer · esc denies",
        Style::default().fg(FAINT),
    )));

    frame.render_widget(
        Paragraph::new(Text::from(lines))
            .block(panel(" PERMISSION ", YELLOW).padding(Padding::new(2, 2, 0, 0)))
            .style(Style::default().bg(BG)),
        area,
    );
}

fn render_help(frame: &mut Frame<'_>) {
    let area = centered(frame.area(), 68, 24);
    frame.render_widget(Clear, area);
    let lines = vec![
        Line::from(""),
        section("PANES"),
        shortcut("tab", "cycle hosts → shell → agent → log"),
        shortcut("q", "quit"),
        Line::from(""),
        section("HOSTS"),
        shortcut("j / k", "move"),
        shortcut("enter", "connect a host, or open an agent"),
        shortcut("r", "reload config.json"),
        Line::from(""),
        section("SHELL"),
        shortcut("i", "send keystrokes to the remote pty"),
        shortcut("ctrl+a d", "stop sending, keep the shell open"),
        shortcut("ctrl+a a", "send a literal ctrl+a"),
        shortcut("x", "close the shell"),
        Line::from(""),
        section("AGENT"),
        shortcut("i", "write a prompt"),
        shortcut("enter / alt+enter", "send / newline"),
        shortcut("s or ctrl+c", "interrupt the running turn"),
        shortcut("1–9", "pick an offered option"),
        shortcut("j / k / G", "scroll, follow"),
        Line::from(""),
        Line::from(Span::styled(
            "  any key closes this",
            Style::default().fg(FAINT),
        )),
    ];
    frame.render_widget(
        Paragraph::new(Text::from(lines))
            .block(panel(" KEYS ", ACCENT).padding(Padding::new(2, 2, 0, 0)))
            .style(Style::default().bg(BG)),
        area,
    );
}

// ---- helpers ------------------------------------------------------------

fn panel<'a>(title: &'a str, colour: Color) -> Block<'a> {
    Block::default()
        .title(Line::styled(
            title,
            Style::default().fg(colour).add_modifier(Modifier::BOLD),
        ))
        .borders(Borders::ALL)
        .border_type(BorderType::Plain)
        .border_style(Style::default().fg(colour))
        .style(Style::default().bg(BG))
}

fn key(value: &'static str) -> Span<'static> {
    Span::styled(format!(" {value} "), Style::default().bg(SURFACE).fg(INK))
}

fn hint(value: &'static str) -> Span<'static> {
    Span::styled(value, Style::default().fg(FAINT))
}

fn section(value: &'static str) -> Line<'static> {
    Line::from(Span::styled(
        value,
        Style::default().fg(ACCENT).add_modifier(Modifier::BOLD),
    ))
}

fn shortcut(key: &'static str, description: &'static str) -> Line<'static> {
    Line::from(vec![
        Span::styled(format!("  {key:<18}"), Style::default().fg(INK)),
        Span::styled(description, Style::default().fg(BODY)),
    ])
}

fn truncate(value: &str, width: usize) -> String {
    let flat = value.replace('\n', " ");
    if flat.chars().count() <= width {
        return flat;
    }
    let head: String = flat.chars().take(width.saturating_sub(1)).collect();
    format!("{head}…")
}

fn centered(area: Rect, width: u16, height: u16) -> Rect {
    let width = width.min(area.width.saturating_sub(2));
    let height = height.min(area.height.saturating_sub(2));
    let x = area.x + (area.width.saturating_sub(width)) / 2;
    let y = area.y + (area.height.saturating_sub(height)) / 2;
    Rect {
        x,
        y,
        width,
        height,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use ratatui::Terminal;
    use ratatui::backend::TestBackend;

    fn draw(app: &App, width: u16, height: u16) -> String {
        let backend = TestBackend::new(width, height);
        let mut terminal = Terminal::new(backend).expect("building the test terminal");
        terminal
            .draw(|frame| render(frame, app))
            .expect("drawing a frame");
        terminal
            .backend()
            .buffer()
            .content()
            .iter()
            .map(|cell| cell.symbol())
            .collect()
    }

    #[test]
    fn the_pty_size_matches_the_shell_pane_layout() {
        // One header row, two footer rows, and the pane's own border.
        assert_eq!(shell_size(120, 40), (118, 35));
    }

    #[test]
    fn a_tiny_terminal_still_asks_for_a_usable_pty() {
        let (cols, rows) = shell_size(4, 4);
        assert!(cols >= 20 && rows >= 5);
    }

    #[test]
    fn the_empty_state_names_the_config_file_to_write() {
        let app = App::new(Config::default(), (100, 30)).expect("building the app");
        let frame = draw(&app, 100, 30);
        assert!(frame.contains("Nothing configured yet."));
        assert!(frame.contains("config.json"));
    }

    #[test]
    fn a_permission_modal_says_the_turn_is_blocked() {
        let mut app = App::new(Config::default(), (100, 30)).expect("building the app");
        app.apply(crate::event::Msg::AgentPermission {
            id: "ui_1".into(),
            prompt: "Allow tool: bash rm -rf /tmp/x".into(),
            options: vec!["Approve".into(), "Deny".into()],
        });
        let frame = draw(&app, 100, 30);
        assert!(frame.contains("PERMISSION"));
        assert!(frame.contains("blocked"));
        assert!(frame.contains("Approve"));
    }
}
