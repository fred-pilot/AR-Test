# Offroad AR

iPhone-App, die deinen Spielzeug-Geländewagen per Kamera erkennt und ein animiertes 3D-Modell
darüberlegt: Die Reifen drehen sich, die Scheibenwischer wischen, Warnblinker und Scheinwerfer blinken.

- Läuft auf jedem iPhone ab iOS 17 (ab iPhone XS/XR), **kein LiDAR nötig**.
- Mit LiDAR (z. B. iPhone 16 Pro) zusätzlich: schnellere Flächenerkennung und optionale Verdeckung durch die Umgebung.
- Hände vor dem Auto verdecken das Modell (ab iPhone XS, auch ohne LiDAR).

## Aufbau

| Datei | Inhalt |
|---|---|
| `OffroadAR/ARController.swift` | AR-Session: Modus „Spielen“ (Auto erkennen) und „Einscannen“ (Referenz-Scan erstellen) |
| `OffroadAR/ToyCar.usdz` | Die gescannte Karosserie (aus deinem Foto-Scan, ausgerichtet und bereinigt) |
| `OffroadAR/CarModelFactory.swift` | Lädt die Karosserie und setzt Räder, Wischer und Lichter an die vermessenen Stellen |
| `OffroadAR/CarAnimator.swift` | Animation von Rädern, Wischern und Lichtern |
| `OffroadAR/ScanBox.swift` | Der Drahtkasten, den man beim Scannen ums Auto legt |
| `OffroadAR/ScanStore.swift` | Speichern und Laden der Scans (`.arobject`) |
| `Resources/ReferenceObjects/` | Scans, die fest in die App eingebaut werden |
| `project.yml` | Projektbeschreibung für XcodeGen (daraus entsteht das Xcode-Projekt) |
| `.github/workflows/ios.yml` | Baut die App in der Cloud als `.ipa`-Datei |
| `tools/scan_to_usdz/` | Python-Skripte, mit denen aus dem OBJ-Scan die `ToyCar.usdz` gemacht wurde |

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
```
Die Grenzen zum Ausschneiden in `normalize_car.py` und die Radmaße in `export_usdz.py` passen
nur zu diesem einen Scan.

## So kommt die App aufs iPhone (kostenlos, ohne Developer Program)

GitHub baut die App auf einem Mac in der Cloud mit aktuellem Xcode, aber **unsigniert**.
Auf dem Windows-PC signiert ein Sideloading-Programm sie mit deiner **normalen, kostenlosen Apple-ID**
und installiert sie per USB-Kabel auf dem iPhone.

Einschränkungen einer kostenlosen Apple-ID (Vorgabe von Apple):
- Die App läuft **7 Tage**, danach muss sie neu installiert werden (einfach drüber installieren, dann bleiben die Scans erhalten).
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

### Alternative: selbst auf dem MacBook bauen
Die App ist so eingestellt, dass sie auch mit **Xcode 15.2** baut, der letzten Version für macOS Ventura
(MacBook Pro 2017). Die fertige `.ipa` installierst du dann genauso mit Sideloadly. Sideloadly gibt es auch für macOS.

Einmalig auf dem Mac:
1. macOS auf die neueste Ventura-Version bringen (mindestens 13.5).
2. **Xcode 15.2** von [developer.apple.com/download/all](https://developer.apple.com/download/all/?q=xcode%2015.2)
   laden (Anmeldung mit normaler Apple-ID, kostenlos). Die `.xip` entpacken, Xcode in **Programme** ziehen, einmal starten
   und die Zusatzkomponenten installieren lassen. Der App Store bietet für Ventura kein passendes Xcode an.
3. Im Terminal:
   ```
   sudo xcode-select -s /Applications/Xcode.app
   git clone https://github.com/<dein-name>/offroad-ar.git ~/offroad-ar
   cd ~/offroad-ar
   curl -L -o /tmp/xcodegen.zip https://github.com/yonaskolb/XcodeGen/releases/latest/download/xcodegen.zip
   unzip -q -o /tmp/xcodegen.zip -d tools
   ```

Bauen (jedes Mal):
```
cd ~/offroad-ar
git pull
bash scripts/build_ipa.sh
```
Danach liegt die App unter `~/offroad-ar/build/OffroadAR.ipa`.

Direkt aus Xcode aufs iPhone spielen klappt mit Xcode 15.2 vermutlich nicht: Es kennt das iOS auf dem
iPhone 16 Pro nicht. Darum der Umweg über die `.ipa` und Sideloadly. Die App selbst läuft trotzdem auf dem neuen iOS.

## Benutzung der App

### Einscannen (einmalig, am besten mit dem iPhone 16 Pro)
1. Auto auf einen Tisch mit etwas Struktur stellen (Holz, Zeitung). Gutes, gleichmäßiges Licht.
2. Modus **Einscannen** wählen, das iPhone etwas bewegen, bis der Tisch erkannt ist.
3. Auf die **Mitte des Autos** tippen. Ein Drahtkasten erscheint, den man mit einem Finger verschieben kann.
4. Mit **Drehung** den Kasten aufs Auto ausrichten. Die **Länge** steht schon auf den gemessenen 10,2 cm
   und muss nur nachgestellt werden, wenn der Kasten nicht genau ums Auto passt.
   Breite und Höhe passen sich automatisch an die Form des Autos an. Die **rote Kante ist vorne**.
   Der Kasten bestimmt später auch, wie groß das 3D-Modell eingeblendet wird.
5. Langsam einmal rund ums Auto gehen, auch schräg von oben. Die gelben Punkte zeigen, was die App sieht.
   Je mehr Punkte auf dem Auto liegen, desto besser.
6. **Scan speichern**. Danach zu **Spielen** wechseln und testen.

### Spielen
Die Kamera aufs Auto richten und sich langsam bewegen. Sobald das Auto erkannt ist, erscheint das Modell darüber.
Mit **Reifen**, **Wischer** und **Licht** schaltest du die Animationen ein und aus.

### Scan sichern
Eigene Scans liegen in der Dateien-App unter **Auf meinem iPhone → Offroad AR → Scans**. Sie bleiben erhalten,
wenn man die neue Version einfach über die alte installiert, ohne die App vorher zu löschen. Mit **Exportieren** lassen sie sich auf den PC schicken. Legt man sie in
`Resources/ReferenceObjects/`, sind sie fest in die App eingebaut.
