//! A one-field text input with a real cursor.
//!
//! Not a text editor and not a widget: it is the model behind the agent
//! composer and every prompt box, and it exists because `String` plus a
//! `usize` gets the cursor wrong the moment someone types an emoji or a CJK
//! character. The cursor is a byte index into valid UTF-8; every movement
//! steps by grapheme-ish `char` boundaries and every render measures with
//! `unicode-width`, so a wide glyph advances the caret two columns.

use unicode_width::UnicodeWidthStr;

#[derive(Debug, Clone, Default)]
pub struct Input {
    text: String,
    /// Byte offset, always on a `char` boundary.
    cursor: usize,
}

impl Input {
    pub fn new() -> Input {
        Input::default()
    }

    pub fn text(&self) -> &str {
        &self.text
    }

    pub fn is_empty(&self) -> bool {
        self.text.is_empty()
    }

    pub fn clear(&mut self) {
        self.text.clear();
        self.cursor = 0;
    }

    /// Hand the content to a caller and reset. The composer submits this way so
    /// there is no window where the same prompt could be sent twice.
    pub fn take(&mut self) -> String {
        let text = std::mem::take(&mut self.text);
        self.cursor = 0;
        text
    }

    pub fn insert(&mut self, value: char) {
        self.text.insert(self.cursor, value);
        self.cursor += value.len_utf8();
    }

    pub fn insert_str(&mut self, value: &str) {
        self.text.insert_str(self.cursor, value);
        self.cursor += value.len();
    }

    pub fn backspace(&mut self) {
        if self.cursor == 0 {
            return;
        }
        let previous = self.previous_boundary();
        self.text.replace_range(previous..self.cursor, "");
        self.cursor = previous;
    }

    pub fn delete(&mut self) {
        if self.cursor >= self.text.len() {
            return;
        }
        let next = self.next_boundary();
        self.text.replace_range(self.cursor..next, "");
    }

    pub fn left(&mut self) {
        self.cursor = self.previous_boundary();
    }

    pub fn right(&mut self) {
        self.cursor = self.next_boundary();
    }

    pub fn home(&mut self) {
        self.cursor = 0;
    }

    pub fn end(&mut self) {
        self.cursor = self.text.len();
    }

    /// Ctrl+U: throw away everything before the caret, the way a shell does.
    pub fn kill_to_start(&mut self) {
        self.text.replace_range(..self.cursor, "");
        self.cursor = 0;
    }

    /// Ctrl+W: delete the word behind the caret.
    pub fn kill_word(&mut self) {
        let head = &self.text[..self.cursor];
        let trimmed = head.trim_end();
        let start = match trimmed.rfind(char::is_whitespace) {
            Some(index) => index + 1,
            None => 0,
        };
        self.text.replace_range(start..self.cursor, "");
        self.cursor = start;
    }

    /// Display columns occupied by the text before the caret — what the caller
    /// adds to a pane's x origin to place the real terminal cursor.
    pub fn cursor_columns(&self) -> u16 {
        UnicodeWidthStr::width(&self.text[..self.cursor]) as u16
    }

    fn previous_boundary(&self) -> usize {
        self.text[..self.cursor]
            .char_indices()
            .next_back()
            .map(|(index, _)| index)
            .unwrap_or(0)
    }

    fn next_boundary(&self) -> usize {
        self.text[self.cursor..]
            .chars()
            .next()
            .map(|value| self.cursor + value.len_utf8())
            .unwrap_or(self.cursor)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backspace_removes_a_whole_multibyte_char() {
        let mut input = Input::new();
        input.insert('a');
        input.insert('é');
        input.backspace();
        assert_eq!(input.text(), "a");
    }

    #[test]
    fn the_caret_measures_in_columns_not_bytes() {
        let mut input = Input::new();
        input.insert_str("日本");
        // Two CJK chars are six bytes but four columns.
        assert_eq!(input.cursor_columns(), 4);
    }

    #[test]
    fn taking_the_text_leaves_the_field_empty() {
        let mut input = Input::new();
        input.insert_str("deploy");
        assert_eq!(input.take(), "deploy");
        assert!(input.is_empty());
        assert_eq!(input.cursor_columns(), 0);
    }

    #[test]
    fn kill_word_stops_at_the_previous_space() {
        let mut input = Input::new();
        input.insert_str("cargo build --release");
        input.kill_word();
        assert_eq!(input.text(), "cargo build ");
    }

    #[test]
    fn moving_left_past_the_start_is_not_an_error() {
        let mut input = Input::new();
        input.left();
        input.backspace();
        assert!(input.is_empty());
    }
}
