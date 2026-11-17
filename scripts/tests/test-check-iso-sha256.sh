#!/usr/bin/env bash
# XrOS — тесты проверки SHA-256 ISO (A-39).
#
# Проверяется НАСТОЯЩИЙ scripts/check-iso.sh на поддельных ISO
# (файлы по 1 МБ, не настоящие образы; mkarchiso не запускается):
# xorriso и mdir — заглушки на PATH, возвращающие правдоподобные
# ответы, чтобы остальные проверки (El Torito, MBR, дерево, EFI,
# media) проходили и итог определялся только вердиктом iso-sha256.
# Матрица: правильный/неправильный хеш, отсутствующий файл/запись,
# пустой файл, невалидный хеш, дубли, повреждённый файл, CRLF,
# имя ISO с пробелами, старый хеш после пересборки, первая сборка.
# Плюс статика: порядок шагов в scripts/build.sh.
#
# Запуск: ./scripts/tests/test-check-iso-sha256.sh
# Выход: 0 — все PASS, 1 — есть FAIL.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK_ISO="$ROOT/scripts/check-iso.sh"
PASS=0; FAIL=0; SKIPN=0
FAILED=()
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL  $1"; }
skip() { SKIPN=$((SKIPN+1)); echo "SKIP  $1 ($2)"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# --- заглушки xorriso/mdir (правдоподобные ответы) ---
mkdir -p "$T/bin"
cat > "$T/bin/xorriso" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"-pvd_info"*) echo "Volume Id : XROS_202611" ;;
  *"-report_el_torito"*) printf -- "-b 'boot/grub/i386-pc/eltorito.img'\n-e '--interval:appended_partition_2:2::'\n" ;;
  *"-report_system_area"*) printf -- "--grub2-mbr\n-append_partition 2 --interval:local_fs:100d-200d::\n" ;;
  *"-find"*) echo "'/boot/grub/grub.cfg'"; echo "'/boot/grub/i386-pc/eltorito.img'"; echo "'/xros/boot/x86_64/vmlinuz-linux'"; echo "'/xros/boot/x86_64/initramfs-linux.img'" ;;
  *"-check_media"*) exit 0 ;;
esac
exit 0
EOF
cat > "$T/bin/mdir" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$T/bin/xorriso" "$T/bin/mdir"
export PATH="$T/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# --- поддельный ISO (1 МБ нулей: dd-извлечение EFI-раздела работает) ---
ISO="$T/test.iso"
truncate -s 1M "$ISO"

run_case() { # $1=имя $2=режим(optional|required) $3=вердикт(PASS|FAIL|SKIP) $4=код выхода(0|1)
  local name="$1" mode="$2" want="$3" want_rc="$4"
  local out rc verdict
  if [[ "$mode" == "required" ]]; then
    out="$("$CHECK_ISO" --require-sha256 "$ISO" 2>&1)"; rc=$?
  else
    out="$("$CHECK_ISO" "$ISO" 2>&1)"; rc=$?
  fi
  verdict="$(printf '%s\n' "$out" | grep -oE '^(PASS|FAIL|SKIP)  iso-sha256' | head -1 | cut -d' ' -f1)"
  if [[ "$verdict" == "$want" && "$rc" == "$want_rc" ]]; then
    ok "sha256 $name [$mode]: $want, exit $want_rc"
  else
    bad "sha256 $name [$mode]: ожидалось $want/exit $want_rc, получено ${verdict:-?}/exit $rc"
    printf '%s\n' "$out" | grep -E "iso-sha256|ИТОГ" | head -3
  fi
}
write_sums() { # $1=содержимое SHA256SUMS (уже готовые строки)
  printf '%s\n' "$1" > "$T/SHA256SUMS"
}
correct_sums() { (cd "$T" && sha256sum "$(basename "$ISO")"); }

# 1. Правильный хеш.
write_sums "$(correct_sums)"
run_case "правильный хеш" optional PASS 0
run_case "правильный хеш" required PASS 0
# 2. Неправильный хеш.
write_sums "0000000000000000000000000000000000000000000000000000000000000000  test.iso"
run_case "неправильный хеш" optional FAIL 1
# 3. Отсутствует файл (первая сборка).
rm -f "$T/SHA256SUMS"
run_case "нет файла (первая сборка)" optional SKIP 0
run_case "нет файла (первая сборка)" required FAIL 1
# 4. Нет записи для этого ISO.
write_sums "1111111111111111111111111111111111111111111111111111111111111111  other.iso"
run_case "нет записи для ISO" optional SKIP 0
run_case "нет записи для ISO" required FAIL 1
# 5. Пустой файл.
: > "$T/SHA256SUMS"
run_case "пустой файл" optional SKIP 0
run_case "пустой файл" required FAIL 1
# 6. Невалидный хеш (64 символа, но не hex).
write_sums "gggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggggg  test.iso"
run_case "невалидный хеш" optional FAIL 1
# 7. Дублирующая запись.
write_sums "$(correct_sums)
$(correct_sums)"
run_case "дублирующая запись" optional FAIL 1
# 8. Повреждённый файл (мусорная строка).
write_sums "this is not a sha256sums file at all"
run_case "повреждённый файл" optional FAIL 1
# 8б. Повреждённый файл (короткий хеш).
write_sums "abc123  test.iso"
run_case "повреждённый файл (короткий хеш)" optional FAIL 1
# 9. CRLF (валидная запись с \r\n).
printf '%s\r\n' "$(correct_sums)" > "$T/SHA256SUMS"
run_case "CRLF" optional PASS 0
# 10. Имя ISO с пробелами.
ISO2="$T/my iso.iso"
truncate -s 1M "$ISO2"
(cd "$T" && sha256sum "my iso.iso") > "$T/SHA256SUMS"
OLD_ISO="$ISO"; ISO="$ISO2"
run_case "имя ISO с пробелами" optional PASS 0
ISO="$OLD_ISO"
# 11. Старый хеш после пересборки (содержимое изменилось, SHA256SUMS старый).
write_sums "$(correct_sums)"
printf 'changed' >> "$ISO"
run_case "старый хеш после пересборки" optional FAIL 1
# 12. Повторная сборка: файл есть, запись есть, хеш совпадает.
truncate -s 1M "$ISO"
write_sums "$(correct_sums)"
run_case "повторная сборка (свежий хеш)" optional PASS 0

# --- статика: порядок шагов в build.sh ---
BUILD="$ROOT/scripts/build.sh"
if grep -q -- '--require-sha256' "$BUILD"; then
  ok "build.sh: check-iso вызывается с --require-sha256"
else
  bad "build.sh: check-iso вызывается с --require-sha256"
fi
_sums_line="$(grep -n 'sha256sum.*> SHA256SUMS' "$BUILD" | head -1 | cut -d: -f1)"
_check_line="$(grep -nF '"$CHECK_ISO" --archiso --require-sha256' "$BUILD" | head -1 | cut -d: -f1)"
if [[ -n "$_sums_line" && -n "$_check_line" && "$_sums_line" -lt "$_check_line" ]]; then
  ok "build.sh: SHA256SUMS создаётся ДО проверки check-iso"
else
  bad "build.sh: SHA256SUMS создаётся ДО проверки check-iso"
fi
# Шаг 10 обязан удалять и устаревший SHA256SUMS (строка rm -rf с WORK).
_rm_line="$(grep -nF 'rm -rf "$WORK"' "$BUILD" | head -1 | cut -d: -f1)"
if [[ -n "$_rm_line" ]] && sed -n "${_rm_line}p" "$BUILD" | grep -q 'SHA256SUMS'; then
  ok "build.sh: шаг 10 удаляет устаревший SHA256SUMS"
else
  bad "build.sh: шаг 10 удаляет устаревший SHA256SUMS"
fi
# Ложный PASS невозможен: в check-iso.sh не осталось check "iso-sha256" 0
# с текстом «сверка невозможна».
if grep -q 'сверка невозможна' "$CHECK_ISO"; then
  bad "check-iso.sh: не осталось ложного PASS «сверка невозможна»"
else
  ok "check-iso.sh: не осталось ложного PASS «сверка невозможна»"
fi

echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
if [[ $FAIL -gt 0 ]]; then
  echo "Не пройдено:"
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
