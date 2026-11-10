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
systemctl enable sddm.service || true
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
echo "xros ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/live-xros
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
# PLACEHOLDER: URL https://xros.example/ — домен не существует,
# заменить на настоящий при публикации (см. AUDIT-REPORT.md).
cat > /usr/lib/os-release <<'OS_EOF'
NAME="XrOS"
PRETTY_NAME="XrOS 1.0"
ID=xros
ID_LIKE=arch
BUILD_ID=1.0
VERSION="1.0"
VERSION_ID="1.0"
ANSI_COLOR="38;2;139;0;255"
HOME_URL="https://xros.example/"
DOCUMENTATION_URL="https://xros.example/"
SUPPORT_URL="https://xros.example/"
BUG_REPORT_URL="https://xros.example/"
LOGO=xros
IMAGE_ID=xros
IMAGE_VERSION=1.0
OS_EOF
ln -sf /usr/lib/os-release /etc/os-release

# root shell — bash.
sed -i 's|^root:\(.*\):/usr/bin/zsh$|root:\1:/bin/bash|' /etc/passwd || true
sed -i 's|^root:x:0:0:root:/root:.*$|root:x:0:0:root:/root:/bin/bash|' /etc/passwd

# Репозиторий XrOS (см. profile/pacman.conf): основной сервер пока
# не опубликован — работает снимок внутри системы. GPG-подпись — позже.
if ! grep -q '^\[xros\]' /etc/pacman.conf 2>/dev/null; then
  cat >> /etc/pacman.conf <<'REPO_EOF'

# XrOS: собственный репозиторий пакетов проекта.
# PLACEHOLDER: основной сервер https://xros.example/repo не существует
# (домен xros.example — заглушка, публикации нет);
# запасной — снимок репозитория внутри системы.
[xros]
SigLevel = Optional TrustAll
Server = https://xros.example/repo/$repo/os/$arch
Server = file:///usr/share/xros/repo/$repo/os/$arch
REPO_EOF
fi

# Права на установщики (перестраховка: profiledef.sh тоже их задаёт).
chown root:root /usr/local/bin/xros-install /usr/local/bin/xros-welcome /usr/local/bin/xros-welcome-gui 2>/dev/null || true
chmod 755 /usr/local/bin/xros-install /usr/local/bin/xros-welcome /usr/local/bin/xros-welcome-gui 2>/dev/null || true
