#!/bin/bash
# check-rootfs-perms.sh — проверка прав rootfs XrOS (регрессионный контроль).
# Использование: check-rootfs-perms.sh <путь-к-rootfs>
# Возвращает 0, если права в порядке, 1 — при любом нарушении.
#
# Дефект 10.11.2026: /usr и /etc (и ещё 32 каталога) имели режим 2770
# вместо 0755 → EACCES для не-root процессов, 127 отказов в доступе,
# 91 перезапуск SDDM за 8 мин, чёрный экран. Этот скрипт — автоматический
# страж: он НЕ исправляет права, а только проверяет и ПАДАЕТ с точной
# причиной при нарушении. Исправление — только в исходниках сборки
# (scripts/build-rootfs-pacstrap.sh, шаги 4а/11б), после анализа.
#
# Допущения (документированы, не скрыты):
# - /usr и /etc принимаются как 0755 ИЛИ 2755: setgid-бит (2000)
#   наследуется от setgid-каталогов хоста при создании rootfs
#   и НЕ ограничивает доступ (2755 по доступу ≡ 0755). Чистый Arch
#   имеет 0755; 2755 — косметическое отличие, не дефект.
#   Любой ограничительный режим (0700, 0750, 2770 и т.п.) — FAIL.
# - /var/log/btmp и /var/log/lastlog — 660 root:utmp (штатный режим
#   Arch для учёта входов); открывать их всему миру НЕЛЬЗЯ.
# - Симлинки /bin, /sbin, /lib, /lib64 → usr/... имеют режим 777
#   (у симлинков всегда 777, это не права доступа к файлам);
#   проверяются цели (0755), а не сами ссылки.
# - /tmp — 1777 (или 3777 с наследованным setgid); /root — 750
#   (или 2750); /var/cache/ldconfig — 700 (или 2700);
#   /run, /dev, /sys, /proc — точки монтирования, 555 (или 2555).
set -u
ROOTFS="${1:-}"
if [[ -z "$ROOTFS" || ! -d "$ROOTFS" ]]; then
  echo "ОШИБКА: укажите существующий каталог rootfs: $0 <путь-к-rootfs>" >&2
  exit 2
fi
FAIL=0
fail() { echo "FAIL: $1" >&2; FAIL=1; }
ok()   { echo "PASS: $1"; }

# 1. /usr и /etc — 0755 или 2755 (доступ ≡ 0755).
for d in usr etc; do
  mode="$(stat -c %a "$ROOTFS/$d" 2>/dev/null || echo MISSING)"
  if [[ "$mode" == "755" || "$mode" == "2755" ]]; then
    ok "/$d режим $mode (допустимо: 0755 или 2755 ≡ 0755 по доступу)"
  else
    fail "/$d режим $mode — ожидается 0755 (допустимо 2755); не-root процессы не смогут читать/исполнять файлы из /$d"
  fi
done

# 2. Ни одного каталога 2770 (исходный дефект).
bad_dirs="$(find "$ROOTFS" -type d -perm 2770 2>/dev/null)"
if [[ -z "$bad_dirs" ]]; then
  ok "каталогов 2770 нет"
else
  n="$(echo "$bad_dirs" | wc -l)"
  fail "каталогов 2770: $n (первые 10):"; echo "$bad_dirs" | head -10 >&2
fi

# 3. Ни одного файла 660/770, кроме btmp/lastlog (660 root:utmp).
bad_files="$(find "$ROOTFS" -type f \( -perm 660 -o -perm 770 \) 2>/dev/null | grep -vE "/var/log/(btmp|lastlog)$" || true)"
if [[ -z "$bad_files" ]]; then
  ok "файлов 660/770 нет (кроме разрешённых btmp/lastlog)"
else
  n="$(echo "$bad_files" | wc -l)"
  fail "файлов 660/770: $n (первые 10):"; echo "$bad_files" | head -10 >&2
fi

# 4. Ни одного файла 777.
f777="$(find "$ROOTFS" -type f -perm 777 2>/dev/null)"
if [[ -z "$f777" ]]; then
  ok "файлов 777 нет"
else
  n="$(echo "$f777" | wc -l)"
  fail "файлов 777: $n (первые 10):"; echo "$f777" | head -10 >&2
fi

# 5. /tmp — 1777/3777 (sticky), /root — 750/2750.
for spec in "tmp:1777:3777" "root:750:2750"; do
  d="${spec%%:*}"; rest="${spec#*:}"; m1="${rest%%:*}"; m2="${rest##*:}"
  mode="$(stat -c %a "$ROOTFS/$d" 2>/dev/null || echo MISSING)"
  if [[ "$mode" == "$m1" || "$mode" == "$m2" ]]; then
    ok "/$d режим $mode"
  else
    fail "/$d режим $mode — ожидается $m1 (допустимо $m2)"
  fi
done

if [[ "$FAIL" -eq 0 ]]; then
  echo "ИТОГ: PASS — права rootfs $ROOTFS в порядке"
  exit 0
else
  echo "ИТОГ: FAIL — в rootfs $ROOTFS есть нарушения прав (см. выше); сборка должна быть остановлена" >&2
  exit 1
fi
