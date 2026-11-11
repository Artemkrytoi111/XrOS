// Состояние установщика: что выбрал пользователь, на каком мы шаге,
// идёт ли установка. Весь UI рисуется из этого.

use crate::install::{self, InstallEvent};
use crate::system;
use crate::theme;
use egui::{Color32, RichText, TextureHandle};
use std::collections::HashSet;
use std::sync::mpsc;

pub const STEPS: [&str; 10] = [
    "Welcome",
    "Location",
    "Keyboard",
    "Desktop",
    "Partitions",
    "Users",
    "Office Suite",
    "Summary",
    "Install",
    "Finish",
];

pub const TIMEZONES: [&str; 13] = [
    "Europe/Astrakhan",
    "Europe/Moscow",
    "Europe/Samara",
    "Europe/Kaliningrad",
    "Europe/Volgograd",
    "Europe/Saratov",
    "Asia/Yekaterinburg",
    "Asia/Omsk",
    "Asia/Novosibirsk",
    "Asia/Krasnoyarsk",
    "Asia/Irkutsk",
    "Asia/Vladivostok",
    "UTC",
];

pub const KEYMAPS: [(&str, &str); 2] = [("Русская", "ru"), ("Английская", "us")];

pub const FILESYSTEMS: [(&str, &str); 3] = [
    ("ext4 — надёжная, по умолчанию", "ext4"),
    ("btrfs — снимки и сжатие", "btrfs"),
    ("xfs — быстрая для больших файлов", "xfs"),
];

pub const DES: [(&str, &str); 7] = [
    ("KDE Plasma — по умолчанию, без интернета", "kde"),
    ("GNOME", "gnome"),
    ("XFCE — лёгкая и быстрая", "xfce"),
    ("Cinnamon", "cinnamon"),
    ("Sway — Wayland, тайловый", "sway"),
    ("i3-wm — тайловый, минимализм", "i3"),
    ("Без графики — только консоль", "none"),
];

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum PartMode {
    Erase,
    Manual,
}

// сюда складываем всё, что выбрал пользователь
#[derive(Clone)]
pub struct Choices {
    pub lang: String,
    pub timezone: String,
    pub keymap: String,
    pub de: String,
    pub disk: String,
    pub partmode: PartMode,
    pub fs: String,
    pub root_part: String,
    pub efi_part: String,
    pub fullname: String,
    pub username: String,
    pub hostname: String,
    pub userpass: String,
    pub pass2: String,
    pub rootpass: String,
    pub same_admin_pass: bool,
    pub autologin: bool,
    pub office: String,
}

impl Default for Choices {
    fn default() -> Self {
        Self {
            lang: "ru".into(),
            timezone: "Europe/Astrakhan".into(),
            keymap: "ru".into(),
            de: "kde".into(),
            disk: String::new(),
            partmode: PartMode::Erase,
            fs: "ext4".into(),
            root_part: String::new(),
            efi_part: String::new(),
            fullname: String::new(),
            username: "xros".into(),
            hostname: "xros-os".into(),
            userpass: String::new(),
            pass2: String::new(),
            rootpass: String::new(),
            same_admin_pass: true,
            autologin: false,
            office: "none".into(),
        }
    }
}

pub struct App {
    pub step: usize,
    pub completed: HashSet<usize>,
    pub sel: Choices,
    pub disks: Vec<(String, String)>,
    pub parts: Vec<(String, String, String)>,
    pub part_hint: String,
    pub progress: f32,
    pub status: String,
    pub log: String,
    pub installing: bool,
    pub error_msg: Option<String>,
    pub users_error: String,
    pub confirm_erase: bool,
    pub reboot_now: bool,
    pub rx: Option<mpsc::Receiver<InstallEvent>>,
    // Ручка запущенного движка: пока идёт установка, GUI отслеживает
    // дочерний процесс и может его остановить (см. install.rs).
    // Сбрасывается в None только после Finished — и только после того,
    // как движок реально вышел (см. drain_events): иначе Drop ручки
    // послал бы SIGTERM группе движка, который уже печатает INSTALL_DONE.
    pub child: Option<install::InstallHandle>,
    // Отмена запрошена пользователем — фиксируется в самой ручке
    // (InstallHandle::cancel ставит флаг cancelled): Finished(false)
    // после этого — не ошибка, а штатная остановка.
    pub confirm_cancel: bool,
    // Фокус уже запрошен для открытого диалога (fixed7): при открытии
    // диалога фокус клавиатуры ставится на его главную кнопку, иначе
    // Tab циклит виджеты главного окна и до кнопок диалога не доходит.
    pub dialog_focus: bool,
    pub logo_small: Option<(TextureHandle, egui::Vec2)>,
    pub logo_big: Option<(TextureHandle, egui::Vec2)>,
}

fn load_fonts(ctx: &egui::Context) {
    // без DejaVu русский превращается в квадратики, так что грузим его первым
    let mut fonts = egui::FontDefinitions::default();
    let paths = [
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ];
    for p in paths {
        if let Ok(data) = std::fs::read(p) {
            fonts.font_data.insert(
                "dejavu".to_owned(),
                std::sync::Arc::new(egui::FontData::from_owned(data)),
            );
            if let Some(family) = fonts.families.get_mut(&egui::FontFamily::Proportional)
            {
                family.insert(0, "dejavu".to_owned());
            }
            break;
        }
    }
    ctx.set_fonts(fonts);
}

fn load_logo(
    ctx: &egui::Context,
    path: &str,
    name: &str,
    width: f32,
) -> Option<(TextureHandle, egui::Vec2)> {
    let img = image::open(path).ok()?.to_rgba8();
    let (w, h) = (img.width(), img.height());
    let color =
        egui::ColorImage::from_rgba_unmultiplied([w as usize, h as usize], img.as_raw());
    let tex = ctx.load_texture(name, color, egui::TextureOptions::LINEAR);
    Some((tex, egui::vec2(width, width * h as f32 / w as f32)))
}

impl App {
    pub fn new(cc: &eframe::CreationContext<'_>, start_step: usize) -> Self {
        let ctx = &cc.egui_ctx;
        ctx.set_visuals(theme::dark_visuals());
        theme::apply_style(ctx);
        load_fonts(ctx);
        let logo_small = load_logo(ctx, "/usr/share/xros/xros-logo-small.png", "logo-small", 170.0);
        let logo_big = load_logo(ctx, "/usr/share/xros/xros-logo.png", "logo-big", 250.0);

        // Finish (шаг 9) напрямую не открываем даже через --step:
        // туда попадают только после реального INSTALL_DONE.
        let start_step = start_step.min(STEPS.len() - 2);
        let mut app = Self {
            step: start_step,
            completed: (0..start_step).collect(),
            sel: Choices::default(),
            disks: system::list_disks(),
            parts: Vec::new(),
            part_hint: String::new(),
            progress: 0.0,
            status: "Нажмите «Установить», чтобы начать.".into(),
            log: String::new(),
            installing: false,
            error_msg: None,
            users_error: String::new(),
            confirm_erase: false,
            reboot_now: true,
            rx: None,
            child: None,
            confirm_cancel: false,
            dialog_focus: false,
            logo_small,
            logo_big,
        };
        if let Some((dev, _)) = app.disks.first().cloned() {
            app.sel.disk = dev;
        }
        app.refresh_partitions();
        app
    }

    pub fn refresh_partitions(&mut self) {
        // Список дисков тоже обновляем: между шагами флешку могли
        // воткнуть/вынуть, а App::new читает диски один раз.
        // Если выбранный диск исчез — сбрасываем выбор, чтобы движок
        // не получил мёртвый /dev-путь (его перепроверка идентификатора
        // всё равно поймала бы, но лучше не доводить до ошибки установки).
        self.disks = system::list_disks();
        if !self.sel.disk.is_empty()
            && !self.disks.iter().any(|(d, _)| *d == self.sel.disk)
        {
            self.sel.disk.clear();
            self.sel.root_part.clear();
            self.sel.efi_part.clear();
        }
        if self.sel.disk.is_empty() {
            self.parts.clear();
            self.part_hint.clear();
            return;
        }
        self.parts = system::list_partitions(&self.sel.disk);
        self.part_hint = if system::is_uefi() {
            "Ручная разметка: корневой раздел — клик, EFI-раздел — двойной клик.".into()
        } else {
            "Ручная разметка: выберите корневой раздел (клик).".into()
        };
    }

    fn advance(&mut self) {
        self.completed.insert(self.step);
        if self.step < STEPS.len() - 1 {
            self.step += 1;
        }
        if self.step == 4 {
            self.refresh_partitions();
        }
    }

    fn validate_users(&self) -> Result<(), String> {
        if self.sel.username.trim().is_empty() {
            return Err("Введите имя для входа.".into());
        }
        if self.sel.userpass.is_empty() {
            return Err("Введите пароль.".into());
        }
        if self.sel.userpass != self.sel.pass2 {
            return Err("Пароли не совпадают.".into());
        }
        if !self.sel.same_admin_pass && self.sel.rootpass.is_empty() {
            return Err("Введите пароль администратора.".into());
        }
        if self.sel.hostname.trim().is_empty() {
            return Err("Введите имя компьютера.".into());
        }
        Ok(())
    }

    fn on_next(&mut self) {
        if self.installing {
            return;
        }
        match self.step {
            4 => {
                if self.sel.disk.is_empty() {
                    self.part_hint = "Выберите диск для установки.".into();
                    return;
                }
                if self.sel.partmode == PartMode::Manual {
                    if self.sel.root_part.is_empty() {
                        self.part_hint = "Выберите корневой раздел.".into();
                        return;
                    }
                    if system::is_uefi() && self.sel.efi_part.is_empty() {
                        self.part_hint = "Для UEFI нужен EFI-раздел.".into();
                        return;
                    }
                    self.advance();
                } else {
                    // стирание диска — только с подтверждением
                    self.confirm_erase = true;
                }
            }
            5 => match self.validate_users() {
                Ok(()) => {
                    self.users_error.clear();
                    self.advance();
                }
                Err(msg) => self.users_error = msg,
            },
            _ => self.advance(),
        }
    }

    fn on_back(&mut self) {
        if self.installing || self.step == 0 || self.step >= 8 {
            return;
        }
        self.step -= 1;
    }

    // Штатная отмена во время установки: SIGTERM всей группе движка
    // (движок по ловушке делает cleanup: гасит rsync/arch-chroot,
    // размонтирует $TARGET, пишет причину в журнал), а если за 5 секунд
    // не ушёл — SIGKILL группе (см. InstallHandle::cancel). Отмена ДО
    // начала установки — просто закрытие окна: движок ещё не запущен,
    // разрушительных операций нет. Случайное закрытие окна (крестик)
    // во время установки по-прежнему заблокировано (CancelClose ниже):
    // остановка — только осознанной кнопкой «Остановить установку»
    // на шаге Install с подтверждением.
    fn cancel_install(&mut self) {
        if let Some(h) = &self.child {
            h.cancel();
        }
        self.status =
            "Остановка установки… Движок завершает работу и размонтирует диск.".into();
    }

    fn drain_events(&mut self) {
        let mut finished = None;
        if let Some(rx) = &self.rx {
            while let Ok(ev) = rx.try_recv() {
                match ev {
                    InstallEvent::Progress(n) => self.progress = n as f32 / 100.0,
                    InstallEvent::Status(s) => self.status = s,
                    InstallEvent::Log(line) => {
                        self.log.push_str(&line);
                        self.log.push('\n');
                    }
                    InstallEvent::Finished(ok) => finished = Some(ok),
                }
            }
        }
        if let Some(ok) = finished {
            // Движок печатает INSTALL_DONE/INSTALL_FAILED чуть раньше
            // своего выхода: дождаться реального выхода (обычно — сразу,
            // try_wait вернёт статус с первой проверки), чтобы сброс
            // ручки ниже не послал SIGTERM уже завершающемуся движку
            // и чтобы не оставить зомби. Ждём не дольше ~2 секунд.
            if let Some(h) = &self.child {
                for _ in 0..20 {
                    if !h.is_running() {
                        break;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
            }
            self.installing = false;
            self.rx = None;
            // Флаг отмены читаем из ручки ДО её сброса.
            let was_cancelled = self
                .child
                .as_ref()
                .map(|h| h.was_cancelled())
                .unwrap_or(false);
            self.child = None;
            if ok {
                self.progress = 1.0;
                self.status = "Установка завершена.".into();
                self.completed.insert(8);
                self.step = 9;
            } else if was_cancelled {
                let tail = install::log_tail(15);
                self.error_msg = Some(format!(
                    "Установка остановлена по вашему запросу.\n\nДвижок остановлен, целевой диск размонтирован, временные файлы удалены. Разметка диска может быть незавершённой — повторите установку с начала.\n\nПоследние строки журнала:\n{tail}"
                ));
                self.status = "Установка остановлена пользователем.".into();
            } else {
                let tail = install::log_tail(15);
                self.error_msg = Some(format!(
                    "Установка завершилась с ошибкой.\n\nПоследние строки журнала:\n{tail}"
                ));
                self.status = "Ошибка. Исправьте проблему и попробуйте снова.".into();
            }
        }
    }

    fn show_sidebar(&mut self, ui: &mut egui::Ui) {
        ui.add_space(10.0);
        if let Some((tex, size)) = &self.logo_small {
            ui.vertical_centered(|ui| {
                ui.image((tex.id(), *size));
            });
        } else {
            ui.vertical_centered(|ui| {
                ui.label(RichText::new("XrOS").size(28.0).strong().color(Color32::WHITE));
            });
        }
        ui.add_space(8.0);
        ui.vertical_centered(|ui| {
            ui.label(RichText::new("XrOS 1.0").size(16.0).strong().color(Color32::WHITE));
        });
        ui.add_space(6.0);
        ui.separator();
        ui.add_space(12.0);
        for (i, step_name) in STEPS.iter().enumerate() {
            let done = self.completed.contains(&i);
            let current = i == self.step;
            // галочка фиолетовая, название — серое (у текущего шага белое)
            let mark = if done {
                "✓  "
            } else if current {
                "●  "
            } else {
                "     "
            };
            let mut job = egui::text::LayoutJob::default();
            job.append(
                mark,
                0.0,
                egui::TextFormat {
                    font_id: egui::FontId::proportional(15.0),
                    color: if done || current {
                        theme::ACCENT_HOVER
                    } else {
                        theme::TEXT_DIM
                    },
                    ..Default::default()
                },
            );
            job.append(
                step_name,
                0.0,
                egui::TextFormat {
                    font_id: egui::FontId::proportional(15.0),
                    color: if current {
                        Color32::WHITE
                    } else {
                        theme::TEXT_DIM
                    },
                    ..Default::default()
                },
            );
            let resp = ui.selectable_label(current, job);
            if resp.clicked() && (done || current) {
                self.step = i;
                if i == 4 {
                    self.refresh_partitions();
                }
            }
            ui.add_space(3.0);
        }
    }

    fn show_nav(&mut self, ui: &mut egui::Ui, ctx: &egui::Context) {
        ui.horizontal(|ui| {
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui
                    .add_enabled(
                        !self.installing,
                        egui::Button::new("Отмена").min_size(egui::vec2(110.0, 36.0)),
                    )
                    .clicked()
                {
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                }
                // на шаге Finish кнопка «Далее» не нужна — там своя «Завершить»
                if self.step < 8 {
                    let next = egui::Button::new(
                        RichText::new("Далее").strong().color(Color32::WHITE),
                    )
                    .fill(theme::ACCENT)
                    .min_size(egui::vec2(110.0, 36.0));
                    if ui
                        .add_enabled(!self.installing, next)
                        .clicked()
                    {
                        self.on_next();
                    }
                }
                if ui
                    .add_enabled(
                        !self.installing && self.step > 0 && self.step < 8,
                        egui::Button::new("Назад").min_size(egui::vec2(110.0, 36.0)),
                    )
                    .clicked()
                {
                    self.on_back();
                }
            });
        });
    }
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.drain_events();

        // Закрытие окна во время установки запрещено: случайный крестик
        // или Alt+F4 не должны оставить xros-install без UI. Это НЕ
        // значит, что установку нельзя остановить вовсе: осознанная
        // остановка — кнопкой «Остановить установку» на шаге Install
        // (см. steps.rs + cancel_install): она шлёт SIGTERM всей
        // группе движка, движок делает cleanup и выходит. А если GUI
        // умирает сам (падение, kill извне) — движок получает SIGTERM
        // от ядра через PR_SET_PDEATHSIG (см. install.rs). Кнопка
        // «Отмена» в этот момент и так неактивна.
        if self.installing && ctx.input(|i| i.viewport().close_requested()) {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            self.status = "Установка идёт — дождитесь её завершения или нажмите «Остановить установку» на шаге Install.".into();
        }

        egui::SidePanel::left("sidebar")
            .exact_width(210.0)
            .resizable(false)
            .show(ctx, |ui| {
                ui.style_mut().visuals.panel_fill = theme::SIDEBAR_BG;
                self.show_sidebar(ui);
            });

        egui::TopBottomPanel::bottom("nav").show(ctx, |ui| {
            ui.add_space(6.0);
            self.show_nav(ui, ctx);
            ui.add_space(6.0);
        });

        egui::CentralPanel::default().show(ctx, |ui| {
            // контент — колонка по центру, не шире 660, чтобы поля
            // не разъезжались на всю ширину окна
            let avail = ui.available_size();
            let col_w = avail.x.min(660.0);
            let left = ((avail.x - col_w) / 2.0).max(0.0);
            ui.horizontal(|ui| {
                ui.add_space(left);
                ui.vertical(|ui| {
                    ui.set_width(col_w);
                    ui.add_space(14.0);
                    crate::steps::show_step(self, ui);
                });
            });
        });

        // фокус диалога (fixed7): пока никакой диалог не открыт —
        // сбрасываем, чтобы при следующем открытии фокус снова встал
        // на главную кнопку диалога
        if !self.confirm_erase && !self.confirm_cancel && self.error_msg.is_none() {
            self.dialog_focus = false;
        }

        // подтверждение стирания диска
        if self.confirm_erase {
            let disk = self.sel.disk.clone();
            egui::Window::new("Очистить диск")
                .collapsible(false)
                .resizable(false)
                .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
                .show(ctx, |ui| {
                    if ui.input(|i| i.key_pressed(egui::Key::Escape)) {
                        self.confirm_erase = false;
                    }
                    ui.label(format!(
                        "Точно стереть диск\n\n  {disk}\n\nи установить туда XrOS?\nВсе файлы на диске будут удалены безвозвратно."
                    ));
                    ui.add_space(8.0);
                    ui.horizontal(|ui| {
                        let erase_btn = ui.add(
                            egui::Button::new(
                                RichText::new("Да, стереть").strong().color(Color32::WHITE),
                            )
                            .fill(theme::ACCENT),
                        );
                        // fixed7: фокус — на главную кнопку сразу при
                        // открытии диалога (иначе Tab циклит главное окно)
                        if !self.dialog_focus {
                            erase_btn.request_focus();
                            self.dialog_focus = true;
                        }
                        if erase_btn.clicked() {
                            self.confirm_erase = false;
                            self.advance();
                        }
                        if ui.button("Отмена").clicked() {
                            self.confirm_erase = false;
                        }
                    });
                });
        }

        // подтверждение остановки установки
        if self.confirm_cancel {
            egui::Window::new("Остановить установку")
                .collapsible(false)
                .resizable(false)
                .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
                .show(ctx, |ui| {
                    if ui.input(|i| i.key_pressed(egui::Key::Escape)) {
                        self.confirm_cancel = false;
                    }
                    ui.label(
                        "Остановить установку?\n\nДвижок будет остановлен, целевой диск размонтирован.\nРазметка диска может оказаться незавершённой —\nустановку придётся повторить с начала.",
                    );
                    ui.add_space(8.0);
                    ui.horizontal(|ui| {
                        let stop_btn = ui.add(
                            egui::Button::new(
                                RichText::new("Да, остановить").strong().color(Color32::WHITE),
                            )
                            .fill(theme::ACCENT),
                        );
                        // fixed7: фокус — на главную кнопку при открытии
                        if !self.dialog_focus {
                            stop_btn.request_focus();
                            self.dialog_focus = true;
                        }
                        if stop_btn.clicked() {
                            self.confirm_cancel = false;
                            self.cancel_install();
                        }
                        if ui.button("Продолжить установку").clicked() {
                            self.confirm_cancel = false;
                        }
                    });
                });
        }

        if let Some(msg) = self.error_msg.clone() {
            egui::Window::new("Ошибка установки")
                .collapsible(false)
                .resizable(false)
                .anchor(egui::Align2::CENTER_CENTER, [0.0, 0.0])
                .show(ctx, |ui| {
                    if ui.input(|i| i.key_pressed(egui::Key::Escape)) {
                        self.error_msg = None;
                    }
                    ui.label(&msg);
                    ui.add_space(8.0);
                    let close_btn = ui.button("Закрыть");
                    // fixed7: фокус — на кнопку при открытии диалога
                    if !self.dialog_focus {
                        close_btn.request_focus();
                        self.dialog_focus = true;
                    }
                    if close_btn.clicked() {
                        self.error_msg = None;
                    }
                });
        }

        // пока идёт установка, кадры нужны постоянно — иначе прогресс замрёт
        if self.installing {
            ctx.request_repaint();
        }
    }
}
