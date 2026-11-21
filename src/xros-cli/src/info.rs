// Печать информации о XrOS: логотип из banner.txt и короткое описание.
// Печать информации о XrOS: логотип из banner.txt и короткое описание.

use std::fs;

pub fn print_info() {
    let banner = fs::read_to_string("/usr/share/xros/banner.txt")
        .unwrap_or_else(|_| "XrOS 1.0".to_string());
    println!("{banner}");
    println!();
    println!("XrOS 1.0 — система на базе Arch Linux");
    println!("Рабочий стол: KDE Plasma");
    println!("Загрузчик: GRUB");
    println!();
    println!("Справка: xros --help");
}
