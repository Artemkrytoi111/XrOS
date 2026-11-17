#!/usr/bin/env bash
# XrOS — тесты безопасной GPG-системы (A-40).
#
# Проверяется НАСТОЯЩИЙ код (не копии логики):
#   A. xros-gpg-check — на эфемерных ключах во временном GNUPGHOME
#      (loopback, без пароля; ключи создаются только для теста
#      и удаляются вместе с GNUPGHOME; production-ключ не нужен).
#   B. verify-repo-signatures.sh — на поддельном репозитории
#      (фальшивые .pkg.tar.zst и БД, подписанные эфемерным ключом).
#   C. sign-repo-offline.sh — полный поток с заглушкой repo-add
#      (заглушка только подписывает БД, как repo-add -s; настоящий
#      repo-add здесь недоступен — это честно отмечено SKIP).
#   D. xros_import_xros_key из src/xros-install — с поддельными
#      arch-chroot и конфигом (абсолютные пути /usr/share/xros/*
#      и /usr/local/bin/xros-gpg-check в извлечённой функции
#      заменены на тестовые — остальное дословно).
#   E. Статика: нет || true на pacman-key, нет тестового ключа
#      как production, есть release gate, SigLevel пока Optional.
#
# Честно НЕ тестируется здесь (отмечено SKIP):
#   * end-to-end с production-ключом (ключа нет — NOT TESTED);
#   * customize_airootfs.sh в реальном chroot (нужен mkarchiso);
#   * настоящий repo-add -s (нет на этом хосте).
#
# Запуск: ./scripts/tests/test-gpg-handling.sh
# Выход: 0 — все PASS, 1 — есть FAIL.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENGINE="$ROOT/src/xros-install"
CHECK="$ROOT/profile/airootfs/usr/local/bin/xros-gpg-check"
VERIFY="$ROOT/scripts/verify-repo-signatures.sh"
SIGNOFF="$ROOT/scripts/sign-repo-offline.sh"
PASS=0; FAIL=0; SKIPN=0
FAILED=()
ok()   { PASS=$((PASS+1)); echo "PASS  $1"; }
bad()  { FAIL=$((FAIL+1)); FAILED+=("$1"); echo "FAIL  $1"; }
skip() { SKIPN=$((SKIPN+1)); echo "SKIP  $1 ($2)"; }

T="$(mktemp -d)"
# Тестовый публичный ключ кладётся в xros-gpg-prod/ только на время
# этого прогона (sign-repo-offline.sh читает его оттуда). Реальный
# production-ключ (если он есть) перед подменой сохраняется в $T и
# восстанавливается при выходе — тест НЕ должен уничтожать ключ
# владельца (15.11.2026: production-ключ создан, удаление недопустимо).
REAL_KEY_BAK=""
cleanup() {
  if [[ -n "${REAL_KEY_BAK:-}" && -f "$REAL_KEY_BAK" ]]; then
    cp "$REAL_KEY_BAK" "$ROOT/xros-gpg-prod/xros-public.key"
  else
    rm -f "$ROOT/xros-gpg-prod/xros-public.key"
  fi
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$T/bin"

if ! command -v gpg >/dev/null 2>&1; then
  echo "gpg нет на хосте — динамические тесты невозможны"
  skip "gpg: xros-gpg-check" "нет gpg"
  skip "gpg: verify-repo-signatures" "нет gpg"
  skip "gpg: sign-repo-offline" "нет gpg"
  skip "gpg: xros_import_xros_key" "нет gpg"
else
  # --- эфемерные ключи (только для теста) ---
  export GNUPGHOME="$T/gnupg"
  mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
  # ВАЖНО: GPG — массив, а не строка (иначе '' становится литералом
  # из двух кавычек и паролем ключей; см. test-sources-manifest.sh).
  GPG=(gpg --batch --pinentry-mode loopback --passphrase '')
  "${GPG[@]}" --quick-gen-key "XrOS Sign <sign@xros.invalid>" ed25519 sign 0 2>/dev/null
  "${GPG[@]}" --export --armor "XrOS Sign" > "$T/sign.pub"
  SIGN_FPR="$("${GPG[@]}" --show-keys --with-colons "$T/sign.pub" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
  "${GPG[@]}" --quick-gen-key "XrOS Cert <cert@xros.invalid>" ed25519 cert 0 2>/dev/null
  "${GPG[@]}" --export --armor "XrOS Cert" > "$T/cert.pub"
  CERT_FPR="$("${GPG[@]}" --show-keys --with-colons "$T/cert.pub" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
  # Просроченный ключ: время генерации подделано в 2020, срок — 2021.
  # ВАЖНО (R-16): срок пишется С ДЕФИСАМИ ('2021-01-01'). Голый
  # формат '20210101' этот gpg НЕ парсит как дату: ключ получается
  # со сроком creation+1с (тоже просрочен, но комментарий «срок — 2021»
  # был бы неверен). Проверено: f7 строки pub = 2021-01-01.
  "${GPG[@]}" --faked-system-time 20200101T000000 --quick-gen-key "XrOS Old <old@xros.invalid>" ed25519 sign 2021-01-01 2>/dev/null
  "${GPG[@]}" --export --armor "XrOS Old" > "$T/old.pub"
  OLD_FPR="$("${GPG[@]}" --show-keys --with-colons "$T/old.pub" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
  # Отозванный ключ: сертификат отзыва из openpgp-revocs.d (снять
  # защитный двоеточие перед BEGIN, как сказано в самом файле).
  "${GPG[@]}" --quick-gen-key "XrOS Rev <rev@xros.invalid>" ed25519 sign 0 2>/dev/null
  REV_FPR="$("${GPG[@]}" --list-keys --with-colons "XrOS Rev" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
  sed 's/^:-----BEGIN/-----BEGIN/' "$GNUPGHOME/openpgp-revocs.d/$REV_FPR.rev" > "$T/rev-clean.asc"
  "${GPG[@]}" --import "$T/rev-clean.asc" >/dev/null 2>&1
  "${GPG[@]}" --export --armor "XrOS Rev" > "$T/rev.pub"
  cat "$T/sign.pub" "$T/cert.pub" > "$T/two.pub"
  printf 'not a key' > "$T/bad.pub"
  : > "$T/empty.pub"  # R-13: пустой файл ключа
  # R-13: ключ только с шифрованием (нет способности подписывать).
  # ed25519/cv25519 для этого не подходят (gpg: Wrong key usage) —
  # нужен RSA с usage encr; caps такого ключа 'ecEC', без 's'.
  "${GPG[@]}" --quick-gen-key "XrOS Encr <encr@xros.invalid>" rsa2048 encr 0 2>/dev/null
  "${GPG[@]}" --export --armor "XrOS Encr" > "$T/encr.pub"
  ENCR_FPR="$("${GPG[@]}" --show-keys --with-colons "$T/encr.pub" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
  # R-13: повреждённый ключ — переворот байта внутри самоподписи
  # (в конце бинарного экспорта). gpg --show-keys его по-прежнему
  # читает, но сообщает validity 'i' (invalid); ветвь 'i' в
  # xros-gpg-check обязана его отклонить.
  "${GPG[@]}" --export "XrOS Sign" > "$T/sign.gpg"
  python3 - "$T/sign.gpg" "$T/corrupt.pub" <<'PYEOF'
import sys
data = bytearray(open(sys.argv[1], 'rb').read())
data[-30] ^= 0xFF
open(sys.argv[2], 'wb').write(bytes(data))
PYEOF
  # R-16: ключи с validity 'f' и 'm' (реальный gpg, не mock).
  # Целевые ключи создаются в ОТДЕЛЬНОМ keyring (не свои для
  # основного), иначе их validity всегда 'u'. Порядок важен:
  # сначала интродьюсеры становятся валидными (их подписывает
  # ultimate-ключ Sign), потом ownertrust marginal, потом они
  # подписывают целевой ключ — иначе trustdb считает validity
  # по устаревшему состоянию (проверено в R-16).
  mkdir -p "$T/gnupg-other"; chmod 700 "$T/gnupg-other"
  GNUPGHOME="$T/gnupg-other" "${GPG[@]}" --quick-gen-key "XrOS Full <full@xros.invalid>" ed25519 sign 0 2>/dev/null
  GNUPGHOME="$T/gnupg-other" "${GPG[@]}" --quick-gen-key "XrOS Marg <marg@xros.invalid>" ed25519 sign 0 2>/dev/null
  GNUPGHOME="$T/gnupg-other" "${GPG[@]}" --export --armor "XrOS Full" > "$T/full.pub"
  GNUPGHOME="$T/gnupg-other" "${GPG[@]}" --export --armor "XrOS Marg" > "$T/marg.pub"
  FULL_FPR="$(GNUPGHOME="$T/gnupg-other" "${GPG[@]}" --list-keys --with-colons "XrOS Full" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
  MARG_FPR="$(GNUPGHOME="$T/gnupg-other" "${GPG[@]}" --list-keys --with-colons "XrOS Marg" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
  "${GPG[@]}" --import "$T/full.pub" "$T/marg.pub" 2>/dev/null
  # 'f': целевой ключ подписан ultimate-ключом Sign.
  "${GPG[@]}" --yes --quick-sign-key --local-user "$SIGN_FPR" "$FULL_FPR" 2>/dev/null
  "${GPG[@]}" --export --armor "XrOS Full" > "$T/full-signed.pub"
  # 'm': интродьюсеры B/C (их сначала подписывает Sign, иначе
  # их validity '-' и они не могут быть интродьюсерами),
  # ownertrust marginal (4), затем они подписывают Marg.
  "${GPG[@]}" --quick-gen-key "XrOS IntroB <ib@xros.invalid>" ed25519 sign 0 2>/dev/null
  "${GPG[@]}" --quick-gen-key "XrOS IntroC <ic@xros.invalid>" ed25519 sign 0 2>/dev/null
  IB_FPR="$("${GPG[@]}" --list-keys --with-colons "XrOS IntroB" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
  IC_FPR="$("${GPG[@]}" --list-keys --with-colons "XrOS IntroC" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
  "${GPG[@]}" --yes --quick-sign-key --local-user "$SIGN_FPR" "$IB_FPR" 2>/dev/null
  "${GPG[@]}" --yes --quick-sign-key --local-user "$SIGN_FPR" "$IC_FPR" 2>/dev/null
  printf '%s:4:\n%s:4:\n' "$IB_FPR" "$IC_FPR" > "$T/ot-marg"
  "${GPG[@]}" --import-ownertrust "$T/ot-marg" 2>/dev/null
  "${GPG[@]}" --yes --quick-sign-key --local-user "$IB_FPR" "$MARG_FPR" 2>/dev/null
  "${GPG[@]}" --yes --quick-sign-key --local-user "$IC_FPR" "$MARG_FPR" 2>/dev/null
  "${GPG[@]}" --update-trustdb 2>/dev/null
  "${GPG[@]}" --export --armor "XrOS Marg" > "$T/marg-signed.pub"
  if [[ -z "$SIGN_FPR" || -z "$CERT_FPR" || -z "$OLD_FPR" || -z "$REV_FPR" || -z "$ENCR_FPR" || -z "$FULL_FPR" || -z "$MARG_FPR" ]]; then
    bad "gpg: эфемерные ключи не создались"
    echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
    exit 1
  fi
  ok "gpg: эфемерные ключи созданы (sign/cert/expired/revoked)"

  # ================= A. xros-gpg-check =================
  run_check() { # $1=имя $2=файл $3=fpr $4=ожидаемый rc (0|nonzero)
    local name="$1" f="$2" fp="$3" want="$4" rc
    if "$CHECK" "$f" "$fp" >"$T/check.out" 2>&1; then rc=0; else rc=1; fi
    if { [[ "$want" == "0" && "$rc" == "0" ]] || [[ "$want" == "nonzero" && "$rc" != "0" ]]; }; then
      ok "gpg-check $name"
    else
      bad "gpg-check $name (ожидалось rc $want, получено $rc: $(cat "$T/check.out" | head -1))"
    fi
  }
  run_check "корректный ключ" "$T/sign.pub" "$SIGN_FPR" 0
  # R-16: тот же ключ в СВЕЖЕМ keyring — реальный контекст проверки
  # (build.sh/customize/движок): validity '-' (unknown), обязан PASS.
  mkdir -p "$T/fresh"; chmod 700 "$T/fresh"
  if GNUPGHOME="$T/fresh" "$CHECK" "$T/sign.pub" "$SIGN_FPR" >"$T/check.out" 2>&1; then
    ok "gpg-check ключ в свежем keyring (validity '-')"
  else
    bad "gpg-check ключ в свежем keyring (validity '-') (отказ: $(head -1 "$T/check.out"))"
  fi
  # R-16: validity 'f' (подписан ultimate-ключом) и 'm' (два
  # marginal-интродьюсера) — реальный gpg, обязаны PASS.
  # Фактическая validity сверяется перед проверкой: если gpg выдал
  # не 'f'/'m', тест честно падает, а не подгоняется под результат.
  _v="$("${GPG[@]}" --list-keys --with-colons "XrOS Full" 2>/dev/null | awk -F: '$1=="pub" {print $2; exit}')"
  [[ "$_v" == "f" ]] && run_check "ключ validity 'f'" "$T/full-signed.pub" "$FULL_FPR" 0 \
    || bad "gpg-check ключ validity 'f' (фактическая validity: '${_v:-?}', ожидалась 'f')"
  _v="$("${GPG[@]}" --list-keys --with-colons "XrOS Marg" 2>/dev/null | awk -F: '$1=="pub" {print $2; exit}')"
  [[ "$_v" == "m" ]] && run_check "ключ validity 'm'" "$T/marg-signed.pub" "$MARG_FPR" 0 \
    || bad "gpg-check ключ validity 'm' (фактическая validity: '${_v:-?}', ожидалась 'm')"
  run_check "несовпадающий fingerprint" "$T/sign.pub" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" nonzero
  run_check "неправильный формат ключа" "$T/bad.pub" "$SIGN_FPR" nonzero
  run_check "отсутствующий ключ" "$T/nope.pub" "$SIGN_FPR" nonzero
  run_check "ключ без способности подписывать (cert-only)" "$T/cert.pub" "$CERT_FPR" nonzero
  run_check "просроченный ключ" "$T/old.pub" "$OLD_FPR" nonzero
  run_check "отозванный ключ" "$T/rev.pub" "$REV_FPR" nonzero
  # R-13: повреждённый ключ (validity 'i') и ключ без способности
  # подписывать (encr-only); пустой файл ключа.
  run_check "повреждённый ключ (validity 'i')" "$T/corrupt.pub" "$SIGN_FPR" nonzero
  run_check "ключ без способности подписывать (encr-only)" "$T/encr.pub" "$ENCR_FPR" nonzero
  run_check "пустой файл ключа" "$T/empty.pub" "$SIGN_FPR" nonzero
  run_check "два ключа в одном файле" "$T/two.pub" "$SIGN_FPR" nonzero
  run_check "отпечаток в нижнем регистре" "$T/sign.pub" "$(printf '%s' "$SIGN_FPR" | tr 'A-F' 'a-f')" 0
  run_check "неверный формат отпечатка (короткий)" "$T/sign.pub" "ABC123" nonzero

  # ================= A2. R-16: unit-тесты парсера validity =================
  # Это тесты ТАБЛИЦЫ ПОЛИТИКИ (чистые функции из xros-gpg-check),
  # а не поведения gpg: значения 'n', 'o', 'q', 'd' реальным gpg
  # 2.4.4 в этой среде не воспроизводятся (см. комментарий в
  # xros-gpg-check), поэтому их ветви проверяются напрямую на
  # функциях. Интеграционные тесты выше покрывают реальным gpg:
  # '-', 'u', 'f', 'm', 'r', 'e', 'i'.
  # shellcheck disable=SC1090
  source "$CHECK"
  unit() { # $1=имя $2=ожидаемый rc (0|nonzero) $3..=команда
    local name="$1" want="$2"; shift 2
    if "$@" >/dev/null 2>&1; then rc=0; else rc=1; fi
    if { [[ "$want" == "0" && "$rc" == "0" ]] || [[ "$want" == "nonzero" && "$rc" != "0" ]]; }; then
      ok "parser $name"
    else
      bad "parser $name (ожидалось rc $want, получено $rc)"
    fi
  }
  for _v in - o q m f u; do unit "validity '$_v' принимается" 0 validity_acceptable "$_v"; done
  for _v in n i d r e "" "xx" "U" "uf" "-x"; do unit "validity '${_v:-<пусто>}' отклоняется" nonzero validity_acceptable "$_v"; done
  unit "caps 'scSC' принимается" 0 caps_acceptable "scSC"
  unit "caps 'sc' (строчные) принимается" 0 caps_acceptable "sc"
  unit "caps 'scSCD' (disabled) отклоняется" nonzero caps_acceptable "scSCD"
  unit "caps 'ec' (без sign) отклоняется" nonzero caps_acceptable "ec"
  unit "caps пустые отклоняются" nonzero caps_acceptable ""
  unit "expires пустой (бессрочный) принимается" 0 expires_ok ""
  unit "expires в будущем принимается" 0 expires_ok 4102444800
  unit "expires в прошлом отклоняется" nonzero expires_ok 1000000000
  unit "expires нечисловой отклоняется" nonzero expires_ok "2030-01-01"
  unit "expires 'abc' отклоняется" nonzero expires_ok "abc"
  # parse_pub_line: РЕАЛЬНАЯ строка pub из gpg (21 поле) — поля
  # извлекаются; неполная строка — отказ. Ручная сборка строки
  # здесь не используется: легко ошибиться в номерах полей.
  _real_pub="$("${GPG[@]}" --show-keys --with-colons "$T/sign.pub" 2>/dev/null | awk -F: '$1=="pub" {print; exit}')"
  if parse_pub_line "$_real_pub" && [[ "$VALIDITY" == "u" && "$CAPS" == "scSC" && -z "$EXPIRES" ]]; then
    ok "parser реальная строка pub разбирается"
  else
    bad "parser реальная строка pub разбирается (validity='$VALIDITY' caps='$CAPS' expires='$EXPIRES')"
  fi
  unit "parse_pub_line короткая строка (5 полей) отклоняется" nonzero parse_pub_line "pub:u:255:22:ABC"
  unit "parse_pub_line пустая строка отклоняется" nonzero parse_pub_line ""

  # ================= B. verify-repo-signatures.sh =================
  sign_file() { # $1=файл $2=fpr
    "${GPG[@]}" --yes --detach-sign --local-user "$2" --output "$1.sig" "$1" 2>/dev/null
  }
  make_repo() { # $1=каталог; создаёт фальшивые пакеты и БД
    local d="$1"; mkdir -p "$d"
    printf 'fake package 1' > "$d/xros-test-1.0-1.pkg.tar.zst"
    printf 'fake package 2' > "$d/xros-test-2.0-1.pkg.tar.zst"
    printf 'fake db' > "$d/xros.db.tar.gz"
    printf 'fake files db' > "$d/xros.files.tar.gz"
  }
  sign_repo() { # $1=каталог $2=fpr; подписывает всё
    local d="$1" fp="$2"
    for f in "$d"/*.pkg.tar.zst "$d"/xros.db.tar.gz "$d"/xros.files.tar.gz; do
      sign_file "$f" "$fp" || return 1
    done
  }
  run_verify() { # $1=имя $2=каталог $3=публичный ключ $4=fpr $5=ожидаемый rc
    local name="$1" d="$2" k="$3" fp="$4" want="$5" rc
    if "$VERIFY" "$d" "$k" "$fp" >"$T/verify.out" 2>&1; then rc=0; else rc=1; fi
    if { [[ "$want" == "0" && "$rc" == "0" ]] || [[ "$want" == "nonzero" && "$rc" != "0" ]]; }; then
      ok "verify $name"
    else
      bad "verify $name (ожидалось rc $want, получено $rc)"
      tail -3 "$T/verify.out"
    fi
  }
  make_repo "$T/repo-good"; sign_repo "$T/repo-good" "$SIGN_FPR"
  run_verify "все подписи валидны" "$T/repo-good" "$T/sign.pub" "$SIGN_FPR" 0
  make_repo "$T/repo-tampered"; sign_repo "$T/repo-tampered" "$SIGN_FPR"
  printf 'x' >> "$T/repo-tampered/xros-test-1.0-1.pkg.tar.zst"
  run_verify "подменённый пакет" "$T/repo-tampered" "$T/sign.pub" "$SIGN_FPR" nonzero
  make_repo "$T/repo-nosig"; sign_repo "$T/repo-nosig" "$SIGN_FPR"
  rm -f "$T/repo-nosig/xros-test-2.0-1.pkg.tar.zst.sig"
  run_verify "нет подписи пакета" "$T/repo-nosig" "$T/sign.pub" "$SIGN_FPR" nonzero
  make_repo "$T/repo-nodbsig"; sign_repo "$T/repo-nodbsig" "$SIGN_FPR"
  rm -f "$T/repo-nodbsig/xros.db.tar.gz.sig"
  run_verify "нет подписи БД" "$T/repo-nodbsig" "$T/sign.pub" "$SIGN_FPR" nonzero
  # Подписано ДРУГИМ ключом — проверка первым ключом обязана упасть.
  "${GPG[@]}" --quick-gen-key "XrOS Other <other@xros.invalid>" ed25519 sign 0 2>/dev/null
  OTHER_FPR="$("${GPG[@]}" --list-keys --with-colons "XrOS Other" 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')"
  make_repo "$T/repo-wrongkey"; sign_repo "$T/repo-wrongkey" "$OTHER_FPR"
  run_verify "подписи чужим ключом" "$T/repo-wrongkey" "$T/sign.pub" "$SIGN_FPR" nonzero
  make_repo "$T/repo-badfpr"; sign_repo "$T/repo-badfpr" "$SIGN_FPR"
  run_verify "неверный ожидаемый отпечаток" "$T/repo-badfpr" "$T/sign.pub" "$OTHER_FPR" nonzero

  # ================= C. sign-repo-offline.sh =================
  # Заглушка repo-add: настоящий repo-add недоступен на этом хосте.
  # Заглушка делает ровно то, что repo-add -s делает с подписями:
  # подписывает БД тем же ключом (пересборка самой БД — не в счёт).
  cat > "$T/bin/repo-add" <<'EOF'
#!/usr/bin/env bash
# fake repo-add -s: подписать БД эфемерным ключом (см. env).
# R-12: sign-repo-offline.sh обязан передавать production fingerprint
# через GPGKEY (у repo-add нет флага --key). Если GPGKEY не задан
# или не равен ожидаемому FPR — отказаться.
if [[ "${GPGKEY:-}" != "$TEST_FPR" ]]; then
  echo "fake repo-add: GPGKEY не задан или не равен ожидаемому FPR (получено: '${GPGKEY:-<пусто>}')" >&2
  exit 1
fi
for db in xros.db.tar.gz xros.files.tar.gz; do
  [[ -f "$db" ]] || continue
  gpg --batch --yes --pinentry-mode loopback --passphrase '' --homedir "$TEST_GNUPGHOME" --detach-sign --local-user "$TEST_FPR" --output "$db.sig" "$db" 2>/dev/null || exit 1
done
exit 0
EOF
  chmod +x "$T/bin/repo-add"
  export PATH="$T/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  export TEST_GNUPGHOME="$GNUPGHOME" TEST_FPR="$SIGN_FPR"
  # Публичный ключ для проверки — на месте, как ожидает скрипт.
  # Реальный production-ключ (если есть) сохраняется и
  # восстанавливается cleanup'ом при выходе.
  mkdir -p "$ROOT/xros-gpg-prod"
  if [[ -f "$ROOT/xros-gpg-prod/xros-public.key" ]]; then
    cp "$ROOT/xros-gpg-prod/xros-public.key" "$T/xros-public.key.real.bak"
    REAL_KEY_BAK="$T/xros-public.key.real.bak"
  fi
  cp "$T/sign.pub" "$ROOT/xros-gpg-prod/xros-public.key"
  # Полный поток: пакеты подписываются, БД подписывается заглушкой,
  # все подписи проверяются настоящим verify-repo-signatures.sh.
  make_repo "$T/repo-sign"
  if "$SIGNOFF" "$T/repo-sign" "$SIGN_FPR" >"$T/signoff.out" 2>&1; then
    ok "sign-offline: полный поток (пакеты + БД + проверка)"
  else
    bad "sign-offline: полный поток (пакеты + БД + проверка)"
    tail -5 "$T/signoff.out"
  fi
  # Отказ при отсутствии приватного ключа.
  if "$SIGNOFF" "$T/repo-sign" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" >"$T/signoff2.out" 2>&1; then
    bad "sign-offline: отказ без приватного ключа"
  else
    grep -q "нет приватного ключа" "$T/signoff2.out" \
      && ok "sign-offline: отказ без приватного ключа" \
      || bad "sign-offline: отказ без приватного ключа"
  fi
  skip "sign-offline: настоящий repo-add -s" "repo-add нет на этом хосте (заглушка только подписывает БД)"
  skip "gpg: end-to-end с production-ключом" "production-ключ не предоставлен владельцем (NOT TESTED)"
  skip "gpg: customize в реальном chroot" "нужен mkarchiso/build-env (NOT TESTED)"

  # ================= D. xros_import_xros_key (движок) =================
  awk '/^# --- XROS: импорт ключа XrOS \(начало\) ---/{f=1; next} /^# --- XROS: импорт ключа XrOS \(конец\) ---/{f=0} f{print}' "$ENGINE" > "$T/import-fn.sh"
  if [[ -s "$T/import-fn.sh" ]] && grep -q "xros_import_xros_key" "$T/import-fn.sh"; then
    ok "engine: блок xros_import_xros_key извлечён из src/xros-install"
  else
    bad "engine: блок xros_import_xros_key извлечён из src/xros-install"
    echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
    exit 1
  fi
  # Заглушка xros-gpg-check — настоящий helper (путь заменён ниже).
  cat > "$T/bin/xros-gpg-check" <<EOF
#!/usr/bin/env bash
exec "$ROOT/profile/airootfs/usr/local/bin/xros-gpg-check" "\$@"
EOF
  chmod +x "$T/bin/xros-gpg-check"
  # Абсолютные пути в извлечённой функции — на тестовые.
  sed -i "s|/usr/share/xros/xros-gpg.conf|$T/xros-gpg.conf|g; s|/usr/local/bin/xros-gpg-check|$T/bin/xros-gpg-check|g" "$T/import-fn.sh"
  sed -i "/key_src=/s|/usr/share/xros/xros-public.key|$T/xros-public.key|" "$T/import-fn.sh"
  say() { echo "SAY: $*" >> "$T/say.log"; }
  # Поддельный arch-chroot: поведение — через env.
  # ARCHCHROOT_FAIL: none|add|finger|lsign|list; FINGER_OK: 1|0.
  arch-chroot() {
    echo "arch-chroot $*" >> "$T/arch.calls"
    local args="$*"
    case "$args" in
      *"pacman-key --add"*) [[ "${ARCHCHROOT_FAIL:-none}" == "add" ]] && return 1; return 0 ;;
      *"pacman-key --finger"*)
        [[ "${ARCHCHROOT_FAIL:-none}" == "finger" ]] && return 1
        if [[ "${FINGER_OK:-1}" == "1" ]]; then printf 'pub   ed25519\n      %s\n' "$SIGN_FPR"; else printf 'pub   ed25519\n      0000000000000000000000000000000000000000\n'; fi
        return 0 ;;
      *"pacman-key --lsign-key"*) [[ "${ARCHCHROOT_FAIL:-none}" == "lsign" ]] && return 1; return 0 ;;
      *"pacman-key --list-keys"*) [[ "${ARCHCHROOT_FAIL:-none}" == "list" ]] && return 1; return 0 ;;
      *) return 0 ;;
    esac
  }
  TARGET="$T/target"; mkdir -p "$TARGET"
  LOG="$T/engine.log"; : > "$LOG"
  # shellcheck disable=SC1090
  source "$T/import-fn.sh"
  run_import() { # $1=имя $2=ожидаемый rc (0|1)
    local name="$1" want="$2" rc
    rm -f "$T/say.log" "$T/arch.calls"
    if xros_import_xros_key; then rc=0; else rc=1; fi
    if [[ "$rc" == "$want" ]]; then ok "engine import $name (rc $want)"; else bad "engine import $name (ожидалось rc $want, получено $rc)"; fi
  }
  # Dev-режим: FPR пуст — предупреждение, arch-chroot не вызывается.
  printf 'XROS_GPG_PROD_FPR=""\n' > "$T/xros-gpg.conf"
  cp "$T/sign.pub" "$T/xros-public.key"
  ARCHCHROOT_FAIL=none FINGER_OK=1 run_import "dev-режим (FPR пуст)" 0
  if [[ ! -f "$T/arch.calls" ]]; then ok "engine import dev-режим: arch-chroot не вызван"; else bad "engine import dev-режим: arch-chroot не вызван"; fi
  # Настроенный режим, всё хорошо.
  printf 'XROS_GPG_PROD_FPR="%s"\n' "$SIGN_FPR" > "$T/xros-gpg.conf"
  ARCHCHROOT_FAIL=none FINGER_OK=1 run_import "настроен, всё хорошо" 0
  if grep -q "pacman-key --add" "$T/arch.calls" && grep -q "pacman-key --lsign-key" "$T/arch.calls"; then
    ok "engine import: вызваны --add и --lsign-key"
  else
    bad "engine import: вызваны --add и --lsign-key"
  fi
  # Неудачи — каждая обязана остановить установку (rc 1).
  ARCHCHROOT_FAIL=add FINGER_OK=1 run_import "неудачный --add" 1
  ARCHCHROOT_FAIL=lsign FINGER_OK=1 run_import "неудачный --lsign-key" 1
  ARCHCHROOT_FAIL=list FINGER_OK=1 run_import "ключ не найден в keyring" 1
  ARCHCHROOT_FAIL=none FINGER_OK=0 run_import "неверный отпечаток в --finger" 1
  rm -f "$T/xros-public.key"
  ARCHCHROOT_FAIL=none FINGER_OK=1 run_import "нет файла ключа" 1
  # Несовпадающий отпечаток в конфиге — проверка ключа падает.
  cp "$T/sign.pub" "$T/xros-public.key"
  printf 'XROS_GPG_PROD_FPR="%s"\n' "$OTHER_FPR" > "$T/xros-gpg.conf"
  ARCHCHROOT_FAIL=none FINGER_OK=1 run_import "несовпадающий FPR в конфиге" 1
fi

# ================= E. Статика =================
# Нет проглатывания ошибок pacman-key в production-путях.
if grep 'pacman-key' "$ROOT/profile/airootfs/root/customize_airootfs.sh" | grep -q '|| true'; then
  bad "статика: customize: нет pacman-key … || true"
else
  ok "статика: customize: нет pacman-key … || true"
fi
if grep 'pacman-key' "$ENGINE" | grep -q '|| true'; then
  bad "статика: движок: нет pacman-key … || true"
else
  ok "статика: движок: нет pacman-key … || true"
fi
if grep -q 'pacman-key --finger' "$ROOT/profile/airootfs/root/customize_airootfs.sh" \
   && grep -q 'pacman-key --finger' "$ENGINE"; then
  ok "статика: отпечаток проверяется и в customize, и в движке"
else
  bad "статика: отпечаток проверяется и в customize, и в движке"
fi
if grep -q 'xros-gpg-check' "$ROOT/profile/airootfs/root/customize_airootfs.sh" \
   && grep -q 'xros-gpg-check' "$ENGINE" \
   && grep -q 'xros-gpg-check' "$ROOT/scripts/build.sh"; then
  ok "статика: xros-gpg-check используется в customize, движке и build.sh"
else
  bad "статика: xros-gpg-check используется в customize, движке и build.sh"
fi
# Тестовый ключ — не production: его отпечаток не стоит как значение
# в production-путях (упоминания в комментариях — допустимы).
if grep -q 'XROS_GPG_PROD_FPR="0EC935D2' "$ROOT/profile/airootfs/usr/share/xros/xros-gpg.conf" \
   || grep -q 'lsign-key 0EC935D2' "$ROOT/profile/airootfs/root/customize_airootfs.sh" \
   || grep -q 'xros-gpg-test/xros-public.key' "$ROOT/scripts/build.sh"; then
  bad "статика: тестовый ключ не используется как production"
else
  ok "статика: тестовый ключ не используется как production"
fi
# Конфиг production-GPG на месте, FPR задан (ключ предоставлен, 15.11.2026).
if [[ -f "$ROOT/profile/airootfs/usr/share/xros/xros-gpg.conf" ]] \
   && grep -Eq '^XROS_GPG_PROD_FPR="[0-9A-Fa-f]{40}"' "$ROOT/profile/airootfs/usr/share/xros/xros-gpg.conf"; then
  ok "статика: xros-gpg.conf на месте, FPR задан (40 hex)"
else
  bad "статика: xros-gpg.conf на месте, FPR задан (40 hex)"
fi
# Release gate в build.sh.
if grep -q 'release_gate' "$ROOT/scripts/build.sh" \
   && grep -q -- '--release' "$ROOT/scripts/build.sh" \
   && grep -q 'verify-repo-signatures.sh' "$ROOT/scripts/build.sh"; then
  ok "статика: release gate в build.sh (--release + проверка подписей)"
else
  bad "статика: release gate в build.sh (--release + проверка подписей)"
fi
# SigLevel = Required в обоих pacman.conf (подписано, 15.11.2026).
# Проверка — по секции [xros] целиком (строка может быть отделена
# комментариями), а не по фиксированному числу строк после заголовка.
xros_siglevel_required() {
  awk '/^\[xros\]/{s=1; next} /^\[/{s=0} s && /^SigLevel = Required$/{f=1} END{exit !f}' "$1"
}
if xros_siglevel_required "$ROOT/profile/pacman.conf" \
   && xros_siglevel_required "$ROOT/profile/airootfs/etc/pacman.conf"; then
  ok "статика: SigLevel = Required в обоих pacman.conf (подписано)"
else
  bad "статика: SigLevel = Required в обоих pacman.conf (подписано)"
fi
# Helper на месте и исполняемый; file_permissions в profiledef.sh.
if [[ -x "$CHECK" ]] && grep -q '"/usr/local/bin/xros-gpg-check"\]="0:0:755"' "$ROOT/profile/profiledef.sh"; then
  ok "статика: xros-gpg-check исполняемый и в file_permissions"
else
  bad "статика: xros-gpg-check исполняемый и в file_permissions"
fi
# Секретов нет: приватных ключей в репозитории (кроме build-env).
if grep -rIl --exclude-dir=build-env --exclude-dir=.git -E 'BEGIN (RSA |EC |OPENSSH |PGP )?PRIVATE KEY' "$ROOT" 2>/dev/null | grep .; then
  bad "статика: приватных ключей в репозитории нет"
else
  ok "статика: приватных ключей в репозитории нет"
fi

echo "ИТОГ: PASS=$PASS FAIL=$FAIL SKIP=$SKIPN"
if [[ $FAIL -gt 0 ]]; then
  echo "Не пройдено:"
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
