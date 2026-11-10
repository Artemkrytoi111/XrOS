# Приветствие XrOS под Wayland — финальная доработка (задача 4)

Дата: 2026-11-10. Живая система: KDE Plasma 6.8 Wayland
(`plasma-x11-session` удалён из Arch, X11-план мёртв).
Статус: правки внесены, статические проверки пройдены.
**Реальный запуск в Plasma Wayland НЕ проверен** — возможен только
в QEMU после сборки ISO (см. «План QEMU» ниже).

## 1. Что было до правок (три параллельных механизма запуска)

| Механизм | Состояние |
|---|---|
| `systemd user service` `xros-welcome.service` (`WantedBy=graphical-session.target`, `systemctl --global enable` в `customize_airootfs.sh`) | `Environment=DISPLAY=:0` + `Environment=XAUTHORITY=%h/.Xauthority` — X11-специфично, под Wayland неверно; дублировал запуск |
| `/etc/xdg/autostart/xros-welcome.desktop` | Рабочий механизм; при этом дублировался heredoc-ом в `customize_airootfs.sh` (две расходящиеся копии) |
| `~/.xprofile` (`/home/xros/.xprofile`) | Под Wayland НЕ выполняется (SDDM/Plasma Wayland его не читает); под X11 дублировал autostart |
| Страховка от дублей | `flock` в `xros-welcome-gui` (сохранена) |

## 2. Выбранный механизм: ТОЛЬКО xdg/autostart

**Основной и единственный механизм — `/etc/xdg/autostart/xros-welcome.desktop`.**
Второй механизм не оставлен даже резервным: любой второй путь —
это гарантированный двойной запуск, который ловит только flock.

Почему именно autostart, а не systemd user service:

- Это штатный механизм KDE для автозапуска GUI-приложений; Plasma
  запускает записи autostart после готовности графической сессии —
  в Wayland и в X11 одинаково. Отдельная привязка к Wayland не нужна.
- Процесс — потомок сессии, поэтому `WAYLAND_DISPLAY`,
  `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS` наследуются от сессии
  автоматически. Задавать их вручную в сервисе/скрипте не нужно
  и вредно (фиксированные значения ломаются при смене сессии).
  По той же причине из сервиса убраны `DISPLAY=:0` и `XAUTHORITY`.
- Переключатель «Запускать при старте» в GUI изначально спроектирован
  именно вокруг autostart: он пишет `~/.config/autostart/xros-welcome.desktop`
  с `Hidden=true`, а по правилу XDG пользовательский файл с тем же
  именем перекрывает системный. То есть отключение работает на уровне
  того же механизма, который запускает окно, — без обходных путей.
- systemd-вариант требовал бы корректной ordering-зависимости от
  сессии. Проверено по официальному списку файлов
  `plasma-workspace 6.8.2-1` (archlinux.org, 2026-11-10):
  **`plasma-kwin_wayland.service` в Plasma 6.8 НЕ существует**
  (нет ни одного упоминания `kwin_wayland` в пакете) — добавлять
  `After=plasma-kwin_wayland.service` нельзя, это выдуманный юнит.
  Реально существующие юниты сессии — `plasma-workspace.target`
  и `plasma-workspace-wayland.target`, но при выборе autostart
  они не нужны вообще.
- `.xprofile` мёртв под Wayland и избыточен под X11 (Plasma X11
  тоже обрабатывает xdg/autostart), поэтому удалён полностью.

Совместимость с X11: если пользователь когда-либо выберет X11-сессию,
приветствие продолжит работать — autostart обрабатывается Plasma
и в X11, а Qt сам выберет платформу (`wayland` при `WAYLAND_DISPLAY`,
иначе `xcb`). Никакой Wayland-only привязки нет.

## 3. Что изменено (файлы)

### Удалено
- `profile/airootfs/etc/systemd/user/xros-welcome.service`
  (вместе с ним — пустой каталог `profile/airootfs/etc/systemd/user/`)
- `packages/xros-welcome/xros-welcome.service` (стейджинг пакета)
- `profile/airootfs/home/xros/.xprofile`

### Изменено
- `profile/airootfs/etc/xdg/autostart/xros-welcome.desktop` —
  переписан: комментарий о единственности механизма; добавлены
  `Comment=` и `OnlyShowIn=KDE;` (приветствие — часть живой
  KDE-системы; в установленной системе файл удаляется установщиком).
  `Exec` без изменений: `/usr/local/bin/xros-welcome-gui`.
- `packages/xros-welcome/xros-welcome.desktop` — байт-в-байт та же
  копия (проверено `cmp`, см. раздел 5).
- `profile/airootfs/root/customize_airootfs.sh` — удалены heredoc,
  перезаписывавший autostart-`.desktop` (дубль профиля), и
  `systemctl --global enable xros-welcome.service`. Вместо них —
  комментарий, что autostart-файл берётся из профиля и не
  перезаписывается. Дублирующих копий больше нет.
- `packages/xros-welcome/PKGBUILD` — из `source`/`sha256sums`/`package()`
  убран `xros-welcome.service`; добавлен `xros-welcome-menu.desktop`
  (установка в `/usr/share/applications/xros-welcome.desktop`).
  В `prepare()` добавлены проверки синхронности обоих `.desktop`
  со staged-копиями профиля (по образцу существующей проверки GUI).
- `src/xros-welcome-gui` (и обе его копии — см. раздел 4):
  1. Комментарий в шапке: запуск только из autostart; service и
     `.xprofile` удалены и почему.
  2. **Флаг `--manual`**: `main()` теперь пропускает проверку
     `Hidden=true`, если в `sys.argv` есть `--manual`. Иначе
     отключение автозапуска блокировало бы и ручной запуск из меню.
  3. **Исправлено начальное состояние галочки «Запускать при старте»**:
     было `setChecked(os.path.exists(AUTOSTART))` — при отсутствии
     пользовательского файла (состояние по умолчанию: системный
     autostart активен) галочка ложно показывалась выключенной.
     Теперь: включена, пока файл не содержит `Hidden=true`
     (отсутствие файла = включено). Плюс `blockSignals(True/False)`
     вокруг `setChecked`, чтобы инициализация не вызывала
     `stateChanged` и не записывала файл при каждом запуске окна.
  4. Логика `flock` (один экземпляр) и `Hidden=true`-toggle —
     без изменений.

### Добавлено (ручной запуск из меню)
- `profile/airootfs/usr/share/applications/xros-welcome.desktop` —
  пункт меню «Добро пожаловать в XrOS»,
  `Exec=/usr/local/bin/xros-welcome-gui --manual`,
  `Categories=System;`, `OnlyShowIn=KDE;`.
  Раньше пункта меню не было вообще — ручной запуск был возможен
  только из терминала.
- `packages/xros-welcome/xros-welcome-menu.desktop` — staged-копия
  для пакета (устанавливается как `/usr/share/applications/xros-welcome.desktop`).

### НЕ изменено (проверено, менять не нужно)
- `src/xros-install` (движок): строки 346–348 уже удаляют из целевой
  системы `etc/xdg/autostart/xros-welcome.desktop`,
  `etc/systemd/user/xros-welcome.service` и симлинк
  `graphical-session.target.wants/xros-welcome.service`.
  После удаления сервиса строки 347–348 — защитные no-op
  (безвредны при отсутствии файлов, страхуют от старых профилей).
  Живой пользователь `xros` удаляется целиком (`rm -rf $TARGET/home/xros`),
  поэтому его `~/.config/autostart`-переопределение и `.xprofile`
  в установленную систему не попадают; в `/etc/skel` autostart-записей
  нет. **Вывод: в установленной системе приветствие НЕ автозапускается.**
  Пункт меню и бинари `/usr/local/bin/xros-welcome*` в установленной
  системе остаются — ручной запуск из меню возможен по дизайну.
- `src/xros-welcome` (консольное меню tty1) — не связано с графическим
  автозапуском, не тронуто.
- `profile/profiledef.sh` — только права `0:0:755` на бинари, актуально.

## 4. Синхронность копий (проверено)

- `src/xros-welcome-gui` == `profile/airootfs/usr/local/bin/xros-welcome-gui`
  == `packages/xros-welcome/xros-welcome-gui` (`cmp`, PASS).
- `profile/airootfs/etc/xdg/autostart/xros-welcome.desktop`
  == `packages/xros-welcome/xros-welcome.desktop` (`cmp`, PASS).
- `profile/airootfs/usr/share/applications/xros-welcome.desktop`
  == `packages/xros-welcome/xros-welcome-menu.desktop` (`cmp`, PASS).
- `prepare()` в `packages/xros-welcome/PKGBUILD` теперь сверяет все три
  файла (GUI + оба `.desktop`) при сборке пакета.

## 5. Результаты проверок (честно)

| Проверка | Результат |
|---|---|
| `python3 -m py_compile` — `src/xros-welcome-gui` и обе staged-копии | **PASS** (3/3) |
| `bash -n` — `customize_airootfs.sh`, `src/xros-install`, `src/xros-welcome`, `packages/xros-welcome/PKGBUILD`, `profile/profiledef.sh` | **PASS** (5/5) |
| Структурная проверка `.desktop` (configparser: `Type/Name/Exec/Icon[/Terminal]`) — все 4 файла | **PASS** (4/4) |
| `desktop-file-validate` | **SKIP** — утилита не установлена на хосте сборки (`command -v` — нет). Обязательна в QEMU/в chroot сборки перед релизом (см. план QEMU) |
| Гейт `main()` на реальном коде (PyQt6 заменён заглушкой, `HOME` — временный каталог): (1) нет user-файла → окно запускается; (2) `Hidden=true` → выход 0 без окна; (3) `Hidden=true` + `--manual` → окно запускается | **PASS** (3/3) |
| Логика начального состояния галочки (тот же код, что в `__init__`): нет файла → вкл.; `Hidden=true` → выкл.; файл без `Hidden` → вкл. | **PASS** (3/3) |
| Остаточные ссылки на удалённый механизм в коде/профиле (кроме комментариев «удалено» и защитных `rm` в `src/xros-install` 347–348) | **PASS** — функциональных ссылок нет (`grep DISPLAY=:0\|XAUTHORITY\|xros-welcome.service\|xprofile\|systemctl --global enable`) |
| Реальный запуск окна в Plasma 6.8 Wayland | **НЕ ПРОВЕРЕНО** — только в QEMU после сборки ISO (см. ниже) |

## 6. Спецификация проверок для `scripts/xros-diagnose.sh` (координатору)

Диагностику НЕ редактировал (запрещено задачей). Сейчас в ней есть
**устаревшие проверки**, которые после этих правок дадут ложный FAIL:

- строки ~344–347: `cmp -s packages/xros-welcome/xros-welcome.service
  profile/airootfs/etc/systemd/user/xros-welcome.service` — обоих файлов
  больше нет;
- строка ~370: `grep -q 'systemctl --global enable xros-welcome.service'
  profile/airootfs/root/customize_airootfs.sh` — команды больше нет.

Готовые фрагменты на замену (стиль — как в существующем скрипте,
`ok`/`bad`):

```bash
# --- Приветствие Wayland: единственный механизм — xdg/autostart ---
# 1. Сервиса и .xprofile быть не должно (X11-наследие удалено).
if [ ! -e profile/airootfs/etc/systemd/user/xros-welcome.service ] \
   && [ ! -e packages/xros-welcome/xros-welcome.service ] \
   && [ ! -e profile/airootfs/home/xros/.xprofile ]; then
  ok "welcome: service и .xprofile удалены"
else
  bad "welcome: остались service или .xprofile"
fi
# 2. В живых файлах не должно быть DISPLAY=:0 / XAUTHORITY (кроме
#    комментариев «удалено» — их ловим отдельно, см. п. 3).
if grep -rq '^Environment=DISPLAY\|^Environment=XAUTHORITY' \
     profile/airootfs/etc profile/airootfs/home 2>/dev/null; then
  bad "welcome: остался Environment=DISPLAY/XAUTHORITY в живых файлах"
else
  ok "welcome: нет Environment=DISPLAY/XAUTHORITY"
fi
# 3. customize не включает service глобально.
if grep -q 'systemctl --global enable xros-welcome.service' \
     profile/airootfs/root/customize_airootfs.sh; then
  bad "customize: welcome service всё ещё включается глобально"
else
  ok "customize: welcome service не включается"
fi
# 4. Синхронность .desktop: пакет == airootfs (autostart + меню).
if cmp -s packages/xros-welcome/xros-welcome.desktop \
     profile/airootfs/etc/xdg/autostart/xros-welcome.desktop; then
  ok "xros-welcome.desktop синхронен (пакет == airootfs)"
else
  bad "xros-welcome.desktop расходится"
fi
if cmp -s packages/xros-welcome/xros-welcome-menu.desktop \
     profile/airootfs/usr/share/applications/xros-welcome.desktop; then
  ok "xros-welcome-menu.desktop синхронен (пакет == airootfs)"
else
  bad "xros-welcome-menu.desktop расходится"
fi
# 5. Единственность механизма: autostart-файл есть, и только он
#    запускает GUI при старте (Exec без --manual).
if grep -q '^Exec=/usr/local/bin/xros-welcome-gui$' \
     profile/airootfs/etc/xdg/autostart/xros-welcome.desktop; then
  ok "welcome: autostart Exec без флагов (единственный механизм)"
else
  bad "welcome: autostart Exec не тот"
fi
# 6. Пункт меню использует --manual, GUI его понимает.
if grep -q '^Exec=/usr/local/bin/xros-welcome-gui --manual$' \
     profile/airootfs/usr/share/applications/xros-welcome.desktop \
   && grep -q '"--manual" not in sys.argv' src/xros-welcome-gui; then
  ok "welcome: меню --manual + поддержка в GUI"
else
  bad "welcome: нет --manual в меню или в GUI"
fi
# 7. flock сохранён (страховка от дублей).
if grep -q 'fcntl.flock' src/xros-welcome-gui; then
  ok "welcome-gui: flock (один экземпляр)"
else
  bad "welcome-gui: нет flock"
fi
# 8. Установщик удаляет autostart из целевой системы.
if grep -q 'rm -f "$TARGET/etc/xdg/autostart/xros-welcome.desktop"' \
     src/xros-install; then
  ok "xros-install: autostart приветствия удаляется из целевой системы"
else
  bad "xros-install: нет удаления autostart приветствия"
fi
# 9. В GUI нет жёсткого DISPLAY=:0 (допускается только в комментариях
#    «удалено»; функциональный код — без DISPLAY/XAUTHORITY).
if grep -q '^Environment=DISPLAY\|DISPLAY=:0"' src/xros-welcome-gui; then
  bad "welcome-gui: жёсткий DISPLAY в коде"
else
  ok "welcome-gui: нет жёсткого DISPLAY"
fi
```

## 7. Обязательный план QEMU (после сборки ISO)

Без этих пунктов Wayland-готовность приветствия НЕ считается проверенной:

1. Загрузка live-ISO (UEFI), автовход SDDM в Plasma Wayland; рабочий
   стол появляется, **окно приветствия открывается ОДИН раз**
   автоматически (проверить: нет второго окна, `ps` — один процесс
   `xros-welcome-gui`).
2. В окне: логотип, текст, кнопки; чекбокс «Запускать при старте»
   **включён** при первом запуске (дефолт).
3. Снять галочку → закрыть → выйти из сессии и войти снова:
   окно **не** появляется. Вернуть галочку через ручной запуск из меню
   (проверить, что пункт меню «Добро пожаловать в XrOS» есть
   и открывает окно несмотря на снятую галочку — флаг `--manual`).
4. `desktop-file-validate` обоих `.desktop` в живой системе
   (на хосте утилиты нет — выполнить в chroot/QEMU).
5. Переменные окружения процесса окна:
   `cat /proc/$(pgrep -f xros-welcome-gui)/environ` —
   должны быть `WAYLAND_DISPLAY=wayland-...` и `XDG_RUNTIME_DIR=/run/user/1000`,
   не должно быть `DISPLAY=:0`, заданного сервисом (XWayland-`DISPLAY`
   от сессии допустим, но окно должно работать через Wayland-плагин Qt).
6. Проверка отсутствия дублей при стрессе: перезагрузка live-системы,
   повторный вход — снова ровно одно окно.
7. Кнопка «Запустить установщик» из окна приветствия открывает
   установщик (регрессия после правок GUI).
8. Полная установка на диск через GUI-установщик → загрузка
   установленной системы → **окно приветствия НЕ автозапускается**,
   но пункт меню «Добро пожаловать в XrOS» присутствует и открывает
   окно вручную.
9. Если в QEMU Plasma Wayland снова даст чёрный экран (как в Plasma 6.4
   на bochs-drm) — это проблема сессии/QEMU, а не приветствия;
   зафиксировать отдельно, приветствие при этом не считать проверенным.

## 8. Оставшиеся проблемы и замечания (не в scope задачи)

1. **Замороженная документация описывает старый механизм** —
   `AUDIT-REPORT.md` (§E9, строки ~90, 128, 241, 293–294, 555) и
   `ARCHITECTURE.md` (строки ~139, 200–205) упоминают
   `xros-welcome.service`, `.xprofile` и `systemctl --global enable`.
   Не редактировал (запрещено задачей) — координатору обновить
   при сборке документации. Также `docs/final-refinement/security-audit.md:51`
   упоминает `.xprofile` (документ другого агента).
2. **Устаревшие проверки в `scripts/xros-diagnose.sh`** (строки ~344–347,
   ~370) дадут ложный FAIL до внесения фрагментов из раздела 6.
3. **Rust-установщик: `src/xros-install-gui-rs/src/main.rs:18`** —
   `sudo --preserve-env=DISPLAY,XAUTHORITY,DBUS_SESSION_BUS_ADDRESS`
   при повторном запуске себя через sudo. Под чистым Wayland
   `WAYLAND_DISPLAY` при этом НЕ сохраняется: root-процесс установщика
   упадёт на XWayland (`DISPLAY`) вместо Wayland. Это вне задачи 4
   (установщик — отдельная зона), но владельцу установщика стоит
   добавить `WAYLAND_DISPLAY` (и, при необходимости, `XDG_RUNTIME_DIR`)
   в `--preserve-env` либо явно проверить запуск установщика из окна
   приветствия в QEMU (пункт 7 плана выше).
4. `desktop-file-validate` недоступен на хосте — валидация `.desktop`
   выполнена только структурной проверкой (раздел 5); формальная
   валидация — пункт 4 плана QEMU.
5. Поведение Qt при одновременном наличии `WAYLAND_DISPLAY` и `DISPLAY`
   (XWayland) — автовыбор платформы `wayland` — принято как штатное
   поведение PyQt6, отдельной проверки кода не требует, но в QEMU
   стоит убедиться, что окно реально рисуется через Wayland
   (пункт 5 плана QEMU).
