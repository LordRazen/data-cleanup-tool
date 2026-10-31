# Offene Fragen und Kritikpunkte (Stand 2026-10-31)

Diese Punkte haben den Bau nicht aufgehalten. Sie sind für die nächste Runde gesammelt. Die getroffenen Annahmen stehen in `BuildAssumptions.md`.

## Bitte zuerst prüfen

1. **Noch nie unter Windows gelaufen.** Gebaut ohne PowerShell-Laufzeit (siehe A-08). Bitte beim ersten Mal `SortingTool/System/Code/Tests/SelfTest.cmd` starten und die FAIL-Zeilen bzw. Fehlermeldungen zurückmelden. Danach `Start.cmd` mit einer kleinen Testsammlung ausprobieren, nicht gleich mit der echten Platte.
2. **SQLite aus Windows statt Zusatz-DLL** (A-03). Bitte bestätigen, dass das so in Ordnung ist. Falls `winsqlite3.dll` auf einem Rechner fehlt (sehr alte Windows-10-Version), startet das Programm nicht.

## Bitte bestätigen (nach Vorschlag umgesetzt)

3. **2.8 offene Fragen 1 und 2:** Tagesordner werden übersprungen, Ordnernamen zählen nicht als Hinweis (A-41).
4. **2.9 offene Frage:** eigener Button „Kategorien verschieben“, keine Kette mit 2.8 (A-44).

## Kritikpunkte und Lücken

5. **Vorschau bei sehr vielen Änderungen:** Die Git-Vorschau ist eine normale Tabelle (DataGridView, nicht virtuell). Bei vielen tausend Zeilen kann das Öffnen und Aufklappen spürbar langsam werden. Abhilfe später: virtueller Modus.
6. **HEIC-Bilder** (iPhone) lassen sich nur lesen, wenn unter Windows die „HEIF-Bilderweiterungen“ installiert sind. Ohne sie fehlen Aufnahmedatum aus EXIF, GPS, dHash und Vorschaubild; das Datum kommt dann aus Windows oder dem Dateinamen.
7. **Abgelehnte Bilder in 2.8** werden beim nächsten Lauf erneut an Claude geschickt (A-39). Sollen sie markiert werden, damit sie nicht immer wieder Nutzung kosten?
8. **Claude Code ändert sich:** Die Kommandozeilen-Schalter und die Texte, an denen das Nutzungslimit erkannt wird (A-51, A-53), können sich mit neuen Versionen von Claude Code ändern. Bei Problemen zuerst dort nachsehen (`System/Code/Api/ClaudeEndpoint.ps1`).
9. **GPS aus Videos** wird nicht gelesen (A-31). Videos ohne Datum im Namen bekommen ihr Datum aus Windows bzw. dem Änderungsdatum.
10. **Ähnlichkeits-Hash ungenutzt:** dHash und `similarityThreshold` werden berechnet und gespeichert, aber noch von keiner Funktion verwendet (ähnliche, nicht identische Bilder). Das wäre eine eigene Funktion 2.x.
11. **Explorer und Ordnerkonflikte:** Zieht man im Explorer einen Ordner dorthin, wo schon ein gleichnamiger Ordner liegt, entsteht `Name_2` (A-45). „Nach Result verschieben“ (2.5) führt dagegen zusammen. Soll der Explorer ebenfalls zusammenführen?
12. **ToDelete im Explorer:** Der Explorer zeigt nur `Input` und `Result`. Was in `ToDelete` liegt (Doubletten, Memes), sieht man nur im Windows-Explorer. Soll `ToDelete` als dritter Bereich dazukommen?
13. **Konsolenfenster beim Start:** `Start.cmd` lässt kurz ein schwarzes Fenster aufblitzen (A-04). Eine Verknüpfung mit „Minimiert“ oder ein kleines VBS-Startskript würde das vermeiden.
