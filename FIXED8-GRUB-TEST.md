# fixed8 — результат QEMU-теста GRUB (UEFI), 11.11.2026

## Вывод одной строкой

**GRUB-меню fixed8 — FAIL**: литерал «@TIMEOUT_NOTIFICATION_SHORT@».
Исправлено в fixed9 (`%d`-шаблон; точный механизм — по исходнику GRUB).

## Прогон

- Запуск: `fixed8-uefi-live`, UEFI, GRUB mode, nodisk, std VGA,
  гибридный ISO fixed8 (`9948646d…`), QEMU -m 2048 -smp 2, TCG.
- Старт 05:02:37 UTC; GRUB-кадр grub1 — ~05:02:45 UTC.
- ВМ остановлена сразу после кадра GRUB (Live-стол fixed8 не
  тестировался: кроме текста темы он идентичен fixed7, стол
  fixed7 — PASS).

## GRUB — FAIL

- Меню: «XrOS 1.0 (x86 64, UEFI)», «XrOS 1.0 — с диктором»,
  «Настройки UEFI», «Выключить компьютер», «Перезагрузить компьютер».
- Футер: **«Автозагрузка через @TIMEOUT_NOTIFICATION_SHORT@»** — литерал.
- Точный механизм (исходник GRUB, `grub-core/gfxmenu/gui_progress_bar.c`,
  `progress_bar_set_property()`, строки 626–666):
  плейсхолдеры `@TIMEOUT_NOTIFICATION_LONG@` / `_MIDDLE@` / `_SHORT@`
  сравниваются через `grub_strcmp` СО ВСЕМ значением `text`
  (точное совпадение), а не как подстрока. Встроенный в длинную
  строку плейсхолдер НЕ подставляется никогда.
- Правильный механизм (тот же файл, `draw_text()`, строки 362–416):
  `text` — это printf-шаблон, `grub_xasprintf(template, |value|)` —
  `%d` заменяется на секунды до автозагрузки (value = остаток
  таймаута). Поэтому fixed9: `text = "Автозагрузка через %d с"` —
  рендерится «Автозагрузка через 7 с».
- Проверки диагностики исправлены (§7з и §15: требуют `%d`-шаблон,
  запрещают любой литерал `@...@` в строках `text =`).
  Диагностика fixed9: PASS=245 FAIL=0 SKIP=11.

## Скриншоты

`experiments/qemu-stage10/screenshots/fixed8-uefi-live-grub1.png`
(меню + литерал @TIMEOUT_NOTIFICATION_SHORT@).
