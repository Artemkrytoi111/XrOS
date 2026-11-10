# XrOS — финальная доработка: брендинг и канонические исходники (задача 7)

Дата: 10 ноября 2026. Запреты соблюдены: `scripts/build.sh`, mkarchiso и ISO
не запускались, пакеты/репозиторий не публиковались, `~/workspace/akvt-os`
не трогался, `ARCHITECTURE.md`, `AUDIT-REPORT.md`, `README.md`,
`scripts/xros-diagnose.sh` не редактировались.

Палитра (везде): фон `#08080D`, доп. фон `#111018`, акцент `#8B00FF`,
второй акцент `#B66AFF`, текст `#F5F3FA`, вторичный текст `#A6A0B3`,
границы `#30283B`. Старые цвета (индиго, циан и промежуточные
фиолетовые из прежних концепций) запрещены — их hex-коды здесь
намеренно не приводятся: `xros-diagnose.sh` (§19ж) проверяет `docs/`
на их наличие.

## 1. Обои без надписи — ПРИНЯТО (новый вариант)

Исходник `branding/wallpaper-real.png` (1672×941) осмотрен: надпись «XrOS»
под символом X, полоса y 573–634, x 630–1000. Нижние острия X заканчиваются
около y=568–570, между X и надписью — тёмный зазор (y 565–572, ярких
пикселей почти нет). Фон под надписью — почти чёрный с плавным затуханием
фиолетового свечения X сверху, поэтому надпись убирается инпейнтингом.

Метод (`scripts/make-branding.py`, `remove_text_wallpaper`, воспроизводимо):
маска ярких пикселей (макс. канал > 70) в полосе y 574–646, x 590–1040
(доли от размера: y 0.610–0.687, x 0.353–0.622), расширенная на 3 px;
заполнение — диффузия Лапласа (гармоническая интерполяция от краёв маски,
до сходимости delta < 0.01, ~730 итераций; зависимость — только numpy+PIL,
cv2 на хосте нет). `wallpaper-real.png` НЕ тронут — это реальный файл от Мии.

**Первая попытка не удалась и была отброшена:** маска с верхней границей
y=540 задела нижние острия X и свечение (проверено попиксельным сравнением
и парным кропом «оригинал/очищенный» 2×: острия оказались срезаны,
свечение размазано). Полоса сужена до y≥574 — вторая попытка чистая.

Проверка результата глазами (полный кадр 1920×1080 на тёмном фоне и кроп
зоны X 2×, оригинал рядом с очищенным):
- X, его острия и свечение — целы, острые кромки сохранены;
- следов надписи и границ маски не видно; зона под X — плавный тёмный
  градиент, читается как затухание свечения;
- остаточная яркость в полосе надписи: 0 пикселей с яркостью > 90
  (макс. 81 — остаток свечения, не текст: текст был белым 240+ и
  фиолетовым 255);
- волны-ленты и свечение сохранены. Единственная потеря: тонкая
  волна-лента, проходившая за надписью, в зоне маски сглажена — она
  очень бледная, на общем фоне её отсутствие не читается.

Итог: отдельный графический ресурс НЕ нужен. `branding/wallpaper.png`
1920×1080 и `branding/wallpaper.jpg` (качество 92) — новый вариант без
надписи, принят. `grub-bg.png`/`grub-bg.jpg` перегенерированы из
очищенных обоев (надписи на фоне GRUB тоже нет; затемнение центра под
меню сохранено: яркость под меню 5,8, макс. 110; под таймером 3,0).

## 2. Канонические исходники — только в branding/

`banner.txt` перенесён: канонический исходник теперь
`branding/banner.txt` (скопирован байт-в-байт из
`profile/airootfs/usr/share/xros/banner.txt`, sha256 совпал до и после).
Содержимое — одна строка `XrOS 1.0 — на базе Arch Linux.` (не ASCII-арт;
печатается командой `xros`, используется как backtitle установщика).
Старых цветов и названий в баннере нет.

Генерация/копирование настроены:
- `scripts/make-branding.py` — теперь раскладывает `banner.txt` из
  `branding/` в `profile/airootfs/usr/share/xros/` и в staged-каталог
  `packages/xros-branding/` (а также стейджит туда же остальные 6 файлов —
  раньше это делал только этап 2 `build.sh`); `logo_small` теперь делается
  ТОЛЬКО из прозрачного `xros-logo.png` (раньше — напрямую из
  `xros-logo-real.png`); `wallpaper_1080`/`grub_bg` принимают очищенное
  от надписи изображение.
- `packages/xros-branding/PKGBUILD` — комментарий про banner.txt исправлен
  (исходник — `branding/banner.txt`), `prepare()` теперь сверяет
  staged-`banner.txt` с `branding/banner.txt`, а не с airootfs.
- `scripts/build.sh` (только комментарий этапа 2, не запускался) —
  стейджинг `banner.txt` теперь из `branding/banner.txt`, с пометкой,
  что то же делает `make-branding.py`.
- `branding/README.md` — раздел обоев (без надписи, метод, проверка,
  неудачная первая попытка), раздел баннера, исправлены устаревшие данные:
  яркость под меню GRUB 7,2 → 5,8; строка «отдельных копий в каталоге
  пакета нет» была неверна — staged-копии в `packages/xros-branding/`
  есть, их сверяет `prepare()`.
- `preview/index.html` — подпись к обоям: «без надписи «XrOS» (надпись
  убрана инпейнтингом…)»; ссылки (`../branding/wallpaper.jpg`,
  `../branding/xros-logo.png`, `../branding/xros-logo-small.png`,
  `../branding/grub-bg.jpg`) уже указывали на актуальные файлы —
  менять нечего.

## 3. Таблица синхронности (SHA256, сверено после перегенерации)

Канон — `branding/`. Все копии — байтовые копии исходника.

| Файл | SHA256 (канон) | Копии | Совпадает |
|---|---|---|---|
| `xros-logo.png` | `2a4730d06dfb2166c2dd69dadd88e7a3940c3d737ca7a3a78966d4619cfe07f7` | `profile/airootfs/usr/share/xros/`, `packages/xros-branding/` | ✅ 3/3 |
| `xros-logo-small.png` | `9333c51a685d1187ad17c85e78a3e37fa527556d660e905fefbf8ba14c0a7497` | `profile/airootfs/usr/share/xros/`, `packages/xros-branding/` | ✅ 3/3 |
| `wallpaper.png` | `949df7a8b5cd0d321d8b5f7c2c14da49de41bc4392478f8b559281293e002733` | `profile/airootfs/usr/share/xros/`, `packages/xros-branding/` | ✅ 3/3 |
| `wallpaper.jpg` | `43fbef3490f3fb135bccfc823e41dafa92aa2ecf8f7c57d92ac7c0004fb4d37c` | `profile/airootfs/usr/share/xros/`, `packages/xros-branding/` | ✅ 3/3 |
| `grub-bg.png` | `2e19f6006a703b19f7e69e3549abdc9c8a4c82283f1a472d5399dbe7bf2866e2` | airootfs `usr/share/xros/`, `packages/xros-branding/`, `profile/grub/splash.png`, `profile/grub/theme/`, airootfs `grub-theme/` | ✅ 6/6 |
| `grub-bg.jpg` | `b4deb522735e198724ddcee741ec8c4c673ded37b2a8640301a4c0669fb71f98` | airootfs `usr/share/xros/`, `packages/xros-branding/`, `profile/grub/grub-bg.jpg`, `profile/grub/splash.jpg`, `profile/grub/theme/`, airootfs `grub-theme/` | ✅ 7/7 |
| `banner.txt` | `3ee7e20abfaaa849f3882e456adee0fe2127bd285324bcf9c6a8766d1b65bb82` | `profile/airootfs/usr/share/xros/`, `packages/xros-branding/` | ✅ 3/3 |

Исходники (не копии, не перезаписывались):
`branding/xros-logo-real.png` — `765d55ff5c75a8a327ac85a824066fa441ddd1052735f31a0c8677557f7f81e6`,
`branding/wallpaper-real.png` — `12a95202af0d209783acb6e93aef04a3d3965aeac92086da3411b6086fa7a32d`
(sha256 до и после работ совпал).

Примечания:
- `xros-logo.png` не изменился (sha256 тот же, что до работ:
  `2a4730d0…`), `xros-logo-small.png` изменился
  (было `ac36a94e…`, стало `9333c51a…`) — только из-за смены источника
  на `xros-logo.png` (чистка невидимой пыли alpha < 5); кроп X тот же
  (28, 0, 1516, 1020), видимое содержимое то же.
- `wallpaper.png`/`wallpaper.jpg`/`grub-bg.*` изменились ожидаемо
  (удалена надпись).
- `profile/grub/grub-bg.jpg` (фон GRUB рядом с `grub.cfg`) —
  в синхронности учтён (совпадает с каноном).

## 4. Старые цвета

`grep -rE` по паттерну старых цветов из §11 `xros-diagnose.sh` по всему
проекту (кроме `AUDIT-REPORT.md` и `scripts/xros-diagnose.sh`):
**0 совпадений**. Остатки только там, где их нельзя/не нужно трогать:
- `AUDIT-REPORT.md:31` — историческая запись аудита о том, что старый
  цвет БЫЛ и исправлен (файл запрещён к редактированию);
- `scripts/xros-diagnose.sh` — сам чекер старых цветов
  (паттерн проверки, не нарушение).
Исправлять в брендинге и `make-branding.py` было нечего — старых цветов
там уже не было.

## 5. Результаты проверок

- `python3 -m py_compile scripts/make-branding.py` — **OK**.
- `python3 scripts/make-branding.py` (перегенерация, не сборка ISO) —
  **OK**, выход 0: логотип 1536×1024 RGBA, углы alpha [0,0,0,0];
  обои 1920×1080; `xros-logo-small.png` 400×274 RGBA; яркость grub-bg:
  меню 5,8 / шапка 5,0 / таймер 3,0.
- PIL, все PNG:
  - `xros-logo.png` 1536×1024 RGBA, углы alpha=0 (перепроверено);
  - `xros-logo-real.png` 1536×1024 RGBA;
  - `xros-logo-small.png` 400×274 RGBA, углы alpha=0, прозрачных
    пикселей 65,1%, непрозрачных 30,8% (прозрачность сохранена,
    производная только из прозрачного `xros-logo.png`);
  - `wallpaper.png` 1920×1080 RGB, `wallpaper.jpg` 1920×1080 RGB;
  - `grub-bg.png` 1024×768 RGB, `grub-bg.jpg` 1024×768 RGB.
- SHA256 всех копий — см. таблицу выше, расхождений нет.
- `preview/index.html` ссылается на актуальные файлы из `branding/`.
- Прогон `scripts/xros-diagnose.sh` (только чтение, 10.11.2026): все
  проверки брендинга PASS — наличие 6 файлов, синхронность §10а,
  PIL §10б, старые цвета §11, banner.txt, SHA256 §19д (все 7 файлов),
  старые цвета в `docs/` §19ж. Всего в прогоне 3 FAIL — все вне
  брендинга (маркеры TODO/FIXME, устаревший пакет xros-welcome,
  trap в движке).

## 6. Спецификация проверок для scripts/xros-diagnose.sh

Координатору: диагностика правится координатором, не этим агентом.
**Важно:** пока шла эта задача, координатор параллельно добавил
в `xros-diagnose.sh` §19д (синхронность брендинга по SHA256, канон
`branding/`, включая `banner.txt`) и §19ж (старых цветов нет в `docs/`) —
эти два пункта из черновика спецификации УЖЕ покрыты, повторно
добавлять их не нужно. Уже есть также: наличие 6 файлов, синхронность
6 файлов (airootfs + пакет), grub-bg (тема + splash), PIL-проверка
логотипа/обоев 1920×1080, theme.txt, grep старых цветов (§11),
синхронность banner.txt «пакет == airootfs». НЕ ХВАТАЕТ (фрагменты ниже):

```sh
# 10г. banner.txt: канон — branding/. Покрыто §19д (SHA256 всех 7 файлов)
# и строкой 349 («пакет == airootfs») — дополнительно ничего не нужно,
# кроме наличия branding/banner.txt (тоже есть в §19д). Этот блок —
# на случай, если §19д будет упрощён: оставить хотя бы его.

# 10д. grub-bg.jpg рядом с grub.cfg и копии в теме airootfs
# (сейчас проверяются только profile/grub/theme/ и splash).
for f in grub-bg.jpg grub-bg.png; do
  if cmp -s "branding/$f" "profile/airootfs/usr/share/xros/grub-theme/$f"; then
    ok "синхронно branding/$f (grub-theme в airootfs)"
  else
    bad "рассинхрон branding/$f (grub-theme в airootfs)"
  fi
done
if cmp -s branding/grub-bg.jpg profile/grub/grub-bg.jpg; then
  ok "синхронно grub-bg.jpg (рядом с grub.cfg)"
else
  bad "рассинхрон profile/grub/grub-bg.jpg"
fi

# 10е. PIL: маленький логотип (прозрачность), размер grub-bg,
# отсутствие надписи на обоях (полоса надписи в координатах 1920x1080:
# y 659-742, x 678-1194 — масштаб 1920/1672 от исходной полосы
# y 574-646, x 590-1040).
if python3 - <<'PY' 2>/dev/null
from PIL import Image
import numpy as np
small = Image.open('branding/xros-logo-small.png')
assert small.mode == 'RGBA', 'small: нет альфа-канала'
w, h = small.size
assert small.getpixel((0, 0))[3] == 0 and small.getpixel((w-1, 0))[3] == 0
assert small.getpixel((0, h-1))[3] == 0 and small.getpixel((w-1, h-1))[3] == 0
assert (np.asarray(small)[:, :, 3] == 0).mean() > 0.5, 'small: мало прозрачных px'
gb = Image.open('branding/grub-bg.png')
assert gb.size == (1024, 768), f'grub-bg {gb.size}'
gj = Image.open('branding/grub-bg.jpg')
assert gj.size == (1024, 768), f'grub-bg jpg {gj.size}'
wp = np.asarray(Image.open('branding/wallpaper.png').convert('RGB')).astype(int)
band = wp[659:742, 678:1194].max(axis=2)
assert (band > 90).sum() == 0, f'в полосе надписи осталось ярких px: {(band > 90).sum()}'
PY
then
  ok "small: RGBA, углы alpha=0; grub-bg 1024x768; на обоях нет надписи"
else
  bad "small/grub-bg/надпись: проверка PIL не пройдена"
fi

# 10ж. Исходники не перезаписывались (sha256 зафиксированы 10.11.2026).
# wallpaper-real.png — С надписью (это исходник от Мии, так и должно быть).
[ "$(sha256sum branding/wallpaper-real.png | cut -d' ' -f1)" = \
  12a95202af0d209783acb6e93aef04a3d3965aeac92086da3411b6086fa7a32d ] \
  && ok "wallpaper-real.png не менялся" || bad "wallpaper-real.png изменён"
[ "$(sha256sum branding/xros-logo-real.png | cut -d' ' -f1)" = \
  765d55ff5c75a8a327ac85a824066fa441ddd1052735f31a0c8677557f7f81e6 ] \
  && ok "xros-logo-real.png не менялся" || bad "xros-logo-real.png изменён"
```

## 7. Оставшиеся проблемы

1. **Снимок репозитория в airootfs устарел:** пакет
   `profile/airootfs/usr/share/xros/repo/xros/os/x86_64/xros-branding-1.0-1-any.pkg.tar.zst`
   (собран 10.11.2026 06:20, до этих правок) содержит старые обои
   С надписью и старый `xros-logo-small.png`. Пересборка пакета и
   репозитория — отдельный этап (не этого агента: публикация пакетов
   запрещена). После пересборки `xros-branding` проверить, что внутри
   пакета лежат файлы с sha256 из таблицы выше.
2. **Визуальная проверка на живой системе не проводилась:** обои и фон
   GRUB проверены только глазами на хосте (PNG) и по яркости зон меню.
   Как обои лягут в KDE Plasma и как читается меню GRUB — покажет
   только QEMU/живая проверка (этап координатора).
3. `AUDIT-REPORT.md:31` упоминает старый индиго-цвет в исторической
   записи аудита — это не нарушение: `xros-diagnose.sh` (раздел 11)
   уже исключает `AUDIT-REPORT.md` из grep старых цветов с комментарием
   «там они упомянуты как удалённые». Действий не требуется; ручной
   grep по всему дереву без исключений даст это одно известное совпадение.
