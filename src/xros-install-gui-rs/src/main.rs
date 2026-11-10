// Установщик XrOS. Без рута тут делать нечего —
// если запустили обычным пользователем, перевыполняемся через sudo
// (у живого пользователя xros sudo без пароля) и едем дальше.

mod app;
mod install;
mod steps;
mod system;
mod theme;

use std::os::unix::process::CommandExt;

fn main() {
    if unsafe { libc::geteuid() != 0 } {
        let exe =
            std::env::current_exe().unwrap_or_else(|_| "xros-install-gui".into());
        // Wayland: без WAYLAND_DISPLAY/XDG_RUNTIME_DIR root-процесс
        // установщика не найдёт сокет композитора и упадёт на XWayland.
        let err = std::process::Command::new("sudo")
            .arg("--preserve-env=DISPLAY,WAYLAND_DISPLAY,XDG_RUNTIME_DIR,XAUTHORITY,DBUS_SESSION_BUS_ADDRESS")
            .arg(&exe)
            .args(std::env::args().skip(1))
            .exec();
        eprintln!("sudo не сработал: {err}");
        std::process::exit(1);
    }

    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Программа установки XrOS")
            .with_inner_size([960.0, 600.0])
            .with_min_inner_size([880.0, 540.0]),
        ..Default::default()
    };
    // для отладки: --step N открывает сразу шаг N
    let mut start_step = 0;
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        if a == "--step" {
            if let Some(n) = args.next().and_then(|s| s.parse::<usize>().ok()) {
                start_step = n;
            }
        }
    }
    if let Err(err) = eframe::run_native(
        "Программа установки XrOS",
        options,
        Box::new(move |cc| Ok(Box::new(app::App::new(cc, start_step)))),
    ) {
        eprintln!("установщик упал: {err}");
        std::process::exit(1);
    }
}
