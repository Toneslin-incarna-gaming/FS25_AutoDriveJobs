# FS25_AutoDriveJobs – AutoDrive Aufträge / AutoDrive Jobs

[Deutsch](#deutsch) · [English](#english)

Add-on für [FS25_AutoDrive](https://github.com/Stephan-S/FS25_AutoDrive): regelbasierte Versorgungs-Aufträge.
*Add-on for FS25_AutoDrive: rule based supply jobs.*

> **Benötigt / Requires:** Farming Simulator 25, FS25_AutoDrive (3.0.x).
> Multiplayer: ja – muss auf dem Server **und** bei allen Spielern installiert sein.

---

## Deutsch

### Was macht der Mod?

Du legst Regeln an, AutoDrive fährt:

> *„Fällt das Stroh im Kuhstall unter 30 %, fährt der Traktor vom Parkplatz P1 zwischen Strohlager und Kuhstall hin und her, bis 90 % erreicht sind (oder höchstens 4 Fahrten), und parkt dann wieder.“*

Kein Timer, keine festen Routenschleifen – der Auftrag startet, wenn er gebraucht wird, und endet, wenn das Ziel erreicht ist.

### Funktionen

**Überwachbare Füllstände**
- Ställe: einzelnes Futter, Futtergruppe, Futter gesamt, Stroh, Wasser, Gülle/Mist
- Fütterungsroboter (z. B. Lely Vector): die einzelnen Bunker
- Silos, Produktionen, Lager, Verkaufsstellen mit Lager – jedes Lager mit Füllstand
- **Fahrzeuge / Anhänger**: z. B. ein Zubringer-Güllefass, das am Feld steht

**Zwei Fahrweisen**
- **Abholen und Liefern** – Pendeln zwischen Ladeziel und Abladeziel, bis Stopp-% oder max. Fahrten erreicht sind, dann parken. Optional Pause, wenn die Fahrten aufgebraucht sind und der Stand noch zu niedrig ist.
- **Laden und zurück (Zubringer)** – fällt der Stand des überwachten Anhängers unter X % und wird 15 s lang nichts mehr umgeladen, fährt er zum Ladeziel, lädt und kehrt zum Warteplatz zurück (wählbar oder automatisch das AD-Ziel, das seinem Standort am nächsten liegt). Nach N Minuten ohne Änderung parkt er und startet erst wieder, wenn sich am Füllstand etwas tut.

**Clever beim Laden und Abladen**
- Lädt nur so viel, wie ins Lager noch passt (mit Sicherheitspuffer) – niemand muss von Hand nachhelfen.
- Ist das Lager voll und bleibt ein Rest im Anhänger: Rest wird bei einem anderen Auftrag mit demselben Ladegut abgeladen, sonst am **Notabladeplatz** des Auftrags.
- **Auftrags-Ketten**: hat das Fahrzeug nach dem Abladen noch einen weiteren offenen Auftrag mit demselben Parkplatz, fährt es direkt weiter, statt erst zu parken.
- Manuell gestartete AD-Fahrten mit denselben Zielen werden vom passenden Auftrag „übernommen“.

**Fahrzeugwahl über den AD-Parkplatz**
Ein Auftrag kennt kein festes Fahrzeug, sondern einen AutoDrive-Parkplatz. Gestartet wird das Fahrzeug, dem dieser Parkplatz zugewiesen ist und das dort steht. Traktor tauschen = einfach anderen Traktor mit passendem Anhänger hinstellen.

**HUD im AutoDrive-Stil**
- Öffnen/Schließen: **LStrg + LAlt + J** (im Spiel umbelegbar)
- An der grünen Kopfzeile verschiebbar, Position wird gespeichert
- Maus an/aus: dieselbe Taste wie bei AutoDrive (Standard: mittlere Maustaste)
- Liste aller Aufträge mit Füllstandsbalken, Status, Fahrtenzähler; An/Aus per Klick
- Editor mit Pull-down-Listen (nach Entfernung sortiert, AD-Ordner) und +/-Zählern (Mausrad = fein)

**Speicherung**
Aufträge liegen im Savegame-Ordner als `autoDriveJobs.xml`, die HUD-Position in `modSettings/FS25_AutoDriveJobs.xml`.

### Installation

1. Unter [Releases](../../releases/latest) die Datei **`FS25_AutoDriveJobs.zip`** herunterladen – **nicht** über den grünen „Code → Download ZIP“-Knopf (der Ordner darin wird vom Spiel nicht erkannt).
2. Die Zip **ungeöffnet** in den Mod-Ordner kopieren: `Dokumente/My Games/FarmingSimulator2025/mods`
3. Im Spiel zusammen mit FS25_AutoDrive aktivieren.

### Schnellstart

1. In AutoDrive: Ziele für Laden, Abladen und einen Parkplatz anlegen; dem Fahrzeug im AD-HUD den Parkplatz zuweisen und es dort abstellen.
2. **LStrg + LAlt + J** → **+** (Neuer Auftrag).
3. Objekt wählen (Stall, Silo, … oder Anhänger) → Messwert wählen → Parkplatz → Ladegut → Ladeziel → Abladeziel → Start-% / Stopp-% / Fahrten → **Speichern**.
4. Fertig. Der Auftrag zeigt in der Liste, was er gerade tut („bereit, Stand ok“, „fährt“, „Pause noch 8 min“, …) oder woran es hängt („Fahrzeug steht nicht am Parkplatz“).

### Hinweise

- Am Fahrzeug sollten die AD-Optionen **„Ziele rotieren“** und **„automatisches Ablade-/Ladeziel“** aus sein – sonst überschreibt AutoDrive die Auftragsziele.
- Zubringer: die Start-Schwelle unter dem AD-„Entladefüllstand“ des Fahrzeugs halten (Standard 100 % → kein Problem), sonst fährt AD ohne zu laden zurück.
- Pausen und Wartezeiten laufen in **Echtzeit**-Minuten.
- Der Auftrag entscheidet direkt nach jedem Abladen neu. Steht im Log `PickupAndDeliverMode nicht gefunden`, läuft ein Fallback (Stopp erst nach der nächsten Fahrt) – bitte als Issue melden mit AD-Version.

### Fehler melden

Bitte mit **log.txt**, AutoDrive-Version, Karte und einer kurzen Beschreibung des Auftrags (Objekt, Messwert, Fahrweise) als [Issue](../../issues) einstellen. Alle Logzeilen des Mods beginnen mit `[AD Jobs]`.

### Unterstützen

Der Mod ist kostenlos. Wenn er dir Zeit spart und du etwas zurückgeben möchtest, freue ich mich über eine kleine Spende – ganz freiwillig.

[![Spenden mit PayPal](https://img.shields.io/badge/Spenden-PayPal-0070ba?logo=paypal&logoColor=white)](https://paypal.me/toneslin)

### Lizenz

Alle Rechte vorbehalten. Kostenlos im Spiel nutzen, auch auf Servern, ist erlaubt. Woanders hochladen, verkaufen oder geänderte Versionen veröffentlichen nur mit meiner Erlaubnis. Bitte verlinke stattdessen auf diese Seite. Details: [LICENSE](LICENSE)

---

## English

### What does it do?

You write rules, AutoDrive drives:

> *"If the straw in the cow barn falls below 30 %, the tractor at park position P1 shuttles between the straw storage and the barn until 90 % is reached (or at most 4 trips), then parks again."*

No timers, no fixed loops – a job starts when it is needed and stops when the target is reached.

### Features

**Fill levels that can be watched**
- Husbandries: single food type, food group, total food, straw, water, slurry / manure
- Feeding robots (e.g. Lely Vector): the individual bunkers
- Silos, productions, storages, selling points with storage – any storage with a fill level
- **Vehicles / trailers**: e.g. a feeder slurry tanker standing at the field

**Two driving modes**
- **Pick up and deliver** – shuttle between load and unload target until the stop % or the max. number of trips is reached, then park. Optional pause when the trips are used up and the level is still too low.
- **Load and return (feeder)** – when the watched trailer falls below X % and nothing has been transferred for 15 s, it drives to the load target, loads and returns to its waiting place (chosen, or automatically the AD target nearest to where it stood). After N minutes without any change it parks and only starts again when the level changes.

**Smart loading and unloading**
- Loads only what still fits into the storage (with a safety margin) – nobody has to help by hand.
- Storage full and a rest left in the trailer: the rest is unloaded at another job with the same fill type, otherwise at the job's **emergency unload point**.
- **Job chaining**: if the vehicle has another open job with the same park position, it continues right away instead of parking first.
- Manually started AD runs with the same targets are adopted by the matching job.

**Vehicle selection via AD park position**
A job does not store a fixed vehicle but an AutoDrive park position. The vehicle that has this park position assigned and stands there is started. Swapping tractors = park another tractor with a fitting trailer there.

**HUD in AutoDrive style**
- Open / close: **LCtrl + LAlt + J** (rebindable)
- Drag by the green header, position is saved
- Mouse on/off: same key as AutoDrive (default: middle mouse button)
- List of all jobs with level bar, status, trip counter; on/off with one click
- Editor with pull-down lists (sorted by distance, AD folders) and +/- counters (mouse wheel = fine steps)

**Saving**
Jobs are stored in the savegame folder as `autoDriveJobs.xml`, the HUD position in `modSettings/FS25_AutoDriveJobs.xml`.

### Installation

1. Download **`FS25_AutoDriveJobs.zip`** from [Releases](../../releases/latest) – **not** via the green "Code → Download ZIP" button (the game does not recognise the folder inside it).
2. Copy the zip **as it is** into your mods folder: `Documents/My Games/FarmingSimulator2025/mods`
3. Enable it in the game together with FS25_AutoDrive.

### Quick start

1. In AutoDrive: create targets for loading, unloading and a park position; assign the park position to the vehicle in the AD HUD and park it there.
2. **LCtrl + LAlt + J** → **+** (New job).
3. Choose the object (barn, silo, … or a trailer) → value to watch → park position → fill type → load target → unload target → start % / stop % / trips → **Save**.
4. Done. The list shows what every job is doing ("ready, level ok", "driving", "pause, 8 min left", …) or what blocks it ("vehicle is not at its park position").

### Notes

- Turn off the AD options **"rotate targets"** and **"automatic unload / pickup target"** on the vehicle – otherwise AutoDrive overrides the job targets.
- Feeder jobs: keep the start threshold below the vehicle's AD "unload fill level" (default 100 % → no issue), otherwise AD returns without loading.
- Pauses and waiting times are **real-time** minutes.
- The job decides anew right after every unloading. If the log says `PickupAndDeliverMode nicht gefunden`, a fallback is active (stop only after the next trip) – please report it as an issue with your AD version.

### Reporting bugs

Please open an [issue](../../issues) with your **log.txt**, AutoDrive version, map and a short description of the job (object, value, mode). All log lines of the mod start with `[AD Jobs]`.

### Support

The mod is free. If it saves you time and you want to give something back, I am happy about a small donation – completely voluntary.

[![Donate with PayPal](https://img.shields.io/badge/Donate-PayPal-0070ba?logo=paypal&logoColor=white)](https://paypal.me/toneslin)

### License

All rights reserved. Using it for free in the game, also on servers, is allowed. Uploading it elsewhere, selling it or publishing changed versions only with my permission. Please link to this page instead. Details: [LICENSE](LICENSE)

---

## Credits

- **Toneslin** – Idee, Code, Tests / idea, code, testing
- **Stephan-S und das AutoDrive-Team / and the AutoDrive team** – FS25_AutoDrive, dessen HUD-Grafiken und Schnittstelle dieser Mod nutzt / whose HUD textures and external interface this mod uses
