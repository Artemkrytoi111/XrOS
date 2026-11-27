# XrOS DE=none — состав пакетов («Без графики»)

Дата: 2026-11-27. Версия: 1.1beta (main, коммит 15394ed).
Проверка: `scripts/xros-diagnose.sh` §20з, тест `scripts/tests/test-de-none.sh`
(67/0 в CI).

## Итог (эталонные цифры)

| Показатель | Пакетов |
|---|---|
| Установлено в живой системе (`pacman -Q`) | 644 |
| Удаляется при DE=none | 211 |
| Остаётся после чистки | 433 |

211 + 433 = 644.

> Примечание о происхождении цифр: 644/211/433 — эталонные значения замера
> на живой системе 1.0 Diamond, зафиксированные в проверке diagnose §20з.
> При сборке ISO 1.1beta их нужно перемерить (`pacman -Q` на живой системе
> до и после чистки DE=none) и обновить этот отчёт и проверку.

## Что удаляется (211)

- 15 именованных графических пакетов из `XROS_GRAPHICS_PKGS`
  (движок `src/xros-install`):
  `plasma-desktop plasma-nm plasma-pa kscreen sddm konsole dolphin pipewire
  pipewire-pulse wireplumber xorg-server ttf-dejavu noto-fonts python-pyqt6
  libxkbcommon-x11`
- 196 осиротевших зависимостей — выведено арифметикой (211 − 15);
  удаляются чисткой `pacman -Qtdq` в ветке `none` движка.
  Точное число сирот перемерить при сборке 1.1beta.

## Что остаётся (433)

Консольная база `XROS_CONSOLE_BASE_PKGS` (движок):
`linux grub networkmanager sudo openssh` — проверяется после чистки
(`pacman -Q`). Менеджер входа не ставится (`DE_DM=""`), цель по умолчанию —
`multi-user.target`.

## Проверяемые факты из репозитория (2026-11-27, main @15394ed)

- `profile/packages.x86_64`: 69 пакетов в списке живой системы.
- Все 15 пакетов из `XROS_GRAPHICS_PKGS` присутствуют в живой системе.
- Вариантов DE — 7 (`kde gnome xfce cinnamon sway i3 none`), в GUI и в
  движке совпадают.
- DE=none: `DE_PKGS=""`, `DE_DM=""` (графика через `pacman -S` не ставится).
- Тест `test-de-none.sh`: 67/0 в CI.

## Как работает DE=none (движок)

1. Ветка `none` в `run_install`: графика не ставится (`DE_PKGS=""`).
2. Удаляется список `XROS_GRAPHICS_PKGS` (15 пакетов).
3. Чистка сирот: `pacman -Qtdq` (осиротевшие зависимости графики).
4. Проверка: базовая консольная система на месте (`pacman -Q` по
   `XROS_CONSOLE_BASE_PKGS`).
5. DM не включается, цель — `multi-user.target`.
