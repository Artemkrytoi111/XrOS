# KDE-PLASMA-VALIDATION.md — XrOS 1.0 (fixed9)

- **Дата:** 11 ноября 2026 (проверки 11.11.2026 07:21–08:12 UTC — агент раунда 2;
  13:39–14:25 +04 — сама)
- **ISO:** `xros-1.0-fixed9-x86_64-hybrid.iso`
  (plain sha256 `d62a997810cf6ade3dd7ca795989acc7773554fb108da0f2bf0e080b357789a1`,
  hybrid sha256 `becd7645a1508d963742fd2aeaf518024f7cef88d08f65aef665a715a7708f0c`)
- **Установленная система:** диск `experiments/qemu-stage10/disks/fixed9-uefi.qcow2`
  (UEFI, /dev/sda2 ext4 XROS-OS + /dev/sda1 vfat XROS-EFI); hostname `xros-os`,
  пользователь `mia` (uid 1000, пароль `xros1234`), autologin=1, TIMEZONE=Europe/Samara,
  KEYMAP=ru, DE=kde, OFFICE=none
- **Окружение:** Plasma 6.8, Wayland (сеанс X11 в Arch отсутствует по дизайну);
  QEMU q35 + OVMF, -vga std, 2 CPU, 2 ГБ RAM, TCG (медленная эмуляция — все задержки
  ниже надо читать с этой поправкой)
- **Статусы — только PASS / FAIL / NOT TESTED**

## 1. Live-система (fixed9)

| Проверка | Результат |
|---|---|
| GRUB Live (меню, таймер) | PASS — «Автозагрузка через N с» с фиолетовой полосой, %d-шаблон работает |
| Загрузка Live до рабочего стола | PASS — фиолетовые обои XrOS, панель, часы, окно «Добро пожаловать в XrOS!» |
| Приветствие (PyQt6) | PASS — открывается автоматически, кнопка «Запустить установщик» |
| BIOS Live | PASS — GRUB «Автозагрузка через 4 с», полный рабочий стол (36 кадров агента) |
| Время появления панели под медленным TCG | PASS с оговоркой — панель может появляться до ~10 мин после загрузки; чёрный стол раньше этого срока — НЕ дефект (доказано на fixed6) |

## 2. Установленная система — первый запуск и сессии

| Проверка | Результат |
|---|---|
| GRUB установленной системы | PASS — меню с темой XrOS, «Автозагрузка через 8 с» (кадр fb2-grub1) |
| SDDM | PASS — active (running), 1 запуск, без цикла перезапусков |
| Автовход mia | PASS — `Authentication for user "mia" successful`, `session opened for user mia(uid=1000)` |
| Сессия Plasma Wayland | PASS — `startplasma-wayland`, `kwin_wayland` (DRM-бэкенд), `plasmashell` (PID 666) active |
| Рабочий стол (первая загрузка) | PASS — фиолетовые обои XrOS, панель, часы 11:41 11.11.2026, Konsole (кадр firstboot-fb-c13) |
| Блокировка экрана | PASS — экран блокировки появляется, пароль xros1234 принимается |
| Разблокировка | PASS — разблокировка работает (loginctl LockedHint=no после ввода пароля) |
| `systemctl --failed` | PASS — 0 упавших юнитов |

## 3. Дефекты Plasma (установленная система)

### 3.1. Чёрный экран после разблокировки — FAIL (прерывистый)

- **Проявления:** 2 из 4 загрузок (агент: 2-я загрузка firstboot2 — чёрный экран + курсор ≥3 мин;
  сама: diag3 14:21–14:25 — VT1 чёрный ~4 мин после успешной разблокировки).
  В обоих случаях сессия ЖИВА: plasmashell и kwin_wayland работают, Ctrl+Alt+T открывает
  Konsole, VT3 доступен, loginctl показывает State=active, LockedHint=no.
- **Перерисовка:** в diag2 стол перерисовался за ~1–2 мин сам; в diag3 — только после
  переключения VT3→VT1 (~4 мин после разблокировки). В firstboot2 за 3+ мин не перерисовался.
- **Причина не установлена.** В журнале только kwin_wayland
  «Input method is trying to show itself but without a context. Aborting.»
  (не «Aborting shell load»). Гонка fixed5/fixed6 (kactivitymanagerd) НЕ воспроизводится.
- **Связанный фактор:** DPMS-гашение экрана блокировки — чёрные кадры сразу после
  переключения на VT1 часто оказываются просто погашенным экраном, а не падением сессии.
  Не судить о чёрном столе раньше ~5 мин после разблокировки.
- **Исправление:** на этапе сборки/диагностики kwin — отдельный пункт; в VM не чинится.

### 3.2. kactivitymanagerd падает при старте сессии — FAIL

- `kactivitymanagerd[412]` 13:24:03: «This application failed to start because no Qt
  platform plugin could be initialized», core dump, systemd «Failed to start
  KActivityManager Activity manager Service» 13:24:06.
- Сервис перезапускается сам: второй экземпляр (PID 672) работает, ExecStartPre
  `/usr/local/bin/xros-wait-kactivitymanagerd` завершается 0/SUCCESS, drop-in
  `10-kactivitymanagerd.conf` на месте, plasmashell стабилен.
- **Исправление — на этапе сборки:** упорядочить старт kactivitymanagerd после
  готовности Wayland (ожидание WAYLAND_DISPLAY или After plasma-kwin_wayland
  в user-юните). В VM не чинится.

### 3.3. Падение сплеша при загрузке — FAIL (мелочь)

- `systemd[372]: Failed to start Splash screen shown during boot.` (13:24:37).
- На работу системы не влияет. На этап сборки.

### 3.4. Обои XrOS для пользователя mia — FAIL → ИСПРАВЛЕНО в VM

- Было: штатные обои Plasma (цветы); appletsrc без строки Image;
  `xros-set-wallpaper` запускается только из автозапуска живого пользователя.
- **Исправлено 14:20 (diag3):** `xros-set-wallpaper` от имени mia в контексте
  графической сессии — exit=0; `Image=file:///usr/share/xros/wallpaper.png`;
  **визуально подтверждено 14:25** (кадр diag3-vt1c): фиолетовые волны XrOS, панель, часы.
- Замечание: фон экрана блокировки отдельный — в 14:21 он был чёрным.
- **Исправление — на этапе сборки:** установщик должен применять обои для
  создаваемого пользователя.

### 3.5. ACPI-выключение — FAIL

- QMP `system_powerdown`: установленная система — ВМ не выключилась за 60 с;
  Live — за 75 с; fixed5 — за 30 с. Во всех случаях ВМ продолжала работать.
- Причина не установлена. На этап сборки (проверить acpid/power-profiles-daemon
  и параметры ядра).

## 4. Что НЕ проверялось — NOT TESTED

- BIOS-установка и первая загрузка BIOS-системы — **делает Мия**
  (диск fixed9-bios.qcow2 пуст; BIOS Live PASS).
- Длительная стабильность Plasma (сессия >1 часа под нагрузкой).
- Переключение раскладок в установленной сессии (KEYMAP=ru в vconsole PASS;
  мульти-раскладка в Plasma — отдельная проверка Diamond).
- Работа с двумя мониторами / HiDPI (в QEMU не применимо).
