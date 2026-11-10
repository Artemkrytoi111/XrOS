// Команда `xros`: коротко о системе и быстрые действия.
// `xros` — показать информацию; `xros info` — то же без лишнего;
// `xros update` / `xros upgrade` — обновление пакетов (нужен root/sudo).

mod info;

use std::process::Command;

fn print_help() {
    println!("xros — команда XrOS");
    println!();
    println!("Использование:");
    println!("  xros            показать информацию о системе");
    println!("  xros info       то же самое, без открытия чего-либо");
    println!("  xros update     обновить списки пакетов (нужен root)");
    println!("  xros upgrade    обновить систему (нужен root)");
    println!("  xros --help     эта справка");
    println!("  xros --version  версия");
}

fn need_root() -> bool {
    // обновление пакетов требует root; честно просим sudo, а не падаем молча
    unsafe { libc::getuid() != 0 }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(|s| s.as_str()).unwrap_or("");
    match cmd {
        "" => info::print_info(),
        "info" => info::print_info(),
        "--help" | "-h" | "help" => print_help(),
        "--version" | "-V" => println!("xros 1.0.0"),
        "update" | "upgrade" => {
            if need_root() {
                eprintln!("Нужны права root: запустите через sudo (sudo xros {cmd})");
                std::process::exit(1);
            }
            let pacman_args = if cmd == "update" {
                vec!["-Sy"]
            } else {
                vec!["-Su"]
            };
            let status = Command::new("pacman").args(&pacman_args).status();
            match status {
                Ok(s) => std::process::exit(s.code().unwrap_or(1)),
                Err(e) => {
                    eprintln!("не удалось запустить pacman: {e}");
                    std::process::exit(1);
                }
            }
        }
        other => {
            eprintln!("неизвестная команда: {other}");
            print_help();
            std::process::exit(1);
        }
    }
}
