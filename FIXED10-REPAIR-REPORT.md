# FIXED10-REPAIR-REPORT — XrOS 1.0, комплексное исправление fixed9

- **Дата:** 11 ноября 2026
- **Сборка:** fixed10, третья сборка (build3, запущена 17:01, в работе; содержит исправления Diamond: лаунчер 755, список раскладок, фильтр флоппи)
- **Вторая сборка fixed10 (build2):** 11.11.2026 ~15:30–15:41, plain sha256 `9766a9c490df0aad59dfba60fcc9bdc6a65f81fbfc21c53a651c2768e0b81b84`, hybrid (с memtest) sha256 `6922c4df723913def9f4f59911284b24d7bc2d5eb3cc23489188989a1ce705ee` (сохранены в `~/workspace/xros-backups/xros-20261111-fixed10-build2-final/`)
- **Первая сборка fixed10 (build1):** 11.11.2026 ~14:58–15:09, plain sha256 `4049e274de2d2b6bae7906a563635d449f43acf46e8441f536df337271b177df`, hybrid sha256 `5c2fabffcb7c562d85965693aaa3d34860b0ae1c945781172bc6fe6dd05e88b4` (сохранены в `~/workspace/xros-backups/xros-20261111-fixed10-build1/`)
- **Среда:** хост-песочница, сборка `scripts/build.sh --confirm`, тесты — только QEMU на виртуальных дисках
- **Основание:** `FIXED10-AUDIT.md` (таблица 12 дефектов D1–D12), `KDE-PLASMA-VALIDATION.md`, `FINAL-SECURITY-REPORT.md`, `XROS-1.0-FINAL-STATUS.md` (13/16 PASS по fixed9)
- **Статус документа:** ЧЕРНОВИК — разделы проверки QEMU заполняются после сборки build2 и тестов; ничего не помечено PASS без фактической проверки

## 1. Что исправлено (в исходниках)

| Дефект | Причина (доказана) | Исправление | Проверка |
|---|---|---|---|
| D6 — /usr, /etc = 2755 в установленной системе | Профиль на хосте имел каталоги 2755 (setgid-наследование); все нормализации целились в точные режимы 2770/660/770/640; чекер явно принимал 2755 | `build-rootfs-pacstrap.sh` шаг 4а: снятие ВСЕХ спецбитов после копии профиля; шаг 11б: явные /, /usr, /etc = 0755 + снятие setgid с публичных путей; `check-rootfs-perms.sh`: точно 755, запрет setgid-каталогов в usr/etc/home/opt/srv; регрессионный тест 10/10 (новые тесты 5б/5в ловят 2755) | В ISO build1 проверено unsquashfs: /usr, /etc = 755; setgid — только 3 легитимных каталога Arch (`var/lib/libuuid`, `var/lib/tpm2-tss/system/keystore`, `var/log/journal`) |
| D7 — / = 555 | В build1 корень squashfs остался 555 (механизм появления — на стороне mkarchiso; источник точно не установлен, см. §3) | Движок: `chmod 755 "$TARGET"` после rsync (`src/xros-install`); живая система: `chmod 755 /` в конце `customize_airootfs.sh` (выполняется в chroot до упаковки squashfs). Только корень, без рекурсии | **PASS в ISO build2** (unsquashfs: / = 755). В РАБОТАЮЩЕЙ Live-системе / остаётся 555 — это режим overlay-монтирования archiso, а не squashfs (проверено в BIOS Live 16:29–16:33); для Live косметика, для установленной системы гарантия — движок. Проверка в установленной системе + после 2 перезагрузок — впереди |
| D1 — kactivitymanagerd падает при старте («no Qt platform plugin», core dump) | Сервис стартовал до появления сокета Wayland (нет `After=`) | Новый дроп-ин `profile/airootfs/etc/systemd/user/plasma-kactivitymanagerd.service.d/10-after-kwin.conf`: `After=plasma-kwin_wayland.service`. Второго механизма запуска не создано | NOT TESTED — 5 запусков сессии, проверка core dump и `systemctl --failed` |
| D4 — обои XrOS не применяются для нового пользователя | `xros-set-wallpaper` запускался только из автозапуска Live-пользователя xros | Движок: после `useradd` ставит тот же `.desktop` в `~/.config/autostart` нового пользователя | NOT TESTED — проверка на НОВОМ тестовом пользователе (не только mia) + фон экрана блокировки отдельно |
| D5 — MOTD установленной системы = текст живой системы | Live-MOTD — статический файл профиля, rsync его копировал, движок не заменял | Движок: перезапись `$TARGET/etc/motd` текстом установленной системы после rsync | NOT TESTED — проверка после установки |
| D12 — в установленной системе нет синхронизированных БД pacman | Движок не выполнял `pacman -Sy` в целевой системе на пути KDE | Движок: `arch-chroot "$TARGET" pacman -Sy --noconfirm` в конце установки, ДО удаления resolv.conf; при ошибке сети — предупреждение, установка не падает. Полного обновления (`-Syu`) нет — без отдельного разрешения | NOT TESTED — проверка после установки |
| D9 — нет `hostname` и `which` | Ничего в системе их не вызывает (проверено grep) | Добавлен ТОЛЬКО `which` (~20 КБ, де-факто стандарт). inetutils/`hostname` сознательно НЕ ставится | Проверка: `which` есть в ISO build2 (пакет 49-й в списке) |
| D11 — пароль root = пароль пользователя | Поведение движка по умолчанию (ROOTPASS=USERPASS) | Diamond: необязательное отдельное поле пароля root (`User.qml`, `separateRoot`, по умолчанию выключено — поведение fixed9 сохранено). Финальный выбор варианта — за Мией | NOT TESTED — проверка в Diamond (поле root, установка с отдельным паролем) |
| D8 — splash screen падает при загрузке | Ведущая гипотеза: таймаут 40 с истекает под медленным TCG | Причина окончательно не установлена; проверка по журналу в QEMU (см. §5) | NOT TESTED |
| D2 — чёрный экран после разблокировки (2 из 4 загрузок fixed9) | Причина НЕ установлена (сессия жива, plasmashell+kwin работают) | Исправления нет — только план проверки: 5 циклов блокировка→разблокировка с замером времени восстановления картинки | NOT TESTED |
| D3 — ACPI-выключение не работает (Live 75 с, установленная 60 с, fixed5 30 с) | Причина НЕ установлена | Исправления нет — только план проверки: 3 способа (KDE / systemctl / QMP) в Live и установленной системе | NOT TESTED |
| D10 — нет GPG-подписи репозитория (TrustAll) | Подпись не была настроена | См. §4: ключ сгенерирован 15:30, публичный ключ опубликован; подписание пакетов — следующий шаг (тест в локальном тестовом репо) | Тест подписи — после сборки (см. §4) |

## 2. Дополнительно: меню BIOS в стиле EndeavourOS (запрос Мии 15:20, скриншот)

Сделано по скриншоту меню EndeavourOS (BIOS):

- **Новые пункты (только BIOS, на UEFI меню не меняется):**
  - `XrOS 1.0 Fallback (nomodeset)` — то же ядро + `nomodeset`
  - `Boot existing OS` — `exit` (возврат в BIOS, загрузка с диска по порядку)
  - `Run Memtest86+ (RAM test)` — пакет `memtest86+` добавлен в `profile/packages.x86_64` (49 пакетов); mkarchiso сам кладёт файл на ISO как `/boot/memtest86+/memtest`; модуль `linux16` добавлен в `BIOS_MODS` постобработки; пункт защищён стражем `search --file --set=_memtest` (требование диагностики §7ж)
- **Тема:** меню 25%/55% (7 пунктов BIOS на низком разрешении), подсказка клавиш `E — изменить параметры • ↑↓ — выбор • Enter — загрузить` (в GRUB редактирование — клавиша E, а не Tab, как в syslinux EndeavourOS); обратный отсчёт `Автозагрузка через %d с` сохранён
- **Зеркально в `loopback.cfg`** (наборы `--id` совпадают — требование диагностики)
- **Честно не сделано:**
  - Пункта NVIDIA нет — проприетарного драйвера NVIDIA в XrOS нет, пункт был бы фикцией
  - HDT нет — это модуль другого загрузчика, в GRUB его не существует
  - Описания выбранного пункта под меню (как в EndeavourOS) нет — gfxmenu GRUB не поддерживает панель описания пункта
- **Проверка:** NOT TESTED — скриншот меню BIOS в QEMU после сборки build2

## 3. Разбор: откуда взялся / = 555 и что с этим сделано

- В ISO build1 (проверено unsquashfs `work/iso/xros/x86_64/airootfs.sfs`): `/usr` = 755, `/etc` = 755, `/` = 555. Профиль на хосте (`profile/airootfs`) = 755.
- Исключено: mksquashfs (сохраняет режим корня источника — проверено тестом, 755 → 755); `cp -af --no-preserve=ownership,mode` (под umask 0007 даёт 770, под 0022 — 755, никогда 555 только на корне); `profiledef.sh file_permissions` (записи для `/` нет).
- Точный источник 555 в потоке mkarchiso не установлен. Защита сделана на двух уровнях (движок + customize), поэтому установленная система получит / = 0755 независимо от режима корня живой системы. Если в build2 корень ISO снова окажется 555 — это будет зафиксировано как NOT FIXED на уровне живой системы с отдельным разбором.

## 4. GPG (Этап 5)

- **Ключ сгенерирован 11.11.2026 в 15:30** по отдельному указанию Мии (14:59): Ed25519, только подпись, без срока; отпечаток `0EC935D2A8E31AEC1878BBE5797805A298A55BAA`; uid `XrOS Project (XrOS Security Updates) <xros@xros.example>`.
- **Публичный ключ опубликован** в XrOS-Security-Updates (коммит `726fa27`, файл `xros-public.key` + раздел «Подпись пакетов (GPG)» в README). В README честно отмечено: пакеты пока НЕ подписаны, SigLevel остаётся `Optional TrustAll`.
- **Тест подписи — ПРОЙДЕН ПОЛНОСТЬЮ (11.11.2026 ~16:34, запуск 7 `xros-gpg-test/run-gpg-test.sh`): T1 подписанный пакет — PASS (скачан и проверен с SigLevel = Required), T2 неподписанный пакет — PASS (отклонён), T3 пакет с плохой подписью — PASS (отклонён).** Честно: первый прогон T3 дал FAIL — баг самого теста: порча подписи дописыванием текста ПОСЛЕ строки `-----END PGP SIGNATURE-----` (gpg игнорирует мусор после END, подпись оставалась валидной); исправлено усечением подписи внутри тела armor (`head -c 120`), после чего T3 — PASS. Подписи проверяются end-to-end.
- **xros-update.timer выключен** и остаётся выключенным до включения обязательной проверки подписи в живых конфигах pacman (отдельный шаг, не в build2/build3).
- Пакеты в публичный репозиторий НЕ загружались (запрет ТЗ). `xros-installer 1.0-5` — только в локальном репозитории.

## 5. Диагностика перед сборкой build2 (11.11.2026 ~15:2x)

- **Итог: PASS=244 FAIL=0 SKIP=13, exit 0.**
- По пути было найдено и исправлено 12 FAIL (все — до запуска сборки):
  1. Заголовок Fallback длиннее 30 символов → сокращён до `XrOS 1.0 Fallback (nomodeset)` (29)
  2. `theme.txt` расходился (профиль != airootfs) → синхронизирован
  3. `xros-install` расходился (src != пакет) → застэйджен в `packages/xros-installer/`
  4. Тема GRUB `%d` → закрыто синхронизацией темы
  5. Наборы `--id` grub.cfg/loopback.cfg различались → BIOS-блок зеркально в loopback.cfg
  6. Слово `syslinux` в комментарии grub.cfg → перефразировано (проверка — dumb-grep)
  7. Тесты `test-de-none.sh` / `test-installer-security.sh` падали на рассинхроне движка → закрыто стэйджингом
  8. Репозиторий: 7 файлов пакетов вместо 4 (старые xros-installer 1.0-2/1.0-3/1.0-4) → удалены; БД уже ссылалась на 1.0-5
  9. Снимок репозитория в airootfs != repo/ → синхронизирован (те же 3 файла)
  10. Профиль: 5 каталогов не 755 + 14 файлов не 644/755 (все — Diamond, режимы 2770/660 от umask 0007) → нормализованы в исходниках (755/644, лаунчер 755) и в airootfs; `build.sh` шаги 8/9 защищены явными chmod (снимок репозитория 755; Diamond: каталоги 755, файлы 644)
  11. Счётчик пакетов в диагностике 48 → 49 (memtest86+)
- Бэкапы перед правками: `~/workspace/xros-backups/fixed10-rebuild-20261111/` (grub.cfg, theme.txt, packages.x86_64, postprocess-bios-grub.sh, customize_airootfs.sh, xros-install, xros-diagnose.sh).

## 6. Сборка build2 — ЗАВЕРШЕНА 15:41 (11 мин)

- Запущена ~15:30 (`./scripts/build.sh --confirm`, pid 96276). Шаги 1–11 чистые (диагностика PASS=244, CA, профиль, Rust, стэйджинг, 4 пакета, repo-add, снимок, бинари + Diamond). Шаг 12 (check-iso) — PASS=12 FAIL=0 SKIP=0; шаг 13 (SHA256SUMS) — выполнен.
- **Хост перезагрузился ~15:43 (перезагрузка №5)** — лог `/tmp/build-fixed10r2.log` потерян (/tmp очищен), но `out/SHA256SUMS`, `out/check-iso.log` и `out/mkarchiso.log` сохранились в проекте. Первая проверка pgrep после перезагрузки дала ложное «build running» (pgrep совпал с собственной командной строкой) — сборка на самом деле была завершена.
- ISO build2: plain 1 865 138 176 Б sha256 `9766a9c490df0aad59dfba60fcc9bdc6a65f81fbfc21c53a651c2768e0b81b84`; hybrid (до фикса memtest) 1 865 451 520 Б sha256 `5c2fabffcb7c562d85965693aaa3d34860b0ae1c945781172bc6fe6dd05e88b4`.
- **Дефект memtest (найден 16:08, исправлен 16:13):** в build2 пункт «Run Memtest86+» вёл в никуда — файла `/boot/memtest86+/memtest` на ISO не было, хотя пакет memtest86+ установлен. Причина: mkarchiso 92 копирует memtest.bin в ISO только для bootmode syslinux (строка ~544), а профиль XrOS — uefi.grub. Исправление: новый шаг 3a в `scripts/postprocess-bios-grub.sh` (копирует `work/x86_64/boot/memtest86+/memtest.bin` → дерево ISO как `/boot/memtest86+/memtest` + LICENSE; не фатально при отсутствии исходника). Постобработка перезапущена ТОЛЬКО для hybrid (plain ISO не пересобирался); на новом hybrid подтверждён `/boot/memtest86+/memtest` (209 408 Б) + LICENSE; check-iso повторно PASS=12 FAIL=0 SKIP=0. Новый hybrid: 1 865 689 088 Б sha256 `6922c4df723913def9f4f59911284b24d7bc2d5eb3cc23489188989a1ce705ee` (SHA256SUMS обновлён; исходный hybrid без memtest сохранён в `xros-backups/xros-20261111-fixed10-build2/`).
- Первая сборка build1: BUILD EXIT=1 только из-за шага 12 (на хосте не было xorriso после перезагрузки); повторный check-iso вручную — PASS=12 FAIL=0 SKIP=0. В build2 xorriso уже установлен из кэша apt.

## 7. Проверка (Этап 9) — статус на 16:2x

| Проверка | Статус | Доказательство |
|---|---|---|
| Структура ISO (check-iso) | **PASS** | build2: PASS=12 FAIL=0 SKIP=0 (15:41); повторно после фикса memtest: PASS=12 FAIL=0 SKIP=0 (16:13) |
| Права /, /usr, /etc в ISO build2 | **PASS** | unsquashfs build2: / = 755, /usr = 755, /etc = 755; setgid только 3 легитимных (libuuid, tpm2-tss keystore, journal) |
| BIOS Live: меню (новый вид) | **PASS** | Кадр `fixed10-live-bios-grub1.png` (16:15): 7 пунктов, подсказка клавиш, «Автозагрузка через 0 с», пункта «Настройки UEFI» нет |
| BIOS Live: рабочий стол | **PASS** | Кадры desk1/desk2 (16:22–16:23): панель, часы, окно «Добро пожаловать в XrOS!»; обои XrOS применились с задержкой ~1 мин (кадр konsole1, 16:24) |
| BIOS Live: `systemctl --failed` | **PASS** | 0 loaded units (16:29) |
| BIOS Live: права /usr, /etc | **PASS** | В работающей Live: /usr = 755, /etc = 755 (16:29) |
| BIOS Live: / = 555 | **FAIL (косметика Live)** | В работающей Live / = 555 — режим overlay-монтирования archiso, не squashfs (squashfs = 755). Установленная система защищена движком (`chmod 755 "$TARGET"`) |
| BIOS Live: ACPI poweroff | **FAIL (D3 открыт)** | QMP `system_powerdown`, 75 с — ВМ не выключилась (16:52) |
| BIOS Live: запуск Diamond | **FAIL (дефект найден)** | Лаунчер `/usr/local/bin/xros-installer-diamond` в ISO — 644, не запускается (в `file_permissions` его не было). В госте обошли `chmod 755` для теста. Исправлено в исходниках (см. §8) — войдёт в build3 |
| Diamond: Welcome (экран 1) | **PASS** | Кадр diamond-welcome (16:34): сайдбар, логотип X, карточка издания, выбор языка. Нефатальная ошибка в консоли запуска: `Welcome.qml:85: TypeError` (ComboBox срабатывает до присвоения `installer`) — исправлено guard'ом |
| Diamond: Region (экран 2) | **PASS** | Кадр diamond-region1 (16:39): поиск «Europe/Samara», автоопределение Europe/Astrakhan, живые часы. Диалог отмены — PASS (кнопки работают; Escape диалог не закрывает — примечание) |
| Diamond: Keyboard (экран 3) | **FAIL (дефект найден)** | Список раскладок НЕ виден: голый `Rectangle` в `RowLayout` схлопнулся в ~0px (паттерн Region — `ColumnLayout`-обёртка — работает). Исправлено обёрткой + `minimumWidth: 320` — войдёт в build3 |
| Diamond: Disk (экран 4) | **PASS (отображение)** | Кадр diamond-disk1 (16:47): режимы, ФС ext4, карточка диска. В ВМ без диска показан только `/dev/fd0` 4,0 КБ — мост отфильтровывал только `type != "disk"`; фильтр fd*/<1 ГБ добавлен в `bridge.py` |
| Diamond: экраны 5–8 | NOT TESTED | В BIOS Live без диска не дойти; проверка — в UEFI Live + установке build3 |
| Memtest86+: файл на ISO | **PASS** | `/boot/memtest86+/memtest` (209 408 Б) + LICENSE на hybrid build2 |
| Memtest86+: запуск пункта меню | NOT TESTED | Нужен отдельный BIOS-прогон с выбором пункта |
| UEFI Live: меню + рабочий стол | **PASS (build3, run fixed10b3-uefi2)** | Первый прогон 17:14 завис (чёрный экран, причина не установлена); второй прогон 18:39: рабочий стол + приветствие 18:49 (desk1) |
| Diamond: 8 экранов в Live | ЧАСТИЧНО (1–5 PASS; 6–8 NOT TESTED) | UEFI Live build3: Welcome/Region/Keyboard/Disk/User PASS; Summary/Install/Finish — не пройдены через GUI (D14: клавиатура не доходит до QML) |
| Установка UEFI на виртуальный диск | **В РАБОТЕ (19:21)** | Движок запущен напрямую (D14 — GUI не заполнить); rsync 29% в 19:23 |
| Первая загрузка установленной системы | NOT TESTED | — |
| Права после 2 перезагрузок | NOT TESTED | — |
| SSH/UFW/sudo | NOT TESTED | fixed9 (VM): PASS (см. FINAL-SECURITY-REPORT) |
| Обои/MOTD (новый пользователь) | NOT TESTED | fixed9 (VM): исправлено вручную; тест — пользователь `test` |
| GRUB установленной системы | NOT TESTED | fixed9: «Автозагрузка через 8 с» PASS |
| `systemctl --failed` | **PASS (Live UEFI build3)** | 0 loaded units, 18:54; установленная система — NOT TESTED |
| 5× блокировка/разблокировка (D2) | NOT TESTED | fixed9: 2 из 4 с задержкой перерисовки 1–4 мин |
| 5 запусков сессии без core dump (D1) | ЧАСТИЧНО (Live UEFI: 1 запуск PASS) | 18:43: старт после kwin, core dump нет; нужны ещё 4 запуска на установленной системе |
| Splash (D8) | **FAIL (подтверждён в Live UEFI build3)** | journal: timeout, 39,819 с wall clock; фикс — drop-in TimeoutSec=120s (build4) |
| ACPI: 3 способа выключения (D3) | NOT TESTED (UEFI) | fixed9: FAIL (60–75 с); Live BIOS build2: FAIL (75 с) |
| GPG-тест (T1/T2/T3) | **PASS** | 11.11.2026 ~16:34, запуск 7: T1 PASS, T2 PASS, T3 PASS (первый прогон T3 — FAIL по багу теста, см. §4) |

## 8. Изменения исходного кода (список с путями)

- `scripts/build-rootfs-pacstrap.sh` — шаг 4а (снятие всех спецбитов), шаг 11б (явные /, /usr, /etc = 0755 + снятие setgid)
- `scripts/check-rootfs-perms.sh` — точно 755 для /, /usr, /etc; запрет setgid-каталогов в публичных путях (2755 больше не принимается)
- `scripts/test-perms-regression.sh` — нормализация тестовой копии; новые тесты 5б (2755) и 5в (setgid-каталог)
- `scripts/xros-diagnose.sh` — ожидание пакетов 48 → 49; проверка дроп-ина kactivitymanagerd
- `scripts/build.sh` — шаг 6 (копирование свежих пакетов в repo/); шаг 8 (chmod 755 снимка репозитория); шаг 9 (явные режимы Diamond 755/644)
- `src/xros-install` — MOTD установленной системы (D5); wallpaper в autostart нового пользователя (D4); `pacman -Sy` в конце установки (D12); `chmod 755 "$TARGET"` (D7)
- `src/xros-installer-diamond/qml/screens/User.qml` — необязательное отдельное поле пароля root (D11)
- `src/xros-installer-diamond/` — нормализация режимов исходников (каталоги 755, файлы 644, лаунчер 755)
- `profile/airootfs/root/customize_airootfs.sh` — `chmod 755 /` в конце (D7, живая система)
- `profile/airootfs/etc/systemd/user/plasma-kactivitymanagerd.service.d/10-after-kwin.conf` — новый файл (D1)
- `profile/packages.x86_64` — `which` (D9); `memtest86+` (меню BIOS)
- `profile/grub/grub.cfg` — BIOS-блок в стиле EndeavourOS (Fallback, Boot existing OS, Memtest86+); обновлён комментарий о Memtest/UEFI Shell
- `profile/grub/loopback.cfg` — зеркальный BIOS-блок (с img_dev/img_loop)
- `profile/grub/theme/theme.txt` — меню 25%/55%, item_height 28, подсказка клавиш на 92%
- `scripts/postprocess-bios-grub.sh` — `linux16` в BIOS_MODS (для Memtest86+); шаг 3a (копирование memtest.bin в дерево ISO, 11.11.2026 — дефект build2)
- `packages/xros-installer/PKGBUILD` — pkgrel 5 (Diamond 1.0-5 с полем пароля root); **pkgrel 6 (11.11.2026 ~16:5x — Diamond с исправлениями Keyboard/Welcome/bridge)**
- `xros-gpg-test/run-gpg-test.sh` — новый тестовый скрипт подписи (T1/T2/T3)
- `profile/profiledef.sh` — `["/usr/local/bin/xros-installer-diamond"]="0:0:755"` в `file_permissions` (11.11.2026 ~16:55; без этого лаунчер в ISO — 644 и Diamond не запускается; найдено в BIOS Live build2)
- `src/xros-installer-diamond/qml/screens/Keyboard.qml` — список раскладок обёрнут в `ColumnLayout` (паттерн Region.qml) + `Layout.minimumWidth: 320` (дефект BIOS Live build2: список схлопнулся в 0px)
- `src/xros-installer-diamond/qml/screens/Welcome.qml` — guard `if (installer)` в `onCurrentIndexChanged` (TypeError при создании ComboBox)
- `src/xros-installer-diamond/bridge.py` — `disksJson()`: фильтр `fd*` и устройств < 1 ГБ (в BIOS Live без диска предлагался флоппи `/dev/fd0` 4,0 КБ)
- `scripts/xros-diagnose.sh` — новая проверка: `xros-installer-diamond` есть в `file_permissions` (755)
- `scripts/build.sh` — шаг 6: копирование в repo/ только СВЕЖЕЙ версии пакета (11.11.2026 ~17:00; раньше `cp packages/$pkg/*.pkg.tar.zst` возвращал старые 1.0-2/1.0-3/1.0-4 в репозиторий и диагностика падала «пакетов 7, ожидалось 4»)
- `~/workspace/xros-security-updates/` — `xros-public.key` + раздел GPG в README (коммит 726fa27)
- `src/xros-installer-diamond/main.py` — self-elevation через sudo до импорта PyQt6 (D13, 11.11.2026 ~18:58; приветствие запускало Diamond без sudo, движок требует root)

## 6а. Диагностика перед сборкой build3 (11.11.2026 ~17:00)

- **Итог: PASS=247 FAIL=0 SKIP=11, exit 0** (247 = 244 + проверка дроп-ина kactivitymanagerd + проверка `which`? нет — +2: проверка Diamond в `file_permissions` и обновлённый счётчик пакетов; FAIL=0 — главное).
- По пути было найдено и исправлено 2 FAIL:
  1. Репозиторий: снова 7 файлов пакетов вместо 4 — **причина найдена**: `build.sh` шаг 6 копировал в repo/ ВСЕ версии из `packages/xros-installer/` (makepkg оставляет старые 1.0-2/1.0-3/1.0-4). Исправлено в самом `build.sh` (копирование только свежей версии) + ручная чистка repo/ и packages/.
  2. Профиль: 1 каталог не 755 — `profile/airootfs/usr/share/xros/repo` (770 после ручной синхронизации снимка; в `build.sh` шаг 8 уже был защищён chmod 755, но ручная синхронизация его обошла). Исправлено `chmod 755` + повторная синхронизация снимка (`diff -r` чистый).
- Примечание: при исправлении я один раз ошибочно накатил бэкап `profiledef.sh` поверх исправленного файла (бэкап был сделан ДО фикса) — диагностика это поймала (FAIL «Diamond НЕТ в file_permissions»), фикс применён повторно, диагностика после этого чистая. Записано честно, чтобы не повторить.

## 6б. Сборка build3 — ЗАВЕРШЕНА 17:12 (11.11.2026)

- Запущена `./scripts/build.sh --confirm` (pid 27181) в 17:01, лог `out/build-fixed10b3.log` (в проекте, а не в /tmp). Содержит: все исправления Diamond (лаунчер 755, Keyboard, Welcome, фильтр fd0), xros-installer 1.0-6, всё содержимое build2.
- **check-iso: PASS=12 FAIL=0 SKIP=0.** plain 1 855 164 416 Б, sha256 `60ca1b6ace45f05a350e89869729be4ab26dd07f26bfd1e5709be8ccc31eb43a`; hybrid 1 855 715 328 Б, sha256 `4762ed4f8d7e286c4e7771a426a413dda63da0a4f2270f9e284b46483bdf862e`.
- unsquashfs-проверка ISO build3: **/ = 755 ✓, /usr = 755 ✓, /etc = 755 ✓; лаунчер `/usr/local/bin/xros-installer-diamond` = `-rwxr-xr-x` 755 ✓**; setgid-каталогов ровно 3, все легитимные (var/lib/libuuid, var/lib/tpm2-tss/system/keystore, var/log/journal); wallpaper.png на месте.
- Build2 ISO сохранены до сборки в `~/workspace/xros-backups/xros-20261111-fixed10-build2-final/` (plain + hybrid + SHA256SUMS).

## 6в. Live UEFI build3 — первый прогон завис, второй идёт (11.11.2026 17:14–19:23)

- **Первый прогон `fixed10b3-live-uefi` (17:14): ЗАВИС.** Serial log: меню GRUB + отсчёт + «Booting `XrOS 1.0 (x86_64, UEFI)'», дальше тишина; скриншоты 18:31/18:36 — «Guest has not initialized the display (yet)». **ХОСТ ПЕРЕЗАГРУЗИЛСЯ №6 ~17:44** — убил прогон. ВМ остановлена чисто 18:37, диск не тронут. Причина зависания дисплея НЕ установлена (гипотезы: initramfs ждёт медленный IDE CD-ROM; efifb/bochs-drm не привязался в этой конфигурации UEFI).
- **Второй прогон `fixed10b3-uefi2` (18:39): загрузка НОРМАЛЬНАЯ.** Кадр boot1 (18:40): initramfs, sr0 смонтирован, «Welcome to XrOS 1.0!». Рабочий стол + окно приветствия — 18:49 (desk1). Проверки в живой системе (Konsole, 18:54–18:57): `systemctl --failed` = 0 loaded units **PASS**; `/usr` = 755 ✓, `/etc` = 755 ✓, `/` = 555 (overlay archiso — косметика, как в BIOS); лаунчер Diamond `-rwxr-xr-x` 755 **в живой системе ПОДТВЕРЖДЁН**; `import PyQt6.QtQml` — OK; `which` установлен (D9 — первое «command not found» было артефактом typeq «whitch»).
- **D1 (kactivitymanagerd) в Live UEFI: дефект НЕ воспроизвёлся.** Journal: Starting 18:43:14 → Started 18:43:58 (ПОСЛЕ kwin — дроп-ин работает); `coredumpctl list` — пусто; PID 689 работает непрерывно с 18:43; `systemctl --user show` — ActiveState=active, SubState=running. Наблюдение (не FAIL): один раз `is-active` вернул «inactive» при живом процессе.
- **D8 (splash) в Live UEFI: FAIL ПОДТВЕРЖДЁН.** `journalctl --user -u plasma-ksplash.service`: «Failed with result 'timeout'», «Failed to start Splash screen shown during boot», «Consumed 2.556s CPU time over 39.819s wall clock time» — гипотеза про TimeoutSec=40s подтверждена. Фикс (drop-in TimeoutSec=120s) — в build4.
- **Diamond в Live UEFI (экраны 1–5, 19:00–19:15):** Welcome PASS; Region PASS; **Keyboard PASS — дефект build2 ИСПРАВЛЕН** (все 9 раскладок видны, выбрана Русская); Disk PASS (только `/dev/sda` 20,0 ГБ, fd0 нет, «Далее» неактивна до выбора+подтверждения); **диалог подтверждения PASS** (точное имя диска, список стираемых разделов, предупреждение о потере данных); состояние «Подтверждено ✓» PASS; User PASS по отображению (поля, чекбокс отдельного пароля root D11, индикатор надёжности, «Далее» неактивна без пароля).
- **НОВЫЙ ДЕФЕКТ D14 (клавиатура в Diamond, найден 19:13):** в этом UEFI-прогоне клавиатура НЕ доходит до QML-приложения Diamond — печать в текстовых полях, Tab/Space/Enter полностью игнорируются (проверено: клик в поле + «t», клик + Ctrl+A + Backspace + «test», двойной клик + «test» — поле остаётся пустым, placeholder «mia»). Мышь при этом работает (кнопки, списки, диалоги). Клавиатура в Konsole работает нормально. Причина НЕ установлена; наиболее вероятно — фокус клавиатуры KWin не перешёл к root-окну QML (Diamond запущен через `sudo` из Konsole). В BIOS-прогоне клавиатура в Diamond работала (Tab-навигация) — разница может быть в контексте запуска. **Следствие: экран Пользователя нельзя заполнить через GUI; передача движка с экрана Установка Diamond остаётся NOT TESTED через GUI (только по коду).** Установка запущена движком напрямую (тот же conf, что пишет Diamond) — см. §6г.
- **НОВЫЙ ДЕФЕКТ D13 (Diamond sudo, найден 18:55):** приветствие запускало Diamond без sudo (`Popen([INSTALLER])`), а движок требует root; старый Rust-GUI сам повышал права, Diamond — нет. **ИСПРАВЛЕН в исходниках** (`src/xros-installer-diamond/main.py`: блок self-elevation до импорта PyQt6 — `os.execvp("sudo", ...)` с комментарием на русском) — войдёт в build4. В текущем тесте Diamond запускался вручную `sudo xros-installer-diamond` из Konsole.

## 6г. Установка UEFI build3 — ЗАПУЩЕНА 19:21 (в работе)

- Diamond закрыт (`pkill -f installer-diamond`, процессов не осталось). Конфиг установки записан вручную в `/tmp/xros-install.conf` (0600) — ровно тот, что пишет Diamond: TIMEZONE='Europe/Samara', KEYMAP='ru', PARTMODE='erase', FS='ext4', DISK='/dev/sda', USERNAME='test', FULLNAME='Test User', USERPASS='test1234', ROOTPASS='test1234', HOSTNAME='xros-os', AUTOLOGIN='1', DE='kde', OFFICE='none'. **Пользователь `test` — новый тестовый (по ТЗ: обои проверять на новом пользователе, не только на mia).**
- Движок запущен: `sudo nohup env XROS_NONINTERACTIVE=1 XROS_INSTALL_CONF=/tmp/xros-install.conf /usr/local/bin/xros-install` (PID 1268/1271, лог `/tmp/xros-install.log` root 0600). Прогресс 19:23: GPT создана, mkfs.fat + mke2fs (ext4, UUID fefadf60-…), `/dev/sda2` смонтирована в `/mnt/xros-install`, rsync живой системы **29% (1,55 МБ/с)**. Дальше: первая загрузка + все проверки §7 (права после 2 перезагрузок, обои у `test`, MOTD, D1 5 сессий, D2 5 циклов, D8, ACPI, SSH/UFW/sudo, БД pacman).

## 9. Остающиеся дефекты и следующие шаги

1. ~~Дождаться build2 → check-iso → unsquashfs-проверка прав (включая /)~~ — ГОТОВО: check-iso 12/12, / = 755, memtest исправлен.
2. ~~GPG-тест~~ — ГОТОВО: T1/T2/T3 PASS (16:34).
3. ~~Build3: сборка → check-iso → unsquashfs → UEFI Live~~ — ГОТОВО: check-iso 12/12, / /usr /etc 755, лаунчер 755 в ISO и в живой системе, рабочий стол PASS, Diamond 1–5 PASS (Keyboard исправлен), D1 в Live не воспроизвёлся, D8 подтверждён FAIL.
4. Установка UEFI build3 — **В РАБОТЕ с 19:21** (движок напрямую, D14): дождаться завершения → первая загрузка (diskboot) → все проверки §7 (5× блокировка D2, 5 запусков D1, splash D8, ACPI D3, права после 2 перезагрузок, SSH/UFW/sudo, обои/MOTD у нового пользователя `test`, БД pacman).
5. **build4** (после установки): main.py sudo-фикс (D13) + drop-in plasma-ksplash TimeoutSec=120s (D8) → пересборка → проверка запуска Diamond из окна приветствия (D13 end-to-end) → повторная проверка D14 (клавиатура в QML при запуске из приветствия) — D14 может быть связан с контекстом запуска из Konsole.
6. Запуск пункта Memtest86+ в BIOS QEMU — отдельно.
7. Заполнить остальные 5 отчётов (FIXED10-KDE-VALIDATION, FIXED10-SECURITY-AUDIT, FIXED10-INSTALLER-VALIDATION, FIXED10-BIOS-UEFI-TESTS, XROS-DIAMOND-READINESS) и XROS-DIAMOND-INSTALLER-REPORT.md + запушить в приватный репозиторий.
8. Не решено: точный источник / = 555 в потоке mkarchiso (защита на двух уровнях сделана; в build2/build3 корень ISO уже 755 — вопрос закрыт фактически, источник не установлен); причина чёрного экрана после разблокировки (D2); ACPI (D3); причина зависания дисплея в первом UEFI-прогоне build3; причина D14 (клавиатура в QML); BIOS-установка — за Мией.
9. Замечено в BIOS Live (не дефект, примечание): обои XrOS применились с задержкой ~1 мин после появления рабочего стола (первые кадры — стоковые обои Plasma; кадр через минуту — фиолетовые волны XrOS). Вероятно, гонка autostart под медленным TCG; проверить в UEFI Live.
10. Замечено в BIOS Live (стенд, не дефект XrOS): после запуска Diamond фокус клавиатуры держит его окно — Konsole на переднем плане не выполняет команды по Enter; проверки в консоли делать ДО запуска GUI-приложений. После VT3→VT1 окна Diamond/Konsole не восстановились визуально (не установлено — потеря окон или промах клика).
