#!/usr/bin/env bash
# XrOS — тесты проверки SigLevel в release gate (R-01).
#
# Проверяется РЕАЛЬНЫЙ helper scripts/check-siglevel-required.sh —
# тот же скрипт, который вызывает release_gate() в scripts/build.sh
# (не grep по коду и не копия логики). Фикстуры — временные файлы
# в mktemp; production-конфигурации не подменяются: отдельный кейс
# проверяет, что реальные profile/pacman.conf и
# profile/airootfs/etc/pacman.conf (после подписания — Required)
# дают PASS.
#
# Запуск: ./scripts/tests/test-release-gate-siglevel.sh
# Выход: 0 — все PASS, 1 — есть FAIL. SKIP — честный пропуск.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="$ROOT/scripts/check-siglevel-required.sh"
PASS=0; FAIL=0; SKIPN=0
FAILED=()
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL  $1"; }
skip() { SKIPN=$((SKIPN+1)); echo "SKIP  $1 ($2)"; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

[[ -x "$CHECK" ]] || { bad "helper check-siglevel-required.sh исполняем"; echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"; exit 1; }
ok "helper check-siglevel-required.sh исполняем"

# run_pair <имя> <ожидаемое pass|fail> <конфиг1> <конфиг2>
run_pair() {
  local name="$1" want="$2" c1="$3" c2="$4"
  printf '%s\n' "$c1" > "$T/a.conf"
  printf '%s\n' "$c2" > "$T/b.conf"
  local got
  if "$CHECK" "$T/a.conf" "$T/b.conf" > "$T/out.log" 2>&1; then got="pass"; else got="fail"; fi
  if [[ "$got" == "$want" ]]; then ok "siglevel $name: $want"; else bad "siglevel $name: ожидалось $want, получено $got"; cat "$T/out.log"; fi
}

OPTIONAL='[options]
SigLevel = Required DatabaseOptional

[xros]
SigLevel = Optional
Server = https://example.invalid/xros/os/$arch'
REQUIRED='[options]
SigLevel = Required DatabaseOptional

[xros]
SigLevel = Required
Server = https://example.invalid/xros/os/$arch'

# 1. Optional в обоих файлах → FAIL.
run_pair "Optional в обоих" fail "$OPTIONAL" "$OPTIONAL"
# 2. Required только в первом → FAIL.
run_pair "Required только в первом" fail "$REQUIRED" "$OPTIONAL"
# 3. Required только во втором → FAIL.
run_pair "Required только во втором" fail "$OPTIONAL" "$REQUIRED"
# 4. Комментарий с SigLevel = Required + активный Optional → FAIL
#    (регрессия R-01: старый awk пропускал такой конфиг).
COMMENT_OPTIONAL='[options]
SigLevel = Required DatabaseOptional

[xros]
# и БД (repo-add -s) вернуть SigLevel = Required. TrustAll НЕ
# использовать.
SigLevel = Optional
Server = https://example.invalid/xros/os/$arch'
run_pair "комментарий Required + активный Optional" fail "$COMMENT_OPTIONAL" "$COMMENT_OPTIONAL"
# 4б. Тот же комментарий, но активный Required → PASS (комментарий
#    не мешает и не считается директивой).
COMMENT_REQUIRED='[options]
SigLevel = Required DatabaseOptional

[xros]
# и БД (repo-add -s) вернуть SigLevel = Required. TrustAll НЕ
# использовать.
SigLevel = Required
Server = https://example.invalid/xros/os/$arch'
run_pair "комментарий Required + активный Required" pass "$COMMENT_REQUIRED" "$COMMENT_REQUIRED"
# 5. Required в обоих → PASS.
run_pair "Required в обоих" pass "$REQUIRED" "$REQUIRED"
# 6. Отсутствующая секция [xros] → FAIL.
NO_SECTION='[options]
SigLevel = Required DatabaseOptional'
run_pair "нет секции [xros]" fail "$NO_SECTION" "$REQUIRED"
run_pair "нет секции [xros] в обоих" fail "$NO_SECTION" "$NO_SECTION"
# 7. Отсутствующая директива → FAIL.
NO_DIRECTIVE='[options]
SigLevel = Required DatabaseOptional

[xros]
Server = https://example.invalid/xros/os/$arch'
run_pair "нет директивы SigLevel" fail "$NO_DIRECTIVE" "$REQUIRED"
# 8. Дубликат директивы → FAIL.
DUPLICATE='[options]
SigLevel = Required DatabaseOptional

[xros]
SigLevel = Required
SigLevel = Optional
Server = https://example.invalid/xros/os/$arch'
run_pair "дубликат директивы" fail "$DUPLICATE" "$REQUIRED"
# 8б. Дубликат Required + Required → тоже FAIL (неоднозначность).
DUPLICATE_REQ='[options]
SigLevel = Required DatabaseOptional

[xros]
SigLevel = Required
SigLevel = Required
Server = https://example.invalid/xros/os/$arch'
run_pair "дубликат Required+Required" fail "$DUPLICATE_REQ" "$REQUIRED"
# 9. Пробелы и табуляция → корректная обработка.
WS_REQUIRED='[options]
SigLevel = Required DatabaseOptional

[xros]
	 SigLevel	 = 	Required
Server = https://example.invalid/xros/os/$arch'
run_pair "Required с табами и пробелами" pass "$WS_REQUIRED" "$WS_REQUIRED"
WS_OPTIONAL='[options]
SigLevel = Required DatabaseOptional

[xros]
	 SigLevel	 = 	Optional
Server = https://example.invalid/xros/os/$arch'
run_pair "Optional с табами и пробелами" fail "$WS_OPTIONAL" "$WS_OPTIONAL"
# 9б. Required с хвостовым комментарием → PASS.
TRAIL_COMMENT='[options]
SigLevel = Required DatabaseOptional

[xros]
SigLevel = Required  # production-режим
Server = https://example.invalid/xros/os/$arch'
run_pair "Required с хвостовым комментарием" pass "$TRAIL_COMMENT" "$TRAIL_COMMENT"
# 9в. SigLevel = Required DatabaseOptional в [xros] → FAIL
#    (требуется ровно Required, см. комментарий в helper'е).
REQ_DBOPT='[options]
SigLevel = Required DatabaseOptional

[xros]
SigLevel = Required DatabaseOptional
Server = https://example.invalid/xros/os/$arch'
run_pair "Required DatabaseOptional в [xros]" fail "$REQ_DBOPT" "$REQ_DBOPT"
# 9г. Глобальный Required не засчитывается как [xros] → FAIL.
GLOBAL_ONLY='[options]
SigLevel = Required DatabaseOptional

[xros]
SigLevel = Optional'
run_pair "глобальный Required + Optional в [xros]" fail "$GLOBAL_ONLY" "$GLOBAL_ONLY"

# Реальные production-конфигурации (Required) обязаны давать PASS:
# после подписания [xros] release gate открыт. Конфиги не подменяются.
if "$CHECK" "$ROOT/profile/pacman.conf" "$ROOT/profile/airootfs/etc/pacman.conf" > "$T/real.log" 2>&1; then
  ok "реальные pacman.conf (Required) дают PASS — release разрешён"
else
  bad "реальные pacman.conf (Required) обязаны давать PASS"
  cat "$T/real.log"
fi

# build.sh обязан вызывать helper, а старый awk — отсутствовать.
if grep -q 'check-siglevel-required.sh' "$ROOT/scripts/build.sh"; then
  ok "build.sh вызывает check-siglevel-required.sh"
else
  bad "build.sh вызывает check-siglevel-required.sh"
fi
if grep -q "SigLevel\[\\\\\[:space:\]\]\*=\[\\\\\[:space:\]\]\*Required" "$ROOT/scripts/build.sh"; then
  bad "build.sh: старый awk с SigLevel удалён"
else
  ok "build.sh: старый awk с SigLevel удалён"
fi

echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
[[ "$FAIL" -eq 0 ]] || exit 1
