# XrOS — подробная диагностика загрузки (BIOS и UEFI)

**Дата:** 2026-11-10. **ISO:** `out/xros-1.0-x86_64-hybrid.iso`
(SHA256 `0e664a48b9cb64a9c043dec2b8f13e620c8caddcceb5c29979760ce15e00f90c`),
исходный `out/xros-1.0-x86_64.iso`
(SHA256 `e2ac86e0e2ffc7614f50aad337c1130ec40f49213e7c7e8a86b6b8a780a0c21a`).
Оба ISO перепроверены после прогонов — не изменились.

## 0. Окружение и метод

- Хост: QEMU 8.2.2 (Debian 1:8.2.2+ds-0ubuntu1.18), OVMF 2024.02-2ubuntu0.10
  (`OVMF_CODE_4M.fd` SHA256
  `ad23261d43116abc3747d59a7837fbf578c9586a8993f4eeba064cd07eccb083`),
  SeaBIOS 1.16.3-2, TCG (нет `/dev/kvm`), 2048 МБ RAM, 2 vCPU.
- Висячий процесс QEMU от предыдущих агентов (PID 23850, `uefi-diag2`,
  работал с 11:40) найден командой `ps aux | grep qemu` и завершён
  (`kill 23850 23852`) до начала своих прогонов.
- Недостающие инструменты доустановлены: `cpio`, `zstd`
  (`apt-get install -y cpio zstd`).
- Метод загрузки в своих прогонах — **прямой запуск ядра**
  (`-kernel`/`-initrd`/`-append`) файлами, извлечёнными из того же ISO
  (`scratch/vmlinuz-linux`, `scratch/initramfs-linux.img`), с тем же
  ISO, примонтированным как CD-ROM. Обоснование: редактирование меню
  GRUB по serial в предыдущих прогонах оказалось ненадёжным (потерянные
  нажатия, испорченная командная строка — см. `logs/uefi-diag/serial.log`),
  а ядро/initramfs/ISO — те же самые файлы, что грузит GRUB; сам GRUB
  отдельно проверен в прогонах `bios-cd`/`uefi-live` (меню OK в обоих
  режимах) и в прогоне R4 ниже.
- Диагностические параметры командной строки (только в своих прогонах,
  исходная конфигурация GRUB не менялась):
  `console=tty0 console=ttyS0,115200 systemd.debug-shell=1 loglevel=7`
  и, для R2/R3, `systemd.journald.forward_to_console=1`
  (чтобы сообщения sddm/Xorg из журнала попадали в serial-лог).
- Исходная командная строка ядра из GRUB (без диагностических добавок):
  `archisobasedir=xros archisosearchuuid=2026-11-10-10-37-25-00`
  (проверено в извлечённом из ISO `/boot/grub/grub.cfg`, строки 74, 80).

## 1. Сводка четырёх комбинаций

| # | Прогон | Режим | ISO | Итог |
|---|---|---|---|---|
| R1 | `uefi-hybrid-diag-20261110` | UEFI (OVMF, q35, virtio-gpu) | гибрид | GRUB не задействован (прямой запуск ядра); ядро+initramfs OK, rootfs смонтирован, `graphical.target` достигнут, SDDM стартовал; далее цикл падения greeter'а, чёрный экран |
| R2 | `uefi-hybrid-diag2-20261110` | UEFI (OVMF, q35, virtio-gpu) | гибрид | То же + журнал в serial: первопричина установлена (см. §4) |
| R3 | `bios-hybrid-diag-20261110` | BIOS (SeaBIOS, pc, std VGA) | гибрид | Та же подпись отказа, что в UEFI (см. §5) |
| R4 | `bios-plain-diag-20261110` | BIOS (SeaBIOS, pc, std VGA) | исходный | Загрузка через прошивку: **«No bootable device.»** — в исходном ISO нет BIOS-загрузчика (по проекту) |

Плюс ранее (другими агентами, логи сохранены):
`bios-cd` (BIOS, гибрид, через GRUB) — меню GRUB OK, ядро 7.2.x
загрузилось, затем чёрный экран ≥11 мин; `uefi-live` (UEFI, гибрид,
через GRUB) — меню с темой OK, systemd 262.2, затем чёрный экран ~8 мин.

## 2. Что проверено статически (этап A)

- **Версии:** ядро `7.2.15-arch1-1` (из `vmlinuz-linux`: `Linux kernel
  x86 boot executable bzImage, version 7.2.15-arch1-1`); systemd
  `262.2-1`; GRUB `2:2.16-1`; archiso 92 (`mkinitcpio-archiso 73-1`);
  `sddm 0.21.0-7`; `plasma-workspace/kwin 6.8.2-1/2`; `mesa 1:26.2.6-1`.
  Источник: `/xros/pkglist.x86_64.txt` из ISO (645 пакетов).
- **profiledef.sh:** `iso_label="XROS_202611"`, `install_dir="xros"`,
  `bootmodes=('uefi.grub')` — только UEFI-GRUB штатно; BIOS-GRUB добавлен
  постобработкой (`Preparer: PREPARED BY MKARCHISO + XROS-BIOS-GRUB`,
  MBR `grub2-mbr`, `/boot/grub/i386-pc/eltorito.img` в гибриде).
- **Структура ISO (гибрид, `xorriso -osirrox`):** 66 узлов;
  `/EFI/BOOT/BOOTx64.EFI`, `/boot/grub/grub.cfg`,
  `/xros/boot/x86_64/vmlinuz-linux`,
  `/xros/boot/x86_64/initramfs-linux.img`,
  `/xros/x86_64/airootfs.sfs`, `/xros/x86_64/airootfs.sha512`,
  `/boot/2026-11-10-10-37-25-00.uuid` (файл-маркер, 0 байт).
- **grub.cfg одинаков в обоих ISO** (`diff` — нет отличий). Пункты меню:
  1) `XrOS 1.0 (x86_64, UEFI|BIOS)`; 2) `XrOS 1.0 — с экранным диктором
  (speaking)`; 3) `Настройки UEFI` (только EFI, `fwsetup`);
  4) `Выключить компьютер`; 5) `Перезагрузить компьютер`.
  Команда ядра: `linux /xros/boot/x86_64/vmlinuz-linux
  archisobasedir=xros archisosearchuuid=2026-11-10-10-37-25-00`,
  `initrd /xros/boot/x86_64/initramfs-linux.img`, `set gfxpayload=keep`.
- **Идентичность ISO:** `vmlinuz-linux`, `initramfs-linux.img` и
  `airootfs.sfs` побайтово идентичны между исходным и гибридным ISO
  (SHA256: ядро `3133feb3…`, initramfs `289820ad…`, sfs `b0b32f14…`).
  Различаются только загрузочные структуры (MBR/GPT/El Torito) и штамп
  времени тома (plain: `2026111010372500`, hybrid: `2026111010490300`).
- **UUID:** метка тома в обоих ISO — `XROS_202611`. В grub.cfg записан
  UUID исходного ISO (`2026-11-10-10-37-25-00`), а UUID тома гибрида —
  `2026-11-10-10-49-03-00`. Это **не причина**: хук archiso ищет
  файл `/boot/2026-11-10-10-37-25-00.uuid` на устройстве и монтирует
  `/dev/sr0` (см. логи: `Searching for '/boot/2026-11-10-10-37-25-00.uuid'
  in '/dev/sr0'` → `Device '/dev/sr0' mounted successfully`).
- **El Torito:** исходный ISO — только EFI-образ (GPT-раздел 2);
  гибрид — `grub2-mbr` + BIOS El Torito + EFI-образ.
- **SDDM:** конфиг по умолчанию `usr/lib/sddm/sddm.conf.d/default.conf`:
  `DisplayServer=x11`; профиль добавляет только
  `etc/sddm.conf.d/autologin.conf` (`User=xros`, `Session=plasma`) и
  `theme.conf` (`Current=breeze`). Сессия `plasma` есть только в
  `/usr/share/wayland-sessions/plasma.desktop`
  (`Exec=/usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland`);
  `/usr/share/xsessions/` отсутствует (X11-сессий нет — по проекту,
  Plasma 6.8 только Wayland).
- **systemd:** `default.target` → `graphical.target`; SDDM включён
  (`etc/systemd/system/display-manager.service` →
  `/usr/lib/systemd/system/sddm.service`); NetworkManager и ufw
  включены; `systemd-networkd`, `systemd-resolved`, `systemd-timesyncd`
  включены пресетом `90-systemd.preset` (штатно для Arch).

## 3. Прогон R1 — UEFI, гибрид, virtio-gpu

Лог: `logs/uefi-hybrid-diag-20261110/serial.log` (273 093 Б).
Старт 2026-11-10 11:56:20 UTC, PID 25436.

Хронология (время — секунды ядра):
- ~1–3 с: ядро, `simpledrm` (minor 0, fb0).
- ~13,7 с: `bochs-drm 0000:00:01.0: [drm] Found bochs VGA, ID 0xb0c5`
  (в q35 по умолчанию есть и std VGA), `fbcon: bochs-drmdrmfb (fb0) is
  primary device`.
- ~14,1 с: `virtio_gpu` detected (`-virgl +edid -resource_blob`,
  minor 1, fb1).
- ~31–36 с: initramfs: `Waiting 10 seconds for device
  /dev/disk/by-uuid/2026-11-10-10-37-25-00 ...`,
  `Mounting '/dev/sr0' to '/run/archiso/bootmnt'` — OK,
  cowspace tmpfs 256M, `Mounting '/dev/loop0' to '/run/archiso/airootfs'`
  — OK, `squashfs: version 4.0`, `overlayfs: "xino" feature enabled`.
- ~79–85 с: systemd 262.2, `Reached target Graphical Interface`,
  `[ OK ] Started Simple Desktop Display Manager`, serial getty
  `xros-os login:`.
- ~251 с: автовход — сессия `xros` открыта и закрыта через 0,23 с
  (audit: `session_open` 251,84 → `session_close` 252,07).
- Далее: цикл PAM-сессий пользователя `sddm` каждые ~5 с
  (91 `session_open` за ~8 мин, интервалы 4,6–6,1 с).
- Экран: чёрный с мигающим курсором сверху слева
  (`screenshots/diag-20261110-r1-vt1-now.png`, проверен визуально).
  Переключение на tty9 (debug-shell) через monitor `sendkey ctrl-alt-f9`
  экран не изменило (`screenshots/diag-20261110-r1-tty9.png` — тоже
  чёрный); слепая печать в shell маркера `TTY9ALIVE`/`T9` в serial-лог
  не попала — интерактивный shell на tty9 в этом прогоне задействовать
  не удалось (цикл greeter'а каждые ~5 с возвращает VT2; см.
  `GRAPHICS-DIAGNOSTICS.md`, §5). Поэтому для R2 использован вывод
  журнала в serial-консоль.

## 4. Прогон R2 — UEFI, гибрид, virtio-gpu, журнал в serial

Лог: `logs/uefi-hybrid-diag2-20261110/serial.log` (312 442 Б).
Старт ~12:03 UTC, PID 26470. Тот же сценарий, что R1, плюс
`systemd.journald.forward_to_console=1`.

Решающие строки (полный текст — в `BLACK-SCREEN-ROOT-CAUSE.md`, §2):

```
[  129.11] systemd-resolved.service: Failed to execute
    /usr/lib/systemd/systemd-resolved: Permission denied
[  129.17] systemd-resolved.service: Failed at step EXEC spawning
    /usr/lib/systemd/systemd-resolved: Permission denied
[  129.21] systemd-resolved.service: Main process exited, status=203/EXEC
    (то же для systemd-networkd и systemd-timesyncd)
dbus-broker-launch[792]: ERROR launcher_run_child ... +344: Permission denied
dbus-broker-launch[791]: ERROR service_add ... +1011: Transport endpoint is not connected
systemd[1]: dbus-broker.service: Failed with result 'start-limit-hit'.
systemd[1]: dbus.socket: Failed with result 'service-start-limit-hit'.
systemd-logind[795]: Failed to start user service 'user-runtime-dir@1000.service':
    Transport endpoint is not connected
sddm-helper[855]: pam_systemd(sddm-autologin:session):
    Varlink call io.systemd.Login.CreateSession failed
sddm-helper[855]: Starting Wayland user session: ... startplasma-wayland
sddm[837]: Auth: sddm-helper exited with 2
sddm[837]: Could not setup default cursor
sddm-helper[875]: Starting X11 session: "" "/usr/bin/sddm-greeter-qt6 ..."
    (далее цикл каждые ~5 с)
```

Счётчики в логе R2: `Failed to start` — 148, `sddm` — 100 строк,
`greeter` — 28. Ошибок DRM/KMS/Xorg/EGL в журнале нет (0 строк
`Xorg`, `EGL`, `modeset`).

**Вывод R2:** загрузка останавливается НЕ на монтировании rootfs и НЕ
на графике, а на невозможности выполнить любой non-root процесс:
`systemd-resolved/networkd/timesyncd` (203/EXEC), дочерний процесс
`dbus-broker` (пользователь `dbus`), greeter SDDM (uid 965), сессия
Plasma (uid 1000). Системная шина D-Bus мертва, logind не создаёт
пользовательские сессии. Причина — права `2770` на `/usr` и `/etc`
(см. `BLACK-SCREEN-ROOT-CAUSE.md`).

## 5. Прогон R3 — BIOS, гибрид, std VGA

Лог: `logs/bios-hybrid-diag-20261110/serial.log` (244 823 Б).
Старт ~12:12 UTC, PID 27152. SeaBIOS, `-machine pc`, `-vga std`.

Та же подпись отказа, что в UEFI:
- 127 строк `Permission denied`, 61× `status=203/EXEC`;
- `dbus-broker-launch` EACCES (×35 строк), `start-limit-hit`;
- `Could not setup default cursor` ×11, `sddm-helper exited with 2` ×11;
- автовход `xros` → `Starting Wayland user session` →
  мгновенное закрытие; далее цикл greeter'а `sddm-greeter-qt6` (~5 с);
- `Reached target Graphical Interface` — достигнут;
- DRM: `bochs-drm 0000:00:02.0: [drm] Found bochs VGA, ID 0xb0c5`,
  `Initialized bochs-drm 1.0.0 ... on minor 0`, `fb0: bochs-drmdrmfb` —
  без ошибок.
- Экран: чёрный (`screenshots/diag-20261110-r3-bios-black.png`,
  проверен визуально — чёрный кадр с курсором сверху слева).

**Вывод R3:** отказ полностью воспроизводится в BIOS и не зависит ни
от прошивки, ни от видеокарты (std VGA вместо virtio-gpu).

## 6. Прогон R4 — BIOS, исходный ISO (через прошивку)

Лог: `logs/bios-plain-diag-20261110/serial.log` (0 Б — SeaBIOS в serial
не пишет). Старт ~12:26 UTC, PID 27576. Обычная загрузка с CD через
SeaBIOS, без `-kernel`.

Скриншот `screenshots/diag-20261110-r4-bios-plain.png` (проверен
визуально, 720×400, текстовый режим):

```
Booting from ROM...
iPXE (PCI 00:03.0) starting execution...ok
Nothing to boot: No such file or directory (https://ipxe.org/2d03e13b)
No more network devices
Booting from Hard Disk...
Boot failed: could not read the boot disk
No bootable device.
```

**Вывод R4:** исходный ISO в BIOS не загружается вообще — по проекту:
`profiledef.sh: bootmodes=('uefi.grub')`, в ISO только EFI-образ
El Torito. Это ожидаемо, а не дефект; BIOS-загрузка есть только у
гибридного ISO (постобработка с GRUB `i386-pc`).

## 7. Известные косметические дефекты GRUB (не причина)

- BIOS: `error: script/function.c:grub_script_function_find:119:
  can't find command 'background_image'` — в BIOS-образе GRUB
  (eltorito) нет модуля `background_image`; в UEFI этой ошибки нет.
  Меню при этом работает (подтверждено `logs/bios-cd/serial.log`).
- Футер темы показывает буквальный `@TIMEOUT@` вместо секунд
  (`theme.txt`: `text = "Автозагрузка через @TIMEOUT@ с"`).
- 2-й пункт меню обрезан справа (ширина меню 50% в `theme.txt`).
- На serial-консоли GRUB кириллица отображается как `?` — только
  в serial-выводе, на VGA кириллица корректна (см. `uefi-live-grub-menu.png`).

## 8. Где останавливается загрузка (по режимам)

| Режим | Этап остановки |
|---|---|
| UEFI, гибрид | systemd доходит до `graphical.target`, SDDM стартует; далее: автовход `xros` падает за 0,23 с, greeter SDDM падает за ~0,1 с в цикле ~5 с. Дальше — чёрный экран. |
| BIOS, гибрид | То же самое (std VGA, `bochs-drm` OK). |
| UEFI, исходный | Идентичен UEFI-гибриду (ядро/initramfs/squashfs побайтово те же; проверено SHA256). Отдельный прогон не проводился — эквивалентность доказана хэшами. |
| BIOS, исходный | Не загружается вообще: «No bootable device.» (нет BIOS-загрузчика в ISO). |

## 9. Изменённые файлы (только диагностика)

Новые логи:
`logs/uefi-hybrid-diag-20261110/` (run-info, serial.log, qemu.stderr.log),
`logs/uefi-hybrid-diag2-20261110/`, `logs/bios-hybrid-diag-20261110/`,
`logs/bios-plain-diag-20261110/`;
новые скриншоты `screenshots/diag-20261110-r1-*.png`,
`diag-20261110-r3-bios-black.png`, `diag-20261110-r4-bios-plain.png`;
вспомогательные скрипты `monq.py`, `typeq.py`, `typeq-fast.py`;
отчёты `BLACK-SCREEN-ROOT-CAUSE.md`, `BOOT-DIAGNOSTICS.md`,
`LIVE-ROOTFS-REPORT.md`, `GRAPHICS-DIAGNOSTICS.md`.
Исходники проекта, ISO и `~/MEMORY.md` не менялись (SHA256 ISO
перепроверены после прогонов).
