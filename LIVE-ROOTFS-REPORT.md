# XrOS — отчёт по Live rootfs и initramfs

**Дата:** 2026-11-10. **ISO:** `out/xros-1.0-x86_64-hybrid.iso`
(SHA256 `0e664a48b9cb64a9c043dec2b8f13e620c8caddcceb5c29979760ce15e00f90c`).

## 1. Вердикт

Live-носитель обнаруживается, метка/UUID находятся, squashfs
монтируется, корень переключается, systemd запускается.
**С rootfs как механизмом загрузки всё в порядке.** Аварийного
завершения initramfs нет. Дефект — в **содержимом** rootfs: права
доступа каталогов (см. §5), из-за которых не выполняется ни один
non-root процесс.

## 2. Обнаружение Live-носителя и монтирование (факты из журналов)

Из `logs/uefi-hybrid-diag-20261110/serial.log` (R1) и
`logs/bios-hybrid-diag-20261110/serial.log` (R3) — одинаково:

```
:: running early hook [udev]
:: running early hook [archiso_pxe_nbd]
:: running hook [udev]
:: Triggering uevents...
:: running hook [archiso]
:: running hook [archiso_loop_mnt]
:: running hook [archiso_pxe_common]
:: running hook [archiso_pxe_nbd]
:: running hook [archiso_pxe_http]
:: running hook [archiso_pxe_nfs]
Waiting 10 seconds for device /dev/disk/by-uuid/2026-11-10-10-37-25-00 ...
:: Searching for '/boot/2026-11-10-10-37-25-00.uuid' in '/dev/sr0'
:: Mounting '/dev/sr0' to '/run/archiso/bootmnt'
:: Device '/dev/sr0' mounted successfully.
:: Mounting /run/archiso/cowspace (tmpfs) filesystem, size=256M...
:: Mounting '/dev/loop0' to '/run/archiso/airootfs'
:: Device '/dev/loop0' mounted successfully.
:: running late hook [archiso_pxe_common]
:: running cleanup hook [udev]
```

Ядро (R1, `loglevel=7`):

```
[   34.79] loop0: detected capacity change from 0 to 3030384
[   35.71] squashfs: version 4.0 (2009/01/31) Phillip Lougher
[   36.38] overlayfs: "xino" feature enabled using 2 upper inode bits.
```

Далее: `Welcome to XrOS 1.0!`, systemd 262.2 как PID 1,
`Reached target Graphical Interface`.

### Метка и UUID

- Метка тома обоих ISO: `XROS_202611` (PVD, `xorriso -pvd_info`).
- UUID тома исходного ISO: `2026-11-10-10-37-25-00`
  (creation `2026111010372500`); гибрида: `2026-11-10-10-49-03-00`
  (creation `2026111010490300` — xorriso переписал штамп при
  постобработке).
- В `grub.cfg` обоих ISO: `archisosearchuuid=2026-11-10-10-37-25-00`.
- Файл-маркер `/boot/2026-11-10-10-37-25-00.uuid` (0 байт) есть в
  обоих ISO. Хук archiso ищет именно этот файл на устройстве, а не
  сверяет UUID тома напрямую — поэтому расхождение штампов **не мешает
  загрузке**: `/dev/sr0` находится и монтируется во всех прогонах.
  Несовпадение задокументировано как риск для будущих сборок, но
  причиной чёрного экрана не является.

## 3. Структура ISO и Live rootfs

`xorriso -osirrox` (гибрид, 66 узлов):

```
/EFI/BOOT/BOOTx64.EFI, /EFI/BOOT/BOOTIA32.EFI
/boot/grub/grub.cfg, /boot/grub/loopback.cfg, /boot/grub/i386-pc/eltorito.img
/boot/grub/theme/*, /boot/grub/grub-bg.jpg
/boot/2026-11-10-10-37-25-00.uuid
/xros/boot/x86_64/vmlinuz-linux (17 248 768 Б)
/xros/boot/x86_64/initramfs-linux.img (226 541 273 Б)
/xros/boot/intel-ucode.img, /xros/boot/amd-ucode.img
/xros/x86_64/airootfs.sfs (1 551 553 582 Б, squashfs 4.0, zstd, блок 1M)
/xros/x86_64/airootfs.sha512
/xros/pkglist.x86_64.txt (645 пакетов), /xros/version (1.0)
```

Идентичность между исходным и гибридным ISO (SHA256):
ядро `3133feb3561a13a58b8a585aedca7637823100237c2c0bc819484ef4f4b3064a`,
initramfs `289820ad168f7038ef8cd403e7a77eeb2166fe4f71c576246a54a472180c4eff`,
sfs `b0b32f14bd4d5187c254fef87f66add8683a8331bf724241eca89384a84f170a`.

## 4. Initramfs и ядро

- Ядро: `7.2.15-arch1-1` (bzImage, SMP PREEMPT_DYNAMIC, 03 Nov 2026).
  Initramfs соответствует этому ядру
  (`usr/lib/modules/7.2.15-arch1-1/` внутри initramfs).
- Initramfs распакован (`cpio -idmv`, 208 МБ) в
  `experiments/qemu-stage10/scratch/initramfs-x/`; это несжатый cpio
  (+ `early_cpio` с микрокодом).
- Конфигурация (`profile/airootfs/etc/mkinitcpio.conf.d/archiso.conf`):
  `HOOKS=(base udev archiso archiso_loop_mnt archiso_pxe_common
  archiso_pxe_nbd archiso_pxe_http archiso_pxe_nfs archiso_kms block
  filesystems keyboard)`, `COMPRESSION="zstd"`,
  `COMPRESSION_OPTIONS=(-19)`. Все хуки `archiso*` есть в пакете
  `mkinitcpio-archiso 73-1`. Хук `archiso_kms` добавляет все модули
  из `/drivers/gpu/drm/` (`add_checked_modules`).
- Модули в initramfs (проверено распаковкой): `loop.ko`,
  `squashfs.ko`, `overlay.ko`, `virtio-gpu.ko`,
  `bochs.ko` (`drivers/gpu/drm/tiny/bochs.ko.zst`),
  `qxl.ko`, `vboxvideo.ko`, `vmwgfx.ko`, `hyperv_drm.ko`.
- Модули в живой системе
  (`work/x86_64/airootfs/usr/lib/modules/7.2.15-arch1-1/`): тот же
  набор + полный DRM (`amdgpu`, `i915`, `nouveau`, `radeon`, `xe`,
  `vkms`, …). Несоответствия initramfs установленному ядру нет.
- Загрузчик использует правильное ядро и initramfs: пути в grub.cfg
  (`/xros/boot/x86_64/vmlinuz-linux`,
  `/xros/boot/x86_64/initramfs-linux.img`) совпадают с файлами на ISO;
  в прямых прогонах использованы те же файлы, извлечённые из ISO.
- Ошибок ранней загрузки нет: хуки выполняются по порядку, устройства
  находятся, монтирование проходит с первой попытки (задержка только
  штатные 10 с ожидания UUID).

## 5. Дефект прав доступа (первопричина чёрного экрана)

### 5.1. Факты

В живой системе (источник squashfs — `work/x86_64/airootfs/`,
подтверждено независимой распаковкой из `airootfs.sfs`):

```
drwxrws--- 1 root root  /usr
drwxrws--- 1 root root  /etc
drwxrws--- 1 root root  /usr/share
```

Полный список каталогов с mode 2770 (34 штуки):

```
/etc, /etc/mkinitcpio.conf.d, /etc/pacman.d, /etc/pacman.d/hooks,
/etc/skel, /etc/skel/.config, /etc/ssh, /etc/ssh/sshd_config.d,
/etc/systemd, /etc/systemd/journald.conf.d, /etc/systemd/logind.conf.d,
/etc/systemd/network, /etc/systemd/resolved.conf.d, /etc/systemd/system,
/etc/xdg, /etc/xdg/autostart,
/home/xros, /home/xros/.config, /home/xros/.config/autostart,
/home/xros/.config/plasma, /home/xros/Desktop,
/usr, /usr/local, /usr/local/bin, /usr/local/bin/__pycache__,
/usr/share, /usr/share/applications, /usr/share/xros,
/usr/share/xros/grub-theme, /usr/share/xros/repo,
/usr/share/xros/repo/xros, /usr/share/xros/repo/xros/os,
/usr/share/xros/repo/xros/os/x86_64,
/var/cache/pacman
```

Ключевые: `/usr` и `/etc` — 2770 `root:root` (нет прав для `other`
вообще). Сами файлы внутри — нормальные 755; блокирует именно
родительский каталог. Для сравнения: в build-env
(`build-env/root.x86_64/`) `/usr` и `/etc` — 755; корень live-rootfs
`/` — 555 (`dr-xr-xr-x`); `/usr/bin`, `/usr/lib` — 755 (их создал
pacman из метаданных пакетов); `/root` — 750 (штатно);
`/etc/shadow` — 0400 (штатно, `file_permissions`).

### 5.2. Откуда взялось 2770

- Хост: `~/workspace` и всё дерево — `drwxrws---` (setgid 2770,
  группа `nogroup`); `umask` текущей оболочки — **0007**.
- Все каталоги `profile/airootfs/` на хосте — 2770
  (проверено: `profile/airootfs`, `etc`, `usr`, `usr/share`,
  `usr/local`, `etc/systemd`, …).
- `scripts/build-rootfs-pacstrap.sh`, шаг 4:
  `cp -af --no-preserve=ownership,mode -- /xros/profile/airootfs/.
  /xros/work/x86_64/airootfs/`. GNU cp без `-p` создаёт каталоги с
  режимом «режим источника, очищенный umask»: `2770 & ~0007 = 2770`.
- `pacman` заметил и предупредил, но не исправил
  (`out/pacstrap-build.log`):
  ```
  warning: directory permissions differ on /xros/work/x86_64/airootfs/usr/
  filesystem: 2770  package: 755
  ```
  (повторяется для `/usr/`, `/usr/share/`, `/etc/` при установке
  первых пакетов).
- `scripts/build.sh` (~строки 241–246) прямо документирует условие
  хоста: «user namespace + btrfs + setgid-родители 2770».

### 5.3. Почему это ломает именно non-root

Проверка по юнитам (unit-файлы в rootfs):

| Служба/процесс | Пользователь | Результат в журнале |
|---|---|---|
| `systemd-resolved` | `systemd-resolve` (974) | `Failed to execute ... Permission denied`, `status=203/EXEC` |
| `systemd-networkd` | `systemd-network` (977) | то же |
| `systemd-timesyncd` | `systemd-timesync` (973) | то же |
| `dbus-broker` (дочерний) | `dbus` (81), `<user>dbus</user>` в `system.conf` | `launcher_run_child ... Permission denied` |
| `sddm-greeter-qt6` | `sddm` (965) | сессия закрывается через ~0,1 с |
| `startplasma-wayland` | `xros` (1000) | `sddm-helper exited with 2`, сессия 0,23 с |
| `systemd --user` (user@.service) | соответствующий uid | `Failed to start user service ... Transport endpoint is not connected` |
| `systemd-logind`, `systemd-journald`, `sddm`, `udev` | root | работают нормально |
| `systemd-homed` | root | стартует, падает позже: `Event loop failed: Connection reset by peer` (шина мертва) |

## 6. Прочее по конфигурации systemd

- `default.target` → `graphical.target`; SDDM включён как
  `display-manager.service`; NetworkManager, ufw включены.
- `systemd-networkd/resolved/timesyncd` включены пресетом
  `90-systemd.preset` (штатно для Arch) — их падение не связано с
  конфликтом с NetworkManager: причина падения — 203/EXEC, а не
  конфликт за интерфейс.
- `/etc/systemd/network/` пуст (только примеры в
  `/usr/lib/systemd/network/`).

## 7. Выводы по этапу C/D

- [x] Live-носитель обнаруживается — ДА.
- [x] Метка/UUID совпадают с ожидаемыми — ДА (с оговоркой про штамп
      времени тома гибрида, не влияющей на загрузку).
- [x] squashfs находится и монтируется — ДА.
- [x] Корневой каталог существует, switch_root проходит — ДА.
- [x] systemd запускается — ДА, до `graphical.target`.
- [x] Аварийного завершения initramfs — НЕТ.
- [x] Initramfs соответствует ядру, модули на месте — ДА.
- [ ] Этап НЕ заблокирован: причина найдена на уровне прав доступа
      внутри rootfs, а не на уровне монтирования.
