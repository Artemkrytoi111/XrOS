# FIXED9 — Post-Installation Diagnostics

- **Дата:** 11 ноября 2026, 13:39–13:50 +04 (сама, без агента)
- **Объект:** установленная система fixed9, диск `experiments/qemu-stage10/disks/fixed9-uefi.qcow2`
  (установка завершена 11.11.2026 07:15 UTC, UEFI, /dev/sda2 ext4 XROS-OS + /dev/sda1 vfat XROS-EFI)
- **VM:** `fixed9-diag2`, QEMU pid 6423, UEFI diskboot без ISO; вход через VT3 (Ctrl+Alt+F3), пользователь `mia`
- **Статусы в этом отчёте — только PASS / FAIL / NOT TESTED** (по ТЗ от 11.11.2026 12:02)
- **Доказательства:** кадры `experiments/qemu-stage10/screenshots/fixed9-diag2-diag2-*.png`
  (g1–g12 — группы команд, vt1/vt1b/vt1c/unlock/unlock2/unlock3 — графическая сессия,
  fix1–fix5 — исправления)

## 1. Идентификация системы — PASS

| Проверка | Результат |
|---|---|
| `uname -a` | Linux xros-os 7.2.15-arch1-1 #1 SMP PREEMPT_DYNAMIC Tue, 03 Nov 2026 12:37:21 +0000 x86_64 GNU/Linux |
| `/etc/os-release` | NAME="XrOS", PRETTY_NAME="XrOS 1.0", ID=xros, ID_LIKE=arch, VERSION="1.0" |
| `date` | Ср 11 ноя 2026 13:39:47 +04 (часовой пояс верный) |
| `whoami` | mia |

Замечание: HOME_URL/DOCUMENTATION_URL/SUPPORT_URL/BUG_REPORT_URL в os-release — `https://xros.example/`
(плейсхолдер домена, известный, по решению этапа 10).

## 2. Hostname — PASS (с поправкой к ранней диагностике)

| Проверка | Результат |
|---|---|
| `hostnamectl status` | Static hostname: **xros-os**; Chassis: vm; Virtualization: qemu; Operating System: XrOS 1.0; Kernel: Linux 7.2.15-arch1-1; Architecture: x86-64; Firmware: 2024.02-2ubuntu0.10 |
| `cat /etc/hostname` | **xros-os** |
| `ls -l /etc/hostname` | `-rw-r--r-- 1 root root 8 ноя 11 11:04 /etc/hostname` |
| getty-баннер VT3 | `XrOS 1.0 (xros-os) - живая система` |

**Поправка:** ранний вывод «/etc/hostname нет» (мой кадр fb-c13 с первой загрузки) **не подтвердился**.
Файл существует с момента установки (mtime 11:04 — во время установки), статическое имя — xros-os.
Исправлять hostname не требуется.

### 2.1. Утилита `hostname` отсутствует — FAIL (мелочь)

| Проверка | Результат |
|---|---|
| `hostname` | command not found (бинарь отсутствует) |
| `which` | command not found (утилита `which` тоже не установлена) |
| `pacman -Qo /usr/bin/hostname` | «Ни один пакет не содержит /usr/bin/hostname» |
| `pacman -Qo /usr/bin/hostnamectl` | `/usr/bin/hostnamectl принадлежит systemd 262.2-1` |

Причина: минимальная установка — пакеты `inetutils` (даёт `hostname`) и `which` не входят в базовый набор.
`hostnamectl` работает, всё системное использует его, поэтому это косметический дефект.
Попутно: sync-базы pacman в установленной системе отсутствуют
(`database file for 'core'/'extra'/'multilib'/'xros' does not exist (use '-Sy' to download)`).
**Предлагаемое исправление (нужно подтверждение Мии на установку пакета):**
`pacman -Sy inetutils which` — проверить репозитории и зависимости перед установкой (по ТЗ).

## 3. Права на каталоги — FAIL (исправлено в VM, проверено)

| Каталог | Было | Стало |
|---|---|---|
| `/` | 555 root:root | **755 root:root** |
| `/usr` | 2755 root:root (setgid) | **755 root:root** |
| `/etc` | 2755 root:root (setgid) | **755 root:root** |
| `/var` | 755 root:root | 755 (без изменений) |
| `/home` | 755 root:root | 755 (без изменений) |
| `/boot` | 755 root:root | 755 (без изменений) |

- `getfacl /usr` и `getfacl /etc` до фикса: owner root, group root, **flags: --s-**,
  user::rwx, group::r-x, other::r-x — расширенных ACL нет, только бит setgid.
- После фикса `getfacl ... | grep flags` — строк flags нет (бит снят).
- Дефект 2770 **не воспроизводится** (это подтверждает и агент раунда 2).
- `/` = 555 при смонтированном rw (`/dev/sda2 ext4 rw,relatime`) — нестандартно
  (в Arch по умолчанию 755); root мог писать благодаря CAP_DAC_OVERRIDE, но отклонение зафиксировано.
- **Исправление (13:49, по «Чини» Мии):** точечно, без рекурсии —
  `sudo chmod g-s /usr /etc` + `sudo chmod 755 /`; метаданные до фикса сохранены
  в `~/perms-before.txt` в VM; проверка `stat` после — 755/755/755.
- **НОВОЕ (14:17, diag3): после перезагрузки `/` снова 555** (а /usr и /etc остались 755).
  Проверено в VM: правил tmpfiles для `/` нет (`grep -E "^[dD] /[[:space:]]"` — пусто),
  в /etc/fstab только `rw,relatime`, включённых юнитов xros/firstboot/tmpfiles нет,
  `chmod` есть только в скриптах установщика (не запускаются при загрузке).
  Наиболее вероятно — потеря записи при жёстком убийстве QEMU ребутом хоста №4
  (writeback-кэш qcow2 не успел сброситься; /usr и /etc успели, / — нет).
  **Повторно применено 14:20: `chmod 755 /` + `sync`, проверено 755/755/755.**
  Окончательная проверка — чистой перезагрузкой VM (без убийства хостом);
  функционально 555 для / не вредит (root обходит DAC), это косметическое отклонение от Arch.
- **Причина setgid окончательно не установлена:** в Live-системе и build rootfs права 0755
  (диагностика PASS), а в установленной — 2755. Вероятно, бит наследуется из Live rootfs
  через rsync установщика; нужна сверка прав profile/airootfs ↔ Live ↔ установленная система
  на этапе сборки. В отчёт о сборке (fixed10/Diamond) — отдельным пунктом.

## 4. Монтирование и файловая система — PASS

| Проверка | Результат |
|---|---|
| `findmnt /` | /dev/sda2 ext4 **rw**,relatime |
| `findmnt /boot/efi` | /dev/sda1 vfat rw,relatime,fmask=0077,dmask=0077 |
| `lsblk -f` | sda1 vfat FAT32, LABEL XROS-EFI, UUID 8EA8-CB50, 510,6M свободно, 0%, /boot/efi; sda2 ext4 1.0, LABEL XROS-OS, UUID ed8ba4c0-cfa4-4dd8-a51b-ca1d2c96151c, 14,2G свободно, 20%, /; sr0 — пустой виртуальный привод |

Разметка чистая: EFI + корень, метки верные.

## 5. systemd и SDDM — PASS

| Проверка | Результат |
|---|---|
| `systemctl --failed` | **0 loaded units listed** — упавших юнитов нет |
| `systemctl status sddm` | active (running) since 13:23:33; Main PID 352; enabled |
| Лог SDDM | Session plasma.desktop selected, `startplasma-wayland` for VT 1; «Authentication for user "mia" successful»; `pam_unix(sddm-autologin:session): session opened for user mia(uid=1000)` |

Автовход mia работает.

## 6. Ошибки загрузки (journalctl -b -p err) — FAIL

Видимые ошибки текущей загрузки:

| Время | Ошибка |
|---|---|
| 13:21:45 | kernel: `virt/tdx: TDX not supported by the host platform` (информационно, TDX в QEMU нет) |
| 13:24:03 | `kactivitymanagerd[412]: This application failed to start because no Qt platform plugin could be initialized. Reinstalling the application may fix this problem.` (доступные плагины: eglfs, minimalegl, offscreen, minimal, wayland-brcm, wayland-egl, wayland, xcb, vnc, linuxfb, vk.khrdisplay — wayland в списке есть, но сокет ещё не был готов) |
| 13:24:06 | `(coredump-worker)[430]: Process 412 (kactivitymanagerd) of user 1000 dumped core.` + стек вызовов Qt6Core/Qt6Gui |
| 13:24:06 | `systemd[372]: Failed to start KActivityManager Activity manager Service.` |
| 13:24:37 | `systemd[372]: Failed to start Splash screen shown during boot.` |

**Вывод:** первый экземпляр kactivitymanagerd падает при старте сессии (Wayland ещё не готов),
systemd перезапускает его, и второй экземпляр (PID 672) работает. Гонка из fixed5/fixed6
частично жива: падение + core dump на каждой загрузке — дефект, хотя конечное состояние здоровое.
**Исправление — на этапе сборки, не в VM:** упорядочить старт kactivitymanagerd после готовности
Wayland (например, ExecStartPre-ожидание WAYLAND_DISPLAY или After plasma-kwin_wayland в user-юните).
Падение сплеша — мелочь, отдельным пунктом в сборку.
Замечание: ранние строки журнала показывают hostname `archlinux` (дефолт initramfs до чтения
/etc/hostname) — косметика.

## 7. KDE Plasma — PASS (с оговоркой по перерисовке)

| Проверка | Результат |
|---|---|
| `systemctl status plasma-plasmashell --user` | active (running) since 13:25:20; Main PID 666; ExecStartPre `/usr/local/bin/xros-wait-kactivitymanagerd` — code exited, status=0/SUCCESS; Drop-In `10-kactivitymanagerd.conf` на месте |
| `ps aux` | mia 666 `/usr/bin/plasmashell --no-respawn`; mia 672 `/usr/lib/kactivitymanagerd` |
| Лог plasmashell | только warning `MESA-EGL: warning: failed to get driver name for fd -1` (программный рендер в QEMU, не ошибка) |
| Стол после загрузки | панель, часы, рабочий стол есть (кадр первой загрузки агента + мой кадр unlock3: панель, трей, часы 13:47 11.11.2026) |
| Блокировка → разблокировка | экран блокировки работает (13:45, пароль xros1234 принят со второй попытки — первая порция нажатий ушла на пробуждение экрана); **стол перерисовался за ~1–2 мин** после разблокировки. Аномалия «чёрный экран после разблокировки» (1 из 2 у агента) **в этом прогоне не воспроизвелась** |

Оговорка: в этом прогоне VT1 сразу после переключения показывал чёрный экран (DPMS-гашение
заблокированного экрана) — не путать с падением сессии: сессия была жива, Ctrl+Alt+T разбудил
экран блокировки.

## 8. Обои XrOS для пользователя mia — FAIL

| Проверка | Результат |
|---|---|
| `ls -l /usr/share/xros/wallpaper.png` | существует, 1 732 266 байт, 10 ноя 10:56 |
| `grep -i wallpaper ~/.config/plasma-org.kde.plasma.desktop-appletsrc` | только `wallpaperplugin=org.kde.image` (×3), **строки Image с путём к обоям нет** |
| Визуально (экран блокировки и стол) | **штатные обои Plasma** (фиолетово-оранжевые цветы), а не фиолетовые волны XrOS |

Причина: `/usr/local/bin/xros-set-wallpaper` запускается только из автозапуска живого
пользователя (`xros-wallpaper.desktop` в ~/.config/autostart живого пользователя); в
`/etc/xdg/autostart/` записи обоев нет, для нового пользователя mia его никто не запускает.
Сам скрипт корректен (ставит обои через `plasma-apply-wallpaperimage`, до 30 попыток с паузой 3 с,
после успеха удаляет свой autostart-файл; готовый appletsrc специально не поставляется —
Plasma 6.8 мигрирует чужой appletsrc и ломает стол, доказано на fixed2/fixed3).
**Исправление — ПРИМЕНЕНО 14:20 (diag3):** однократно запущен скрипт от имени mia
в контексте графической сессии (`XDG_RUNTIME_DIR=/run/user/1000`,
`DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus`), **exit=0 с первой попытки**;
в appletsrc появилась строка `Image=file:///usr/share/xros/wallpaper.png`;
**визуально подтверждено 14:25** (кадр diag3-vt1c): стол — фиолетовые волны XrOS с логотипом X,
панель и часы 14:25 11.11.2026. Замечание: фон экрана блокировки отдельный — в 14:21 он был
чёрным (до этого — штатные цветы Plasma); на рабочий стол это не влияет.
В сборку: установщик должен применять обои для создаваемого пользователя
(или класть xros-wallpaper.desktop в ~/.config/autostart нового пользователя).

## 9. GRUB — PASS

| Проверка | Результат |
|---|---|
| `/etc/default/grub` | GRUB_DEFAULT=0, GRUB_TIMEOUT=10, GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet", GRUB_CMDLINE_LINUX="" |
| Меню установленной системы | «Автозагрузка через 8 с» с фиолетовой полосой (кадр агента fb2-grub1; %d-шаблон работает, @TIMEOUT@ закрыт везде) |

Загрузчик не трогался (по ТЗ) и в правках не нуждается.

## 10. CA песочницы — PASS (ложная тревога закрыта окончательно)

| Проверка | Результат |
|---|---|
| `ls -la /etc/ca-certificates/trust-source/anchors/` | пусто (только `.` и `..`) |
| `find /etc -name '*hatch*'` | ничего |

CA в ISO и в установленной системе нет (подтверждено повторно в этой диагностике).

## 11. MOTD установленной системы — FAIL

`/etc/motd` содержит текст живой системы:
«Добро пожаловать в XrOS 1.0 - живую систему на базе Arch Linux. Установщик: xros-install-gui
(ярлык <Установить XrOS> на рабочем столе) или команда 'xros-install' в терминале.»
**Исправление — ПРИМЕНЕНО 14:20 (diag3):** `/etc/motd` заменён, проверено `cat /etc/motd`:
«Добро пожаловать в XrOS 1.0 — установленная система на базе Arch Linux.»
В сборку: установщик должен ставить свой MOTD вместо живого.

## 12. Сводка исправлений

| Проблема | Статус исправления |
|---|---|
| /usr и /etc 2755, / 555 | **ИСПРАВЛЕНО в VM 13:49 + повторно / 14:20, проверено 755/755/755** (откат / до 555 после ребута — см. §3, причина уточняется) |
| Обои mia не применяются | **ИСПРАВЛЕНО 14:20, визуально подтверждено 14:25** (фиолетовые волны XrOS) |
| MOTD — текст живой системы | **ИСПРАВЛЕНО 14:20, проверено `cat /etc/motd`** |
| `hostname`/`which` отсутствуют | Предложено: `pacman -Sy inetutils which` (нужно подтверждение) |
| kactivitymanagerd падает при старте | Исправление на этапе сборки (порядок старта) |
| Падение сплеша при загрузке | На этап сборки (мелочь) |
| Причина setgid 2755 | На этап сборки (сверка прав profile ↔ Live ↔ установленная) |

## 13. Прервано перезагрузкой хоста №4

13:50 +04 хост перезагрузился (uptime 0) и убил VM fixed9-diag2 в момент правки MOTD
(команда printf не завершена; /tmp/motd-new потерян — /tmp это tmpfs).
Диск `fixed9-uefi.qcow2` цел (4 837 998 592 байт, `qemu-img check` — без ошибок).
QEMU/OVMF после перезагрузки пропали; восстановление: установка из кэша apt
(`dpkg -i` по .deb из /var/cache/apt/archives — apt-get update системы завис,
списки пусты; доустановлены недостающие libfdt/libpmem/librdmacm/libibverbs/libslirp/
liburing/libfuse3/libaio/libndctl/libdaxctl/libnl).
VM перезапущена как `fixed9-diag3` (QEMU pid 3795, UEFI diskboot), дочинка MOTD и обоев —
выполнена 14:20, стол с обоями XrOS подтверждён кадром diag3-vt1c в 14:25.
Попутно воспроизведена аномалия «чёрный экран после разблокировки» (2-й раз из 4):
сессия разблокирована (loginctl LockedHint=no, plasmashell + kwin_wayland живы),
а VT1 оставался чёрным ~4 мин и перерисовался только после переключения VT3→VT1
(в diag2 перерисовка заняла 1–2 мин). Причина не установлена; в отчёт KDE-PLASMA.

## 14. Что НЕ проверялось в этом прогоне — NOT TESTED

- Полная установка с нуля (уже PASS в раунде 2, UEFI).
- BIOS-установка и первая загрузка BIOS — **делает Мия** (диск fixed9-bios.qcow2 пуст).
- ACPI-выключение в этой сессии (FAIL зафиксирован агентом в раунде 2, Live + установленная;
  повторный тест — только при стабильной системе, в конце).
- Полный GUI-тест установщика Diamond (отдельный отчёт, дедлайн 12.11.2026 17:00).
