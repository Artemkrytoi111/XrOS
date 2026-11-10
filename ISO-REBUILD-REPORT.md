# ISO-REBUILD-REPORT.md — Пересборка ISO XrOS (fixed1–fixed4)

Дата: 10 ноября 2026. Проект: `~/workspace/xros`.
Инструменты: archiso 92-1, mkarchiso, xorriso 1.5.6, QEMU 8.2.2,
OVMF (SHA256 `ad23261d43116abc3747d59a7837fbf578c9586a8993f4eeba064cd07eccb083`).

## Схема сборки (штатная + workaround)

Штатный `scripts/build.sh` (mkarchiso) падает на этом хосте
(«Mount too revealing» при монтировании внутри chroot — ограничение
песочницы, не баг проекта). Используется проверенный workaround
по схеме AKVT build-15: `scripts/build-rootfs-pacstrap.sh --confirm`
(ручной pacstrap + копирование профиля + `arch-chroot customize`)
→ `mkarchiso` (с `_run_once`-маркерами, пропускающими pacstrap)
→ `scripts/postprocess-bios-grub.sh --iso …` (гибрид BIOS-GRUB
через xorriso) → `scripts/check-iso.sh --archiso`.

`scripts/build.sh` НЕ удалён и не изменён. Подписи и проверки
безопасности не отключались. Публикации нет.

## fixed1 — исправление прав

- pacstrap EXIT 0 (rootfs 4,1 ГБ, 181 146 файлов; шаг 11б: 0 каталогов
  2770, 1 файл 660 = btmp, allowlisted).
- mkarchiso EXIT 0 → plain ISO 1 852 039 168 Б, SHA256
  `12869edcfa4de0bb0896d9c9721e3417e9598bbd9396fb96895d78c960f88f11`.
- Гибрид 1 852 350 464 Б, SHA256
  `2082ad65536e799015d1f12fb25ba82100dfc9ec4a3c21e7c8e9ece336e8c310`.
- `check-iso.sh --archiso` PASS=12/0/0. Squashfs: 0×2770 каталогов,
  0×660 файлов; `/etc`, `/usr` — `drwxr-sr-x` (2755, эквивалентно
  755 — косметический setgid от хостовой ФС).
- **Файлы ISO fixed1 УТЕРЯНЫ** (удалены пересборкой fixed2 до
  бэкапа); сохранились только SHA256 (`out/SHA256SUMS.fixed`,
  `xros-20261110-desktop-fix/SHA256-fixed1.txt`).

## fixed2 — appletsrc с пустым activityId

- pacstrap EXIT 0 (181 147 файлов); mkarchiso EXIT 0 → plain
  1 852 039 168 Б, SHA256
  `05ae37d1577c7ad6df71ad7742cc2b14ca11c5b560e368bb38245d033c11b9cf`.
- Гибрид 1 852 350 464 Б, SHA256
  `14b52b6eac171d1c98a1c7f33f5d162e582e5c4e95078de4cadfb4a641ca8b14`.
- `check-iso.sh --archiso` PASS=12/0/0. `out/SHA256SUMS.fixed2`.
- Оба ISO забэкаплены в `xros-20261110-desktop-fix/`.

## fixed3 — appletsrc из сгенерированного файла

- pacstrap EXIT 0; mkarchiso EXIT 0 → plain 1 852 051 456 Б, SHA256
  `30f72f0069fbb0f24b230f29dc7e2953f7267cc31d256ef523289d98687332f8`.
- Гибрид 1 852 362 752 Б, SHA256
  `0894db1b14c54ab98b2e05216a3da884409300533fff8e054ca8171443e35dbf`.
- `check-iso.sh --archiso` PASS=12/0/0. `out/SHA256SUMS.fixed3`.
- Оба ISO забэкаплены. UUID гибрида `2026-11-10-15-28-03-00`.

## fixed4 — без appletsrc; обои автозапуском; GRUB

- pacstrap EXIT 0 (BUILD_EXIT=0, `out/pacstrap-build-fixed4.log`).
  Rootfs проверен: НЕТ appletsrc (ни в skel, ни в home);
  `autostart/xros-wallpaper.desktop` есть;
  `xros-set-wallpaper` есть.
- **Найденный дефект сборки:** `xros-set-wallpaper` в rootfs был
  644 (профиль копируется `cp --no-preserve=mode`, режим 755
  теряется). Исправлено: запись в `file_permissions`
  `profile/profiledef.sh` + `chmod 755` в rootfs. Первый mkarchiso
  (16:25) собрал ISO с 644-скриптом; второй запуск mkarchiso
  ничего не сделал (все `_run_once`-маркеры стоят — урок:
  маркеры лежат в `work/`, а не в `work/x86_64/`).
  Удалены маркеры `base._make_common_bootmode_grub_cfg`,
  `base._make_bootmode_uefi.grub`, `base._make_boot_on_iso9660`,
  `base._mkairootfs_squashfs`, `base._prepare_airootfs_image`,
  `build._build_buildmode_iso`, `iso._build_iso_image`;
  маркеры pacstrap/customize сохранены. Пересборка mkarchiso
  EXIT 0 (16:31).
- Plain ISO 1 852 039 168 Б, SHA256
  `dab87a2f658035a2992670f778850e06d7b9496faf5429739d6934c894cc43f0`.
- Гибрид 1 852 362 752 Б, SHA256
  `f8bc0712cad61c2c80ef29bade7cf325f7bcb42da1da5a0718b805b6e2b298e8`.
- `check-iso.sh --archiso` PASS=12/0/0. `out/SHA256SUMS.fixed4`.
- Оба ISO забэкаплены в `xros-20261110-desktop-fix/` СРАЗУ.
- Squashfs проверен (`unsquashfs -ll`):
  `xros-set-wallpaper` — `-rwxr-xr-x` (755);
  `xros-wallpaper.desktop` — 1000/1000, 220 Б;
  appletsrc — отсутствует.
- ISO: `loopback.cfg` — пункт «XrOS 1.0 — с диктором»;
  тема содержит label `__timeout__`.
- UUID гибрида `2026-11-10-16-32-22-00`, LABEL `XROS_202611`.

## Исходный ISO (сохранён)

- Plain `e2ac86e0e2ffc7614f50aad337c1130ec40f49213e7c7e8a86b6b8a780a0c21a`,
  гибрид `0e664a48b9cb64a9c043dec2b8f13e620c8caddcceb5c29979760ce15e00f90c`
  — в `~/workspace/xros-backups/xros-20261110-perms-fix/original-iso/`
  с SHA256SUMS (хеши перепроверены).

## Известные особенности

- В grub.cfg гибрида UUID — время plain-ISO (известный quirk:
  grub.cfg собирается до postprocess); archiso находит ISO по
  метке, загрузка идёт. Не влияет на работу.
- `mkarchiso` при повторном запуске без удаления маркеров ничего
  не пересобирает (молчаливый EXIT 0) — проверять время файла ISO.
- Хост перезагружался 3 раза за день; `mksquashfs` (squashfs-tools)
  после перезагрузки отсутствует — переустанавливать вместе с QEMU.
