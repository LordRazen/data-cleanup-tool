# Annahmen beim Bau (Stand 2026-10-31)

Razen war während des Baus nicht erreichbar. Wo die Spezifikation Spielraum ließ, habe ich eine Annahme getroffen und sie hier festgehalten. Jede Annahme lässt sich ändern. Offene Fragen und Kritikpunkte stehen getrennt in `OpenQuestions.md`.

## Aufbau und Technik

- **A-01 Ort im Repository:** Das Werkzeug liegt im Ordner `SortingTool/`. Dieser Ordner wird komplett auf die externe Platte kopiert. `Input`, `Result` und `ToDelete` legt das Programm beim ersten Start im Hauptordner an (wie im Ordnerbaum der Basis, Abschnitt 4) und sie sind per `.gitignore` vom Repository ausgeschlossen.
- **A-02 Common.ps1 aufgeteilt:** `Common.ps1` lädt thematische Teildateien aus `System/Code/Common/` (Pfade, Einstellungen, Datenbank, Log, Bildinfos, Dateioperationen, Plan, Rückgängig, Dialoge, Vorschau). Inhaltlich ist alles weiterhin „Common.ps1“, nur lesbarer.
- **A-03 SQLite ohne Zusatz-DLL:** Statt `System.Data.SQLite.dll` in `System/Lib` nutze ich die SQLite-Engine, die in Windows 10 (ab 1607) und Windows 11 eingebaut ist (`winsqlite3.dll`), über einen kleinen C#-Wrapper, der beim Start mit `Add-Type` übersetzt wird. Grund: nichts herunterladen, keine 32/64-Bit-Fallen mit `SQLite.Interop.dll`, Grundsatz „nichts zu installieren“ bleibt erfüllt. `System/Lib` bleibt vorerst leer.
- **A-04 Start ohne Konsole:** `Start.cmd` startet PowerShell mit `-WindowStyle Hidden`. Ein Konsolenfenster blitzt dabei kurz auf, bleibt aber nicht stehen.
- **A-05 Feste Buttons in layout.json:** Unter dem Schlüssel `fixedButtons` (gleicher Aufbau wie Gruppenbuttons). „Aktion rückgängig machen“ hat `"special": "Undo"`. Skripte der festen Buttons liegen in `System/Code/Database/`.
- **A-06 Schnittstelle der Funktionsskripte:** Jedes Skript hat `param($Context, [hashtable]$Arguments)`. Es gibt entweder einen Plan zurück (Vorschau, dann Ausführen) oder ein Ergebnis `Done`, `Message`, `Cancelled` oder `Failed`. `Cancelled` und `Failed` stoppen die Kette.
- **A-07 Encoding:** Alle `.ps1`-Dateien sind UTF-8 mit BOM, sonst zeigt PowerShell 5.1 Umlaute falsch an. Logs werden als UTF-8 mit BOM geschrieben.
- **A-08 Nicht unter Windows getestet:** Gebaut in einer Linux-Umgebung ohne PowerShell. Der Code ist sorgfältig geprüft, aber noch nie gelaufen. Der Selbsttest `System/Code/Tests/SelfTest.cmd` ist für den ersten Lauf unter Windows gedacht.

## Vorschau

- **A-10 Ausschnitt statt ganzer Baum:** Die Vorschau zeigt nur den Inhalt der Ordner, in denen sich etwas ändert, plus die Hauptordner der Funktion. So bleibt sie auch bei großem `Result` schnell. Sehr große Ordner zeigen höchstens 3000 Einträge als Zusammenhang.
- **A-11 Ordner einzeln einklappen:** per Doppelklick auf die Ordnerzeile.
- **A-12 Umbenannte Ordner** (2.6, 2.7, Explorer) erscheinen als je eine Zeile links (rot) und rechts (grün), ihr Inhalt wird nicht einzeln aufgelistet.
- **A-13 Leere Ordner in Input:** Das Hauptprogramm ergänzt nur Ordner, die *durch den Plan* leer werden (Herkunftsordner verschobener Dateien und deren Eltern), nicht schon vorher leere, unbeteiligte Ordner. Sie erscheinen als rote Zeile mit Häkchen und können abgewählt werden.
- **A-14 Neue Ordner ohne eigenes Häkchen:** Ein neuer Ordner ist grün, wenn mindestens eine angehakte Datei hineinkommt. Sein Häkchen schaltet alle Änderungen darin.
- **A-15 Dateianzahl** steht bei neuen Ordnern direkt im Namen, z. B. `2024-07-13 (12 Dateien)`.

## Log und Rückgängig

- **A-20 Vierte Spalte:** Logzeilen haben bei Bedarf eine vierte, tabulatorgetrennte Spalte mit Zusatzinfo (Grund bei `REJECTED`, Ziel einer Verknüpfung, Aufnahmedatum bei 2.3, ganze Datenbankzeile als JSON bei `ENTRY_REMOVED`).
- **A-21 Zusätzliche Schrittarten:** `ENTRY_PATH_UPDATED` (2.1, außerhalb verschobene Datei erkannt, nur Info), `ENTRY_RESTORED` (Rückgängig von 2.4).
- **A-22 Initialisieren-Logs** vermerken entfernte Zeilen als `ENTRY_REMOVED`, werden aber nicht in der Rückgängig-Liste angeboten (2.1 Abschnitt 6).
- **A-23 Rückgängig entfernt angelegte Ordner überall**, nicht nur in `Result`, wenn sie nach dem Zurückverschieben leer sind. Ist ein solcher Ordner nicht leer, bleibt er und wird als `REJECTED` geloggt.
- **A-24 Rückgängig-Liste** sortiert nach Schreibzeit der Logdatei, die neueste oben. Zwei Logs in derselben Sekunde bekommen `(2)` im Namen.
- **A-25 API-Aufrufe** werden am Anfang des Logs der Funktion geschrieben. Wird die Vorschau abgebrochen, entsteht kein Log (also auch keine `API_CALL`-Zeilen).

## Funktionen

- **A-30 (2.1) Abbrechen** von „Input initialisieren“ stoppt die Kette, `FindDuplicates` läuft dann nicht. Die Bereinigung fehlender Einträge läuft nur bei vollständigem Durchlauf.
- **A-31 (2.1) GPS aus Videos** wird nicht gelesen, nur aus Bildern (EXIF über System.Drawing).
- **A-32 (2.1) Windows-Eigenschaft „Aufnahmedatum“** liefert die Shell als UTC, sie wird in Ortszeit umgerechnet.
- **A-33 (2.2)** Nur noch nicht geprüfte Dateien können Doubletten werden. Das Original wird unter allen Treffern bestimmt; bei mehreren Treffern in `Result` gilt der alphabetisch erste Pfad.
- **A-34 (2.3)** Das Hand-Symbol entsteht nur durch Klick auf das Ordner-Häkchen, nicht durch einzelne Dateien.
- **A-35 (2.5)** Der Pfad unterhalb von `Input` bleibt im Ziel erhalten. Damit gelten alle drei Regeln aus 2.5 Abschnitt 5 (Datei direkt, Ordner mit Inhalt, teilweise angehakter Ordner). „Neuer Ordner …“ legt den Ordner unter dem gerade gewählten Ziel an.
- **A-36 (2.6)** Dateien, deren Koordinate wegen `maxLookupsPerFolder` nicht abgefragt wurde, zählen zum Ort der nächstgelegenen abgefragten Koordinate. Der Anteil für den zweiten Ort bezieht sich auf die Dateien mit GPS.
- **A-37 (2.7)** Bilder gehen als verkleinerte JPEG-Kopien ohne Metadaten an Claude (wie in 2.8), unter neutralen Dateinamen. Kann Claude keinen Ort nennen, steht „Unbekannter Ort“ im Namensfeld und die Zeile ist nicht angehakt.
- **A-38 (2.8) Kategorie und Unterordner in einem Dropdown**, z. B. „Rezepte › Backen“, statt zwei getrennter Dropdowns.
- **A-39 (2.8) `CategorySetHash`** wird nur für tatsächlich verschobene Bilder gespeichert (und für Bilder, die schon in `Input/Sonstiges` liegen und Default bleiben). Abgelehnte Bilder werden beim nächsten Lauf erneut an Claude geschickt.
- **A-40 (2.8)** Bilder ohne Claude-Antwort und ohne Voreinschätzung erscheinen nicht in der Vorschau und kommen beim nächsten Lauf wieder dran. Über `maxCallsPerRun` hinaus gibt es nur die Voreinschätzung, die Statuszeile nennt die Anzahl der übrigen Bilder.
- **A-41 (2.8) Offene Fragen nach Vorschlag umgesetzt:** Tagesordner (`YYYY-MM-DD…`) werden übersprungen. Ordnernamen zählen nicht als Hinweis.
- **A-42 (2.8.3)** Der Hinweis „Bildgröße passt zu einem Bildschirm“ wird nur angezeigt, er beeinflusst die Kategorie nicht.
- **A-43 (2.8) `genericNamePatterns`:** Standardliste mit Ziffernmustern (`IMG_[0-9]*`, `DSC[0-9]*`, `PXL_[0-9]*`, `*-WA[0-9]*` …), damit z. B. `IMG_Rezept.jpg` nicht als generisch gilt.
- **A-44 (2.9) Offene Frage nach Vorschlag umgesetzt:** eigener Button, keine Kette mit 2.8.
- **A-45 Explorer:** Liegt am Ablageort schon ein *Ordner* gleichen Namens, bekommt der ankommende Ordner `_2` (die Basis regelt nur Dateien). Die Listenansicht zeigt höchstens 20.000 Dateien.

## Claude (3.1)

- **A-50 Anmeldeprüfung erst bei Bedarf:** Beim Programmstart wird nur geprüft, ob Claude Code installiert und eingeschaltet ist (sonst Button grau mit Grund). Die kleine Testabfrage „angemeldet?“ läuft erst, wenn eine Claude-Funktion startet, weil sie Zeit und etwas Nutzung kostet. Schlägt sie fehl, bleibt der Button für diese Sitzung grau.
- **A-51 Aufruf:** `claude -p --output-format json --max-turns 8 --allowedTools Read --disallowedTools Bash,Edit,MultiEdit,Write,NotebookEdit,WebFetch,WebSearch,Task,TodoWrite`, die Frage geht über die Standardeingabe (UTF-8). Dateien werden als `st_01.jpg` usw. in `System/Temp/Claude` kopiert und danach wieder entfernt.
- **A-52 Abo-Garantie:** Neben `ANTHROPIC_API_KEY` wird auch `ANTHROPIC_AUTH_TOKEN` für den gestarteten Prozess entfernt.
- **A-53 Nutzungslimit** wird am Text der Antwort erkannt („usage limit“, „limit reached“ …). Die Uhrzeit kommt aus `…|<Unix-Zeit>` oder „resets 3pm“. Ohne Uhrzeit wird alle `limitRetryMinutes` mit einer Mini-Abfrage geprüft.
