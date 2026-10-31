# Sortierwerkzeug (SortingTool)

Eine Windows-Oberfläche, mit der du deine Sammlung per Knopfdruck aufräumst. Jede Funktion zeigt zuerst eine Vorschau im Stil einer Git-Änderungsansicht, erst nach „Ausführen“ wird etwas verschoben. Es wird nie eine Datei gelöscht. Jede Aktion schreibt ein Log und lässt sich mit „Aktion rückgängig machen“ zurücknehmen.

Die Spezifikation liegt im Repository unter `doc/` (Wurzel: `1 - Base.md`).

## Voraussetzungen

- Windows 10 (ab Version 1607) oder Windows 11. PowerShell 5.1 und Windows Forms sind dort schon vorhanden.
- Nichts zu installieren. Die Datenbank nutzt die SQLite-Engine, die in Windows eingebaut ist (`winsqlite3.dll`).
- Optional für „Ort bestimmen (Claude)“ und „Bilder kategorisieren (Claude)“: Claude Code, einmal mit deinem Claude-Konto angemeldet (in der Eingabeaufforderung `claude` starten und anmelden). Es wird nur dein Abo genutzt, nie ein API-Schlüssel.
- Optional für „Ort bestimmen (OpenStreetMap)“: Internetverbindung.

## Einrichten

1. Den Ordner `SortingTool` komplett auf die externe Platte kopieren.
2. Doppelklick auf `Start.cmd`. Beim ersten Start legt das Programm die Ordner `Input`, `Result` und `ToDelete` neben `System` an.
3. Optional: `System/Code/Tests/SelfTest.cmd` starten. Der Selbsttest prüft Datenbank, Verschieben, Doubletten, Vorschau und Rückgängig in einem eigenen temporären Ordner und zeigt PASS oder FAIL je Prüfung.

```
SortingTool/
├─ Start.cmd
├─ Input/      Eingang
├─ Result/     Ergebnis
├─ ToDelete/   Aussortiertes zum späteren Löschen (Doublets, Memes)
└─ System/
   ├─ Code/      Main.ps1, Common.ps1 (+ Common/), Explorer.ps1, Database/, Images/, Api/, Tests/
   ├─ Config/    layout.json, settings.json, Categories/*.json
   ├─ Logs/      eine Logdatei pro Aktion
   ├─ Database/  index.db
   ├─ Lib/       (leer, siehe doc/BuildAssumptions.md A-03)
   └─ Temp/      kurzlebige Kopien für Claude
```

## Erste Schritte

1. Fertige Sammlung nach `Result` legen und **Result initialisieren** klicken. Das liest alle Dateien einmal ein (Hashes, Aufnahmedatum, GPS).
2. Neue Dateien nach `Input` legen und **Input initialisieren** klicken. Danach sortiert die Kette sofort exakte Doubletten nach `ToDelete/Doublets` aus (mit Verknüpfungen zum Original).
3. Bilder: **Nach Aufnahmedatum gruppieren** → **Ort bestimmen (OpenStreetMap)** → bei Bedarf **Ort bestimmen (Claude)**.
4. Andere Bilder: **Bilder kategorisieren (Claude)** sortiert in `Input` vor (Rezepte, Screenshots, Memes, Sonstiges), **Kategorien verschieben** bringt die Ordner nach `Result` bzw. `ToDelete`.
5. Fertiges mit **Nach Result verschieben** an die gewünschte Stelle in `Result` bringen.
6. **Datenbank bereinigen** entfernt Einträge zu Dateien, die es nicht mehr gibt.

Im Explorer (Mitte) kannst du mit F2 umbenennen und per Ziehen und Ablegen verschieben. Das geht sofort, wird aber ebenfalls geloggt und ist rückgängig machbar.

## Einstellungen

`System/Config/settings.json`, unter anderem `minImagesPerDay`, `resultTargetDepth`, `thumbnailSize`, `imageExtensions`, `videoExtensions`, Abschnitte `places`, `categories` und `api` (`api.claude`, `api.nominatim`). Neue Buttons entstehen über `System/Config/layout.json`, neue Bildkategorien über eine weitere Datei in `System/Config/Categories/`.
