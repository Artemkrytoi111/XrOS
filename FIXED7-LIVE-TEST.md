# fixed7 Live — результат QEMU-теста (UEFI), 11.11.2026

## Вывод одной строкой

**Live-стол fixed7 РАБОТАЕТ полностью** (обои + панель + приветствие +
значок «Установить XrOS», 17+ мин стабильности, гонки plasmashell нет).
**GRUB-меню fixed7 — FAIL**: литерал «@TIMEOUT@» (дефект fixed6,
исправлен в fixed8 исходниках, ISO fixed8 не собран на момент теста).

## Прогон

- Запуск: `fixed7-uefi-live`, UEFI, GRUB mode, nodisk, std VGA,
  гибридный ISO fixed7 (`f8094a1b…`), QEMU -m 2048 -smp 2, TCG.
- Старт 04:31:38 UTC; GRUB-кадр grub1 — ~04:31:45 UTC;
  boot1 (systemd) — 04:33:20 UTC; boot2 (чёрный экран + курсор,
  сессия стартует) — 04:37:36 UTC; boot3 (стол + приветствие) —
  04:41:43 UTC (~10 мин); stable17 — 04:48:22 UTC (~17 мин).

## GRUB — FAIL (единственный дефект fixed7)

- Меню: «XrOS 1.0 (x86 64, UEFI)», «XrOS 1.0 — с диктором»,
  «Настройки UEFI», «Выключить компьютер», «Перезагрузить компьютер».
- Футер: **«Автозагрузка через @TIMEOUT@ с»** — литерал.
- Причина: предположение fixed6 неверно — GRUB 2.16 НЕ подставляет
  `@TIMEOUT@` нигде. Доказательство: `strings gfxmenu.mod` содержит
  только `__timeout__` и `@TIMEOUT_NOTIFICATION_LONG@` / `_MIDDLE@` /
  `_SHORT@` (LONG — "The highlighted entry will be executed
  automatically in %ds.", MIDDLE — "%ds remaining.", SHORT — "%ds").
- Исправление (fixed8, коммиты 866c8e3 + f2ab9d8): текст темы —
  «Автозагрузка через @TIMEOUT_NOTIFICATION_SHORT@»
  (рендерится «Автозагрузка через 7s») в обоих theme.txt
  (ISO GRUB + Live/установленная), проверка §7з исправлена
  (старая ТРЕБОВАЛА литерал @TIMEOUT@), новая проверка §15
  запрещает литерал в строках `text =`. Диагностика fixed8:
  PASS=245 FAIL=0 SKIP=11.

## Live-стол — PASS

- Фиолетовые обои (волны XrOS), значок «Установить XrOS»,
  окно «Добро пожаловать в XrOS!» (логотип X, «Запустить установщик»,
  «О системе», «Закрыть», «Запускать при старте» включён),
  панель снизу (Kickoff, таск-менеджер, трей, часы 08:41–08:48,
  11.11.2026). Панель появилась СРАЗУ с приветствием (в fixed6-repro
  панель догружалась ~10 мин после приветствия).
- Стабильность: 17+ мин, стол не падал, Konsole работает.

## Проверка фикса гонки Plasma (внутри Live, Konsole)

| Проверка | Результат |
|---|---|
| `ls -l /usr/local/bin/xros-wait-kactivitymanagerd` | `-rwxr-xr-x 1 root root 1843` (755 — file_permissions сработал) |
| `systemctl --user show plasma-plasmashell.service -p ActiveState -p SubState -p DropInPaths` | `ActiveState=active`, `DropInPaths=/etc/systemd/user/plasma-plasmashell.service.d/10-kactivitymanagerd.conf` |
| `journalctl --user -b -g Aborting --no-pager` | `-- No entries --` (аборта нет) |
| `pgrep -a plasmashell` | `958 /usr/bin/plasmashell --no-respawn` |
| `pgrep -af kactivitymanagerd` | `967 /usr/lib/kactivitymanagerd` |

- Вывод: ExecStartPre-ожидание + drop-in загружены, plasmashell
  стартовал без аборта, ActivityManager на месте. Гонка в Live
  не воспроизвелась ни разу (fixed6-repro + fixed7).
- Оговорка: Live-тест — одна загрузка; надёжность фикса в
  установленной системе проверяется установкой из fixed8
  (там же — GRUB installed + ACPI shutdown).

## Скриншоты

`experiments/qemu-stage10/screenshots/fixed7-uefi-live-*.png`:
grub1 (меню + литерал @TIMEOUT@), boot1 (systemd), boot2
(чёрный + курсор), boot3 (стол + приветствие + панель),
konsole1/konsole2, check1/check2/check3 (диагностика),
stable17 (17 мин стабильности).
