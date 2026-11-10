#!/bin/bash
# test-perms-regression.sh — регрессионный тест чекера прав rootfs.
# Доказывает, что scripts/check-rootfs-perms.sh ДЕЙСТВИТЕЛЬНО обнаруживает
# искусственно внесённое нарушение 2770 (и другие), а не просто всегда
# возвращает PASS. Тест работает на ОТДЕЛЬНОЙ копии (subset реального
# live-rootfs) в scratch-каталоге и НЕ изменяет рабочий rootfs.
# Использование: test-perms-regression.sh [--keep] (без --keep scratch удаляется).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/scripts/check-rootfs-perms.sh"
LIVE="$HOME/workspace/xros-backups/xros-20261110-final-validation/live-rootfs"
SCRATCH="$ROOT/.perms-regression-scratch"
KEEP=0; [[ "${1:-}" == "--keep" ]] && KEEP=1
PASS_N=0; FAIL_N=0
result() { # result <имя> <ожидаемый-код> <фактический-код>
  if [[ "$2" == "$3" ]]; then echo "PASS: $1 (код $3 как ожидалось)"; PASS_N=$((PASS_N+1));
  else echo "FAIL: $1 (ожидался код $2, получен $3)"; FAIL_N=$((FAIL_N+1)); fi
}

echo "=== Подготовка тестовой копии (subset live-rootfs, НЕ рабочий rootfs) ==="
rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/rootfs"
# Реальные файлы и режимы из распакованного live-rootfs (маленький subset).
cp -a "$LIVE/etc" "$SCRATCH/rootfs/" 2>/dev/null || mkdir -p "$SCRATCH/rootfs/etc"
cp -a "$LIVE/usr" "$SCRATCH/rootfs/" 2>/dev/null || mkdir -p "$SCRATCH/rootfs/usr"
# usr из live-rootfs большой; для скорости теста оставляем только часть,
# но структура usr/ и его режим сохраняются (cp -a сохраняет режим 2755).
# Если usr скопировался целиком — обрежем тяжёлые каталоги, режим не трогаем.
rm -rf "$SCRATCH/rootfs/usr/lib/firmware" "$SCRATCH/rootfs/usr/share/doc" 2>/dev/null || true
cp -a "$LIVE/home" "$SCRATCH/rootfs/" 2>/dev/null || mkdir -p "$SCRATCH/rootfs/home"
mkdir -p "$SCRATCH/rootfs/tmp" "$SCRATCH/rootfs/root" "$SCRATCH/rootfs/var/log"
# ВНИМАНИЕ: mkdir в setgid-каталоге хоста с umask 0007 даёт новым
# каталогам 2770 (тот самый дефект 10.11.2026!) — ставим режимы явно,
# иначе чистая копия не будет чистой.
chmod 755 "$SCRATCH/rootfs" "$SCRATCH/rootfs/var" "$SCRATCH/rootfs/var/log"
chmod 1777 "$SCRATCH/rootfs/tmp"; chmod 750 "$SCRATCH/rootfs/root"
# Сентинел: режим реального rootfs до и после теста (доказательство, что он не тронут).
SENTINEL_MODE_BEFORE="$(stat -c %a "$ROOT/work/x86_64/airootfs/usr" 2>/dev/null || echo NA)"
SENTINEL_LIVE_BEFORE="$(stat -c %a "$LIVE/usr" 2>/dev/null || echo NA)"

echo "=== Тест 1: чистая копия — чекер должен PASS (код 0) ==="
"$CHECK" "$SCRATCH/rootfs" >/dev/null 2>&1; result "чистая копия PASS" 0 $?

echo "=== Тест 2: каталог 2770 в usr — чекер должен FAIL (код 1) ==="
cp -a "$SCRATCH/rootfs" "$SCRATCH/case2"
chmod 2770 "$SCRATCH/case2/usr"
"$CHECK" "$SCRATCH/case2" >/dev/null 2>&1; result "2770 в /usr обнаружен" 1 $?

echo "=== Тест 3: каталог 2770 в etc — чекер должен FAIL ==="
cp -a "$SCRATCH/rootfs" "$SCRATCH/case3"
chmod 2770 "$SCRATCH/case3/etc"
"$CHECK" "$SCRATCH/case3" >/dev/null 2>&1; result "2770 в /etc обнаружен" 1 $?

echo "=== Тест 4: файл 660 — чекер должен FAIL ==="
cp -a "$SCRATCH/rootfs" "$SCRATCH/case4"
touch "$SCRATCH/case4/etc/test-secret.conf"; chmod 660 "$SCRATCH/case4/etc/test-secret.conf"
"$CHECK" "$SCRATCH/case4" >/dev/null 2>&1; result "файл 660 обнаружен" 1 $?

echo "=== Тест 5: /usr 0700 (ограничительный режим) — чекер должен FAIL ==="
cp -a "$SCRATCH/rootfs" "$SCRATCH/case5"
chmod 0700 "$SCRATCH/case5/usr"
"$CHECK" "$SCRATCH/case5" >/dev/null 2>&1; result "/usr 0700 обнаружен" 1 $?

echo "=== Тест 6: файл 777 — чекер должен FAIL ==="
cp -a "$SCRATCH/rootfs" "$SCRATCH/case6"
touch "$SCRATCH/case6/etc/test-open.sh"; chmod 777 "$SCRATCH/case6/etc/test-open.sh"
"$CHECK" "$SCRATCH/case6" >/dev/null 2>&1; result "файл 777 обнаружен" 1 $?

echo "=== Тест 7: рабочий rootfs не тронут ==="
SENTINEL_MODE_AFTER="$(stat -c %a "$ROOT/work/x86_64/airootfs/usr" 2>/dev/null || echo NA)"
SENTINEL_LIVE_AFTER="$(stat -c %a "$LIVE/usr" 2>/dev/null || echo NA)"
if [[ "$SENTINEL_MODE_BEFORE" == "$SENTINEL_MODE_AFTER" && "$SENTINEL_LIVE_BEFORE" == "$SENTINEL_LIVE_AFTER" ]]; then
  echo "PASS: рабочий rootfs не изменён (/usr=$SENTINEL_MODE_AFTER, live /usr=$SENTINEL_LIVE_AFTER)"; PASS_N=$((PASS_N+1))
else
  echo "FAIL: рабочий rootfs ИЗМЕНЁН (было $SENTINEL_MODE_BEFORE/$SENTINEL_LIVE_BEFORE, стало $SENTINEL_MODE_AFTER/$SENTINEL_LIVE_AFTER)"; FAIL_N=$((FAIL_N+1))
fi
# И сам чекер на рабочем rootfs по-прежнему PASS.
"$CHECK" "$ROOT/work/x86_64/airootfs" >/dev/null 2>&1; result "рабочий rootfs по-прежнему PASS" 0 $?

[[ "$KEEP" -eq 0 ]] && rm -rf "$SCRATCH"
echo "=== ИТОГ: PASS=$PASS_N FAIL=$FAIL_N ==="
[[ "$FAIL_N" -eq 0 ]] && exit 0 || exit 1
