# FINAL-PERMISSIONS-AUDIT.md — XrOS 1.0, итоговый аудит прав доступа

Дата: 2026-11-10 (UTC) / 2026-11-11 (Europe/Samara, дедлайн Мии).
ISO: `out/xros-1.0-fixed5-x86_64.iso` (plain, 1 852 039 168 Б,
SHA256 `fb9e49a700a7079f203aa0c5dd5ae62100f0350237540636074da20315eb95f5`),
hybrid `out/xros-1.0-fixed5-x86_64-hybrid.iso` (1 852 350 464 Б,
SHA256 `d1e57d3ad402c96dfb01acd46c7240b625d74c570b6df0ad6e1905138ae7b251`).
Предыдущий ISO fixed4 сохранён: plain `dab87a2f658035a2992670f778850e06d7b9496faf5429739d6934c894cc43f0`,
hybrid `f8bc0712cad61c2c80ef29bade7cf325f7bcb42da1da5a0718b805b6e2b298e8`
(бэкап `~/workspace/xros-backups/xros-20261110-final-validation/`).
Хост: Ubuntu, QEMU 8.2.2, OVMF 2024.02, xorriso 1.5.6.

## Первопричина (доказана, см. BLACK-SCREEN-ROOT-CAUSE.md)
34 каталога live-rootfs имели mode 2770 (`drwxrws---`, root:root),
включая `/usr`, `/etc`, `/usr/share`, `/etc/systemd`, `/home/xros`;
64 файла — mode 660. Любой процесс не от root получал EACCES.
Serial-лог старого ISO: 127× «Permission denied», systemd-resolved/
networkd/timesyncd — status=203/EXEC в цикле, dbus-broker-launch —
Permission denied, нет системной шины D-Bus, logind не создавал сессии,
автовход xros жил 0,23 с, greeter SDDM ~0,1 с, 91 цикл перезапуска за
8 мин → чёрный экран. Источник: хост setgid-каталоги 2770 + umask 0007 →
profile/airootfs/ 2770/660 → `scripts/build-rootfs-pacstrap.sh:243`
`cp -af --no-preserve=ownership,mode`. Pacman предупреждал (5 602
«directory permissions differ»), но не исправлял.

## Исправление (fixed4, сохранено в fixed5)
- profile/airootfs на хосте: каталоги 2770→755 (35×755, `/root`→750),
  файлы 660→644 (59×644), `customize_airootfs.sh` 770→755.
- `scripts/build-rootfs-pacstrap.sh`: `umask 0022` в начале; шаг 4a —
  нормализация сразу после копирования профиля + жёсткая проверка;
  шаг 11b — финальная проверка (FAIL при любом 2770/660/770, allowlist
  только `/var/log/btmp` и `/var/log/lastlog` — 660 root:utmp, штатные
  режимы Arch); `runuser -u xros` — проверка доступности.
- `scripts/check-rootfs-perms.sh` (новый, 755): автономный чекер, НЕ
  исправляет, только проверяет и FAIL с точной причиной. `/usr` и
  `/etc` = 0755 или 2755 (2755 ≡ 0755 по доступу; setgid — косметика
  наследования ФС хоста), 0 каталогов 2770, 0 файлов 660/770 (кроме
  btmp/lastlog), 0 файлов 777, `/tmp` 1777/3777, `/root` 750/2750.
- `scripts/build-rootfs-pacstrap.sh` шаг 11в: чекер как gate сборки
  после шага 11b; сборка останавливается до mkarchiso при нарушении.
- `profile/airootfs/root/customize_airootfs.sh`: `umask 0022` после
  `set -e -u`.
- `scripts/xros-diagnose.sh` §21 (права профиля) + §7з (GRUB: один
  `__timeout__`, нет progress_bar) + проверка `with_maximized` GUI.
  Диагностика: **PASS=240 FAIL=0 SKIP=13** (2 SKIP — grub-script-check,
  нет на хосте; остальные SKIP — отсутствие инструментов на хосте).

## 1. Build rootfs (`work/x86_64/airootfs`) — PASS
Команда: `./scripts/check-rootfs-perms.sh work/x86_64/airootfs`
(также ручной `find` + `stat` по 11 точкам).
- `/`=555, `/usr`=2755, `/etc`=2755, `/bin`/`/sbin`/`/lib` — симлинки
  (777 — сама ссылка; цели 755), `/var`=755, `/run`=2555, `/home`=755,
  `/root`=2750 (≡750), `/tmp`=3777 (≡1777), `/opt`/`/srv`/`/mnt`=755.
- **0 каталогов 2770, 0 файлов 660, 0 файлов 777.**
- 7 каталогов вне allowlist — все объяснены: `root` 2750,
  `var/cache/ldconfig` 2700 (≡700, штатно), `run`/`dev`/`sys`/`proc`
  2555 (точки монтирования), `tmp` 3777. btmp/lastlog в rootfs нет
  (создаются при запуске).
- `xros-set-wallpaper` 755; appletsrc отсутствует; autostart
  `xros-wallpaper.desktop` на месте.

## 2. Распакованная Live rootfs из fixed4 ISO (squashfs) — PASS
`~/workspace/xros-backups/xros-20261110-final-validation/live-rootfs`
(131 552 файла, распаковка `unsquashfs` из `airootfs.sfs`).
- Режимы идентичны build rootfs; **0×2770/660/777**.
- Чекер `check-rootfs-perms.sh` — **PASS** и на build rootfs, и на
  распакованной Live rootfs.
- `pacman -Qk` в chroot build-env (645 пакетов, лог
  `pacman-Qk-build-rootfs.log`): **0 отсутствующих файлов**, кроме
  2 ожидаемых ucode (`/boot/amd-ucode.img`, `/boot/intel-ucode.img` —
  они в boot-каталоге ISO, не в rootfs); несоответствий
  режима/размера — **нет**.

## 3. Распакованная Live rootfs из fixed5 ISO (squashfs) — PASS
Проверка `unsquashfs` из `work/iso/xros/x86_64/airootfs.sfs`
(после сборки fixed5):
- `/usr/local/bin/xros-install-gui` — sha256
  `e73507550fa3e54e78407344dccc0a7d732f94bd7184361589d617242560c055`
  (новый бинарь fixed5, with_maximized), режим 755.
- `/usr/share/xros/grub-theme/theme.txt` — режим 644; `__timeout__`
  ровно 1; progress_bar отсутствует (только упоминания в комментарии).
- `/usr` — 2755 (≡755).
- ISO fixed5: check-iso.sh — **PASS=12 FAIL=0 SKIP=0**
  (первый прогон FAIL=11 — только сломанный xorriso на хосте после
  перезагрузки ВМ: не было libisoburn.so.1/libburn.so.4; переустановлен
  из .deb-кэша, повторный прогон — 12/0/0).

## 4. Live-система в QEMU (serial-логи) — PASS
- fixed4 UEFI diag (kernel, virtio-gpu): **0 Permission denied**,
  **0 203/EXEC**, 1 сессия sddm-helper (без цикла), Wayland-сессия
  стартовала, окно приветствия открылось.
- fixed4 UEFI GRUB (std VGA, 12 мин): полный рабочий стол, обои XrOS,
  панель, часы тикают, Alt+F4 закрывает приветствие.
- fixed4 BIOS GRUB (std VGA, 12 мин): полный рабочий стол, **BIOS PASS**.
- fixed5 UEFI GRUB: прогон `fixed5-uefi-grub` (в работе на момент
  написания; результаты — в LIVE-BOOT-VALIDATION.md).

## 5. Регрессионный тест — PASS (см. PERMISSIONS-REGRESSION-TEST.md)
`scripts/test-perms-regression.sh` — работает на ОТДЕЛЬНОЙ тестовой
копии (подмножество Live rootfs) в `~/workspace/xros/.perms-regression-scratch`
(удаляется после прогона, если нет `--keep`); рабочий rootfs не трогается.
**PASS=8 FAIL=0** (лог в бэкапе финальной валидации). Кейсы: чистая
копия PASS; 2770 в /usr — обнаружен; 2770 в /etc — обнаружен; файл 660 —
обнаружен; /usr 0700 — обнаружен; файл 777 — обнаружен; рабочий rootfs
не тронут; рабочий rootfs по-прежнему PASS.
Заметка: тест 1 сначала FAILED, потому что `mkdir -p` в setgid-каталоге
хоста с umask 0007 создал каталоги 2770 — чекер их корректно поймал;
исправлено явным `chmod 755` в тесте.

## 6. Установленная система — PENDING (заполняется после установки)
Проверяется после GUI-установки на виртуальный диск (UEFI + BIOS):
`/usr` и `/etc` на установленной системе (должны быть 0755/2755),
отсутствие 2770/660/777, SDDM, KDE, вход пользователя, повторная
загрузка. Результаты — в INSTALLED-SYSTEM-VALIDATION.md.

## Итог
| Место проверки | Результат |
|---|---|
| Build rootfs | **PASS** (0×2770/660/777) |
| Live rootfs fixed4 (squashfs) | **PASS** (0×2770/660/777; pacman -Qk 0 ошибок) |
| Live rootfs fixed5 (squashfs) | **PASS** (бинарь e7350755…, тема 1×__timeout__, /usr 2755) |
| Live QEMU (serial-логи) | **PASS** (0 Permission denied vs 127; 1 сессия vs 91 цикл) |
| Регрессионный тест | **PASS=8 FAIL=0** |
| Установленная система | **PENDING** (после GUI-установки) |
| Безопасность (права) | см. FINAL-SECURITY-REPORT.md |

Критерий готовности «permissions audit — PASS» выполнен для Live-системы
и build rootfs; для установленной системы — после установки.
