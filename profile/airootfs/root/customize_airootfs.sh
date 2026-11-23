#!/usr/bin/env bash
# XrOS — настройка живой системы (выполняется в chroot при сборке).
# Запускается из arch-chroot при штатном mkarchiso (см. scripts/build.sh).
# ВАЖНО: файл должен быть +x в профиле, иначе mkarchiso его не выполнит.
set -e -u
# Umask 0022 (дефект 10.11.2026: chroot наследовал umask 0007 хоста —
# созданные здесь файлы получались 660 и не читались пользователем
# xros; см. FIX-REPORT.md).
umask 0022

# Локали и часовой пояс по умолчанию (поменять — одной правкой).
sed -i 's/^#ru_RU.UTF-8/ru_RU.UTF-8/; s/^#en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
locale-gen
ln -sf /usr/share/zoneinfo/Europe/Astrakhan /etc/localtime

# Пароли живой системы заблокированы: вход — только автовход SDDM,
# sudo — без пароля. Известный пароль по умолчанию + включённый SSH
# давали бы удалённый root.
passwd -l root || true
chmod 600 /etc/shadow
systemctl enable NetworkManager.service || true
systemctl disable sshd.service || true
# Файрвол: по умолчанию запрещаем входящие.
ufw default deny incoming || true
systemctl enable ufw.service || true

# Системные пользователи (sddm, dbus, polkitd) создаются из
# /usr/lib/sysusers.d — не перезаписывать /etc/passwd профилем.
systemd-sysusers || true

# --- Живая KDE Plasma (Wayland) ---
# Plasma 6.8 убрала X11-сессию полностью, пакета plasma-x11-session
# в Arch больше нет — живая сессия теперь Plasma (Wayland),
# SDDM, сессия plasma. Прежняя причина держать X11 (чёрный экран
# Wayland в QEMU/bochs-drm) относилась к Plasma 6.4 и требует
# повторной проверки в QEMU перед сборкой.
# A-10: sddm — БЕЗ '|| true': если enable не удался, сборка должна
# упасть громко (иначе ISO с чёрным экраном без лога). Для
# NetworkManager/ufw '|| true' оставлено осознанно: их enable
# не критичен для загрузки графической сессии.
systemctl enable sddm.service
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf <<'SDDM_EOF'
[Autologin]
User=xros
Session=plasma
SDDM_EOF
chmod 755 /etc/sddm.conf.d
chmod 644 /etc/sddm.conf.d/autologin.conf
# Обои XrOS на экране входа SDDM.
cat > /etc/sddm.conf.d/theme.conf <<'SDDM_THEME_EOF'
[Theme]
Current=breeze
CursorTheme=breeze_cursors
SDDM_THEME_EOF
# tty1 отдаём SDDM: убираем автовход getty на tty1 из releng,
# иначе getty и SDDM дерутся за одну консоль.
rm -rf /etc/systemd/system/getty@tty1.service.d

# Живой пользователь xros.
useradd -m -G wheel,audio,video,optical,storage,render -s /bin/bash xros
passwd -l xros || true
echo "xros ALL=(root) NOPASSWD: /usr/local/bin/xros-install" > /etc/sudoers.d/live-xros
chmod 440 /etc/sudoers.d/live-xros

# Обои и тёмная тема KDE для живого пользователя.
mkdir -p /home/xros/.config
cat > /home/xros/.config/kdeglobals <<'KDE_EOF'
[General]
ColorScheme=BreezeDark
Name=BreezeDark
[Icons]
Theme=breeze-dark
KDE_EOF
# Раскладка рабочего стола НЕ поставляется (нет appletsrc ни в
# /etc/skel, ни в /home/xros): Plasma 6.8 при загрузке чужого
# plasma-org.kde.plasma.desktop-appletsrc мигрирует его (новый
# activityId, папки [1]/[2] → [21]/[22], коллизия с ID виджетов
# трея) — plasmashell крутит CPU, KWin зависает, рабочий стол
# не рисуется (доказано в QEMU на fixed2 и fixed3, 10.11.2026,
# см. PLASMA-SESSION-REPORT.md). Без appletsrc Plasma генерирует
# раскладку сама из look-and-feel breezedark — рабочий стол,
# панель и иконка установщика появляются. Обои XrOS ставятся
# отдельным автозапуском (только живой пользователь, не skel —
# в установленной системе пользователь сам выбирает обои).
mkdir -p /home/xros/.config/autostart
cat > /home/xros/.config/autostart/xros-wallpaper.desktop <<'WALL_EOF'
[Desktop Entry]
Type=Application
Name=XrOS Wallpaper
Comment=Установить обои XrOS по умолчанию (один раз)
Exec=/usr/local/bin/xros-set-wallpaper
X-KDE-autostart-after=panel
NoDisplay=true
WALL_EOF
# Блокировка экрана в ЖИВОЙ системе отключена: у xros заблокирован
# пароль (passwd -l), и после автоблокировки через 5 мин простоя
# разблокировать сессию было бы нечем (PAM: authentication failure).
# В установленной системе блокировка остаётся штатной: этот файл
# лежит только в /home/xros/.config, а не в /etc/skel.
cat > /home/xros/.config/kscreenlockerrc <<'LOCK_EOF'
[Daemon]
Autolock=false
LockOnResume=false
LOCK_EOF
# Те же настройки — в /etc/skel, чтобы их получил и пользователь,
# созданный при установке (установщик копирует skel в его домашний каталог).
mkdir -p /etc/skel/.config
cp /home/xros/.config/kdeglobals /etc/skel/.config/kdeglobals

# Иконка установщика на рабочем столе xros.
mkdir -p /home/xros/Desktop
cat > /home/xros/Desktop/xros-install.desktop <<'DESK_EOF'
[Desktop Entry]
Type=Application
Name=Установить XrOS
Comment=Установить XrOS на диск
Exec=/usr/local/bin/xros-install-gui
Icon=/usr/share/xros/xros-logo.png
Terminal=false
Categories=System;
DESK_EOF
chmod +x /home/xros/Desktop/xros-install.desktop
chown -R xros:xros /home/xros

# Автостарт окна приветствия в Plasma — ТОЛЬКО через xdg/autostart:
# файл /etc/xdg/autostart/xros-welcome.desktop лежит в профиле
# (profile/airootfs) и здесь НЕ перезаписывается, чтобы не было
# двух расходящихся копий. systemd user service и ~/.xprofile
# удалены: service требовал X11-переменные DISPLAY=:0/XAUTHORITY
# и дублировал запуск, а .xprofile под Wayland не выполняется.
# Установщик (src/xros-install) удаляет autostart-файл из целевой
# системы — в установленной системе приветствие не автозапускается.

# --- os-release XrOS ---
# URL не публикуем: домена проекта пока нет.
cat > /usr/lib/os-release <<'OS_EOF'
NAME="XrOS"
PRETTY_NAME="XrOS 1.0"
ID=xros
ID_LIKE=arch
BUILD_ID=1.0
VERSION="1.0"
VERSION_ID="1.0"
ANSI_COLOR="38;2;139;0;255"
LOGO=xros
IMAGE_ID=xros
IMAGE_VERSION=1.0
OS_EOF
ln -sf /usr/lib/os-release /etc/os-release

# root shell — bash.
sed -i 's|^root:\(.*\):/usr/bin/zsh$|root:\1:/bin/bash|' /etc/passwd || true
sed -i 's|^root:x:0:0:root:/root:.*$|root:x:0:0:root:/root:/bin/bash|' /etc/passwd

# Репозиторий XrOS (см. profile/pacman.conf): основной сервер —
# GitHub Pages (XrOS-Security-Updates).
if ! grep -q '^\[xros\]' /etc/pacman.conf 2>/dev/null; then
  cat >> /etc/pacman.conf <<'REPO_EOF'

# XrOS: собственный репозиторий пакетов проекта.
# Основной сервер — GitHub Pages (XrOS-Security-Updates);
# запасной — снимок репозитория внутри системы.
# A-04: SigLevel = Optional ВРЕМЕННО (пакеты не подписаны, см.
# profile/pacman.conf); после подписания вернуть Required.
[xros]
SigLevel = Optional
Server = https://artemkrytoi111.github.io/XrOS-Security-Updates/xros/os/$arch
Server = file:///usr/share/xros/repo/$repo/os/$arch
REPO_EOF
fi

# D10/A-40: импорт production публичного ключа XrOS в keyring живой системы.
# Источник истины — /usr/share/xros/xros-gpg.conf (XROS_GPG_PROD_FPR).
# Пока FPR пуст — production GPG не настроен: dev-режим, явное
# предупреждение, импорт пропускается (SigLevel=Optional, см. A-04).
# Когда FPR задан — строгий путь: проверка ключа, --init, --add,
# проверка отпечатка, --lsign-key, проверка наличия в keyring.
# Любая ошибка — падение customize (явные проверки + exit 1), а не
# || true: молча пропущенная ошибка импорта делала бы Required
# неработоспособным. Тестовый ключ 0EC935D2… здесь не используется.
if [[ -f /usr/share/xros/xros-gpg.conf ]]; then
  # shellcheck disable=SC1091
  . /usr/share/xros/xros-gpg.conf
else
  XROS_GPG_PROD_FPR=""
fi
if [[ -z "${XROS_GPG_PROD_FPR:-}" ]]; then
  echo "ПРЕДУПРЕЖДЕНИЕ: production GPG не настроен (XROS_GPG_PROD_FPR пуст) — dev-режим, ключ XrOS не импортирован, SigLevel=Optional (A-40)" >&2
else
  KEY_FILE=/usr/share/xros/xros-public.key
  [[ -f "$KEY_FILE" ]] || { echo "ОШИБКА: production GPG: нет $KEY_FILE при заданном XROS_GPG_PROD_FPR=$XROS_GPG_PROD_FPR" >&2; exit 1; }
  /usr/local/bin/xros-gpg-check "$KEY_FILE" "$XROS_GPG_PROD_FPR" || exit 1
  pacman-key --init || { echo "ОШИБКА: pacman-key --init не удался (A-40)" >&2; exit 1; }
  pacman-key --add "$KEY_FILE" || { echo "ОШИБКА: pacman-key --add $KEY_FILE не удался (A-40)" >&2; exit 1; }
  # Проверка фактического импорта: отпечаток обязан быть в keyring.
  pacman-key --finger "$XROS_GPG_PROD_FPR" 2>/dev/null | tr -d '[:space:]' | grep -qi "${XROS_GPG_PROD_FPR// /}" \
    || { echo "ОШИБКА: отпечаток $XROS_GPG_PROD_FPR не найден в keyring после --add (A-40)" >&2; exit 1; }
  pacman-key --lsign-key "$XROS_GPG_PROD_FPR" || { echo "ОШИБКА: pacman-key --lsign-key $XROS_GPG_PROD_FPR не удался (A-40)" >&2; exit 1; }
  pacman-key --list-keys "$XROS_GPG_PROD_FPR" >/dev/null 2>&1 \
    || { echo "ОШИБКА: ключ $XROS_GPG_PROD_FPR не найден в keyring после --lsign-key (A-40)" >&2; exit 1; }
  echo "GPG: production-ключ $XROS_GPG_PROD_FPR импортирован и подписан локально (A-40)"
fi

# Зеркала pacman (1.1, пункт 1): /etc/pacman.d/mirrorlist обязан быть
# непустым — иначе живая система не синхронизирует базы
# («failed to synchronize all databases / no servers configured»).
# Профиль кладёт готовый mirrorlist в airootfs; здесь — страховка на
# случай, если файл потерялся или пуст (например, его перезаписал
# пакет pacman-mirrorlist при pacstrap): восстанавливаем из
# встроенной копии. Падение сборки здесь лучше, чем ISO без зеркал.
# Boot-сервис не нужен: файл лежит в squashfs (только чтение) и
# попасть в живую систему пустым после этой проверки не может.
if ! grep -q '^Server' /etc/pacman.d/mirrorlist 2>/dev/null; then
  echo "ПРЕДУПРЕЖДЕНИЕ: /etc/pacman.d/mirrorlist пуст или отсутствует — восстанавливаю зеркала XrOS" >&2
  mkdir -p /etc/pacman.d
  cat > /etc/pacman.d/mirrorlist <<'MIRROR_EOF'
##
## XrOS — зеркала pacman для живой системы (1.1, пункт 1).
## Проверены на Arch VM (14.11.2026): dotsrc и osbeck — самые быстрые,
## metalgamer — запасное. Порядок = приоритет.
##

Server = https://mirrors.dotsrc.org/archlinux/$repo/os/$arch
Server = https://mirror.osbeck.com/archlinux/$repo/os/$arch
Server = https://mirror.metalgamer.eu/archlinux/$repo/os/$arch
MIRROR_EOF
fi
grep -q '^Server' /etc/pacman.d/mirrorlist \
  || { echo "ОШИБКА: /etc/pacman.d/mirrorlist пуст после восстановления — зеркала не настроены" >&2; exit 1; }
chmod 644 /etc/pacman.d/mirrorlist

# Права на установщики (перестраховка: profiledef.sh тоже их задаёт).
chown root:root /usr/local/bin/xros-install /usr/local/bin/xros-welcome /usr/local/bin/xros-welcome-gui 2>/dev/null || true
chmod 755 /usr/local/bin/xros-install /usr/local/bin/xros-welcome /usr/local/bin/xros-welcome-gui 2>/dev/null || true

# Корень живой системы — 0755 (fixed10, Этап 2): mkarchiso копирует профиль
# в work/airootfs, и корень там оказывался 555 — в squashfs и, через rsync,
# в установленной системе. Скрипт выполняется в chroot от root до упаковки
# squashfs, поэтому / здесь — корень живой системы. Только корень, без рекурсии.
chmod 755 / || true
