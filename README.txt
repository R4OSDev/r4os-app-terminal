TERMINAL.R4X
============

TERMINAL.R4X ist R4OS' DOS-artige Terminal-/Shell-Anwendung. Sie laeuft als
normales R4X-Programm im Userland und ist sowohl fuer Terminal Window als auch
fuer Terminal Mode der produktive Shell-Pfad.

Stand 0.59.12:
- Projektstruktur seit 0.51.20:
  `build.zig` baut TERMINAL.R4X als eigenes SDK-Projekt,
  `build.zig.zon` bindet `r4os_sdk`, und `module.R4MF` beschreibt Artefakt,
  Zielpfad, die R4STD-DATE_V1-/TIME_V1-Imports und den R4XStart-Contract.
- TERMINAL.R4X besitzt den produktiven Userland-Hauptloop fuer die Shell.
- TERMINAL.R4X liest Tastaturereignisse ueber R4SYS, normalisiert sichtbare
  Eingabe, verwaltet History, Prompt, Environment, PATH, SHELL und ERRORLEVEL
  selbst.
- TERMINAL.R4X liest keine COMMAND.R4S, TERMINAL.R4S oder Designwerte aus
  CONFIG.R4S oder DESKTOP.R4S.
- Feste Terminal-Defaults liegen im Terminal-Code. Eine Terminal-Settings-App
  oder Terminal-Design-Konfigurationsdatei gibt es nicht.
- Der feste Default-`PATH` enthaelt nur die produktiven Terminal-Verzeichnisse
  `C:\R4OS\SOFTWARE\TERMINAL` und `C:\R4OS\SOFTWARE\TERMINAL\DIAG`.
  Alte BIN-Fallbacks gibt es nicht mehr.
- `TERMINAL.R4X /NOAUTOEXEC` startet eine interaktive Sitzung ohne
  `C:\AUTOEXEC.BAT`; Desktop nutzt das fuer Desktop-gehostete Terminal Windows,
  damit neue Fenster keine Boot-Skripte erneut ausfuehren. SSHD nutzt denselben
  Pfad fuer headless Remote-Shells.
- `TERMINAL.R4X /C <Befehl>` startet keine interaktive Sitzung, sondern
  fuehrt genau eine Befehlszeile aus und gibt deren ERRORLEVEL als
  Programm-Exitcode zurueck. In Kombination mit `/NOAUTOEXEC` nutzt SSHD
  diesen Pfad fuer nicht-interaktive SSH-Exec-Requests.
- Einfache Built-ins, externe Programmstarts, einfache Batch-Dateien und
  grundlegende Redirection laufen ohne produktive Kernel-Executor-Bruecke.
- Laufwerkswechsel wie `D:` sowie `CD`/`CHDIR` laufen ueber den
  validierten Terminal-CWD: Nicht vorhandene Laufwerke oder Verzeichnisse
  aendern den Prompt nicht.
- `DESKTOP` ist ein interner Host-Befehl fuer Terminal Mode. Im Terminal Window
  und ohne Desktop-Host bleibt er wirkungslos und meldet den falschen Kontext.
- `EXIT` beendet die aktuelle Terminal-Sitzung. Das ist fuer normale Shells
  unspektakulaer, fuer SSH-gehostete Sitzungen aber der saubere
  Sitzungsabschluss.
- Nicht migrierte Batch-/Stream-Funktionen werden sichtbar als nicht migriert
  gemeldet, statt still in eine alte Kernel-Runtime zurueckzufallen.
- `TERMINAL.R4X /SELFTEST`, `/BUILTINTEST`, `/LAUNCHTEST` und `/BATCHTEST`
  bilden die automatische Terminal-Abnahme.
- Externe GUI-Module mit einem reinen Konsolenmodus koennen `/CONSOLE` als
  expliziten Launch-Hinweis erhalten. Die etablierten Utility-Schalter
  `/EXPORT` und `/RDPTRACE` werden kompatibel ebenfalls mit Console-Policy
  gestartet; die Ausnahme fuer Serviceprogramme bleibt auf `/SELFTEST`
  beschraenkt.
- `TERMINAL.R4X /?` zeigt die knappe Hilfe.

Seit 0.49.2 startet der Kernel-Bootpfad TERMINAL.R4X aus
`C:\R4OS\SOFTWARE\TERMINAL\`. Seit 0.49.3 ist auch das Quellprojekt nach
`Code/Software/Terminal` umgezogen. Seit 0.49.4 trennt der Desktop zwischen
Terminal Window und Terminal Mode und kann mehrere Terminal-Windows parallel
hosten. Seit 0.49.5 heissen die Hostkennungen `terminal_window` und
`terminal_mode`. Seit 0.49.6 ist festgeschrieben, dass es keine produktive
Terminal-Settingsdatei gibt: weder COMMAND.R4S noch TERMINAL.R4S, und keine
Terminal-Designwerte aus CONFIG.R4S. Terminal bleibt dadurch eine
austauschbare Userland-Anwendung; neue Shell-Logik gehoert nicht in den Kernel.
Seit 0.49.20 sind auch die Terminal-Default-Suchpfade und Terminal-Smokes hart
auf `C:\R4OS\SOFTWARE\TERMINAL\` und dessen `DIAG`-Unterordner gelegt.
Seit 0.52.6 kann Terminal als Shell-Gast in einer SSHD-Remote-Console laufen;
SSHD liefert dabei Eingabe, Ausgabe und Fenstermaße ueber die Console-Host-
APIs, ohne einen zweiten Shell-Interpreter einzufuehren.
Seit 0.52.7 kann Terminal mit `/C` denselben Userland-Shellpfad fuer einzelne
SSH-Remote-Kommandos verwenden; SSHD muss dafuer keinen eigenen
Befehlsinterpreter enthalten.
Seit 0.59.12 bleibt die Ausgabe von GUI-klassifizierten Exportwerkzeugen mit
`/CONSOLE` ownergebunden in der aufrufenden Terminal- oder SSH-Sitzung.

Einzelbuild:

    cd Code\System\Software\Terminal
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Software\Terminal\zig-out\TERMINAL.R4X
