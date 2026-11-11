# FIXED10-BIOS-UEFI-TESTS — XrOS 1.0, проверка загрузки BIOS + UEFI

- **Дата:** 11 ноября 2026
- **Сборка:** fixed10 build2 (на момент написания — идёт, шаг 10 mkarchiso)
- **ISO:** `out/xros-1.0-x86_64-hybrid.iso` (build2; sha256 — после сборки)
- **Среда:** QEMU (`experiments/qemu-stage10/run-fixed.sh`), только виртуальные диски
- **Статус документа:** ЧЕРНОВИК-ЧЕКЛИСТ — все проверки NOT TESTED до фактического прогона; заполняется по мере тестов

## 1. Структура ISO (check-iso)

| # | Проверка | Статус | Доказательство |
|---|---|---|---|
| 1.1 | `check-iso.sh --archiso` PASS=12 FAIL=0 | **PASS** | build2, 15:41: PASS=12 FAIL=0 SKIP=0; повторно после фикса memtest (16:13): PASS=12 FAIL=0 SKIP=0 |
| 1.2 | BIOS El Torito есть | **PASS** | check-iso + postprocess-лог (BIOS El Torito: ЕСТЬ) |
| 1.3 | UEFI El Torito есть | **PASS** | check-iso (appended_partition_2) |
| 1.4 | Гибридный MBR grub2-mbr | **PASS** | check-iso + postprocess-лог |
| 1.5 | Volume id XROS_202611 | **PASS** | check-iso |
| 1.6 | `/boot/memtest86+/memtest` на ISO есть | **PASS** | Найден и ИСПРАВЛЕН 16:08–16:13: в первом build2 файла НЕ было (mkarchiso 92 копирует memtest.bin только для bootmode syslinux, строка ~544; профиль — uefi.grub). Исправление: шаг 3a в scripts/postprocess-bios-grub.sh; постобработка перезапущена только для hybrid; на ISO подтверждён /boot/memtest86+/memtest (209 408 Б) + LICENSE; check-iso повторно 12/12. Новый hybrid sha256 `6922c4df723913def9f4f59911284b24d7bc2d5eb3cc23489188989a1ce705ee` |
| 1.7 | Права в squashfs: /usr, /etc = 755; / = 755 (см. FIXED10-REPAIR-REPORT §3) | **PASS** | unsquashfs build2: / = drwxr-xr-x 755, /usr = 755, /etc = 755, /boot /home /opt /srv /var = 755, /root = 750, /tmp = 1777 |
| 1.8 | setgid-каталогов в ISO — только легитимные (libuuid, tpm2-tss keystore, journal) | **PASS** | unsquashfs build2: ровно 3 setgid-каталога, все легитимные |

## 2. BIOS Live (меню в стиле EndeavourOS)

Запуск: `XROS_ISO=... ./run-fixed.sh fixed10-live-bios bios grub nodisk`

| # | Проверка | Статус | Доказательство |
|---|---|---|---|
| 2.1 | Меню BIOS загружается (фон, тема XrOS) | **PASS** | кадр `fixed10-live-bios-grub1.png` (16:15): фон — чёрные фиолетовые волны, заголовок «XrOS 1.0», 7 пунктов |
| 2.2 | Пункты меню (7 шт.): по умолчанию, диктор, Fallback (nomodeset), Boot existing OS, Memtest86+, выключение, перезагрузка | **PASS** | тот же кадр: все 7 пунктов видны, заголовки не обрезаны |
| 2.3 | Подсказка клавиш внизу: `E — изменить параметры • ↑↓ — выбор • Enter — загрузить` | **PASS** | тот же кадр, внизу экрана |
| 2.4 | Обратный отсчёт: `Автозагрузка через N с` (%d, не литерал) | **PASS** | тот же кадр: «Автозагрузка через 0 с» |
| 2.5 | Пункта `Настройки UEFI` в BIOS-меню НЕТ | **PASS** | тот же кадр: пункта нет |
| 2.6 | Заголовки пунктов не обрезаются (все ≤ 30 символов) | **PASS** | тот же кадр |
| 2.7 | Загрузка Live-системы из BIOS (рабочий стол, приветствие) | **PASS** | кадры `fixed10-live-bios-desk1/desk2.png` (16:22–16:23): панель, часы 16:23, окно «Добро пожаловать в XrOS!»; обои XrOS (фиолетовые волны) применились с задержкой ~1 мин после загрузки стола (кадр konsole1, 16:24) — см. примечание ниже |
| 2.8 | Memtest86+ запускается (выбор пункта → экран теста памяти) | NOT TESTED | Файл на ISO есть (§1.6); запуск пункта в QEMU — следующим прогоном |
| 2.9 | `Boot existing OS` — пункт есть (загрузка с диска не тестируется: на тестовом диске нет BIOS-системы) | **PASS** | пункт виден в меню (кадр grub1) |
| 2.10 | `systemctl --failed` = 0 загруженных юнитов (Live) | **PASS** | Konsole в Live (кадр `fixed10-live-bios-term2.png`, 16:30): `0 loaded units listed.` |
| 2.11 | Права в Live: /usr, /etc = 755 | **PASS** | тот же кадр: `/usr` 755, `/etc` 755. НО: `/` в Live = **555** (см. 2.12) |
| 2.12 | `/` в Live = 755 | **FAIL** | В работающей Live-системе `stat -c %a /` = 555 (кадр term2), хотя корень squashfs в ISO = 755 (unsquashfs, §1.7) и `chmod 755 /` добавлен в customize_airootfs.sh. Вывод: режим `/` в Live определяет НЕ squashfs, а overlay-монтирование archiso (initramfs). Для Live это косметика (squashfs read-only, root обходит права), для УСТАНОВЛЕННОЙ системы закрыто движком (`chmod 755 "$TARGET"` в src/xros-install) — проверяется в §4.4. |
| 2.13 | ACPI: QMP `system_powerdown` выключает Live-систему (D3) | **FAIL** | 16:52–16:53: `system_powerdown` → через 75 с VM всё ещё `running` (проверено `info status` дважды). Как в fixed9 (Live 75 с). Дефект D3 НЕ исправлен в build2. |
| 2.14 | Консольный вход root/xros в Live | **PASS** (по проекту) | VT3: вход root и xros с пустым паролем — `Login incorrect`. По проекту: пароли root и xros ЗАБЛОКИРОВАНЫ (`passwd -l`, customize_airootfs.sh:19,58); Live работает только через автологин SDDM + passwordless sudo. Это НЕ дефект. |
| 2.15 | Окна GUI после переключения VT3→VT1 | NOT TESTED (наблюдение) | 16:52: после возврата на VT1 рабочий стол есть (обои, панель, часы 16:52), но окна Diamond и Konsole НЕ видны и не восстанавливаются кликом по панели задач (клик, возможно, мимо иконки — точность мыши QEMU ненадёжна). Сессия жива. Требуется отдельная проверка: живы ли процессы окон после VT-переключения, или kwin их потерял. Зафиксировано как наблюдение, не как FAIL. |
| 2.16 | Diamond: экраны 1–4 в Live BIOS | ЧАСТИЧНО | Welcome **PASS** (кадр `diamond-welcome.png`), Region **PASS** (`diamond-region1.png`: автоопределение Astrakhan, список зон, живые часы), Keyboard **FAIL** (см. §2.17), Disk **PASS** (`diamond-disk1.png`: список дисков отрисован, режим «Очистить диск», ФС ext4). Диалог отмены **PASS** (текст и кнопки корректны, закрывается кликом «Продолжить установку»; Escape НЕ закрывает диалог — проверить в исходниках). |
| 2.17 | Diamond: экран Keyboard — список раскладок виден | **FAIL** | Кадры `diamond-kb2/kb3.png` (16:41–16:42): правая колонка («Дополнительные раскладки», «Поле проверки») растянута на всю ширину, список 9 раскладок НЕ виден (схлопнулся в ~0 px; видна только его левая граница). Причина (по коду): список — голый `Rectangle { Layout.fillWidth: true }` напрямую в RowLayout; на экране Region тот же список обёрнут в ColumnLayout с fillWidth — и работает. Исправление: обернуть список Keyboard в ColumnLayout (паттерн Region) + `Layout.minimumWidth`. Также в stderr: `Welcome.qml:85: TypeError: Value is undefined...` (обработчик ComboBox языка срабатывает до присвоения `installer`) — не фатально, но исправить guard'ом. Дополнительно: в списке дисков виден только `/dev/fd0` 4.0 КБ (флоппи; диск не подключён — `nodisk`), ISO-диск /dev/sr0 в списке отсутствует (отфильтрован мостом — правильно). Флоппи как кандидат на установку — фильтровать в `bridge.disksJson()` (минимум: исключить `fd*` и диски < 1 ГБ). |

## 3. UEFI Live (build3)

Прогон 1 `fixed10b3-live-uefi` (17:14, nodisk): **ЗАВИС** — serial log: меню GRUB + отсчёт + «Booting `XrOS 1.0 (x86_64, UEFI)'», дальше тишина; скриншоты 18:31/18:36 — «Guest has not initialized the display (yet)» (26+ мин). Убит хост-перезагрузкой №6 (~17:44). Причина не установлена.

Прогон 2 `fixed10b3-uefi2` (18:39, диск fixed10-uefi.qcow2 подключён): загрузка нормальная (кадр boot1 18:40 — initramfs, sr0 смонтирован, «Welcome to XrOS 1.0!»).

| # | Проверка | Статус | Доказательство |
|---|---|---|---|
| 3.1 | Меню UEFI загружается, пункты прежние (5 шт.): по умолчанию, диктор, настройки UEFI, выключение, перезагрузка | **PASS** | Прогон 1: serial log — меню GRUB + отсчёт; состав меню UEFI не менялся с build1 (BIOS-блок защищён `grub_platform=pc`) |
| 3.2 | Новых BIOS-пунктов (Fallback, Memtest, Boot existing OS) в UEFI-меню НЕТ | **PASS** | То же (guard по платформе; в BIOS-меню build2 эти пункты есть — §2) |
| 3.3 | Обратный отсчёт `%d` работает | **PASS** | Прогон 1 и 2: отсчёт в serial log; build1: «Автозагрузка через 0 с» (кадр fixed10-live-uefi-grub1.png) |
| 3.4 | Рабочий стол KDE + окно «Добро пожаловать в XrOS!» | **PASS** | Прогон 2, кадр desk1 (18:49): рабочий стол + окно приветствия; обои XrOS применились (чёрные волны с фиолетовым неоном) |
| 3.5 | `systemctl --failed` = 0 загруженных юнитов | **PASS** | Konsole 18:54: «0 loaded units listed» |
| 3.6 | kactivitymanagerd: нет core dump при старте (D1) | **PASS (1 запуск)** | Journal: Starting 18:43:14 → Started 18:43:58 (после kwin, дроп-ин работает); `coredumpctl list` — пусто; PID 689 жив с 18:43; ActiveState=active. Наблюдение: один раз `is-active` вернул «inactive» при живом процессе |
| 3.7 | Splash screen: нет `Failed to start Splash screen` (D8) | **FAIL** | `journalctl --user -u plasma-ksplash.service`: «Failed with result 'timeout'», 39,819 с wall clock — гипотеза TimeoutSec=40s ПОДТВЕРЖДЕНА; фикс — drop-in TimeoutSec=120s (build4) |
| 3.8 | ACPI: QMP `system_powerdown` выключает Live-систему (D3) | NOT TESTED | Live BIOS build2: FAIL (75 с); UEFI — не тестировался |

## 4. Установка UEFI (виртуальный диск fixed10-uefi.qcow2, 20G)

| # | Проверка | Статус | Доказательство |
|---|---|---|---|
| 4.1 | Diamond: 8 экранов проходятся (скриншоты — в XROS-DIAMOND-INSTALLER-REPORT.md) | **ЧАСТИЧНО (1–5 PASS)** | UEFI Live build3: Welcome PASS, Region PASS, Keyboard PASS (исправлен), Disk PASS (+диалог подтверждения PASS), User PASS (отображение). Summary/Install/Finish через GUI — NOT TESTED: **D14 — клавиатура не доходит до QML-приложения** (печать/Tab/Enter игнорируются; мышь работает). Установка выполняется движком напрямую (см. 4.2) |
| 4.2 | Установка завершается; экран «XrOS 1.0 Diamond успешно установлена!», чекбокс перезагрузки включён по умолчанию | **В РАБОТЕ** | Движок запущен 19:21 напрямую: `sudo nohup env XROS_NONINTERACTIVE=1 XROS_INSTALL_CONF=/tmp/xros-install.conf /usr/local/bin/xros-install` (PID 1268/1271). Конфиг — как у Diamond: Europe/Samara, ru, erase, ext4, /dev/sda, пользователь `test`/test1234, autologin, xros-os. 19:23: GPT, mkfs.fat + mke2fs, /dev/sda2 → /mnt/xros-install, rsync **29% (1,55 МБ/с)**. Экран Finish Diamond — NOT TESTED (GUI) |
| 4.3 | Первая загрузка установленной системы: рабочий стол, панель, часы | NOT TESTED | кадр |
| 4.4 | Права /, /usr, /etc = 0755 после установки | NOT TESTED | `stat -c %a / /usr /etc` |
| 4.5 | Права /, /usr, /etc = 0755 после 2 перезагрузок | NOT TESTED | то же, после каждой перезагрузки |
| 4.6 | Обои XrOS у НОВОГО тестового пользователя (не mia) | NOT TESTED | `grep Image ~/.config/plasma-org.kde.plasma.desktop-appletsrc` + кадр стола |
| 4.7 | Фон экрана блокировки — отдельно | NOT TESTED | кадр экрана блокировки |
| 4.8 | MOTD установленной системы (текст, не Live) | NOT TESTED | `cat /etc/motd` |
| 4.9 | GRUB установленной системы: «Автозагрузка через N с» | NOT TESTED | кадр меню |
| 4.10 | SSH выключен, UFW включён, sudo требует пароль, NOPASSWD закомментирован | NOT TESTED | `systemctl is-enabled/is-active sshd`, `ufw status`, `sudo -l`, `grep NOPASSWD` |
| 4.11 | `systemctl --failed` = 0 | NOT TESTED | вывод команды |
| 4.12 | 5 циклов блокировка→разблокировка с замером времени перерисовки (D2) | NOT TESTED | таблица времён по циклам |
| 4.13 | 5 запусков сессии без core dump kactivitymanagerd (D1) | NOT TESTED | `coredumpctl` / journal |
| 4.14 | ACPI: выключение из KDE, `systemctl poweroff`, QMP powerdown (D3) | NOT TESTED | время до выключения, 3 способа |
| 4.15 | Пакет `which` есть; БД pacman синхронизированы (`pacman -Sy` в движке, D12) | NOT TESTED | `which --version`, `pacman -Sl` |

## 5. BIOS-установка

- **За Мией** (её решение 12:13). Не выполняется мной без её слова. В этом отчёте — NOT TESTED (ответственность Мии).

## 6. Итог (промежуточный, 11.11.2026 19:24)

- PASS: §1 — 8/8; §2 — 2.1–2.7, 2.9–2.11, 2.14 (12 пунктов); §3 — 3.1–3.6 (6 пунктов). Всего PASS: 26
- FAIL: 2.12 (`/` в Live = 555), 2.13 (ACPI Live), 2.17 (список раскладок Diamond — ИСПРАВЛЕН в build3, перепроверен PASS в §3/§4), 3.7 (splash D8 — подтверждён) — 4 пункта (2.17 закрыт исправлением)
- ЧАСТИЧНО: 2.16 (Diamond 1–4: 3 PASS, 1 FAIL→исправлен), 3.6 (D1: 1 запуск PASS из 5), 4.1 (Diamond 1–5 PASS, 6–8 NOT TESTED из-за D14)
- В РАБОТЕ: 4.2 (установка UEFI, движок с 19:21)
- NOT TESTED: 2.8 (запуск Memtest), 2.15 (окна после VT-переключения — наблюдение), 3.8 (ACPI UEFI), §4.3–4.15 (первая загрузка и проверки установленной системы), §5 (BIOS-установка — за Мией)
- Новые дефекты: **D13** (Diamond без sudo — исправлен в исходниках, в build4), **D14** (клавиатура не доходит до QML Diamond в UEFI Live — причина не установлена; передача движка с экрана Установка NOT TESTED через GUI).
- Вывод промежуточный: fixed10 build3 загружается в UEFI, рабочий стол и Diamond 1–5 — в порядке; установка UEFI идёт (движок напрямую из-за D14); остаются: первая загрузка, циклы D1/D2, ACPI, build4 (D13+D8).
