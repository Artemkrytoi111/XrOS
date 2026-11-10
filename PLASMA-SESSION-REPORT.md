# PLASMA-SESSION-REPORT.md — диагностика сессии KDE Plasma (XrOS 1.0)

Дата: 2026-11-10. Автор: агент автономного восстановления XrOS.
ISO: `out/xros-1.0-fixed-x86_64-hybrid.iso`
(SHA256 `2082ad65536e799015d1f12fb25ba82100dfc9ec4a3c21e7c8e9ece336e8c310`,
1 852 350 464 Б) — сборка с исправленными правами 2770/660.
QEMU 8.2.2 (Debian 1:8.2.2+ds-0ubuntu1.18), OVMF (SHA256
`ad23261d43116abc3747d59a7837fbf578c9586a8993f4eeba064cd07eccb083`),
SeaBIOS, xorriso 1.5.6. Гость: linux 7.2.15.arch1-1, plasma-desktop
6.8.2-1, sddm 0.21.0-7, kwin 6.8.2, Qt 6.9.x / KF6 6.31.0.

## Итог

| Проверка | Результат |
|---|---|
| Права 2770/660 исправлены (0× Permission denied, 0× 203/EXEC) | **PASS** |
| SDDM стартует 1 раз, без цикла перезапусков | **PASS** |
| Автовход xros, сессия Wayland открывается | **PASS** |
| kwin_wayland (DRM backend), курсор, окна | **PASS** |
| Окно приветствия XrOS (PyQt6) | **PASS** |
| Рабочий стол: обои + панель + иконки | **FAIL** (до исправления appletsrc, см. §3) |
| После удаления минимального appletsrc — панель, обои, без ошибки | **PASS** (живой эксперимент, §4) |

## 1. Что было исправлено до этого (контекст)

Первопричина чёрного экрана — права 2770/660 в live-rootfs
(подробно: `BLACK-SCREEN-ROOT-CAUSE.md`). После исправления
пересобранный ISO `xros-1.0-fixed-*` в QEMU даёт: 0×
«Permission denied» в serial-логе (было 127×), 0× `status=203/EXEC`,
D-Bus работает, SDDM стартует ровно 1 раз, сессия xros открывается
(гостевое время 193 с), `kwin_wayland` выбирает DRM backend (213 с),
сессия не закрывается. Это подтверждено в двух независимых прогонах
(`fixed-uefi-diag`, `fixed-uefi-diag2`, direct kernel boot, virtio-gpu)
и в прогоне через GRUB (`fixed-uefi-grub`, UEFI, std VGA, один GPU).

## 2. Новая проблема: ошибка виджета "" и отсутствие панели

### 2.1 Симптомы (воспроизводится в 3 прогонах: diag, diag2, grub)

- После открытия сессии — полноэкранный диалог ошибки виджета:
  «No error information.», «Ошибка загрузки виджета: неверный формат
  пакета (отсутствуют метаданные).», кнопка «Скопировать в буфер обмена».
- В журнале (serial log):
  `plasmashell[745]: error when loading applet "" QList("Ошибка
  загрузки виджета: неверный формат пакета (отсутствуют метаданные).", "")`,
  перед этим `QQmlComponent: Component is not ready`, после —
  `AppletError.qml:128:17: Unable to assign [undefined] to QString`.
- Диалог ошибки — на весь экран (это placeholder виджета, а не окно;
  Alt+F4 его не закрывает). За ним — чёрный рабочий стол без обоев,
  без панели, без иконок.
- Окно приветствия XrOS при этом работает нормально (логотип X,
  «Запустить установщик», «О системе», «Запускать при старте» ☑).
- Панель отсутствует полностью: в живом appletsrc только
  `[Containments][1]` (desktop) и `[Containments][2]` (folder,
  `lastScreen=1` — неактивный экран); секций `[Applets]` нет.

### 2.2 Что это НЕ такое (проверено, гипотезы закрыты)

- **Не отсутствие пакетов виджетов.** Все виджеты панели на месте:
  `kickoff.so`, `pager.so`, `showdesktop.so`, `digitalclock.so`,
  `systemtray.so`, `marginsseparator.so` —
  в `/usr/lib/qt6/plugins/plasma/applets/` (в Plasma 6.8 это C++-плагины,
  а не каталоги в `/usr/share/plasma/plasmoids/`); `icontasks` и `folder` —
  в `/usr/share/plasma/plasmoids/`. Проверено по pacman-базе
  (`plasma-workspace-6.8.2-1`, `plasma-desktop-6.8.2-1`) и сверено
  с официальным списком файлов plasma-workspace 6.8.2-1 на archlinux.org.
- **Не dual-GPU.** Ошибка воспроизводится и на одном GPU (GRUB-прогон,
  только std VGA, bochs-drm), и на двух (virtio-gpu + std VGA).
- **Не Wayland vs X11.** Plasma 6.8 — только Wayland
  (plasma-x11-session удалён из Arch); X11-тест — SKIP по дизайну.
- **Не графика/MESA.** KWin работает, курсор есть, окна рисуются;
  ошибки ZINK/EGL (`vkCreateInstance failed`, `failed to create dri2
  screen`) — только software-рендеринг fallback, см.
  `GRAPHICS-COMPATIBILITY-REPORT.md`.

### 2.3 Первопричина

Поставляемый appletsrc был минимальным: только `[Containments][1]`
(`plugin=org.kde.plasma.desktop`, обои) — без виджета папки и без
панели. Такой файл писал `customize_airootfs.sh` (heredoc `PLASMA_EOF`,
строки 71–83) в `/home/xros/.config/`, а затем **перезаписывал им же**
хорошую версию в `/etc/skel/.config/` (строка 88). Plasma 6.8 при
загрузке такого appletsrc пытается восстановить виджет с пустым именем
плагина (`applet ""`) — KPackage не находит метаданные — и показывает
полноэкранный placeholder ошибки вместо рабочего стола; панель не
создаётся, потому что в appletsrc её нет, а default layout не
применяется при наличии appletsrc.

Дополнительно: при двух GPU (virtio + std) Plasma создавала вторую
папку `[Containments][2]` на `lastScreen=1` (неактивный экран), и
иконка «Установить XrOS» попадала в `itemsOnDisabledScreens`
(`[ScreenMapping]`), то есть была невидима.

## 3. Доказательство: живой эксперимент (diag2, 10.11.2026)

В работающей ВМ (tty9, debug shell, root):

1. Остановлен `plasma-plasmashell.service`, удалён
   `/home/xros/.config/plasma-org.kde.plasma.desktop-appletsrc`
   (бэкап — `/tmp/appletsrc-minimal.bak`).
2. Запланирован отложенный перезапуск plasmashell (`sleep 5; systemctl
   --user start …`) + переключение на графический VT (`chvt 1`),
   чтобы у KWin были выходы при старте plasmashell.
3. Результат (скриншот
   `experiments/qemu-stage10/screenshots/fixed-uefi-diag2-default-layout-test.png`):
   **рабочий стол полностью работает** — обои Breeze, панель снизу
   (kickoff, pager, icontasks, systemtray, часы `18:03 10.11.2026`,
   showdesktop), окно приветствия, **ошибки виджета нет**.
   Plasma сгенерировала default layout из look-and-feel breezedark.
4. Сгенерированный appletsrc выгружен из живой системы
   (бэкап: `~/workspace/xros-backups/xros-20261110-desktop-fix/appletsrc-generated-live.txt`,
   148 строк) — он и стал основой исправления.

Контрольный отрицательный тест: перезапуск plasmashell при НЕактивном
графическом VT (tty9) даёт 3× SEGV в `libKF6ConfigCore.so.6.31.0`
(plasmashell 1135/1181/1207, `start-limit-hit`) и «There are no
outputs - creating placeholder screen». Это артефакт теста
(перезапуск без выходов), а не дефект системы: при активном VT
сегфолтов нет. Вывод: plasmashell нельзя рестартовать с неактивного VT.

## 4. Исправление (в исходниках проекта)

Файлы:
- `profile/airootfs/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc`
  — переписан: раскладка из сгенерированной Plasma (рабочий стол —
  `org.kde.plasma.folder`, панель `org.kde.panel` с kickoff/pager/
  icontasks/marginsseparator/systemtray/digitalclock/showdesktop),
  отличия от сгенерированной: убран второй экран `[Containments][2]`,
  убран `[ScreenMapping]`, `activityId=` пустой, добавлены обои XrOS
  (`Image=/usr/share/xros/wallpaper.png`), из launchers icontasks
  убран Discover (не установлен).
- `profile/airootfs/root/customize_airootfs.sh` — heredoc `PLASMA_EOF`
  удалён; теперь customize **копирует** appletsrc из `/etc/skel`
  (одна копия, проверка наличия файла с понятной ошибкой).
  Добавлен `kscreenlockerrc` (`Autolock=false`, `LockOnResume=false`)
  только для живого пользователя — см. §5.
- `scripts/xros-diagnose.sh` — секция 22 (проверка раскладки:
  панель, папка, обои, все виджеты панели, нет Discover, нет старого
  `org.kde.plasma.desktop`, нет второго heredoc, нет kscreenlockerrc
  в skel). Диагностика: **PASS=237 FAIL=0 SKIP=13** (было 223/0/11).

Бэкап оригиналов: `~/workspace/xros-backups/xros-20261110-desktop-fix/`
(`appletsrc-skel-orig.txt`, `customize_airootfs.sh-orig`,
`xros-diagnose.sh-orig`, `appletsrc-generated-live.txt`,
`SHA256-fixed1.txt`).

Проверка обоев в живой системе: секция `[Wallpaper]` добавлена в живой
appletsrc (diag2) — plasmashell перезапущен без сегфолта и без ошибки
`""`; визуальная проверка обоев XrOS затруднена автоблокировкой сессии
(см. §5) и будет выполнена на пересобранном ISO.

## 5. Найденный попутно критический дефект: автоблокировка живой сессии

Plasma по умолчанию блокирует экран через 5 мин простоя
(`kscreenlocker_greet`). У живого пользователя `xros` пароль
заблокирован (`passwd -l`), поэтому разблокировать сессию НЕЧЕМ:
в журнале `kscreenlocker_worker: pam_unix(kde:auth): authentication
failure; user=xros` (попытка ввести пароль в экран блокировки).
После 5 мин простоя живая система становилась непригодной к работе.
Исправление: `kscreenlockerrc` с `Autolock=false` +
`LockOnResume=false` только в `/home/xros/.config/` (не в `/etc/skel`,
чтобы в установленной системе с настоящим паролем блокировка осталась
штатной). Проверено диагностикой (секция 22); поведение в живой
системе будет проверено на пересобранном ISO (сессия не должна
блокироваться за 10+ мин простоя).

## 6. Прочие наблюдения (не блокируют)

- `plasma-ksplash.service` / `plasma-plasmashell.service`: 40-секундные
  таймауты старта под TCG (plasmashell: ~24 с CPU за 80 с стены);
  первый plasmashell был SIGKILLнут по таймауту и перезапущен
  systemd — это медлительность эмуляции, а не дефект (на железе
  старт в разы быстрее). `dbus-:1.2-org.kde.KSplash@2.service`:
  `WaitForName` timeout — косметика.
- `plasmashell: Failed to register with host portal` (×2) —
  xdg-desktop-portal без хоста; косметика, на рабочий стол не влияет.
- `kwin_wayland: drmModeListLessees() failed: Отказано в доступе`,
  `Applying output configuration failed: EACCESS` — при переключении
  VT туда-обратно под virtio-gpu; после возврата на графический VT
  выходы восстанавливаются. См. `GRAPHICS-COMPATIBILITY-REPORT.md`.
- `org_kde_powerdevil: There are no outputs - creating placeholder
  screen` — следствие переключения VT, не дефект.

## 8. fixed2: зависание plasmashell/KWin (10.11.2026, вторая итерация)

Пересобранный ISO `xros-1.0-fixed2-*` (та же раскладка, но с ПУСТЫМ
`activityId=` у папок, без `[Containments][2]`, без `[ScreenMapping]`,
с комментариями `#` в начале файла) в QEMU **не показал рабочий стол**:

- UEFI GRUB: окно приветствия появилось (10:30), ошибки виджета `""`
  НЕТ, но панель и обои не появились к 12 мин; Alt+F2 (KRunner) не
  отвечает; клик по месту kickoff — без реакции.
- UEFI diag (serial-лог): первый plasmashell убит по таймауту 40 с
  (старт, 283 с); второй plasmashell[817] — 10 мин 17 с CPU за 10 мин
  1 с стены (больше 100% — многопоточный спин), 539 МБ; `kwin_wayland` —
  90× «The main thread was hanging temporarily!»; рабочий стол не
  отрендерился ни разу; рестарт plasmashell не помог.
- Живой appletsrc показал миграцию: `[Containments][1]` исчез,
  вместо него `[Containments][21]`/`[22]` (папки, activityId
  `3ad94196-a1c3-4084-a48a-32d658d4f5a2`, созданный при миграции);
  панель `[3]` сохранилась. ID 21/22 совпадают с ID дочерних виджетов
  трея (battery=21, brightness=22) — вероятная коллизия/петля.
- Секция `[Wallpaper]` (обои XrOS) потерялась при миграции (у новых
  папок её нет); обои XrOS не отрендерились НИ в одном прогоне
  (сам PNG валиден: 1920×1080 RGB, проверен PIL).
- **Решающий тест**: удаление appletsrc + рестарт plasmashell в ТОЙ ЖЕ
  ВМ — рабочий стол появился за ~110 с: обои Breeze, панель
  (kickoff/pager/icontasks/systemtray/часы 19:13/showdesktop), иконка
  «Установить XrOS» слева сверху. Скриншот:
  `fixed2-uefi-diag-no-appletsrc-test.png`. Значит, причина зависания —
  именно поставляемый appletsrc fixed2 (пустой activityId → миграция),
  а не система, не графика и не KWin сами по себе.
- Автоблокировка: в fixed2 НЕ сработала ни разу (kscreenlockerrc
  `Autolock=false` работает — `kscreenlocker_greet` в логе отсутствует).

### Исправление fixed3

Поставляемый appletsrc переписан с нуля из СГЕНЕРИРОВАННОГО Plasma
файла (`appletsrc-generated-live3.txt`, 148 строк, бэкап
`xros-20261110-desktop-fix/`): настоящий `activityId=
3ad94196-a1c3-4084-a48a-32d658d4f5a2` у папок `[1]`/`[2]` (без миграции),
`[Containments][2]` сохранён, добавлен только `[Wallpaper]` с обоями
XrOS, убран Discover из launchers, убран `[ScreenMapping]`, без
комментариев `#`. Диагностика дополнена проверкой непустого activityId
(секция 22): **PASS=241 FAIL=0 SKIP=11**. Пересборка — fixed3.

## 10. fixed3: миграция происходит и с настоящим activityId (10.11.2026)

fixed3 (appletsrc из сгенерированного файла, настоящий
`activityId=3ad94196-a1c3-4084-a48a-32d658d4f5a2`, без
`[ScreenMapping]`, с `[Wallpaper]` XrOS) в QEMU:

- UEFI GRUB: приветствие в 7:30, ошибки виджета НЕТ, но голый
  рабочий стол чёрный (нет панели, нет обоев, нет иконки);
  Alt+F2 и правый клик не отвечают.
- UEFI diag: plasmashell[811] — 2:30 CPU за 3:45 (66%), KWin —
  90+ «main thread was hanging»; `plasma-plasmashell.service`
  сжёг 9:41 CPU за 10:00 стены (487 МБ).
- **Живой appletsrc после загрузки: `activityId=
  aec83b14-c5c4-400d-96c3-5041ef2df568` (НОВЫЙ, не shipped!),
  папки снова `[Containments][21]`/`[22]`, секция `[Wallpaper]`
  исчезла (0 совпадений).** Вывод: Plasma МИГРИРУЕТ любой
  поставляемый appletsrc независимо от activityId — настоящий
  UUID миграцию НЕ предотвращает (гипотеза fixed2 опровергнута).
  Пустой activityId был СЛЕДСТВИЕМ миграции, а не её причиной.
- **Решающий тест (та же ВМ): удаление appletsrc + корректный
  рестарт plasmashell → ПОЛНЫЙ РАБОЧИЙ СТОЛ**: обои Breeze,
  панель (kickoff/pager/icontasks/systemtray/часы 20:01),
  иконка «Установить XrOS» слева сверху. Скриншот:
  `fixed3-uefi-diag-no-appletsrc-retest2.png`.
- **Обои XrOS через `plasma-apply-wallpaperimage
  /usr/share/xros/wallpaper.png` — РАБОТАЮТ**: «Successfully set
  the wallpaper», фиолетовые волны с X на весь экран, иконка
  и панель на месте (скриншот `fixed3-uefi-diag-wallpaper-test2.png`).
  Первый кадр после команды был чёрным — артефакт переключения VT.
- Замечено: обои периодически «мерцают» в чёрный кадр и
  возвращаются (~20 с); клик по kickoff и Meta-клавиша меню
  не открыли в этой ВМ (возможно, TCG-медлительность или
  спин plasmashell ~65% CPU). Панель и часы работают.
  Требует перепроверки на fixed4.

### Исправление fixed4

- appletsrc НЕ поставляется нигде (удалён из skel, customize
  его не копирует). Plasma генерирует раскладку сама.
- Обои XrOS ставит скрипт `/usr/local/bin/xros-set-wallpaper`
  (retry до 30×3 с, самоудаление autostart-файла после успеха)
  из автозапуска живого пользователя
  `/home/xros/.config/autostart/xros-wallpaper.desktop`
  (только live, НЕ в skel — установленная система обои не трогает).
- GRUB: таймаут — отдельным `label` с `id="__timeout__"`
  (`@TIMEOUT@` в `progress_bar` не подставляется);
  пункт 2 сокращён до «XrOS 1.0 — с диктором».
- Диагностика: PASS=236 FAIL=0 SKIP=11 (секция 22 переписана:
  требует ОТСУТСТВИЯ appletsrc + наличия скрипта обоев;
  добавлены проверки меню GRUB 7з).

## 9. Потеря файлов fixed1 (урок процесса)

Пересборка pacstrap (шаг 1) УДАЛЯЕТ `out/xros-*.iso`. Файлы fixed1
(`xros-1.0-fixed-x86_64.iso`, гибрид) были удалены пересборкой fixed2
до того, как их скопировали в бэкап; сохранились только их SHA256
(`SHA256SUMS.fixed`, `SHA256-fixed1.txt`). Оригинальные ISO — в
`xros-20261110-perms-fix/original-iso/`. fixed1 полностью
воспроизводим (тот же скрипт + профиль до правок appletsrc). Урок:
копировать ISO в бэкап СРАЗУ после сборки, до любой пересборки.
fixed2 забэкаплен сразу (`xros-20261110-desktop-fix/*.iso`).

## 7. Логи и скриншоты

- `experiments/qemu-stage10/logs/fixed-uefi-diag2/serial.log`
  (сессия, ошибка `""` в 299 с, сгенерированная раскладка, SEGV-тест)
- `experiments/qemu-stage10/logs/fixed-uefi-diag/serial.log`
  (127× Permission denied — старый ISO; 0× в fixed)
- `experiments/qemu-stage10/logs/fixed-uefi-grub/serial.log`
  (GRUB-прогон, воспроизведение ошибки на одном GPU)
- Скриншоты:
  `fixed-uefi-diag2-boot-7min.png` (ошибка + приветствие),
  `fixed-uefi-diag2-default-layout-test.png` (рабочий стол с панелью),
  `fixed-uefi-grub-boot-6min.png` (ошибка на одном GPU),
  `fixed-uefi-grub-bare-desktop.png` (полноэкранная ошибка),
  `fixed-uefi-diag2-wallpaper-test*.png` (см. §4, тест затруднён блокировкой)
