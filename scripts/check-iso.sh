#!/usr/bin/env bash
# XrOS — проверка готового ISO (после mkarchiso + postprocess-bios-grub).
#
# Проверяет ФАКТЫ по файлу ISO, ничего не собирает и не монтирует:
#   * BIOS El Torito, UEFI El Torito, гибридный MBR (grub2-mbr)
#   * Volume id, размер, SHA256
#   * структуру дерева: /boot/grub/grub.cfg, /boot/grub/i386-pc/eltorito.img
#     (BOOTX64.EFI в дереве НЕ ищется: у mkarchiso 92 EFI-раздел лежит
#     ТОЛЬКО как appended partition 2 и не входит в ISO9660-дерево —
#     проверяется отдельно внутри FAT-образа раздела, см. efi-bootx64)
#   * с --archiso — дополнительно штатные пути mkarchiso:
#     /xros/boot/x86_64/vmlinuz-linux и initramfs-linux.img
#     (без --archiso эти проверки — SKIP: экспериментальный ISO
#     experiments/bios-grub-test/ их не содержит по построению).
#   * целостность данных: xorriso -check_media (отключается --no-media-check)
#
# Использование:
#   ./scripts/check-iso.sh <iso> [--label XROS_202611] [--archiso]
#                           [--no-media-check]
# Выход: 0 — все обязательные проверки PASS; 1 — есть FAIL.
# Каждая проверка печатает одну строку PASS/FAIL/SKIP + итог.
set -u

ISO=""
LABEL="XROS_202611"
EXPECT_ARCHISO=0
MEDIA_CHECK=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --label) LABEL="${2:-}"; [[ -n "$LABEL" ]] || { echo "check-iso: --label требует значения" >&2; exit 2; }; shift 2 ;;
        --label=*) LABEL="${1#--label=}"; shift ;;
        --archiso) EXPECT_ARCHISO=1; shift ;;
        --no-media-check) MEDIA_CHECK=0; shift ;;
        --help|-h)
            sed -n '2,20p' "$0"; exit 0 ;;
        -*)
            echo "check-iso: неизвестный аргумент: $1" >&2; exit 2 ;;
        *)
            if [[ -z "$ISO" ]]; then ISO="$1"; shift;
            else echo "check-iso: лишний аргумент: $1" >&2; exit 2; fi ;;
    esac
done
[[ -n "$ISO" && -f "$ISO" ]] || { echo "check-iso: нет ISO: ${ISO:-<пусто>}" >&2; exit 2; }
command -v xorriso >/dev/null 2>&1 || { echo "check-iso: нет xorriso на хосте" >&2; exit 2; }

PASS=0; FAIL=0; SKIP=0
check() { # check <name> <ok:0/1> [detail]
    if [[ "$2" -eq 0 ]]; then
        PASS=$((PASS+1)); echo "PASS  $1${3:+ — $3}"
    else
        FAIL=$((FAIL+1)); echo "FAIL  $1${3:+ — $3}"
    fi
}
skip() { SKIP=$((SKIP+1)); echo "SKIP  $1${2:+ — $2}"; }

echo "check-iso: $ISO"
SIZE="$(stat -c%s "$ISO")"
check "iso-exists-size" 0 "${SIZE} Б"
SHA="$(sha256sum "$ISO" | awk '{print $1}')"
check "iso-sha256" 0 "$SHA"

VOLID="$(xorriso -indev "$ISO" -pvd_info 2>/dev/null | sed -n 's/^Volume Id *: //p' | head -1)"
if [[ "$VOLID" == "$LABEL" ]]; then check "volid" 0 "$VOLID";
else check "volid" 1 "ожидалось $LABEL, получено ${VOLID:-<не прочитано>}"; fi

REPORT="$(mktemp)"
trap 'rm -f "$REPORT"' EXIT
xorriso -indev "$ISO" -report_el_torito as_mkisofs >"$REPORT" 2>/dev/null \
    || { check "el-torito-readable" 1 "xorriso -report_el_torito failed"; }
if grep -q -- "-b '" "$REPORT" 2>/dev/null; then
    BIOS_IMG="$(grep -- "-b '" "$REPORT" | head -1 | sed "s/.*-b '//; s/'.*//")"
    check "bios-el-torito" 0 "$BIOS_IMG"
else
    check "bios-el-torito" 1 "нет BIOS El Torito (-b)"
fi
if grep -q -- "-e '--interval:appended_partition_2" "$REPORT" 2>/dev/null; then
    check "uefi-el-torito" 0 "appended_partition_2"
else
    check "uefi-el-torito" 1 "нет UEFI El Torito (appended_partition_2)"
fi

SYS_AREA="$(xorriso -indev "$ISO" -report_system_area as_mkisofs 2>/dev/null)"
if printf '%s' "$SYS_AREA" | grep -q -- "--grub2-mbr"; then
    check "hybrid-mbr" 0 "grub2-mbr"
else
    check "hybrid-mbr" 1 "нет гибридного MBR grub2-mbr"
fi

# Структура дерева (xorriso -find; -osirrox не нужен для поиска имён).
# -find печатает пути в кавычках: '/boot/grub/grub.cfg'.
tree_has() { xorriso -osirrox on -indev "$ISO" -find "$1" -type f 2>/dev/null | grep -qx "'$1'"; }
if tree_has /boot/grub/grub.cfg; then
    check "tree-grub-cfg" 0 "/boot/grub/grub.cfg"
else
    check "tree-grub-cfg" 1 "нет /boot/grub/grub.cfg"
fi
if tree_has /boot/grub/i386-pc/eltorito.img; then
    check "tree-eltorito-img" 0 "/boot/grub/i386-pc/eltorito.img"
else
    check "tree-eltorito-img" 1 "нет /boot/grub/i386-pc/eltorito.img"
fi

# BOOTX64.EFI — ВНУТРИ appended EFI-раздела (partition 2), а не в дереве
# ISO9660: mkarchiso 92 кладёт efiboot.img только как appended partition.
# Исправлено 10.11.2026: прежняя проверка tree_has /EFI/BOOT/BOOTX64.EFI
# давала ложный FAIL и на чистом ISO от mkarchiso, и на гибридном
# (BOOTX64.EFI при этом реально есть в FAT-образе — проверено mdir
# и python3 FAT-walker'ом). Извлекаем раздел dd по интервалу из
# xorriso -report_system_area и проверяем mdir (если есть) или
# минимальным FAT-парсером на python3; если нет ни того, ни другого —
# SKIP (не FAIL): окончательная проверка уже выполнена postprocess'ом.
EFI_IMG="$(mktemp)"
trap 'rm -f "$REPORT" "$EFI_IMG"' EXIT
SYS_AREA_LINE="$(printf '%s' "$SYS_AREA" | grep -- '-append_partition 2 ' | head -1)"
EFI_START="$(printf '%s' "$SYS_AREA_LINE" | sed -n 's/.*local_fs:\([0-9]*\)d-.*/\1/p')"
EFI_END="$(printf '%s' "$SYS_AREA_LINE" | sed -n 's/.*local_fs:[0-9]*d-\([0-9]*\)d.*/\1/p')"
if [[ -n "$EFI_START" && -n "$EFI_END" && "$EFI_END" -gt "$EFI_START" ]]; then
    EFI_COUNT=$((EFI_END - EFI_START + 1))
    if dd if="$ISO" of="$EFI_IMG" bs=512 skip="$EFI_START" count="$EFI_COUNT" status=none 2>/dev/null \
        && [[ -s "$EFI_IMG" ]]; then
        if command -v mdir >/dev/null 2>&1; then
            if mdir -i "$EFI_IMG" ::/EFI/BOOT/BOOTX64.EFI >/dev/null 2>&1; then
                check "efi-bootx64" 0 "/EFI/BOOT/BOOTX64.EFI в appended EFI-разделе (mdir)"
            else
                check "efi-bootx64" 1 "нет /EFI/BOOT/BOOTX64.EFI в appended EFI-разделе (mdir)"
            fi
        elif command -v python3 >/dev/null 2>&1; then
            if python3 - "$EFI_IMG" <<'PYEOF' >/dev/null 2>&1
import struct, sys
data = open(sys.argv[1], 'rb').read()
def u16b(b, o): return struct.unpack_from('<H', b, o)[0]
def u32b(b, o): return struct.unpack_from('<I', b, o)[0]
bps = u16b(data, 11); spc = data[13]; res = u16b(data, 14); nfats = data[16]
root_entries = u16b(data, 17); fat_size = u16b(data, 22) or u32b(data, 36)
is32 = root_entries == 0
fat_off = res * bps
data_off = fat_off + nfats * fat_size * bps + (0 if is32 else root_entries * 32)
def fat_entry(c):
    return (u32b(data, fat_off + c * 4) & 0x0FFFFFFF) if is32 else u16b(data, fat_off + c * 2)
def coff(c): return data_off + (c - 2) * spc * bps
def read_chain(start):
    out = b''; c = start; seen = set()
    while 2 <= c < 0x0FFFFFF8 and c not in seen:
        seen.add(c); out += data[coff(c):coff(c) + spc * bps]; c = fat_entry(c)
    return out
def list_dir(blob):
    out = []
    for i in range(0, len(blob) - 31, 32):
        e = blob[i:i + 32]
        if e[0] == 0x00: break
        if e[0] == 0xE5 or e[11] == 0x0F: continue
        clus = u16b(e, 26) | ((u16b(e, 20) << 16) if is32 else 0)
        out.append((e[0:8].decode('ascii', 'replace').strip(), e[8:11].decode('ascii', 'replace').strip(), e[11], clus))
    return out
root = read_chain(u32b(data, 44)) if is32 else data[fat_off + nfats * fat_size * bps: fat_off + nfats * fat_size * bps + root_entries * 32]
cur = list_dir(root)
for want_name in ['EFI', 'BOOT', 'BOOTX64.EFI']:
    hit = None
    for (name, ext, attr, clus) in cur:
        if name + ('.' + ext if ext else '') == want_name:
            hit = (attr, clus); break
    if hit is None: sys.exit(1)
    if want_name == 'BOOTX64.EFI': sys.exit(0)
    cur = list_dir(read_chain(hit[1]))
PYEOF
            then
                check "efi-bootx64" 0 "/EFI/BOOT/BOOTX64.EFI в appended EFI-разделе (python3 FAT)"
            else
                check "efi-bootx64" 1 "нет /EFI/BOOT/BOOTX64.EFI в appended EFI-разделе (python3 FAT)"
            fi
        else
            skip "efi-bootx64" "нет mdir и python3 для проверки FAT-образа"
        fi
    else
        check "efi-bootx64" 1 "не удалось извлечь appended EFI-раздел"
    fi
else
    check "efi-bootx64" 1 "нет appended partition 2 в system area"
fi

# Штатные пути mkarchiso — только с --archiso.
if [[ "$EXPECT_ARCHISO" -eq 1 ]]; then
    if tree_has /xros/boot/x86_64/vmlinuz-linux; then
        check "archiso-vmlinuz" 0 "/xros/boot/x86_64/vmlinuz-linux"
    else
        check "archiso-vmlinuz" 1 "нет /xros/boot/x86_64/vmlinuz-linux"
    fi
    if tree_has /xros/boot/x86_64/initramfs-linux.img; then
        check "archiso-initramfs" 0 "/xros/boot/x86_64/initramfs-linux.img"
    else
        check "archiso-initramfs" 1 "нет /xros/boot/x86_64/initramfs-linux.img"
    fi
else
    skip "archiso-vmlinuz" "без --archiso (экспериментальный ISO не содержит /xros/boot/...)"
    skip "archiso-initramfs" "без --archiso"
fi

if [[ "$MEDIA_CHECK" -eq 1 ]]; then
    MEDIA_OUT="$(mktemp)"
    if xorriso -indev "$ISO" -check_media -- >"$MEDIA_OUT" 2>&1; then
        check "media-check" 0 "xorriso -check_media: код 0"
    else
        check "media-check" 1 "xorriso -check_media: код != 0: $(grep -a -m1 -i -E 'fail|error' "$MEDIA_OUT" | head -c 200)"
    fi
    rm -f "$MEDIA_OUT"
else
    skip "media-check" "--no-media-check"
fi

echo "check-iso: ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[[ "$FAIL" -eq 0 ]]
