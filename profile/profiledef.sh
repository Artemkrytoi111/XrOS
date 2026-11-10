#!/usr/bin/env bash
# shellcheck disable=SC2034
# XrOS — профиль mkarchiso (на базе archiso releng).
# Все имена, цвета и тексты бренда — ПРОВИЗОРНЫЕ, см. branding/README.md
# и ARCHITECTURE.md. Меняются здесь и в profile/airootfs одной правкой.

iso_name="xros"
iso_label="XROS_202611"
# PLACEHOLDER: домен xros.example не существует — заменить на настоящий
# домен при публикации (см. AUDIT-REPORT.md).
iso_publisher="XrOS <https://xros.example>"
iso_application="XrOS 1.0"
iso_version="1.0"
install_dir="xros"
bootmodes=('uefi.grub')
# ВНИМАНИЕ: archiso 92 знает только три bootmode — bios.syslinux,
# uefi.grub и uefi.systemd-boot (см. /usr/share/doc/archiso/
# README.profile.rst и /usr/sbin/mkarchiso: функции _make_bootmode_*).
# bootmode bios.grub НЕ СУЩЕСТВУЕТ: GRUB для BIOS-загрузки live-ISO
# штатно сделать нельзя. Поэтому live-ISO грузится ТОЛЬКО по UEFI
# (GRUB); BIOS-загрузка live-ISO отсутствует, пока координатор не
# решит: либо смириться (установленная система на BIOS всё равно
# получает GRUB через xros-install: grub-install --target=i386-pc),
# либо делать BIOS-GRUB вручную вне mkarchiso (El Torito core.img
# + постобработка xorriso). Исследование вариантов, проверенное
# 10.11.2026 (рецепт, риски, трудозатраты): docs/boot-bios-grub.md.
# Резерв удалённых syslinux/efiboot: /tmp/xros-bootloader-backup-20261110/.
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
# zstd вместо xz: с KDE в образе ~130 тыс. файлов xz сжимает их
# ~12 МБ/мин (больше часа). zstd в разы быстрее при почти том же
# размере; ядро Arch поддерживает zstd-squashfs.
airootfs_image_tool_options=('-comp' 'zstd' '-Xcompression-level' '15' '-b' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
kernel_params_aarch64="clk_ignore_unused pd_ignore_unused arm64.nopauth"
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/root/.gnupg"]="0:0:700"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/Installation_guide"]="0:0:755"
  ["/usr/local/bin/xros-install"]="0:0:755"
  ["/usr/local/bin/xros-install-gui"]="0:0:755"
  ["/usr/local/bin/xros"]="0:0:755"
  ["/usr/local/bin/xros-welcome"]="0:0:755"
  ["/usr/local/bin/xros-welcome-gui"]="0:0:755"
  ["/usr/local/bin/xros-set-wallpaper"]="0:0:755"
  ["/usr/local/bin/livecd-sound"]="0:0:755"
)
