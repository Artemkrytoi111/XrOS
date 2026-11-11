# fixed6 Live — результат воспроизведения (repro), 11.11.2026

## Вывод одной строкой

**Регрессия fixed6 «чёрный Live-стол» НЕ воспроизвелась.**
На этой загрузке fixed6 Live-стол работает ПОЛНОСТЬЮ
(обои + панель + часы + окно приветствия + значок «Установить XrOS»).
Drop-in `10-kactivitymanagerd.conf` как причина чёрного стола
**оправдан**: юнит активен С drop-in, и стол при этом работает.
Причина чёрного стола у ночного агента — разовый тайминг-флейк
под медленным TCG, а не детерминированный дефект drop-in.

## Прогон

- Запуск: `fixed6-uefi-repro`, UEFI, GRUB mode, nodisk, std VGA,
  гибридный ISO fixed6 (`4c7cb6b7…`), QEMU -m 2048 -smp 2, TCG.
- Старт 03:48:27 UTC; скриншот boot9 — 03:56:20 UTC
  (окно «Добро пожаловать в XrOS!» открыто, фиолетовые обои видны).
- После Alt+F4: чистый стол с фиолетовыми обоями.
- Панель появилась НЕ сразу: в кадре desktop1 её ещё не было,
  в кадре konsole1 (~04:05 UTC, ~10 мин после старта) панель
  на месте (Kickoff, таск-менеджер, трей, часы 07:56).
- Значок «Установить XrOS» на столе появился ещё позже
  (кадр ps3, ~04:07 UTC). **Вывод: под TCG загрузка стола
  занимает ~10 мин; объявлять «чёрный стол» раньше нельзя.**

## Диагностика внутри живой системы (Konsole, Ctrl+Alt+T)

| Проверка | Результат |
|---|---|
| `pgrep -a plasmashell` | `723 /usr/bin/plasmashell --no-respawn` |
| `ps -o pid,ppid,etime,time,comm -p 723` | PID 723, PPID 640 (systemd --user), ELAPSED 06:03, TIME 00:03:15 |
| `pgrep -af kactivitymanagerd` | `758 /usr/lib/kactivitymanagerd` |
| `systemctl --user show plasma-plasmashell.service -p ActiveState -p SubState -p DropInPaths` | `ActiveState=active`, `SubState=running`, `DropInPaths=/etc/systemd/user/plasma-plasmashell.service.d/10-kactivitymanagerd.conf` |

- plasmashell: 3 мин 15 с CPU за 6 мин 03 с работы (~54% одного
  ядра) — тяжёлый софтверный рендер под TCG/llvmpipe, НЕ tight loop
  (у ночного агента было 4:22 CPU — тот же порядок).
- `systemctl --user` в Live РАБОТАЕТ и видит юнит с drop-in.
  Ошибка ночного агента «Unit plasma-plasmashell.service not found»
  не воспроизвелась (вероятно, он запускал systemctl не в сессии
  пользователя или опечатался) — дефектом не считается.
- `pgrep kactivitymanagerd` без `-f` даёт ноль совпадений
  (имя длиннее 15 символов) — использовать `pgrep -af`.

## Ловушка стенда (важно для следующих агентов)

- `typeq.py`: токен `<enter>` НЕ работает — скрипт шлёт текст
  токена как есть в QEMU sendkey, а у QEMU клавиша Return
  называется `ret`, не `enter`. Использовать **`<ret>`**,
  `<tab>`, `<esc>`. Докстринг typeq.py врёт — исправлен в fixed7.
- Клавиши через typeq.py доходят с задержкой 0.25 с/клавиша;
  Konsole открывается не сразу (первый Ctrl+Alt+T дал окно
  только через ~15 с — открылось ДВА окна).
- Клики мыши в QEMU в Wayland-госте не регистрируются
  (ограничение стенда, подтверждено ночным агентом).

## Что это значит для fixed7

1. Drop-in НЕ откатываем: он работает и в Live, и (через rsync
   движка, `src/xros-install:746`, excludes без /etc/systemd/user)
   попадёт в установленную систему. Установленная система ночного
   агента гонку ловила потому, что ставилась из **fixed5**
   (без drop-in), а не из fixed6.
2. fixed7 добавляет к drop-in надёжное ожидание готовности
   ActivityManager по шине (`ExecStartPre` + `TimeoutStartSec=120s`),
   потому что `After=` для `Type=simple` гарантирует только
   порядок fork'а, а не готовность bus-name (разрыв 27 с
   в установленной системе fixed5 — доказан журналом).
3. Тема GRUB progress_bar (fixed6) уже стоит в обоих theme.txt;
   её работа в установленной системе проверяется повторной
   установкой из fixed7 (ночной агент ставил из fixed5 с label-формой).
4. Тест Live-стола: ждать не менее 15 мин до вердикта
   «чёрный стол» — панель и значки под TCG появляются поздно.

## Скриншоты (доказательства)

`experiments/qemu-stage10/screenshots/fixed6-uefi-repro-repro-*.png`:
boot9 (приветствие + обои), desktop1 (чистый стол), konsole1/konsole2
(панель + часы 07:56), ps4 (plasmashell 723), ps6 (kactivitymanagerd
758), ps8 (ActiveState=active, SubState=running, DropInPaths=…conf).
