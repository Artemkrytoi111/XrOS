#!/usr/bin/env bash
# XrOS — проверка SigLevel = Required в секции [xros] pacman.conf (R-01).
#
# Использование: check-siglevel-required.sh <pacman.conf> [<pacman.conf>...]
# Для каждого файла требует ровно одну активную директиву SigLevel
# в секции [xros] со значением Required. Комментарии (#...), пустые
# строки и директивы вне [xros] (в том числе глобальная
# SigLevel = Required DatabaseOptional) не учитываются. Пробелы и
# табы перед директивой и вокруг '=' допускаются. Значение обязано
# быть ровно Required: Required DatabaseOptional в [xros] тоже
# отклоняется (БД репозитория проверяется отдельно гейтом, а в
# установленной системе подпись БД должна требоваться тоже).
# Выход 0 — все файлы в порядке; иначе 1 и причина в stderr.
# Используется release_gate() в scripts/build.sh (вместо прежнего
# awk, который находил SigLevel = Required внутри комментария,
# R-01). Тесты: scripts/tests/test-release-gate-siglevel.sh.
set -euo pipefail

[[ $# -ge 1 ]] || { echo "check-siglevel-required: использование: $0 <pacman.conf>..." >&2; exit 2; }

fail=0
for f in "$@"; do
  [[ -f "$f" ]] || { echo "check-siglevel: нет файла: $f" >&2; fail=1; continue; }
  mapfile -t _vals < <(awk '
    {
      line = $0
      sub(/#.*/, "", line)
      if (line ~ /^\[.*\][[:space:]]*$/) {
        in_xros = (line ~ /^\[xros\][[:space:]]*$/)
        next
      }
      if (in_xros && line ~ /^[[:space:]]*SigLevel[[:space:]]*=/) {
        val = line
        sub(/^[[:space:]]*SigLevel[[:space:]]*=[[:space:]]*/, "", val)
        sub(/[[:space:]]+$/, "", val)
        print val
      }
    }' "$f")
  if [[ "${#_vals[@]}" -eq 0 ]]; then
    echo "check-siglevel: $f: нет активной директивы SigLevel в секции [xros]" >&2; fail=1
  elif [[ "${#_vals[@]}" -gt 1 ]]; then
    echo "check-siglevel: $f: дублирующаяся директива SigLevel в [xros] (${#_vals[@]} шт.): ${_vals[*]}" >&2; fail=1
  elif [[ "${_vals[0]}" != "Required" ]]; then
    echo "check-siglevel: $f: SigLevel = ${_vals[0]} в [xros], требуется ровно Required" >&2; fail=1
  else
    echo "check-siglevel: OK: $f (SigLevel = Required)"
  fi
done
[[ "$fail" -eq 0 ]] || exit 1
