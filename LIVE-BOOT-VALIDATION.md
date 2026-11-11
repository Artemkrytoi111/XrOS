# LIVE-BOOT-VALIDATION — XrOS 1.0 (fixed7 / fixed9), 11.11.2026

## Вывод одной строкой

**Live-загрузка fixed9 — PASS (UEFI).** GRUB-меню с живым обратным
отсчётом («Автозагрузка через N с», дефект «@TIMEOUT@» закрыт),
рабочий стол KDE Plasma с фиолетовыми обоями XrOS, панель, окно
«Добро пожаловать в XrOS!», стабильность 17+ мин (fixed7) и
~25 мин рабочей сессии установщика (fixed9). **BIOS — PENDING**
(тест после UEFI-установки).

## Прогоны

| Прогон | ISO | Режим | Результат |
|---|---|---|---|
| fixed7-uefi-live | fixed7 hybrid `f8094a1b…` | UEFI, GRUB, nodisk | Стол PASS, GRUB FAIL (@TIMEOUT@) |
| fixed8-uefi-live | fixed8 hybrid `9948646d…` | UEFI, GRUB, nodisk | GRUB FAIL (@TIMEOUT_NOTIFICATION_SHORT@) |
| fixed9-uefi-live | fixed9 hybrid `becd7645…` | UEFI, GRUB, nodisk | GRUB PASS (обратный отсчёт) |
| fixed9-uefi-install2 | fixed9 hybrid `becd7645…` | UEFI, GRUB, диск 20 ГБ | Стол PASS (сессия установщика ~25 мин) |
| fixed9-bios-live | — | BIOS (SeaBIOS) | PENDING |

Все прогоны: QEMU 8.2.2, -m 2048 -smp 2, TCG, std VGA, -display none,
скриншоты через monitor screendump.

## GRUB — PASS (fixed9, UEFI)

- Меню: «XrOS 1.0 (x86 64, UEFI)», «XrOS 1.0 — с диктором»,
  «Настройки UEFI», «Выключить компьютер», «Перезагрузить компьютер».
- Футер (кадры grub1/grub2, fixed9-uefi-live): «Автозагрузка через 6 с»
  → через 3 с «Автозагрузка через 3 с» — **число уменьшается по-русски,
  полоса прогресса анимируется**. Литералов `@...@` нет.
- История дефекта: fixed7 — литерал «@TIMEOUT@»; fixed8 — литерал
  «@TIMEOUT_NOTIFICATION_SHORT@». Причина (исходник GRUB 2.16,
  `grub-core/gfxmenu/gui_progress_bar.c`, `progress_bar_set_property()`):
  плейсхолдеры сравниваются `grub_strcmp` со ВСЕМ значением `text`,
  а `text` — это printf-шаблон (`grub_xasprintf(template, |value|)`).
  Исправление fixed9: `text = "Автозагрузка через %d с"` в обоих
  theme.txt (ISO GRUB + Live/установленная).
  Подробнее: FIXED7-LIVE-TEST.md, FIXED8-GRUB-TEST.md.
- Диагностика fixed9: **PASS=245 FAIL=0 SKIP=11** (§7з и §15 требуют
  `%d`-шаблон и запрещают литерал `@...@` в строках `text =`).
  check-iso fixed9: PASS=10 FAIL=0 SKIP=2.
- GRUB в установленной системе: проверяется первой загрузкой
  (INSTALLED-SYSTEM-VALIDATION.md).

## Live-стол — PASS (UEFI)

- **Обои:** чёрные с фиолетовыми волнами + X по центру
  (`/usr/share/xros/wallpaper.png`, без надписи «XrOS» — по решению Мии).
  Подтверждены в fixed7 (boot3) и в сессии fixed9-uefi-install2
  (кадры i1–j45, фиолетовые волны с первой минуты стола).
  Нюанс: в кадре fixed9-uefi-live-boot1 за окном приветствия ещё виден
  стандартный фон Plasma — скрипт `xros-set-wallpaper`
  (autostart, `plasma-apply-wallpaperimage`, до 30 попыток × 3 с)
  применяет обои XrOS с задержкой после входа. Дефектом не является:
  в той же сборке (install2) волны на месте с начала сессии.
- **Окно «Добро пожаловать в XrOS!»:** авто-появляется при входе
  (логотип X, «Запустить установщик», «О системе», «Закрыть»,
  «Запускать при старте» включён). Подтверждено в fixed6-repro,
  fixed7, fixed9-live, fixed9-install2.
- **Панель:** Kickoff, таск-менеджер, трей, часы (fixed7: 08:41–08:48;
  fixed9-install2: 09:58–10:19). Значок «Установить XrOS» на столе.
- **Стабильность:** fixed7 — 17+ мин без падений; fixed9-install2 —
  ~25 мин активной работы установщика (Konsole + GUI) без сбоев стола.
  Правило стенда (доказано fixed6-repro): под медленным TCG стол
  появляется за ~10 мин; вердикт «чёрный стол» — не раньше ~15 мин
  после старта ВМ.
- **Гонка Plasma (фикс fixed7):** drop-in
  `plasma-plasmashell.service.d/10-kactivitymanagerd.conf`
  (Wants+After kactivitymanagerd) + `ExecStartPre=/usr/local/bin/xros-wait-kactivitymanagerd`
  (опрос `busctl --user status org.kde.ActivityManager`, до 30 с,
  всегда exit 0) + `TimeoutStartSec=120s`. Внутри Live (fixed7,
  Konsole): unit `ActiveState=active`, drop-in загружен,
  `journalctl --user -b -g Aborting` — «No entries»,
  plasmashell PID 958, kactivitymanagerd PID 967. Аборт
  «The activity manager daemon is not running» (причина чёрного
  стола установленной системы из fixed5) в Live не воспроизвёлся
  ни разу (fixed6-repro + fixed7 + fixed9-install2).
- **Консоль:** Konsole открывается по Ctrl+Alt+T (~15–40 с под TCG),
  работает; MESA-EGL предупреждения и ошибка ZINK
  (`vkCreateInstance failed (VK_ERROR_INCOMPATIBLE_DRIVER)`) —
  шум программного рендеринга, не дефект.

## Известные аномалии Live-среды (не блокируют загрузку)

- **Самопроизвольный автозапуск установщика окном приветствия —
  ПОДТВЕРЖДЁН 11.11.2026** (fixed9-install2, 10:06–10:07 UTC):
  второй экземпляр `xros-install-gui` появился без ввода пользователя
  (окно приветствия было живо). Та же аномалия — ночь 10→11 ноября
  (два sudo-процесса pid 1069, 1076). Причина в коде приветствия
  не исследована. На установку не влияет, если приветствие закрыто;
  как отдельная задача — найти триггер (ложное срабатывание кнопки
  при фокусе?) и исправить.
- **KRunner не запускается** (Meta / Alt+F2): «Could not activate
  remote peer org.kde.krunner». `plasma-krunner.service` имеет
  `TimeoutSec=5sec` — гипотеза: мало под TCG. Не доказано, не блокирует.
- **Мышь QEMU не работает в Wayland-госте** (mouse_move не двигает
  курсор) — ограничение стенда, не дефект системы. Вся навигация —
  клавиатурой (см. INSTALLER-NAV-NOTES.md).
- **Печать под TCG ненадёжна:** клавиши двоятся/теряются (задержка
  0.25–0.4 с на клавишу; Tab/Shift+Tab теряются ~50% через QMP) —
  ограничение стенда, не дефект системы.

## BIOS — PENDING

- BIOS-GRUB проверен на экспериментальном образе 155 МБ в этапе 10
  (SeaBIOS CD PASS, isohybrid USB PASS) — но НЕ на основном ISO
  fixed9 с темой `%d`. Тест: загрузка fixed9 hybrid в BIOS-режиме,
  кадр GRUB (обратный отсчёт «Автозагрузка через N с», без литерала),
  Live-стол. Выполняется после UEFI-установки.

## Скриншоты и логи

- `experiments/qemu-stage10/screenshots/fixed7-uefi-live-*.png`
  (grub1, boot1–boot3, konsole1/2, check1–3, stable17)
- `experiments/qemu-stage10/screenshots/fixed8-uefi-live-grub1.png`
- `experiments/qemu-stage10/screenshots/fixed9-uefi-live-*.png`
  (grub1, grub2, boot1)
- `experiments/qemu-stage10/screenshots/fixed9-uefi-install2-*.png`
  (i1–i15, j1–j45 — Live-сессия + установка)
- `experiments/qemu-stage10/logs/fixed7-uefi-live/`,
  `fixed8-uefi-live/`, `fixed9-uefi-live/`, `fixed9-uefi-install2/`
- ISO: `out/xros-1.0-fixed9-x86_64.iso` (sha256
  `d62a997810cf6ade3dd7ca795989acc7773554fb108da0f2bf0e080b357789a1`),
  `out/xros-1.0-fixed9-x86_64-hybrid.iso` (sha256
  `becd7645a1508d963742fd2aeaf518024f7cef88d08f65aef665a715a7708f0c`)

- **Гашение экрана (DPMS) во время долгой установки:** Live-сессия гасит
  дисплей после ~10–15 мин без ввода (fixed9-install2, 06:29–06:39 UTC).
  Экран чёрный, курсор появляется после Ctrl+Alt+F1, полная перерисовка
  — через ~30 с. Установка при этом продолжается (диск рос). Не сбой.
  Правило стенда: Shift каждые ~5 мин или пробуждение через Ctrl+Alt+F1.
