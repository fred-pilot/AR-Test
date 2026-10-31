# Offroad AR

iPhone-App, die deinen Spielzeug-Geländewagen per Kamera erkennt und ein animiertes 3D-Modell
passgenau darüberlegt: Die Reifen drehen sich, die Scheibenwischer wischen, Warnblinker und Scheinwerfer blinken.

- **Einmal einlernen, dann automatisch:** Beim ersten Start legst du das Modell einmal aufs Auto und
  gehst einmal darum herum (etwa eine Minute). Ab dann erkennt die App das Auto bei jedem Start von selbst,
  samt Lage, Drehung, Höhe und Boden, und legt das Modell darüber.
- Schiebst du das Auto, sucht die App es laufend neu und zieht das Modell nach (mit etwa einer Sekunde Verzögerung).
- Braucht **iOS 27** oder neuer.
- Mit LiDAR (z. B. iPhone 16 Pro) zusätzlich: optionale Verdeckung durch die Umgebung.
- Hände vor dem Auto verdecken das Modell.

## Aufbau

| Datei | Inhalt |
|---|---|
| `OffroadAR/ARController.swift` | AR-Session: Einlernen, Erkennen und Nachführen des Autos |
| `OffroadAR/ContentView.swift` | Oberfläche: Anleitung beim Einlernen, Schalter für die Animationen |
| `OffroadAR/ToyCar.usdz` | Die gescannte Karosserie (aus deinem Foto-Scan, ausgerichtet und bereinigt) |
| `OffroadAR/CarModelFactory.swift` | Lädt die Karosserie und setzt Räder, Wischer und Lichter an die vermessenen Stellen |
| `OffroadAR/CarAnimator.swift` | Animation von Rädern, Wischern und Lichtern |
| `training/ToyCar_training.usdz` | Trainingsmodell: der Scan mit seinen echten Rädern, in echter Größe (10,2 cm) |
| `project.yml` | Projektbeschreibung für XcodeGen (daraus entsteht das Xcode-Projekt) |
| `.github/workflows/ios.yml` | Baut die App in der Cloud als `.ipa`-Datei |
| `tools/scan_to_usdz/` | Python-Skripte, mit denen aus dem OBJ-Scan die `ToyCar.usdz` und das Trainingsmodell gemacht wurden |

### Das 3D-Modell
Die Karosserie stammt aus deinem Scan (`31.10.2026.obj`). Dafür wurde der Scan so bearbeitet:
- Der mitgescannte Tischboden wurde entfernt.
- Das Auto wurde gerade ausgerichtet (es stand im Scan um etwa 3,5° schräg) und auf Länge 1 normiert.
- Die gescannten Räder und die Scan-Schürze unter dem Auto wurden herausgeschnitten.

An ihre Stelle setzt die App eigene Räder, die sich drehen können. Wischer, Scheinwerfer und Blinker
kommen als eigene Teile dazu. Die Positionen dafür stehen in `CarModelFactory.Layout.scanned`.
Fehlt `ToyCar.usdz`, baut die App ein einfaches Ersatzmodell aus Grundformen.

Neu erzeugen (Python 3 mit `numpy pillow matplotlib usd-core`):
```
python tools/scan_to_usdz/normalize_car.py <scan.obj> <diffuse.jpg> <arbeitsordner>
python tools/scan_to_usdz/export_usdz.py <arbeitsordner> <texturordner> OffroadAR/ToyCar.usdz
python tools/scan_to_usdz/export_usdz.py <arbeitsordner> <texturordner> training/ToyCar_training.usdz 0.102
```
Die Grenzen zum Ausschneiden in `normalize_car.py` und die Radmaße in `export_usdz.py` passen
nur zu diesem einen Scan. Die `0.102` ist die echte Länge in Metern und muss zu
`CarModelFactory.realLength` passen.

### Die Erkennung
Beim Einlernen entsteht ein ARKit-Referenzobjekt (`ToyCar.arobject`) in den App-Daten. Sein Ursprung ist
genau die Stelle, an die du das Modell gelegt hast. Darum sitzt das animierte Modell später ohne
Korrektur auf dem erkannten Auto. Liegt es nicht genau, hilft **Neu einlernen**.

ARKit erkennt so ein eingelerntes Objekt nur, es verfolgt es nicht Bild für Bild. Die App vergisst das
erkannte Auto deshalb nach einem Moment wieder, ARKit findet es neu, und das Modell rückt an die neue Stelle.

**Noch genauer, mit Verfolgung in jedem Bild:** Aus `training/ToyCar_training.usdz` lässt sich mit Create ML
ein `.referenceobject` trainieren. Das braucht einen Mac mit Apple-Chip (M1 oder neuer) und macOS 27,
auf den kostenlosen GitHub-Macs ist es ohne Grafikbeschleunigung viel zu langsam:
```
xcrun createml objecttracker -m extended -s training/ToyCar_training.usdz -o OffroadAR/ToyCar.referenceobject
```
Liegt `OffroadAR/ToyCar.referenceobject` in der App, nimmt sie automatisch das und überspringt das Einlernen.
Das Trainingsmodell liegt im selben Koordinatensystem wie `ToyCar.usdz`, nur auf echte Größe skaliert.

## So kommt die App aufs iPhone (kostenlos, ohne Developer Program)

GitHub baut die App auf einem Mac in der Cloud mit aktuellem Xcode, aber **unsigniert**.
Auf dem Windows-PC signiert ein Sideloading-Programm sie mit deiner **normalen, kostenlosen Apple-ID**
und installiert sie per USB-Kabel auf dem iPhone.

Einschränkungen einer kostenlosen Apple-ID (Vorgabe von Apple):
- Die App läuft **7 Tage**, danach muss sie neu installiert werden (einfach drüber installieren, dann bleibt das eingelernte Auto erhalten).
- Höchstens 3 selbst installierte Apps gleichzeitig.
- Weitergabe an andere ist so nicht möglich.

### Einmalige Einrichtung
1. **GitHub:** Kostenloses Konto auf [github.com](https://github.com) und ein leeres Repository, z. B. `offroad-ar`.
   Ein öffentliches Repository hat unbegrenzte Build-Minuten. Bei einem privaten reichen die
   kostenlosen Minuten für etwa 15 bis 20 Builds im Monat.
2. **Sideloading-Programm auf dem PC**, eins von beiden:
   - [Sideloadly](https://sideloadly.io): am einfachsten. Braucht iTunes und iCloud für Windows als Download von apple.com, nicht die Microsoft-Store-Version.
   - [AltStore](https://altstore.io) mit AltServer: kann die App später auch über WLAN automatisch verlängern.
   Beide fragen nach deiner Apple-ID. Das Passwort gibst du dort selbst ein.
3. **iPhone:** Mit USB-Kabel an den PC, „Vertrauen“ bestätigen. Dann unter
   **Einstellungen → Datenschutz & Sicherheit → Entwicklermodus** einschalten und das iPhone neu starten.

### Neue Version installieren
1. Auf GitHub im Repository unter **Actions → iOS** den neuesten grünen Lauf öffnen. Jeder Push baut automatisch,
   alternativ über **Run workflow** von Hand starten.
2. Unten bei **Artifacts** `OffroadAR-…` herunterladen und entpacken. Darin liegt `OffroadAR.ipa`.
3. Die `.ipa` in Sideloadly ziehen (bzw. in AltStore über „+“ auswählen), Apple-ID eingeben, **Start**.
4. Beim ersten Mal auf dem iPhone: **Einstellungen → Allgemein → VPN & Geräteverwaltung** → deine Apple-ID → **Vertrauen**.

### Selbst bauen
Die App braucht **Xcode 27** (wegen iOS 27). Das läuft nur auf einem Mac mit aktuellem macOS,
nicht mehr auf dem MacBook Pro 2017. Darum baut GitHub die App in der Cloud.

## Benutzung der App

Beim ersten Start (einmalig):
1. Auto auf Boden oder Tisch stellen, gutes Licht, möglichst nichts anderes direkt daneben.
2. Das Auto auf dem Bildschirm antippen. Ein halbdurchsichtiges Modell erscheint.
3. Mit einem Finger schieben, mit zwei Fingern drehen, bis das Modell genau auf dem Auto sitzt. **Passt** tippen.
4. Langsam einmal ganz um das Auto herumgehen, 30 bis 50 cm entfernt und leicht von oben.
   Bei 100 % speichert die App von selbst (ab 75 % geht auch **Fertig**).

Danach bei jedem Start: Kamera aufs Auto richten, das Modell erscheint von selbst.

Mit **Reifen**, **Wischer** und **Licht** schaltest du die Animationen ein und aus.
**Auto neu suchen** startet die Erkennung von vorn, **Neu einlernen** vergisst das Auto und beginnt das Einlernen neu.
