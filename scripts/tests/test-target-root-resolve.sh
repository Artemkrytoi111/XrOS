#!/usr/bin/env bash
# XrOS — тест R-22: разрешение путей внутри target root (chroot-семантика).
#
# Проверяет исправление трёх находок R-21:
#   R21-A-LOW-1 — xros_disable_dm не обнаруживал цепочки абсолютных
#                 симлинков (только один уровень readlink);
#   R21-A-LOW-2 — [ -e "$f" ] разрешал абсолютные симлинки относительно
#                 хоста (файл на хосте делал целевой симлинк «существующим»);
#   R21-B-LOW-1 — xros_verify_default_target принимал юнит-симлинк на
#                 хостовый файл с [Unit].
#
# Все пути и симлинки установленной системы должны разрешаться в
# контексте $TARGET, а не корневой файловой системы хоста.
# Resolver: xros_resolve_in_target() — покомпонентный, с лимитом
# переходов 40, '.' пропускаются, '..' не выходят выше корня цели,
# абсолютные цели — относительно $TARGET, относительные — относительно
# каталога симлинка, промежуточные симлинки тоже разрешаются.
#
# Слои:
#   R — resolver напрямую: обычные файлы, абсолютные/относительные
#       симлинки, цепочки, '..', промежуточные симлинки, циклы,
#       висячие ссылки, хостовые файлы, маски, выход за корень.
#   A — xros_disable_dm (A01–A14): реальный systemctl --root на
#       временном target root; проверяется и код возврата helper,
#       и факт вызова/невызова `systemctl disable` (calls.log).
#   B — xros_verify_default_target (B01–B12): тот же временный root;
#       B05/B06 доказывают, что содержимое хостового файла не
#       используется для получения PASS.
#
# Helper извлекаются ДОСЛОВНО из актуального движка (awk по границам
# функций) — тест проверяет production-код, а не копию.
# systemctl — настоящий (systemctl 255, --root на временном root),
# заглушка arch-chroot только транслирует вызов.
#
# Использование:
#   ./scripts/tests/test-target-root-resolve.sh        # из корня проекта
#   bash scripts/tests/test-target-root-resolve.sh     # то же
# Выход: 0, если все проверки PASS; 1, если есть хоть один FAIL.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/src/xros-install"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL  $1"; }

# --- Извлечь helper дословно из движка ---
T="$(mktemp -d /tmp/xros-resolve-test.XXXXXX)"
trap 'rm -rf "$T"' EXIT
LOG="$T/test.log"; : > "$LOG"
say() { echo "say: $*" >> "$LOG"; }
export LOG
awk '/^xros_resolve_in_target\(\) \{$/{on=1} on{print} on&&/^}$/{exit}' "$ENGINE" > "$T/resolve.sh"
awk '/^xros_disable_dm\(\) \{$/{on=1} on{print} on&&/^}$/{exit}' "$ENGINE" > "$T/disable.sh"
awk '/^xros_verify_default_target\(\) \{$/{on=1} on{print} on&&/^}$/{exit}' "$ENGINE" > "$T/verify.sh"
# shellcheck disable=SC1090
source "$T/resolve.sh"; source "$T/disable.sh"; source "$T/verify.sh"

# --- Заглушка arch-chroot: настоящий systemctl --root ---
CALLS="$T/calls.log"; : > "$CALLS"
arch-chroot() {
  local tgt="$1"; shift
  if [[ "$1" == "systemctl" ]]; then
    shift
    echo "systemctl $* (root=$tgt)" >> "$CALLS"
    systemctl --root="$tgt" "$@"
    return $?
  fi
  echo "arch-chroot: не-systemctl вызов: $*" >> "$CALLS"; return 1
}

# --- Стенд ---
mkroot() {
  local d="$1"
  mkdir -p "$d/usr/lib/systemd/system" "$d/usr/local/lib/systemd/system" "$d/etc/systemd/system" "$d/etc"
  printf '[Unit]\nDescription=multi\n' > "$d/usr/lib/systemd/system/multi-user.target"
  printf '[Unit]\nDescription=graph\n' > "$d/usr/lib/systemd/system/graphical.target"
}
mkunit() { printf '[Unit]\nDescription=%s\n' "$2" > "$1/usr/lib/systemd/system/$2"; }

# --- R: resolver напрямую ---
# $1=id $2=ожидаемый rc $3=путь $4=ожидаемый суффикс ('' = не проверять)
chk_resolve() {
  local id="$1" want_rc="$2" path="$3" want_suffix="$4" got rc
  got="$(xros_resolve_in_target "$path" 2>/dev/null)"; rc=$?
  if [[ "$rc" == "$want_rc" ]] && { [[ -z "$want_suffix" ]] || [[ "$got" == *"$want_suffix" ]]; }; then
    ok "$id (rc=$rc)"
  else
    bad "$id want rc=$want_rc got rc=$rc got=$got path=$path"
  fi
}
R="$T/resolver"; rm -rf "$R"; mkroot "$R"; TARGET="$R"
printf '[Unit]\nDescription=real\n' > "$R/usr/lib/systemd/system/gdm-real.service"
printf '[Unit]\nDescription=real\n' > "$R/etc/systemd/system/other.service"
mkdir -p "$R/usr/lib/systemd/system-real"
printf '[Unit]\nDescription=deep\n' > "$R/usr/lib/systemd/system-real/deep.service"
ln -s /usr/lib/systemd/system/gdm-real.service "$R/usr/lib/systemd/system/gdm-abs.service"
ln -s gdm-real.service "$R/usr/lib/systemd/system/gdm-rel.service"
ln -s /usr/lib/systemd/system/gdm-abs.service "$R/usr/lib/systemd/system/gdm-chain-aa.service"
ln -s gdm-abs.service "$R/usr/lib/systemd/system/gdm-chain-ra.service"
ln -s /usr/lib/systemd/system/gdm-rel.service "$R/usr/lib/systemd/system/gdm-chain-ar.service"
ln -s /usr/lib/systemd/system/../../systemd/system/gdm-real.service "$R/usr/lib/systemd/system/gdm-dotdot.service"
ln -s /etc/hostname "$R/usr/lib/systemd/system/gdm-hostonly.service"
ln -s /nonexistent-xyz.service "$R/usr/lib/systemd/system/gdm-dang-abs.service"
ln -s nonexistent-xyz.service "$R/usr/lib/systemd/system/gdm-dang-rel.service"
ln -s gdm-cycle-b.service "$R/usr/lib/systemd/system/gdm-cycle-a.service"
ln -s gdm-cycle-a.service "$R/usr/lib/systemd/system/gdm-cycle-b.service"
ln -s /usr/lib/systemd/system/multi-user.target "$R/etc/systemd/system/default.target"
ln -s system-real "$R/usr/lib/systemd/system-link"
ln -s /dev/null "$R/usr/lib/systemd/system/gdm-mask.service"
ln -s /../../../../etc/passwd "$R/usr/lib/systemd/system/gdm-escape.service"
chk_resolve "R01: обычный файл" 0 /usr/lib/systemd/system/gdm-real.service /usr/lib/systemd/system/gdm-real.service
chk_resolve "R02: абсолютный симлинк" 0 /usr/lib/systemd/system/gdm-abs.service /usr/lib/systemd/system/gdm-real.service
chk_resolve "R03: относительный симлинк" 0 /usr/lib/systemd/system/gdm-rel.service /usr/lib/systemd/system/gdm-real.service
chk_resolve "R04: цепочка absolute->absolute->file" 0 /usr/lib/systemd/system/gdm-chain-aa.service /usr/lib/systemd/system/gdm-real.service
chk_resolve "R05: цепочка relative->absolute->file" 0 /usr/lib/systemd/system/gdm-chain-ra.service /usr/lib/systemd/system/gdm-real.service
chk_resolve "R06: цепочка absolute->relative->file" 0 /usr/lib/systemd/system/gdm-chain-ar.service /usr/lib/systemd/system/gdm-real.service
chk_resolve "R07: абсолютная цель с .." 0 /usr/lib/systemd/system/gdm-dotdot.service /usr/lib/systemd/system/gdm-real.service
chk_resolve "R08: абсолютный симлинк на хостовый файл" 1 /usr/lib/systemd/system/gdm-hostonly.service ''
chk_resolve "R09: висячий абсолютный симлинк" 1 /usr/lib/systemd/system/gdm-dang-abs.service ''
chk_resolve "R10: висячий относительный симлинк" 1 /usr/lib/systemd/system/gdm-dang-rel.service ''
chk_resolve "R11: циклическая ссылка" 2 /usr/lib/systemd/system/gdm-cycle-a.service ''
chk_resolve "R12: default.target -> multi-user.target" 0 /etc/systemd/system/default.target /usr/lib/systemd/system/multi-user.target
chk_resolve "R13: промежуточный симлинк каталога" 0 /usr/lib/systemd/system-link/deep.service /usr/lib/systemd/system-real/deep.service
chk_resolve "R14: симлинк на /dev/null (маска: существует, т.к. arch-chroot bind-mountит /dev)" 0 /usr/lib/systemd/system/gdm-mask.service /dev/null
chk_resolve "R15: попытка выйти за корень через .." 1 /usr/lib/systemd/system/gdm-escape.service ''
chk_resolve "R16: путь с ." 0 /usr/lib/systemd/system/./gdm-real.service /usr/lib/systemd/system/gdm-real.service
chk_resolve "R17: путь с .." 0 /usr/lib/systemd/system/../system/gdm-real.service /usr/lib/systemd/system/gdm-real.service
chk_resolve "R18: корень цели" 0 / /
chk_resolve "R19: отсутствующий файл" 1 /usr/lib/systemd/system/nope.service ''

# --- A: xros_disable_dm (A01–A14) ---
# $1=id $2=ожидаемый rc $3=ожидается ли вызов disable (yes/no) $4=сетап
run_a() {
  local id="$1" want_rc="$2" want_call="$3"
  local d="$T/tgt-a-$id"
  rm -rf "$d"; mkroot "$d"; TARGET="$d"; : > "$CALLS"
  eval "$4"
  ( xros_disable_dm "gdm.service" >>"$LOG" 2>&1 ); local rc=$?
  local called=no; grep -q 'disable gdm.service' "$CALLS" && called=yes
  if [[ "$rc" == "$want_rc" && "$called" == "$want_call" ]]; then ok "$id (rc=$rc call=$called)"; else bad "$id want rc=$want_rc call=$want_call got rc=$rc call=$called"; fi
}
run_a "A01: обычный файл юнита" 0 yes 'mkunit "$d" gdm.service'
run_a "A02: абсолютный симлинк на файл внутри цели" 0 yes 'mkunit "$d" gdm-real.service; ln -s /usr/lib/systemd/system/gdm-real.service "$d/usr/lib/systemd/system/gdm.service"'
run_a "A03: цепочка absolute->absolute->file" 0 yes 'mkunit "$d" gdm-real.service; ln -s /usr/lib/systemd/system/gdm-real.service "$d/usr/lib/systemd/system/gdm-mid.service"; ln -s /usr/lib/systemd/system/gdm-mid.service "$d/usr/lib/systemd/system/gdm.service"'
run_a "A04: цепочка relative->absolute->file" 0 yes 'mkunit "$d" gdm-real.service; ln -s /usr/lib/systemd/system/gdm-real.service "$d/usr/lib/systemd/system/gdm-mid.service"; ln -s gdm-mid.service "$d/usr/lib/systemd/system/gdm.service"'
run_a "A05: цепочка absolute->relative->file" 0 yes 'mkunit "$d" gdm-real.service; ln -s gdm-real.service "$d/usr/lib/systemd/system/gdm-mid.service"; ln -s /usr/lib/systemd/system/gdm-mid.service "$d/usr/lib/systemd/system/gdm.service"'
run_a "A06: относительная ссылка с .. в пределах root" 0 yes 'mkunit "$d" gdm-real.service; ln -s /usr/lib/systemd/system/../system/gdm-real.service "$d/usr/lib/systemd/system/gdm.service"'
run_a "A07: абсолютная ссылка на файл, существующий только на хосте" 0 no 'ln -s /etc/hostname "$d/usr/lib/systemd/system/gdm.service"'
run_a "A08: висячий абсолютный симлинк" 0 no 'ln -s /nonexistent-gdm.service "$d/usr/lib/systemd/system/gdm.service"'
run_a "A09: висячий относительный симлинк" 0 no 'ln -s nonexistent-gdm.service "$d/usr/lib/systemd/system/gdm.service"'
run_a "A10: циклическая ссылка (fail-closed)" 1 no 'ln -s gdm-cycle-b.service "$d/usr/lib/systemd/system/gdm.service"; ln -s gdm.service "$d/usr/lib/systemd/system/gdm-cycle-b.service"'
run_a "A11: промежуточные симлинки (каталог + цепочка)" 0 yes 'mkdir -p "$d/usr/lib/systemd/system-real"; printf "[Unit]\nDescription=deep\n" > "$d/usr/lib/systemd/system-real/gdm.service"; ln -s system-real "$d/usr/lib/systemd/system-link"; ln -s /usr/lib/systemd/system-link/gdm.service "$d/usr/lib/systemd/system/gdm.service"'
run_a "A12: каталог вместо файла (systemctl отклоняет, fail-closed)" 1 yes 'mkdir "$d/usr/lib/systemd/system/gdm.service"'
run_a "A13: путь с . и .." 0 yes 'mkunit "$d" gdm-real.service; ln -s ./gdm-real.service "$d/usr/lib/systemd/system/gdm.service"'
run_a "A14: попытка выйти за пределы цели" 0 no 'ln -s /../../../../etc/passwd "$d/usr/lib/systemd/system/gdm.service"'

# --- B: xros_verify_default_target (B01–B12) ---
# $1=id $2=ожидаемый rc $3=сетап
run_b() {
  local id="$1" want_rc="$2"
  local d="$T/tgt-b-$id"
  rm -rf "$d"; mkroot "$d"
  # shellcheck disable=SC2034
  TARGET="$d"
  eval "$3"
  ( xros_verify_default_target "multi-user.target" >>"$LOG" 2>&1 ); local rc=$?
  if [[ "$rc" == "$want_rc" ]]; then ok "$id (rc=$rc)"; else bad "$id want rc=$want_rc got rc=$rc"; fi
}
run_b "B01: корректный default.target внутри цели" 0 'ln -s /usr/lib/systemd/system/multi-user.target "$d/etc/systemd/system/default.target"'
run_b "B02: абсолютная цель внутри цели" 0 'ln -s /usr/lib/systemd/system/multi-user.target "$d/etc/systemd/system/default.target"'
run_b "B03: относительная цель внутри цели" 0 'ln -s ../../../usr/lib/systemd/system/multi-user.target "$d/etc/systemd/system/default.target"'
run_b "B04: цепочка симлинков внутри цели" 0 'rm "$d/usr/lib/systemd/system/multi-user.target"; ln -s multi-mid.target "$d/usr/lib/systemd/system/multi-user.target"; ln -s multi-real.target "$d/usr/lib/systemd/system/multi-mid.target"; printf "[Unit]\nDescription=real\n" > "$d/usr/lib/systemd/system/multi-real.target"; ln -s /usr/lib/systemd/system/multi-user.target "$d/etc/systemd/system/default.target"'
run_b "B05: цель — хостовый файл с [Unit]" 1 'rm "$d/usr/lib/systemd/system/multi-user.target"; ln -s /usr/lib/systemd/system/multi-user.target "$d/usr/lib/systemd/system/multi-user.target"; ln -s /usr/lib/systemd/system/multi-user.target "$d/etc/systemd/system/default.target"'
run_b "B06: цель отсутствует в цели, но существует на хосте" 1 'rm "$d/usr/lib/systemd/system/multi-user.target"; ln -s /usr/lib/systemd/system/multi-user.target "$d/etc/systemd/system/default.target"'
run_b "B07: циклическая цепочка (default -> multi-user -> multi-mid -> multi-user)" 1 'rm "$d/usr/lib/systemd/system/multi-user.target"; ln -s multi-mid.target "$d/usr/lib/systemd/system/multi-user.target"; ln -s multi-user.target "$d/usr/lib/systemd/system/multi-mid.target"; ln -s /usr/lib/systemd/system/multi-user.target "$d/etc/systemd/system/default.target"'
run_b "B08: цель на /dev/null (маска)" 1 'rm "$d/usr/lib/systemd/system/multi-user.target"; ln -s /dev/null "$d/usr/lib/systemd/system/multi-user.target"; ln -s /usr/lib/systemd/system/multi-user.target "$d/etc/systemd/system/default.target"'
run_b "B09: цель с неправильным именем" 1 'ln -s /usr/lib/systemd/system/graphical.target "$d/etc/systemd/system/default.target"'
run_b "B10: файл без [Unit]" 1 'printf "мусор без секции\n" > "$d/usr/lib/systemd/system/multi-user.target"; ln -s /usr/lib/systemd/system/multi-user.target "$d/etc/systemd/system/default.target"'
run_b "B11: висячий default.target" 1 'ln -s /usr/lib/systemd/system/nonexistent.target "$d/etc/systemd/system/default.target"'
run_b "B12: промежуточный симлинк выходит за root" 1 'rm "$d/usr/lib/systemd/system/multi-user.target"; ln -s /usr/lib/systemd/system/multi-user.target "$d/etc/systemd/system/default.target"; ln -s multi-mid.target "$d/usr/lib/systemd/system/multi-user.target"; ln -s /etc/hostname "$d/usr/lib/systemd/system/multi-mid.target"'

echo "ИТОГ: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" == "0" ]] && exit 0 || exit 1
