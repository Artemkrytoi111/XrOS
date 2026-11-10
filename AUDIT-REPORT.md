# XrOS — AUDIT-REPORT (финальный аудит, этапы A–G)

**Дата:** 10 ноября 2026.
**Статус:** аудит завершён. ISO **НЕ собран** (сборка — отдельный этап G,
только после явного разрешения Мии). QEMU **НЕ запускался** (нет ISO) —
всё, что ниже помечено «проверено в QEMU», является планом, а не фактом.

**Что сделано финальным агентом:** перепроверены все утверждения
четырёх агентов аудита (брендинг, установщик/безопасность, загрузчик,
пакеты); найдены и исправлены дополнительные ошибки (см. раздел 3);
Rust-проекты скомпилированы и пересобраны в chroot; диагностика
расширена и прогнана до чистого результата; документация обновлена;
этот отчёт составлен.

**Окружение проверок:** хост — Linux VM (нет cargo, makepkg,
shellcheck, grub-script-check); chroot — Arch rootfs другого проекта
(`~/workspace/akvt-os/build-chroot.sh`, см. раздел 6.5):
cargo/rustc **1.99.1**, clippy 0.1.99 (rust-clippy 1.99.0),
`CARGO_HOME=/home/hatch/.cargo`, кэш 303 crate, `--offline`.

---

## 1. Найденные проблемы (по этапам A–G)

### Этап A — Брендинг

| # | Проблема | Статус |
|---|---|---|
| A1 | Старая палитра в `ARCHITECTURE.md` (6 мест: строки 8, 10, 208, 296, 401, 444 — прежние индиго/циан и промежуточный фиолетовый) | ✅ Исправлено финальным агентом (переписан весь документ) |
| A2 | `selected_item_color #B66AFF` на фоне выбранного пункта `#8B00FF` — контраст 1,83:1, текст меню нечитаем | ✅ Исправлено финальным агентом → `#F5F3FA` (5,39:1), обе копии `theme.txt` |
| A3 | `ANSI_COLOR="38;2;108;92;231"` в `customize_airootfs.sh` — это старый цвет `#6C5CE7` в ос-release (агентами не замечен) | ✅ Исправлено финальным агентом → `38;2;139;0;255` (`#8B00FF`) |
| A4 | `branding/README.md:58` — упоминание удалённого `profile/syslinux/splash.png` | ✅ Исправлено финальным агентом (строка удалена) |
| A5 | Обои `wallpaper.png/jpg` 1920×1080 — апскейл ×1,149 из исходника 1672×941, без кропа | ✅ Подтверждено (PIL: оба файла 1920×1080); исходник сохранён |
| A6 | Логотип — настоящий прозрачный PNG (родной альфа-канал, пыль alpha<5 вычищена, углы alpha=0) | ✅ Подтверждено (PIL: RGBA, углы 0, 68,1% пикселей alpha=0) |
| A7 | Присланные обои содержат X и текст «XrOS» по центру — противоречит требованию «не размещать логотип с текстом без отдельного утверждения» | ⏳ Решение за Мией (раздел 7.2) |

### Этап B — Установщик: движок (bash)

| # | Проблема | Статус |
|---|---|---|
| B1 | Инъекция через пароль/ФИО в chroot-heredoc | ✅ Исправлено агентом 2 (`%q`-экранирование, `src/xros-install:400-403`); перепроверено |
| B2 | Нет проверки диска с ISO в ручном режиме | ✅ Исправлено агентом 2 (проверка по `findmnt`/`lsblk PKNAME`, строки 101–115, 244–253); перепроверено |
| B3 | Нет проверки диска (`-b`, `TYPE=disk`) | ✅ Исправлено агентом 2 (строки 121–122); перепроверено |
| B4 | `sudo` стирал `XROS_NONINTERACTIVE`/`XROS_INSTALL_CONF` | ✅ Исправлено агентом 2 (`sudo --preserve-env`, строка 44); перепроверено |
| B5 | `resolv.conf` удалялся до сетевых операций в chroot (падал pacman для DE/офиса) | ✅ Исправлено агентом 2 (удаление перенесено после сетевых операций, строка 508); перепроверено |
| B6 | `machine-id` живой системы копировался в установленную | ✅ Исправлено агентом 2 (удаление + `systemd-machine-id-setup`, строки 352–355, 406); перепроверено |
| B7 | Автовход: GDM и Sway не обрабатывались (всем писался `plasma`, GDM не читает lightdm.conf) | ✅ Исправлено агентом 2 (`/etc/gdm/custom.conf`, сессия по DE, строки 482–501); перепроверено |
| B8 | Два DM висели на `display-manager.service` одновременно | ✅ Исправлено агентом 2 (отключение sddm+lightdm+gdm перед включением выбранного, строки 447–450); перепроверено |
| B9 | Финальная проверка была слабой (только ядро/grub.cfg/EFI/MBR) | ✅ Исправлено агентом 2 (fstab непустой, пользователь, hostname, DM, тема GRUB, строки 513–541); перепроверено |
| B10 | `DE=none` чистит не всё: удаляются только `plasma-desktop sddm konsole dolphin plasma-nm xorg-server ttf-dejavu`, остаются `plasma-pa`, `kscreen`, `pipewire*`, `wireplumber`, `python-pyqt6` | ⏳ ОТКРЫТО (раздел 5.2) |
| B11 | Явных ошибок при падении `grub-install`/`grub-mkconfig` не было; нет предпроверки EF02 для BIOS/GPT | ✅ Исправлено агентом 3; перепроверено по коду (явные `exit 1` с сообщениями) |

### Этап C — Установщик: GUI (Rust)

| # | Проблема | Статус |
|---|---|---|
| C1 | Конфиг установки с паролями создавался с правами 644 на время записи | ✅ Исправлено агентом 2 (`OpenOptionsExt::mode(0o600)` + `set_permissions`, `install.rs`); перепроверено |
| C2 | Окно можно было закрыть во время установки — дочерний `xros-install` продолжал разметку без UI | ✅ Частично: `CancelClose` + блокировка кнопок (`app.rs:441`, `add_enabled(!self.installing)`); убийство дочернего процесса при отмене НЕ сделано — см. C5 |
| C3 | `--step` открывал любой шаг, включая Finish | ✅ Исправлено агентом 2 (`start_step.min(STEPS.len() - 2)` — максимум шаг 8, `app.rs:178`); перепроверено |
| C4 | Финиш назывался иначе, чем в ТЗ | ✅ Исправлено агентом 2: «XrOS успешно установлена», чекбокс перезагрузки включён по умолчанию, кнопка «Завершить» (`steps.rs:414`); перепроверено |
| C5 | Убийство дочернего `xros-install` при отмене установки не реализовано | ⏳ ОТКРЫТО (раздел 5.1). Проверено финальным агентом: из GUI отмена во время установки невозможна (кнопка «Отмена» неактивна, закрытие запрещено), риск остаётся только при внешнем убийстве GUI (kill/падение) |
| C6 | `cargo clippy -- -D warnings`: 2 ошибки — `needless_range_loop` (`app.rs:344`) и `useless_format` (`steps.rs:336`) | ✅ Найдено и исправлено финальным агентом (см. раздел 3.5) |
| C7 | Rust-код агента 2 не компилировался им (нет cargo на хосте) | ✅ Скомпилировано финальным агентом в chroot: `cargo check` и `cargo build --release` — 0 ошибок (раздел 4.1) |

### Этап D — Загрузчик

| # | Проблема | Статус |
|---|---|---|
| D1 | `bios.grub` в archiso 92 НЕ СУЩЕСТВУЕТ (проверено grep по `mkarchiso`: 0 совпадений; есть только `bios.syslinux`, `uefi.grub`, `uefi.systemd-boot`) | ✅ Подтверждено финальным агентом по `profiledef.sh` и комментариям агента 3; live-ISO — только UEFI (`bootmodes=('uefi.grub')`) |
| D2 | `profile/syslinux/` и `profile/efiboot/` присутствовали в профиле | ✅ Удалены агентом 3 (резерв `/tmp/xros-bootloader-backup-20261110/`); отсутствие проверено |
| D3 | `grub.cfg`: пути `${prefix}` не работают в live-GRUB (memdisk), шрифты/тема молча не находились | ✅ Исправлено агентом 3 (пути `/boot/grub/...`, `gfxterm`); перепроверено чтением файла |
| D4 | `loopback.cfg` не передавал ядру `img_dev`/`img_loop` — загрузка ISO из GRUB падала | ✅ Переписан агентом 3 по образцу releng; перепроверено чтением файла |
| D5 | Шрифтов DejaVu `.pf2` не было в теме — тема не грузилась целиком | ✅ Добавлены агентом 3 (`DejaVuSans-12/14/Bold-16.pf2`); наличие проверено |
| D6 | Secure Boot: подписанной цепочки нет (shim/MOK, подпись ядра/GRUB) | ✅ Зафиксировано: НЕ поддерживается, нигде не заявляется (ARCHITECTURE.md §7) |
| D7 | `menu_color_highlight=white/indigo` и `color_highlight=white/indigo` в `grub.cfg`/`loopback.cfg` — `indigo` НЕ входит в 16 стандартных имён цветов GRUB (агентами не замечен) | ✅ Найдено и исправлено финальным агентом → `white/magenta` (оба файла) |
| D8 | Пункты Memtest86+ и UEFI Shell в меню при отсутствующих пакетах | ⏳ ОТКРЫТО (раздел 5.3): пункты защищены `-f` и скроются, пакетов `memtest86+-efi`/`edk2-shell` в списке нет |

### Этап E — Пакеты и репозиторий

| # | Проблема | Статус |
|---|---|---|
| E1 | **БЛОКЕР:** Plasma 6.8 убрала X11-сессию полностью (`plasma-x11-session` удалён из Arch, `plasma-workspace` 6.8.2 конфликтует) | ✅ Подтверждено агентом 4 (archlinux.org, 10.11.2026); пакет удалён из `packages.x86_64`, `DE_PKGS` и списков удаления; живая система — Plasma (Wayland) |
| E2 | `xorg-server` — кандидат на удаление (в Plasma 6.8 от него ничего не зависит) | ⏳ ОТКРЫТО: оставлен до ретеста Wayland в QEMU (раздел 5.4) |
| E3 | Не хватало `linux-firmware`, `pipewire`, `pipewire-pulse`, `wireplumber`, `ntfs-3g`, `kscreen` | ✅ Добавлены агентом 4; наличие проверено диагностикой |
| E4 | В списке были `syslinux`, `kdialog` | ✅ Удалены агентом 4; отсутствие проверено |
| E5 | 3 ошибки компиляции Rust (unsafe `getuid`, `scroll.bar_width` в egui 0.32, `1.5_f32`) | ✅ Исправлены агентом 4; финальный агент пересобрал оба проекта с 0 ошибок |
| E6 | Автообновления через неподписанный/несуществующий репозиторий — дыра | ✅ Выключены агентом 4: `enable xros-update.timer` убран из движка; юниты остаются в пакете инертными; проверено grep по `src/` и `profile/airootfs/` |
| E7 | `xros.example` упоминался без пометки в `profiledef.sh:9` (`iso_publisher`) и в `os-release` (`customize_airootfs.sh:128-131`) | ✅ Исправлено финальным агентом: добавлены комментарии `PLACEHOLDER` в обоих местах |
| E8 | `ANSI_COLOR` в os-release — старый цвет (см. A3) | ✅ Исправлено финальным агентом |
| E9 | `DISPLAY=:0`/`XAUTHORITY` в `xros-welcome.service` и `.xprofile` — X11-наследие; под Wayland `.xprofile` не выполняется | ⏳ ОТКРЫТО (раздел 5.5): зона приветствия, проверка/правка на этапе QEMU |
| E10 | `banner.txt` без исходника в `branding/` (единственная копия — в airootfs) | ⏳ ОТКРЫТО (раздел 5.6): задокументировано в PKGBUILD и ARCHITECTURE.md |

### Этап F — Документация и диагностика

| # | Проблема | Статус |
|---|---|---|
| F1 | Старая диагностика ожидала `syslinux`/`systemd-boot` и старую строку финиша — давала ложные FAIL (старый запуск: PASS=51 FAIL=4 SKIP=2) | ✅ Диагностика переписана финальным агентом (этап E): 134 проверки, см. раздел 4.3 |
| F2 | Упоминания другого проекта (`AKVT`) в комментариях PKGBUILD/`build.sh`/`repo/README.md` роняли проверку «нет следов» | ✅ Переформулированы финальным агентом; происхождение рецепта — только в ARCHITECTURE.md §2; путь к chroot-скрипту в `build.sh` — документированное исключение (см. раздел 6.5) |
| F3 | `scripts/build.sh:45` ссылался на несуществующий `./build-chroot.sh` | ✅ Исправлено финальным агентом: указан реальный путь `~/workspace/akvt-os/build-chroot.sh` |
| F4 | `makepkg` нельзя запускать от root; пользователя `hatch` внутри chroot нет (комментарий в `build.sh` «от пользователя hatch внутри chroot» неверен) | ✅ Выяснено финальным агентом: для проверки создан временный пользователь `xrosbuild` (uid 1001), после проверок удалён; см. раздел 4.2 |
| F5 | `profiledef.sh` называл bootmodes «BIOS+UEFI», `ARCHITECTURE.md` описывал syslinux/systemd-boot как используемые | ✅ Исправлено финальным агентом (переписан ARCHITECTURE.md) |

### Этап G — Сборка ISO

| # | Проблема | Статус |
|---|---|---|
| G1 | ISO не собран; сборка — только после явного разрешения Мии | ⏳ ЗАПЛАНИРОВАНО (план — раздел 6) |
| G2 | Рецепт ручного pacstrap + маркеры `_run_once` из другого проекта НЕПРОВЕРЕН для XrOS и не может считаться гарантированным | ✅ Зафиксировано в ARCHITECTURE.md §2 и `scripts/build.sh`: основной путь — штатный archiso |
| G3 | QEMU не запускался (нет ISO) | ⏳ ЗАПЛАНИРОВАНО (план тестов — ARCHITECTURE.md §10) |

---

## 2. Принятые решения (с обоснованием и источниками проверки)

| Решение | Обоснование / источник |
|---|---|
| Загрузчик — только GRUB; live-ISO — только UEFI (`bootmodes=('uefi.grub')`) | `bios.grub` не существует в archiso 92 (grep по `mkarchiso`: 0 совпадений; только `bios.syslinux`, `uefi.grub`, `uefi.systemd-boot`). Источник: агент 3 + комментарий в `profiledef.sh:14-23`. Альтернативы — на решение Мии (раздел 7.1) |
| Secure Boot НЕ поддерживается и не заявляется | Нет подписанной цепочки (shim/MOK). Заявлять поддержку без неё — ложь |
| Живая система — Plasma 6.8 Wayland (X11-сессии нет) | `plasma-x11-session` удалён из Arch, `plasma-workspace` 6.8.2 конфликтует. Источник: агент 4 (archlinux.org, 10.11.2026). Ретест в QEMU обязателен |
| Новая палитра — единственная (`#08080D`/`#111018`/`#8B00FF`/`#B66AFF`/`#F5F3FA`/`#A6A0B3`/`#30283B`) | Редизайн Мии от 10.11.2026; единый источник — `branding/design-tokens.css`; старые цвета — 0 совпадений по проекту (кроме этого отчёта) |
| Логотип — только символ X, прозрачный PNG | Исходник Мии `xros-logo-real.png` (RGBA); углы alpha=0 проверены PIL; пыль alpha<5 вычищена |
| Обои по умолчанию — присланные Мией (с X и текстом «XrOS»), 1920×1080 | Мия прислала их именно как обои; апскейл ×1,149 LANCZOS без кропа (PIL: 1920×1080). Противоречие с правилом «логотип с текстом — только с утверждения» — на её решение (раздел 7.2) |
| Автообновления ВЫКЛЮЧЕНЫ | Репозиторий не подписан (`SigLevel Optional TrustAll`), сервер `xros.example` не существует. Автообновление с такого источника — дыра. Включение — отдельным шагом после публикации и GPG-подписи |
| `xros.example` — PLACEHOLDER везде | Домен не существует; каждая строка с ним сопровождается `PLACEHOLDER` (проверяется диагностикой, раздел 13г) |
| Основной путь сборки — штатный archiso | Рецепт ручного pacstrap + маркеры не проверен для XrOS (другой список пакетов, другая версия archiso, причина падения не установлена). Обход — только при воспроизводимом падении штатного пути и после разбора причины |
| `selected_item_color #F5F3FA` в теме GRUB | Контраст 5,39:1 на фоне `#8B00FF` против 1,83:1 у `#B66AFF` (данные агента брендинга; исправлено финальным агентом в обеих копиях `theme.txt`) |
| Fallback-цвета GRUB `white/magenta` | `indigo` — невалидное имя цвета GRUB (допустимы только 16 стандартных). Найдено и исправлено финальным агентом |
| `xros-welcome.service` включён глобально (`systemctl --global enable`) + `Hidden=true`-toggle | Под Wayland `.xprofile` не выполняется; service — единственный надёжный запуск. Toggle проверен чтением `src/xros-welcome-gui:171-200` |
| Убийство дочернего процесса при отмене — НЕ реализовано | Из GUI отмена во время установки невозможна (CancelClose + неактивная кнопка), поэтому риск только при внешнем убийстве GUI. Реализация (PDEATHSIG/process-group) требует изменений в `install.rs`/`app.rs` и проверки запуском GUI — отложено, задокументировано как открытая проблема |

---

## 3. Исправленные ошибки (файлами)

### 3.1 Финальным агентом (10.11.2026, в ходе этого аудита)

| Файл | Исправление |
|---|---|
| `profile/grub/theme/theme.txt`, `profile/airootfs/usr/share/xros/grub-theme/theme.txt` | `selected_item_color #b66aff` → `#f5f3fa` (+ комментарий о контрасте 5,39:1) |
| `profile/grub/grub.cfg`, `profile/grub/loopback.cfg` | `white/indigo` → `white/magenta` (невалидное имя цвета GRUB) |
| `profile/airootfs/root/customize_airootfs.sh` | `ANSI_COLOR 38;2;108;92;231` → `38;2;139;0;255`; добавлен `PLACEHOLDER`-комментарий к URL os-release |
| `profile/profiledef.sh` | Добавлен `PLACEHOLDER`-комментарий к `iso_publisher` (`xros.example`) |
| `branding/README.md` | Удалено упоминание `profile/syslinux/splash.png` |
| `packages/xros-cli/PKGBUILD`, `packages/xros-installer/PKGBUILD`, `packages/xros-welcome/PKGBUILD`, `packages/xros-branding/PKGBUILD`, `repo/README.md`, `scripts/build.sh` | Упоминания другого проекта в комментариях переформулированы (происхождение рецепта — только в ARCHITECTURE.md §2) |
| `scripts/build.sh` | Исправлен путь к chroot-скрипту (`./build-chroot.sh` → `~/workspace/akvt-os/build-chroot.sh`); опечатка «чрут» → «chroot» |
| `src/xros-install-gui-rs/src/app.rs` | Clippy `needless_range_loop`: `for i in 0..STEPS.len()` → `for (i, step_name) in STEPS.iter().enumerate()` (+ `STEPS[i]` → `step_name`) |
| `src/xros-install-gui-rs/src/steps.rs` | Clippy `useless_format`: `format!("Загрузчик: GRUB (UEFI/BIOS)")` → `"…".to_string()` |
| `packages/xros-installer/xros-install-gui`, `profile/airootfs/usr/local/bin/xros-install-gui` | Перестейджен новый бинарь после clippy-фикса (sha256 `5e470eaa…`, см. раздел 4.1) |
| `repo/xros/os/x86_64/xros-installer-1.0-1-x86_64.pkg.tar.zst`, `xros.db.tar.gz`, `xros.files.tar.gz` (+ снимки в `profile/airootfs/usr/share/xros/repo/…`) | Пакет пересобран с новым бинарём, БД перегенерирована (`repo-add`, 4 пакета) |
| `scripts/xros-diagnose.sh` | Полностью переписан: 134 проверки (было 56), см. раздел 4.3 |
| `ARCHITECTURE.md` | Полностью переписан под результаты аудита (новая палитра, GRUB-only/UEFI-only, Wayland, выключенные автообновления, PLACEHOLDER, статусы РЕАЛИЗОВАНО/ЗАПЛАНИРОВАНО/НЕПРОВЕРЕНО) |

### 3.2 Агентами аудита (перепроверено финальным агентом)

- **Брендинг:** прозрачный логотип, обои 1920×1080, новая палитра везде
  кроме ARCHITECTURE.md (добито финальным агентом), `preview/index.html`
  под новую палитру + блок экрана завершения, `theme.txt` — новая палитра.
- **Установщик/безопасность:** `%q`, защита от диска с ISO, проверка
  диска, `sudo --preserve-env`, `resolv.conf` после сетевых операций,
  `machine-id`, автовход GDM/Sway, отключение всех DM, расширенная
  финальная проверка, `umask 077`, конфиг 0600, `CancelClose`,
  `--step ≤ 8`, финиш «XrOS успешно установлена», welcome service
  `systemctl --global enable` + `Hidden=true`.
- **Загрузчик:** `bootmodes=('uefi.grub')`, удалены `profile/syslinux/`
  и `profile/efiboot/`, исправлены `grub.cfg`/`loopback.cfg`,
  добавлены DejaVu `.pf2`, явные ошибки `grub-install`/`grub-mkconfig`,
  предпроверка EF02.
- **Пакеты:** удалены `plasma-x11-session`, `syslinux`, `kdialog`;
  добавлены `linux-firmware`, `pipewire`, `pipewire-pulse`,
  `wireplumber`, `ntfs-3g`, `kscreen`; 3 ошибки Rust исправлены;
  4 PKGBUILD переписаны; автообновления выключены; `xros.example`
  помечен PLACEHOLDER (кроме 2 мест — добито финальным агентом).

---

## 4. Результаты тестов

### 4.1 Rust (chroot, cargo/rustc 1.99.1, `--offline`)

| Проверка | Результат |
|---|---|
| `cargo check` xros-cli | PASS, 0 ошибок (2,40 с) |
| `cargo check` xros-install-gui | PASS, 0 ошибок (1 мин 18 с) |
| `cargo clippy -- -D warnings` xros-cli | PASS |
| `cargo clippy -- -D warnings` xros-install-gui | **Сначала FAIL (2 ошибки)**, после фикса — PASS (см. 3.1) |
| `cargo build --release` xros-cli | PASS (2,07 с), 516 720 Б, sha256 `9c67cfdcc1b50998e05be1d0c9efd6d1325473731b8b7de6971ebe049954e1aa` |
| `cargo build --release` xros-install-gui (до clippy-фикса) | PASS (6 мин 36 с), 11 247 144 Б, sha256 `36af32cf…` — байтово совпал со staged-копией, что подтвердило её свежесть |
| `cargo build --release` xros-install-gui (после clippy-фикса) | PASS (12,16 с), 11 247 128 Б, sha256 `5e470eaa4bbb2777c94e23fafceecdb2c42373a30eaa76ccd56f94a03190024f` — перестейджен в `packages/xros-installer/` и `profile/airootfs/usr/local/bin/` |
| `Cargo.lock` | В обоих проектах; сборка в chroot не изменила их (diff — пусто) |

### 4.2 Пакеты (chroot, от временного пользователя `xrosbuild`)

| Проверка | Результат |
|---|---|
| `makepkg --printsrcinfo` (4 PKGBUILD) | PASS × 4 |
| `makepkg --nodeps` xros-cli / xros-branding / xros-welcome / xros-installer | PASS × 4 (в правильном дереве проекта; первая попытка в плоском каталоге дала ложные FAIL в `prepare()` — `prepare()` сверяется с `$startdir/../../branding|src`, поэтому собирать надо из дерева проекта) |
| Свежесобранный `xros-cli` vs снимок в `repo/` | Списки файлов совпадают; содержимое всех файлов (кроме `.PKGINFO`/`.MTREE`/`.BUILDINFO`) побайтово совпадает; отличается только `builddate` (1794292462 vs 1794291622) — ожидаемо |
| `xros-installer` после clippy-фикса | Пересобран; бинарь внутри пакета = stripped-версия нового бинаря (тот же BuildID `118ced95…`, sha после strip `c7cdb685…` совпала) |
| `repo-add` (БД перегенерирована) | 4 пакета в `xros.db.tar.gz` (`xros-branding`, `xros-cli`, `xros-installer`, `xros-welcome`); снимок в airootfs синхронен с `repo/` (`diff -r` — пусто) |
| `grub-script-check` grub.cfg / loopback.cfg | PASS × 2 (код выхода 0, в chroot) |

Примечания: `makepkg` от root запрещён, пользователя `hatch` в chroot
нет — для проверок создан временный пользователь `xrosbuild` (uid 1001),
после проверок удалён вместе с домашним каталогом и временными файлами
(`/root/xros-build`, `/root/xros-pkg`, `/home/xrosbuild`,
`/root/makepkg-check*.sh`, `/root/pkgcmp-old.pkg.tar.zst`).
В chroot `/tmp` — tmpfs (монтируется при каждом запуске
`build-chroot.sh`), поэтому временные файлы туда не класть.

### 4.3 Диагностика (`scripts/xros-diagnose.sh`)

| Запуск | PASS | FAIL | SKIP | Итог |
|---|---|---|---|---|
| Старая диагностика, до аудита | 51 | 4 | 2 | FAIL: ложные срабатывания (ожидались syslinux/efiboot, старая строка финиша, упоминания другого проекта) |
| Новая диагностика, первый прогон | 118 | 3 | 13 | FAIL: старые цвета и `xros.example` без PLACEHOLDER в ARCHITECTURE.md; путь к чужому chroot в `build.sh` |
| Новая диагностика, финальный прогон | **121** | **0** | **13** | **PASS, код выхода 0** |

SKIP (13) — честные, не замаскированные PASS:
`shellcheck` (1 — нет на хосте), `cargo check`/`clippy` (4 — нет cargo
на хосте; проверено в chroot, раздел 4.1), `makepkg --printsrcinfo`
(4 — нет makepkg на хосте; проверено в chroot, раздел 4.2),
`grub-script-check` (2 — нет на хосте; проверено в chroot),
`memtest86+-efi`/`edk2-shell` (2 — пакетов нет в списке, пункты меню
скроются; см. раздел 5.3).

Полный вывод финального прогона — в приложении А.

### 4.4 Сверка (канон: `src/` и `branding/`)

| Сверка | Результат |
|---|---|
| `src/xros-install` == `profile/airootfs/usr/local/bin/xros-install` == `packages/xros-installer/xros-install` | ✅ Совпадают (`diff` — пусто) |
| `src/xros-welcome-gui` == airootfs == `packages/xros-welcome/xros-welcome-gui` | ✅ Совпадают (`cmp`) |
| `src/xros-welcome` == airootfs | ✅ Совпадают |
| `theme.txt` профиль == airootfs | ✅ Совпадают (включая контраст-фикс) |
| `profile/pacman.conf` == `profile/airootfs/etc/pacman.conf` | ✅ Совпадают |
| 6 файлов `branding/*` == airootfs == `packages/xros-branding/*` (+ `grub-bg.*` == тема GRUB и `splash.*`) | ✅ Совпадают (sha256) |
| `packages/xros-cli/xros` == airootfs `xros` | ✅ Совпадают |
| `packages/xros-installer/xros-install-gui` == airootfs | ✅ Совпадают (новый бинарь после clippy-фикса) |
| `banner.txt` пакет == airootfs | ✅ Совпадают |
| `xros-welcome.service` / `.desktop` пакет == airootfs | ✅ Совпадают |

### 4.5 Превью (`preview/index.html`)

- Все пути к ресурсам существуют (`design-tokens.css`, `wallpaper.jpg`,
  `xros-logo*.png`, `grub-bg.jpg`) — проверено диагностикой.
- Новая палитра (`#08080D`/`#8B00FF`/`#B66AFF`), прозрачный логотип,
  блок экрана завершения («XrOS успешно установлена», чекбокс
  перезагрузки включён, кнопка «Завершить») — на месте.
- Выбранный пункт меню GRUB в превью — белый текст на `#8B00FF`,
  что соответствует исправленному `selected_item_color #F5F3FA`.

---

## 5. Оставшиеся проблемы

### 5.1 Убийство дочернего `xros-install` при отмене установки — ✅ ИСПРАВЛЕНО (финальная доработка 10.11.2026)

GUI отслеживает дочерний процесс через `InstallHandle`:
`pre_exec` ставит `PR_SET_PDEATHSIG (SIGTERM)` + проверку
`getppid()` (гонка fork→prctl закрыта) + `setsid()` (своя группа
процессов — для отмены и для внуков `rsync`/`arch-chroot`).
Отмена: SIGTERM группе → 5 с → SIGKILL группе; `Drop` —
последняя страховка. Движок ловит `HUP`/`TERM`/`INT` ловушкой
(идемпотентный cleanup: гашение потомков, `umount -R`, удаление
временных файлов, `sync`, коды 129/130/143) + фоновый сторож
родителя (PPID раз в секунду — bash откладывает ловушку, пока
ждёт `rsync`/`mkfs`). Кнопка «Остановить установку» — на шаге
Install, с подтверждением. Тест `scripts/tests/test-child-process.sh`:
**33 PASS / 0 FAIL (×3 прогона)**. Не проверено без живой системы:
реальное падение GUI посреди `rsync`, отмена кнопкой в реальном
GUI — только в QEMU. Подробно — `docs/final-refinement/child-process.md`.

### 5.2 `DE=none` чистит не всё — ✅ ИСПРАВЛЕНО (финальная доработка 10.11.2026)

При выборе «Без графики» движок удаляет точный список
`XROS_GRAPHICS_PKGS` (15 пакетов: plasma-*, sddm, konsole,
dolphin, pipewire*, wireplumber, xorg-server, шрифты,
python-pyqt6, libxkbcommon-x11) + чистка сирот `pacman -Qtdq`
+ удаление `sddm.conf.d` и KDE-настроек из `/etc/skel` +
проверка результата (`pacman -Q`: графики нет, база `linux grub
networkmanager sudo openssh` на месте); цель по умолчанию
`multi-user.target`, офис при `none` пропускается. KDE:
`plasma-desktop plasma-nm plasma-pa kscreen sddm konsole dolphin`
(`xorg-server` убран — Plasma 6.8 Wayland). Все 7 вариантов DE
реально реализуемы (проверено по sync-БД Arch). Тест
`scripts/tests/test-de-none.sh`: **56 PASS / 0 FAIL**
(до исправлений было 22/14). Реальная установка с `DE=none` —
НЕПРОВЕРЕНО, только в QEMU. Подробно —
`docs/final-refinement/de-none.md`.

### 5.3 Memtest86+ / UEFI Shell: пунктов меню не будет — ✅ РЕШЕНО (финальная доработка 10.11.2026)

Пункты **удалены** из `profile/grub/grub.cfg` и
`profile/grub/loopback.cfg` (пакеты `memtest86+-efi` и
`edk2-shell` в `profile/packages.x86_64` отсутствуют, файлы
на ISO не попадут; фиктивных файлов не создавалось).
В меню только рабочие пункты: XrOS, speaking, настройки UEFI,
выключение, перезагрузка. Пакеты существуют в Arch
(`memtest86+-efi 9.00-1`, `edk2-shell 202608-1`) — вернуть
можно, добавив их в список пакетов и `menuentry` с `-f`.
Подробно — `docs/final-refinement/bootloader.md`.

### 5.4 `xorg-server` — кандидат на удаление

В Plasma 6.8 от него ничего не зависит. Удаление — после ретеста
Wayland в QEMU (если рабочий стол стабилен без него).

### 5.5 Приветствие под Wayland — X11-наследие — ✅ ИСПРАВЛЕНО (финальная доработка 10.11.2026)

Удалены два параллельных механизма запуска: `systemd user
xros-welcome.service` (с `DISPLAY=:0`/`XAUTHORITY`) и
`~/.xprofile` (под Wayland не выполняется). Остался только
`/etc/xdg/autostart/xros-welcome.desktop` — штатный механизм
KDE, работает и в Wayland, и в X11; `WAYLAND_DISPLAY`/
`XDG_RUNTIME_DIR` наследуются от сессии. `flock` сохранён
(страховка от дублей). Исправлен баг галочки «Запускать при
старте» (ложно показывалась выключенной при дефолте);
добавлен флаг `--manual` и пункт меню для ручного запуска.
Проверено: `py_compile` (3 копии), `bash -n`, гейт `main()`
на реальном коде 3/3 + логика галочки 3/3. Реальный запуск
в Plasma Wayland — НЕПРОВЕРЕН, только в QEMU. Дополнительно
исправлено координатором: `main.rs` GUI-установщика теперь
сохраняет `WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR` через sudo
(иначе root-процесс под Wayland падал бы на XWayland).
Подробно — `docs/final-refinement/welcome-wayland.md`.

### 5.6 `banner.txt` без исходника в `branding/` — ✅ ИСПРАВЛЕНО (финальная доработка 10.11.2026)

Исходник заведён в `branding/banner.txt`; все копии (airootfs,
пакет `xros-branding`) создаются из него через
`scripts/make-branding.py` и сверяются по SHA256
(диагностика §19д).

### 5.7 Остаток syslinux

`profile/syslinux/` удалён полностью (проверено). Остаток —
только резервная копия в `/tmp/xros-bootloader-backup-20261110/syslinux/splash.png`
(600 КБ, временный каталог вне проекта, не часть XrOS) и
упоминания syslinux как исторического факта в документации.
Удалять резерв до успешной сборки ISO не следует.

### 5.8 Прочее

- `xros` CLI: `xros` открывает сайт через `xdg-open`; в живой
  системе браузера по умолчанию нет — появится диалог выбора
  браузера (не баг, поведение системы).
- Полная установка через GUI до конца в QEMU не проверена
  (нет ISO); консольный движок end-to-end не тестировался.
- `profile/grub/splash.jpg/png` — копии `grub-bg.*`
  (синхронность проверена `cmp`).

---

## 6. План сборки ISO (этап G — НЕ запускать без разрешения Мии)

### 6.1 Предусловия

1. Разрешение Мии на сборку (этап 10) + её решения из раздела 7
   (минимум — п. 7.1 про UEFI-only).
2. Закрыты или явно приняты открытые проблемы раздела 5
   (5.1, 5.2, 5.3, 5.5, 5.6 — закрыты финальной доработкой
   10.11.2026, см. раздел 8; остались 5.4, 5.7, 5.8 — не блокируют).
3. Финальный прогон `./scripts/xros-diagnose.sh` — FAIL=0.
4. Свежие бинари и пакеты (пересборка по `scripts/build.sh`, этап 2).

### 6.2 Шаги (основной путь — штатный archiso)

```bash
cd ~/workspace/xros
./scripts/xros-diagnose.sh            # должен быть PASS, FAIL=0
./scripts/build.sh --confirm          # ТОЛЬКО с явного разрешения
# внутри build.sh:
#   1. Собрать Rust-бинари (офлайн, в chroot; см. build.sh, этап 2)
#   2. Застейджить бинари и исходники рядом с PKGBUILD
#   3. Собрать пакеты: cd packages/<пакет> && makepkg (в chroot,
#      от непривилегированного пользователя)
#   4. repo-add в repo/xros/os/x86_64/ + обновить снимок в airootfs
#   5. mkarchiso -v -w work -o out profile
#   6. Проверить ISO: sha256, размер, наличие /boot/grub/grub.cfg
```

### 6.3 Если штатный путь упадёт

- **СТОП.** Разобрать причину (лог mkarchiso, `Write failed`/`EPERM`,
  место падения), зафиксировать.
- Только при воспроизводимом падении на pacstrap полного списка —
  пробовать НЕПРОВЕРЕННЫЙ обход (ручной pacstrap + маркеры
  `_run_once`, см. ARCHITECTURE.md §2), только с явного разрешения.
- Обход без разбора причины не применять.

### 6.4 После сборки — QEMU (11 пунктов, см. ARCHITECTURE.md §10)

1. Живая загрузка UEFI, рабочий стол KDE виден (скриншот).
2. Ретест Plasma 6.8 Wayland (нет чёрного экрана, `plasmashell` жив).
3. Одно окно приветствия после входа (проверка 5.5).
4. Ярлык «Установить XrOS» на рабочем столе.
5. Установка через GUI (UEFI), создание пользователя, GRUB.
6. Установка на BIOS (установленная система; live-ISO BIOS не грузится).
7. Первая загрузка установленной системы, SDDM-логин.
8. Перезагрузка из установленной системы.
9. Экран Finish + перезагрузка по чекбоксу и без него.
10. Журналы без критических ошибок (`journalctl`, `Failed to start`,
    kernel panic, segv plasmashell/sddm).
11. Пункты меню GRUB: только рабочие (Memtest86+ / UEFI Shell
    удалены из меню — см. 5.3); скриншоты каждого шага.

### 6.5 Зависимость от чужого chroot — ✅ УБРАНА (финальная доработка 10.11.2026)

Собственный build environment — `scripts/xros-build-env.sh`:
свой каталог `build-env/`, rootfs из официального Arch
bootstrap-тарболла (проверка GPG-подписи), `pacman -r`,
`systemd-nspawn` (запасной путь — `unshare`+`chroot`),
`makepkg` от непривилегированного `builder`, `grub-script-check`.
`scripts/build.sh` больше не ссылается на чужой проект
(`grep akvt` по `scripts/` — 0 совпадений).
Статус: скрипты готовы, проверены в dry-run (честный отказ
без rootfs: не хватает `zstd` и самого rootfs); полноценный
rootfs НЕ создан (`--init` — отдельный шаг, ~120 МБ bootstrap
+ ~2–3 ГБ пакетов; первая сборка Rust — онлайн). До `--init`
проверки Rust/`makepkg`/`grub-script-check` выполняются
в chroot другого проекта только как временная мера
(временные каталоги и пользователь удаляются после проверок).
Подробно — `docs/final-refinement/build-env.md`.

**Обновление 10.11.2026 (финальный этап, §9):** rootfs создан
(`build-env/root.x86_64` 3.2 ГБ, маркеры `init-done` +
`deps-fetched`, builder uid 1000, rust/cargo 1.99.1, grub 2.16,
pacman 7.1.0); Rust пересобран, все 4 пакета собраны от builder.
Проверки больше не зависят от чужого chroot.

---

## 7. Решения для Мии

### 7.1 Загрузка live-ISO: UEFI-only vs syslinux vs custom BIOS-GRUB

**Факт:** в archiso 92 режима `bios.grub` не существует. Live-ISO
сейчас грузится **только по UEFI**. Варианты:

- **(а) Принять UEFI-only live-ISO.** Плюсы: ничего не делать,
  GRUB везде. Минусы: старые BIOS-машины (без UEFI) не загрузятся
  с ISO вообще. Установленная система на BIOS при этом GRUB получает.
- **(б) Вернуть `bios.syslinux`.** Плюсы: BIOS-загрузка live-ISO
  работает штатно. Минусы: два загрузчика в ISO (GRUB для UEFI,
  syslinux для BIOS), syslinux возвращается в профиль и пакеты.
- **(в) Кастомный BIOS-GRUB через xorriso.** Плюсы: GRUB везде,
  один загрузчик. Минусы: ручная постобработка ISO вне mkarchiso
  (El Torito `core.img`), нестандартно, требует разработки и тестов.

**Исследование (финальная доработка 10.11.2026,
`docs/boot-bios-grub.md`):** образ `i386-pc-eltorito` собран
(`grub-mkimage`, GRUB 2.16, 334 195 Б) и прошёл
`grub-script-check`; подводные камни найдены практически
(`--sbat` для BIOS запрещён, модуль поиска по метке —
`search_label`, а не `search_fs_label`); прецедент —
`grub-mkrescue`. Но **загрузка НЕ тестировалась** (ISO не
собирался) — рецепт не является работающей фичей до тестов
в QEMU. Рекомендация исследователя: для первого релиза — **(а)**,
если BIOS нужен — **(в)**, а не (б). В основную сборку ничего
не внедрено. Решение — за Мией.

**Обновление 10.11.2026 (финальный этап, §9):** вариант (в) проверен
загрузкой в QEMU (BIOS CD, BIOS USB, UEFI-регрессия — PASS,
`docs/boot-bios-grub.md`). Рекомендация та же; внедрение —
только после решения Мии.

### 7.2 Обои с текстом «XrOS» по центру — ✅ РЕШЕНО Мией 10.11.2026

Основной вариант обоев — **без надписи «XrOS»**: надпись убрана
инпейнтингом (диффузия Лапласа, `scripts/make-branding.py`),
X и острия целы, следов маски нет (проверено глазами на полном
кадре и кропе 2×; исходник `wallpaper-real.png` не тронут).
Обои 1920×1080, отдельный графический ресурс не понадобился.

### 7.3 Домен вместо `xros.example`

Сейчас везде PLACEHOLDER: репозиторий, сайт, os-release,
`iso_publisher`. Какой настоящий домен? Без него публикация
репозитория и автообновления невозможны.

### 7.4 Часовой пояс по умолчанию

Сейчас `Europe/Astrakhan`. Подтвердить или назвать другой.

### 7.5 Офис по умолчанию

Сейчас «Не устанавливать». Подтвердить или выбрать
LibreOffice / только просмотр (Okular).

### 7.6 Ретест Wayland в QEMU

После сборки ISO нужно подтвердить, что Plasma 6.8 Wayland
в QEMU работает (не чёрный экран). Это проверка, а не решение,
но без неё нельзя удалять `xorg-server` и финализировать
живую систему.

---

## 8. Финальная доработка перед первой сборкой ISO (10.11.2026)

Выполнено после аудита (этапы A–G), до сборки ISO. ISO **не собирался**,
QEMU **не запускался**, `scripts/build.sh`/`mkarchiso` не запускались.
Резервная копия проекта до правок: `/tmp/xros-backup-20261110`
(git в проекте нет). Детальные отчёты по каждому направлению —
`docs/final-refinement/*.md`.

### 8.1 Что исправлено

| # | Задача | Итог |
|---|---|---|
| 1 | Загрузчик: BIOS-GRUB, Memtest/Shell | `bios.grub` в archiso 92 **подтверждённо отсутствует** (README.profile.rst + функции `_make_bootmode_*` в mkarchiso). Исследование BIOS-GRUB через El Torito + xorriso: образ `i386-pc-eltorito` (GRUB 2.16, 334 195 Б) собран, `grub-script-check` PASS; загрузка НЕ тестировалась — в основную сборку НЕ внедрено, только `docs/boot-bios-grub.md`. Пункты Memtest86+ и UEFI Shell **удалены** из `grub.cfg`/`loopback.cfg` (пакеты в живой системе отсутствуют, фиктивных файлов нет). Меню: 5 рабочих пунктов. `grub-script-check` обоих файлов — PASS. |
| 2 | Отмена установки (критично) | GUI: `InstallHandle`, `PR_SET_PDEATHSIG` + проверка `getppid()` + `setsid()` (своя группа процессов), отмена SIGTERM группе → 5 с → SIGKILL, `Drop`-страховка, кнопка «Остановить установку». Движок: ловушки `HUP`/`TERM`/`INT` + идемпотентный cleanup + фоновый сторож родителя (PPID раз в секунду). Конфиг с паролями удаляется и при ошибке `spawn`. Тест `scripts/tests/test-child-process.sh` — **33 PASS / 0 FAIL (×3)**. |
| 3 | Приветствие под Wayland | Только `xdg/autostart` (service с `DISPLAY=:0`/`XAUTHORITY` и `.xprofile` удалены). Исправлен баг галочки автозапуска, добавлен флаг `--manual` + пункт меню. `main.rs` GUI-установщика: `WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR` в `--preserve-env` sudo. Реальный запуск в Plasma Wayland — только в QEMU. |
| 4 | `DE=none` | Точный список удаления `XROS_GRAPHICS_PKGS` (15 пакетов — в тексте этапа стояло «16» по ошибке подсчёта, см. §9.3) + чистка сирот + `multi-user.target` + защита от офиса; KDE дополнен (`plasma-nm plasma-pa kscreen`, без `xorg-server`). Все 7 вариантов DE реально реализуемы. Тест `scripts/tests/test-de-none.sh` — **56 PASS / 0 FAIL** (было 22/14). |
| 5 | Свой build environment | `scripts/xros-build-env.sh` (новый, ~600 строк): свой `build-env/`, rootfs из Arch bootstrap (GPG), `pacman -r`, `systemd-nspawn` (запасной путь `unshare`+`chroot`), `makepkg` от `builder`, `grub-script-check`. `build.sh` больше не ссылается на чужой проект (`grep akvt` по `scripts/` — 0). Dry-run PASS; rootfs НЕ создан (`--init` — отдельный шаг). |
| 6 | Брендинг | Обои **без надписи «XrOS»** (инпейтинг, проверено глазами; исходник не тронут). `banner.txt` — в `branding/` (канон), все копии из исходников, SHA256 синхронны. `grub-bg.*` перегенерированы из очищенных обоев. Старых цветов — 0 (кроме исторической записи в AUDIT-REPORT.md). |
| 7 | Репозиторий | Локальный репозиторий проверен (4 пакета целы, база актуальна, снимок в airootfs синхронен). `docs/REPO-PUBLISHING.md` — план публикации (домен PLACEHOLDER, HTTPS, GPG, `SigLevel Required`, ротация ключей). Автообновления выключены везде (перепроверено по коду). |
| 8 | Диагностика | Новый §19 (13 проверок), обновлены §7ж, §15, §16. Финальный итог — **PASS=165 FAIL=0 SKIP=13** (два прогона побайтово идентичны, exit 0; до доработки было 121/0/13). |
| 9 | Безопасность установщика (повторный аудит координатора) | Подтверждено: живой NOPASSWD не попадает в установленную систему, пароли не пишутся в журнал, защита от диска с ISO в обоих режимах, разрушительные действия — с подтверждением, живые следы не копируются. Найдено и исправлено: конфиг с паролями при ошибке `spawn` (п. 2), `GRUB_COLOR_HIGHLIGHT white/cyan → white/magenta`. Открыто: проверки молчат при пустом ISODISK (нештатная загрузка) — задокументировано как ограничение. Подробно — `docs/final-refinement/security-audit.md`. |
| 10 | Пакеты пересобраны | `cargo build --release` GUI — 11 267 488 Б, sha256 `52ea6a30…` (BuildID `993a47ef…`, в пакете — тот же BuildID после strip). `makepkg --nodeps` — 3 пакета с pkgrel=2 (`xros-installer`, `xros-welcome`, `xros-branding`; `xros-cli` — 1.0-1 без изменений). БД перегенерирована (`repo-add`, 4 пакета), снимок в airootfs синхронен. |

### 8.2 Результаты проверок (финальные, 10.11.2026)

| Проверка | Результат |
|---|---|
| `./scripts/xros-diagnose.sh` (×2, идентичны) | **PASS=165 FAIL=0 SKIP=13**, exit 0 (полный вывод — Приложение Б) |
| `cargo check` GUI + CLI (chroot, `--offline`) | PASS, 0 ошибок |
| `cargo clippy -- -D warnings` GUI + CLI (chroot) | PASS (ранее ошибочно считался недоступным в chroot) |
| `cargo build --release` GUI | PASS, 6 мин 35 с, 11 267 488 Б |
| `makepkg --printsrcinfo` (4 PKGBUILD, chroot) | PASS × 4 |
| `makepkg --nodeps` (3 пакета, chroot, от `xrosbuild`) | PASS × 3, pkgrel=2 |
| `grub-script-check` grub.cfg / loopback.cfg (chroot) | PASS × 2 |
| `scripts/tests/test-child-process.sh` | 33 PASS / 0 FAIL (×3) |
| `scripts/tests/test-de-none.sh` | 56 PASS / 0 FAIL |
| `bash -n` всех shell-файлов, `py_compile` | PASS (в диагностике) |
| `mkinitcpio.conf.d/archiso.conf` | TODO закрыт сверкой: пакет `mkinitcpio-archiso 73-1` свой conf не поставляет, все хуки из списка есть в пакете |
| QEMU / ISO | **НЕ запускались** — отдельный этап, только с разрешения Мии |

SKIP (13) — честные: `shellcheck` (1), `cargo check`/`clippy` (4),
`makepkg --printsrcinfo` (4), `grub-script-check` (2),
`memtest86+-efi`/`edk2-shell` (2) — инструментов нет на хосте;
всё проверено отдельно в chroot (таблица выше).

### 8.3 Что осталось проблемой

1. **BIOS-загрузка live-ISO** — главное незакрытое решение (см. 7.1):
   live-ISO только UEFI; варианты (а) принять, (б) syslinux
   (только с отдельного согласования), (в) BIOS-GRUB через xorriso
   (рецепт проверен до генерации образа, загрузка не тестировалась).
   Без решения Мии `bootmodes` не меняется.
2. **Собственный rootfs не создан** (`scripts/xros-build-env.sh --init`
   не запускался: ~120 МБ bootstrap + ~2–3 ГБ пакетов, нужен `zstd`
   на хосте; первая сборка Rust — онлайн). До `--init` проверки
   выполняются в чужом chroot как временная мера.
3. **`xorg-server` в живом списке** — кандидат на удаление после
   ретеста Wayland в QEMU (см. 5.4).
4. **Остаточные риски отмены установки** (честно): ловушка bash
   откладывается при прямом `kill <pid>` вне группы; внук
   с собственным `setsid`; сторож не стартует при `pgid != $$`.
   Подробно — `docs/final-refinement/child-process.md` §5–6.
5. **GUI при `DE=none` не дизейблит шаг Office Suite** —
   пользователь может выбрать LibreOffice, движок молча пропустит
   его (запись в журнале). Мелкое улучшение GUI, не блокирует.
6. **Мёртвый груз в консольной системе** (`DE=none`): файлы бренда
   и бинарь `xros-install-gui` остаются (пакет `xros-installer`
   удалять нельзя — он владеет и `xros-install`).
7. **Неиспользуемая иконка `theme/memtest.png`** (420 Б) — мелочь.

### 8.4 Что требует решения Мии (обновлено)

- **7.1** BIOS для live-ISO: (а) UEFI-only / (б) syslinux / (в) BIOS-GRUB.
- **7.3** Домен вместо `xros.example`.
- **7.4** Часовой пояс (сейчас Europe/Astrakhan).
- **7.5** Офисный пакет (сейчас «Не устанавливать»).
- **7.6** Ретест Wayland в QEMU (после сборки ISO).
- **Закрыто 10.11.2026:** 7.2 (обои без надписи), 5.1, 5.2, 5.3, 5.5, 5.6, 6.5.

### 8.5 План QEMU (обязательный, после сборки ISO)

Собрано из планов агентов доработки (детали — в
`docs/final-refinement/*.md`):

1. Живая загрузка UEFI (OVMF), рабочий стол KDE виден, нет чёрного экрана Wayland.
2. Одно окно приветствия (autostart-only), переключатель «Запускать при старте», ручной запуск из меню (`--manual`).
3. Меню GRUB: только рабочие пункты (без Memtest/Shell); `fwsetup`, выключение, перезагрузка; loopback-загрузка ISO с диска.
4. Репозиторий в живой системе: `pacman -Sy xros` с `file://`, `pacman -Sl xros` — 4 пакета (1.0-2/1.0-1); `pacman -Sy` по первому серверу честно завершается ошибкой.
5. Автообновления: `xros-update.timer` отсутствует в `systemctl list-timers`.
6. Установка через GUI (UEFI + BIOS для установленной системы), создание пользователя, GRUB; отмена установки из GUI; закрытие GUI во время установки (PDEATHSIG).
7. Установка с `DE=none`: загрузка в консоль, нет графических пакетов и включённых DM, `systemctl get-default` → `multi-user.target`, сеть и логин работают.
8. Первая загрузка установленной системы, SDDM-логин, перезагрузка; экран Finish + перезагрузка по чекбоксу и без него.
9. Журналы без критических ошибок (`journalctl`, `Failed to start`, kernel panic, segv plasmashell/sddm).
10. Установленная система: приветствие НЕ автозапускается, `xros` и `xros info` работают.

---

## 9. Финальный этап подготовки к первой сборке ISO (10.11.2026)

Выполнен после §8 семью агентами по семи направлениям; консолидация
и перепроверка — отдельным агентом (этот раздел). ISO **не собирался**,
`scripts/build.sh`/`mkarchiso` не запускались, ничего никуда
не загружалось. Резервная копия этапа:
`~/workspace/xros-backups/xros-20261110-final-prep` — не трогалась.
Предыдущий резерв (`/tmp/xros-backup-20261110` из §8) утрачен
при очистке tmpfs; пост-доработочный резерв —
`~/workspace/xros-backups/xros-20261110-final-refinement`.

Статусы в этом разделе: **Реализовано** — написано в коде;
**Проверено** — запущено и зафиксировано; **Не проверено** —
требует настоящего ISO/QEMU; **Запланировано** — следующий этап;
**Заблокировано** — ждёт решения Мии.

### 9.1 Что исправлено за этап

| # | Направление | Итог |
|---|---|---|
| 1 | Отмена установки (движок) | **Реализовано + Проверено.** Исправлены 5 багов: `trap` на SIGTERM/EXIT, сторож-зомби, внуки процессов, `INSTALL_FAILED` в журнал, интерактивный cleanup. Документы: `docs/final-refinement/child-process.md`. Тесты — см. 9.2. |
| 2 | BIOS-GRUB | **Проверено загрузкой в QEMU (было: только рецепт).** BIOS CD, BIOS USB (isohybrid raw) и регрессия UEFI — все PASS. Образ `experiments/bios-grub-test/out/xros-bios-test.iso`, sha256 `1e29fe99…`, логи и скриншоты — `experiments/bios-grub-test/logs/`. В `profiledef.sh` НЕ внедрено (`bootmodes=('uefi.grub')`), syslinux не возвращался. Подробно — `docs/boot-bios-grub.md`. |
| 3 | Приветствие Wayland | **Реализовано + Проверено (кроме живого Plasma).** Исправлен краш при клике «Запустить установщик» без бинаря (SIGABRT 134 → предупреждение). Offscreen/Xvfb проверено. Живые тесты в Plasma — честный SKIP (нужен ISO). Подробно — `docs/final-refinement/welcome-wayland.md`. |
| 4 | DE=none | **Проверено реальным разрешением pacman.** KDE 644 пакета, без графики 211, удалено 433, утечек графики 0. Отчёт — `docs/de-none-package-lists.md`. Уточнение: в списке `XROS_GRAPHICS_PKGS` **15 пакетов**, а не 16 (см. 9.3). |
| 5 | Сборочная среда | **Реализовано + Проверено, ГОТОВА.** Rootfs `build-env/root.x86_64` 3.2 ГБ создан (bootstrap GPG-проверен, rust/cargo 1.99.1, grub 2.16, pacman 7.1.0, builder uid 1000). Rust пересобран: `xros` 516 720 Б sha256 `9c67cfdc…`, GUI 11 268 248 Б sha256 `f81a1b18…`. Все 4 пакета собраны от builder. `xros-build-env.sh` починен (4 бага: `/dev/fd`, опечатка пути, `CheckSpace`, повторный `makepkg`). nspawn на хосте не работает — путь `unshare`+`chroot`. Подробно — `docs/final-refinement/build-env.md`. |
| 6 | Безопасность установщика | **Реализовано + Проверено.** Исправлен критический мёртвый `set -e` в `run_install` (явные guard'ы) + F1–F13 (повторная проверка диска, смонтированность, EXIT-trap, санитизация HOSTNAME, TYPE=part/FAT и др.). Документ — `docs/final-refinement/security-audit-2.md`. Пароли в логи не пишутся (проверено grep + отсутствием `set -x` в движке; диагностика §20к). |
| 7 | Брендинг | **Проверено, 0 изменённых файлов.** Alpha логотипа, обои 1920×1080 без надписи, SHA256-синхронность всех копий — PASS. Подробно — `docs/final-refinement/branding.md`. |
| 8 | Дефект UEFI `test`-модуля (НОВОЕ, найдено BIOS-агентом, исправлено на этом этапе) | **Проверено + Исправлено.** В UEFI-образе mkarchiso 92 нет модуля `test`: все пять проверок `[ ... ]` в `grub.cfg`/`loopback.cfg` ложны — тема/фон не грузились, метка платформы была `x86_64-efi`, пункт «Настройки UEFI» скрыт. Исправление: тема/фон — безусловно, платформа и `fwsetup` — через `regexp` (модуль есть в обоих списках). **QEMU-подтверждение на настоящем `grub.cfg`:** ДО — 8–10 ошибок `test.mod not found`, текстовое меню, 4 пункта; ПОСЛЕ — 0 ошибок, меню с темой, заголовок `UEFI`, 5 пунктов. BIOS-контроль: тема работала и до исправления. Эксперимент — `experiments/uefi-test-module/` (README, скрипты, логи ДО/ПОСЛЕ). `grub-script-check` обоих файлов PASS (GRUB 2.12 хост + 2.16 chroot). |
| 9 | Мелочи этапа | Превью: пункт Memtest86+ убран из мока меню GRUB (`preview/index.html`) — теперь соответствует реальному меню. Stray `__pycache__/` в `packages/xros-welcome/` удалён (в пакет не входил). В `theme.rs` 5 цветов вне 7 токенов задокументированы как осознанные (производные + ошибка) — не удалять без решения. В KDE нет собственной цветовой схемы — только BreezeDark. |

### 9.2 Результаты проверок (финальные, 10.11.2026)

| Проверка | Результат |
|---|---|
| `./scripts/xros-diagnose.sh` (§20, новый) | **PASS=212 FAIL=0 SKIP=13**, exit 0; прогоны 2 и 3 побайтово идентичны. Прогон 1 после расширения дал 209/3/13 — все 3 FAIL оказались ошибками новых проверок (комментарии в `profiledef.sh`, `XROS_GRAPHICS_PKGS` 15, а не 16), исправлены проверки и опечатка в документации, а не код. До этапа было 169/0/11. Уточнение (этап 1а, 10.11.2026): повторный прогон даёт **PASS=214 FAIL=0 SKIP=11** — см. §9.8 (причина — `grub-script-check` снова доступен на хосте; всего проверок 225 в обоих случаях). |
| `scripts/tests/test-child-process.sh` | **33 PASS / 0 FAIL** (перезапущен агентом консолидации, 28 с) |
| `scripts/tests/test-child-process-extended.sh` | **82 PASS / 0 FAIL / 1 SKIP** (E10e — живая перезагрузка; 38 с) |
| `scripts/tests/test-de-none.sh` | **58 PASS / 0 FAIL** (было 56 в §8 — тест расширен) |
| `scripts/tests/test-installer-security.sh` | **46 PASS / 0 FAIL / 1 SKIP** |
| Все 4 теста внутри диагностики | Запускаются в §20д/§20з/§20к, их итоги — настоящий результат прогона, а не захардкоженный PASS |
| `grub-script-check` grub.cfg / loopback.cfg | PASS × 2 (GRUB 2.16 в build-env chroot; на хосте — GRUB 2.12, тоже PASS до перезагрузки ВМ) |
| BIOS-GRUB QEMU (QEMU 8.2.2, SeaBIOS, OVMF) | BIOS CD PASS, BIOS USB PASS, UEFI-регрессия PASS |
| UEFI test-модуль QEMU (настоящий grub.cfg) | ДО: 8–10 ошибок `test.mod`, текстовое меню; ПОСЛЕ: 0 ошибок, тема, `UEFI`, 5 пунктов; BIOS-контроль PASS |
| Синхронность GUI-бинаря | `xros-install-gui` 11 268 248 Б sha256 `f81a1b18…` — пакет == airootfs (рассинхрон из §8 закрыт синхронизацией; зафиксирован в диагностике §20л) |
| Синхронность CLI-бинаря | `xros` 516 720 Б sha256 `9c67cfdc…` — пакет == airootfs |
| QEMU / настоящий ISO | **НЕ запускались** — отдельный этап, только с разрешения Мии |

SKIP (13) — честные: `shellcheck` (1), `cargo check`/`clippy` (4),
`makepkg --printsrcinfo` (4), `grub-script-check` (2),
`memtest86+-efi`/`edk2-shell` (2). Инструментов нет на хосте
(хостовый GRUB потерян при перезагрузке ВМ 10.11.2026 вместе
с apt-пакетами QEMU/xorriso — окружение хоста эфемерно, см. 9.4);
всё проверено отдельно в build-env chroot (таблица выше).

Инструменты и условия тестов: хост Ubuntu 24.04.5 LTS, ядро
7.0.0-44-generic, EUID 0; QEMU 8.2.2 (Debian 1:8.2.2+ds-0ubuntu1.18),
OVMF `/usr/share/OVMF/OVMF_CODE_4M.fd`, SeaBIOS `bios-256k.bin`,
xorriso 1.5.6; в build-env rootfs: rustc/cargo 1.99.1, GRUB 2.16,
pacman 7.1.0 (libalpm 16.0.1), Python 3.14.9.

### 9.3 Уточнения к ранним разделам (фактические исправления)

- **`XROS_GRAPHICS_PKGS` — 15 пакетов, а не 16.** В §8 (п. 4) и в
  `docs/de-none-package-lists.md` (метод и результаты) стояло «16».
  Прямой подсчёт списка в `src/xros-install:592` даёт 15;
  сам отчёт (`de-none-package-lists.md`, строка «удаляются 15»)
  и перечисление в `scripts/tests/test-de-none.sh` — тоже 15.
  Ошибка была только в прозе отчёта; симуляция (644/211/433) считалась
  по настоящему списку из 15 имён и верна. В отчёте «16» исправлено
  на «15» в трёх местах; диагностика проверяет ровно 15.
- **Собственный rootfs СОЗДАН** (§6.5 и ARCHITECTURE.md §2 говорили
  «НЕ создан»): `build-env/root.x86_64` 3.2 ГБ, маркеры
  `state/init-done` + `state/deps-fetched`, builder uid 1000.
  Проверки Rust/`makepkg`/`grub-script-check` больше не зависят
  от чужого chroot.
- **BIOS-GRUB проверен загрузкой в QEMU** (§7.1 говорил «загрузка
  НЕ тестировалась»): BIOS CD, BIOS USB и регрессия UEFI — PASS
  (см. 9.1 п. 2). В основную сборку по-прежнему НЕ внедрено.
- **Диагностика: 165 → 169 → 212 → 214 (см. §9.8).** 169 — после синхронизации
  GUI-бинаря координатором; 212 — после добавления §20 (+43 проверки:
  build-env, независимость, BIOS/UEFI GRUB, запуск
  тестов, Wayland/X11, DE=none, пакеты, репозиторий, безопасность,
  брендинг, зафиксированные sha256 бинарей; в скрипте §20 — 72 точки
  вызова в циклах); 214 — повторный прогон
  этапа 1а 10.11.2026: те же 225 проверок, 2 проверки `grub-script-check`
  перешли из SKIP в PASS, так как хостовый GRUB 2.12 снова установлен.
- **`test-de-none.sh`: 56 → 58 PASS** (тест расширен).
- **GUI-бинарь: sha `52ea6a30…` → `f81a1b18…`** (11 268 248 Б):
  пересобран в build-env, синхронизирован пакет == airootfs.
- **Превью** приведено к реальному меню GRUB (без Memtest86+).

### 9.4 Что осталось проблемой

1. **Решения Мии не приняты** (см. 9.5) — главное: BIOS для
   live-ISO (теперь ПРОВЕРЕННАЯ опция, а не рецепт), домен,
   часовой пояс, офисный пакет.
2. **Не проверено на настоящем ISO:** загрузка live-системы,
   Plasma 6.8 Wayland в QEMU (ретест), loopback-загрузка,
   полная установка через GUI, первая загрузка установленной
   системы, SDDM-логин, экран Finish. Всё — только после
   сборки ISO (см. 9.6–9.7).
3. **Окружение хоста эфемерно:** при перезагрузке ВМ 10.11.2026
   пропали apt-пакеты хоста (QEMU, OVMF, xorriso, mtools,
   dosfstools, GRUB хоста) — их ставил BIOS-агент через apt.
   Всё, что должно пережить перезагрузку, живёт только
   в `~/workspace` (`build-env/`, эксперименты, логи).
   Перед следующим QEMU-прогоном хостовые инструменты
   переустанавливаются (`apt-get install qemu-system-x86 ovmf
   xorriso mtools dosfstools`).
4. **Список `EFI_MODS` для UEFI-образа** сверен только чтением
   `/usr/sbin/mkarchiso` в чужом chroot (BIOS-агентом);
   первоисточник (пакет archiso 92) в проекте не читался.
   На исправление `grub.cfg` не влияет (см. 9.1 п. 8).
5. **Замороженная зависимость BIOS-эксперимента от чужого chroot:**
   `experiments/bios-grub-test/src/build-iso.sh` читает chroot
   другого проекта (только чтение: `grub-mkimage`, ядро, модули).
   Это замороженный эксперимент, а не часть сборки: его артефакт
   (ISO + логи) сохранён, пересобирать его не нужно; новый
   эксперимент `uefi-test-module` использует только собственный
   build-env. В `scripts/` и `build-env/` ссылок на чужой проект
   нет (диагностика §20б).
6. **Попутные наблюдения по теме GRUB** (не блокируют):
   текст полосы таймера `Автозагрузка через @TIMEOUT@ с`
   показан буквально, без подстановки числа; на 800×600 второй
   пункт меню обрезается по ширине (`boot_menu` 50%).
   Геометрия темы — отдельное решение, не правилось.
7. **Осталось из §8.3:** 5.4 (`xorg-server` — кандидат на удаление
   после ретеста Wayland), остаточные риски отмены установки,
   GUI не дизейблит шаг Office при `DE=none`, мёртвый груз
   в консольной системе, неиспользуемая иконка `theme/memtest.png`.
8. **Не сделано (отдельные задачи):** LUKS/GRUB-пароль,
   Secure Boot (не заявляется), публичный хостинг репозитория
   (`https://xros.example/repo` не существует), GPG-подпись
   репозитория.

### 9.5 Что требует решения Мии (обновлено)

- **7.1 BIOS для live-ISO — теперь ПРОВЕРЕННАЯ опция:**
  (а) принять UEFI-only (ноль работ); (б) вернуть `bios.syslinux`
  (только с отдельного согласования — второй загрузчик);
  (в) **BIOS-GRUB через xorriso — проверен загрузкой в QEMU**
  (BIOS CD, BIOS USB, UEFI-регрессия — PASS; внедрение —
  скрипт постобработки после `_build_iso_image` + матрица
  на настоящем ISO). Рекомендация: для первого релиза (а),
  если BIOS нужен — (в), а не (б). Без решения `bootmodes`
  не меняется.
- **7.3** Домен вместо `xros.example`.
- **7.4** Часовой пояс (сейчас Europe/Astrakhan).
- **7.5** Офисный пакет (сейчас «Не устанавливать»).
- **7.6** Ретест Wayland в QEMU (после сборки ISO).
- **Закрыто 10.11.2026:** 7.2 (обои без надписи), 5.1, 5.2, 5.3,
  5.5, 5.6, 6.5, дефект UEFI `test`-модуля (9.1 п. 8).

### 9.6 План первой сборки ISO (этап 10 — НЕ запускать без разрешения Мии)

Предусловия: разрешение Мии + решения из 9.5 (минимум — 7.1);
финальный прогон `./scripts/xros-diagnose.sh` — FAIL=0;
свежие бинари и пакеты (пересборка только через build-env,
офлайн где возможно).

```bash
cd ~/workspace/xros
./scripts/xros-diagnose.sh            # должен быть PASS, FAIL=0
./scripts/build.sh --confirm          # ТОЛЬКО с явного разрешения
# внутри build.sh (см. §6.2):
#   1. Собрать Rust-бинари (офлайн, в build-env; см. build.sh, этап 2)
#   2. Застейджить бинари и исходники рядом с PKGBUILD
#   3. Собрать пакеты: cd packages/<пакет> && makepkg (в build-env,
#      от непривилегированного пользователя builder)
#   4. repo-add в repo/xros/os/x86_64/ + обновить снимок в airootfs
#   5. mkarchiso -v -w work -o out profile
#   6. Проверить ISO: sha256, размер, наличие /boot/grub/grub.cfg
```

Если штатный путь упадёт — см. §6.3 (СТОП, разбор причины;
обход ручным pacstrap — НЕПРОВЕРЕН для XrOS, только
с явного разрешения и после разбора причины).

Если Мия выберет BIOS-GRUB (в): после `_build_iso_image` —
постобработка по рецепту `experiments/bios-grub-test/src/build-iso.sh`
(адаптировать под настоящий ISO) + матрица QEMU из 9.7 п. 3.
Без этого шага получится молча UEFI-only ISO.

### 9.7 План полноценного QEMU-тестирования после сборки (обязательный)

Хост: QEMU 8.2.2, OVMF + SeaBIOS (переустановить при необходимости,
см. 9.4 п. 3). Скриншоты каждого шага — в проект.

1. **GRUB на настоящем ISO (UEFI):** меню с темой (фон, шрифты,
   кириллица), заголовок `UEFI`, 5 пунктов (включая «Настройки UEFI»),
   таймер 10 с; ошибок `test.mod` в выводе нет.
2. **GRUB на настоящем ISO (BIOS)** — только если внедрён вариант (в):
   BIOS CD + BIOS USB (isohybrid raw), тема, заголовок `BIOS`,
   4 пункта (без «Настройки UEFI»); регрессия UEFI.
3. **Loopback-загрузка** ISO-файла с диска (внешний GRUB +
   `loopback.cfg`, `img_dev`/`img_loop`).
4. Живая загрузка UEFI, рабочий стол KDE виден (скриншот).
5. Ретест Plasma 6.8 Wayland (нет чёрного экрана, `plasmashell` жив).
6. Одно окно приветствия после входа (autostart-only), переключатель
   «Запускать при старте», ручной запуск из меню (`--manual`),
   клик «Запустить установщик» открывает GUI (без краша).
7. Ярлык «Установить XrOS» на рабочем столе.
8. Установка через GUI (UEFI), создание пользователя, GRUB;
   отмена установки из GUI; закрытие GUI во время установки.
9. Установка на BIOS (установленная система; live-ISO BIOS
   не грузится без варианта (в)).
10. Установка с `DE=none`: загрузка в консоль, нет графических
    пакетов и включённых DM, `systemctl get-default` →
    `multi-user.target`, сеть и логин работают.
11. Первая загрузка установленной системы, SDDM-логин.
12. Перезагрузка из установленной системы.
13. Экран Finish + перезагрузка по чекбоксу и без него.
14. Репозиторий в живой системе: `pacman -Sy xros` с `file://`,
    `pacman -Sl xros` — 4 пакета; `pacman -Sy` по первому серверу
    честно завершается ошибкой.
15. Автообновления: `xros-update.timer` отсутствует
    в `systemctl list-timers`.
16. Журналы без критических ошибок (`journalctl`, `Failed to start`,
    kernel panic, segv plasmashell/sddm).
17. Установленная система: приветствие НЕ автозапускается,
    `xros` и `xros info` работают.

### 9.8 Перепроверка диагностики (этап 1а, 10.11.2026) — расхождение 212 vs 214

Координатор сообщил PASS=214 FAIL=0 SKIP=11, а в §9.2 зафиксировано
PASS=212 FAIL=0 SKIP=13. Перепроверка агентом этапа 1а:

- `./scripts/xros-diagnose.sh` запущен 2 раза, оба прогона —
  **PASS=214 FAIL=0 SKIP=11**, exit 0, выводы побайтово идентичны
  (sha256 обоих логов `2b7d50a47acdb86e0fb583b88c0d0e4ffea8470d973b2c5a01b5c9904a840a21`).
  Логи: `docs/final-prep/diagnose-run1-20261110.log`,
  `docs/final-prep/diagnose-run2-20261110.log` (по 228 строк).
- **Причина расхождения — окружение хоста, а не код и не число
  проверок.** Всего проверок одинаково: 212 + 13 = 214 + 11 = **225**.
  Две проверки `grub-script-check grub.cfg` / `grub-script-check
  loopback.cfg` (§7д скрипта) дают SKIP, только если `grub-script-check`
  отсутствует на хосте, и PASS — если он есть. На прогонах §9.2
  хостового GRUB не было (потерян при перезагрузке ВМ 10.11.2026
  вместе с apt-пакетами QEMU/xorriso — см. §9.2 и 9.4 п. 3), поэтому
  было SKIP=13. К перепроверке хостовые пакеты снова установлены
  (grub-common 2.12-1ubuntu7.3, `grub-script-check` —
  `/usr/bin/grub-script-check`; QEMU 8.2.2, xorriso 1.5.6, mtools —
  те же версии, что в §9.2), и обе проверки дают PASS:
  строки 42–43 логов. Скрипт при этом не менялся.
- Тот же переход SKIP 13→11 уже случался раньше и объяснён так же:
  `docs/final-refinement/security-audit-2.md`, п. 6 (165→169).
- Текущий состав SKIP (11): `shellcheck` (1), `cargo check`/`clippy` (4),
  `makepkg --printsrcinfo` (4), `memtest86+-efi`/`edk2-shell` (2).
  `grub-script-check` в SKIP больше нет. Остальные SKIP — честные:
  инструментов по-прежнему нет на хосте; результаты — в build-env
  chroot (см. §9.2).
- **Итог: настоящее текущее значение — PASS=214 FAIL=0 SKIP=11.**
  Значения 212/0/13 в §9.2 оставлены как историческая запись прогонов
  того этапа (они были верны на тот момент); актуальный статус
  обновлён здесь, в §9.3 и в ARCHITECTURE.md (§15) и README.md.
  Резервная копия проекта до этих правок:
  `~/workspace/xros-backups/xros-20261110-stage10-prep`
  (без `build-env/root.x86_64`, сверена `diff -rq`, 333 файла).

---

## Приложение А. Полный вывод финальной диагностики

Запуск: `./scripts/xros-diagnose.sh`, 10.11.2026.
Итог: **PASS=121 FAIL=0 SKIP=13**, код выхода 0.

```text
PASS  bash -n profile/airootfs/root/customize_airootfs.sh
PASS  bash -n profile/airootfs/usr/local/bin/xros-install
PASS  bash -n profile/airootfs/usr/local/bin/xros-welcome
PASS  bash -n profile/profiledef.sh
PASS  bash -n src/xros-install
PASS  bash -n src/xros-welcome
PASS  bash -n packages/xros-installer/PKGBUILD
PASS  bash -n packages/xros-installer/xros-install
PASS  bash -n packages/xros-welcome/PKGBUILD
PASS  bash -n packages/xros-branding/PKGBUILD
PASS  bash -n packages/xros-cli/PKGBUILD
PASS  bash -n scripts/xros-diagnose.sh
PASS  bash -n scripts/build.sh
SKIP  shellcheck (shellcheck не установлен на этом хосте)
PASS  py_compile src/xros-welcome-gui
PASS  py_compile scripts/make-branding.py
SKIP  cargo check xros-install-gui (cargo не установлен на этом хосте (см. AUDIT-REPORT.md: проверено в chroot))
SKIP  cargo check xros-cli (cargo не установлен на этом хосте (см. AUDIT-REPORT.md: проверено в chroot))
SKIP  cargo clippy xros-cli (cargo не установлен на этом хосте)
SKIP  cargo clippy xros-install-gui (cargo не установлен на этом хосте)
SKIP  makepkg --printsrcinfo xros-cli (makepkg не установлен на этом хосте (см. AUDIT-REPORT.md: проверено в chroot))
SKIP  makepkg --printsrcinfo xros-installer (makepkg не установлен на этом хосте (см. AUDIT-REPORT.md: проверено в chroot))
SKIP  makepkg --printsrcinfo xros-welcome (makepkg не установлен на этом хосте (см. AUDIT-REPORT.md: проверено в chroot))
SKIP  makepkg --printsrcinfo xros-branding (makepkg не установлен на этом хосте (см. AUDIT-REPORT.md: проверено в chroot))
PASS  нет следов другого проекта (кроме ARCHITECTURE.md §2)
PASS  profiledef: bootmodes=('uefi.grub')
PASS  profiledef: в bootmodes нет syslinux/systemd-boot
PASS  profile/syslinux и profile/efiboot отсутствуют (удалены)
PASS  есть profile/grub/grub.cfg
PASS  есть profile/grub/loopback.cfg
PASS  есть profile/grub/theme/theme.txt
PASS  есть profile/grub/theme/grub-bg.jpg
PASS  есть profile/grub/theme/DejaVuSans-12.pf2
PASS  есть profile/grub/theme/DejaVuSans-14.pf2
PASS  есть profile/grub/theme/DejaVuSans-Bold-16.pf2
PASS  theme.txt: desktop-image grub-bg.jpg существует
SKIP  grub-script-check grub.cfg (grub-script-check нет на хосте (см. AUDIT-REPORT.md: проверено в chroot))
SKIP  grub-script-check loopback.cfg (grub-script-check нет на хосте (см. AUDIT-REPORT.md: проверено в chroot))
PASS  grub.cfg/loopback.cfg: нет невалидного цвета 'indigo'
PASS  grub.cfg: пункт Memtest86+ защищён проверкой -f
PASS  grub.cfg: пункт UEFI Shell защищён проверкой -f
PASS  packages.x86_64: нет syslinux
PASS  packages.x86_64: нет plasma-x11-session
SKIP  packages.x86_64: memtest86+-efi (пакета нет — пункт меню Memtest86+ скроется (см. AUDIT-REPORT.md))
SKIP  packages.x86_64: edk2-shell (пакета нет — пункт меню UEFI Shell скроется (см. AUDIT-REPORT.md))
PASS  packages.x86_64: дублей нет
PASS  packages.x86_64: есть linux-firmware
PASS  packages.x86_64: есть pipewire
PASS  packages.x86_64: есть pipewire-pulse
PASS  packages.x86_64: есть wireplumber
PASS  packages.x86_64: есть ntfs-3g
PASS  packages.x86_64: есть kscreen
PASS  packages.x86_64: есть grub
PASS  packages.x86_64: есть linux
PASS  есть profile/profiledef.sh
PASS  есть profile/packages.x86_64
PASS  есть profile/pacman.conf
PASS  есть profile/airootfs/root/customize_airootfs.sh
PASS  есть profile/airootfs/etc/hostname
PASS  есть profile/airootfs/etc/locale.conf
PASS  customize_airootfs.sh +x
PASS  profile/pacman.conf == profile/airootfs/etc/pacman.conf
PASS  есть branding/xros-logo.png
PASS  есть branding/xros-logo-small.png
PASS  есть branding/wallpaper.png
PASS  есть branding/wallpaper.jpg
PASS  есть branding/grub-bg.jpg
PASS  есть branding/grub-bg.png
PASS  синхронно branding/xros-logo.png (airootfs + пакет)
PASS  синхронно branding/xros-logo-small.png (airootfs + пакет)
PASS  синхронно branding/wallpaper.png (airootfs + пакет)
PASS  синхронно branding/wallpaper.jpg (airootfs + пакет)
PASS  синхронно branding/grub-bg.jpg (airootfs + пакет)
PASS  синхронно branding/grub-bg.png (airootfs + пакет)
PASS  синхронно branding/grub-bg.jpg (тема GRUB + splash)
PASS  синхронно branding/grub-bg.png (тема GRUB + splash)
PASS  логотип: RGBA, углы alpha=0; обои 1920x1080
PASS  theme.txt: title-text:
PASS  theme.txt: desktop-image:
PASS  theme.txt: item_font
PASS  theme.txt: + boot_menu
PASS  theme.txt: selected_item_color #f5f3fa (контраст 5,39:1) в обеих копиях
PASS  theme.txt синхронен (профиль == airootfs)
PASS  старых цветов нет (кроме AUDIT-REPORT.md)
PASS  есть preview/index.html
PASS  preview: все пути к ресурсам существуют
PASS  preview: блок экрана завершения
PASS  preview: design-tokens.css подключён
PASS  xros-update.timer нигде не включается
PASS  repo DB: 4 пакета
PASS  есть repo xros.files.tar.gz
PASS  снимок репозитория в airootfs == repo/
PASS  xros.example везде помечен PLACEHOLDER
PASS  есть src/xros-cli/Cargo.lock
PASS  есть src/xros-install-gui-rs/Cargo.lock
PASS  xros-install синхронен (src == airootfs == пакет)
PASS  xros-welcome синхронен (src == airootfs)
PASS  xros-welcome-gui синхронен (src == airootfs == пакет)
PASS  xros (CLI) синхронен (пакет == airootfs)
PASS  xros-install-gui синхронен (пакет == airootfs)
PASS  banner.txt синхронен (пакет == airootfs)
PASS  xros-welcome.service синхронен (пакет == airootfs)
PASS  xros-welcome.desktop синхронен (пакет == airootfs)
PASS  xros-install: mkfs_root
PASS  xros-install: FS:=ext4
PASS  xros-install: grub-install --target=x86_64-efi
PASS  xros-install: grub-install --target=i386-pc
PASS  xros-install: INSTALL_DONE
PASS  xros-install: INSTALL_FAILED
PASS  xros-install: GRUB_THEME=
PASS  xros-install: %q-экранирование пароля/ФИО
PASS  xros-install: защита от установки на диск с ISO
PASS  xros-install: проверка диска (-b, TYPE=disk)
PASS  xros-install: sudo --preserve-env
PASS  xros-install: umask 077
PASS  xros-install: machine-id удаляется + пересоздаётся
PASS  xros-install: resolv.conf удаляется
PASS  xros-install: все DM отключаются перед включением выбранного
PASS  xros-install: автовход GDM/LightDM/SDDM по выбранному DE
PASS  xros-install: расширенная финальная проверка (fstab, пользователь, hostname, DM)
PASS  customize: welcome service включён глобально
PASS  welcome-gui: Hidden=true toggle «Запускать при старте»
PASS  gui: "Desktop"
PASS  gui: "Finish"
PASS  gui: reboot_now
PASS  gui: XrOS успешно установлена
PASS  gui: Перезагрузить компьютер сейчас
PASS  gui: запрет закрытия окна во время установки (CancelClose)
PASS  gui: --step ограничен шагом 8 (Finish недоступен напрямую)
PASS  gui: конфиг установки 0600 с момента создания
PASS  gui: кнопки навигации блокируются во время установки
PASS  profiledef: iso_name="xros"
PASS  profiledef: iso_label="XROS_202611"
PASS  profiledef: install_dir="xros"

Итого: PASS=121 FAIL=0 SKIP=13
Диагностика пройдена.

```


---

## Приложение Б. Полный вывод диагностики после финальной доработки

Запуск: `./scripts/xros-diagnose.sh`, 10.11.2026, дважды (выводы побайтово идентичны).
Итог: **PASS=165 FAIL=0 SKIP=13**, код выхода 0.

```text
PASS  bash -n profile/airootfs/root/customize_airootfs.sh
PASS  bash -n profile/airootfs/usr/local/bin/xros-install
PASS  bash -n profile/airootfs/usr/local/bin/xros-welcome
PASS  bash -n profile/profiledef.sh
PASS  bash -n src/xros-install
PASS  bash -n src/xros-welcome
PASS  bash -n packages/xros-installer/xros-install
PASS  bash -n packages/xros-installer/PKGBUILD
PASS  bash -n packages/xros-welcome/PKGBUILD
PASS  bash -n packages/xros-branding/PKGBUILD
PASS  bash -n packages/xros-cli/PKGBUILD
PASS  bash -n scripts/xros-diagnose.sh
PASS  bash -n scripts/build.sh
PASS  bash -n scripts/xros-build-env.sh
PASS  bash -n scripts/tests/test-de-none.sh
PASS  bash -n scripts/tests/test-child-process.sh
SKIP  shellcheck (shellcheck не установлен на этом хосте)
PASS  py_compile src/xros-welcome-gui
PASS  py_compile scripts/make-branding.py
SKIP  cargo check xros-install-gui (cargo не установлен на этом хосте (см. AUDIT-REPORT.md: проверено в chroot))
SKIP  cargo check xros-cli (cargo не установлен на этом хосте (см. AUDIT-REPORT.md: проверено в chroot))
SKIP  cargo clippy xros-cli (cargo не установлен на этом хосте)
SKIP  cargo clippy xros-install-gui (cargo не установлен на этом хосте)
SKIP  makepkg --printsrcinfo xros-cli (makepkg не установлен на этом хосте (см. AUDIT-REPORT.md: проверено в chroot))
SKIP  makepkg --printsrcinfo xros-installer (makepkg не установлен на этом хосте (см. AUDIT-REPORT.md: проверено в chroot))
SKIP  makepkg --printsrcinfo xros-welcome (makepkg не установлен на этом хосте (см. AUDIT-REPORT.md: проверено в chroot))
SKIP  makepkg --printsrcinfo xros-branding (makepkg не установлен на этом хосте (см. AUDIT-REPORT.md: проверено в chroot))
PASS  нет следов другого проекта (кроме ARCHITECTURE.md §2)
PASS  profiledef: bootmodes=('uefi.grub')
PASS  profiledef: в bootmodes нет syslinux/systemd-boot
PASS  profile/syslinux и profile/efiboot отсутствуют (удалены)
PASS  есть profile/grub/grub.cfg
PASS  есть profile/grub/loopback.cfg
PASS  есть profile/grub/theme/theme.txt
PASS  есть profile/grub/theme/grub-bg.jpg
PASS  есть profile/grub/theme/DejaVuSans-12.pf2
PASS  есть profile/grub/theme/DejaVuSans-14.pf2
PASS  есть profile/grub/theme/DejaVuSans-Bold-16.pf2
PASS  theme.txt: desktop-image grub-bg.jpg существует
SKIP  grub-script-check grub.cfg (grub-script-check нет на хосте (см. AUDIT-REPORT.md: проверено в chroot))
SKIP  grub-script-check loopback.cfg (grub-script-check нет на хосте (см. AUDIT-REPORT.md: проверено в chroot))
PASS  grub.cfg/loopback.cfg: нет невалидного цвета 'indigo'
PASS  grub.cfg: пункта Memtest86+ нет (намеренно отсутствует)
PASS  grub.cfg: пункта UEFI Shell нет (намеренно отсутствует)
PASS  packages.x86_64: нет syslinux
PASS  packages.x86_64: нет plasma-x11-session
SKIP  packages.x86_64: memtest86+-efi (пакета нет — пункт меню Memtest86+ скроется (см. AUDIT-REPORT.md))
SKIP  packages.x86_64: edk2-shell (пакета нет — пункт меню UEFI Shell скроется (см. AUDIT-REPORT.md))
PASS  packages.x86_64: дублей нет
PASS  packages.x86_64: есть linux-firmware
PASS  packages.x86_64: есть pipewire
PASS  packages.x86_64: есть pipewire-pulse
PASS  packages.x86_64: есть wireplumber
PASS  packages.x86_64: есть ntfs-3g
PASS  packages.x86_64: есть kscreen
PASS  packages.x86_64: есть grub
PASS  packages.x86_64: есть linux
PASS  есть profile/profiledef.sh
PASS  есть profile/packages.x86_64
PASS  есть profile/pacman.conf
PASS  есть profile/airootfs/root/customize_airootfs.sh
PASS  есть profile/airootfs/etc/hostname
PASS  есть profile/airootfs/etc/locale.conf
PASS  customize_airootfs.sh +x
PASS  profile/pacman.conf == profile/airootfs/etc/pacman.conf
PASS  есть branding/xros-logo.png
PASS  есть branding/xros-logo-small.png
PASS  есть branding/wallpaper.png
PASS  есть branding/wallpaper.jpg
PASS  есть branding/grub-bg.jpg
PASS  есть branding/grub-bg.png
PASS  синхронно branding/xros-logo.png (airootfs + пакет)
PASS  синхронно branding/xros-logo-small.png (airootfs + пакет)
PASS  синхронно branding/wallpaper.png (airootfs + пакет)
PASS  синхронно branding/wallpaper.jpg (airootfs + пакет)
PASS  синхронно branding/grub-bg.jpg (airootfs + пакет)
PASS  синхронно branding/grub-bg.png (airootfs + пакет)
PASS  синхронно branding/grub-bg.jpg (тема GRUB + splash)
PASS  синхронно branding/grub-bg.png (тема GRUB + splash)
PASS  логотип: RGBA, углы alpha=0; обои 1920x1080
PASS  theme.txt: title-text:
PASS  theme.txt: desktop-image:
PASS  theme.txt: item_font
PASS  theme.txt: + boot_menu
PASS  theme.txt: selected_item_color #f5f3fa (контраст 5,39:1) в обеих копиях
PASS  theme.txt синхронен (профиль == airootfs)
PASS  старых цветов нет (кроме AUDIT-REPORT.md)
PASS  есть preview/index.html
PASS  preview: все пути к ресурсам существуют
PASS  preview: блок экрана завершения
PASS  preview: design-tokens.css подключён
PASS  xros-update.timer нигде не включается
PASS  repo DB: 4 пакета
PASS  есть repo xros.files.tar.gz
PASS  снимок репозитория в airootfs == repo/
PASS  xros.example везде помечен PLACEHOLDER
PASS  есть src/xros-cli/Cargo.lock
PASS  есть src/xros-install-gui-rs/Cargo.lock
PASS  xros-install синхронен (src == airootfs == пакет)
PASS  xros-welcome синхронен (src == airootfs)
PASS  xros-welcome-gui синхронен (src == airootfs == пакет)
PASS  xros (CLI) синхронен (пакет == airootfs)
PASS  xros-install-gui синхронен (пакет == airootfs)
PASS  banner.txt синхронен (пакет == airootfs)
PASS  welcome service отсутствует (модель autostart-only)
PASS  xros-welcome.desktop (пункт меню) синхронен (пакет == airootfs)
PASS  xros-welcome.desktop синхронен (пакет == airootfs)
PASS  xros-install: mkfs_root
PASS  xros-install: FS:=ext4
PASS  xros-install: grub-install --target=x86_64-efi
PASS  xros-install: grub-install --target=i386-pc
PASS  xros-install: INSTALL_DONE
PASS  xros-install: INSTALL_FAILED
PASS  xros-install: GRUB_THEME=
PASS  xros-install: %q-экранирование пароля/ФИО
PASS  xros-install: защита от установки на диск с ISO
PASS  xros-install: проверка диска (-b, TYPE=disk)
PASS  xros-install: sudo --preserve-env
PASS  xros-install: umask 077
PASS  xros-install: machine-id удаляется + пересоздаётся
PASS  xros-install: resolv.conf удаляется
PASS  xros-install: все DM отключаются перед включением выбранного
PASS  xros-install: автовход GDM/LightDM/SDDM по выбранному DE
PASS  xros-install: расширенная финальная проверка (fstab, пользователь, hostname, DM)
PASS  customize: welcome service НЕ включается (модель autostart-only)
PASS  customize: .desktop приветствия берётся из профиля, дублей нет
PASS  welcome-gui: Hidden=true toggle «Запускать при старте»
PASS  gui: "Desktop"
PASS  gui: "Finish"
PASS  gui: reboot_now
PASS  gui: XrOS успешно установлена
PASS  gui: Перезагрузить компьютер сейчас
PASS  gui: запрет закрытия окна во время установки (CancelClose)
PASS  gui: --step ограничен шагом 8 (Finish недоступен напрямую)
PASS  gui: конфиг установки 0600 с момента создания
PASS  gui: кнопки навигации блокируются во время установки
PASS  profiledef: iso_name="xros"
PASS  profiledef: iso_label="XROS_202611"
PASS  profiledef: install_dir="xros"
PASS  profile/grub/grub.cfg: пунктов Memtest/Shell нет (намеренно отсутствуют)
PASS  profile/grub/grub.cfg: нет кодовых ссылок на edk2-shell
PASS  profile/grub/loopback.cfg: пунктов Memtest/Shell нет (намеренно отсутствуют)
PASS  profile/grub/loopback.cfg: нет кодовых ссылок на edk2-shell
PASS  grub.cfg/loopback.cfg: наборы --id совпадают
PASS  grub.cfg/loopback.cfg: нет syslinux/systemd-boot/efiboot
PASS  loopback.cfg: есть img_dev= и img_loop=
PASS  grub.cfg: archisobasedir есть, img_dev нет (живая загрузка)
PASS  xros-welcome.service отсутствует (модель autostart-only)
PASS  autostart .desktop приветствия есть (airootfs + пакет)
PASS  xros-welcome-gui: flock во всех копиях
PASS  движок: защитные удаления приветствия из целевой системы
PASS  .xprofile отсутствует (мёртв под Wayland)
PASS  scripts/: нет упоминаний другого проекта (кроме пути chroot в build.sh)
PASS  есть branding/banner.txt
PASS  sha256 xros-logo.png: branding == airootfs == пакет
PASS  sha256 xros-logo-small.png: branding == airootfs == пакет
PASS  sha256 wallpaper.png: branding == airootfs == пакет
PASS  sha256 wallpaper.jpg: branding == airootfs == пакет
PASS  sha256 grub-bg.jpg: branding == airootfs == пакет
PASS  sha256 grub-bg.png: branding == airootfs == пакет
PASS  sha256 banner.txt: branding == airootfs == пакет
PASS  движок: DE=none → DE_PKGS="" и DE_DM=""
PASS  движок: DE=none отключает все DM и не включает ни один
PASS  GUI: предлагает «Без графики» (DE=none)
PASS  docs/: старых цветов нет (кроме исторической записи в branding.md)
PASS  xros.example везде с PLACEHOLDER рядом
PASS  маркеров-заглушек нет
PASS  PKGBUILD xros-cli: все source-файлы на месте
PASS  PKGBUILD xros-installer: все source-файлы на месте
PASS  PKGBUILD xros-welcome: все source-файлы на месте
PASS  PKGBUILD xros-branding: все source-файлы на месте
PASS  repo: файлы пакета xros-cli совпадают с package()
PASS  repo: файлы пакета xros-installer совпадают с package()
PASS  repo: файлы пакета xros-welcome совпадают с package()
PASS  repo: файлы пакета xros-branding совпадают с package()
PASS  GUI: PDEATHSIG + process group + отмена (InstallHandle)
PASS  движок: есть trap на SIGTERM/EXIT
PASS  install.rs: pub const без дублей

Итого: PASS=165 FAIL=0 SKIP=13
Диагностика пройдена.
```

## 10. Сборка ISO обходным путём — ручной pacstrap (10.11.2026)

Штатный `mkarchiso` (build.sh, шаг 10) трижды упал одинаково:
`pacstrap → chroot_setup → свежий mount sysfs → "Mount too revealing"`
(песочница: user namespace без хостового net ns; свежие mount sysfs
и devtmpfs запрещены ядром). По разрешению Мии применён обходной путь
по проверенной схеме ручного pacstrap (рецепт другого
Arch-дистрибутива, сборка 15, 07.11.2026; источник — см.
ARCHITECTURE.md §2 и PACSTRAP-BUILD-REPORT.md). Штатный
`scripts/build.sh` не переписан; обход — отдельный скрипт
`scripts/build-rootfs-pacstrap.sh` (только подготовка rootfs,
mkarchiso сам не запускает).

Что сделано и проверено 10.11.2026 (полный отчёт —
PACSTRAP-BUILD-REPORT.md):
- Патч `chroot_setup()` в копиях `pacstrap`/`arch-chroot` внутри
  build-env завершён (2 строки: свежие mount sysfs/devtmpfs →
  `--rbind` хостовых `/sys` и `/dev`, штатная идиома из
  `unshare_setup()`); оригиналы `.orig` сохранены. Штатный
  `pacstrap -N` (вложенный unshare) в песочнице зависает (>10 мин)
  и не используется.
- Найден и исправлен латентный дефект: `file://`-репозиторий `[xros]`
  не виден при pacstrap (pacman резолвит его относительно хоста) —
  снимок теперь кладётся и в build-env (`/usr/share/xros/repo`).
- Rootfs: 46 пакетов из списка, всего 645 установленных; ядро
  `7.2.15.arch1-1`, Plasma `6.8.2-1`, GRUB `2.16`, SDDM `0.21.0-7`;
  пользователь `xros`, автовход SDDM, пароли заблокированы,
  shadow 600, ufw DROP, initramfs с archiso-хуками. DE=none:
  15 графических пакетов покрыты `XROS_GRAPHICS_PKGS`.
- mkarchiso с маркерами `base.*`: exit 0, 0 ERROR; squashfs
  1 551 566 608 Б. Постобработка BIOS-GRUB: exit 0.
- Гибридный ISO `out/xros-1.0-x86_64-hybrid.iso` (1 852 350 464 Б,
  SHA256 `0e664a48b9cb64a9c043dec2b8f13e620c8caddcceb5c29979760ce15e00f90c`):
  `check-iso.sh --archiso` — **PASS=12 FAIL=0 SKIP=0** (BIOS El Torito,
  UEFI El Torito, гибридный MBR, BOOTX64.EFI в appended EFI-разделе,
  vmlinuz/initramfs, media-check). Исправлен ложный FAIL check-iso
  по BOOTX64.EFI (mkarchiso 92 не кладёт его в дерево ISO9660).
- Диагностика после сборки: PASS=217 FAIL=0 SKIP=11.
- Ограничения: PXE-загрузка недоступна (нет ipconfig/nbd-client/
  nfsmount); результат не побайтово равен штатному; патч build-env
  надо повторять после `--reinit`; QEMU-тесты и установка на диск
  НЕ проверены (следующий этап); ISO не опубликован.

