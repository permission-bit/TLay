use std::env;
use std::process::{Command, ExitCode};

const DEFAULT_APPS: &str = "Terminal,iTerm2";

fn usage() {
    println!(
        r#"terminal-layout 0.1

Ordnet macOS-Fenster mit der Bedienungshilfe in einem 2x2-Raster an.

BEFEHLE
  layout [--apps Terminal,iTerm2,Safari] [--margin 12]
      Ordnet die passenden Fenster in Bildschirm-Vierteln an.
  prompt
      Gibt eine kurze zsh-Prompt-Konfiguration aus.
  help

BEISPIELE
  terminal-layout layout
  terminal-layout layout --apps Terminal,iTerm2,Safari
  terminal-layout prompt >> ~/.zshrc

Hinweis: macOS muss Terminal-Layout unter
Systemeinstellungen > Datenschutz & Sicherheit > Bedienungshilfen erlauben."#
    );
}

fn run_osascript(script: &str) -> Result<String, String> {
    let output = Command::new("osascript")
        .args(["-e", script])
        .output()
        .map_err(|e| format!("osascript konnte nicht gestartet werden: {e}"))?;

    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
    } else {
        Err(String::from_utf8_lossy(&output.stderr).trim().to_owned())
    }
}

fn layout(apps: &str, margin: i32) -> Result<(), String> {
    let app_list = apps
        .split(',')
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .map(|name| format!("\"{}\"", name.replace('"', "\\\"")))
        .collect::<Vec<_>>()
        .join(", ");

    if app_list.is_empty() {
        return Err("--apps darf nicht leer sein".into());
    }

    let script = format!(
        r#"tell application "Finder"
set desktopBounds to bounds of window "Desktop"
end tell
set originX to item 1 of desktopBounds
set originY to item 2 of desktopBounds
set screenWidth to (item 3 of desktopBounds) - originX
set screenHeight to (item 4 of desktopBounds) - originY
use application "System Events"
set appNames to {{{app_list}}}
set marginSize to {margin}
set cellWidth to (screenWidth - (marginSize * 3)) div 2
set cellHeight to (screenHeight - (marginSize * 3)) div 2
set slots to {{{{originX + marginSize, originY + marginSize}}, {{originX + marginSize * 2 + cellWidth, originY + marginSize}}, {{originX + marginSize, originY + marginSize * 2 + cellHeight}}, {{originX + marginSize * 2 + cellWidth, originY + marginSize * 2 + cellHeight}}}}
set slotNumber to 1
set movedCount to 0
repeat with appName in appNames
    if exists process (contents of appName) then
        tell process (contents of appName)
            repeat with currentWindow in (every window whose subrole is "AXStandardWindow")
                if slotNumber > 4 then exit repeat
                set position of currentWindow to item slotNumber of slots
                set size of currentWindow to {{cellWidth, cellHeight}}
                set slotNumber to slotNumber + 1
                set movedCount to movedCount + 1
            end repeat
        end tell
    end if
    if slotNumber > 4 then exit repeat
end repeat
return movedCount as text"#
    );

    let moved = run_osascript(&script)?;
    println!("{moved} Fenster angeordnet.");
    if moved == "0" {
        println!(
            "Keine passenden Fenster gefunden. Aktiviere Bedienungshilfen und öffne ein Fenster."
        );
    }
    Ok(())
}

fn prompt() {
    println!(
        r#"# >>> terminal-layout prompt >>>
PROMPT='%F{{yellow}}❯%f '
RPROMPT='%F{{cyan}}%n@%m%f %F{{blue}}%1~%f'
# <<< terminal-layout prompt <<<"#
    );
}

fn main() -> ExitCode {
    let mut args = env::args().skip(1);
    let command = args.next().unwrap_or_else(|| "help".into());

    match command.as_str() {
        "help" | "--help" | "-h" => usage(),
        "prompt" => prompt(),
        "layout" => {
            let mut apps = DEFAULT_APPS.to_owned();
            let mut margin = 12_i32;
            while let Some(arg) = args.next() {
                match arg.as_str() {
                    "--apps" => apps = args.next().unwrap_or_default(),
                    "--margin" => margin = args.next().and_then(|v| v.parse().ok()).unwrap_or(12),
                    unknown => {
                        eprintln!("Unbekannte Option: {unknown}");
                        return ExitCode::from(2);
                    }
                }
            }
            if let Err(error) = layout(&apps, margin.max(0)) {
                eprintln!("Fehler: {error}");
                return ExitCode::from(1);
            }
        }
        unknown => {
            eprintln!("Unbekannter Befehl: {unknown}\n");
            usage();
            return ExitCode::from(2);
        }
    }
    ExitCode::SUCCESS
}
