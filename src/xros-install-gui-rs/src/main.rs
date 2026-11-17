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
            .with_min_inner_size([880.0, 540.0])
            // 10.11.2026 (fixed5): окно открывается развёрнутым.
            // Без этого KWin ставил окно 960x600 со смещением
            // (x≈475 при 1280x800) — правая часть и кнопки «Назад»/
            // «Продолжить» оказывались за экраном, а maximize/drag
            // через оконный менеджер не срабатывали. Развёрнутое окно
            // всегда полностью видно, на любом разрешении.
            .with_maximized(true),
        // П.6 (XrOS 1.1): vsync ВЫКЛЮЧЕН, аппаратное ускорение —
        // Preferred (по умолчанию, зафиксировано явно).
        // Причина: в живой системе под VirtualBox видеодрайвер
        // vmwgfx сломан (ошибки DRM при загрузке), рендер идёт
        // через программный llvmpipe. Со включённым vsync каждый
        // кадр дополнительно ждёт vblank/present у композитора,
        // и цикл обработки событий тормозится: нажатия клавиш
        // копились между редкими кадрами и визуально «терялись»
        // при быстром вводе. Без vsync swap_buffers возвращается
        // сразу, цикл крутит события так быстро, как позволяет CPU,
        // и ввод доходит до полей без многосекундных задержек.
        // Тиринг в окне установщика неважен. На железе с рабочим
        // GPU ускорение по-прежнему используется (Preferred).
        vsync: false,
        hardware_acceleration: eframe::HardwareAcceleration::Preferred,
        ..Default::default()
    };
    // для отладки: --step N открывает сразу шаг N.
    // A-11: только в debug-сборке. В релизе флаг игнорируется:
    // пропуск шагов мимо валидации в релизном установщике недопустим.
    #[cfg(debug_assertions)]
    let mut start_step = 0;
    #[cfg(not(debug_assertions))]
    let start_step = 0;
    #[cfg(debug_assertions)]
    {
        let mut args = std::env::args().skip(1);
        while let Some(a) = args.next() {
            if a == "--step" {
                if let Some(n) = args.next().and_then(|s| s.parse::<usize>().ok()) {
                    start_step = n;
                }
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
