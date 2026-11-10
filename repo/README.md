# XrOS — репозиторий пакетов
# Репозиторий `xros`: пакеты проекта (xros-installer, xros-welcome,
# xros-branding, xros-cli).
#
# PLACEHOLDER: домен xros.example НЕ СУЩЕСТВУЕТ — действующего сервера
# репозитория нет. Основной сервер https://xros.example/repo — заглушка
# до публикации (этап 9). Публикация, GPG-подпись репозитория
# (SigLevel Required + ключ в связке) и автообновления — следующие шаги
# ПОСЛЕ публикации; сейчас их нет.
#
# Структура (как в pacman):
#   repo/xros/os/x86_64/*.pkg.tar.zst
#   repo/xros/os/x86_64/xros.db.tar.gz
#   repo/xros/os/x86_64/xros.files.tar.gz
#
# Статус на 10.11.2026: СОБРАН (аудит пакетов): каталог
# repo/xros/os/x86_64/ содержит все 4 пакета 1.0-1 + БД
# (xros.db.tar.gz, xros.files.tar.gz, repo-add 10.11.2026).
# Проверено в chroot сборки: pacman -Sy с file://-источника скачивает
# БД, pacman -Sl xros показывает все 4 пакета. Снимок репозитория
# также лежит в profile/airootfs/usr/share/xros/repo/ (копия этого
# каталога) — file://-источник в pacman.conf живой системы рабочий.
# При пересборке любого пакета: makepkg → repo-add -f → обновить
# обе копии (repo/ и airootfs-снимок). Сервер xros.example —
# по-прежнему PLACEHOLDER, GPG-подписи нет.
#
# Сборка пакетов (этап 2):
#   1. Собрать Rust-бинари (см. scripts/build.sh):
#        cargo build --release --offline в chroot сборки
#        (кэш cargo: /home/hatch/.cargo внутри chroot);
#        бинари xros и xros-install-gui — в packages/xros-cli/ и
#        packages/xros-installer/ соответственно.
#   2. Застейджить остальные исходники рядом с PKGBUILD:
#        cp src/xros-install packages/xros-installer/
#        cp src/xros-welcome-gui packages/xros-welcome/
#        cp branding/{xros-logo,xros-logo-small,wallpaper}.png \
#           branding/{wallpaper,grub-bg}.jpg branding/grub-bg.png \
#           profile/airootfs/usr/share/xros/banner.txt \
#           packages/xros-branding/
#      (prepare() в каждом PKGBUILD проверяет свежесть копий.)
#   3. cd packages/<пакет> && makepkg
#      ... и так для каждого пакета ...
#   4. repo-add repo/xros/os/x86_64/xros.db.tar.gz repo/xros/os/x86_64/*.pkg.tar.zst
#   5. Снимок в ISO: cp -a repo/xros profile/airootfs/usr/share/xros/repo/
#      (делается на этапе сборки ISO; без снимка file://-источник
#      в pacman.conf указывает в пустоту — см. profile/pacman.conf).
#
# Модель обновлений (безопасная, до подписанного репозитория):
#   - Arch-репозитории (core/extra/multilib): обновляются обычным
#     `pacman -Syu` / `sudo xros upgrade` вручную пользователем.
#   - [xros]: автообновлений НЕТ. Юниты xros-update.service/.timer
#     поставляются в пакете xros-cli, но таймер ВЫКЛЮЧЕН везде:
#     в живой системе его нет (юнитов нет в airootfs), установщик
#     его НЕ включает. Причина: репозиторий не подписан
#     (SigLevel Optional TrustAll) и сервер — PLACEHOLDER;
#     автообновление с неподписанного/несуществующего источника —
#     дыра: система либо молча не обновляется, либо тянет пакеты
#     без проверки подписи.
#   - После публикации [xros]: подписать репозиторий GPG,
#     перевести [xros] на SigLevel Required + ключ, и только тогда
#     решать о включении xros-update.timer (отдельным шагом,
#     с явного разрешения).
