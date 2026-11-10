# XrOS — первопричина чёрного экрана live-системы

**Дата диагностики:** 2026-11-10 (UTC ~11:56–12:30).
**ISO:** `out/xros-1.0-x86_64-hybrid.iso`, SHA256
`0e664a48b9cb64a9c043dec2b8f13e620c8caddcceb5c29979760ce15e00f90c`
(перепроверен после всех прогонов — не изменился).
Исходный ISO `out/xros-1.0-x86_64.iso`:
`e2ac86e0e2ffc7614f50aad337c1130ec40f49213e7c7e8a86b6b8a780a0c21a`.
**Статус:** причина УСТАНОВЛЕНА, с прямыми доказательствами из журналов
загрузки. Это НЕ проблема графики, НЕ проблема GRUB, НЕ проблема
ядра/initramfs и НЕ проблема метки/UUID ISO.

## 1. Первопричина (одно предложение)

**В живой системе каталоги `/usr` и `/etc` (и ещё 32 каталога из профиля)
имеют права `drwxrws---` (mode 2770, root:root) вместо 0755** — поэтому
любой процесс, работающий НЕ от root, не может ни выполнить файл из
`/usr`, ни прочитать что-либо из `/etc`: `execve()` возвращает
`EACCES (Permission denied)`.

## 2. Доказательства

### 2.1. Права в живой системе (из самого ISO)

Каталоги в `work/x86_64/airootfs/` — источнике `airootfs.sfs`, и в
независимой распаковке из `airootfs.sfs`
(`experiments/qemu-stage10/scratch/airootfs-part/`):

```
drwxrws--- root root  /usr
drwxrws--- root root  /etc
drwxrws--- root root  /usr/share
drwxrws--- root root  /usr/local, /usr/local/bin, /etc/systemd, ...
```

Всего каталогов с mode 2770 в живой системе — **34** (полный список —
в `LIVE-ROOTFS-REPORT.md`, §5). Сами исполняемые файлы при этом
нормальные (`-rwxr-xr-x`): `systemd-resolved`, `systemd-networkd`,
`systemd-timesyncd`, `dbus-broker`, `sddm-greeter-qt6` — все 755.
Ломает не файл, а **непроходимый для non-root родительский каталог**.

### 2.2. Журнал загрузки: отказ exec именно у non-root служб

Прогон `uefi-hybrid-diag2-20261110` (UEFI, virtio-gpu, журнал перенаправлен
в serial-консоль параметром `systemd.journald.forward_to_console=1`):

```
[  129.11] (stemd-resolved)[497]: systemd-resolved.service:
    Failed to execute /usr/lib/systemd/systemd-resolved: Permission denied
[  129.17] (stemd-resolved)[497]: systemd-resolved.service:
    Failed at step EXEC spawning /usr/lib/systemd/systemd-resolved: Permission denied
[  129.21] systemd[1]: systemd-resolved.service: Main process exited,
    code=exited, status=203/EXEC
```

То же для `systemd-networkd` (User=systemd-network) и
`systemd-timesyncd` (User=systemd-timesync) — все три юнита имеют
`User=` non-root. Службы, работающие от root (`systemd-logind`,
`systemd-journald`, `sddm`, `udev`), стартуют нормально.

### 2.3. Мёртвая системная шина D-Bus

```
dbus-broker-launch[792]: ERROR launcher_run_child @
    ../dbus-broker-37/src/launch/launcher.c +344: Permission denied
dbus-broker-launch[791]: ERROR service_add @
    ../dbus-broker-37/src/launch/service.c +1011: Transport endpoint is not connected
dbus-broker-launch[791]: Exiting due to fatal error: -107
systemd[1]: dbus-broker.service: Main process exited, code=exited, status=1/FAILURE
... (5 попыток)
systemd[1]: dbus-broker.service: Start request repeated too quickly.
systemd[1]: dbus-broker.service: Failed with result 'start-limit-hit'.
systemd[1]: dbus.socket: Failed with result 'service-start-limit-hit'.
```

Причина та же: `dbus-broker-launch` сбрасывает привилегии к пользователю
`dbus`, потому что `/usr/share/dbus-1/system.conf` содержит
`<user>dbus</user>` (проверено в rootfs). Дочерний процесс не может
выполнить `/usr/bin/dbus-broker` под `/usr` 2770 → EACCES.
**Системной шины D-Bus в живой системе нет вообще.**

Следствия мёртвой шины (из того же журнала):

```
systemd-logind[795]: Failed to start user service 'user-runtime-dir@1000.service':
    Transport endpoint is not connected
systemd-logind[795]: Failed to start user service 'user@1000.service':
    Transport endpoint is not connected
sddm-helper[855]: pam_systemd(sddm-autologin:session):
    Varlink call io.systemd.Login.CreateSession failed: ...
sddm-helper[855]: pam_systemd_home(sddm-autologin:account):
    Failed to connect to system bus: В соединении отказано
systemd-homed[794]: Event loop failed: Connection reset by peer
```

### 2.4. Падение автовхода и greeter'а SDDM

```
sddm-helper[855]: pam_unix(sddm-autologin:session): session opened for user xros(uid=1000)
sddm-helper[855]: Starting Wayland user session: "/usr/share/sddm/scripts/wayland-session"
    "/usr/lib/plasma-dbus-run-session-if-needed /usr/bin/startplasma-wayland"
sddm[837]: Auth: sddm-helper exited with 2
```

Сессия `xros` живёт **0,23 с** (открыта 251,84 с, закрыта 252,07 с):
`startplasma-wayland` (uid 1000) не может выполнить ни один файл из
`/usr`. Затем SDDM переходит к greeter'у:

```
sddm-helper[875]: Starting X11 session: "" "/usr/bin/sddm-greeter-qt6
    --socket /tmp/sddm-:0-gHAOYY --theme /usr/share/sddm/themes/breeze"
sddm-helper[875]: pam_unix(sddm-greeter:session): session closed for user sddm
sddm[837]: Could not setup default cursor
```

Сессия greeter'а (uid 965, пользователь `sddm`) живёт **~0,1 с** и
перезапускается каждые **~5,0 с** (91 цикл за ~8 минут в прогоне R1,
интервалы 4,6–6,1 с). Greeter ни разу не отрисовался → чёрный экран.
Нагрузка QEMU ~109% CPU — это циклы перезапуска, а не загрузка.

### 2.5. BIOS подтверждает независимость от прошивки

Прогон `bios-hybrid-diag-20261110` (SeaBIOS, std VGA, тот же журнал):
127 строк `Permission denied`, 61× `status=203/EXEC`, те же ошибки
`dbus-broker-launch`, те же `Could not setup default cursor` (×11) и
`sddm-helper exited with 2` (×11), тот же автовход `xros` → мгновенное
закрытие. Подпись отказа побайтово та же, что в UEFI.

## 3. Как 2770 попало в образ (механизм, проверен по файлам)

1. Хост: все каталоги рабочего дерева `~/workspace` — `drwxrws---`
   (setgid 2770, группа `nogroup`), текущий `umask` — **0007**.
   Соответственно, все каталоги `profile/airootfs/` на хосте тоже 2770
   (проверено: `profile/airootfs`, `etc`, `usr`, `usr/share`,
   `usr/local`, `etc/systemd`, …).
2. `scripts/build-rootfs-pacstrap.sh`, шаг 4: профиль копируется в новый
   rootfs командой
   `cp -af --no-preserve=ownership,mode -- /xros/profile/airootfs/. /xros/work/x86_64/airootfs/`.
   Даже с `--no-preserve=mode` GNU cp создаёт каталоги с режимом
   «режим источника, очищенный umask»: `2770 & ~0007 = 2770` — umask
   0007 не снимает ни одного установленного бита. Итог: `/usr`, `/etc`,
   `/usr/share` и остальные каталоги профиля в rootfs — 2770.
3. `pacman` при pacstrap ЗАМЕТИЛ проблему, но не исправил её
   (`out/pacstrap-build.log`, строки ~710–763, повторяется для каждого
   пакета):
   ```
   warning: directory permissions differ on /xros/work/x86_64/airootfs/usr/
   filesystem: 2770  package: 755
   warning: directory permissions differ on /xros/work/x86_64/airootfs/etc/
   filesystem: 2770  package: 755
   ```
   Каталоги, созданные самим pacman, получили 755 из метаданных пакетов
   (поэтому `/usr/bin`, `/usr/lib` — 755); каталоги, уже существовавшие
   от копии профиля, pacman не трогает.
4. `mkarchiso` запаковал `work/x86_64/airootfs` в `airootfs.sfs` как есть.
   В build-env (`build-env/root.x86_64/`) `/usr` и `/etc` — нормальные
   755: дефект внесён именно на этапе сборки live-rootfs, а не в
   bootstrap-окружении.
5. Команда `scripts/build.sh` (строки ~241–246) прямо документирует
   условие хоста: «user namespace + btrfs + setgid-родители 2770».

## 4. Что при этом работает (и почему это вводило в заблуждение)

- GRUB-меню (BIOS и UEFI), ядро 7.2.15-arch1-1, initramfs (hooks
  `base udev archiso archiso_loop_mnt archiso_pxe_* archiso_kms block
  filesystems keyboard`), монтирование `/dev/sr0` → loop0 squashfs →
  overlayfs, `switch_root`, systemd 262.2-1 доходит до
  `graphical.target`, SDDM стартует — **всё это процессы root**, а root
  права 2770 не ограничивают.
- DRM/KMS исправны: в UEFI `bochs-drm` (minor 0, fb0) +
  `virtio_gpu` (minor 1, fb1); в BIOS `bochs-drm` (minor 0, fb0).
  Драйверы `bochs.ko`, `virtio-gpu.ko`, `loop.ko`, `squashfs.ko`,
  `overlay.ko` есть и в initramfs, и в живой системе.
- Поэтому «чёрный экран после меню GRUB» выглядел как проблема
  графики, хотя графика ни разу не ошиблась.

## 5. Что НЕ является причиной (исключено доказательствами)

| Гипотеза | Почему нет |
|---|---|
| Устаревший UUID в grub.cfg (`archisosearchuuid=2026-11-10-10-37-25-00` при UUID тома гибрида `2026-11-10-10-49-03-00`) | archiso ищет файл-маркер `/boot/2026-11-10-10-37-25-00.uuid` на `/dev/sr0` и монтирует его во всех прогонах; rootfs смонтирован |
| Не найден Live-носитель / squashfs | `/dev/sr0` смонтирован, loop0 + squashfs + overlayfs — во всех журналах |
| Неподходящее ядро/initramfs | vmlinuz и initramfs побайтово идентичны (sha256) в обоих ISO; initramfs соответствует ядру 7.2.15-arch1-1; все нужные модули на месте |
| Отсутствует qt6-wayland | `libQt6WaylandClient.so.6.12.0` есть — в Qt 6.12 он входит в пакет `qt6-base` (проверено по `/var/lib/pacman/local/qt6-base-*/files`) |
| Отсутствуют Mesa / Xorg / драйверы | mesa 26.2.6, `xorg-server` 21.1.25-2, `modesetting_drv.so`, DRI-драйверы (вкл. `kms_swrast`) — на месте |
| Ошибка GRUB `background_image` (BIOS) | Косметика: модуль отсутствует только в BIOS-образе GRUB; меню работает, ядро грузится |
| `@TIMEOUT@` / обрезка пункта меню | Косметика темы GRUB, на загрузку не влияет |
| Сеть (networkd/resolved) | Следствие: эти службы падают с тем же 203/EXEC EACCES, а не причина |
| Wayland vs X11 | SDDM по умолчанию `DisplayServer=x11` (greeter — X11), автовход — Wayland-сессия Plasma; падают ОБА — до любой работы с GPU |

## 6. Масштаб последствий

Дефект не только live-режима: установщик `src/xros-install`
(строка 739) копирует живую систему на целевой диск командой
`rsync -aAX / "$TARGET"/` — права 2770 унаследовала бы и
**установленная система** (проверено чтением кода установщика;
полная установка в этой диагностике не тестировалась).

## 7. Рекомендация для следующего этапа (НЕ применена)

Минимальное исправление — нормализовать права каталогов профиля
в rootfs на этапе сборки, до pacstrap/squashfs:

- в `scripts/build-rootfs-pacstrap.sh`, шаг 4, после копирования
  профиля: явно `chmod 755` для `/usr`, `/etc`, `/usr/share` и всех
  остальных каталогов, пришедших из профиля (или, надёжнее,
  `find "$AIROOTFS" -type d -perm 2770 -exec chmod 755 {} +`),
  не трогая явно заданные `file_permissions` (`/etc/shadow` 0400,
  `/root` 0750 и т.п.);
- параллельно исправить исходник: `chmod 755` каталогов
  `profile/airootfs/` на хосте;
- добавить в диагностику (`scripts/diagnose.sh`) проверку: в собранном
  rootfs не должно быть каталогов с правами, закрытыми для `other`
  (кроме явно перечисленных исключений); сверять с предупреждениями
  pacman `directory permissions differ` в логе сборки — их наличие
  должно останавливать сборку.

Пересборка + повторный прогон в QEMU (UEFI и BIOS) — отдельный этап.

## 8. Доказательная база (файлы)

- `experiments/qemu-stage10/logs/uefi-hybrid-diag2-20261110/serial.log`
  (312 442 Б) — UEFI, журнал с `forward_to_console`: все цитаты §2.
- `experiments/qemu-stage10/logs/bios-hybrid-diag-20261110/serial.log`
  (244 823 Б) — BIOS, та же подпись отказа.
- `experiments/qemu-stage10/logs/uefi-hybrid-diag-20261110/serial.log`
  (273 093 Б) — UEFI, первый интерактивный прогон.
- `experiments/qemu-stage10/logs/bios-plain-diag-20261110/serial.log`
  (0 Б) + скриншот `screenshots/diag-20261110-r4-bios-plain.png` —
  «No bootable device.»
- `experiments/qemu-stage10/screenshots/diag-20261110-r3-bios-black.png`,
  `diag-20261110-r1-vt1-now.png` — чёрный экран (проверены визуально).
- `out/pacstrap-build.log` — предупреждения pacman `filesystem: 2770`.
- `profile/airootfs/` — исходные каталоги 2770 на хосте.
- Подробности по этапам: `BOOT-DIAGNOSTICS.md`,
  `LIVE-ROOTFS-REPORT.md`, `GRAPHICS-DIAGNOSTICS.md`.
