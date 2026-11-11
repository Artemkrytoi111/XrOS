#!/bin/bash
# Выполняется ВНУТРИ build-env rootfs. CONF — /xros/xros-gpg-test/pacman-test.conf.
set -u
CONF="/xros/xros-gpg-test/pacman-test.conf"
GPGDIR="/tmp/xros-gpg-test/gnupg"
DBDIR="/tmp/xros-gpg-test/db"
CACHEDIR="/tmp/xros-gpg-test/cache"
FPR="0EC935D2A8E31AEC1878BBE5797805A298A55BAA"
rm -rf /tmp/xros-gpg-test
mkdir -p "$GPGDIR" "$DBDIR" "$CACHEDIR"
pacman-key --config "$CONF" --init || exit 1
pacman-key --config "$CONF" --add /xros/xros-gpg-test/xros-public.key || exit 1
pacman-key --config "$CONF" --lsign-key "$FPR" || exit 1
echo "--- T1: подписанный пакет (ожидается УСПЕХ) ---"
pacman -Sy --config "$CONF" --noconfirm || exit 1
pacman -Sw xros-installer --config "$CONF" --noconfirm || exit 1
echo "T1 PASS: подписанный пакет скачан и проверен"
rm -rf "$CACHEDIR"/* "$DBDIR"/*
echo "--- T2: неподписанный пакет (ожидается ОТКАЗ) ---"
rm -f /xros/xros-gpg-test/test/os/x86_64/xros-installer-1.0-5-x86_64.pkg.tar.zst.sig
if pacman -Sy --config "$CONF" --noconfirm 2>/tmp/xros-gpg-test/t2.log \
   && pacman -Sw xros-installer --config "$CONF" --noconfirm 2>>/tmp/xros-gpg-test/t2.log; then
  echo "T2 FAIL: неподписанный пакет ПРИНЯТ (так быть не должно)"
  exit 1
else
  echo "T2 PASS: неподписанный пакет отклонён"
  grep -iE "signature|подпис" /tmp/xros-gpg-test/t2.log | head -3 || true
fi
rm -rf "$CACHEDIR"/* "$DBDIR"/*
echo "--- T3: плохая подпись (ожидается ОТКАЗ) ---"
cp /xros/xros-gpg-test/xros-installer-1.0-5-x86_64.pkg.tar.zst.sig.bak \
   /xros/xros-gpg-test/test/os/x86_64/xros-installer-1.0-5-x86_64.pkg.tar.zst.sig 2>/dev/null || true
# Портим подпись ВНУТРИ брони: обрезаем файл до 120 байт (тело подписи
# обрывается на середине) — gpg не сможет её разобрать. Просто дописать
# мусор ПОСЛЕ '-----END PGP SIGNATURE-----' НЕ работает: gpg игнорирует
# всё после END, и подпись остаётся валидной (проверено: T3 дал ложный
# FAIL на первом запуске именно из-за этого).
head -c 120 /xros/xros-gpg-test/test/os/x86_64/xros-installer-1.0-5-x86_64.pkg.tar.zst.sig \
  > /tmp/xros-gpg-test/corrupt.sig
mv /tmp/xros-gpg-test/corrupt.sig \
   /xros/xros-gpg-test/test/os/x86_64/xros-installer-1.0-5-x86_64.pkg.tar.zst.sig
if pacman -Sy --config "$CONF" --noconfirm 2>/tmp/xros-gpg-test/t3.log \
   && pacman -Sw xros-installer --config "$CONF" --noconfirm 2>>/tmp/xros-gpg-test/t3.log; then
  echo "T3 FAIL: пакет с плохой подписью ПРИНЯТ (так быть не должно)"
  exit 1
else
  echo "T3 PASS: пакет с плохой подписью отклонён"
  grep -iE "signature|подпис" /tmp/xros-gpg-test/t3.log | head -3 || true
fi
echo "GPG-ТЕСТ: ВСЕ ПРОВЕРКИ ПРОЙДЕНЫ (T1 PASS, T2 PASS, T3 PASS)"
