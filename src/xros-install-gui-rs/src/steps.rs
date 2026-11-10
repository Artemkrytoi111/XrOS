// Страницы установщика — по одной функции на шаг.
// Ничего хитрого: заголовок, поля, кнопки.

use crate::app::{App, PartMode, DES, FILESYSTEMS, KEYMAPS, TIMEZONES};
use crate::install;
use crate::system;
use crate::theme;
use egui::{Color32, RichText};

pub fn show_step(app: &mut App, ui: &mut egui::Ui) {
    match app.step {
        0 => show_welcome(app, ui),
        1 => show_location(app, ui),
        2 => show_keyboard(app, ui),
        3 => show_desktop(app, ui),
        4 => show_partitions(app, ui),
        5 => show_users(app, ui),
        6 => show_office(app, ui),
        7 => show_summary(app, ui),
        8 => show_install(app, ui),
        _ => show_finish(app, ui),
    }
}

fn title(ui: &mut egui::Ui, text: &str) {
    ui.label(RichText::new(text).size(20.0).strong().color(Color32::WHITE));
    ui.add_space(4.0);
}

fn show_welcome(app: &mut App, ui: &mut egui::Ui) {
    ui.add_space(18.0);
    if let Some((tex, size)) = &app.logo_big {
        ui.vertical_centered(|ui| {
            ui.image((tex.id(), *size));
        });
    }
    ui.add_space(18.0);
    ui.vertical_centered(|ui| {
        ui.label(
            RichText::new("Добро пожаловать в XrOS")
                .size(24.0)
                .strong()
                .color(Color32::WHITE),
        );
    });
    ui.add_space(8.0);
    ui.vertical_centered(|ui| {
        ui.label(
            "XrOS 1.0 — система на базе Arch Linux\n\n\
             Программа установки проведёт вас через несколько шагов:\n\
             выбор места и раскладки, рабочий стол, разметка диска,\n\
             создание пользователя и установка системы с загрузчиком GRUB.",
        );
    });
    ui.add_space(18.0);
    ui.vertical_centered(|ui| {
        ui.horizontal(|ui| {
            ui.label("Язык:");
            egui::ComboBox::from_id_salt("lang")
                .selected_text(if app.sel.lang == "ru" { "Русский" } else { "English" })
                .show_ui(ui, |ui| {
                    ui.selectable_value(&mut app.sel.lang, "ru".to_string(), "Русский");
                    ui.selectable_value(&mut app.sel.lang, "en".to_string(), "English");
                });
        });
    });
}

fn show_location(app: &mut App, ui: &mut egui::Ui) {
    title(ui, "Местоположение");
    ui.label(RichText::new("Выберите часовой пояс. Он будет установлен в системе.").color(theme::TEXT_DIM));
    ui.add_space(10.0);
    egui::ComboBox::from_id_salt("tz")
        .selected_text(app.sel.timezone.as_str())
        .width(320.0)
        .show_ui(ui, |ui| {
            for tz in TIMEZONES {
                ui.selectable_value(&mut app.sel.timezone, tz.to_string(), tz);
            }
        });
}

fn show_keyboard(app: &mut App, ui: &mut egui::Ui) {
    title(ui, "Клавиатура");
    ui.label(RichText::new("Выберите раскладку клавиатуры.").color(theme::TEXT_DIM));
    ui.add_space(10.0);
    egui::ComboBox::from_id_salt("kb")
        .selected_text(if app.sel.keymap == "ru" { "Русская" } else { "Английская" })
        .width(320.0)
        .show_ui(ui, |ui| {
            for (label, code) in KEYMAPS {
                ui.selectable_value(&mut app.sel.keymap, code.to_string(), label);
            }
        });
}

fn show_desktop(app: &mut App, ui: &mut egui::Ui) {
    title(ui, "Рабочий стол");
    ui.label("Выберите графическую оболочку. KDE Plasma ставится с этого диска, без интернета.");
    ui.add_space(6.0);
    for (label, code) in DES {
        ui.radio_value(&mut app.sel.de, code.to_string(), label);
    }
    ui.add_space(6.0);
    ui.label(RichText::new("Другие оболочки скачиваются из интернета при установке. Без интернета останется KDE Plasma. «Без графики» работает и без интернета: графический стек живой системы удаляется, система загружается в консоль.").color(theme::TEXT_DIM).size(13.0));
}

fn show_partitions(app: &mut App, ui: &mut egui::Ui) {
    title(ui, "Разделы");
    ui.label("Выберите диск для установки XrOS.");
    ui.add_space(4.0);
    egui::ScrollArea::vertical()
        .max_height(110.0)
        .show(ui, |ui| {
            for (dev, size) in app.disks.clone() {
                let resp = ui.selectable_value(
                    &mut app.sel.disk,
                    dev.clone(),
                    format!("{dev}  —  {size}"),
                );
                if resp.changed() {
                    app.sel.root_part.clear();
                    app.sel.efi_part.clear();
                    app.refresh_partitions();
                }
            }
        });
    ui.add_space(6.0);
    let r1 = ui.radio_value(
        &mut app.sel.partmode,
        PartMode::Erase,
        "Очистить диск (стереть всё и разметить заново)",
    );
    let r2 = ui.radio_value(
        &mut app.sel.partmode,
        PartMode::Manual,
        "Ручная разметка (выбрать разделы вручную)",
    );
    if r1.changed() || r2.changed() {
        app.refresh_partitions();
    }
    ui.add_space(6.0);
    ui.label("Файловая система корневого раздела:");
    egui::ComboBox::from_id_salt("fs")
        .selected_text(
            FILESYSTEMS
                .iter()
                .find(|(_, code)| *code == app.sel.fs)
                .map(|(label, _)| *label)
                .unwrap_or("ext4 — надёжная, по умолчанию"),
        )
        .width(320.0)
        .show_ui(ui, |ui| {
            for (label, code) in FILESYSTEMS {
                ui.selectable_value(&mut app.sel.fs, code.to_string(), label);
            }
        });
    ui.label("Разделы выбранного диска (для ручной разметки):");
    let manual = app.sel.partmode == PartMode::Manual;
    ui.add_enabled_ui(manual, |ui| {
        egui::ScrollArea::vertical()
            .max_height(130.0)
            .show(ui, |ui| {
                for (dev, size, fstype) in app.parts.clone() {
                    let resp = ui.selectable_label(
                        app.sel.root_part == dev,
                        format!("{dev}  —  {size}  {fstype}"),
                    );
                    if resp.clicked() {
                        app.sel.root_part = dev.clone();
                        app.part_hint = format!("Корневой раздел: {dev}");
                    }
                    if resp.double_clicked() && system::is_uefi() {
                        app.sel.efi_part = dev.clone();
                        app.part_hint = format!(
                            "Корневой раздел: {}  •  EFI-раздел: {dev}",
                            app.sel.root_part
                        );
                    }
                }
            });
    });
    if !app.part_hint.is_empty() {
        ui.label(RichText::new(&app.part_hint).color(theme::TEXT_DIM).size(12.0));
    }
}

// кружок-галочка справа от поля: фиолетовый с белой галочкой,
// если значение нормальное, и тусклое кольцо — если пока нет.
fn check_badge(ui: &mut egui::Ui, valid: bool) {
    let size = 20.0;
    let (rect, _) = ui.allocate_exact_size(egui::vec2(size, size), egui::Sense::hover());
    if valid {
        ui.painter().circle_filled(rect.center(), size / 2.0, theme::ACCENT);
        ui.painter().text(
            rect.center(),
            egui::Align2::CENTER_CENTER,
            "✓",
            egui::FontId::proportional(13.0),
            Color32::WHITE,
        );
    } else {
        ui.painter().circle_stroke(
            rect.center(),
            size / 2.0 - 1.0,
            egui::Stroke::new(1.5_f32, theme::BORDER),
        );
    }
}

// поле ввода + фиолетовая галочка справа, если значение нормальное
fn user_field(
    ui: &mut egui::Ui,
    label: &str,
    valid: bool,
    add: impl FnOnce(&mut egui::Ui, f32),
) {
    ui.label(RichText::new(label).size(14.0).color(theme::TEXT));
    ui.add_space(2.0);
    ui.horizontal(|ui| {
        let w = ui.available_width();
        add(ui, w - 30.0);
        check_badge(ui, valid);
    });
    ui.add_space(10.0);
}

fn show_users(app: &mut App, ui: &mut egui::Ui) {
    title(ui, "Пользователи");
    ui.label("Кто будет пользоваться этим компьютером?");
    ui.add_space(4.0);

    let fullname_ok = !app.sel.fullname.trim().is_empty();
    let username_ok = !app.sel.username.trim().is_empty();
    let hostname_ok = !app.sel.hostname.trim().is_empty();
    let pass_ok = !app.sel.userpass.is_empty();
    let pass2_ok = !app.sel.pass2.is_empty() && app.sel.pass2 == app.sel.userpass;

    user_field(ui, "Как Вас зовут?", fullname_ok, |ui, w| {
        ui.add(egui::TextEdit::singleline(&mut app.sel.fullname).desired_width(w));
    });
    user_field(ui, "Какое имя Вы хотите использовать для входа?", username_ok, |ui, w| {
        ui.add(egui::TextEdit::singleline(&mut app.sel.username).desired_width(w));
    });
    user_field(ui, "Какое имя у компьютера?", hostname_ok, |ui, w| {
        ui.add(egui::TextEdit::singleline(&mut app.sel.hostname).desired_width(w));
    });
    user_field(
        ui,
        "Выберите пароль для защиты вашей учётной записи",
        pass_ok,
        |ui, w| {
            ui.add(
                egui::TextEdit::singleline(&mut app.sel.userpass)
                    .password(true)
                    .desired_width(w),
            );
        },
    );
    user_field(ui, "Повторите пароль", pass2_ok, |ui, w| {
        ui.add(
            egui::TextEdit::singleline(&mut app.sel.pass2)
                .password(true)
                .desired_width(w),
        );
    });

    ui.add_space(6.0);
    ui.checkbox(
        &mut app.sel.same_admin_pass,
        "Использовать тот же пароль для администрирования",
    );
    if !app.sel.same_admin_pass {
        ui.add_space(4.0);
        ui.horizontal(|ui| {
            let w = ui.available_width();
            ui.add(
                egui::TextEdit::singleline(&mut app.sel.rootpass)
                    .password(true)
                    .hint_text("Пароль администратора (root).")
                    .desired_width(w),
            );
        });
    }
    ui.add_space(6.0);
    ui.checkbox(
        &mut app.sel.autologin,
        "Автоматический вход, без запроса пароля",
    );
    if !app.users_error.is_empty() {
        ui.add_space(6.0);
        ui.label(RichText::new(&app.users_error).color(Color32::from_rgb(0xf0, 0x70, 0x70)).size(13.0));
    }
}

fn show_office(app: &mut App, ui: &mut egui::Ui) {
    title(ui, "Office Suite");
    ui.label("Выберите офисный пакет. Установка — из интернета; без него пакет пропускается.");
    ui.add_space(6.0);
    ui.radio_value(&mut app.sel.office, "none".to_string(), "Не устанавливать");
    ui.radio_value(
        &mut app.sel.office,
        "libreoffice".to_string(),
        "LibreOffice (полный пакет)",
    );
    ui.radio_value(
        &mut app.sel.office,
        "viewer".to_string(),
        "Только просмотр документов (Okular)",
    );
}

fn show_summary(app: &mut App, ui: &mut egui::Ui) {
    title(ui, "Итог");
    let de_name = DES
        .iter()
        .find(|(_, code)| *code == app.sel.de)
        .map(|(label, _)| *label)
        .unwrap_or("KDE Plasma");
    let fs_name = FILESYSTEMS
        .iter()
        .find(|(_, code)| *code == app.sel.fs)
        .map(|(label, _)| *label)
        .unwrap_or("ext4");
    let mut lines = vec![
        format!("Диск: {}", app.sel.disk),
        format!(
            "Разметка: {}",
            if app.sel.partmode == PartMode::Erase {
                "Очистить диск"
            } else {
                "Ручная разметка"
            }
        ),
        format!("Файловая система: {fs_name}"),
        "Загрузчик: GRUB (UEFI/BIOS)".to_string(),
    ];
    if app.sel.partmode == PartMode::Manual {
        lines.push(format!("Корневой раздел: {}", app.sel.root_part));
        if !app.sel.efi_part.is_empty() {
            lines.push(format!("EFI-раздел: {}", app.sel.efi_part));
        }
    }
    lines.push(format!("Часовой пояс: {}", app.sel.timezone));
    lines.push(format!("Раскладка: {}", app.sel.keymap));
    lines.push(format!(
        "Имя: {}",
        if app.sel.fullname.is_empty() {
            &app.sel.username
        } else {
            &app.sel.fullname
        }
    ));
    lines.push(format!("Логин: {}", app.sel.username));
    lines.push(format!("Компьютер: {}", app.sel.hostname));
    lines.push(format!(
        "Автовход: {}",
        if app.sel.autologin { "да" } else { "нет" }
    ));
    lines.push(format!("Офисный пакет: {}", app.sel.office));
    lines.push(format!("Оболочка: {de_name}"));
    ui.label(lines.join("\n"));
}

fn show_install(app: &mut App, ui: &mut egui::Ui) {
    title(ui, "Установка");
    ui.label(&app.status);
    ui.add_space(4.0);
    ui.add(egui::ProgressBar::new(app.progress).show_percentage());
    ui.add_space(4.0);
    egui::ScrollArea::vertical()
        .stick_to_bottom(true)
        .max_height(280.0)
        .show(ui, |ui| {
            ui.label(&app.log);
        });
    ui.add_space(6.0);
    let btn = egui::Button::new(RichText::new("Установить").strong().color(Color32::WHITE))
        .fill(theme::ACCENT);
    if ui.add_enabled(!app.installing, btn).clicked() {
        match install::start_install(&app.sel) {
            Ok((rx, handle)) => {
                app.rx = Some(rx);
                app.child = Some(handle);
                app.installing = true;
                app.progress = 0.0;
                app.log.clear();
                app.status = "Установка началась…".into();
            }
            Err(e) => {
                app.error_msg = Some(format!("Не удалось запустить установку: {e}"));
            }
        }
    }
    // Осознанная остановка во время установки (случайное закрытие окна
    // заблокировано в app.rs, кнопка «Отмена» внизу неактивна):
    // SIGTERM всей группе движка + cleanup в движке + сообщение.
    if app.installing
        && ui
            .button("Остановить установку")
            .clicked()
    {
        app.confirm_cancel = true;
    }
}

fn show_finish(app: &mut App, ui: &mut egui::Ui) {
    // Этот шаг показывается ТОЛЬКО после реального успеха установки
    // (см. drain_events в app.rs: при ошибке сюда не переходим).
    ui.add_space(20.0);
    ui.vertical_centered(|ui| {
        // иконка успеха: фиолетовый кружок с белой галочкой
        let size = 72.0;
        let (rect, _) = ui.allocate_exact_size(egui::vec2(size, size), egui::Sense::hover());
        ui.painter().circle_filled(rect.center(), size / 2.0, theme::ACCENT);
        ui.painter().text(
            rect.center(),
            egui::Align2::CENTER_CENTER,
            "✓",
            egui::FontId::proportional(40.0),
            Color32::WHITE,
        );
        ui.add_space(12.0);
        ui.label(
            RichText::new("XrOS успешно установлена")
                .size(22.0)
                .strong()
                .color(Color32::WHITE),
        );
        ui.add_space(8.0);
        ui.label(
            "XrOS установлена на диск и готова к использованию.\n\n\
             Не забудьте вынуть флешку/диск с ISO перед перезагрузкой.",
        );
        ui.add_space(16.0);
        ui.checkbox(&mut app.reboot_now, "Перезагрузить компьютер сейчас");
        ui.add_space(12.0);
        let finish = egui::Button::new(
            RichText::new("Завершить").strong().color(Color32::WHITE),
        )
        .fill(theme::ACCENT)
        .min_size(egui::vec2(160.0, 40.0));
        if ui.add(finish).clicked() {
            if app.reboot_now {
                // Движок уже сделал sync и размонтировал целевой диск
                // до сигнала INSTALL_DONE. На всякий случай — ещё один sync,
                // и только потом безопасная перезагрузка.
                let _ = std::process::Command::new("sync").status();
                let _ = std::process::Command::new("reboot").status();
            } else {
                ui.ctx().send_viewport_cmd(egui::ViewportCommand::Close);
            }
        }
    });
}
