# FIX-REPORT.md — Исправления XrOS (чёрный экран → рабочий стол)

Дата: 10 ноября 2026. Проект: `~/workspace/xros`. Автор: агент автономного
восстановления (subagent eb761b9c).

## 1. Первопричина чёрного экрана (подтверждена независимо)

Права доступа, не графика:

- 34 каталога в live-rootfs имели режим `2770` (`drwxrws---`, root:root),
  включая `/usr`, `/etc`, `/usr/share`, `/etc/systemd`, `/home/xros`;
  64 файла — режим `660`. Любой процесс не от root получал `EACCES`
  на `execve()`/`open()` под `/usr` и `/etc`.
- Доказательства (посчитано по serial-логам
  `experiments/qemu-stage10/logs/*-diag-20261110/serial.log`):
  127× «Permission denied»; `systemd-resolved`/`networkd`/`timesyncd` —
  `status=203/EXEC` в цикле; `dbus-broker-launch` → «Permission denied»
  → нет системной шины D-Bus; logind не создаёт сессии; автовход xros
  живёт 0,23 с; greeter SDDM живёт ~0,1 с, 91 цикл перезапуска за 8 мин.
  При этом systemd доходит до `graphical.target`, SDDM стартует,
  DRM/KMS исправны (bochs-drm, simpledrm, fb0).
- Происхождение: хост — setgid-каталоги 2770 + `umask 0007` →
  `profile/airootfs/` 2770/660 → `scripts/build-rootfs-pacstrap.sh:243`
  копирует профиль командой `cp -af --no-preserve=ownership,mode` →
  pacman предупреждал (`out/pacstrap-build.log`, 5 602 предупреждения
  «directory permissions differ»), но не исправлял.
- Масштаб: установщик копирует живую систему через
  `rsync -aAX / "$TARGET"/` (`src/xros-install:739`) — установленная
  система унаследовала бы те же 2770.

## 2. Исправление прав (fixed1)

Бэкап: `~/workspace/xros-backups/xros-20261110-perms-fix/`
(исходные ISO + SHA256SUMS, `profile-airootfs-orig/`, `scripts-orig/`).

- Профиль на хосте: каталоги 2770→755 (35×755, `/root`→750),
  файлы 660→644 (59×644), `customize_airootfs.sh` 770→755.
- `scripts/build-rootfs-pacstrap.sh`: `umask 0022` в начале; шаг 4а —
  нормализация прав сразу после копирования профиля + жёсткая проверка;
  шаг 11б — финальная проверка (падение при любом оставшемся каталоге
  2770 или файле 660/770; allowlist: `/var/log/btmp`,
  `/var/log/lastlog` — 660 root:utmp, штатные режимы Arch);
  проверка доступности от пользователя xros (`runuser -u xros`).
- `profile/airootfs/root/customize_airootfs.sh`: `umask 0022` после
  `set -e -u`.
- `scripts/xros-diagnose.sh`: секция 21 (права профиля).
  Диагностика после исправления: PASS=223 FAIL=0 SKIP=11.

## 3. Дефект рабочего стола: ошибка виджета «» (fixed1)

После исправления прав SDDM стартует один раз (без цикла), сессия
xros открывается, Wayland стартует, `kwin_wayland` выбирает DRM,
приветствие работает. Но:

- Полноэкранная ошибка `error when loading applet ""`
  («Ошибка загрузки виджета: неверный формат пакета (отсутствуют
  метаданные)»), детерминированно в каждом прогоне.
- Нет панели: живой appletsrc содержал только `[Containments][1]`
  (рабочий стол) и `[Containments][2]` (папка, отключённый экран);
  секций `[Applets]` не было. Plasma 6 не создаёт панель сама,
  если appletsrc существует.
- Причина: в профиле было ДВЕ расходящиеся копии appletsrc —
  полная в `profile/airootfs/etc/skel/.config/` (879 Б: рабочий стол
  + папка + панель с kickoff/icontasks/systemtray/digitalclock)
  и МИНИМАЛЬНАЯ в heredoc `PLASMA_EOF` в `customize_airootfs.sh`
  (строки 71–83, только рабочий стол без папки и панели), которая
  перезаписывала skel-версию в `/home/xros/.config/`.
- Закрытые гипотезы: не отсутствующие пакеты виджетов (все плагины
  на месте: `kickoff.so`, `pager.so`, `showdesktop.so`,
  `digitalclock.so`, `systemtray.so` в
  `/usr/lib/qt6/plugins/plasma/applets/`, сверено с БД pacman и
  официальным списком файлов plasma-workspace 6.8.2-1); не два GPU
  (воспроизводится на одном); не Wayland-vs-X11 (Plasma 6.8 —
  только Wayland); не графика (KWin рисует, курсор и окна работают).

## 4. Дефект автоблокировки (найден 10.11.2026)

Plasma автоблокирует экран через 5 мин простоя
(`kscreenlocker_greet`). У живого пользователя `xros` заблокирован
пароль (`passwd -l`) — разблокировать сессию невозможно
(`pam_unix(kde:auth): authentication failure`). После 5 мин простоя
живая система становилась непригодной.
Исправление: `kscreenlockerrc` с `Autolock=false` +
`LockOnResume=false` ТОЛЬКО в `/home/xros/.config/` (не в
`/etc/skel` — в установленной системе блокировка штатная).
Проверено в fixed2: `kscreenlocker_greet` в логе отсутствует.

## 5. fixed2: зависание plasmashell/KWin (гипотеза пустого activityId — опровергнута)

Пересобранный appletsrc fixed2 (полный, но с ПУСТЫМ `activityId=`,
без `[Containments][2]`, без `[ScreenMapping]`, с комментариями `#`):

- Приветствие появилось (10:30), ошибки виджета нет, но панели
  и обоев нет к 12 мин; Alt+F2 не отвечает.
- plasmashell[817]: 09:14 CPU за 10:01 стены (>100%, спин),
  539 МБ; `kwin_wayland`: 90× «The main thread was hanging
  temporarily!»; рестарт plasmashell не помог.
- Живой appletsrc: `[Containments][1]` исчез, вместо него
  `[Containments][21]`/`[22]` (папки, новый activityId
  `3ad94196-a1c3-4084-a48a-32d658d4f5a2`); панель `[3]` сохранилась;
  секция `[Wallpaper]` потерялась. ID 21/22 совпадают с ID дочерних
  виджетов трея (battery=21, brightness=22) — предполагаемая коллизия.
- Решающий тест: удаление appletsrc + рестарт plasmashell в ТОЙ ЖЕ
  ВМ → ПОЛНЫЙ РАБОЧИЙ СТОЛ за ~110 с: обои Breeze, панель,
  часы 19:13, иконка «Установить XrOS», без ошибки
  (`fixed2-uefi-diag-no-appletsrc-test.png`).

## 6. fixed3: миграция происходит и с настоящим activityId

fixed3 (appletsrc из сгенерированного файла, настоящий
`activityId=3ad94196-a1c3-4084-a48a-32d658d4f5a2`, без
`[ScreenMapping]`, с `[Wallpaper]` XrOS):

- Приветствие в 7:30, ошибки нет, но рабочий стол чёрный;
  plasmashell[811] — 66% CPU, KWin зависает.
- Живой appletsrc: activityId снова НОВЫЙ
  (`aec83b14-c5c4-400d-96c3-5041ef2df568`), папки снова
  `[21]`/`[22]`, `[Wallpaper]` исчез. **Вывод: Plasma МИГРИРУЕТ
  любой поставляемый appletsrc независимо от activityId.**
  Пустой activityId был следствием миграции, а не причиной.
- Решающий тест (та же ВМ, корректный рестарт): удаление appletsrc
  → ПОЛНЫЙ РАБОЧИЙ СТОЛ: обои Breeze, панель, часы 20:01,
  иконка «Установить XrOS»
  (`fixed3-uefi-diag-no-appletsrc-retest2.png`).
- Обои XrOS через `plasma-apply-wallpaperimage
  /usr/share/xros/wallpaper.png` — РАБОТАЮТ
  (`fixed3-uefi-diag-wallpaper-test2.png`).
- Замечено: обои периодически «мерцают» в чёрный кадр и
  возвращаются (~20 с); клик по kickoff и Meta-клавиша меню
  не открыли в этой ВМ (возможно, TCG-медлительность / спин
  plasmashell ~65% CPU). Требует перепроверки на fixed4.

## 7. fixed4: appletsrc не поставляется; обои — автозапуском

- `profile/airootfs/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc`
  УДАЛЁН (бэкап: `xros-20261110-desktop-fix/appletsrc-skel-fixed3.txt`).
  `customize_airootfs.sh` его больше не копирует (блок заменён
  комментарием с объяснением + создание автозапуска обоев).
- Новый скрипт `profile/airootfs/usr/local/bin/xros-set-wallpaper`
  (755; запись в `file_permissions` в `profile/profiledef.sh` —
  без неё в rootfs он становился 644, найдено при сборке fixed4):
  retry `plasma-apply-wallpaperimage /usr/share/xros/wallpaper.png`
  до 30×3 с, после успеха удаляет свой autostart-файл.
- Автозапуск `/home/xros/.config/autostart/xros-wallpaper.desktop`
  создаётся в customize (только живой пользователь, НЕ в skel —
  в установленной системе обои не трогаются).
- Диагностика переписана: секция 22 требует ОТСУТСТВИЯ appletsrc
  + наличия скрипта обоев и его записи в file_permissions;
  добавлены проверки меню GRUB (7з). Итог: PASS=236 FAIL=0 SKIP=11.
- GRUB (stage 11): таймаут — отдельным `label` с `id="__timeout__"`
  (`@TIMEOUT@` в `text` у `progress_bar` GRUB не подставляет —
  на экране был литерал); пункт 2 сокращён до «XrOS 1.0 — с
  диктором» (был «…с экранным диктором (speaking)», обрезался до
  «(s»); исправлен также `loopback.cfg`. Тема синхронизирована:
  `profile/airootfs/usr/share/xros/grub-theme/theme.txt`.
  **Остаток stage 11 (не исправлено):** в fixed4 label с
  `id="__timeout__"` показывает литерал «@TIMEOUT@» — GRUB
  обновляет только ПЕРВЫЙ компонент с этим id (progress_bar,
  он заполняется), а текст label не подставляется; label
  перекрывается с полосой и футером. Требуется fixed5:
  убрать id у progress_bar (или убрать полосу), оставить
  `__timeout__` только у label, разнести позиции.

## 8. Потеря файлов fixed1 (урок процесса)

Пересборка pacstrap (шаг 1) УДАЛЯЕТ `out/xros-*.iso`. Файлы fixed1
были удалены пересборкой fixed2 до копирования в бэкап; сохранились
только их SHA256 (`out/SHA256SUMS.fixed`,
`xros-20261110-desktop-fix/SHA256-fixed1.txt`). Оригинальные ISO —
в `xros-20261110-perms-fix/original-iso/`. Урок: копировать ISO
в бэкап СРАЗУ после сборки, до любой пересборки. fixed2, fixed3,
fixed4 забэкаплены сразу.

## 9. Список изменённых файлов (diff — сводка)

- `scripts/build-rootfs-pacstrap.sh`: `umask 0022`; шаг 4а
  (нормализация + проверка прав профиля); шаг 11б (финальная
  проверка прав, allowlist btmp/lastlog); проверка `runuser -u xros`.
- `profile/airootfs/root/customize_airootfs.sh`: `umask 0022`;
  удалён heredoc `PLASMA_EOF` и копирование appletsrc; добавлен
  автозапуск обоев (live only); `kscreenlockerrc` (live only).
- `profile/airootfs/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc`:
  переписан в fixed2/fixed3, УДАЛЁН в fixed4.
- `profile/airootfs/usr/local/bin/xros-set-wallpaper`: новый (fixed4).
- `profile/profiledef.sh`: `file_permissions` +
  `["/usr/local/bin/xros-set-wallpaper"]="0:0:755"` (fixed4).
- `profile/grub/theme/theme.txt`: label `__timeout__` (fixed4);
  синхронизировано в
  `profile/airootfs/usr/share/xros/grub-theme/theme.txt`.
- `profile/grub/grub.cfg`, `profile/grub/loopback.cfg`: пункт 2
  «XrOS 1.0 — с диктором» (fixed4).
- `scripts/xros-diagnose.sh`: секции 21 (права), 22 (раскладка/
  обои), 7з (меню GRUB). Итог: PASS=236 FAIL=0 SKIP=11.
- `experiments/qemu-stage10/run-fixed.sh`,
  `extract-fixed-kernel.sh`: переключены на fixed4-гибрид.

## 10. Известные ограничения

- plasmashell под TCG крутит ~65% CPU (спин) даже на рабочем
  столе; на реальном железе / KVM ожидается ниже — не проверено.
- Обои периодически «мерцают» в чёрный кадр (~20 с) под TCG.
- Клик по kickoff / Meta-клавиша не открыли меню в тестовой ВМ
  fixed3-diag — перепроверить на fixed4.
- GRUB: литерал `@TIMEOUT@` в label (см. §7), требуется fixed5.
- Полная установка через GUI-инсталлятор в QEMU — не выполнена
  (см. INSTALLER-FINAL-REPORT.md — честный SKIP/частично).
- Хост перезагружался 3 раза за день (13:04, 14:49, ~16:46 UTC),
  каждый раз снося apt-пакеты QEMU/OVMF/xorriso — их приходится
  переустанавливать перед каждым прогоном.
