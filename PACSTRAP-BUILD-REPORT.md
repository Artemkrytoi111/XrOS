# XrOS — отчёт о сборке ISO обходным путём (ручной pacstrap)

Дата сборки: **2026-11-10**. Статус: **ISO собран, проверки пройдены**.
Разрешение Мии (10.11.2026): ручной pacstrap по проверенной схеме
разрешён ТОЛЬКО для подготовки rootfs и упаковки в ISO. Не разрешает:
реальные диски, чужие chroot, отключение проверки подписей, публикацию ISO.

## 1. Итог

| Артефакт | Путь | Размер | SHA256 |
|---|---|---|---|
| ISO от mkarchiso | `out/xros-1.0-x86_64.iso` | 1 852 039 168 Б (1,8 ГБ) | `e2ac86e0e2ffc7614f50aad337c1130ec40f49213e7c7e8a86b6b8a780a0c21a` |
| Гибридный ISO (BIOS-GRUB) | `out/xros-1.0-x86_64-hybrid.iso` | 1 852 350 464 Б (1,8 ГБ) | `0e664a48b9cb64a9c043dec2b8f13e620c8caddcceb5c29979760ce15e00f90c` |

- `scripts/check-iso.sh --archiso` для гибридного ISO: **PASS=12 FAIL=0 SKIP=0**
  (лог: `out/check-iso.log`).
- Для ISO от mkarchiso (без постобработки): PASS=9 FAIL=3 — три FAIL
  ровно про отсутствующий BIOS (нет BIOS El Torito, нет гибридного MBR,
  нет `/boot/grub/i386-pc/eltorito.img`), что ожидаемо до постобработки
  (лог: `out/check-iso-plain.log`).
- Диагностика после сборки: `./scripts/xros-diagnose.sh` —
  **PASS=217 FAIL=0 SKIP=11** (лог: `out/diagnose.log`).
- `grub-script-check` для `grub.cfg` из ISO — PASS.
- QEMU-тесты НЕ запускались (следующий этап, отдельные агенты).
- ISO никуда НЕ загружался и НЕ публиковался.

## 2. Почему штатный mkarchiso не работает в текущей песочнице

Штатный путь (`scripts/build.sh`, шаг 10) трижды упал одинаково
(попытки 1–3, логи `out/mkarchiso.log`, `out/build-stage3-*.log`):

```
mkarchiso -> pacstrap -> chroot_setup -> свежий mount sysfs ->
mount: /xros/work/x86_64/airootfs/sys: fsmount() failed: VFS: Mount too revealing.
==> ERROR: failed to setup chroot /xros/work/x86_64/airootfs
```

Причина — среда, а не профиль и не список пакетов: хост сборки
работает в user namespace, не владеющем хостовым net ns; свежий mount
sysfs (а следом — и devtmpfs, проверено: `mount: .../dev: permission
denied`) запрещён ядром для такого неймспейса. Это подтверждено
независимо: проба `nspawn_usable()` в `xros-build-env.sh`
(`unshare --mount -- sh -c 'mount -t sysfs …'`) тоже падает, поэтому
`systemd-nspawn` на этом хосте недоступен и build-env работает
по запасному пути `unshare+chroot`. Минимальный набор пакетов ведёт
себя так же — дело не в размере списка.

## 3. Что делает обход

Схема — ручной pacstrap по проверенному рецепту другого
Arch-дистрибутива (сборка 15, 07.11.2026: ручной pacstrap полного
списка + файлы профиля + `customize_airootfs.sh` через arch-chroot +
файл версии + маркеры `_run_once`, затем mkarchiso только для
squashfs + ISO; рецепт восстановлен по датированному логу
`~/memory/2026-11-07.md`, строка 132, и сверен с файлами профиля
того проекта в `~/workspace/akvt-os` — только чтение, ничего
не изменено). Отличия XrOS: свои каталоги/метка (`XROS_202611`,
`install_dir xros`), свой список пакетов (Plasma 6.8 Wayland,
без syslinux/systemd-boot/xfce4/lightdm), профиль копируется ДО
pacstrap (штатный порядок mkarchiso), BIOS-GRUB — отдельной
постобработкой после mkarchiso.

Скрипт обхода: `scripts/build-rootfs-pacstrap.sh` (исполняемый,
`bash -n` чистый, требует `--confirm`). Он НЕ запускает mkarchiso
сам — только готовит rootfs. Штатный `scripts/build.sh` НЕ переписан
и НЕ удалён: штатная сборка и обход — два отдельных пути.

Точная последовательность выполненных команд (внутри build-env,
через `scripts/xros-build-env.sh --exec`, т.е. `unshare+chroot`):

1. Диагностика `scripts/xros-diagnose.sh` — FAIL=0, иначе стоп.
2. Архив старых логов в `out/prev-logs-<дата>/`; `rm -rf work`;
   удаление старых ISO в `out/`; `build_date` = SOURCE_DATE_EPOCH
   (`1794307045` = 2026-11-10 10:37:25 UTC).
3. Обновление egress-CA хоста в build-env (`update-ca-trust extract`).
4. `chmod 755 build-env/run` (см. §6, пункт 5).
5. Генерация `work/iso.pacman.conf` — ТОЧНО как `_make_pacman_conf`
   в mkarchiso (`pacman-conf --config profile/pacman.conf` + тот же
   `sed`: strip CacheDir/DBPath/HookDir/LogFile/RootDir, append
   CacheDir + HookDir на airootfs).
6. `cp -af --no-preserve=ownership,mode profile/airootfs/. airootfs/`
   ДО pacstrap (штатный порядок: `_make_custom_airootfs` до
   `_make_packages`) + применение `file_permissions` из
   `profiledef.sh` для существующих файлов (отсутствующие —
   предупреждение, как у mkarchiso).
7. Снимок репозитория `[xros]` в build-env по пути
   `/usr/share/xros/repo` (см. §6, пункт 2).
8. Ручной pacstrap — ТЕ ЖЕ опции, что у mkarchiso (`_make_packages`):
   `env -u TMPDIR pacstrap -C /xros/work/iso.pacman.conf -c -G -M -- /xros/work/x86_64/airootfs <46 пакетов из profile/packages.x86_64>`.
   Без `--needed`, без послаблений SigLevel, без лишних пакетов.
   Скачано 1129,18 МиБ; установленный размер 3380,04 МиБ.
9. Проверка: все 46 пакетов из списка установлены (`pacman -Q`
   каждого); всего пакетов в rootfs: **645** (список:
   `work/installed-pkgs.txt`).
10. `arch-chroot airootfs /root/customize_airootfs.sh` (как
    `_make_customize_airootfs`), затем удаление скрипта из airootfs.
11. Контрольный `mkinitcpio -P` в chroot + проверка archiso-хуков
    в initramfs (`lsinitcpio`, см. §6, пункт 4).
12. Файлы версии — как `_make_version` в mkarchiso: `airootfs/version`
    (`1.0`), `work/iso/xros/version`, `IMAGE_ID=xros` /
    `IMAGE_VERSION=1.0` в os-release, `/usr/lib/clock-epoch`
    на SOURCE_DATE_EPOCH.
13. Шесть маркеров `_run_once` в `work/`: `base._make_work_dir`,
    `base._make_pacman_conf`, `base._make_custom_airootfs`,
    `base._make_packages`, `base._make_version`,
    `base._make_customize_airootfs`.
14. Проверки готового rootfs (все прошли, см. §5).

Затем упаковка (отдельно, не скриптом rootfs):
`xros-build-env.sh --exec -- mkarchiso -v -w /xros/work -o /xros/out /xros/profile`
— mkarchiso пропустил 6 шагов по маркерам и выполнил только
`_make_iso_limited_grubenv`, `_copy_boot_out_of_pacstrap_dir`,
`_make_pkglist`, `_check_if_initramfs_has_ucode`,
`_make_boot_on_iso9660`, `_make_bootmode_uefi.grub`,
`_cleanup_pacstrap_dir`, `_prepare_airootfs_image` (squashfs),
`_build_iso_image`. Выход — 0, ошибок в логе — 0.
Первая попытка mkarchiso была прервана на 23% squashfs не по вине
сборки (обрыв вызова инструмента); повторный запуск дошёл до конца
(маркеры сохранили уже выполненные шаги, частичный `.sfs` пересоздан).

Затем `scripts/postprocess-bios-grub.sh --iso out/xros-1.0-x86_64.iso`
(exit 0; `eltorito.img` 334 190 Б; лог `out/xros-1.0-x86_64-hybrid.iso.postprocess.log`),
затем `scripts/check-iso.sh --archiso` и `SHA256SUMS` в `out/`.

## 4. Что делает pacstrap, а что остаётся за mkarchiso

- **pacstrap** (вручную): создаёт каталог rootfs, монтирует
  API-файловые системы (proc, sys, dev, devpts, shm, run, tmp),
  запускает `pacman -Sy <пакеты>` с `--config` и `--disable-sandbox`
  в новый корень. Проверка подписей НЕ отключается
  (`SigLevel = Required DatabaseOptional` из профиля).
- **mkarchiso** (после маркеров): копирование `/boot` из airootfs,
  список установленных пакетов (`pkglist.x86_64.txt`), проверка
  microcode в initramfs, подготовка ядра/initramfs для ISO9660,
  UEFI-GRUB (FAT-образ 23 МиБ, `BOOTX64.EFI` + `BOOTIA32.EFI`),
  очистка airootfs, squashfs (`zstd -Xcompression-level 15 -b 1M`,
  `airootfs.sfs` 1 551 566 608 Б), сборка ISO (xorriso).
- **postprocess-bios-grub.sh**: добавляет BIOS-GRUB (El Torito
  `i386-pc`, гибридный MBR `grub2-mbr`), не трогая UEFI-часть.

## 5. Результат подготовки rootfs (проверки, все PASS)

- Версии: `linux 7.2.15.arch1-1`, `plasma-desktop 6.8.2-1`,
  `grub 2:2.16-1`, `sddm 0.21.0-7`, `mkinitcpio-archiso 73-1`,
  `ufw 0.36.2-7`. airootfs: 4,1 ГБ, 181 145 файлов (до очистки
  mkarchiso; после — 3,9 ГБ, `/boot` вынесен в `work/x86_64/boot`).
- Пользователь `xros` (uid 1000, группы wheel/audio/optical/render/
  storage/video); SDDM-автовход `User=xros, Session=plasma`.
- Службы включены: `sddm`, `NetworkManager`, `ufw`.
- Пароли `root` и `xros` заблокированы (`passwd -S` → `L`),
  `/etc/shadow` — 600.
- Локали: `ru_RU.UTF-8` сгенерирована; часовой пояс
  `Europe/Astrakhan`.
- Фирменная тема: `/usr/share/xros/wallpaper.png`,
  `/usr/share/xros/xros-logo.png`, `BreezeDark` в kdeglobals.
- Файрвол: `DEFAULT_INPUT_POLICY="DROP"` в `/etc/default/ufw`.
- Установщик и приветствие: `/usr/local/bin/xros`,
  `xros-install`, `xros-install-gui`, `xros-welcome`,
  `xros-welcome-gui` — все исполняемые.
- systemd на месте (`/usr/lib/systemd/systemd`).
- initramfs (226 541 273 Б): хуки `archiso`, `archiso_loop_mnt`,
  `archiso_pxe_common`, `archiso_pxe_nbd`, `archiso_pxe_http`,
  `archiso_pxe_nfs` (плюс `archiso_kms` как deprecated-предупреждение).
- DE=none (проверка списка/конфигурации, не установка): 15
  графических пакетов из `packages.x86_64` полностью покрыты
  `XROS_GRAPHICS_PKGS` установщика (15 пакетов) — установка
  без графики их не получит.

## 6. Найденные проблемы и как исправлены

1. **Патч pacstrap от агента исправления — незавершён.**
   Состояние на момент проверки: в
   `build-env/root.x86_64/usr/bin/pacstrap` была изменена ровно
   одна строка (`chroot_setup`: свежий mount sysfs →
   `chroot_add_mount_lazy /sys "$1/sys" --rbind`), оригинал сохранён
   как `pacstrap.orig`, каталога `scripts/patches/` не было.
   Тест показал: sysfs починен, но следующий шаг падал —
   свежий mount devtmpfs запрещён (`permission denied`).
   Патч ЗАВЕРШЁН корректно, а не откачен: добавлена вторая строка
   тем же штатным приёмом (`chroot_add_mount_lazy /dev "$1/dev"
   --rbind` — идиома из `unshare_setup()` того же файла).
   Итоговый diff против `.orig` — ровно 2 строки в `chroot_setup()`.
   Проверено минимальным pacstrap (`filesystem bash`, exit 0).
2. **Штатный `pacstrap -N` (вложенный unshare) зависает.**
   `pacstrap -N` (стоковый `unshare_setup`) завис более чем на
   10 минут без вывода: процесс `unshare --fork --pid --mount
   --map-auto --map-root-user …` не продвинулся дальше создания
   неймспейса; убит по SIGTERM, следов не оставил. Дополнительно:
   `-N` сериализует всё окружение (`declare_all`) в командную
   строку дочернего процесса — в `ps` видны секреты окружения
   (токены/прокси-пароли). Путь `-N` НЕ используется.
3. **`arch-chroot` (стоковый) падал так же, как pacstrap.**
   Свежий mount sysfs в `chroot_setup`. Применён тот же
   двухстрочный патч (оригинал `arch-chroot.orig` сохранён),
   проверено: `arch-chroot <тестовый root> …` — OK.
4. **Диагностика упала из-за упоминаний другого проекта в новом скрипте.**
   `xros-diagnose.sh` запрещает `akvt|АКВТ` в `scripts/` (исключение
   для `build.sh` удалено 10.11.2026). Комментарии скрипта
   переписаны нейтрально («проверенная схема», «эталонный проект»);
   полная атрибуция — только здесь и в `ARCHITECTURE.md` §2 /
   `AUDIT-REPORT.md` §10 (корневые `.md`, диагностикой не сканируются).
   Диагностика после правки: PASS=217 FAIL=0 SKIP=11.
5. **`source profiledef.sh` падал с syntax error.**
   `file_permissions` — ассоциативный массив; без предварительного
   `declare -A file_permissions` bash парсит `["/etc/shadow"]="…"`
   как арифметический индекс. Добавлен `declare -A` до `source`
   + проверка непустоты массива.
6. **Латентный дефект: `file://`-репозиторий `[xros]` не виден при pacstrap.**
   pacman резолвит `file:///usr/share/xros/repo` относительно
   ХОСТА (build-env), а не нового корня — а снимок лежал только
   в `profile/airootfs` (внутри цели). Первая попытка полного
   pacstrap упала: `Could not open file /usr/share/xros/repo/xros/
   os/x86_64/xros.db`. Штатный mkarchiso упал бы точно так же.
   Исправление (профиль и живую систему не меняет): та же копия
   снимка кладётся в build-env по тому же пути
   `/usr/share/xros/repo` (шаг 4б скрипта).
7. **`/run` в chroot был read-only (555).**
   Bootstrap-тарболл поставляет `/run` с правами 555; arch-chroot/
   pacstrap биндят именно его, и `ufw default deny incoming`
   в customize падал на создании `/run/ufw.lock`. Политика при этом
   уже `DROP` по умолчанию пакета ufw, вреда не было. Исправлено:
   `chmod 755 build-env/run` (шаг 2б скрипта) — ближе к штатному
   хосту, где `/run` — tmpfs. После правки `ufw` в customize
   отработал без traceback.
8. **`mkinitcpio -P` возвращает 1 (PXE-хуки).**
   Отсутствуют helper-бинари `ipconfig`, `nbd-client`, `nfsmount`
   для хуков `archiso_pxe_*` — их нет в живой системе по дизайну
   профиля. Образ при этом создаётся полный, с archiso-хуками
   (та же картина была в эталонном проекте). Скрипт допускает
   exit 0/1, но ОБЯЗАТЕЛЬНО проверяет образ (существует, непустой,
   archiso-хуки на месте). Следствие: PXE-загрузка недоступна,
   обычная загрузка с ISO не затронута.
9. **`lsinitcpio` нет в build-env.**
   Проверка хуков перенесена внутрь chroot (`arch-chroot …
   lsinitcpio -a /boot/initramfs-linux.img`).
10. **Путь `/xros/work/…` недоступен внутри arch-chroot.**
    Список пакетов для проверки теперь кладётся внутрь airootfs
    (`/root/pacstrap-pkglist.txt`), результат — в
    `/root/missing-pkgs.txt`; оба файла удаляются после проверки.
11. **`check-iso.sh` давал ложный FAIL по `BOOTX64.EFI`.**
    Скрипт искал `/EFI/BOOT/BOOTX64.EFI` в дереве ISO9660, но
    mkarchiso 92 кладёт EFI-раздел ТОЛЬКО как appended partition 2
    (это же подтверждает заголовок `postprocess-bios-grub.sh`).
    Исправлено: `efi-bootx64` теперь извлекает appended раздел dd
    по интервалу из `xorriso -report_system_area` и проверяет
    `BOOTX64.EFI` внутри FAT-образа — `mdir`, если есть, иначе
    минимальным FAT-парсером на python3 (проверен отдельно),
    иначе SKIP. Дополнительно проверено вручную: в разделе
    `ARCHISO_EFI` (24 117 248 Б) лежат `BOOTX64.EFI` (8 155 136 Б)
    и `BOOTIA32.EFI` (6 537 216 Б).
12. **Хост потерял apt-пакеты после сброса ВМ.**
    В ходе работ хост лишился `xorriso` (а затем и
    `grub-script-check`) — `apt-get update` + переустановка
    (`xorriso 1.5.6`, `grub-common` с `grub-script-check 2.12`).
    Два зеркала `mirror.cogentco.com` (noble-updates/security)
    недоступны через прокси — `apt-get update` их пропустил
    с предупреждениями, установка прошла по остальным зеркалам.
    Долгосрочно: apt-пакеты хоста не переживают перезагрузку ВМ.

## 7. Версии инструментов

- Build-env (внутри rootfs): `pacman 7.1.0.r9.g54d9411-3`,
  `archiso 92-1`, `grub 2:2.16-1`, `squashfs-tools 4.7.5-1`,
  `libisoburn 1.5.8.2-1`, `rustc/cargo 1.99.1`.
- Хост: `xorriso 1.5.6`, `grub-script-check 2.12`, `python3 3.12.3`.
- Профиль: `bootmodes=('uefi.grub')`, `iso_label XROS_202611`,
  `iso_version 1.0`, `airootfs_image_type squashfs`
  (`zstd -Xcompression-level 15 -b 1M`).
- Пакеты в rootfs — из репозиториев Arch на момент 2026-11-10
  (ядро `7.2.15.arch1-1` и др., см. §5).

## 8. Структура гибридного ISO (проверено)

- BIOS El Torito: `/boot/grub/i386-pc/eltorito.img`
  (GRUB 2.16, `eltorito.img` 334 190 Б); гибридный MBR `grub2-mbr`.
- UEFI El Torito: appended partition 2 (`ARCHISO_EFI`, FAT,
  24 117 248 Б) с `/EFI/BOOT/BOOTX64.EFI` и `BOOTIA32.EFI`.
- `/boot/grub/grub.cfg`: тема `/boot/grub/theme/theme.txt`,
  фон `/boot/grub/grub-bg.jpg`, 6 пунктов меню (XrOS 1.0,
  speaking-вариант, Настройки UEFI, выключение, перезагрузка),
  кириллица на месте; `grub-script-check` — PASS.
- `/xros/boot/x86_64/vmlinuz-linux` и `initramfs-linux.img`;
  `airootfs.sfs` 1 551 566 608 Б; `pkglist.x86_64.txt`;
  `xros/version` = `1.0`. В дереве ISO нет `syslinux`
  (не возвращён) и нет `systemd-boot`.
- `xorriso -check_media` — код 0.

## 9. Ограничения обходной сборки (честно)

- Результат НЕ идентичен штатному побайтово: rootfs собран тем же
  pacstrap и тем же списком, но порядок операций и маркеры — ручные.
  Воспроизводимость — повторным прогоном
  `scripts/build-rootfs-pacstrap.sh --confirm` с тем же профилем;
  версии пакетов зависят от состояния репозиториев Arch на момент
  запуска (не зафиксированы снапшотом зеркал).
- Патч `chroot_setup()` — локальное изменение копий
  `arch-install-scripts` ВНУТРИ build-env
  (`build-env/root.x86_64/usr/bin/{pacstrap,arch-chroot}`, оригиналы
  `.orig` рядом). При `--reinit` build-env патч надо применить
  заново — скрипт проверяет его наличие и останавливается без него.
  Сами пакеты `arch-install-scripts` не пересобирались, подписи
  пакетов не трогались.
- PXE-загрузка недоступна (нет `ipconfig`/`nbd-client`/`nfsmount`
  в образе, §6 п. 8). Обычная загрузка с ISO/CD/USB не затронута.
- Репозиторий `[xros]` — заглушка `https://xros.example/repo`
  (домен не существует) + снимок `file:///usr/share/xros/repo`
  внутри системы; автообновления отключены; GPG-подписи репозитория
  нет (`SigLevel = Optional TrustAll` для `[xros]`, основные
  репозитории — `Required`). Публичного хостинга репозитория нет.
- Secure Boot НЕ поддерживается (нет подписанной цепочки).
- Live-ISO штатно — UEFI-only от mkarchiso; BIOS-загрузка добавлена
  постобработкой (проверена только структурно, см. §10).
- Полная GUI-установка на диск в QEMU НЕ проверена
  (отдельный этап).

## 10. Что НЕ проверено (следующие этапы)

- Загрузка ISO в QEMU: UEFI (OVMF), BIOS (SeaBIOS, CD и USB),
  Wayland-сессия Plasma в живой системе.
- Полная установка через графический установщик на диск
  и загрузка установленной системы.
- Проверка `akvt`-аналога не применима: это XrOS, отдельный проект.

## 11. Логи и файлы

- `scripts/build-rootfs-pacstrap.sh` — скрипт обхода.
- `out/pacstrap-build.log` — полный лог подготовки rootfs
  (все 5 запусков, включая неудачные, — история отладки).
- `out/mkarchiso.log` — первая (прерванная) попытка mkarchiso.
- `out/mkarchiso2.log` — успешный mkarchiso (exit 0, 0 ERROR).
- `out/postprocess.log` — постобработка BIOS-GRUB (exit 0).
- `out/xros-1.0-x86_64-hybrid.iso.postprocess.log` — то же,
  рядом с ISO.
- `out/check-iso.log` — гибридный ISO: 12/0/0.
- `out/check-iso-plain.log` — ISO от mkarchiso: 9/3 (3 — BIOS).
- `out/diagnose.log` — 217/0/11.
- `out/SHA256SUMS` — SHA256 обоих ISO.
- `out/prev-logs-20261110-*/` — архивы логов неудачных попыток.
- `work/` — rootfs + маркеры `base.*` + `iso/xros/version` +
  `installed-pkgs.txt` (645) + `pacstrap-pkglist.txt` (46).
- Резервная копия проекта НЕ тронута:
  `~/workspace/xros-backups/xros-20261110-stage10-prep`.
