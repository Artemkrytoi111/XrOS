# XrOS — production-ключ подписи (публичный ключ)

Сюда владелец кладёт ТОЛЬКО публичный ключ production-подписи:
`xros-public.key` (armored, `gpg --export --armor <отпечаток>`).

Правила:

- Приватный ключ — ТОЛЬКО офлайн, на машине владельца. Его нет
  в репозитории, GitHub, build-env и ISO. Никогда.
- После размещения ключа владелец записывает его отпечаток
  в `profile/airootfs/usr/share/xros/xros-gpg.conf`
  (`XROS_GPG_PROD_FPR`, 40 hex-символов).
- Тестовый ключ `0EC935D2…` здесь не используется — он только
  для `xros-gpg-test/`.
- Процедура подписания — `docs/REPO-PUBLISHING.md` §2.3 и
  `scripts/sign-repo-offline.sh` (только на офлайн-машине владельца).
- Проверка подписей — `scripts/verify-repo-signatures.sh`.
