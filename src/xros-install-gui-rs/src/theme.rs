// Цвета XrOS — фирменная система, утверждённая 10.11.2026.
// Единый источник — branding/design-tokens.css, здесь тот же набор.
// Фон #08080D, доп. фон #111018, акцент #8B00FF, второй акцент #B66AFF,
// текст #F5F3FA, вторичный #A6A0B3, границы #30283B.
// Зелёного тут нет, красного тоже: у XrOS своя палитра.

use egui::{Color32, FontFamily, FontId, TextStyle, Visuals};

// акцент — фиолетовый неон, второй акцент — светлый неон (hover, ссылки)
pub const ACCENT: Color32 = Color32::from_rgb(0x8b, 0x00, 0xff);
pub const ACCENT_HOVER: Color32 = Color32::from_rgb(0xb6, 0x6a, 0xff);
// тёмный акцент — для активного (нажатого) состояния кнопок
pub const ACCENT_DARK: Color32 = Color32::from_rgb(0x5a, 0x00, 0xb8);
// светло-фиолетовый для ссылок
pub const LINK: Color32 = Color32::from_rgb(0xb6, 0x6a, 0xff);

pub const BG: Color32 = Color32::from_rgb(0x08, 0x08, 0x0d);
pub const SIDEBAR_BG: Color32 = Color32::from_rgb(0x05, 0x05, 0x08);
pub const FIELD_BG: Color32 = Color32::from_rgb(0x11, 0x10, 0x18);
pub const BUTTON_BG: Color32 = Color32::from_rgb(0x1e, 0x19, 0x2e);
pub const TEXT: Color32 = Color32::from_rgb(0xf5, 0xf3, 0xfa);
pub const TEXT_DIM: Color32 = Color32::from_rgb(0xa6, 0xa0, 0xb3);
pub const BORDER: Color32 = Color32::from_rgb(0x30, 0x28, 0x3b);

pub fn dark_visuals() -> Visuals {
    let mut v = Visuals::dark();
    v.window_fill = BG;
    v.panel_fill = BG;
    v.extreme_bg_color = FIELD_BG;
    v.faint_bg_color = SIDEBAR_BG;
    v.override_text_color = Some(TEXT);
    v.selection.bg_fill = ACCENT;
    v.selection.stroke = egui::Stroke::new(1.0_f32, ACCENT_HOVER);
    v.hyperlink_color = LINK;
    v.error_fg_color = Color32::from_rgb(0xf0, 0x70, 0x70);
    v.window_stroke = egui::Stroke::new(1.0_f32, BORDER);
    // скругления — без них всё выглядит как из 2000-х
    let round = egui::CornerRadius::same(6);
    v.widgets.noninteractive.bg_stroke = egui::Stroke::new(1.0_f32, BORDER);
    v.widgets.noninteractive.corner_radius = round;
    v.widgets.inactive.bg_fill = BUTTON_BG;
    v.widgets.inactive.weak_bg_fill = BUTTON_BG;
    v.widgets.inactive.corner_radius = round;
    v.widgets.hovered.bg_fill = Color32::from_rgb(0x2e, 0x22, 0x4a);
    v.widgets.hovered.corner_radius = round;
    v.widgets.active.bg_fill = ACCENT_DARK;
    v.widgets.active.corner_radius = round;
    v.widgets.open.bg_fill = FIELD_BG;
    v.widgets.open.corner_radius = round;
    v
}

// шрифты и отступы — чтобы не было мелко и тесно
pub fn apply_style(ctx: &egui::Context) {
    let mut style = (*ctx.style()).clone();
    style.text_styles.insert(TextStyle::Heading, FontId::new(22.0, FontFamily::Proportional));
    style.text_styles.insert(TextStyle::Body, FontId::new(15.0, FontFamily::Proportional));
    style.text_styles.insert(TextStyle::Button, FontId::new(15.0, FontFamily::Proportional));
    style.text_styles.insert(TextStyle::Small, FontId::new(13.0, FontFamily::Proportional));
    style.text_styles.insert(TextStyle::Monospace, FontId::new(13.0, FontFamily::Monospace));
    // отступы: воздуха между строками хватает, тексты не прыгают —
    // высота строк задаётся стилем, а не контентом
    style.spacing.item_spacing = egui::vec2(8.0, 10.0);
    style.spacing.button_padding = egui::vec2(16.0, 9.0);
    style.spacing.indent = 18.0;
    style.spacing.combo_height = 200.0;
    style.spacing.scroll.bar_width = 10.0;
    ctx.set_style(style);
}
