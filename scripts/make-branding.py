#!/usr/bin/env python3
"""XrOS — производные брендинга из реальных файлов.

Исходники прислала Мия 10 ноября 2026, они лежат в branding/ и не
перезаписываются этим скриптом:
- xros-logo-real.png (1536x1024, RGBA) — чёрный металлический X
  с фиолетовым неоном. У файла УЖЕ есть настоящий альфа-канал
  (углы полностью прозрачны, проверено композитом на белой,
  шахматной и тёмной подложке 10.11.2026): чёрного ореола нет.
  Поэтому маска по яркости НЕ извлекается — она только обрезала бы
  полупрозрачное неоновое свечение и дала рваные края. Логотип
  берётся как есть, чистится только невидимая пыль (альфа < 5).
- wallpaper-real.png (1672x941, RGB) — чёрные обои с фиолетовыми
  волнами-лентами, по центру X и надпись «XrOS». По решению Мии
  10.11.2026 основной вариант обоев — БЕЗ надписи: надпись
  убирается инпейнтингом (remove_text_wallpaper, диффузия Лапласа
  по маске ярких пикселей в полосе надписи), X, волны и свечение
  сохраняются. wallpaper-real.png при этом НЕ трогается — это
  реальный исходник, присланный Мией.

Скрипт делает производные и раскладывает копии по профилю
и пакету, чтобы везде лежали одни и те же файлы:
- xros-logo.png — прозрачный логотип 1536x1024 (RGBA, альфа-канал).
- xros-logo-small.png — логотип, обрезанный по самому X, ПРОЗРАЧНЫЙ
  фон (раньше был сплющен на чёрный RGB — исправлено 10.11.2026),
  ширина 400px. Для сайдбара установщика. Делается ТОЛЬКО из
  прозрачного xros-logo.png (не из исходника напрямую).
- wallpaper.png / wallpaper.jpg — обои 1920x1080 (ресайз очищенного
  от надписи изображения, X цел — соотношение исходника почти
  равно 16:9).
- grub-bg.png / grub-bg.jpg — обои 1024x768 (кроп 4:3 по центру).
  X попадает под зону меню GRUB (верх 30%, высота 45%), поэтому
  центр затемнён с растушёвкой — текст меню читается. Надписи
  «XrOS» на фоне GRUB больше нет (убрана вместе с обоями).
- banner.txt — текстовый баннер «XrOS 1.0 — на базе Arch Linux.»
  (одна строка, не ASCII-арт). Канонический исходник —
  branding/banner.txt; скрипт раскладывает копии в airootfs
  и в staged-каталог пакета xros-branding.
- select_*.png / terminal_box_*.png — 9-слайс картинки для темы
  GRUB (theme.txt ссылается на них, без файлов тема не грузится
  целиком). select — заливка акцентом, terminal_box — тёмный
  бокс с границей.
- Иконки темы GRUB — кружки с буквами в фиолетовой палитре.

Фирменная система XrOS (единая, 10.11.2026):
фон #08080D, доп. фон #111018, акцент #8B00FF, второй акцент #B66AFF,
текст #F5F3FA, вторичный текст #A6A0B3, границы #30283B.
Тот же набор — в branding/design-tokens.css, src/xros-install-gui-rs
(src/theme.rs), profile/grub/theme/theme.txt, src/xros-welcome-gui.

Запуск: python3 scripts/make-branding.py
"""
import hashlib
import os
import shutil
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.expanduser("~/workspace/xros")
BRANDING = os.path.join(ROOT, "branding")
GRUB_THEME = os.path.join(ROOT, "profile/grub/theme")
AIROOTFS_XROS = os.path.join(ROOT, "profile/airootfs/usr/share/xros")
AIROOTFS_GRUB_THEME = os.path.join(AIROOTFS_XROS, "grub-theme")
PKG_BRANDING = os.path.join(ROOT, "packages/xros-branding")

# Фирменная система XrOS (см. branding/design-tokens.css).
ACCENT = (139, 0, 255)         # #8B00FF — акцент
ACCENT_LIGHT = (182, 106, 255)  # #B66AFF — второй акцент
BG = (8, 8, 13)                # #08080D — фон основной
PANEL = (17, 16, 24)           # #111018 — фон дополнительный
TEXT = (245, 243, 250)         # #F5F3FA — текст основной
DIM = (166, 160, 179)          # #A6A0B3 — текст вторичный
BORDER = (48, 40, 59)          # #30283B — границы
WHITE = (255, 255, 255)
GREY = (120, 120, 130)
WINDOWS_BLUE = (0, 120, 215)  # фирменный цвет иконки Windows
RED = (200, 60, 60)           # иконка выключения

FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def copy(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)


def transparent_logo(logo_real, out_path):
    """Прозрачный логотип из реального файла.

    У исходника уже есть настоящий альфа-канал (проверено 10.11.2026
    композитом на белой, шахматной и тёмной подложке — ореолов нет,
    углы прозрачны). Сохраняем его как есть, убираем только
    невидимую пыль: пиксели с альфой < 5 не видны ни на каком фоне,
    но мешают чистой проверке углов. Края не трогаем: растушёвка
    свечения — часть знака."""
    logo = Image.open(logo_real).convert("RGBA")
    alpha = logo.getchannel("A")
    clean = alpha.point(lambda p: 0 if p < 5 else p)
    logo.putalpha(clean)
    logo.save(out_path)
    corners = [logo.getpixel(xy)[3] for xy in
               [(0, 0), (logo.width - 1, 0),
                (0, logo.height - 1), (logo.width - 1, logo.height - 1)]]
    return logo.size, corners


def logo_small(logo_path, out_path, width=400, pad=24):
    """Маленький логотип: кроп по самому X (по альфа-каналу, не по
    яркости — у свечения альфа тянется дальше металла), ПРОЗРАЧНЫЙ
    фон, ширина 400px. Квадратный кроп тут не подходит: X широкий
    (примерно 1370x940), квадрат обрезал бы острия."""
    logo = Image.open(logo_path).convert("RGBA")
    alpha = logo.getchannel("A")
    # границы X: пиксели с заметной альфой (металл и неон)
    bbox = alpha.point(lambda p: 255 if p > 10 else 0).getbbox()
    x0 = max(0, bbox[0] - pad)
    y0 = max(0, bbox[1] - pad)
    x1 = min(logo.width, bbox[2] + pad)
    y1 = min(logo.height, bbox[3] + pad)
    crop = logo.crop((x0, y0, x1, y1))
    small = crop.resize((width, round(width * crop.height / crop.width)),
                        Image.LANCZOS)
    small.save(out_path)  # RGBA — прозрачность сохраняется
    return small.size, (x0, y0, x1, y1)


def remove_text_wallpaper(wallpaper_path):
    """Обои БЕЗ надписи «XrOS»: инпейнтинг полосы надписи.

    Геометрия для исходника 1672x941 (замерено 10.11.2026):
    - нижние острия X заканчиваются около y=568-570, над ними —
      металл и фиолетовое свечение (их трогать нельзя);
    - надпись «XrOS» — y 573-634, x 630-1000; между X и надписью
      тёмный зазор y 565-572 (ярких пикселей почти нет).
    Маска — яркие пиксели (макс. канал > 70) внутри полосы
    y 574-646, x 590-1040 (доли от размера: y 0.610-0.687,
    x 0.353-0.622), расширенная на 3 px. Верх маски y=571 —
    с запасом ниже остриёв X. Заполнение — диффузия Лапласа
    (гармоническая интерполяция от краёв маски): фон под надписью
    почти чёрный с плавным затуханием свечения X сверху, поэтому
    диффузия даёт незаметный переход. Тонкая волна-лента, проходившая
    за надписью, в зоне маски теряется — она очень бледная, на
    общем фоне её отсутствие не читается. Проверено глазами
    10.11.2026: X, его острия и свечение целы, следов надписи нет.
    Возвращает очищенное RGB-изображение в размере исходника."""
    wp = Image.open(wallpaper_path).convert("RGB")
    w, h = wp.size
    a = np.asarray(wp).astype(np.float64)
    lum = a.max(axis=2)
    x0, x1 = int(w * 0.353), int(w * 0.622)
    y0, y1 = int(h * 0.610), int(h * 0.687)
    mask = np.zeros(lum.shape, dtype=bool)
    band = lum > 70
    band[:y0, :] = False
    band[y1:, :] = False
    band[:, :x0] = False
    band[:, x1:] = False
    mask |= band
    mimg = Image.fromarray((mask * 255).astype(np.uint8))
    mimg = mimg.filter(ImageFilter.MaxFilter(7))  # расширение на 3 px
    mask = np.asarray(mimg) > 0
    filled = a.copy()
    filled[mask] = 0
    for _ in range(4000):
        up = np.roll(filled, 1, axis=0)
        down = np.roll(filled, -1, axis=0)
        left = np.roll(filled, 1, axis=1)
        right = np.roll(filled, -1, axis=1)
        avg = (up + down + left + right) / 4.0
        new = filled.copy()
        new[mask] = avg[mask]
        delta = float(np.abs(new[mask] - filled[mask]).max())
        filled = new
        if delta < 0.01:
            break
    return Image.fromarray(np.clip(filled, 0, 255).astype(np.uint8))


def wallpaper_1080(wp_image, out_png, out_jpg):
    """Обои 1920x1080 из очищенного от надписи изображения.
    Соотношение исходника 1672:941 почти равно 16:9, поэтому просто
    ресайз — ничего не обрезается, X целиком в кадре."""
    wp = wp_image.resize((1920, 1080), Image.LANCZOS)
    wp.save(out_png)
    wp.save(out_jpg, quality=92)
    return wp.size


def grub_bg(wp_image, out_png, out_jpg):
    """Фон GRUB 1024x768. Кроп 4:3 по центру исходника, затем центр
    затемняется под меню (меню: верх 30%, высота 45%, ширина 50%).
    Кроп нельзя сдвинуть так, чтобы X ушёл из-под меню: по вертикали
    окно кропа — вся высота исходника, а по горизонтали хода всего
    ~200px, X всё равно остаётся по центру. Поэтому затемнение."""
    wp = wp_image.convert("RGB")
    # окно кропа 4:3 по центру: ширина = 941 * 4 / 3
    cw = int(wp.height * 4 / 3)
    x0 = (wp.width - cw) // 2
    gb = wp.crop((x0, 0, x0 + cw, wp.height)).resize((1024, 768),
                                                     Image.LANCZOS)
    # маска затемнения: прямоугольник чуть шире и выше меню,
    # края растушёваны, чтобы не было видно границы
    mask = Image.new("L", gb.size, 0)
    d = ImageDraw.Draw(mask)
    d.rectangle([180, 175, 844, 640], fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(60))
    # затемнённая копия: яркость 42% от исходной
    dark = gb.point(lambda p: int(p * 0.42))
    gb = Image.composite(dark, gb, mask)
    # и общее лёгкое затемнение всего фона для читаемости меню
    gb = gb.point(lambda p: int(p * 0.92))
    gb.save(out_png)
    gb.convert("RGB").save(out_jpg, quality=92)
    return gb.size


def nine_slice(prefix, theme_dir, airootfs_theme_dir, size=16,
               fill=None, border=None, rounded=True):
    """9-слайс картинки для GRUB: <prefix>_c/_n/_s/_e/_w/_nw/_ne/_sw/_se.

    GRUB режет бокс на 9 частей: углы не тянутся, края тянутся в одну
    сторону, центр — в обе. fill — заливка центра и краёв, border —
    цвет 1px рамки по внешнему краю (None — без рамки)."""
    fill = fill if fill is not None else ACCENT
    parts = {}
    # центр и края — сплошная заливка
    parts["c"] = Image.new("RGBA", (size, size), fill + (255,))
    parts["n"] = Image.new("RGBA", (size, size), fill + (255,))
    parts["s"] = Image.new("RGBA", (size, size), fill + (255,))
    parts["e"] = Image.new("RGBA", (size, size), fill + (255,))
    parts["w"] = Image.new("RGBA", (size, size), fill + (255,))
    if border is not None:
        for name in ("n", "s", "e", "w"):
            d = ImageDraw.Draw(parts[name])
            if name == "n":
                d.line([(0, 0), (size - 1, 0)], fill=border + (255,), width=1)
            elif name == "s":
                d.line([(0, size - 1), (size - 1, size - 1)],
                       fill=border + (255,), width=1)
            elif name == "e":
                d.line([(size - 1, 0), (size - 1, size - 1)],
                       fill=border + (255,), width=1)
            else:
                d.line([(0, 0), (0, size - 1)], fill=border + (255,), width=1)
    # углы: заливка со скруглённым внешним углом
    for name, corner in (("nw", (0, 0)), ("ne", (1, 0)),
                         ("sw", (0, 1)), ("se", (1, 1))):
        im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        d.rectangle([0, 0, size - 1, size - 1], fill=fill + (255,))
        if rounded:
            # скругление честно, попиксельно: дуга радиуса size-1
            # с центром во ВНУТРЕННЕМ углу квадрата (для nw — (15,15)):
            # всё дальше радиуса от него — прозрачно
            cx = size - 1 if corner[0] == 0 else 0
            cy = size - 1 if corner[1] == 0 else 0
            px = im.load()
            r = size - 1
            for y in range(size):
                for x in range(size):
                    dx = x - cx
                    dy = y - cy
                    if dx * dx + dy * dy > r * r:
                        px[x, y] = (0, 0, 0, 0)
        if border is not None:
            d = ImageDraw.Draw(im)
            if name == "nw":
                d.arc([0, 0, 2 * size - 2, 2 * size - 2], 180, 270,
                      fill=border + (255,), width=1)
                d.line([(0, size - 1), (0, 0)], fill=border + (255,))
                d.line([(0, 0), (size - 1, 0)], fill=border + (255,))
            elif name == "ne":
                d.arc([-(size - 1), 0, size - 1, 2 * size - 2], 270, 360,
                      fill=border + (255,), width=1)
                d.line([(size - 1, size - 1), (size - 1, 0)],
                       fill=border + (255,))
                d.line([(size - 1, 0), (0, 0)], fill=border + (255,))
            elif name == "sw":
                d.arc([0, -(size - 1), 2 * size - 2, size - 1], 90, 180,
                      fill=border + (255,), width=1)
                d.line([(0, 0), (0, size - 1)], fill=border + (255,))
                d.line([(0, size - 1), (size - 1, size - 1)],
                       fill=border + (255,))
            else:
                d.arc([-(size - 1), -(size - 1), size - 1, size - 1], 0, 90,
                      fill=border + (255,), width=1)
                d.line([(size - 1, 0), (size - 1, size - 1)],
                       fill=border + (255,))
                d.line([(size - 1, size - 1), (0, size - 1)],
                       fill=border + (255,))
        parts[name] = im
    for name, im in parts.items():
        fname = f"{prefix}_{name}.png"
        im.save(os.path.join(theme_dir, fname))
        copy(os.path.join(theme_dir, fname),
             os.path.join(airootfs_theme_dir, fname))
    return sorted(parts)


def grub_icons(theme_dir, airootfs_theme_dir):
    """Иконки темы GRUB 48x48: кружок + буква, фиолетовая палитра.
    Временные, пока нет рисованного набора."""
    icons = {
        "xros": ("Xr", ACCENT), "linux": ("Xr", ACCENT),
        "windows": ("W", WINDOWS_BLUE), "efi": ("E", ACCENT_LIGHT),
        "memtest": ("M", GREY), "reboot": ("R", ACCENT_LIGHT),
        "shutdown": ("S", RED),
    }
    f = ImageFont.truetype(FONT_BOLD, 20)
    f2 = ImageFont.truetype(FONT_BOLD, 16)
    for name, (letter, col) in icons.items():
        im = Image.new("RGBA", (48, 48), (0, 0, 0, 0))
        dd = ImageDraw.Draw(im)
        dd.ellipse([2, 2, 46, 46], fill=col + (255,))
        ff = f if len(letter) == 1 else f2
        dd.text((24, 24), letter, font=ff, fill=WHITE + (255,),
                anchor="mm")
        im.save(os.path.join(theme_dir, f"{name}.png"))
        copy(os.path.join(theme_dir, f"{name}.png"),
             os.path.join(airootfs_theme_dir, f"{name}.png"))


def mean_lum(img, box):
    """Средняя яркость области — для проверки, что под меню не ярко."""
    region = img.crop(box).convert("L")
    px = list(region.getdata())
    return round(sum(px) / len(px), 1)


def main():
    logo_real = os.path.join(BRANDING, "xros-logo-real.png")
    wp_real = os.path.join(BRANDING, "wallpaper-real.png")

    # прозрачный логотип из реального файла (альфа уже есть,
    # чистится только пыль альфа < 5)
    logo_size, corners = transparent_logo(
        logo_real, os.path.join(BRANDING, "xros-logo.png"))
    print("xros-logo.png:", logo_size, "RGBA, углы (альфа):", corners)

    # обои БЕЗ надписи «XrOS» (инпейнтинг, исходник не трогается),
    # затем 1920x1080 (png + jpg)
    wp_clean = remove_text_wallpaper(wp_real)
    wp_size = wallpaper_1080(wp_clean,
                             os.path.join(BRANDING, "wallpaper.png"),
                             os.path.join(BRANDING, "wallpaper.jpg"))
    print("wallpaper.png/jpg (без надписи):", wp_size)

    # маленький прозрачный логотип для сайдбара установщика —
    # ТОЛЬКО из прозрачного xros-logo.png
    small_size, crop_box = logo_small(
        os.path.join(BRANDING, "xros-logo.png"),
        os.path.join(BRANDING, "xros-logo-small.png"))
    print("xros-logo-small.png:", small_size, "RGBA, кроп X:", crop_box)

    # фон GRUB — из очищенных от надписи обоев
    grub_bg(wp_clean,
            os.path.join(BRANDING, "grub-bg.png"),
            os.path.join(BRANDING, "grub-bg.jpg"))

    # баннер: канонический исходник — branding/banner.txt
    copy(os.path.join(BRANDING, "banner.txt"),
         os.path.join(AIROOTFS_XROS, "banner.txt"))
    copy(os.path.join(BRANDING, "banner.txt"),
         os.path.join(PKG_BRANDING, "banner.txt"))

    # копии в профиль и пакет (тот же набор стейджит и этап 2
    # scripts/build.sh; prepare() в PKGBUILD сверяет staged-копии
    # с branding/)
    for name in ("xros-logo.png", "xros-logo-small.png",
                 "wallpaper.png", "wallpaper.jpg",
                 "grub-bg.png", "grub-bg.jpg"):
        copy(os.path.join(BRANDING, name),
             os.path.join(AIROOTFS_XROS, name))
        copy(os.path.join(BRANDING, name),
             os.path.join(PKG_BRANDING, name))
    # фон GRUB — в тему и в сплэши загрузки
    for name in ("grub-bg.png", "grub-bg.jpg"):
        copy(os.path.join(BRANDING, name),
             os.path.join(GRUB_THEME, name))
        copy(os.path.join(BRANDING, name),
             os.path.join(AIROOTFS_GRUB_THEME, name))
    copy(os.path.join(BRANDING, "grub-bg.png"),
         os.path.join(ROOT, "profile/grub/splash.png"))
    copy(os.path.join(BRANDING, "grub-bg.jpg"),
         os.path.join(ROOT, "profile/grub/splash.jpg"))
    # фон GRUB рядом с grub.cfg: background_image в grub.cfg
    # ссылается на /boot/grub/grub-bg.jpg (путь от корня ISO, не
    # ${prefix}: префикс в live-GRUB — memdisk образа, а не ISO)
    copy(os.path.join(BRANDING, "grub-bg.jpg"),
         os.path.join(ROOT, "profile/grub/grub-bg.jpg"))

    # 9-слайс картинки для theme.txt: выбранный пункт — акцент,
    # терминал — тёмный бокс с границей
    nine_slice("select", GRUB_THEME, AIROOTFS_GRUB_THEME,
               fill=ACCENT, border=None)
    nine_slice("terminal_box", GRUB_THEME, AIROOTFS_GRUB_THEME,
               fill=PANEL, border=BORDER)
    print("select_*.png, terminal_box_*.png: 9 файлов каждый")

    grub_icons(GRUB_THEME, AIROOTFS_GRUB_THEME)

    # проверка: размеры и яркость под меню GRUB (зона меню: x 25-75%,
    # y 30-75% от 1024x768), а также шапка и полоса таймера
    gb = Image.open(os.path.join(BRANDING, "grub-bg.png")).convert("RGB")
    print("xros-logo-small.png:", small_size, "кроп X:", crop_box)
    print("wallpaper.jpg: 1920x1080, grub-bg: 1024x768")
    print("grub-bg яркость: меню",
          mean_lum(gb, (256, 230, 768, 576)),
          "| шапка", mean_lum(gb, (256, 0, 768, 115)),
          "| таймер", mean_lum(gb, (256, 614, 768, 691)))
    print("sha256 xros-logo.png:", sha256(os.path.join(BRANDING, "xros-logo.png"))[:16])
    print("sha256 wallpaper.png:", sha256(os.path.join(BRANDING, "wallpaper.png"))[:16])
    print("branding:", sorted(os.listdir(BRANDING)))


if __name__ == "__main__":
    main()
