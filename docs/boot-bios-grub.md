# BIOS-загрузка live-ISO XrOS через GRUB — исследование вариантов

Дата: 10 ноября 2026. Статус: **рецепт ПРОВЕРЕН загрузкой в QEMU
(10.11.2026) — BIOS-GRUB работает; в основную сборку НЕ внедрён**.
Решение принимает Мия. Основная сборка не менялась: `bootmodes=('uefi.grub')`.
Эксперимент: `experiments/bios-grub-test/` (README, скрипты, логи, скриншоты).

## 1. Исходное положение (проверено)

- Установленная система: BIOS = GRUB `i386-pc`, UEFI = GRUB `x86_64-efi`.
  Это делает движок `src/xros-install` (`grub-install --target=x86_64-efi` /
  `--target=i386-pc`, строки 416/419) — согласовано, не меняется.
- Live ISO: только UEFI. `profile/profiledef.sh`: `bootmodes=('uefi.grub')`.
- **archiso 92 НЕ знает режима `bios.grub` — подтверждено на этом хосте:**
  - `/usr/share/doc/archiso/README.profile.rst` (в chroot AKVT,
    `archiso-92-1`): раздел `bootmodes` перечисляет ровно три значения —
    `bios.syslinux`, `uefi.grub`, `uefi.systemd-boot`.
  - `/usr/sbin/mkarchiso` содержит только `_make_bootmode_bios.syslinux`,
    `_make_bootmode_uefi.grub`, `_make_bootmode_uefi.systemd-boot`
    (плюс устаревшие алиасы `bios.syslinux.eltorito/.mbr`,
    `uefi-x64/ia32.*`, которые возвращают ошибку). Функции
    `_make_bootmode_bios.grub` нет; проверка в `_validate_options`
    (`typeset -f "_make_bootmode_${bootmode}"`) отвергла бы такой режим.
  - На самом хосте archiso нет (нет `pacman`, `/usr/sbin/mkarchiso`
    отсутствует) — проверка выполнена в chroot
    `~/workspace/akvt-os/root.x86_64` (только чтение; файлы AKVT не менялись).

Следствие: штатно, внутри mkarchiso, BIOS-GRUB для live-ISO сделать нельзя.
Возможны только: смириться с UEFI-only, постобработка готового ISO вне
mkarchiso, либо возврат к `bios.syslinux`.

## 2. Рецепт BIOS-GRUB через El Torito + xorriso (проверен частично)

Идея: mkarchiso собирает обычный UEFI-only ISO, затем отдельный шаг
постобработки добавляет в него второй El Torito boot entry — BIOS GRUB.
В основную сборку этот шаг НЕ внедрён.

### 2.1. Шаг 1 — образ BIOS GRUB

GRUB 2.16 (в chroot) напрямую поддерживает формат El Torito:

```
grub-mkimage -O i386-pc-eltorito \
  -o boot/grub/i386-pc/eltorito.img \
  -p /boot/grub -c early.cfg \
  <модули>
```

- Формат `i386-pc-eltorito` есть в выводе `grub-mkimage --help`
  (проверено в chroot).
- **Проверено практически 10.11.2026:** образ собран успешно
  (334 195 байтов) с модулями, зеркально повторяющими список mkarchiso
  для UEFI минус EFI-модули (`efifwsetup`, `efinet`, `lsefi`, `tpm`)
  плюс BIOS-модули (`biosdisk`, `vbe`, `vga`) и с early-конфигом,
  который ищет ISO по метке и отдаёт управление в `/boot/grub/grub.cfg`.
  Первая проверка (только образ, 334 195 Б) — в `/tmp`; полная проверка —
  тестовый ISO в `experiments/bios-grub-test/` (eltorito.img 334 195 Б),
  загрузка в QEMU пройдена, см. §2.3.
- Early-конфиг (встраивается ключом `-c`, проверен `grub-script-check`):

```grub
insmod iso9660
insmod part_gpt
insmod part_msdos
search --no-floppy --set=root --label XROS_202611
set prefix=($root)/boot/grub
configfile /boot/grub/grub.cfg
```

- Подводные камни, найденные при проверке (а не из документации):
  - `--sbat` для BIOS-образа запрещён: `grub-mkimage` завершается
    ошибкой `SBAT data can be added only to EFI or powerpc-ieee1275 images`.
    SBAT в BIOS-образ не добавлять.
  - Модуль поиска по метке называется `search_label`, а не
    `search_fs_label` (такого `.mod` для `i386-pc` нет;
    `search_fs_file` и `search_fs_uuid` — есть). Неверное имя модуля
    роняет сборку образа.
- Прецедент: `grub-mkrescue` (GRUB 2.16, chroot) делает ровно это —
  в его бинаре есть строки `boot/grub/i386-pc/eltorito.img`,
  `i386-pc-eltorito`, `--grub2-boot-info`, `--grub2-mbr`, `boot_hybrid.img`.
- Профиль `grub.cfg` для BIOS готов заранее: в нём уже есть ветка
  `grub_platform == 'pc'` → `archiso_platform='BIOS'`, а пункты,
  требующие UEFI (`fwsetup`), защищены проверкой платформы.
  Изменений в `grub.cfg`/`loopback.cfg` для BIOS не требуется.

### 2.2. Шаг 2 — добавление образа в готовый ISO через xorriso

xorriso 1.5.8.pl02 (в chroot, `libisoburn-1.5.8.2-1`) умеет загружать
готовый ISO (`-indev`), сохранять его загрузочные записи
(`-boot_image any replay`) и добавлять новый El Torito boot entry.
Проверено по `xorriso -help` и man-странице `xorriso.1.gz` в chroot,
а затем практически — на тестовом ISO 10.11.2026 (xorriso 1.5.6 на хосте,
см. §2.3).

Схема (mkisofs-совместимый вызов, по образцу `grub-mkrescue`
и `_build_iso_image` из mkarchiso) — **проверена на тестовом ISO 10.11.2026**
(см. §2.3 и `experiments/bios-grub-test/src/build-iso.sh`):

```
xorriso -as mkisofs \
  -b boot/grub/i386-pc/eltorito.img \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  --grub2-boot-info \
  --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
  ... (остальные опции mkarchiso: -iso-level 3, -volid, UEFI entry и т.д.)
```

Что делает каждая опция:

- `-b .../eltorito.img -no-emul-boot -boot-load-size 4 -boot-info-table` —
  первый (BIOS) El Torito boot entry без эмуляции, с boot info table.
- `--grub2-boot-info` — записывает адрес boot-образа в байты 2548–2555
  образа (нужно GRUB, чтобы найти себя на диске).
- `--grub2-mbr boot_hybrid.img` — ставит MBR-код GRUB в System Area:
  нужен для загрузки с USB-флешки/диска (isohybrid). Без него BIOS
  загрузится только с оптического диска, а с флешки, записанной через
  `dd`, — нет.
- Порядок важен: UEFI entry добавляется через `-eltorito-alt-boot -e ...`
  (как делает `_add_common_xorrisofs_options_uefi` в mkarchiso);
  BIOS entry должен быть первым.

Альтернатива без пересборки ISO с нуля — правка готового ISO:

```
xorriso -indev xros.iso -outdev xros-bios.iso \
  -map eltorito.img /boot/grub/i386-pc/eltorito.img \
  -boot_image any replay \
  -boot_image grub bin_path=/boot/grub/i386-pc/eltorito.img \
  ...
```

Нюансы из man-страницы xorriso (проверено чтением):

- `-boot_image any replay` нужно применять ПОСЛЕ всех манипуляций
  с файлами: пути запоминаются на момент загрузки ISO, а замена
  boot-образа после `replay` даёт скрытый устаревший образ.
- Тип `grub` (а не `any`) сам включает патчинг boot info table;
  для `any` его нужно включать отдельно.
- GPT: mkarchiso при отсутствии BIOS-режима добавляет
  `-appended_part_as_gpt` (валидный GPT), а при наличии BIOS —
  `-isohybrid-gpt-basdat` (намеренно невалидный GPT, иначе часть
  старых BIOS не грузится). Уже собранный UEFI-only ISO имеет валидный
  GPT — при постобработке это отдельный вопрос, требующий проверки
  на тестовой матрице (см. §2.3).

### 2.3. Проверка загрузки в QEMU — ПРОЙДЕНА 10.11.2026

Экспериментальный ISO `experiments/bios-grub-test/out/xros-bios-test.iso`
(155 МБ, sha256 `1e29fe9909c673d81a9e42d8312e08454c9ac433b4ff64a8b12da42ad281399d`)
собран по этому рецепту: BIOS El Torito (`eltorito.img`, 334 195 Б, GRUB 2.16)
+ UEFI El Torito (`BOOTX64.EFI` в efiboot.img, тот же список модулей, что
у mkarchiso 92), ядро Arch 7.2.14-arch1-1 + минимальный initramfs (busybox).
Инфраструктура: QEMU 8.2.2 установлен на хосте (`apt-get install
qemu-system-x86 qemu-utils ovmf xorriso grub-pc-bin`), SeaBIOS
`/usr/share/seabios/bios-256k.bin`, OVMF `/usr/share/OVMF/OVMF_CODE_4M.fd`
+ `OVMF_VARS_4M.fd`; GRUB 2.16, ядро и модули — из chroot AKVT
(только чтение/запуск, bind-mount вывода, следов в chroot не осталось).

| Тест | Результат |
|---|---|
| BIOS SeaBIOS, CD (`-machine pc -drive if=ide,media=cdrom -boot d`) | ✅ PASS — GRUB 2.16 меню «XROS test kernel (BIOS)», ядро, init: метка `XROS_202611` найдена на /dev/sr0, ISO смонтирован, poweroff, QEMU exit 0. Доказательства: `experiments/bios-grub-test/logs/bios-serial.log`, `bios-menu.png` |
| BIOS SeaBIOS, «флешка» (ISO записан через dd в raw-диск 200 МБ, `-hda -boot c`) | ✅ PASS — MBR boot_hybrid.img → GRUB → ядро → init: метка найдена на /dev/sda1, ISO смонтирован, poweroff, QEMU exit 0. Доказательства: `logs/usb-serial.log`, `logs/usb-menu.png`. С этапа 2 этот режим воспроизводится штатно: `./src/run-qemu.sh usb` (копия ISO в `logs/usb.img`, `-drive if=ide,media=disk -boot c`) |
| UEFI OVMF, CD (`-machine q35`, OVMF_CODE_4M.fd) — регрессия | ✅ PASS — OVMF → BOOTX64.EFI → меню «XROS test kernel (x86_64-efi)» → ядро → init → poweroff, QEMU exit 0. Доказательства: `logs/uefi-serial.log`, `logs/uefi-menu.png`. **Повторён 10.11.2026 (этап 2) со свежим логом `logs/uefi-serial-20261110.log`: монтирование ISO по метке ДОКАЗАНО** — `ISO LABEL FOUND on /dev/sr0`, `ISO MOUNTED`. Старый лог `uefi-serial.log` (07:36) был от предыдущей сборки ISO: init тогда искал метку через `/dev/disk/by-label`, которого нет в минимальном initramfs без udev, и честно писал `ISO LABEL NOT FOUND`; текущий init ищет метку по смещению PVD (сектор 16 + 40 = offset 32808), и монтирование проходит и на UEFI, и на BIOS. |
| Гибрид после постобработки (этап 2): `scripts/postprocess-bios-grub.sh` на копии тестового ISO, `--force` | ✅ PASS — все три режима на пересобранном ISO (`xros-bios-test-copy-hybrid.iso`, sha256 `aaf0aaa99f85e512d0a15f994dae6c3f5f0a3609c8304f4d5b8c1d4c59af5b6c`): BIOS CD, UEFI CD, USB — QEMU exit 0, ISO смонтирован в каждом режиме. Доказательства: `logs/hybrid-bios-serial-20261110.log`, `logs/hybrid-uefi-serial-20261110.log`, `logs/hybrid-usb-serial-20261110.log`. Сгенерированный в rootfs `eltorito.img` — 334 190 Б (на 5 Б меньше, чем 334 195 Б в тестовом ISO: другая строка `echo` в early-config — `XROS: BIOS GRUB...` вместо `XROS-TEST: BIOS GRUB...`). Проверки `scripts/check-iso.sh` на обоих ISO: PASS=10 FAIL=0 SKIP=2. |

Подводные камни, найденные при проверке (факты, не догадки):

- **В early-конфиге grub-mkimage НЕТ `if`/`fi`** (`Unknown command 'if'`):
  early-контекст работает до загрузки normal.mod. Условия — только в grub.cfg,
  загружаемом через `configfile`. Финальный early-конфиг — без условий.
- **В early-конфиге `#` — НЕ комментарий** (`Unknown command '#'`): строки
  с `#` дают безвредные ошибки. Комментарии убраны из early-конфигов.
- **`/dev/console` — ПОСЛЕДНИЙ `console=` в cmdline.** С порядком
  `console=ttyS0 console=tty0` вывод init уходил на VGA, а не в serial-лог.
  Правильно: `console=tty0 console=ttyS0,115200`.
- **В списке модулей mkarchiso 92 для UEFI НЕТ `test`** — поэтому `[ ... ]`
  в grub.cfg на UEFI печатает `error: file '/boot/grub/x86_64-efi/test.mod'
  not found`, но выполнение продолжается через ветку `else`. Это же касается
  реального `profile/grub/grub.cfg` — подробнее отдельным абзацем ниже.
- **`/dev/disk/by-label` без udev не существует** — в минимальном initramfs
  метку проверяли чтением ISO9660 PVD напрямую (сектор 16 + 40 = offset 32808).
  В настоящем archiso-initramfs это делает udev/blkid — проблемы нет.
- `grub-mkstandalone` 2.16 предупреждает о SBAT: `Global SBAT level 4 in
  sbat.csv does not match the build-time Global SBAT level 6` — только
  предупреждение, EFI собирается и грузится.

ВАЖНОЕ УТОЧНЕНИЕ по пункту про `test`: из-за отсутствия модуля `test`
в UEFI-списке mkarchiso проверки вида `if [ -f /boot/grub/theme/theme.txt ]`
в реальном `profile/grub/grub.cfg` на UEFI **не сработают** (ошибка, условие
ложно) — тема и фон не загрузятся, меню будет текстовым. Это касается и
текущего UEFI-only ISO (не только BIOS-варианта) и требует отдельной проверки
на реальном ISO XrOS; обход — переписать проверки без `[` (например, через
`if search --file ...` или `if regexp ...`) либо смириться с текстовым меню
до выяснения. На BIOS-GRUB модуль `test` в образ включить МОЖНО (список
модулей BIOS задаём мы сами) — там проверки работают (проверено: `if [ ... ]`
в тестовом grub.cfg на BIOS отработал без ошибок).

**Обновление 10.11.2026 (финальный этап, AUDIT-REPORT.md §9): дефект
ИСПРАВЛЕН.** `profile/grub/grub.cfg` и `profile/grub/loopback.cfg`
переписаны без `[ ... ]`: тема/фон — безусловно, платформа и `fwsetup` —
через `regexp`. Проверено в QEMU на настоящем `grub.cfg`
(`experiments/uefi-test-module/`): ДО — 8–10 ошибок `test.mod`,
текстовое меню; ПОСЛЕ — 0 ошибок, меню с темой, заголовок `UEFI`,
5 пунктов. На настоящем ISO с archiso-initramfs тема перепроверяется
в рамках плана QEMU после сборки (AUDIT-REPORT.md §9.7 п. 1).

### Что по-прежнему НЕ проверено

- Загрузка настоящего ISO XrOS с archiso-initramfs (тестировалось только
  тестовое ядро + минимальный initramfs; archiso-хук не прогонялся).
- Постобработка на НАСТОЯЩЕМ ISO от mkarchiso (прогнана только на копии
  тестового ISO: структура та же — UEFI El Torito + `/boot/grub/grub.cfg`,
  но нет `/xros/boot/x86_64/vmlinuz-linux` и initramfs; тест на реальном
  ISO — этап 3).
- Настоящее меню `profile/grub/grub.cfg` под BIOS-GRUB: тема, фон,
  кириллица и guard `regexp '^efi$'` для пункта «Настройки UEFI»
  проверены только `grub-script-check`, а не загрузкой (тестовый ISO
  несёт упрощённое меню без темы).
- Loopback-загрузка ISO-файла с диска (loopback.cfg).
- Реальное железо / старые BIOS (только QEMU SeaBIOS + OVMF).
- Поведение на старых BIOS с валидным GPT — снято частично: тест «флешка»
  прошёл с `-isohybrid-gpt-basdat` (намеренно невалидный GPT, как у mkarchiso
  при наличии BIOS-режима); вариант с валидным GPT (`-appended_part_as_gpt`)
  для BIOS-образа не тестировался и не нужен.
- Совместимость с будущими версиями archiso/grub/xorriso.
- Вложенный unshare: `mkarchiso` внутри build-env rootfs выполняет
  pacstrap через вложенный unshare (уже внутри unshare+chroot) —
  на этом хосте не проверялось (см. шапку `scripts/build.sh`).

## 3. Сравнение вариантов

### Вариант А — принять UEFI-only live ISO (текущее состояние)

Плюсы:

- Ноль работы, ноль нового кода, ноль рисков для UEFI-загрузки.
- Соответствует upstream Arch: официальный ISO Arch Linux тоже
  UEFI+BIOS через syslinux, но сам archiso не навязывает BIOS.
- Установленная система на BIOS всё равно получает GRUB —
  ограничение касается только live-носителя.

Минусы / честные ограничения:

- Live ISO не загрузится на машинах с чистым BIOS без UEFI
  (старые ПК примерно до 2012 года, некоторые виртуалки
  с SeaBIOS по умолчанию, редкие прошивки с отключённым UEFI).
- Тестирование live ISO в QEMU по умолчанию (SeaBIOS) невозможно —
  нужен OVMF (`-bios /usr/share/edk2-ovmf/...` или pflash).
- Пользователь с BIOS-машиной не сможет даже запустить установщик.

Трудозатраты: 0. Решение: ничего не делать, честно написать
в документации, что live ISO требует UEFI.

### Вариант Б — BIOS-GRUB через xorriso-постобработку (рецепт выше)

Плюсы:

- Единое меню GRUB и единая тема XrOS для BIOS и UEFI —
  без второго загрузчика и без дублирования конфигов.
- Без syslinux: аудит-решение «только GRUB» сохраняется.
- Технически реально: формат `i386-pc-eltorito` поддерживается
  GRUB 2.16, образ собирается (проверено), xorriso умеет добавлять
  El Torito entry в готовый ISO (проверено по документации).

Минусы / честные ограничения:

- Шаг живёт ВНЕ mkarchiso: `mkarchiso` о нём не знает, его `_run_once`
  маркеры его не покрывают, повторный запуск `mkarchiso` его не
  воспроизведёт. Его должен явно вызывать скрипт сборки после
  `_build_iso_image` и ронять сборку при ошибке, иначе получится
  молча UEFI-only ISO.
- Хрупкость при обновлениях: смена archiso может поменять раскладку
  `isofs_dir`, опции xorriso или список модулей GRUB; смена GRUB —
  формат/имена модулей; всё это — ручная перепроверка при каждом
  обновлении инструментов. Это главный долгосрочный минус.
- GPT/MBR-нюансы (§2.2): валидный GPT против старых BIOS,
  isohybrid MBR для флешек — всё требует тестов на железе/матрице QEMU.
- Загрузка проверена на тестовом ISO (см. §2.3); на настоящем ISO XrOS
  с archiso-initramfs — ещё нет.
- Secure Boot тут ни при чём (BIOS его не знает), но и не решается.

Трудозатраты: внедрение ~0,5–1 день (скрипт постобработки +
матрица QEMU: BIOS-CD, BIOS-USB, регрессия UEFI, loopback) +
поддержка при каждом обновлении archiso/grub (перепроверка рецепта).

### Вариант В — вернуть `bios.syslinux` (только как вариант для решения Мии)

Плюсы:

- Штатно поддерживается mkarchiso: `bootmodes=('bios.syslinux'
  'uefi.grub')`, ноль кастомного кода, проверенный upstream путь.
- Официальный ISO Arch Linux грузится с BIOS именно так.
- Работает и с CD, и с флешки (isohybrid MBR из коробки).

Минусы / честные ограничения:

- Возвращает syslinux, который аудит сознательно удалил
  («загрузчик XrOS — только GRUB»): второй загрузчик, второй
  конфиг (`profile/syslinux/*.cfg`), вторая тема оформления
  вместо единой GRUB-темы XrOS.
- Syslinux фактически заброшен (6.04-pre3, разработка замерла);
  его меню выглядит иначе, чем GRUB-меню, — единый фирменный вид
  теряется.
- Потребуется восстановить `profile/syslinux/` из резерва
  `/tmp/xros-bootloader-backup-20261110/` и заново оформить его
  в палитре XrOS — отдельная работа.
- НЕ внедрять без отдельного согласования (требование аудита).

Трудозатраты: ~0,5 дня (восстановить syslinux, оформить,
прогнать матрицу QEMU) + вечный второй загрузчик в поддержке.

## 4. Рекомендация (обновлено 10.11.2026 после QEMU-тестов; статус — этап 2)

**Вариант Б (BIOS-GRUB через xorriso-постобработку) теперь ПРОВЕРЕН
загрузкой в QEMU** — это больше не непроверенный рецепт: BIOS-CD, BIOS-USB
и регрессия UEFI прошли (см. §2.3). Ограничения, которые остались:
загрузка настоящего archiso-initramfs не прогонялась, loopback не
тестировался, реальное железо не тестировалось. Плюс вскрылся отдельный
дефект текущего UEFI-only ISO: из-за отсутствия модуля `test` в списке
mkarchiso проверки `[ -f ... ]` в `profile/grub/grub.cfg` на UEFI не
работают (тема/фон не загрузятся) — это надо проверить и чинить
независимо от решения по BIOS.

**Внедрение варианта Б в основную сборку — СДЕЛАНО на этапе 2
(10.11.2026), ISO ещё НЕ собран:**
- `scripts/postprocess-bios-grub.sh` — постобработка ISO от mkarchiso:
  BIOS El Torito (GRUB 2.16 из build-env rootfs) + гибридный MBR,
  UEFI El Torito сохраняется (efiboot.img извлекается из appended
  partition 2 по GPT-интервалу через dd — в ISO от mkarchiso её нет
  в дереве); выход `<имя>-hybrid.iso` или `--in-place` с бэкапом.
  На копии тестового ISO проверен полностью (см. §2.3, строка
  «Гибрид после постобработки»).
- `scripts/check-iso.sh` — проверки ISO: оба El Torito, гибридный MBR,
  Volume id, структура, SHA256, `xorriso -check_media`; с `--archiso`
  дополнительно `/xros/boot/x86_64/vmlinuz-linux` и initramfs.
- `scripts/build.sh` — реальный драйвер (13 шагов, `--dry-run` для
  проверки без выполнения): диагностика (FAIL=0) → Rust → 4 пакета →
  репозиторий → снимок в airootfs → бинари в airootfs → mkarchiso
  ВНУТРИ build-env rootfs → постобработка → check-iso → SHA256SUMS.
  mkarchiso НЕ запускался (этап 3, отдельным запуском с разрешения Мии).
- Путь запуска mkarchiso: ТОЛЬКО внутри `build-env/root.x86_64`
  (через `scripts/xros-build-env.sh --exec`, unshare+chroot —
  systemd-nspawn на хосте не работает). В rootfs установлены
  archiso 92-1, squashfs-tools 4.7.5-1, grub 2:2.16-1, xorriso 1.5.8.pl02
  (пакет libisoburn 1.5.8.2-1). Хостовый GRUB — 2.12, для генерации
  eltorito.img НЕ подходит (core.img и boot_hybrid.img должны быть
  одной версии 2.16). CA egress-TLS хоста в rootfs обновляется
  драйвером сборки на каждом запуске (CA меняется при перезагрузке ВМ).
- Зеркало профиля в build-env синхронизировано с актуальным `profile/`
  (`diff -rq` — 0 отличий); драйвер сборки синхронизирует его при
  каждом запуске. `profiledef.sh` по-прежнему `bootmodes=('uefi.grub')`,
  syslinux НЕ возвращался.

Для первого релиза по-прежнему разумен **вариант А (принять UEFI-only)**,
если Мия не хочет расширять объём работ: BIOS-машин без UEFI почти не
осталось. Но теперь **вариант Б — проверенная опция**, а не риск вслепую:
если Мия решит, что BIOS нужен, — делать вариант Б (единый GRUB и единая
тема), а не В. Внедрение варианта Б в основную сборку — сделано на этапе 2
(см. выше); осталось — прогон матрицы на настоящем ISO XrOS после сборки
в этапе 3 (BIOS-CD, BIOS-USB, UEFI-регрессия, loopback, проверка темы
на UEFI и на BIOS). Диагностика после этапа 2: PASS=216 FAIL=0 SKIP=11
(было 214: +2 — bash -n двух новых скриптов).
Вариант В (syslinux) — только если вариант Б провалится на тестах
настоящего ISO, чего пока ничто не предвещает.

## 5. Источники проверки (10.11.2026)

- `/usr/share/doc/archiso/README.profile.rst` (archiso 92, chroot AKVT):
  раздел `bootmodes`.
- `/usr/sbin/mkarchiso` (archiso 92): `_make_bootmode_*`,
  `_add_xorrisofs_options_*`, `_build_iso_image`,
  `_make_bootmode_uefi.grub` (строки 733–836), `_make_common_bootmode_grub_cfg`
  (embedded grub.cfg: поиск по файлу `/boot/<uuid>.uuid`, hint из cmdpath),
  `_add_common_xorrisofs_options_uefi` (строки 1493–1526: `-partition_offset 16`,
  `-append_partition 2 <ESP-GUID>`, `-isohybrid-gpt-basdat` ДО `-e`,
  `-e --interval:appended_partition_2:all::`).
- `grub-mkimage --help` (GRUB 2.16, chroot): формат `i386-pc-eltorito`.
- Практическая сборка `eltorito.img` (334 195 байтов) + `grub-script-check`
  early-конфига — в chroot, вывод только в `/tmp` (не в проект).
- Строки бинаря `grub-mkrescue` (GRUB 2.16): `eltorito.img`,
  `--grub2-boot-info`, `--grub2-mbr`, `boot_hybrid.img`.
- `xorriso -help`, man `xorriso.1.gz` (xorriso 1.5.8.pl02):
  `-boot_image ... replay/patch`, `bin_path`, `grub2-boot-info`,
  `grub2-mbr`.
- Man `xorrisofs.1.gz`: `--grub2-boot-info`, `--grub2-mbr`.
- Пакеты в репозиториях Arch: `memtest86+-efi 9.00-1`,
  `edk2-shell 202608-1` (sync-БД `extra.db`/`extra.files` в chroot).
- **QEMU-проверка 10.11.2026 (новое):** QEMU 8.2.2, SeaBIOS
  `/usr/share/seabios/bios-256k.bin`, OVMF `/usr/share/OVMF/OVMF_CODE_4M.fd`
  (установлены на хосте через apt); тестовый ISO
  `experiments/bios-grub-test/out/xros-bios-test.iso` (sha256
  `1e29fe9909c673d81a9e42d8312e08454c9ac433b4ff64a8b12da42ad281399d`);
  логи и скриншоты: `experiments/bios-grub-test/logs/` (`bios-serial.log`,
  `uefi-serial.log`, `usb-serial.log`, `bios-menu.png`, `uefi-menu.png`,
  `usb-menu.png`); скрипты воспроизведения:
  `experiments/bios-grub-test/src/build-iso.sh`, `src/run-qemu.sh`.
