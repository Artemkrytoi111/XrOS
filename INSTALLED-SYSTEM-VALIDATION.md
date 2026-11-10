# INSTALLED-SYSTEM-VALIDATION.md — XrOS 1.0 (fixed5)

Дата: 2026-11-11 (UTC). ISO: `xros-1.0-fixed5-x86_64-hybrid.iso`
(SHA256 `d1e57d3ad402c96dfb01acd46c7240b625d74c570b6df0ad6e1905138ae7b251`).
Диск: `experiments/qemu-stage10/disks/fixed-uefi.qcow2` (20 ГБ, UEFI).
Установленная конфигурация: hostname `xros-os`, пользователь `mia` (uid 1000,
пароль `xros1234`), root `xros1234`, AUTOLOGIN=1, TIMEZONE=Europe/Samara,
KEYMAP=ru, DE=kde, OFFICE=none. Установка движком `xros-install`
(non-interactive, erase, ext4) завершена 100% 2026-11-11 ~02:15 UTC.

## 1. Первая загрузка установленной системы (прогон fixed5-uefi-grub2)

| Проверка | Результат |
|---|---|
| GRUB установленной системы (меню) | PASS — меню с темой XrOS, пункты не обрезаны |
| GRUB footer `@TIMEOUT@` | **FAIL** — в футере литерал «Автозагрузка через @TIMEOUT@ с»; исправление fixed5 (единственный `id="__timeout__"` на label) НЕ сработало для установленной системы. Таймаут 10 с при этом срабатывает, первый пункт грузится. |
| Загрузка ядра + initramfs | PASS |
| SDDM запуск | PASS — `Started Simple Desktop Display Manager` 22:15:31, без цикла перезапусков (в журнале 1 запуск) |
| Автовход mia | PASS — `Authentication for user "mia" successful`, `session opened for user mia(uid=1000)`, `Session started true` 22:15:44 |
| Сессия Plasma Wayland | PASS (старт) — `startplasma-wayland` запущен, `kwin_wayland` выбрал DRM-бэкенд, выход `Virtual-1` 1280×800 обнаружен и настроен (`kwinoutputconfig.json`: enabled=true) |
| Рабочий стол (обои, панель) | **FAIL** — чёрный экран; виден только курсор мыши (~4 мин), затем полностью чёрный экран (~9 мин). Дисплей не пробуждается. |
| `system_powerdown` (ACPI) | FAIL — ВМ не выключилась за 30 с (138% CPU). Принудительный `quit`. |

## 2. Форензика установленной системы (диск смонтирован через qcow2→raw→debugfs)

Метод: `qemu-img convert` → raw (20 ГБ) → `dd skip=513` (корень, XROS-ROOT,
сектор 1050624) → `e2fsck -y` (починка копии после некорректного выключения:
счётчики free blocks/inodes + orphan inode 12) → `debugfs` + `journalctl --file`.
Оригинальный qcow2 НЕ менялся (чинились только копии).

### 2.1 Права доступа — PASS (исправление 2770 работает и в установленной системе)

| Путь | Режим | Вердикт |
|---|---|---|
| `/usr` | 2755 (`drwxr-sr-x`) | PASS (≡0755) |
| `/etc` | 2755 (`drwxr-sr-x`) | PASS (≡0755) |
| `/` | 0555 | PASS |
| `/root` | 2750 (≡0750) | PASS |
| `/home` | 0755 | PASS |
| `/home/mia` | 0700, uid:gid 1000:1000 | PASS |
| `/tmp` | 1777 | PASS |
| `/boot`, `/var`, `/run` | 0755 | PASS |
| `/usr/share/xros/wallpaper.png` | 0644 | PASS |

**0 каталогов 2770, 0 файлов 660/777 в проверенных местах.** Установщик
(`rsync -aAX`) корректно перенёс исправленные права из живой системы.
Первопричина чёрного экрана (2770) в установленной системе НЕ воспроизводится.

### 2.2 SDDM / сессия — PASS (по журналу)

- `/etc/sddm.conf.d/autologin.conf`: `[Autologin] User=mia Session=plasma` — корректно.
- SDDM: X-сервер на VT2, сессия plasma на VT1, автовход успешен.
- В системном журнале 0 ошибок уровня err, кроме нерелевантного
  `virt/tdx: TDX not supported by the host platform`.
- SDDM НЕ перезапускается в цикле (1 запуск; ср. 91 цикл в старом ISO).

### 2.3 Причина чёрного экрана — plasmashell aborted (гонка старта)

Из `user-1000.journal`:

```
22:16:58 plasmashell[432]: Aborting shell load: The activity manager daemon
           (kactivitymanagerd) is not running.
22:16:58 plasmashell[432]: If this Plasma has been installed into a custom
           prefix, verify that its D-Bus services dir is known to the system
           for the daemon to be activatable.
22:17:26 kactivitymanagerd[487]: Failed to register with host portal
           QDBusError("org.freedesktop.DBus.Error.NoReply", ...)
```

- plasmashell[432] стартовал в 22:16:58, не нашёл запущенный
  `kactivitymanagerd` и **прервал загрузку оболочки** (но процесс остался жив —
  тот же PID 432 виден в 22:23:48). Поэтому нет ни обоев, ни панели, ни меню —
  только курсор от KWin.
- `kactivitymanagerd` реально стартовал только в 22:17:26 — ПОСЛЕ того, как
  plasmashell уже сдался. Plasmashell не делает повторной попытки.
- Сопутствующие симптомы (вероятно, следствие медленного TCG):
  `linux_dmabuf_feedback.main_device: Failed to fetch DRM device` (22:16:56),
  `MESA-EGL: failed to create dri2 screen` (22:17:04/22:21:33),
  `kwin_wayland: Atomic commit failed: EACCESS` (22:23:47),
  `There are no outputs - creating placeholder screen` — ВПЕРВЫЕ только
  в 22:23:47 (через 8 мин после старта сессии), для plasmashell, kded,
  polkit-агента, портала и др. До этого KWin выход ВИДЕЛ
  (`kwinoutputconfig.json`: Virtual-1, 1280×800, enabled).
- `kscreenlocker_greet` в 22:23:58 тоже «no outputs» — экран блокировки
  попытался показаться.
- DRM в ядре исправен: `bochs-drm` зарегистрирован (22:13:50), `simpledrm` fb0;
  пользователь `mia` в группе `video` (983).

**Вердикт по причине:** гонка порядка запуска Plasma под медленным TCG
(kactivitymanagerd опаздывает, plasmashell сдаётся без ретрая). В живой
системе (тот же ISO, тот же QEMU) plasmashell загружается — значит, дефект
зависит от тайминга, а не систематический отказ пакетов. Требует повторной
проверки (вторая загрузка установленной системы — прогон fixed5-uefi-inst3).

### 2.4 Найденные дефекты установленной системы

1. **Автоблокировка для установленного пользователя — НЕ дефект (by design).**
   `customize_airootfs.sh:94-100` явно: kscreenlockerrc (`Autolock=false`)
   создаётся ТОЛЬКО для `/home/xros/` (live-пользователь с заблокированным
   паролем), а «в установленной системе блокировка остаётся штатной».
   У `mia` есть пароль (`xros1234`), она может разблокировать экран.
   То, что экран блокировки в этом прогоне не отобразился («no outputs»),
   — следствие аварии plasmashell/дисплея (§2.3), а не автоблокировки.
   В `/etc/skel` kscreenlockerrc НЕ добавляется (намеренно).
2. **GRUB: нет fallback `\EFI\BOOT\BOOTX64.EFI` (FAIL, надёжность).**
   На EFI-разделе только `\EFI\XROS\GRUBX64.EFI` (167 936 Б). При свежем
   NVRAM (без записи Boot0002) UEFI не находит загрузчик и уходит в PXE
   (`BdsDxe: failed to load Boot0002 ... Not Found`, проверено прогоном
   fixed5-uefi-inst2). Загрузка возможна только при сохранённом NVRAM
   (старые `ovmf_vars.fd` из прогона установки) — так загружена inst3.
   **Исправление:** в движке установки добавлять fallback
   (`grub-install --removable` или копия `grubx64.efi` → `BOOTX64.EFI`).
3. **GRUB footer `@TIMEOUT@` — литерал (FAIL, косметика, см. §1).**
   Исправление fixed5 не сработало для установленной системы. Нужна отдельная
   проверка темы GRUB установленной системы (возможно, тема копируется
   движком из другого места, чем исправленный `theme.txt`).
4. **D-Bus portal `NoReply`** для `kactivitymanagerd`, `xembedsniproxy`,
   `gmenudbusmenuproxy`, `polkit-kde-authentication-agent-1`, `kaccess`,
   `org_kde_powerdevil` (22:17:26–22:17:44) — вероятно, таймауты D-Bus
   из-за медленного TCG. Не подтверждено как системный дефект.

## 3. Повторная загрузка (прогон fixed5-uefi-inst3, в процессе)

- Запуск: QEMU вручную (без ISO), `-boot c`, старые `ovmf_vars.fd`
  (из fixed5-uefi-grub2, с записью Boot0002), std VGA.
- 22:3x UTC: `Загружается «XrOS Linux»`, `Loading Linux linux ...`,
  `Loading initial ramdisk ...` — GRUB + ядро грузятся. (скриншот
  `fixed5-uefi-inst3-inst3-boot1.png`)
- Ожидание рабочего стола — результат будет дописан после проверки.

## 4. Итог по установленной системе (промежуточный)

| Критерий | Статус |
|---|---|
| UEFI installation (100%) | PASS |
| Installed first boot (GRUB+ядро) | PASS |
| Installed /usr и /etc (2755) | PASS |
| SDDM + автовход | PASS |
| Installed KDE session (рабочий стол) | **FAIL (1-я загрузка)** — plasmashell aborted (гонка); повторная загрузка в процессе |
| GRUB fallback BOOTX64.EFI | FAIL (отсутствует) |
| GRUB @TIMEOUT@ | FAIL (литерал) |
| Автоблокировка для установленного пользователя | OK (by design — штатная, у mia есть пароль) |

Файлы: журнал `inst-check/system.journal`, `inst-check/user-1000.journal`
(извлечены из установленной системы),
`~/workspace/xros-backups/installed-root.ext4` (копия корня, починена e2fsck),
`~/workspace/xros-backups/installed-uefi.raw`, `installed-efi.img`.
