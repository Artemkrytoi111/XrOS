#!/usr/bin/env bash
# XrOS — постобработка ISO от mkarchiso: добавление BIOS-GRUB.
#
# mkarchiso 92 (archiso) умеет для live-ISO только UEFI-GRUB
# (bootmodes=('uefi.grub')); штатного bootmode bios.grub НЕ СУЩЕСТВУЕТ.
# Этот скрипт НЕ запускает mkarchiso и НЕ пересобирает живую систему:
# он берёт ГОТОВЫЙ ISO от mkarchiso и добавляет второй El Torito
# (BIOS, i386-pc-eltorito) + гибридный MBR, сохраняя UEFI El Torito
# и всю archiso-логику (ядро/initramfs — штатные от mkarchiso).
#
# Механизм (проверен экспериментом experiments/bios-grub-test/,
# BIOS CD + BIOS USB + UEFI в QEMU 10.11.2026):
#   * eltorito.img — grub-mkimage -O i386-pc-eltorito (GRUB 2.16)
#     с early-config: поиск ISO по метке (search --label) и
#     configfile /boot/grub/grub.cfg — то же меню, что и в UEFI
#     (единая тема XrOS, кириллица, фон; пункт «Настройки UEFI»
#     в grub.cfg показан только на UEFI через regexp-проверку
#     grub_platform — на BIOS он не появляется).
#   * efiboot.img (UEFI El Torito) в ISO от mkarchiso лежит ТОЛЬКО
#     в appended partition 2 и НЕ входит в ISO9660-дерево — скрипт
#     извлекает её из ISO по GPT-интервалу (xorriso
#     -report_system_area: '-append_partition 2 ... --interval:
#     local_fs:STARTd-ENDd::') через dd и проверяет md5/сигнатуру.
#   * Пересборка xorriso -as mkisofs — параметры как у mkarchiso 92
#     (_add_xorrisofs_options_bios.syslinux +
#     _add_common_xorrisofs_options_uefi, см. /usr/sbin/mkarchiso):
#     порядок опций важен: --grub2-mbr, -partition_offset 16,
#     -append_partition 2, -isohybrid-gpt-basdat ДО -eltorito-alt-boot
#     (иначе EFI-раздел теряет GUID EFI system partition в GPT).
#   * GRUB-образы (core.img + boot_hybrid.img) ОБЯЗАТЕЛЬНО одной
#     версии — 2.16 из build-env rootfs. Хостовый GRUB (Ubuntu: 2.12)
#     НЕ подходит, поэтому вся работа выполняется ВНУТРИ build-env
#     rootfs через scripts/xros-build-env.sh --exec (unshare+chroot;
#     systemd-nspawn на хосте не работает — см. build-env.md).
#
# Использование (с хоста; скрипт сам перевызывает себя в rootfs):
#   ./scripts/postprocess-bios-grub.sh --iso out/xros-1.0-x86_64.iso
#   ./scripts/postprocess-bios-grub.sh --iso <iso> --out <hybrid.iso>
#   ./scripts/postprocess-bios-grub.sh --iso <iso> --in-place
#   ./scripts/postprocess-bios-grub.sh --iso <iso> --force   # если в ISO
#       уже есть BIOS El Torito (перегенерация, напр. для тестов)
# Пути --iso/--out/--work-dir — внутри проекта (относительные или
# абсолютные под корнем проекта); наружу скрипт не пишет, кроме
# указанного --out. Выход по умолчанию: <имя>-hybrid.iso рядом
# с входом. --in-place: исходник сохраняется как <имя>.pre-bios-grub.iso.
# Проверки результата — scripts/check-iso.sh (отдельно).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ENV="$ROOT/scripts/xros-build-env.sh"

# Модули BIOS-GRUB: список mkarchiso 92 для UEFI (_make_bootmode_uefi.grub)
# минус EFI-модули, плюс BIOS-модули. Проверен в эксперименте.
BIOS_MODS="all_video at_keyboard boot btrfs cat chain configfile echo exfat ext2 f2fs fat font gfxmenu gfxterm gzio halt hfsplus iso9660 jpeg keylayouts linux loadenv loopback ls minicmd normal ntfs ntfscomp part_apple part_gpt part_msdos png probe read reboot regexp search search_fs_file search_fs_uuid search_label serial sleep test udf usb usbserial_common usbserial_ftdi usbserial_pl2303 usbserial_usbdebug video xfs zstd biosdisk vbe vga"

die() { echo "postprocess-bios-grub: ОШИБКА: $*" >&2; exit 1; }
log() { echo "postprocess-bios-grub: $*"; }

usage() {
    cat <<'EOF'
Использование:
  postprocess-bios-grub.sh --iso <iso-от-mkarchiso> [--out <hybrid.iso>]
  postprocess-bios-grub.sh --iso <iso> --in-place
  postprocess-bios-grub.sh --iso <iso> --force [--label XROS_202611]
  postprocess-bios-grub.sh --iso <iso> --work-dir <dir> [--keep-work]
  postprocess-bios-grub.sh --help
Опции:
  --iso PATH       входной ISO от mkarchiso (обязательно)
  --out PATH       выходной гибридный ISO (по умолчанию <имя>-hybrid.iso)
  --in-place       выход = входной путь; исходник -> <имя>.pre-bios-grub.iso
  --force          перегенерировать BIOS El Torito, даже если он уже есть
  --label LABEL    метка тома ISO и поиска в early-config (по умолчанию:
                   метка входного ISO; если её нет — XROS_202611)
  --work-dir DIR   рабочий каталог (по умолчанию mktemp в /tmp)
  --keep-work      не удалять рабочий каталог
  --in-rootfs      (внутренний флаг) выполнять работу внутри rootfs
EOF
}

# --- разбор аргументов -------------------------------------------------------
ISO="" OUT="" IN_PLACE=0 FORCE=0 LABEL="" WORK_DIR="" KEEP_WORK=0 IN_ROOTFS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --iso)       ISO="${2:-}"; shift 2 ;;
        --out)       OUT="${2:-}"; shift 2 ;;
        --in-place)  IN_PLACE=1; shift ;;
        --force)     FORCE=1; shift ;;
        --label)     LABEL="${2:-}"; shift 2 ;;
        --work-dir)  WORK_DIR="${2:-}"; shift 2 ;;
        --keep-work) KEEP_WORK=1; shift ;;
        --in-rootfs) IN_ROOTFS=1; shift ;;
        --help|-h)   usage; exit 0 ;;
        *) die "неизвестный аргумент: $1 (см. --help)" ;;
    esac
done
[[ -n "$ISO" ]] || { usage >&2; die "--iso обязателен"; }
[[ "$IN_PLACE" -eq 0 || -z "$OUT" ]] || die "--in-place и --out несовместимы"

# --- перевод путей хост -> /xros при перевызове в rootfs --------------------
# Внутри rootfs проект смонтирован в /xros, а хостовые абсолютные пути
# там не существуют. Поэтому снаружи принимаем только пути внутри
# проекта и переписываем их в /xros/... перед --exec.
to_rootfs_path() { # to_rootfs_path <path> -> путь вида /xros/...
    local p="$1"
    case "$p" in
        /xros/*) printf '%s' "$p"; return 0 ;;
        "$ROOT"/*) printf '/xros/%s' "${p#"$ROOT"/}"; return 0 ;;
        /*) die "путь вне проекта XrOS: $p (разрешены только пути внутри $ROOT)" ;;
        *) printf '/xros/%s' "$p"; return 0 ;;
    esac
}

if [[ "$IN_ROOTFS" -eq 0 ]]; then
    # Хостовый режим: ничего не делаем сами, только перевызываем себя
    # внутри build-env rootfs (там GRUB 2.16 + xorriso + mtools).
    [[ -x "$BUILD_ENV" ]] || die "нет $BUILD_ENV"
    args=(--in-rootfs --iso "$(to_rootfs_path "$ISO")")
    [[ -n "$OUT" ]] && args+=(--out "$(to_rootfs_path "$OUT")")
    [[ "$IN_PLACE" -eq 1 ]] && args+=(--in-place)
    [[ "$FORCE" -eq 1 ]] && args+=(--force)
    [[ -n "$LABEL" ]] && args+=(--label "$LABEL")
    if [[ -n "$WORK_DIR" ]]; then args+=(--work-dir "$(to_rootfs_path "$WORK_DIR")"); fi
    [[ "$KEEP_WORK" -eq 1 ]] && args+=(--keep-work)
    log "перевызов внутри build-env rootfs (GRUB 2.16, xorriso)..."
    exec "$BUILD_ENV" --exec -- bash "/xros/scripts/postprocess-bios-grub.sh" "${args[@]}"
fi

# --- дальше — только внутри rootfs -------------------------------------------
# Здесь ROOT=/xros (bind-mount проекта), все пути — внутри rootfs.
[[ -d /xros/scripts ]] || die "не внутри rootfs: нет /xros/scripts (запускайте без --in-rootfs, скрипт сам перевызовет себя)"
command -v xorriso >/dev/null || die "внутри rootfs нет xorriso (пакет libisoburn)"
command -v grub-mkimage >/dev/null || die "внутри rootfs нет grub-mkimage (пакет grub)"
command -v grub-script-check >/dev/null || die "внутри rootfs нет grub-script-check (пакет grub)"
[[ -f /usr/lib/grub/i386-pc/boot_hybrid.img ]] || die "внутри rootfs нет /usr/lib/grub/i386-pc/boot_hybrid.img (пакет grub)"
GRUB_VER="$(grub-mkimage --version | head -1)"
case "$GRUB_VER" in
    *2.16*) log "GRUB в rootfs: $GRUB_VER (совпадает с boot_hybrid.img 2.16)" ;;
    *) die "GRUB в rootfs: $GRUB_VER — требуется 2.16 (core.img и boot_hybrid.img должны быть одной версии)" ;;
esac
log "xorriso в rootfs: $(xorriso --version 2>&1 | head -1)"

# Пути входа/выхода внутри rootfs уже вида /xros/...
[[ -f "$ISO" ]] || die "нет входного ISO: $ISO"
ISO_ABS="$(readlink -f "$ISO")"
if [[ "$IN_PLACE" -eq 1 ]]; then
    # Собираем во временный файл в work, ротация — только ПОСЛЕ успешной
    # проверки результата (иначе исходник был бы потерян до бэкапа).
    FINAL_ISO="$ISO_ABS"
    BACKUP="${ISO_ABS%.iso}.pre-bios-grub.iso"
    OUT_ISO=""  # задаётся после создания WORK ниже
else
    if [[ -z "$OUT" ]]; then
        OUT_ISO="${ISO_ABS%.iso}-hybrid.iso"
    else
        OUT_ISO="$(readlink -m "$OUT")"
    fi
    FINAL_ISO="$OUT_ISO"
    BACKUP=""
fi
[[ -n "$OUT_ISO" ]] && [[ "$OUT_ISO" != "$ISO_ABS" ]] || [[ "$IN_PLACE" -eq 1 ]] || die "выход совпадает со входом без --in-place"
if [[ -n "$WORK_DIR" ]]; then
    WORK="$WORK_DIR"
    mkdir -p "$WORK"
else
    WORK="$(mktemp -d /tmp/xros-postprocess.XXXXXX)"
fi
[[ "$KEEP_WORK" -eq 0 ]] && trap 'rm -rf "$WORK"' EXIT
if [[ "$IN_PLACE" -eq 1 ]]; then
    OUT_ISO="$WORK/hybrid.iso"
fi
log "вход:  $ISO_ABS"
log "выход: $OUT_ISO"
log "work:  $WORK"

# --- 1. проверка входного ISO ------------------------------------------------
log "== 1. Проверка входного ISO =="
VOLID="$(xorriso -indev "$ISO_ABS" -pvd_info 2>/dev/null | sed -n 's/^Volume Id *: //p' | head -1)"
[[ -n "$VOLID" ]] || die "не удалось прочитать Volume id входного ISO"
log "Volume id входного ISO: $VOLID"
if [[ -z "$LABEL" ]]; then LABEL="$VOLID"; fi
[[ "$LABEL" == "$VOLID" ]] || die "--label $LABEL не совпадает с Volume id ISO ($VOLID): early-config искал бы несуществующую метку"
log "Метка для early-config: $LABEL"

ELTORITO_REPORT="$WORK/el-torito.txt"
xorriso -indev "$ISO_ABS" -report_el_torito as_mkisofs >"$ELTORITO_REPORT" 2>"$WORK/el-torito.err" || die "xorriso -report_el_torito failed"
if grep -q -- "-e '--interval:appended_partition_2" "$ELTORITO_REPORT"; then
    log "UEFI El Torito: ЕСТЬ (appended_partition_2)"
else
    die "входной ISO НЕ имеет UEFI El Torito (appended_partition_2) — это не ISO от mkarchiso uefi.grub, постобработка невозможна"
fi
if grep -q -- "-b '" "$ELTORITO_REPORT"; then
    if [[ "$FORCE" -eq 0 ]]; then
        die "входной ISO УЖЕ имеет BIOS El Torito; для перегенерации добавьте --force"
    fi
    log "BIOS El Torito уже есть — перегенерация (--force)"
else
    log "BIOS El Torito: нет (будет добавлен)"
fi
if ! xorriso -osirrox on -indev "$ISO_ABS" -find /boot/grub/grub.cfg -type f 2>/dev/null | grep -q "'/boot/grub/grub.cfg'"; then
    die "в ISO нет /boot/grub/grub.cfg — early-config нечего загружать"
fi
log "/boot/grub/grub.cfg: есть"
APPID="$(xorriso -indev "$ISO_ABS" -pvd_info 2>/dev/null | sed -n 's/^App Id *: //p' | head -1)"
PUBLISHER="$(xorriso -indev "$ISO_ABS" -pvd_info 2>/dev/null | sed -n 's/^Publisher Id *: //p' | head -1)"
[[ -n "$APPID" ]] || APPID="XrOS 1.0"
[[ -n "$PUBLISHER" ]] || PUBLISHER="XrOS"
log "Application id: $APPID; Publisher: $PUBLISHER"

# --- 2. извлечение efiboot.img из appended partition 2 -----------------------
log "== 2. Извлечение efiboot.img (appended partition 2) =="
SYS_AREA="$WORK/system-area.txt"
xorriso -indev "$ISO_ABS" -report_system_area as_mkisofs >"$SYS_AREA" 2>/dev/null || die "xorriso -report_system_area failed"
INTERVAL="$(grep -o -- "-append_partition 2[^:]*--interval:local_fs:[0-9]*d-[0-9]*d::" "$SYS_AREA" | head -1)"
[[ -n "$INTERVAL" ]] || die "не найден интервал appended partition 2 в -report_system_area"
PART_START="$(printf '%s' "$INTERVAL" | sed -E 's/.*local_fs:([0-9]+)d-([0-9]+)d::/\1/')"
PART_END="$(printf '%s' "$INTERVAL" | sed -E 's/.*local_fs:([0-9]+)d-([0-9]+)d::/\2/')"
PART_COUNT=$(( PART_END - PART_START + 1 ))
[[ "$PART_COUNT" -gt 0 ]] || die "пустой интервал appended partition 2: $INTERVAL"
log "EFI-раздел: секторы $PART_START..$PART_END (512 Б), $(( PART_COUNT * 512 )) Б"
dd if="$ISO_ABS" of="$WORK/efiboot.img" bs=512 skip="$PART_START" count="$PART_COUNT" status=none \
    || die "dd извлечение efiboot.img не удалось"
# Проверка: FAT-образ (OEM-ID mkfs.fat) и наличие BOOTX64.EFI внутри.
OEM_ID="$(dd if="$WORK/efiboot.img" bs=1 skip=3 count=8 status=none 2>/dev/null | tr -d '\0')"
case "$OEM_ID" in
    mkfs.fat*) log "efiboot.img: FAT-образ OK (OEM-ID mkfs.fat), $(( $(stat -c%s "$WORK/efiboot.img") )) Б" ;;
    *) die "извлечённый efiboot.img не похож на FAT-образ (OEM-ID: '$OEM_ID')" ;;
esac
if command -v mdir >/dev/null 2>&1; then
    mdir -i "$WORK/efiboot.img" ::/EFI/BOOT/BOOTX64.EFI >/dev/null 2>&1 \
        || die "в efiboot.img нет /EFI/BOOT/BOOTX64.EFI"
    log "efiboot.img: /EFI/BOOT/BOOTX64.EFI есть"
else
    log "mtools нет — проверка BOOTX64.EFI внутри efiboot.img пропущена"
fi

# --- 3. распаковка дерева ISO -------------------------------------------------
log "== 3. Распаковка дерева ISO =="
TREE="$WORK/tree"
mkdir -p "$TREE"
xorriso -osirrox on -indev "$ISO_ABS" -extract / "$TREE" >/dev/null 2>"$WORK/extract.err" \
    || { cat "$WORK/extract.err" >&2; die "распаковка ISO не удалась"; }
# Старый boot-каталог — мусор: xorriso при пересборке сгенерирует новый
# по -eltorito-catalog; оставленный файл вносил бы путаницу.
rm -f "$TREE/EFI/boot.cat" "$TREE/boot/grub/boot.cat"
[[ -f "$TREE/boot/grub/grub.cfg" ]] || die "после распаковки нет tree/boot/grub/grub.cfg"
TREE_SIZE_MB="$(du -s --apparent-size -B1M "$TREE" | awk '{print $1}')"
log "дерево распаковано: ${TREE_SIZE_MB} МиБ"

# --- 4. генерация BIOS GRUB-образа -------------------------------------------
log "== 4. Генерация eltorito.img (GRUB 2.16, i386-pc-eltorito) =="
cat >"$WORK/early-bios.cfg" <<EOF
insmod iso9660
insmod part_gpt
insmod part_msdos
insmod search
insmod search_label
insmod serial
serial --unit=0 --speed=115200
terminal_output --append serial
echo 'XROS: BIOS GRUB early config running (i386-pc-eltorito)'
search --no-floppy --set=root --label $LABEL
set prefix=(\$root)/boot/grub
configfile /boot/grub/grub.cfg
EOF
grub-script-check "$WORK/early-bios.cfg" || die "grub-script-check early-bios.cfg failed"
# shellcheck disable=SC2086
grub-mkimage -O i386-pc-eltorito \
    -o "$WORK/eltorito.img" \
    -p /boot/grub -c "$WORK/early-bios.cfg" \
    $BIOS_MODS || die "grub-mkimage i386-pc-eltorito failed"
ELTORITO_SIZE="$(stat -c%s "$WORK/eltorito.img")"
[[ "$ELTORITO_SIZE" -gt 0 ]] || die "eltorito.img пустой"
log "eltorito.img: $ELTORITO_SIZE Б"
mkdir -p "$TREE/boot/grub/i386-pc"
cp "$WORK/eltorito.img" "$TREE/boot/grub/i386-pc/eltorito.img"

# --- 5. пересборка ISO через xorriso -----------------------------------------
log "== 5. Пересборка гибридного ISO (xorriso) =="
# Порядок опций — как у mkarchiso 92 (bios.syslinux + uefi.grub):
# --grub2-mbr, -partition_offset 16, -append_partition 2,
# -isohybrid-gpt-basdat ДО -eltorito-alt-boot (иначе EFI-раздел
# теряет GUID EFI system partition в GPT). -no-pad — как у mkarchiso
# для деревьев > 900 МиБ. Каталог — boot/grub/boot.cat (как в эксперименте).
XOR_OPTS=(
    -iso-level 3 -full-iso9660-filenames -joliet -joliet-long -rational-rock
    -volid "$LABEL" -appid "$APPID" -publisher "$PUBLISHER"
    -preparer "prepared by mkarchiso + xros-bios-grub"
    -eltorito-boot boot/grub/i386-pc/eltorito.img
    -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info
    --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img
    -partition_offset 16
    --mbr-force-bootable
    -append_partition 2 C12A7328-F81F-11D2-BA4B-00A0C93EC93B "$WORK/efiboot.img"
    -isohybrid-gpt-basdat
    -eltorito-alt-boot -e '--interval:appended_partition_2:all::'
    -no-emul-boot
    -eltorito-catalog boot/grub/boot.cat
)
if (( TREE_SIZE_MB > 900 )); then XOR_OPTS+=(-no-pad); fi
mkdir -p "$(dirname "$OUT_ISO")"
rm -f "$OUT_ISO"
xorriso -no_rc -as mkisofs "${XOR_OPTS[@]}" -o "$OUT_ISO" "$TREE" >"$WORK/xorriso.log" 2>&1 \
    || { tail -20 "$WORK/xorriso.log" >&2; die "xorriso пересборка не удалась"; }
log "ISO пересобран: $OUT_ISO ($(stat -c%s "$OUT_ISO") Б)"

# --- 6. проверка результата ----------------------------------------------------
log "== 6. Проверка результата =="
OUT_REPORT="$WORK/out-el-torito.txt"
xorriso -indev "$OUT_ISO" -report_el_torito as_mkisofs >"$OUT_REPORT" 2>/dev/null || die "xorriso -report_el_torito выходного ISO failed"
grep -q -- "-b 'boot/grub/i386-pc/eltorito.img'" "$OUT_REPORT" \
    || grep -q -- "-b '/boot/grub/i386-pc/eltorito.img'" "$OUT_REPORT" \
    || die "в выходном ISO НЕТ BIOS El Torito"
grep -q -- "-e '--interval:appended_partition_2" "$OUT_REPORT" \
    || die "в выходном ISO НЕТ UEFI El Torito"
xorriso -indev "$OUT_ISO" -report_system_area as_mkisofs 2>/dev/null | grep -q -- "--grub2-mbr" \
    || die "в выходном ISO нет гибридного MBR grub2-mbr"
OUT_VOLID="$(xorriso -indev "$OUT_ISO" -pvd_info 2>/dev/null | sed -n 's/^Volume Id *: //p' | head -1)"
[[ "$OUT_VOLID" == "$LABEL" ]] || die "Volume id выходного ISO ($OUT_VOLID) != $LABEL"
log "BIOS El Torito: ЕСТЬ; UEFI El Torito: ЕСТЬ; MBR: grub2-mbr; Volume id: $OUT_VOLID"
SHA="$(sha256sum "$OUT_ISO" | awk '{print $1}')"
log "SHA256: $SHA"

if [[ "$IN_PLACE" -eq 1 ]]; then
    mv "$ISO_ABS" "$BACKUP"
    mv "$OUT_ISO" "$FINAL_ISO"
    OUT_ISO="$FINAL_ISO"
    log "in-place: исходник сохранён как $BACKUP"
fi
{
    echo "XrOS postprocess-bios-grub: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "input:  $ISO_ABS"
    echo "output: $OUT_ISO"
    echo "label:  $LABEL"
    echo "grub:   $GRUB_VER"
    echo "eltorito.img: $ELTORITO_SIZE bytes"
    echo "efiboot.img: $(( PART_COUNT * 512 )) bytes (partition 2, sectors $PART_START..$PART_END)"
    echo "size:   $(stat -c%s "$OUT_ISO") bytes"
    echo "sha256: $SHA"
} >"$OUT_ISO.postprocess.log"
log "лог: $OUT_ISO.postprocess.log"
log "ГОТОВО: $OUT_ISO"
