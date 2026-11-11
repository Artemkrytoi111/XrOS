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

## 5. fixed6 — исправления и тест Live-системы (2026-11-11 ~23:00 UTC)

Собрана fixed6 (plain `4c7cb6b7c47d996c81d1755045da446a1bfff5540ead1439dada8ae02c6af1dd`,
hybrid `ea2d334e1a2dc979d4c3660e58ff93ba84d6e39ff77e31cf7ee4bfae5380bffd`;
diagnose PASS=239 FAIL=0 SKIP=13; check-iso PASS=10 FAIL=0 SKIP=2;
коммит `02a974d`, запушено в main). Включает 4 фикса:
1. Drop-in `plasma-plasmashell.service.d/10-kactivitymanagerd.conf`
   (`Wants=`+`After=plasma-kactivitymanagerd.service`) — против гонки §2.3.
2. GRUB: обратный отсчёт — `progress_bar` с `id="__timeout__"` и текстом
   `@TIMEOUT@` (label с @TIMEOUT@ удалён; fixed5-label показывал литерал).
3. Движок: fallback `\EFI\BOOT\BOOTX64.EFI` после UEFI grub-install.
4. Движок: журнал создаётся ПОСЛЕ sudo re-exec (был xros-owned 600,
   root не мог дописать — ложный «sgdisk не удался»).

**Тест Live fixed6 (UEFI GRUB, прогон fixed6-uefi-grub, pid 22238):**
- Приветствие «Добро пожаловать в XrOS!» открывается — PASS.
- Konsole (Ctrl+Alt+T) работает — PASS (промпт `[xros@xros-os ~]$`).
- **НО: рабочий стол чёрный — обои, панель, значок «Установить XrOS» НЕ
  отображаются (после Alt+F4 и через 10+ мин). РЕГРЕССИЯ относительно
  fixed5 (там Live-рабочий стол работал).**
- В Konsole: `plasmashell` (pid 727, **4:22 CPU** — busy loop),
  `kactivitymanagerd` (pid 759) — ОБА запущены. `journalctl --user -b |
  grep -i abort` — сообщения «Aborting shell load» НЕТ (только фрагмент
  стека `abort (libc.so.6)`). То есть причина НЕ та же гонка, что в
  установленной системе fixed5.
- `systemctl --user restart plasma-plasmashell` — «Unit
  plasma-plasmashell.service not found» (в Live-сессии plasmashell
  запускается через `startplasma-wayland`, а не через systemd — это может
  быть нормой, а не признаком поломки).
- Drop-in в живой системе ПРИСУТСТВУЕТ
  (`/etc/systemd/user/plasma-plasmashell.service.d/` виден в `ls`).
  Подозрение на drop-in как причину регрессии — НЕ ДОКАЗАНО (Live-сессия
  не использует systemd-юнит plasmashell напрямую).
- GRUB-меню fixed6 поймать не удалось (таймаут 10 с, скриншот поздний);
  проверка progress_bar с числом — НЕ ВЫПОЛНЕНА.
- Установка fixed6 и первая загрузка установленной системы — НЕ ТЕСТИРОВАЛИСЬ.

**Статус fixed6: НЕ ГОТОВА к объявлению исправленной.** Требуется:
откатить/перепроверить drop-in (fixed7) либо установить точную причину
чёрного Live-стола fixed6 (busy loop plasmashell, 4:22 CPU) и только затем
повторить установку и первую загрузку установленной системы.

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

## 4. Первая загрузка установленной системы из fixed9 (UEFI) — 2026-11-11, прогон fixed9-uefi-firstboot
Диск: fixed9-uefi.qcow2 (4 786 946 048 Б, установка из fixed9, завершена
07:15 UTC). Запуск diskboot 07:21:03 UTC (pid 16025).
- GRUB → ядро → initramfs: PASS (кадр fb-grub1: «Загружается „XrOS Linux"»,
  Loading Linux / initramfs). Меню GRUB на кадре не поймано (10-сек.
  таймаут прошёл за 25 с сна до первого кадра) — текст обратного отсчёта
  в установленной системе визуально НЕ подтверждён, проверяется по файлу
  темы ниже.
- Чёрный экран + курсор ~07:24 (3,5 мин) — сессия стартует, не дефект.
- ~07:29: рабочий стол ПОКАЗАН (обои Plasma по умолчанию — см. ниже),
  панели ещё нет. ~07:35 экран чёрный — DPMS/блокировка (см. ниже).
- Экран блокировки: PASS — часы 11:35, «среда, 11 ноября 2026 г.»,
  пользователь Mia, поле «Пароль». Разблокировка xros1234 PASS
  (после очистки поля: первая попытка + вторая сложились в 16 точек —
  рендер отстаёт; Ctrl+A + Backspace, ввод заново, ровно 8 точек).
- Рабочий стол KDE: PASS (кадр fb-desk1, 11:37) — панель снизу
  (Kickoff, задачи, трей, часы 11:37, 11.11.2026), курсор. Впервые
  установленная XrOS показывает рабочий стол с панелью. Дефект
  «чёрный стол» из fixed5 ЗАКРЫТ фиксом гонки (fixed7: drop-in +
  xros-wait-kactivitymanagerd, доставлен в установленную систему через
  rsync из fixed9).
- Konsole: PASS, приглашение [mia@xros-os ~]$.
- whoami = mia; date = Ср 11 ноя 2026 11:38:40 +04;
  timedatectl Timezone=Europe/Samara — PASS.
- hostname (команда) = command not found (бинарь отсутствует в
  минимальной системе; имя хоста xros-os — по приглашению и по
  установщику). Нюанс, не дефект установки.
- /usr = 2755, /etc = 2755 (≡0755 + setgid) — дефект 2770 в
  установленной системе НЕ воспроизводится. PASS.
- plasmashell: PID 698, /usr/bin/plasmashell --no-respawn — PASS.
- Обои установленной системы: FAIL (брендинг) — на рабочем столе
  стоковые обои Plasma (цветная абстракция), НЕ фиолетовые волны XrOS.
  Причина: xros-set-wallpaper — только автостарт Live-пользователя
  xros; для нового пользователя mia ничего обои не применяет.
  Файл /usr/share/xros/wallpaper.png в установленной системе
  НЕ проверен (прогон прерван перезагрузкой хоста).
- НЕ ПРОВЕРЕНО (прогон прерван перезагрузкой хоста 07:44 UTC):
  kactivitymanagerd PID (команда выполнена, вывод не успел
  отрисоваться), journalctl «Aborting», drop-in + wait-скрипт в
  установленной системе, файл темы GRUB (%d) и /etc/default/grub,
  якорь CA песочницы в trust store, ACPI-выключение установленной
  системы, стабильность ≥15 мин.

### 4.1 Перезагрузка хоста №3 — 2026-11-11 ~07:44 UTC
Хост снова перезагрузился (uptime 0 мин в 07:44:33 UTC), убив прогон
fixed9-uefi-firstboot на середине диагностики Konsole. apt-пакеты
QEMU/OVMF/xorriso снова стёрты — переустановить перед продолжением.
Диск fixed9-uefi.qcow2 цел (установка завершена 07:15, QEMU убит
SIGTERM от systemd-shutdown, как в прошлые разы).

### 4.2 Вторая загрузка установленной системы из fixed9 (UEFI) — 2026-11-11, прогон fixed9-uefi-firstboot2
Запуск diskboot 07:47:15 UTC (pid 6348). GRUB-меню установленной
системы — PASS (кадр fb2-grub1): «XrOS 1.0», фон фиолетовые волны,
«XrOS Linux», футер «Автозагрузка через 8 с» с фиолетовой полосой —
шаблон %d работает в установленной системе. Дефект «@TIMEOUT@»
ЗАКРЫТ и в установленной системе (файл + живой кадр).
- Чёрный экран + курсор ~07:52 (5,5 мин) — сессия стартует.
- ~07:56 чёрный экран без курсора — DPMS/блокировка (стол уже
  появился и заблокировался, как в прогоне №1).
- Экран блокировки: PASS (11:57, Mia, поле «Пароль»). Разблокировка
  xros1234 — пароль принят (8 точек, Enter).
- АНОМАЛИЯ после разблокировки: рабочий стол НЕ перерисовался —
  чёрный экран + курсор ≥3 мин (кадры fb2-desk2…fb2-desk5),
  Ctrl+Alt+F2 — тоже чёрный VT, Shift не будит. ВМ 134% CPU.
  НО: сессия жива — Ctrl+Alt+T открыл Konsole ([mia@xros-os ~]$).
  plasmashell PID 666 (/usr/bin/plasmashell --no-respawn) и
  kactivitymanagerd PID 670 (/usr/lib/kactivitymanagerd) — ОБА ЖИВЫ.
  То есть оболочка запущена, но не рисует обои и панель после
  разблокировки. В прогоне №1 (первая загрузка) стол с панелью
  ПОКАЗЫВАЛСЯ — воспроизводимость частичная: 1 из 2 загрузок.
  Причина не установлена (подозрение: kwin/plasmashell после
  блокировки под TCG; журнал: только kwin_wayland «Input method is
  trying to show itself but without a context. Aborting.» 11:56:05 —
  это НЕ «Aborting shell load»).
- journalctl --user -b -g Aborting: «Aborting shell load» НЕТ.
  Гонка fixed5 НЕ воспроизводится. PASS.
- Wait-скрипт: -rwxr-xr-x root root 1843 ноя 11 08:03
  /usr/local/bin/xros-wait-kactivitymanagerd — PASS (доставлен rsync).
- Drop-in: /etc/systemd/user/plasma-plasmashell.service.d/
  10-kactivitymanagerd.conf — PASS.
- Тема GRUB: /usr/share/xros/grub-theme/theme.txt содержит
  text = "Автозагрузка через %d с" — PASS.
- Обои: /usr/share/xros/wallpaper.png есть (1 732 266 Б, 644),
  но для пользователя mia НЕ применены (стол — стоковые обои Plasma).
  Дефект брендинга подтверждён файлом. FAIL.
- CA песочницы: /etc/ca-certificates/trust-source/anchors/ ПУСТ —
  якорь hatch-egress-ca.crt в установленную систему НЕ попал
  (вопреки прежнему предположению «доставит rsync»). Риск для
  установленной системы НЕ подтверждён; CA остаётся только в Live
  ISO (проверить отдельно). См. FINAL-SECURITY-REPORT.md.
- ACPI-выключение установленной системы: в работе (см. §4.3).

### 4.3 ACPI-выключение установленной системы — FAIL
QMP system_powerdown послан 08:11:15 UTC (сессия mia разблокирована,
Konsole открыта). Через 60 с ВМ работает. Тот же результат, что в
Live-системе (07:18 UTC, 75 с, 121% CPU) и в установленной системе
из fixed5 (ночь 10→11 ноября, 30 с, 138% CPU). ACPI powerdown —
FAIL и в Live, и в установленной системе. ВМ остановлена через QMP
quit. Причина не установлена (logind/powerdevil не реагируют на
кнопку питания под QEMU/TCG — отдельный дефект, не блокирует
установку и рабочий стол).
