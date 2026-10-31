# Terminal Layout · macOS

Automatische Fensterlayouts für Terminal, iTerm2 und weitere macOS-Apps – direkt aus der Menüleiste.

Native SwiftUI-App für macOS 13 oder neuer. Englisch ist die Standardsprache.
Die App enthält alle benötigten Ressourcen und benötigt weder Rust noch einen Account.

## Schnellstart

Voraussetzungen: macOS 13+ und Xcode Command Line Tools (`xcode-select --install`).
Nach dem Klonen des Repositorys im Projektordner ausführen:

```bash
bash build-app.sh
open "Terminal Layout.app"
```

Danach unter **Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen**
Terminal Layout freigeben. Für das Öffnen neuer Terminals kann zusätzlich eine
Automation-Freigabe erforderlich sein.

Das Repository enthält den Quellcode. Die App wird lokal gebaut; generierte Apps,
Build-Verzeichnisse und lokale Entwicklungsumgebungen werden nicht versioniert.

## Starten und bauen

Nach dem Build die **Terminal Layout.app** im Finder doppelklicken.

    bash build-app.sh
    open "Terminal Layout.app"

Der Build enthält Apple Silicon und Intel. Für einen schnelleren lokalen Build:

    ARCHITECTURES=arm64 bash build-app.sh

Die Xcode Command Line Tools werden benötigt. Alternativ das Projekt
**TerminalLayout.xcodeproj** in Xcode öffnen und das Scheme **TerminalLayout** starten.

## Bedienung

Beim ersten Start erscheint die Sprachauswahl. Verfügbar sind Englisch, Deutsch, Spanisch,
Französisch, Italienisch, Portugiesisch (Brasilien), Russisch, Hindi, Arabisch,
Chinesisch (vereinfacht), Japanisch und Koreanisch. Die Sprache lässt sich jederzeit oben
über das Globus-Menü ändern. Arabisch verwendet die Schreibrichtung von rechts nach links.

Die App speichert Sprache, App-Auswahl, Fensterabstand und Layout automatisch.
Drei Layouts stehen zur Wahl: vier Viertel, nebeneinander und ein großes Fenster.
Ab Version 0.3 läuft sie als **Menüleisten-App im Hintergrund** weiter, auch wenn du das
Einstellungsfenster schließt. Das Vier-Viertel-Symbol oben in der macOS-Menüleiste öffnet
Einstellungen, Pause-Schalter, „Jetzt anordnen“ und die Ordnerübersicht. Beenden geht über
„Terminal Layout beenden“ in diesem Menü.

Ab Version 0.4 gibt es dort **„4 neue Terminals öffnen“** und **„2 neue Terminals öffnen“**.
Sie öffnen Apple Terminal im 2×2-Raster beziehungsweise nebeneinander auf dem Bildschirm
mit dem Mauszeiger. Dock und Menüleiste bleiben frei. Die neuen Fenster bekommen größere
Schrift (mindestens vier Vergrößerungsschritte), kommen nach vorne und das erste Fenster
ist zum Schreiben aktiv. Der kurze linke zsh-Prompt wird vor dem Öffnen eingerichtet.
Die Auswahl stellt auch das laufende Layout auf vier Viertel beziehungsweise zwei Spalten um.
Die neuen Fenster haben bei der automatischen Anordnung Vorrang vor bereits offenen Fenstern.
Die Aktion funktioniert auch bei pausierter Automatik. macOS kann einmalig die Automation
von Terminal erlauben lassen; Fehler erscheinen im Menü und im Einstellungsfenster.

Nach einem Neubau: Terminal Layout über sein Menü beenden und die **Terminal Layout.app**
aus diesem Projektordner neu öffnen. Eine eventuell verwendete Kopie in „Programme“ ebenfalls
ersetzen. Falls macOS die Fenstersteuerung blockiert, die Bedienungshilfen-Freigabe für diese
App unter Datenschutz & Sicherheit aus- und wieder einschalten.

Wenn „Open Settings“ trotz aktivierter Freigabe immer wieder erscheint, kann nach dem
lokalen Ad-hoc-Neubau ein alter Berechtigungseintrag übrig sein. Terminal Layout vollständig
beenden, unter Datenschutz & Sicherheit → Bedienungshilfen den Eintrag „Terminal Layout“
mit **− entfernen** und mit **+ die neu gebaute App aus diesem Projektordner** hinzufügen.
Den Schalter aktivieren und genau diese App neu starten. Nur das Einstellungsfenster zu
schließen beendet die Hintergrund-App nicht. Die App muss dafür nicht erneut gebaut werden.

**Standard: Automatik an, vier Viertel, viermal ⌘+.** Öffne nach der Einrichtung ein neues
Terminalfenster: Es erhält automatisch ein Viertel seines Bildschirms, auch wenn erst ein
Fenster offen ist. Weitere Fenster belegen die nächsten Plätze. Die App erkennt Änderungen
etwa jede Sekunde und wartet bei gerade entstehenden Fenstern kurz nach.
Manuelles Verschieben wird bis zur nächsten Änderung an der Fensteranzahl oder am Layout
respektiert. Der Automatik-Schalter pausiert Anordnung und Schriftvergrößerung.

„Fenster anordnen“ oder ⌘↵ wendet das Layout einmalig an, auch im pausierten Modus.
Dock und Menüleiste bleiben frei. Zusätzliche Fenster
bleiben an ihrem Platz; minimierte Fenster und Vollbildfenster werden übersprungen.
Die Fensterverwaltung verwendet direkt die öffentliche macOS-Accessibility-Schnittstelle.

Erlaube **Terminal Layout** einmalig unter Systemeinstellungen → Datenschutz & Sicherheit →
Bedienungshilfen. Bei Rückkehr zur App wird die Berechtigung erneut geprüft.
Nach einem lokalen Neubau kann die Freigabe erneut nötig sein.

## Schrift, Hintergrundstart und Ordner

Die Schriftvergrößerung führt den **eigenen Befehl des Terminals für größere Schrift** aus.
Standardmäßig vier Schritte, einstellbar von null bis acht. Sie erfolgt erst, wenn das betreffende
Terminalfenster aktiv ist. Die App gibt dafür keine globalen Tastendrücke an andere Apps weiter.
Erfolgreiche Schritte werden pro Fenster lokal gespeichert, damit sie nach einem App-Neustart
nicht nochmals ausgeführt werden. Die Einstellung wirkt auf Terminal und iTerm2; andere
ausgewählte Apps werden nur angeordnet.

„Bei der Anmeldung öffnen“ verwendet SMAppService und ist standardmäßig aus.
Es wird nur durch deine Auswahl eingeschaltet. macOS kann eine Freigabe verlangen.
Ein lokaler Ad-hoc-Build ist noch kein signierter und notarisierter öffentlicher Release.

**„Terminals nach Arbeitsordner gruppieren“** sortiert die Fenster im normalen Layout nach
ihrem vollständigen lokalen Pfad und zeigt eine eigene, anklickbare Ordnerübersicht.
Die aktive Registerkarte wird berücksichtigt. Unbekannte Ordner bleiben als unbekannt sichtbar.
Lokale Shell-Pfade werden über die Terminal-Metadaten und öffentliche Prozess-APIs ermittelt;
es werden weder Terminalpuffer noch Befehlsverläufe gelesen. Gegebenenfalls fragt macOS
nach Zugriff auf Terminal/iTerm2 unter Datenschutz & Sicherheit → Automation.
Diese Erkennung läuft getrennt von der Anordnung, sodass ein Freigabedialog sie nicht aufhält.
Entfernte SSH-Pfade werden nicht ermittelt.

**F3 / Mission Control bleibt macOS vorbehalten.** macOS bietet Gruppierung nach Anwendung.
Diese App kann dort keine eigenen Pfadgruppen anlegen. „F3-Einstellungen“ öffnet die passenden
Systemeinstellungen; Pfadgruppen und gezieltes Fensterwechseln bietet die eigene Ordnerübersicht.
Siehe [Apple: Mission Control](https://support.apple.com/en-gb/guide/mac-help/mh35798/mac).

## Prompt und Zurücksetzen

„Prompt installieren“ richtet den kurzen zsh-Prompt ein: Eingabe links hinter ❯,
Benutzer/Rechner/Ordner rechts. Änderungen gelten in neuen Terminalfenstern.
Zsh-Konfigurationen mit exportiertem ZDOTDIR werden berücksichtigt.

**„Auf Werkseinstellungen zurücksetzen“** öffnet einen Bestätigungsdialog. Danach gelten
Englisch, erneute Sprachauswahl, Terminal und iTerm2, automatische vier Viertel, 12 pt Abstand
und vier Schriftvergrößerungen für neue Fenster. Ordnergruppierung und Anmeldestart werden
ausgeschaltet. Bestehende Fenster werden nicht kleiner geschrieben.
Der von uns installierte Prompt wird entfernt, auch die bekannten früheren CLI-Versionen.
Eigene Shell-Einstellungen und später ergänzte Inhalte bleiben erhalten.
Vor jeder Shell-Änderung wird eine private Sicherung angelegt. Fehlerhafte Prompt-Markierungen
brechen den Vorgang ab.

Die App setzt keine fremden Apps oder macOS-Berechtigungen zurück und löscht keine Sicherungen.
Fensterpositionen lassen sich separat über **„Positionen wiederherstellen“** zurückholen,
solange die App läuft und die Fenster noch existieren.
Dabei wird die Automatik pausiert.

Einstellungen und Shell-Sicherungen liegen unter
~/Library/Application Support/com.rastafari.terminallayout/.
Es gibt keine Telemetrie oder Netzwerkverbindungen.

Das lokale Journal window-zoom.json merkt sich ausgeführte Schriftvergrößerungen.
Es enthält Fensterkennungen und Schrittzahlen, keine Terminal-Inhalte.

## Prüfen

    bash test-app.sh

Prüft sicheren Prompt-Einbau/-Ausbau, alte Versionen, Symlinks, Dateirechte, Sicherungen,
Werkseinstellungen, Sprachpersistenz, Erststart, Fehlerbehandlung, Layout-Geometrie und
Vollständigkeit aller zwölf Übersetzungen. Tests verwenden ausschließlich temporäre Dateien.
Zusätzlich wird die Automatik mit einem simulierten Fensterzugriff geprüft: neue/geschlossene
Fenster, vier Schriftvergrößerungen, Pause, Wiederaufnahme, Neustart, fehlgeschlagene Aktionen,
begrenzte Wiederholungen, Pfadgruppen, Abbruch laufender Vorgänge und mehrere Bildschirme.
Das tatsächliche Verschieben fremder Fenster muss zusätzlich auf einem Mac mit erteilter
Berechtigung geprüft werden.

## Veröffentlichung

Ein Xcode-Projekt und ein universeller lokaler Build sind vorhanden.
**Diese Version ist noch nicht für den Mac App Store freigegeben:** Der freie Zugriff auf fremde
Fenster kollidiert mit Sandbox-Beschränkungen. Voraussetzungen, Quellen und verbleibende
Schritte sind in [docs/RELEASING.md](docs/RELEASING.md) beschrieben.
Eine App-Store-Zulassung wird nicht zugesagt.

Die alte Rust-CLI bleibt als eigenständiger Entwicklungshelfer erhalten:

    cargo build --release

Die SwiftUI-App verwendet die CLI nicht.

## Projektstruktur

| Pfad | Inhalt |
| --- | --- |
| `MacApp/` | SwiftUI-App, Fensterverwaltung und Übersetzungen |
| `Tests/` | Swift-Tests für Kernlogik, Einstellungen und Automatik |
| `Tools/` | Icon-Erstellung und Vorschau |
| `src/` | Optionale Rust-CLI |
| `docs/RELEASING.md` | Hinweise zur Veröffentlichung |

## Mitwirken

Fehlerberichte bitte mit macOS-Version, Prozessor (Apple Silicon/Intel),
Reproduktionsschritten und erwartetem Verhalten erstellen.
Bei Änderungen `bash test-app.sh` und `bash build-app.sh` ausführen;
für CLI-Änderungen zusätzlich `cargo test --locked`.
GitHub Actions prüft Swift-Tests, den universellen App-Build und die Rust-CLI.

## Lizenz

[MIT](LICENSE).
