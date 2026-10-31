# Basisspezifikation Sortierwerkzeug (v0.24)

## 1. Zweck
- Eine einfache Windows-Oberfläche, über die du Aufräumarbeiten an deiner Sammlung per Knopfdruck startest.
- Diese Basis beschreibt nur Oberfläche, Speicherung der Struktur, Ausführung und Ordner. Was die einzelnen Buttons fachlich tun, kommt später.

## 2. Grundregeln
- **Code-Ebene englisch, sichtbare Oberfläche deutsch (bestätigt).** Ordner, Dateien, Skripte, Funktionen, Variablen, Tabellen, Spalten, Konfigurationsschlüssel und Logdateien sind englisch. Alle sichtbaren Texte der Oberfläche (Buttons, Gruppen, Tooltips, Meldungen, Vorschau) sind deutsch. Diese Spezifikation bleibt deutsch.
- **Nie Dateien löschen, nur verschieben.** Kein Skript löscht jemals eine Datei.
- Daraus folgt: Eine vorhandene Datei wird beim Verschieben nie überschrieben.
- **Namenskonflikt:** Liegt am Ziel schon eine Datei mit gleichem Namen, wird die ankommende Datei trotzdem verschoben und bekommt eine laufende Nummer mit Unterstrich vor der Endung: `Image.jpg` wird zu `Image_2.jpg`, dann `Image_3.jpg` usw. Grund: Doubletten werden vorher aussortiert, gleiche Namen sind also verschiedene Dateien. In der Vorschau steht der neue Name als grüne Zeile.
- **Ausnahmen für leere Ordner:** Leere Ordner in `Input` dürfen entfernt werden. Beim Rückgängigmachen darf außerdem ein Ordner in `Result` entfernt werden, den die ursprüngliche Aktion angelegt hat und der dadurch leer wird. Beides erscheint vorher als Änderung in der Vorschau.
- **Erst Vorschau, dann ausführen.** Jede Funktion zeigt zuerst, was sie tun würde. Erst nach deiner Bestätigung wird etwas verändert.
- **Einzige Ausnahme von der Vorschau:** Umbenennen und Verschieben von Hand im Datei-Explorer (Abschnitt 11). Das machst du bewusst selbst, es wird sofort ausgeführt, aber trotzdem geloggt und ist rückgängig machbar.

## 3. Technik (bestätigt)
- **Sprache: PowerShell 5.1.** Ist auf jedem Windows vorinstalliert, also nichts zu installieren.
- **Oberfläche: Windows Forms**, direkt aus PowerShell. Kein Webserver, kein Browser, keine Zusatzsoftware.
- **Start:** Doppelklick auf `Start.cmd` im Hauptordner, das startet das Programm ohne Konsolenfenster.
- **Struktur-Datei: JSON.** PowerShell liest JSON mit einem Befehl ein, und die Datei ist für Menschen leicht zu lesen und zu ändern.
- **SQLite:** PowerShell kann SQLite nicht von Haus aus. Dafür kommt eine einzelne Bibliotheksdatei (`System.Data.SQLite.dll`) nach `System/Lib`. Keine Installation nötig.

## 4. Ordnerstruktur der Anwendung
- Hauptordner des Werkzeugs: `SortingTool` (bestätigt).
- Ordnernamen ohne Nummern: `Input`, `Result`, `ToDelete`, `System`.
- `ToDelete` sammelt alles, was du später selbst löschen willst, je Art in einem Unterordner, z. B. `ToDelete/Doublets` (2.2) und `ToDelete/Memes` (2.8.2) (Razen, 2026-10-30). Das Werkzeug löscht auch dort nie etwas.
- Werkzeug, Input und Result liegen direkt nebeneinander auf der externen Platte.
- Das Programm findet die Ordner über seinen eigenen Speicherort. Ein anderer Laufwerksbuchstabe stört also nicht.
```
SortingTool/
├─ Start.cmd
├─ Input/      Eingang: hier legst du Dateien und Ordner zur Bearbeitung ab
├─ Result/     Ergebnis: hierhin verschieben die Funktionen die bearbeiteten Dateien
├─ ToDelete/   Aussortiertes zum späteren Löschen (Doublets, Memes, …)
└─ System/
   ├─ Code/
   │  ├─ Main.ps1           Hauptprogramm
   │  ├─ Common.ps1         gemeinsame Hilfsfunktionen (Verschieben, Umbenennen, Log, Datenbank, Rückgängig)
   │  ├─ Explorer.ps1       Datei-Explorer im Hauptfenster (Abschnitt 11)
   │  ├─ Images/            ein Ordner pro Gruppe ...
   │  │  └─ FindDuplicates.ps1   ... darin ein Skript pro Funktion
   │  ├─ Documents/
   │  └─ Songs/
   ├─ Config/         layout.json (Gruppen und Buttons), settings.json (Einstellungen)
   ├─ Logs/           eine Logdatei pro Aktion
   ├─ Database/       index.db (SQLite)
   └─ Lib/            Zusatzbibliotheken (SQLite-DLL)
```

## 5. Oberfläche
- Ein einzelnes Fenster, von oben nach unten aufgeteilt:
  1. **Oben: Leiste mit den Gruppen** und ihren Buttons.
  2. **Mitte: Datei-Explorer**, links `Input`, rechts `Result` (Abschnitt 11). Er nimmt den meisten Platz ein.
  3. **Darunter: feste Button-Reihe** (bleibt unten, bestätigt).
  4. **Ganz unten: Statusbereich**, der live anzeigt, was gerade passiert.
- Die Gruppen erscheinen als beschriftete Rahmen. Für den Anfang: **Bilder**, **Dokumente**, **Songs** (bestätigt). Intern heißen sie `Images`, `Documents`, `Songs`.
- In jedem Rahmen stehen die Buttons dieser Gruppe untereinander.
- Außerhalb der Gruppen, als feste Button-Reihe unten über dem Statusbereich (bestätigt): Buttons **Result initialisieren** und **Input initialisieren** (siehe Abschnitt 10) sowie **Aktion rückgängig machen** (siehe Abschnitt 9).
- Der Statusbereich zeigt auf Deutsch, was gerade passiert. Die Logdatei enthält dieselben Schritte in englischer Form.
- Während eine Funktion läuft, sind alle Buttons gesperrt und im Explorer kann nichts umbenannt oder verschoben werden, damit nie zwei Aufgaben gleichzeitig laufen.
- Fährt man mit der Maus über einen Button, erscheint eine kurze Beschreibung.

### Vorschaufenster (im Stil einer Git-Änderungsansicht)
- Öffnet sich nach jedem Klick auf einen Button, bevor irgendetwas passiert.
- Zwei Spalten nebeneinander, wie bei einem Code-Vergleich in Git:
  - **Links: Vorher.** Der aktuelle Ordnerinhalt als eingerückte Textliste, ein Ordner oder eine Datei pro Zeile.
  - **Rechts: Nachher.** Derselbe Inhalt so, wie er nach der Aktion aussehen würde.
- **Farben der Zeilen:**
  - **Rot** hinterlegt: verschwindet an dieser Stelle (Datei zieht weg, alter Name bei Umbenennung, leerer Ordner wird entfernt).
  - **Grün** hinterlegt: kommt an dieser Stelle neu hinzu (Datei kommt an, neuer Name, neuer Ordner).
  - **Weiß**: keine Änderung.
- Eine Umbenennung erscheint also links als rote Zeile mit dem alten Namen und rechts als grüne Zeile mit dem neuen Namen.
- **Gleiche Höhe:** Beide Seiten scrollen immer gemeinsam, und dasselbe Element steht links und rechts auf gleicher Höhe. Gibt es eine Zeile nur auf einer Seite, bleibt auf der anderen Seite an dieser Höhe eine leere Zeile.
- Technisch ist die Vorschau eine Tabelle mit zwei Spalten statt zwei getrennter Listen. Dadurch ist die gleiche Höhe immer garantiert.
- **Unveränderte Bereiche einklappen:** Mehrere weiße Zeilen am Stück werden zu einer einzigen Sammelzeile zusammengefasst, z. B. „▸ 37 unveränderte Einträge“. Ein Klick darauf klappt sie aus, ein weiterer klappt sie wieder ein. Beide Seiten klappen gemeinsam.
- Direkt über und unter jeder Änderung bleiben 2 weiße Zeilen als Zusammenhang sichtbar, damit man sieht, wo die Änderung steht (wie bei Git).
- Standardmäßig ist alles Unveränderte eingeklappt. Oben gibt es einen Umschalter **Alles ausklappen / Unverändertes einklappen**.
- Ordner kann man außerdem einzeln auf- und zuklappen.
- Klickt man eine Zeile an, wird ihr Gegenstück auf der anderen Seite mit markiert, auch wenn es an anderer Stelle steht.
- **Häkchen pro Änderung:** Jede rote oder grüne Zeile hat eine Checkbox. Standardmäßig sind alle angehakt.
- Nimmst du das Häkchen weg, wird diese Änderung abgelehnt: Die Datei bleibt, wo sie ist, und die Zeilen werden weiß.
- Ein Häkchen an einem Ordner schaltet alle Änderungen darin auf einmal an oder aus.
- Ein neuer Ordner wird nur angelegt, wenn mindestens eine angehakte Datei hineinkommt.
- Zusätzlich zwei kleine Buttons: **Alle annehmen** und **Alle ablehnen**.
- Darunter eine Zusammenfassung: Anzahl der angenommenen und der abgelehnten Änderungen sowie Anzahl der Konflikte.
- Zwei Buttons: **Ausführen** und **Abbrechen**. Abbrechen ändert nichts.
- Ausgeführt werden genau die angehakten Änderungen, so wie sie in der Vorschau zu sehen waren.

## 6. Struktur-Datei (`System/Config/layout.json`)
- Legt fest, welche Gruppen und Buttons es gibt und in welcher Reihenfolge.
- Ein neuer Button entsteht, indem man einen Eintrag ergänzt und das passende Skript in den Ordner der Gruppe legt. Am Hauptprogramm ändert sich nichts.
- Schlüssel und interne Namen (`name`, `script`, `scope`) sind englisch, die sichtbaren Texte (`label`, `description`) deutsch. `name` ist zugleich der Ordnername der Gruppe in `System/Code`.
- Beispiel:
```json
{
  "groups": [
    {
      "name": "Images",
      "label": "Bilder",
      "buttons": [
        { "label": "Doubletten finden", "script": "FindDuplicates.ps1", "scope": "InputAndResult", "description": "Sucht doppelte Bilder in Input und Result" }
      ]
    },
    { "name": "Documents", "label": "Dokumente", "buttons": [] },
    { "name": "Songs", "label": "Songs", "buttons": [] }
  ]
}
```

## 7. Funktionen hinter den Buttons
- Jede Funktion ist ein eigenes Skript.
- Jede Gruppe hat einen eigenen Ordner in `System/Code`, benannt wie die Gruppe. Darin liegt für jede Funktion der Gruppe ein Skript.
- Jeder Button startet genau ein Skript. Die Struktur-Datei nennt den Dateinamen, der Ordner ergibt sich aus der Gruppe (Beispiel: `Code/Images/FindDuplicates.ps1`).
- Jedes Skript bekommt dieselben Angaben: Pfad zu Input, Pfad zu Result, Zugriff auf Log und Datenbank.
- **Arbeitsbereich je Funktion:** Jede Funktion arbeitet entweder nur in `Input` oder in `Input` und `Result`. Das steht pro Button in der Struktur-Datei (Feld `scope` mit den Werten `Input` oder `InputAndResult`).
  - Beispiel nur Input: Dateien in einen Ordner einsortieren.
  - Beispiel Input und Result: Doubletten finden, weil eine neue Datei schon in Result liegen kann.
- Der Bereich wird bei der Spezifikation jeder einzelnen Funktion festgelegt, und ich frage jedes Mal ausdrücklich bei dir nach.
- Bei Funktionen mit Bereich Input und Result zeigt die Vorschau beide Ordner.
- Ein Skript fasst selbst keine Datei an. Es liefert nur einen **Plan**: eine Liste von Schritten der Art „Datei X von Pfad A nach Pfad B“ (Umbenennen ist dabei ein Verschieben unter neuem Namen) sowie „Ordner anlegen“.
- Das Hauptprogramm ergänzt den Plan automatisch um „leeren Ordner in Input entfernen“ für alle Ordner, die nach dem Plan leer wären.
- Das Hauptprogramm baut aus dem Plan die Vorschau. Nach der Bestätigung führt `Common.ps1` die angehakten Schritte aus, schreibt das Log und passt die Datenbank an.
- So gilt die Grundregel für alle Skripte automatisch: Es gibt keinen Schritt „Datei löschen“.
- Fehlt ein eingetragenes Skript, ist der Button ausgegraut und das Log meldet es.

## 8. Logging
- Jede Aktion (ein Klick auf einen Button) schreibt eine eigene Logdatei.
- Dateiname: `YYYY-MM-DD_HH-MM-SS - Group - Script.log`, z. B. `2026-10-25_06-20-00 - Images - FindDuplicates.log`. So sortieren sich die Logs zeitlich.
- Kopf der Datei: `StartTime`, `EndTime`, `Group`, `Script`, `FilesMoved`, `Errors`.
- Danach eine Zeile pro Schritt in festem Format, durch Tabulator getrennt: Art des Schritts, alter Pfad, neuer Pfad.
- Arten: `MOVED` (verschoben, auch von Hand im Explorer), `RENAMED` (von Hand im Explorer umbenannt), `FOLDER_CREATED` (Ordner angelegt), `EMPTY_FOLDER_REMOVED` (leerer Ordner entfernt), `REJECTED` (abgelehnt), `ERROR` (Fehler).
- Abgelehnte Änderungen stehen also ebenfalls im Log. So sieht man später, was bewusst nicht gemacht wurde.
- Ein Fehler bricht nur die betroffene Datei ab, nicht den ganzen Lauf.

## 9. Rückgängig machen (bestätigt)
- Button **Aktion rückgängig machen** in der festen Button-Reihe.
- Ein Klick öffnet eine Auswahl der Logdateien aus `System/Logs`, die neueste oben.
- Aus der gewählten Logdatei entsteht ein umgekehrter Plan: Jede Verschiebung und jede Umbenennung wird zurückgenommen, entfernte leere Ordner werden wieder angelegt.
- Ordner in `Result`, die die ursprüngliche Aktion angelegt hat und die nach dem Zurückverschieben leer sind, werden entfernt (rote Zeile mit Häkchen in der Vorschau).
- Dieser Plan erscheint im selben Vorschaufenster, mit Farben und Häkchen. Man kann also auch nur einen Teil rückgängig machen.
- Liegt eine Datei nicht mehr dort, wo das Log sie erwartet, wird sie als Konflikt angezeigt und übersprungen.
- Das Rückgängigmachen schreibt eine eigene Logdatei (`... - Undo - <ursprüngliche Aktion>.log`). So kann man auch das wieder zurücknehmen.

## 10. Datenbank
### Zweck
- Die Datenbank kennt jede Datei in `Result` (und bei Bedarf in `Input`) mit ihren Hashes.
- Kerngedanke: Einmal `Result` initialisieren, danach `Input` initialisieren. Dann lassen sich neue Dateien schnell mit dem Bestand vergleichen, z. B. um Doubletten zu finden, ohne den ganzen Bestand jedes Mal neu einzulesen.

### Datei und Tabelle
- Datei: `System/Database/index.db` (SQLite).
- Tabelle **Files**, eine Zeile pro Datei:

| Spalte | Inhalt |
|---|---|
| `Path` | relativer Pfad ab dem Hauptordner des Werkzeugs, z. B. `Result/Images/Holiday/IMG_0412.jpg`. Eindeutig. |
| `Hash` | eindeutiger Hash des Dateiinhalts (SHA-256). Gleicher Hash = exakt gleiche Datei. |
| `SimilarityHash` | Ähnliche Inhalte ergeben ähnliche Werte. Für Bilder ein Bild-Hash (dHash, 64 Bit), der auch bei verkleinerten oder neu gespeicherten Kopien fast gleich bleibt. Vorerst **nur für Bilder** (bestätigt), bei allen anderen Dateien leer. |
| `Size` | Dateigröße in Byte |
| `Modified` | Änderungsdatum der Datei |
| `LastChecked` | Zeitpunkt der letzten Prüfung |

- `Size` und `Modified` dienen nur dazu, festzustellen, ob die Hashes neu berechnet werden müssen. So muss beim erneuten Initialisieren nur Neues oder Geändertes berechnet werden.
- Weil der Pfad mit `Result/` oder `Input/` beginnt, ist sofort klar, wo eine Datei liegt.

### Initialisieren
- Zwei feste Buttons neben **Aktion rückgängig machen**: **Result initialisieren** und **Input initialisieren**. Beide machen dasselbe, nur für den jeweiligen Ordner.
- Ablauf für jede Datei im Ordner:
  1. Gibt es schon einen Eintrag mit diesem Pfad und sind Größe und Änderungsdatum gleich, bleibt der Eintrag, wie er ist. Nichts wird berechnet.
  2. Gibt es den Eintrag, aber Größe oder Datum haben sich geändert, werden die Hashes neu berechnet.
  3. Gibt es keinen Eintrag, werden die Hashes berechnet. Gibt es einen Eintrag mit demselben Hash, dessen Datei an ihrem alten Pfad fehlt, wurde die Datei außerhalb des Werkzeugs verschoben: Der Pfad im Eintrag wird angepasst. Sonst entsteht ein neuer Eintrag.
- Zum Schluss werden alle Einträge dieses Ordners, deren Datei nicht mehr existiert, komplett aus der Datenbank entfernt (bestätigt) und im Log vermerkt. Das betrifft nur die Datenbankzeile, nie eine Datei.
- Das Initialisieren verändert keine Dateien, nur die Datenbank. Es zeigt einen Fortschrittsbalken und am Ende eine Zusammenfassung (neu, unverändert, neu berechnet, verschoben erkannt, fehlend).
- Es kann jederzeit abgebrochen werden. Was schon berechnet ist, bleibt gespeichert, beim nächsten Mal geht es dort weiter.
- Auch das Initialisieren schreibt eine Logdatei (`... - Database - InitializeResult.log` bzw. `InitializeInput.log`).

### Datenbank bei jeder Änderung aktuell halten
- Jedes Verschieben und Umbenennen durch das Werkzeug (auch beim Rückgängigmachen, bei `_2`-Umbenennungen und beim Umbenennen oder Verschieben von Hand im Explorer) ändert im selben Schritt den `Path` des Eintrags. Die Hashes bleiben, weil sich der Inhalt nicht ändert.
- Das erledigt `Common.ps1` zentral, damit kein Skript es vergessen kann.
- Verschiebt eine Funktion eine Datei, die noch keinen Eintrag hat, bekommt sie dabei einen.

### Doubletten finden (Beispiel für die Nutzung)
- Voraussetzung: Result und Input sind initialisiert.
- **Exakte Doublette:** gleicher `Hash`.
- **Ähnliches Bild:** `SimilarityHash` unterscheidet sich nur in wenigen Bits. Die Grenze steht in `settings.json` als `similarityThreshold` (Vorschlag: höchstens 5 von 64 Bit).
- Was mit gefundenen Doubletten passiert, wird bei der Funktion selbst spezifiziert.

## 11. Datei-Explorer
### Aufbau (bestätigt)
- Liegt im Hauptfenster zwischen der Leiste mit den Gruppen und der festen Button-Reihe und funktioniert ähnlich wie der Windows-Explorer.
- Zwei **getrennte Bereiche nebeneinander**: **links `Input`**, **rechts `Result`**. Jeder Bereich zeigt nur seinen eigenen Ordner. `System` und `ToDelete` werden nicht angezeigt (bestätigt).
- Jeder Bereich hat oben eine Pfadzeile (z. B. `Result › Images › 2024-07-13 - Tokio`) mit einem Button **Eine Ebene hoch**. Doppelklick auf einen Ordner öffnet ihn. Beide Bereiche navigieren unabhängig voneinander.
- Jeder Bereich hat **seinen eigenen Umschalter** mit zwei Buttons für die Ansicht (bestätigt), der aktive ist hervorgehoben. So kann z. B. links die Liste und rechts die Ordneransicht offen sein:
  - **Liste:** flache Liste aller Dateien im aktuellen Ordner **und allen Unterordnern**, ohne Ordnerebenen. Spalten: Name, Ordner (relativer Pfad), Größe, Änderungsdatum. Klick auf eine Spaltenüberschrift sortiert danach.
  - **Ordneransicht:** nur der Inhalt des aktuellen Ordners, Ordner zuerst. Bilder erscheinen als **Vorschaubild** (Thumbnail), andere Dateien mit ihrem Windows-Symbol.
- Die zuletzt gewählte Ansicht jeder Seite merkt sich das Programm für den nächsten Start (`settings.json`, Schlüssel `explorerViewInput` und `explorerViewResult`, jeweils `List` oder `Folder`).
- Doppelklick auf eine Datei öffnet sie mit dem Windows-Standardprogramm, z. B. ein Bild in der Fotoanzeige. Das ändert nichts an der Datei.
- Mehrfachauswahl wie im Windows-Explorer: Strg-Klick, Umschalt-Klick, Strg+A.
- Button **Aktualisieren** (auch Taste F5) liest beide Bereiche neu ein. Nach jeder ausgeführten Funktion, jedem Rückgängigmachen und jeder Änderung von Hand aktualisiert sich der Explorer von selbst.

### Vorschaubilder
- Werden beim Anzeigen aus dem Bild berechnet, nur für die gerade sichtbaren Bilder, damit große Ordner schnell bleiben.
- Sie liegen nur im Arbeitsspeicher, es werden keine zusätzlichen Dateien angelegt.
- Größe einstellbar in `settings.json`, Schlüssel `thumbnailSize` (Vorschlag: 128 Pixel).
- Lässt sich ein Bild nicht lesen (z. B. HEIC ohne passenden Windows-Codec), erscheint statt der Vorschau das normale Dateisymbol.

### Umbenennen
- Möglich für Dateien und Ordner, über Rechtsklick **Umbenennen** oder Taste F2, wie im Windows-Explorer.
- Wird **sofort ausgeführt**, ohne Vorschaufenster, weil du die Änderung selbst bewusst eintippst.
- Regeln:
  - Gibt es im selben Ordner schon einen Eintrag mit dem neuen Namen, wird **nicht** umbenannt und nichts überschrieben. Es erscheint eine Meldung, und du kannst einen anderen Namen eingeben. Hier gibt es keine automatische `_2`-Nummer, weil du den Namen bewusst wählst.
  - Unzulässige Zeichen für Windows-Namen (`\ / : * ? " < > |`) werden abgelehnt, mit Meldung.
  - Änderst du die Dateiendung, fragt das Programm einmal nach, ob das gewollt ist.
  - `Input` und `Result` selbst lassen sich nicht umbenennen.
- **Datenbank:** Beim Umbenennen einer Datei wird ihr `Path` angepasst. Beim Umbenennen eines Ordners werden alle Einträge angepasst, deren `Path` mit dem alten Ordnerpfad beginnt. Die Hashes bleiben gleich. Das erledigt `Common.ps1`, wie bei jeder anderen Änderung.
- **Log und Rückgängig:** Jede Umbenennung schreibt eine eigene Logdatei `YYYY-MM-DD_HH-MM-SS - Explorer - Rename.log` mit einer Zeile `RENAMED`, alter Pfad, neuer Pfad. Über **Aktion rückgängig machen** lässt sie sich zurücknehmen wie jede andere Aktion.

### Verschieben per Ziehen und Ablegen (bestätigt)
- Dateien und Ordner (auch mehrere ausgewählte) lassen sich mit der Maus ziehen und ablegen:
  - innerhalb eines Bereichs in einen anderen Ordner, z. B. in `Input` von einem Ordner in einen Unterordner,
  - zwischen den Bereichen, also von `Input` nach `Result` oder von `Result` nach `Input`.
- Ablegen geht auf einen Ordner in der Ansicht, auf die freie Fläche des gerade geöffneten Ordners oder auf einen Teil der Pfadzeile.
- Wird **sofort ausgeführt**, ohne Vorschaufenster, wie das Umbenennen.
- Regeln:
  - Liegt am Ziel schon eine Datei mit gleichem Namen, gilt die Grundregel: Die ankommende Datei bekommt `_2`, `_3` usw. Der Statusbereich meldet die neue Benennung.
  - Ein Ordner kann nicht in sich selbst oder in einen seiner Unterordner gezogen werden.
  - `Input` und `Result` selbst lassen sich nicht verschieben.
  - Wird ein Ordner in `Input` durch das Verschieben leer, wird er entfernt (Grundregel für leere Ordner in `Input`).
  - In der Liste-Ansicht kann man Dateien wegziehen, aber nichts dort ablegen, weil sie keine Ordner zeigt.
- **Datenbank:** Wie beim Umbenennen, jede verschobene Datei bekommt ihren neuen `Path`, bei Ordnern alle Einträge darunter.
- **Log und Rückgängig:** Jedes Ablegen schreibt eine eigene Logdatei `YYYY-MM-DD_HH-MM-SS - Explorer - Move.log` mit einer Zeile `MOVED` pro verschobener Datei oder Ordner (plus ggf. `EMPTY_FOLDER_REMOVED`). Über **Aktion rückgängig machen** lässt es sich zurücknehmen.
- **Löschen** gibt es im Explorer nicht (Grundregel). Die Entf-Taste tut nichts.

## 12. Hinweise für die Funktionsspezifikationen (nicht hier geregelt)
- Der Explorer zeigt nur `Input` und `Result`, `ToDelete` (Doubletten aus 2.2, Memes aus 2.8.2) ist dort bewusst nicht sichtbar (bestätigt).
- Funktionen, die Ordner umbenennen oder Dateien verschieben (z. B. 2.5, 2.6, 2.7), sollten dieselben zentralen Hilfsfunktionen in `Common.ps1` nutzen wie der Explorer, damit die Datenbank immer gleich angepasst wird.

## 13. Offene Fragen
- Keine.
