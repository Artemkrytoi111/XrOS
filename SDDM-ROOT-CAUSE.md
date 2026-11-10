# SDDM-ROOT-CAUSE.md — диагностика SDDM и первопричина чёрного экрана (XrOS 1.0)

Дата: 2026-11-10. Автор: агент автономного восстановления XrOS.
Подробный разбор с цифрами — в `BLACK-SCREEN-ROOT-CAUSE.md`,
`BOOT-DIAGNOSTICS.md`, `LIVE-ROOTFS-REPORT.md`; здесь — срез по SDDM.

## Итог

Первопричина чёрного экрана — **не SDDM и не графика**, а права доступа
в live-rootfs: 34 каталога (включая `/usr`, `/etc`) имели режим 2770
(`drwxrws---`, root:root), 64 файла — 660. Не-root процессы не могли
выполнить файлы из `/usr` и прочитать `/etc`. SDDM при этом был
исправен и настроен правильно; он падал как следствие, а не как причина.

## 1. Конфигурация SDDM (проверена, корректна)

- Установлен: `sddm 0.21.0-7`, служба `sddm.service` enabled.
- Автовход: `/etc/sddm.conf.d/autologin.conf` — `User=xros`,
  `Session=plasma`; тема — `breeze`, курсор `breeze_cursors`
  (`/etc/sddm.conf.d/theme.conf`).
- Сессии Wayland: `/usr/share/wayland-sessions/plasma.desktop` есть.
  X11-сессий нет по дизайну (Plasma 6.8, `plasma-x11-session` удалён
  из Arch; `/usr/share/xsessions` отсутствует) — тест X11 SKIP.
- Живой пользователь `xros` (uid 1000): домашний каталог `/home/xros`,
  группы `wheel,audio,video,optical,storage,render`, пароль заблокирован
  (`passwd -l`), sudo без пароля. `/run/user/1000` создаётся logind,
  `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS` — штатные.
- `sddm-greeter-qt6 --version` — rc=0; `sddm --help` — работает;
  `sddm --version` — SIGABRT (rc=134): это НЕ валидная опция SDDM,
  не использовать как проверку исправности.
- Зависимости: `ldd` для sddm, greeter, plasmashell, kwin_wayland —
  недостающих библиотек нет; `plasmashell 6.8.2` и `kwin 6.8.2`
  запускаются от xros с `QT_QPA_PLATFORM=offscreen` (rc=0).

## 2. Как падал SDDM в старом ISO (доказательства из serial-логов)

Логи: `experiments/qemu-stage10/logs/uefi-hybrid-diag2-20261110/serial.log`
и `bios-hybrid-diag-20261110/serial.log` (старый ISO, до исправления прав):

- 127× «Permission denied» в каждом логе.
- `systemd-resolved` / `networkd` / `timesyncd` — `status=203/EXEC`
  в цикле (не могут выполнить файлы из `/usr`).
- `dbus-broker-launch` (user `dbus`, uid 81) — «Permission denied» →
  нет системной шины D-Bus → logind не создаёт сессии.
- Сессия автовхода `xros` живёт 0,23 с; greeter SDDM живёт ~0,1 с;
  **91 цикл перезапуска SDDM за ~8 мин** → чёрный экран.
- При этом systemd доходит до `graphical.target`, SDDM стартует,
  DRM/KMS исправны (bochs-drm, simpledrm, fb0).

Происхождение 2770: хост — setgid-каталоги 2770 + `umask 0007` →
`profile/airootfs/` 2770/660 → `scripts/build-rootfs-pacstrap.sh:243`
`cp -af --no-preserve=ownership,mode` сохраняет режимы → pacman
предупреждал (5 602× «directory permissions differ» в
`out/pacstrap-build.log`), но не исправлял → squashfs сохранил 2770.
Масштаб: установщик копирует живую систему через
`rsync -aAX / "$TARGET"/` (`src/xros-install:739`) — установленная
система унаследовала бы те же 2770.

## 3. Подтверждение исправления (новый ISO fixed)

- `out/xros-1.0-fixed-x86_64-hybrid.iso`
  (SHA256 `2082ad65536e799015d1f12fb25ba82100dfc9ec4a3c21e7c8e9ece336e8c310`):
  в squashfs 0× каталогов 2770, 0× файлов 660 (кроме placeholder
  `/dev/null`); `/etc` и `/usr` — 2755 (эквивалент 755 по доступу).
- В QEMU (diag, diag2, grub): 0× «Permission denied», 0× 203/EXEC,
  SDDM стартует ровно 1 раз, сессия xros открывается (193 с),
  Wayland-сессия стартует (197 с), сессия не закрывается.
- Исправления: `scripts/build-rootfs-pacstrap.sh` (umask 0022, шаг 4а
  нормализация прав профиля, шаг 11б финальная проверка +
  allowlist `/var/log/btmp`, `/var/log/lastlog`, проверка доступности
  от xros через `runuser`), `profile/airootfs/` (каталоги 755,
  файлы 644), `customize_airootfs.sh` (umask 0022),
  `scripts/xros-diagnose.sh` (секция 21). Подробно — в `FIX-REPORT.md`.

## 4. Что осталось по SDDM/сессии (после исправления прав)

Следующая проблема — уже не SDDM, а раскладка Plasma: ошибка виджета
`""` на весь экран и отсутствие панели (минимальный appletsrc).
SDDM, автовход и сессия при этом работают. Подробно —
в `PLASMA-SESSION-REPORT.md`.
