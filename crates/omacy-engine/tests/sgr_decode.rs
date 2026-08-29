//! Independent SGR decoder. fill_grid must not call this.

use crate::abi::OmacyCell;
use ttfx::engine::terminal::{CELL_HAS_BACKGROUND, CELL_HAS_GLYPH};
use ttfx::utils::hexterm;

#[derive(Clone, Copy)]
struct Pen {
    fg: Option<[u8; 3]>,
    bg: Option<[u8; 3]>,
    reverse: bool,
}

impl Default for Pen {
    fn default() -> Self {
        Self {
            fg: None,
            bg: None,
            reverse: false,
        }
    }
}

pub fn decode_ansi(text: &str, cols: u32, rows: u32, term_bg: [u8; 3]) -> Vec<OmacyCell> {
    let mut cells = vec![OmacyCell::default(); (cols * rows) as usize];
    let mut pen = Pen::default();
    let mut row = 0u32;
    let mut col = 0u32;
    let bytes = text.as_bytes();
    let chars = text.char_indices().collect::<Vec<_>>();
    let mut ci = 0;
    while ci < chars.len() {
        let (byte_index, ch) = chars[ci];
        if ch == '\u{1b}' {
            if byte_index + 1 < bytes.len() && bytes[byte_index + 1] == b'[' {
                if let Some((end, params)) = parse_sgr(&bytes[byte_index..]) {
                    apply_sgr(&mut pen, &params);
                    let consumed = end;
                    while ci < chars.len() && chars[ci].0 < byte_index + consumed {
                        ci += 1;
                    }
                    continue;
                }
            }
        }
        if ch == '\n' {
            row += 1;
            col = 0;
            ci += 1;
            continue;
        }
        if row < rows && col < cols {
            cells[(row * cols + col) as usize] = snapshot(ch, pen, term_bg);
        }
        col += 1;
        ci += 1;
    }
    cells
}

fn parse_sgr(bytes: &[u8]) -> Option<(usize, Vec<u16>)> {
    if bytes.len() < 3 || bytes[0] != 0x1B || bytes[1] != b'[' {
        return None;
    }
    let mut params = Vec::new();
    let mut n: Option<u16> = None;
    for (idx, b) in bytes[2..].iter().enumerate() {
        match *b {
            b'0'..=b'9' => {
                let d = (*b - b'0') as u16;
                n = Some(n.unwrap_or(0).saturating_mul(10).saturating_add(d));
            }
            b';' => {
                params.push(n.unwrap_or(0));
                n = None;
            }
            b'm' => {
                params.push(n.unwrap_or(0));
                return Some((idx + 3, params));
            }
            _ => return None,
        }
    }
    None
}

fn apply_sgr(pen: &mut Pen, params: &[u16]) {
    let mut i = 0;
    while i < params.len() {
        match params[i] {
            0 => *pen = Pen::default(),
            1 | 22 | 3 | 23 | 4 | 24 => {}
            7 => pen.reverse = true,
            27 => pen.reverse = false,
            30..=37 => pen.fg = Some(ansi16((params[i] - 30) as u8)),
            90..=97 => pen.fg = Some(ansi16((params[i] - 90 + 8) as u8)),
            40..=47 => pen.bg = Some(ansi16((params[i] - 40) as u8)),
            100..=107 => pen.bg = Some(ansi16((params[i] - 100 + 8) as u8)),
            39 => pen.fg = None,
            49 => pen.bg = None,
            38 | 48 => {
                let is_fg = params[i] == 38;
                if i + 1 < params.len() && params[i + 1] == 5 && i + 2 < params.len() {
                    let rgb = xterm256(params[i + 2] as u8);
                    if is_fg {
                        pen.fg = Some(rgb);
                    } else {
                        pen.bg = Some(rgb);
                    }
                    i += 2;
                } else if i + 1 < params.len() && params[i + 1] == 2 && i + 4 < params.len() {
                    let rgb = [
                        params[i + 2] as u8,
                        params[i + 3] as u8,
                        params[i + 4] as u8,
                    ];
                    if is_fg {
                        pen.fg = Some(rgb);
                    } else {
                        pen.bg = Some(rgb);
                    }
                    i += 4;
                }
            }
            _ => {}
        }
        i += 1;
    }
}

fn ansi16(code: u8) -> [u8; 3] {
    xterm256(code)
}

fn xterm256(code: u8) -> [u8; 3] {
    let hex = hexterm::xterm_to_hex(code);
    let s = hex.trim_matches('#');
    [
        u8::from_str_radix(&s[0..2], 16).unwrap(),
        u8::from_str_radix(&s[2..4], 16).unwrap(),
        u8::from_str_radix(&s[4..6], 16).unwrap(),
    ]
}

fn snapshot(ch: char, pen: Pen, term_bg: [u8; 3]) -> OmacyCell {
    let mut cell = OmacyCell::default();
    let ink = pen.fg.unwrap_or([255, 255, 255]);
    let (fg, bg, has_background) = if pen.reverse {
        (pen.bg.unwrap_or(term_bg), Some(ink), true)
    } else {
        (ink, pen.bg, pen.bg.is_some())
    };
    if has_background {
        let [r, g, b] = bg.unwrap();
        cell.occupancy |= CELL_HAS_BACKGROUND;
        cell.bg_r = r;
        cell.bg_g = g;
        cell.bg_b = b;
        cell.bg_a = 255;
    }
    if ch != ' ' && ch != '\0' {
        cell.occupancy |= CELL_HAS_GLYPH;
        cell.glyph = ch as u32;
        cell.fg_r = fg[0];
        cell.fg_g = fg[1];
        cell.fg_b = fg[2];
        cell.fg_a = 255;
    }
    cell
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decoder_compiles() {
        let cells = decode_ansi("A", 1, 1, [0, 0, 0]);
        assert_eq!(cells[0].glyph, u32::from('A'));
    }
}

#[allow(dead_code)]
pub fn occupancy(cell: &OmacyCell) -> (bool, bool) {
    (
        cell.occupancy & CELL_HAS_BACKGROUND != 0,
        cell.occupancy & CELL_HAS_GLYPH != 0,
    )
}
