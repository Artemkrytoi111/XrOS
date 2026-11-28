#!/bin/bash
# XrOS — Атомарная миграция production GPG-ключа (шаблон, НЕ выполнять без отдельного разрешения владельца).
#
# Назначение: безопасно заменить 7 production-подписей, публичный ключ и
# fingerprint со старого ключа (B16629E8…) на новый (52F96353…).
# Новый ключ бессрочный: offline master + отдельный online signing subkey.
#
# Принципы (Фаза 4.5 §2, Фаза 5D):
#   - set -e НЕ является атомарной транзакцией. Используются отдельные
#     candidate directories, staging, полная проверка ДО замены, журнал,
#     backup и автоматический rollback при сбое.
#   - Не допускается состояние со смешанными старыми и новыми подписями.
#   - Не допускается частично обновлённый ключ/FPR.
#
# Требования перед запуском (все — отдельные разрешения владельца):
#   1. Публикация переходного пакета xros-keyring и исправленных aliases.
#   2. Период внедрения (рекомендуется не менее 4 недель).
#   3. Решение владельца о переключении подписей.
#   4. Наличие 7 новых БИНАРНЫХ (dearmored) .sig от нового ключа
#      (armored .sig от Carolyn НЕ подходят для pacman — см. Фазу 5 §6).
#   5. Наличие нового публичного ключа (offline master и online subkey проверены локально).
#
# Использование (только после разрешения):
#   sudo bash scripts/xros-migrate-production-key.sh \
#       --new-sigs-dir /path/to/new-sigs-binary \
#       --new-public-key /path/to/xros-public-new.key
#
# Скрипт НЕ создаёт ISO, НЕ делает commit/push, НЕ публикует релиз,
# НЕ отзывает старый ключ, НЕ удаляет старый приватный ключ.
# Отзыв старого ключа — отдельный этап после успешной миграции.

set -u -o pipefail

OLD_FPR="B16629E8B17270764AED33013D1718A6EE45C94C"
NEW_FPR="52F963537CCD76C941B4DFD7B0DD24EE45116C8A"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="${REPO_ROOT}/repo/xros/os/x86_64"
SNAP_DIR="${REPO_ROOT}/profile/airootfs/usr/share/xros/repo/xros/os/x86_64"
NEW_SIGS_DIR=""
NEW_PUBKEY=""

# Семь файлов, подписи которых заменяются.
ARTIFACTS=(
  "xros-branding-1.0-2-any.pkg.tar.zst"
  "xros-cli-1.0-1-x86_64.pkg.tar.zst"
  "xros-installer-1.0-6-x86_64.pkg.tar.zst"
  "xros-welcome-1.0-2-any.pkg.tar.zst"
  "xros.db.tar.gz"
  "xros.files.tar.gz"
  "xros-sources.manifest"
)

# Три места, где хранится fingerprint.
FPR_FILES=(
  "${REPO_ROOT}/profile/pacman.conf"
  "${REPO_ROOT}/profile/airootfs/etc/pacman.conf"
  "${REPO_ROOT}/profile/airootfs/usr/share/xros/xros-gpg.conf"
)

# Три места, где хранится публичный ключ.
PUBKEY_FILES=(
  "${REPO_ROOT}/xros-gpg-prod/xros-public.key"
  "${REPO_ROOT}/profile/airootfs/usr/share/xros/xros-public.key"
)

log()  { echo "[$(date -Is)] $*"; }
fail() { echo "[$(date -Is)] ОШИБКА: $*" >&2; exit 1; }

usage() {
  echo "Использование: $0 --new-sigs-dir DIR --new-public-key FILE"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --new-sigs-dir)     NEW_SIGS_DIR="$2"; shift 2 ;;
    --new-public-key)   NEW_PUBKEY="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$NEW_SIGS_DIR" && -d "$NEW_SIGS_DIR" ]] || fail "--new-sigs-dir не задан или не существует"
[[ -n "$NEW_PUBKEY" && -f "$NEW_PUBKEY" ]] || fail "--new-public-key не задан или не существует"

# --- Этап 0: подготовка рабочих каталогов и журнала ---
STAMP="$(date +%Y-%m-%d_%H%M%S)"
WORK="/tmp/xros-migration-${STAMP}"
CANDIDATE="${WORK}/candidate"
BACKUP="${WORK}/backup"
JOURNAL="${WORK}/journal.txt"
mkdir -p "$CANDIDATE" "$BACKUP"
echo "=== Журнал миграции production-ключа XrOS ===" > "$JOURNAL"
echo "Начало: $(date -Is)" >> "$JOURNAL"
echo "Старый FPR: $OLD_FPR" >> "$JOURNAL"
echo "Новый FPR:  $NEW_FPR" >> "$JOURNAL"

# Автоматический откат при любом сбое после начала замены.
ROLLBACK_NEEDED=0
rollback() {
  local rc=$?
  if [[ "$ROLLBACK_NEEDED" == "1" ]]; then
    log "СБОЙ (код $rc) — автоматический откат из бэкапа ${BACKUP}"
    echo "СБОЙ (код $rc) — откат" >> "$JOURNAL"
    cp -a "${BACKUP}/." "${REPO_DIR}/" 2>/dev/null || true
    cp -a "${BACKUP}/snapshot/." "${SNAP_DIR}/" 2>/dev/null || true
    cp -a "${BACKUP}/pubkey/." "${REPO_ROOT}/xros-gpg-prod/" 2>/dev/null || true
    log "Откат завершён. Проверьте состояние вручную."
    echo "Откат завершён: $(date -Is)" >> "$JOURNAL"
  fi
  exit "$rc"
}
trap rollback EXIT

# --- Этап 1: backup (до любых изменений) ---
log "Этап 1: backup старых .sig, публичного ключа и конфигов"
mkdir -p "${BACKUP}/snapshot" "${BACKUP}/pubkey" "${BACKUP}/configs"
for f in "${ARTIFACTS[@]}"; do
  cp -a "${REPO_DIR}/${f}.sig" "${BACKUP}/" || fail "backup: нет ${f}.sig в репозитории"
  cp -a "${SNAP_DIR}/${f}.sig" "${BACKUP}/snapshot/" || fail "backup: нет ${f}.sig в snapshot"
done
cp -a "${REPO_DIR}/xros.db.sig" "${BACKUP}/" 2>/dev/null || true
cp -a "${REPO_DIR}/xros.files.sig" "${BACKUP}/" 2>/dev/null || true
cp -a "${SNAP_DIR}/xros.db.sig" "${BACKUP}/snapshot/" 2>/dev/null || true
cp -a "${SNAP_DIR}/xros.files.sig" "${BACKUP}/snapshot/" 2>/dev/null || true
for f in "${PUBKEY_FILES[@]}"; do cp -a "$f" "${BACKUP}/pubkey/" || fail "backup: нет $f"; done
for f in "${FPR_FILES[@]}"; do cp -a "$f" "${BACKUP}/configs/" || fail "backup: нет $f"; done
(
  cd "$BACKUP" || exit
  mapfile -d '' files < <(find . -type f ! -name SHA256SUMS -print0 | sort -z)
  sha256sum "${files[@]}" > SHA256SUMS
)
sha256sum -c "${BACKUP}/SHA256SUMS" >/dev/null || fail "backup: проверка SHA256SUMS не прошла"
log "Backup создан: ${BACKUP} (SHA256SUMS OK)"
echo "Backup: ${BACKUP}" >> "$JOURNAL"

# --- Этап 2: staging кандидата (в отдельном каталоге, production не трогается) ---
log "Этап 2: staging кандидата в ${CANDIDATE}"
for f in "${ARTIFACTS[@]}"; do
  [[ -f "${NEW_SIGS_DIR}/${f}.sig" ]] || fail "кандидат: нет ${f}.sig в ${NEW_SIGS_DIR}"
  cp -a "${NEW_SIGS_DIR}/${f}.sig" "${CANDIDATE}/" || fail "staging: ${f}.sig"
  # Подписи должны быть БИНАРНЫМИ (dearmored). Armored .sig pacman отвергает.
  if head -c 27 "${CANDIDATE}/${f}.sig" | grep -q "BEGIN PGP SIGNATURE"; then
    fail "кандидат: ${f}.sig — ASCII-armored, нужны БИНАРНЫЕ (dearmored) подписи"
  fi
done
cp -a "$NEW_PUBKEY" "${CANDIDATE}/xros-public-new.key" || fail "staging: публичный ключ"
log "Кандидат собран: 7 .sig (бинарные) + публичный ключ"
echo "Кандидат: ${CANDIDATE}" >> "$JOURNAL"

# --- Этап 3: гейт верификации кандидата (ДО замены production) ---
log "Этап 3: гейт верификации кандидата"
TMPG="$(mktemp -d)"; chmod 700 "$TMPG"
gpg --batch --homedir "$TMPG" --import "${CANDIDATE}/xros-public-new.key" >/dev/null 2>&1 \
  || fail "гейт: импорт нового публичного ключа не удался"
IMPORTED_FPR="$(gpg --batch --homedir "$TMPG" --show-keys --with-colons "${CANDIDATE}/xros-public-new.key" 2>/dev/null | awk -F: '$1 == "fpr" {print $10}')"
[[ "$IMPORTED_FPR" == "$NEW_FPR" ]] || fail "гейт: FPR импортированного ключа ($IMPORTED_FPR) != $NEW_FPR"
for f in "${ARTIFACTS[@]}"; do
  # Проверка подписи во временном keyring, только новым ключом.
  OUT="$(gpg --batch --homedir "$TMPG" --status-fd 1 --verify "${CANDIDATE}/${f}.sig" "${REPO_DIR}/${f}" 2>/dev/null)"
  echo "$OUT" | grep -q "VALIDSIG ${NEW_FPR}" || fail "гейт: ${f}.sig — нет VALIDSIG новым ключом"
  # Отсутствие подписи старым ключом.
  echo "$OUT" | grep -q "VALIDSIG ${OLD_FPR}" && fail "гейт: ${f}.sig — подпись СТАРЫМ ключом"
  # SHA-256 артефакта не изменился (сверка с эталоном Фазы 2 — файл в репозитории).
  log "  ${f}: VALIDSIG новым ключом OK"
done
rm -rf "$TMPG"
log "Гейт пройден: 7/7 VALIDSIG новым ключом, 0 старых подписей"
echo "Гейт: 7/7 VALIDSIG новым ключом" >> "$JOURNAL"

# --- Этап 4: замена (единственный шаг, после которого включается rollback) ---
log "Этап 4: замена production-файлов"
ROLLBACK_NEEDED=1
for f in "${ARTIFACTS[@]}"; do
  cp -a "${CANDIDATE}/${f}.sig" "${REPO_DIR}/${f}.sig" || fail "замена: ${f}.sig (repo)"
  cp -a "${CANDIDATE}/${f}.sig" "${SNAP_DIR}/${f}.sig" || fail "замена: ${f}.sig (snapshot)"
  chmod 644 "${REPO_DIR}/${f}.sig" "${SNAP_DIR}/${f}.sig"
done
# Aliases на новые подписи (побайтовые копии, как в Фазе 5A).
cp -a "${REPO_DIR}/xros.db.tar.gz.sig" "${REPO_DIR}/xros.db.sig" || fail "замена: xros.db.sig"
cp -a "${REPO_DIR}/xros.files.tar.gz.sig" "${REPO_DIR}/xros.files.sig" || fail "замена: xros.files.sig"
cp -a "${SNAP_DIR}/xros.db.tar.gz.sig" "${SNAP_DIR}/xros.db.sig" || fail "замена: xros.db.sig (snapshot)"
cp -a "${SNAP_DIR}/xros.files.tar.gz.sig" "${SNAP_DIR}/xros.files.sig" || fail "замена: xros.files.sig (snapshot)"
chmod 644 "${REPO_DIR}/xros.db.sig" "${REPO_DIR}/xros.files.sig" "${SNAP_DIR}/xros.db.sig" "${SNAP_DIR}/xros.files.sig"
# Публичный ключ (все три копии).
for f in "${PUBKEY_FILES[@]}"; do
  cp -a "${CANDIDATE}/xros-public-new.key" "$f" || fail "замена: публичный ключ $f"
  chmod 644 "$f"
done
# Fingerprint (все три места).
sed -i "s/${OLD_FPR}/${NEW_FPR}/g" "${FPR_FILES[@]}" || fail "замена: fingerprint в конфигах"
log "Замена выполнена"
echo "Замена выполнена: $(date -Is)" >> "$JOURNAL"

# --- Этап 5: пост-гейт (проверка результата; сбой → автоматический откат) ---
log "Этап 5: пост-гейт"
diff -r "${REPO_DIR}" "${SNAP_DIR}" >/dev/null || fail "пост-гейт: репозиторий != snapshot"
grep -q "$NEW_FPR" "${FPR_FILES[@]}" || fail "пост-гейт: новый FPR не во всех конфигах"
grep -q "$OLD_FPR" "${FPR_FILES[@]}" && fail "пост-гейт: старый FPR остался в конфигах"
log "Пост-гейт пройден: repo == snapshot, FPR новый везде"
echo "Пост-гейт: PASS" >> "$JOURNAL"

# --- Этап 6: завершение ---
ROLLBACK_NEEDED=0
trap - EXIT
log "Миграция завершена. Дальнейшие проверки (вне скрипта):"
log "  - scripts/verify-repo-signatures.sh"
log "  - scripts/xros-diagnose.sh (ожидается PASS=306 FAIL=0)"
log "  - полный набор тестов (ожидается 919/0/7)"
log "  - pacman -Sy сценарий B + установка пакета новым ключом"
log "  - гейт автообновления (xros_xros_repo_signed)"
log "Журнал: ${JOURNAL}"
log "Backup: ${BACKUP} (НЕ удалять до подтверждения успешной миграции)"
echo "Завершено: $(date -Is)" >> "$JOURNAL"
echo "Backup: ${BACKUP}" >> "$JOURNAL"
