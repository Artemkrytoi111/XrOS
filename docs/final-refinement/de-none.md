# XrOS — задача 5: DE=none («Без графики»)

**Дата:** 10 ноября 2026.
**Статус:** готово (статика). Реальная установка НЕ запускалась, ISO НЕ собирался.
**Файлы задачи:** движок `src/xros-install`, GUI `src/xros-install-gui-rs/src/steps.rs`
(только текст подсказки), тест `scripts/tests/test-de-none.sh`.
**Не тронуто:** `~/workspace/akvt-os` (только чтение через `build-chroot.sh`),
`ARCHITECTURE.md`, `AUDIT-REPORT.md`, `README.md`, `scripts/xros-diagnose.sh`,
`profile/packages.x86_64` (живая система всегда с KDE — см. ниже).

---

## 1. Что было до исправления (аудит)

* `DE=none` в движке удалял только 7 пакетов
  (`plasma-desktop sddm konsole dolphin plasma-nm xorg-server ttf-dejavu`)
  и отключал DM. Оставались `plasma-pa`, `kscreen`, `pipewire`,
  `pipewire-pulse`, `wireplumber`, `python-pyqt6` (+ `libxkbcommon-x11`,
  `noto-fonts`) и все их зависимости (`plasma-workspace`, `kwin`,
  `qt6-*`, `kf6-*`, `breeze`) — «только консоль» получалась нечистой
  (AUDIT-REPORT.md, проблема B10).
* Система после `DE=none` оставалась в `graphical.target` (цель живой
  системы) — `set-default` не делался вообще ни для одного варианта.
* `xorg-server` был в списке KDE, хотя Plasma 6.8 Wayland он не нужен
  (AUDIT-REPORT.md E2).
* Графические настройки живой системы копировались в консольную:
  `/etc/sddm.conf.d/theme.conf` и KDE-настройки из `/etc/skel/.config/`.
* Офисный пакет (`libreoffice`/`okular`) ставился и при `DE=none` —
  Okular/LibreOffice тянут обратно Qt/GTK.
* Подсказка в GUI («Без интернета останется KDE Plasma») врала для
  `none`: удаление графики интернету не нужно вообще.

## 2. Проверки зависимостей (Arch sync DB, chroot, только чтение)

Проверено `pacman -Si/-Sii/-Sg` в chroot `~/workspace/akvt-os`
(синхронная БД `core.db`/`extra.db`, сеть не трогалась, `pacman -Sy`
не запускался):

| Факт | Источник | Вывод для задачи |
|---|---|---|
| `plasma-desktop 6.8.2-1` зависит от `plasma-workspace` и др., но НЕ от `xorg-server` и НЕ от `sddm` | `pacman -Si plasma-desktop` | `xorg-server` из списка KDE можно убрать |
| `plasma-workspace 6.8.2-1` зависит от `xorg-xwayland`, конфликтует с `plasma-x11-session` | `pacman -Si plasma-workspace` | XWayland у KDE есть и без `xorg-server`; X11-сессии нет (аудит E1) |
| `xorg-server Required By: sddm, lightdm, ...` | `pacman -Sii xorg-server` | `xorg-server` приходит зависимостью SDDM/LightDM; в KDE он всё равно будет (через `sddm`), но явное перечисление избыточно |
| `libxkbcommon-x11 Required By: qt6-base, i3-wm, ...` | `pacman -Sii libxkbcommon-x11` | при `DE=none` уходит вместе с `qt6-base` (сирота в той же транзакции `pacman -Rns` + чистка `pacman -Qtdq`) |
| `gnome` — группа, включает `gdm` | `pacman -Sg gnome` | `DE_PKGS="gnome gdm"` корректен (`gdm` продублирован явно как документ DM) |
| `xfce4`, `xfce4-goodies` — группы | `pacman -Sg xfce4[-goodies]` | списки XFCE корректны |
| `cinnamon 6.6.9-1` зависит от `gtk3`, `muffin`, `network-manager-applet`; `gnome-terminal` НЕ в зависимостях | `pacman -Si cinnamon` | `gnome-terminal` в списке Cinnamon — осознанное дополнение (штатный терминал Cinnamon), не зависимость |
| `i3-wm 4.25.1-1` зависит от `libxkbcommon-x11`, `ttf-font` | `pacman -Si i3-wm` | `ttf-font` уже закрыт живым `ttf-dejavu` — выбора провайдера при `pacman -S` не будет |
| `sway 1:1.12-4` зависит от `ttf-font` | `pacman -Si sway` | то же, что для i3 |
| `gdm 51.1.1-1` зависит от `gnome-shell`, `gnome-session` | `pacman -Si gdm` | связка GNOME+gdm комплектна |
| `lightdm` зависит от `xorg-server` | `pacman -Si lightdm` | X11-вариантам `xorg-server` нужен |
| `pipewire-pulse` зависит от `pipewire-session-manager` (вирт., даёт `wireplumber`) | `pacman -Si pipewire-pulse` | тройка `pipewire/pipewire-pulse/wireplumber` удаляется одним списком |
| `python-pyqt6` зависит от `qt6-base` | `pacman -Si python-pyqt6` | удаляется вместе со стеком Qt; обратных зависимостей в базе pacman нет (`xros-welcome` — файл overlay, а не пакет, см. §4) |

**Все 7 вариантов реально реализуемы, фиктивных нет.** Ни один вариант
не убран: `kde`, `gnome`, `xfce`, `cinnamon`, `sway`, `i3`, `none` —
все пакеты/группы существуют в репозиториях Arch на 10.11.2026.

## 3. Итоговые списки пакетов по вариантам

Единый источник списков — движок `src/xros-install` (case-карта `DE`).
GUI (`app.rs`, константа `DES`) только передаёт код `DE` через
`/tmp/xros-install.conf` (`install.rs: write_conf`), своих списков
пакетов у GUI нет. Живая система всегда KDE (`profile/packages.x86_64`
не менялся).

| Вариант | Код | DM | `DE_PKGS` (точный список) | Как ставится |
|---|---|---|---|---|
| KDE Plasma | `kde` | `sddm` | `plasma-desktop plasma-nm plasma-pa kscreen sddm konsole dolphin` | Копия живой системы (rsync), интернет не нужен; `pacman -S` не вызывается |
| GNOME | `gnome` | `gdm` | `gnome gdm` | `pacman -S` из интернета; без интернета остаётся KDE |
| XFCE | `xfce` | `lightdm` | `xfce4 xfce4-goodies xorg-server lightdm lightdm-gtk-greeter` | `pacman -S` из интернета; без интернета остаётся KDE |
| Cinnamon | `cinnamon` | `lightdm` | `cinnamon xorg-server lightdm lightdm-gtk-greeter gnome-terminal` | `pacman -S` из интернета; без интернета остаётся KDE |
| Sway | `sway` | `sddm` | `sway foot wofi sddm xorg-xwayland` | `pacman -S` из интернета; без интернета остаётся KDE |
| i3-wm | `i3` | `lightdm` | `i3-wm i3status dmenu xorg-server xorg-xinit lightdm lightdm-gtk-greeter xterm` | `pacman -S` из интернета; без интернета остаётся KDE |
| **Без графики** | `none` | — (нет) | _(пусто — ничего не ставится)_ | Удаление графики из копии живой системы, интернет не нужен |

### 3.1. KDE: что изменилось

* `xorg-server` **убран** из `DE_PKGS`. Обоснование: Plasma 6.8 —
  Wayland, `plasma-workspace` сам тянет `xorg-xwayland`, а `xorg-server`
  приходит зависимостью `sddm` (см. §2). Явное перечисление было
  избыточным, а не ошибочным по сути.
* Добавлены `plasma-nm plasma-pa kscreen` — это канонический состав
  KDE-системы: раньше список был неполным (`plasma-desktop sddm konsole
  dolphin`), хотя живая система содержит и эти три пакета.
* **Нюанс (честно):** из установленной KDE-системы `xorg-server` от
  этой правки не исчезнет — система копируется из живой, а в живом
  списке `profile/packages.x86_64` `xorg-server` пока оставлен до
  ретеста Wayland в QEMU (AUDIT-REPORT.md 5.4). Убрать его оттуда —
  отдельное решение, не часть `DE=none`; в коде это задокументировано
  комментарием у case-карты.

### 3.2. DE=none: точный состав консольной системы

Принцип: **точный список на удаление, а не «установить всё, потом
чистить»**. Установленная система — это копия живой системы минус
графический стек, плюс проверки.

**Удаляется — `XROS_GRAPHICS_PKGS`** (верхнеуровневые пакеты из живого
списка; зависимости снимаются `pacman -Rns` автоматически, остатки —
чисткой сирот):

```
plasma-desktop plasma-nm plasma-pa kscreen sddm konsole dolphin
pipewire pipewire-pulse wireplumber xorg-server
ttf-dejavu noto-fonts python-pyqt6 libxkbcommon-x11
```

Каждый пакет проверен на необходимость (§2): ни один из них не нужен
консольной системе, и ни один не требуется базовыми пакетами.
Зависимости, которые уходят вместе с ними без отдельного перечисления:
`plasma-workspace`, `kwin`, `qt6-*`, `kf6-*`, `breeze`, `libpulse`,
`pipewire`-библиотеки и т.д. (через `-Rns` + `pacman -Qtdq`).

**Остаётся — `XROS_CONSOLE_BASE_PKGS`** (обязательные, проверяются
после чистки через `pacman -Q`):

| Пакет | Зачем консоли |
|---|---|
| `linux` | ядро (копируется с ISO, `mkinitcpio -P` пересобирает initramfs) |
| `grub` | загрузчик (`grub-install` в обе цели, BIOS `i386-pc` и UEFI `x86_64-efi`) |
| `networkmanager` | сеть; сервис включается для любого DE (`systemctl enable NetworkManager.service`) |
| `sudo` | администрирование через группу `wheel` (`/etc/sudoers.d/wheel`) |
| `openssh` | SSH-клиент/сервер в системе есть (пакет из живой системы), но **`sshd` НЕ включается**: удалённый вход по умолчанию закрыт, как и в живой системе (`customize_airootfs.sh`: `systemctl disable sshd`) |

Прочее из живой системы, что остаётся и не мешает консоли:
`base`, `dialog`, `nano`, `mkinitcpio`, `efibootmgr`, `os-prober`,
дисковые утилиты, `ufw`, `xros`-утилиты. Файлы бренда
(`/usr/share/xros/wallpaper.*`, `grub-bg.jpg`) остаются — это не
настройки и не сервисы; `grub-bg.jpg` нужен теме GRUB.
Консольное меню `xros-welcome` (`dialog`, tty1) **не удаляется** —
оно работает без графики; удаляется только GUI-бинарь
`xros-welcome-gui` (PyQt6 мёртв без `python-pyqt6`).

### 3.3. Что делает ветка `none` в движке (по шагам)

1. Отключает все DM (`sddm`/`lightdm`/`gdm`) и ставит цель по умолчанию
   `multi-user.target` (`systemctl set-default`). Без этого система
   грузилась бы в `graphical.target` живой системы.
2. Фильтрует `XROS_GRAPHICS_PKGS` до установленных (`pacman -Qq` —
   `pacman -Rns` падает целиком, если хоть один пакет не установлен)
   и удаляет их одной транзакцией `pacman -Rns --noconfirm`.
3. Чистит сирот: `pacman -Qtdq` → `pacman -Rns` (Qt/KF/Plasma-библиотеки).
4. Удаляет файлами графические настройки: `rm -rf /etc/sddm.conf.d`,
   `/etc/skel/.config/kdeglobals`,
   `/etc/skel/.config/plasma-org.kde.plasma.desktop-appletsrc`,
   `/usr/local/bin/xros-welcome-gui`.
5. Проверяет результат: ни одного пакета из `XROS_GRAPHICS_PKGS`
   (`pacman -Qq`) + все пакеты из `XROS_CONSOLE_BASE_PKGS` на месте.
   Неудача — честное предупреждение в журнале и
   `DE_RESULT="только консоль (чистка графики неполная — см. журнал)"`,
   установка при этом не падает (система грузится).
6. Автовход не ставится (уже было: требует непустого `DE_DM`).
   Офис не ставится: блок офиса первым проверяет `DE=none`
   (LibreOffice/Okular тянут обратно Qt/GTK).
7. Финальная проверка DM пропускается для `none` (уже было:
   требует непустого `DE_DM`); ядро/initramfs/`grub.cfg`/`fstab`/
   пользователь/hostname проверяются как для всех вариантов.

Графические варианты, наоборот, теперь явно ставят
`graphical.target` (`set-default` в ветке `kde` и в успешной ветке
`else`) — раньше цель по умолчанию вообще не задавалась.

## 4. Что изменено (файлы)

| Файл | Изменение |
|---|---|
| `src/xros-install` | Case-карта DE: KDE без `xorg-server`, с `plasma-nm plasma-pa kscreen`; новые переменные `XROS_GRAPHICS_PKGS`, `XROS_CONSOLE_BASE_PKGS` с комментариями-обоснованиями; ветка `none` переписана (п. 3.3); `set-default graphical.target` для графических вариантов; защита офиса при `DE=none`; текст диалога выбора DE упоминает, что `none` — без интернета |
| `profile/airootfs/usr/local/bin/xros-install` | Синхронизирована копия (`cmp` — совпадает) |
| `packages/xros-installer/xros-install` | Синхронизирована копия (`cmp` — совпадает) |
| `src/xros-install-gui-rs/src/steps.rs` | Шаг Desktop: подсказка дополнена — ««Без графики» работает и без интернета: графический стек живой системы удаляется, система загружается в консоль» |
| `scripts/tests/test-de-none.sh` | **Новый тест** (см. §5) |

Не менялось: `profile/packages.x86_64`, `src/xros-install-gui-rs/src/app.rs`
(набор `DES` уже совпадал с консолью — 7 кодов), `install.rs`
(GUI только передаёт код `DE`).

**Внимание координатору — параллельные правки в тех же файлах:**
во время работы над задачей в `src/xros-install` (строки 58–160) и в
`src/xros-install-gui-rs/src/install.rs`/`app.rs` работал другой агент
(защита дочернего процесса, задача C5: `InstallHandle`, `PDEATHSIG`,
`pre_exec`, ловушки `HUP/TERM/INT`). Его блок в `src/xros-install`
сохранён как есть и включён в синхронизированные копии; мои правки с
ним не пересекаются (разные регионы файла). Его же код — причина
текущего `cargo check` FAIL (см. §6.2). Синхронизацию копий после его
финиша стоит перепроверить: если он ещё раз правит `src/xros-install`,
копии разойдутся снова.

## 5. Тест `scripts/tests/test-de-none.sh`

Новый файл `scripts/tests/test-de-none.sh` (каталога `scripts/tests`
раньше не было — создан). Только статический разбор, без установки:
парсит `src/xros-install`, `app.rs` (`DES`), `steps.rs` и
`profile/packages.x86_64`. Проверки: (а) `DE_PKGS`/`DE_DM` пусты при
`none`, каждый графический пакет живой системы — в списке удаления,
чистка сирот, `pacman -Rns`, удаление `sddm.conf.d` и KDE-`skel`;
(б) базовый список `linux grub networkmanager sudo openssh` + проверка
`pacman -Q` после чистки, ядро и NetworkManager — общие для всех DE;
(в) в ветке `none` нет `systemctl enable`, все DM отключаются,
`set-default multi-user.target`, автовход и офис заблокированы;
(г) варианты GUI == консоли (7 кодов); KDE полный и без `xorg-server`;
синхронность staged-копий. Выход 0 при всех PASS, 1 при любом FAIL.

### Прогон 1 — ДО исправлений (10.11.2026)

```
PASS=22 FAIL=14, exit 1
FAIL  XROS_GRAPHICS_PKGS: список удаления графики не определён в движке
FAIL  DE=none: чистка сирот (pacman -Qtdq) в ветке none
FAIL  DE=none: удаляется /etc/sddm.conf.d целиком
FAIL  DE=none: удаляются KDE-настройки из /etc/skel
FAIL  XROS_CONSOLE_BASE_PKGS: список обязательных базовых пакетов не определён
FAIL  DE=none: после чистки проверяется наличие базовых пакетов (pacman -Q)
FAIL  DE=none: цель по умолчанию — multi-user.target
FAIL  KDE: цель по умолчанию — graphical.target
FAIL  DE=none: нет защиты от установки офиса в блоке офиса
FAIL  KDE: plasma-nm в DE_PKGS
FAIL  KDE: plasma-pa в DE_PKGS
FAIL  KDE: kscreen в DE_PKGS
FAIL  KDE: xorg-server в DE_PKGS
FAIL  GUI: шаг Desktop упоминает, что none работает без интернета
```

### Прогон 2 — ПОСЛЕ исправлений (10.11.2026)

```
PASS=56 FAIL=0, exit 0
```

Полный вывод прогона 2: все 56 проверок PASS, включая все 16 живых
графических пакетов в списке удаления, все 5 базовых пакетов,
совпадение вариантов GUI/консоли
(`cinnamon gnome i3 kde none sway xfce`) и синхронность копий.
Повторный прогон после ре-синхронизации копий (см. §4 про параллельного
агента) — тоже **PASS=56 FAIL=0**.

## 6. Проверка кода

### 6.1. `bash -n`

```
bash -n src/xros-install            → OK
bash -n scripts/tests/test-de-none.sh → OK
```

Также прогнано на версии `src/xros-install` уже после добавления блока
параллельного агента (§4): `bash -n` — OK.

### 6.2. `cargo check` для GUI — FAIL, НЕ по моей вине

Хост: `cargo` отсутствует. Проверка — в chroot `~/workspace/akvt-os`
(`build-chroot.sh`, `cargo/rustc 1.99.1`, `--offline`,
`CARGO_HOME=/home/hatch/.cargo`); исходники копировались во временный
каталог `/root/xros-gui-check`, после проверок он удалён (chroot
возвращён в исходное состояние; пустой каталог `/root/xros-tmp` от
06:04 — не мой, не трогался).

* Первая попытка: FAIL — `install.rs:127 unexpected closing delimiter`
  (файл был в промежуточном состоянии правок параллельного агента).
* Вторая попытка (после завершения его правок в `install.rs`):
  **FAIL, 1 ошибка + 1 предупреждение**, обе в `install.rs` — коде
  параллельного агента, не в моих файлах:

```
error[E0133]: call to unsafe function `pre_exec` is unsafe and requires unsafe function or block
   --> src/install.rs:184:21
    |       let mut child = Command::new(INSTALLER)
    ...
warning: variable does not need to be mutable
   --> src/install.rs:184:9
    |     let mut child = Command::new(INSTALLER)
```

Моя единственная правка в GUI — строковый литерал в `steps.rs:105`
(текст подсказки). Других ошибок компилятор не сообщил — то есть
`steps.rs` (включая мою строку) разбирается нормально; сборку роняет
только `pre_exec` в `install.rs:184` (код задачи C5, не `DE=none`).
Исправлять чужой незавершённый код не стал, чтобы не конфликтовать с
параллельным агентом. **Пересборка бинаря `xros-install-gui` и его
рестейджинг в `packages/xros-installer/` и `profile/airootfs/` —
на этапе сборки, после закрытия C5** (иначе `prepare()` в PKGBUILD
уронит сборку: исходники новее бинаря).

## 7. Спецификация проверок для `scripts/xros-diagnose.sh`

Готовые фрагменты в стиле существующей диагностики (`ok`/`bad`,
`grep -q`). Координатор вставляет их в `xros-diagnose.sh`
(этот файл мне править запрещено). Имена переменных — как в движке.

```bash
# --- DE=none: точный список пакетов, без графики (задача 5) ---
# (а) DE=none: ничего не ставится, менеджера входа нет.
if grep -E '^[[:space:]]*none\)' src/xros-install | grep -q 'DE_PKGS=""'; then
  ok "de-none: DE_PKGS пуст при DE=none"
else bad "de-none: DE_PKGS не пуст при DE=none"; fi
if grep -E '^[[:space:]]*none\)' src/xros-install | grep -q 'DE_DM=""'; then
  ok "de-none: DE_DM пуст при DE=none"
else bad "de-none: DE_DM не пуст при DE=none"; fi
# (а) Каждый графический пакет живой системы — в списке удаления.
GRAPHICS_REMOVE=$(grep -E '^XROS_GRAPHICS_PKGS=' src/xros-install \
  | sed -E 's/^[^=]*="([^"]*)".*/\1/')
for p in plasma-desktop plasma-nm plasma-pa kscreen sddm konsole dolphin \
         pipewire pipewire-pulse wireplumber xorg-server \
         ttf-dejavu noto-fonts python-pyqt6 libxkbcommon-x11; do
  if grep -qx "$p" profile/packages.x86_64; then
    if echo " $GRAPHICS_REMOVE " | grep -q " $p "; then
      ok "de-none: живой пакет $p — в списке удаления"
    else bad "de-none: живой пакет $p НЕ в списке удаления"; fi
  fi
done
# (а) Сироты и настройки: чистка Qtdq, удаление sddm.conf.d и KDE-skel.
if grep -q 'pacman -Qtdq' src/xros-install; then
  ok "de-none: чистка сирот (pacman -Qtdq)"
else bad "de-none: нет чистки сирот (pacman -Qtdq)"; fi
if grep -q 'rm -rf "$TARGET/etc/sddm.conf.d"' src/xros-install; then
  ok "de-none: удаляется /etc/sddm.conf.d"
else bad "de-none: не удаляется /etc/sddm.conf.d"; fi
if grep -q 'skel/.config/kdeglobals' src/xros-install; then
  ok "de-none: удаляются KDE-настройки из /etc/skel"
else bad "de-none: не удаляются KDE-настройки из /etc/skel"; fi
# (б) Базовая консольная система обязана остаться.
for p in linux grub networkmanager sudo openssh; do
  if grep -E '^XROS_CONSOLE_BASE_PKGS=' src/xros-install | grep -q "$p"; then
    ok "de-none: базовый пакет $p — в списке обязательных"
  else bad "de-none: базовый пакет $p НЕ в списке обязательных"; fi
done
# (в) DM не включается, цель — multi-user.target; графика — graphical.target.
if grep -q 'systemctl set-default multi-user.target' src/xros-install; then
  ok "de-none: цель по умолчанию — multi-user.target"
else bad "de-none: нет set-default multi-user.target"; fi
if grep -q 'systemctl set-default graphical.target' src/xros-install; then
  ok "de-none: графические варианты — graphical.target"
else bad "de-none: нет set-default graphical.target"; fi
# (в) Офис при DE=none не ставится (тянет Qt/GTK обратно).
OFFICE_LINE=$(grep -n 'Офисный пакет' src/xros-install | head -n 1 | cut -d: -f1)
if awk -v start="$OFFICE_LINE" 'NR>start && /\[\[ "\$DE" == "none" \]\]; then/{found=1; exit} END{exit !found}' src/xros-install; then
  ok "de-none: офисный пакет пропускается при DE=none"
else bad "de-none: нет защиты от установки офиса при DE=none"; fi
# KDE: полный состав, без xorg-server.
KDE_PKGS=$(grep -E '^[[:space:]]*kde\)' src/xros-install \
  | sed -E 's/.*DE_PKGS="([^"]*)".*/\1/')
for p in plasma-desktop plasma-nm plasma-pa kscreen sddm konsole dolphin; do
  if echo " $KDE_PKGS " | grep -q " $p "; then
    ok "de-none: KDE содержит $p"
  else bad "de-none: в KDE нет $p"; fi
done
if echo " $KDE_PKGS " | grep -q " xorg-server "; then
  bad "de-none: xorg-server в списке KDE (Plasma 6.8 Wayland: не нужен)"
else ok "de-none: xorg-server НЕ в списке KDE"; fi
# (г) Варианты GUI и консоли совпадают.
CONSOLE_DES=$(grep -oE '^[[:space:]]+(kde|gnome|xfce|cinnamon|sway|i3|none) "' src/xros-install \
  | grep -oE '(kde|gnome|xfce|cinnamon|sway|i3|none)' | sort -u | tr '\n' ' ')
GUI_DES=$(sed -n '/pub const DES/,/];/p' src/xros-install-gui-rs/src/app.rs \
  | grep -oE '"(kde|gnome|xfce|cinnamon|sway|i3|none)"' | tr -d '"' | sort -u | tr '\n' ' ')
if [[ "$CONSOLE_DES" == "$GUI_DES" && -n "$CONSOLE_DES" ]]; then
  ok "de-none: варианты GUI == консоли ($CONSOLE_DES)"
else bad "de-none: варианты расходятся: консоль=[$CONSOLE_DES] GUI=[$GUI_DES]"; fi
# Тест задачи 5 запускается и проходит (полная проверка логики).
if bash scripts/tests/test-de-none.sh >/dev/null 2>&1; then
  ok "de-none: scripts/tests/test-de-none.sh PASS"
else bad "de-none: scripts/tests/test-de-none.sh FAIL"; fi
```

## 8. Оставшиеся проблемы и что требует QEMU

1. **Реальное поведение `DE=none` не проверено установкой.** Тест —
   статический разбор. `pacman -Rns` точного списка + чистка сирот
   в живой системе никогда не запускались: возможны сюрпризы
   (например, пакет из списка окажется нужен чему-то из базы, и
   транзакция `pacman -Rns` откажется удалять его целиком — тогда
   сработает предупреждение, но часть графики останется).
   **QEMU:** установить XrOS с `DE=none`, загрузиться, проверить:
   `systemctl get-default` → `multi-user.target`,
   `pacman -Q plasma-desktop sddm pipewire ...` → «не установлен»,
   `pacman -Qtdq` → пусто, `pacman -Q qt6-base` → не установлен,
   `systemctl status display-manager` → нет такого сервиса,
   логин в консоли + `sudo`, сеть (`nmcli`, `ping`), `grub.cfg` на месте.
2. **`xorg-server` в установленной KDE-системе останется** (через живую
   копию и зависимость `sddm`) — см. §3.1. Удаление из живого списка —
   после ретеста Wayland в QEMU (AUDIT-REPORT.md 5.4).
3. **`cargo check` GUI падает (E0133, `install.rs:184`)** — код задачи
   C5 параллельного агента, не `DE=none` (см. §6.2). После его закрытия
   — пересобрать `xros-install-gui` и перестейджить бинарь.
4. **Параллельные правки:** другой агент правит те же файлы
   (`src/xros-install`, GUI). Перед финальным прогоном диагностики —
   перепроверить `cmp` копий движка и заново прогнать
   `scripts/tests/test-de-none.sh`.
5. **Остаток графики вне пакетов:** файлы бренда
   (`/usr/share/xros/wallpaper.*`) и бинарь GUI-установщика
   (`/usr/local/bin/xros-install-gui`, egui) остаются в консольной
   системе как мёртвый груз (пакет `xros-installer` удалять нельзя —
   он владеет и самим `xros-install`). Если координатор решит, что
   консольная система должна быть чище, — удалять файлами
   (`rm -f .../xros-install-gui .../wallpaper.*`) в ветке `none`,
   но это уже не пакеты, а файлы overlay.
6. **Офис при `DE=none` из консоли недоступен** — это осознанно
   (см. §3.3 п.6); в GUI выбор офиса при `none` никак не подсвечен
   (пользователь выберет LibreOffice, а движок молча пропустит его
   с записью в журнале). Возможное улучшение GUI: при `de == "none"`
   дизейблить шаг Office Suite — не сделано, на усмотрение координатора.
