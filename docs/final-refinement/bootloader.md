# Финальная доработка XrOS — загрузчик и GRUB-меню

Дата: 10 ноября 2026. Задача 2 (загрузчик и GRUB-меню).
Запреты соблюдены: `scripts/build.sh` и `mkarchiso` не запускались,
ISO не создавался, пакеты/репозитории не публиковались.
`~/workspace/akvt-os` не менялся (только чтение + временный bind-mount
для проверок, см. ниже); `ARCHITECTURE.md`, `AUDIT-REPORT.md`,
`README.md`, `scripts/xros-diagnose.sh`, `~/MEMORY.md` не редактировались.

## 1. Что проверено и каким способом

### 1.1. Возможности archiso 92 — `bios.grub` отсутствует (ПОДТВЕРЖДЕНО)

- На самом хосте archiso нет (`pacman`, `/usr/sbin/mkarchiso`,
  `/usr/share/doc/archiso/` отсутствуют). Проверка выполнена в chroot
  `~/workspace/akvt-os/root.x86_64` (установлен `archiso-92-1`,
  GRUB 2.16, xorriso 1.5.8.pl02) — только чтение его файлов.
- `/usr/share/doc/archiso/README.profile.rst`, раздел `bootmodes`:
  ровно три значения — `bios.syslinux`, `uefi.grub`,
  `uefi.systemd-boot`. Про `bios.grub` нет ни слова.
- `/usr/sbin/mkarchiso`: есть только `_make_bootmode_bios.syslinux`,
  `_make_bootmode_uefi.grub`, `_make_bootmode_uefi.systemd-boot`
  (+ устаревшие алиасы, возвращающие ошибку). Функции
  `_make_bootmode_bios.grub` нет; `_validate_options` отверг бы
  такой режим (`typeset -f "_make_bootmode_${bootmode}"`).
- Вывод: комментарий в `profiledef.sh` верен — штатно сделать
  BIOS-GRUB для live-ISO в archiso 92 нельзя.

### 1.2. BIOS GRUB через El Torito + xorriso — исследование

Подробно: `docs/boot-bios-grub.md`. Коротко, что проверено практически:

- `grub-mkimage --help` (GRUB 2.16, chroot): формат `i386-pc-eltorito`
  поддерживается.
- **Сборка тестового образа удалась:** `grub-mkimage -O i386-pc-eltorito`
  с модулями по образцу списка mkarchiso для UEFI (минус EFI-модули,
  плюс `biosdisk`, `vbe`, `vga`) и встроенным early-конфигом
  (поиск ISO по метке `XROS_202611` → `configfile /boot/grub/grub.cfg`)
  дал образ **334 195 байтов**. Early-конфиг прошёл `grub-script-check`.
  Образ — только в `/tmp`, в проект не попал, ISO не создавался.
- Найденные подводные камни (практикой, а не чтением документации):
  `--sbat` для BIOS-образа запрещён (`SBAT data can be added only to
  EFI...`); модуль поиска по метке — `search_label`, а не
  `search_fs_label` (такого `.mod` для `i386-pc` нет).
- Прецедент: `grub-mkrescue` делает ровно это (строки его бинаря:
  `boot/grub/i386-pc/eltorito.img`, `--grub2-boot-info`, `--grub2-mbr`,
  `boot_hybrid.img`).
- xorriso 1.5.8: `-boot_image any replay` сохраняет загрузочные записи
  готового ISO, тип `grub` сам патчит boot info table
  (проверено по `xorriso -help` и man `xorriso.1.gz` / `xorrisofs.1.gz`).
- **НЕ проверено:** загрузка такого ISO (BIOS-CD, BIOS-USB,
  регрессия UEFI) — ISO не собирался, тестов в QEMU не было.
  Рецепт — не работающая фича до тестов.
- В основную сборку ничего не внедрено — только исследование.

### 1.3. Memtest86+ / UEFI Shell — пакетов нет, пункты удалены

- `profile/packages.x86_64`: `memtest86+-efi` и `edk2-shell`
  отсутствуют (проверено grep).
- В репозиториях Arch пакеты СУЩЕСТВУЮТ (источник — sync-БД
  `extra.db`/`extra.files` в chroot AKVT, срез ~ноябрь 2026):
  `memtest86+-efi 9.00-1` (ставит `/boot/memtest86+/memtest86x64.efi`,
  415 КБ) и `edk2-shell 202608-1` (ставит
  `/usr/share/edk2-shell/x64/Shell_Full.efi`, 6,5 МБ).
- Но в самом chroot они НЕ установлены (`/usr/share/edk2-shell`
  и `/boot/memtest86+` отсутствуют), а значит, mkarchiso при сборке
  XrOS не скопирует эти файлы на ISO (`_make_bootmode_uefi.grub`
  копирует их только при наличии в `pacstrap_dir`/`boot_dir`).
  Проверки `-f` в меню означали бы, что пункты никогда не появляются.
- По ТЗ пункты **удалены** из `profile/grub/grub.cfg` и
  `profile/grub/loopback.cfg` (см. §2). Фиктивных файлов не создавалось.

### 1.4. Синхронность grub.cfg / loopback.cfg и тема

- После правок список `menuentry` в обоих файлах побайтово одинаков
  (проверено `diff` по строкам `menuentry`): 5 пунктов —
  обычная загрузка, speaking, «Настройки UEFI» (только EFI),
  выключение, перезагрузка.
- Тема `profile/grub/theme/theme.txt` на месте; палитра соответствует
  новой фирменной системе 10.11.2026 (`#08080D`, `#111018`, `#8B00FF`,
  `#B66AFF`, `#F5F3FA`, `#A6A0B3`, `#30283B` — в комментарии и значениях
  файла). Шрифты `.pf2` (DejaVuSans-12/14/Bold-16), фон `grub-bg.jpg`
  и иконки — на месте.
- Неиспользуемый файл иконки `profile/grub/theme/memtest.png` оставлен
  (420 байт, ни на что не влияет, меню его не показывает). Удалять не
  стал — вне объёма задачи; при желании убрать одной правкой.
- Установленная система: `src/xros-install` (строки 416/419) делает
  `grub-install --target=x86_64-efi` и `--target=i386-pc`, а меню
  установленной системы генерирует `grub-mkconfig` на цели
  (строка 422) — профиль `grub.cfg` относится только к live-ISO.
  Не менялось.
- Других упоминаний Memtest/UEFI Shell в проекте нет
  (grep по `profile/airootfs/`, `src/`, `packages/` — пусто).

### 1.5. profiledef.sh — документация состояния

- `bootmodes=('uefi.grub')` — НЕ менялся (без решения Мии).
- Комментарий про UEFI-only и отсутствие `bios.grub` — верен
  и подтверждён проверкой §1.1. Добавлена одна строка —
  ссылка на исследование `docs/boot-bios-grub.md`.
- Резерв удалённых syslinux/efiboot `/tmp/xros-bootloader-backup-20261110/`
  существует (каталоги `efiboot`, `syslinux` на месте).

## 2. Что изменено (список файлов)

| Файл | Изменение |
|---|---|
| `profile/grub/grub.cfg` | Удалён блок Memtest86+ (EFI- и BIOS-ветки). Удалён блок UEFI Shell. Удалён ставший мёртвым блок присваивания `uefi_machine_type_lower`. Оставлен только `fwsetup`-пункт «Настройки UEFI» под проверкой платформы. Добавлен комментарий, почему Memtest/Shell нет и как вернуть. |
| `profile/grub/loopback.cfg` | Те же правки, симметрично. |
| `profile/profiledef.sh` | Добавлена ссылка на `docs/boot-bios-grub.md` в комментарий про UEFI-only (bootmodes не менялся). |
| `docs/boot-bios-grub.md` | **Новый файл**: исследование BIOS-GRUB (рецепт El Torito + xorriso, сравнение трёх вариантов, рекомендация). |
| `docs/final-refinement/bootloader.md` | **Новый файл**: этот отчёт. |

Не менялись: `ARCHITECTURE.md`, `AUDIT-REPORT.md`, `README.md`,
`scripts/xros-diagnose.sh`, `profile/packages.x86_64`, движок установки,
тема GRUB.

Итоговое меню live-ISO (оба файла, одинаково):

1. `XrOS 1.0 (%ARCH%, ${archiso_platform})` — обычная загрузка.
2. `XrOS 1.0 — с экранным диктором (speaking)` (hotkey `s`).
3. `Настройки UEFI` — только на UEFI (`fwsetup`, встроенная команда GRUB).
4. `Выключить компьютер` (`halt`).
5. `Перезагрузить компьютер` (`reboot`).

Только рабочие пункты, в фирменной теме XrOS. Фиктивных ссылок нет.

## 3. Результаты проверок

| Проверка | Способ | Результат |
|---|---|---|
| `bios.grub` в archiso 92 отсутствует | README.profile.rst + функции `_make_bootmode_*` в mkarchiso (chroot) | **PASS** (подтверждено) |
| Сборка BIOS El Torito образа GRUB 2.16 | `grub-mkimage -O i386-pc-eltorito` в chroot, вывод в `/tmp` | **PASS** (334 195 байтов) |
| Early-конфиг BIOS GRUB | `grub-script-check` (GRUB 2.16, chroot) | **PASS** |
| `grub.cfg` после правок | `grub-script-check` (GRUB 2.16, chroot) | **PASS** |
| `loopback.cfg` после правок | `grub-script-check` (GRUB 2.16, chroot) | **PASS** |
| Синхронность меню grub.cfg / loopback.cfg | `diff` по строкам `menuentry` | **PASS** (идентичны) |
| Тема и палитра | чтение `theme.txt`, сверка цветов с палитрой 10.11.2026 | **PASS** |
| Пакеты memtest86+-efi / edk2-shell в Arch | sync-БД `extra.db`/`extra.files` в chroot | **PASS** (существуют, версии 9.00-1 / 202608-1) |
| Файлы Memtest/Shell попадут на ISO | `packages.x86_64` + логика `_make_bootmode_uefi.grub` | **FAIL** (пакетов нет → файлов не будет → пункты удалены) |
| Загрузка BIOS-GRUB ISO в QEMU/на железе | — | **SKIP** — ISO не собирался (запрещено ТЗ); проверять только после решения Мии и внедрения, матрица — в `docs/boot-bios-grub.md` §2.3 |
| Визуальная проверка меню в QEMU | — | **SKIP** — нет ISO; скриншот меню — на этапе сборки |
| Полная сборка ISO | — | **SKIP** — запрещено ТЗ, отдельный этап |

Примечание про среду проверок: `grub-script-check` и `grub-mkimage`
запускались из chroot AKVT (`/usr/bin/grub-script-check`,
`/usr/bin/grub-mkimage`); файлы для проверки подкладывались через
временный bind-mount хостового каталога `/tmp/xros-boot-check`
на существующий пустой каталог `$chroot/mnt` (в пределах одного
вызова, после — `umount`). В дерево `~/workspace/akvt-os` при этом
попал один нулевой файл-заглушка от прерванного запуска
(`$chroot/mnt/eltorito-test.img`, создан до падения `grub-mkimage`
по `--sbat`) — **удалён, каталог `$chroot/mnt` пуст, AKVT не изменён**.
Хостовая scratch-папка `/tmp/xros-boot-check/` удалена после проверок.

## 4. Оставшиеся проблемы и что требует решения Мии

1. **BIOS-загрузка live-ISO (главное решение).** Live ISO сейчас
   только UEFI. Варианты — в `docs/boot-bios-grub.md`:
   (А) принять UEFI-only — ноль работы;
   (Б) BIOS-GRUB через xorriso-постобработку — рецепт проверен
   до генерации образа, но загрузка не тестировалась, плюс вечная
   плата за поддержку при обновлениях archiso/grub;
   (В) вернуть `bios.syslinux` — штатно, но возвращает заброшенный
   загрузчик и второй конфиг/тему (только с отдельного согласования).
   Моя рекомендация: для первого релиза — (А); если BIOS нужен —
   (Б), а не (В). **Без решения Мии `bootmodes` не меняется.**
2. **Memtest86+ / UEFI Shell — возвращать или нет?** Сейчас пунктов
   нет. Если Мия захочет их в меню — добавить `memtest86+-efi`
   и/или `edk2-shell` в `profile/packages.x86_64` (+~0,4 МБ и ~6,5 МБ
   к образу) и вернуть `menuentry` с проверками `-f` в оба файла
   (инструкция — в комментарии в самих файлах). Это отдельное решение,
   не блокирует сборку.
3. **QEMU-проверка меню и загрузки** — возможна только после сборки
   ISO (отдельный этап, после разрешения Мии). Для live ISO нужен
   OVMF, т.к. QEMU по умолчанию — SeaBIOS, а live ISO UEFI-only.
4. **Неиспользуемая иконка `theme/memtest.png`** — мелочь, можно
   удалить при следующей правке темы (на меню не влияет).

## 5. Честные оговорки

- `grub-script-check` проверяет только синтаксис GRUB-скрипта,
  а не то, что меню реально отрисуется с темой и загрузит ядро, —
  визуальная проверка возможна только в QEMU с собранным ISO.
- Рецепт BIOS-GRUB проверен только до генерации `eltorito.img`;
  загрузка не тестировалась, и я не утверждаю, что она работает.
- Версии пакетов Memtest/edk2-shell взяты из снэпшота sync-БД
  в chroot AKVT (~ноябрь 2026), а не из живого запроса к зеркалам
  Arch — к моменту сборки версии могут быть новее.
