# XrOS — диагностика systemd и графической среды (SDDM / KDE)

**Дата:** 2026-11-10. **ISO:** `out/xros-1.0-x86_64-hybrid.iso`
(SHA256 `0e664a48b9cb64a9c043dec2b8f13e620c8caddcceb5c29979760ce15e00f90c`).

## 1. Вердикт

Этап НЕ заблокирован: systemd и графика продиагностированы по журналу
(перенаправленному в serial-консоль). **Графическая подсистема
исправна; чёрный экран вызван не ею.** SDDM стартует, X-сервер
поднимается от root, но greeter и сессия Plasma умирают мгновенно,
потому что не могут выполнить ни один файл из `/usr` (права 2770,
подробности — в `BLACK-SCREEN-ROOT-CAUSE.md` и
`LIVE-ROOTFS-REPORT.md`).

## 2. Достигнутый target и состояние служб

Прогоны R1/R2 (UEFI) и R3 (BIOS) — одинаково:

```
[  OK  ] Reached target Graphical Interface.
[  OK  ] Started Simple Desktop Display Manager.
[  OK  ] Started Serial Getty on ttyS0.
[  OK  ] Reached target Login Prompts.
[  OK  ] Reached target Multi-User System.
```

- SDDM (`sddm.service`, root, `Restart=always`) — `Started`, pid 837
  (R2) / 834 (R3). Работает весь прогон.
- `systemd-logind` — работает (`New seat seat0`, кнопки питания и
  клавиатура наблюдаются: `Watching system buttons on /dev/input/event0/1`).
- `systemd-journald`, `systemd-udevd` (262.2) — работают.
- **Мертвы (203/EXEC, Permission denied):** `systemd-resolved`,
  `systemd-networkd`, `systemd-timesyncd` — все с `User=` non-root.
  После нескольких перезапусков — `start-limit-hit`; у networkd
  дополнительно падают зависимые сокеты (`systemd-networkd.socket`,
  `...-varlink.socket`, `...-resolve-hook.socket`).
- **Мёртв (EACCES в дочернем процессе):** `dbus-broker.service` —
  5 попыток, затем `start-limit-hit`; `dbus.socket` —
  `service-start-limit-hit`. **Системной шины D-Bus нет.**
- `systemd-homed` (root) стартует, но падает:
  `Event loop failed: Connection reset by peer` (шина мертва).
- `systemd-networkd-persistent-storage.service` — `Dependency failed`
  (зависимость от networkd).

## 3. SDDM: greeter и автовход

Конфигурация (проверено в rootfs):
- `usr/lib/sddm/sddm.conf.d/default.conf`: `DisplayServer=x11`
  (по умолчанию; Wayland помечен experimental).
- `etc/sddm.conf.d/autologin.conf`: `[Autologin] User=xros,
  Session=plasma`.
- `etc/sddm.conf.d/theme.conf`: `[Theme] Current=breeze,
  CursorTheme=breeze_cursors`. Тема `breeze` на месте
  (`/usr/share/sddm/themes/breeze/Main.qml` и др.).
- `sddm.service`: `ExecStart=/usr/bin/sddm`, `Restart=always`,
  `StartLimitBurst=2`, `Conflicts=getty@tty1.service`.
- Бинарь greeter'а: `/usr/bin/sddm-greeter-qt6`; X-сервер:
  `/usr/bin/X` → `Xorg` 21.1.25-2; `modesetting_drv.so` на месте.

Фактическая последовательность (R2, журнал в serial):

1. `sddm[837]: Could not setup default cursor` (252,57 с).
2. Автовход: `pam_unix(sddm-autologin:session): session opened for
   user xros(uid=1000)` → `Starting Wayland user session:
   "/usr/share/sddm/scripts/wayland-session"
   "/usr/lib/plasma-dbus-run-session-if-needed
   /usr/bin/startplasma-wayland"` → `sddm[837]: Auth: sddm-helper
   exited with 2`. Сессия прожила 0,23 с.
3. Greeter: `Starting X11 session: "" "/usr/bin/sddm-greeter-qt6
   --socket /tmp/sddm-:0-gHAOYY --theme /usr/share/sddm/themes/breeze"`
   → `session closed for user sddm` через ~0,1 с →
   `Could not setup default cursor` → повтор каждые ~5 с
   (91 цикл за ~8 мин в R1; интервалы 4,6–6,1 с).
4. Побочные строки PAM: `pam_systemd_home: Failed to connect to system
   bus: В соединении отказано`, `pam_systemd: Varlink call
   io.systemd.Login.CreateSession failed`, `pam_motd: error scanning
   directory /etc/motd.d: Отказано в доступе` (тоже следствие 2770
   на `/etc`).

Ни разу не появилось ни одной строки об ошибке Xorg, EGL, GLX,
modesetting или kwin (в R2: `Xorg` — 0, `EGL` — 0, `kwin` — 0,
`modeset` — 0). Greeter и сессия умирают на этапе `exec()`, до
обращения к графике.

## 4. Plasma / Wayland / X11: наличие компонентов

Проверено статически в `work/x86_64/airootfs/` (источник squashfs):

- `plasma-workspace 6.8.2-1`, `plasma-desktop 6.8.2-1`, `kwin 6.8.2-2`,
  `sddm 0.21.0-7`, `mesa 1:26.2.6-1`, `libdrm 2.4.134-1`,
  `wayland 1.26.0-1`, `xorg-server 21.1.25-2`,
  `xorg-xwayland 24.1.14-1`, `qt6-base 6.12.0-4`.
- `libQt6WaylandClient.so.6.12.0` **есть** (пакет `qt6-base` в Qt 6.12
  включает модуль Wayland-клиента; отдельного пакета `qt6-wayland`
  в списке нет — это не дефект).
- Qt platform plugins: `libqxcb.so`, `libqwayland.so`, `libqeglfs.so`,
  `libqminimal.so`, `libqoffscreen.so` — на месте.
- `libEGL_mesa.so`, `libGL.so`, `libGLESv2.so` — на месте.
- DRI-драйверы в `/usr/lib/dri/` — на месте, включая `kms_swrast_dri.so`.
- Сессия Plasma: только Wayland
  (`/usr/share/wayland-sessions/plasma.desktop`,
  `Exec=... /usr/bin/startplasma-wayland`); X11-сессий нет
  (`/usr/share/xsessions/` отсутствует) — по проекту (Plasma 6.8,
  `plasma-x11-session` удалён из Arch).
- `weston` отсутствует — не нужен: `DisplayServer=x11`, а Wayland-
  greeter не используется.
- Пользователь `xros` (uid 1000, группы `wheel,audio,video,optical,
  storage,render`), пароль заблокирован (`passwd -l`), sudo без пароля;
  `sddm` (uid 965). Домашний каталог `/home/xros` — 2770 `xros:xros`
  (для самого xros проходим, не является блокером).

## 5. DRM/KMS и виртуальные GPU (факты из журналов ядра)

UEFI + virtio-gpu (R1, `loglevel=7`):

```
[    3.36] [drm] Initialized simpledrm 1.0.0 for simple-framebuffer.0 on minor 0
[   13.74] bochs-drm 0000:00:01.0: vgaarb: deactivate vga console
[   13.76] [drm] Found bochs VGA, ID 0xb0c5.
[   13.76] [drm] Framebuffer size 16384 kB @ 0x80000000, mmio @ 0x81087000.
[   13.80] [drm] Initialized bochs-drm 1.0.0 for 0000:00:01.0 on minor 0
[   13.94] fbcon: bochs-drmdrmfb (fb0) is primary device
[   14.06] [drm] pci: virtio-gpu-pci detected at 0000:00:02.0
[   14.07] [drm] features: -virgl +edid -resource_blob -host_visible
[   14.08] [drm] number of scanouts: 1
[   14.16] [drm] Initialized virtio_gpu 0.1.0 for 0000:00:02.0 on minor 1
[   14.35] virtio-pci 0000:00:02.0: [drm] fb1: virtio_gpudrmfb frame buffer device
```

BIOS + std VGA (R3):

```
bochs-drm 0000:00:02.0: [drm] Found bochs VGA, ID 0xb0c5.
[drm] Initialized bochs-drm 1.0.0 for 0000:00:02.0 on minor 0
bochs-drm 0000:00:02.0: [drm] fb0: bochs-drmdrmfb frame buffer device
```

Оба DRM-устройства инициализируются без ошибок; `fbcon` работает
(загрузочные сообщения видны на VGA до старта SDDM — скриншот
`uefi-live-boot-2min.png` из прошлых прогонов). Ошибок DRM/KMS
в журналах нет. Драйверы `bochs.ko`, `virtio-gpu.ko` есть и в
initramfs, и в живой системе.

### Сравнение режимов виртуальной графики

| Режим | Прогон | Результат |
|---|---|---|
| virtio-gpu-pci (+ std VGA в q35) | R1, R2 (UEFI) | Тот же отказ: 203/EXEC, мёртвый D-Bus, цикл greeter'а |
| std VGA (`-vga std`) | R3 (BIOS) | Тот же отказ, побайтово та же подпись |
| QXL (`-vga qxl`) | — | **SKIP (честный)**: отказ наступает на `exec()` non-root процессов до любого обращения к GPU и воспроизводится одинаково на двух уже проверенных GPU; QXL не изменил бы точку отказа. Отдельный прогон не проводился. |

Вывод: проблема не в графическом драйвере и не зависит от GPU —
она в правах доступа внутри rootfs.

## 6. Попытка интерактивной диагностики (честно о неудаче)

Интерактивный root-shell через `systemd.debug-shell=1` (tty9)
задействовать не удалось:
- `sendkey ctrl-alt-f9` через QEMU monitor выполняется, но скриншот
  tty9 остаётся чёрным (`screenshots/diag-20261110-r1-tty9.png`);
- слепая печать маркера (`echo TTY9ALIVE >/dev/ttyS0`) через
  `sendtext.py`/`typeq.py`/`typeq-fast.py` (новые вспомогательные
  скрипты в `experiments/qemu-stage10/`) маркера в serial-лог не дала;
- вероятная причина: цикл перезапуска greeter'а каждые ~5 с
  возвращает активный VT на tty2, и нажатия уходят не в shell tty9;
  дополнительно `sendtext.py` зависал на чтении ответа монитора
  (убит, заменён на `typeq.py`/`typeq-fast.py` с отдельным
  соединением на клавишу).
- Обходной путь, давший решающие данные: вывод журнала в
  serial-консоль (`systemd.journald.forward_to_console=1`) — все
  ошибки sddm/dbus/systemd получены без интерактивного shell.
- Для полноты: `journalctl`, `systemctl status sddm`,
  `cat /var/log/Xorg.0.log` и `loginctl` внутри живой системы
  напрямую не выполнялись — в них нет необходимости: причина
  установлена по журналу, а Xorg.0.log не содержит строк в журнале
  (0 упоминаний Xorg), что согласуется с падением greeter'а до
  запуска X-клиента.

## 7. Нагрузка и «замершее» чтение с диска

QEMU ~109% CPU при чёрном экране (R1/R3) — это циклы перезапуска:
`systemd-resolved/networkd/timesyncd` (restart), `dbus-broker`
(до start-limit), SDDM greeter (~5 с). Чтение с CD замирает, потому
что загружать больше нечего: система давно в `graphical.target`,
а графическая сессия не стартует.

## 8. Выводы по этапу E

- [x] Достигнутый target: `graphical.target` (UEFI и BIOS).
- [x] SDDM запускается; греeter и автовход падают мгновенно
      (0,1 с / 0,23 с) в цикле ~5 с.
- [x] Конкретная служба/механизм отказа: `execve()` → EACCES для
      всех non-root процессов из-за `/usr` и `/etc` 2770;
      вторично — мёртвая шина D-Bus и невозможность создать
      пользовательскую сессию logind.
- [x] Wayland и X11 проверены: оба пути (X11-greeter и
      Wayland-сессия Plasma) падают до работы с GPU.
- [x] Библиотеки/драйверы графики на месте; DRM/KMS без ошибок.
- [ ] QXL — честный SKIP (см. §5).
- [ ] Интерактивный shell на tty9 — не задействован (см. §6);
      данных журнала достаточно для установления причины.
