// Печать информации о XrOS: логотип из banner.txt и короткое описание.

use std::collections::HashMap;
use std::fs;

fn installed_metadata() -> HashMap<String, String> {
    let mut metadata = HashMap::new();
    for path in ["/etc/os-release"] {
        let Ok(contents) = fs::read_to_string(path) else { continue };
        for line in contents.lines() {
            let Some((key, value)) = line.split_once('=') else { continue };
            metadata.insert(key.to_string(), value.trim_matches('"').to_string());
        }
    }
    metadata
}

pub fn print_info() {
    let banner = fs::read_to_string("/usr/share/xros/banner.txt")
        .unwrap_or_else(|_| "XrOS".to_string());
    let metadata = installed_metadata();
    let name = metadata.get("PRETTY_NAME").map(String::as_str).unwrap_or("XrOS");
    let desktop = metadata.get("XROS_DESKTOP").map(String::as_str).unwrap_or("не указан");
    let bootloader = metadata.get("XROS_BOOTLOADER").map(String::as_str).unwrap_or("не указан");
    println!("{banner}");
    println!();
    println!("{name} — система на базе Arch Linux");
    println!("Рабочий стол: {desktop}");
    println!("Загрузчик: {bootloader}");
    println!();
    println!("Справка: xros --help");
}
