# FS25_AutoDriveJobs – AutoDrive Aufträge / AutoDrive Jobs

[Deutsch](#deutsch) · [English](#english)

Add-on für [FS25_AutoDrive](https://github.com/Stephan-S/FS25_AutoDrive): regelbasierte Versorgungs- und Abfuhr-Aufträge.
*Add-on for FS25_AutoDrive: rule based supply and haul away jobs.*

> **Benötigt / Requires:** Farming Simulator 25, FS25_AutoDrive (3.0.x).
> Optional: FS25_Courseplay – nur für die Fahrweise „Ablauf“ / *only for the "Sequence" mode*.
> Multiplayer: ja – muss auf dem Server **und** bei allen Spielern installiert sein, in derselben Version.

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

**Drei Fahrweisen**
- **Abholen und Liefern** – Pendeln zwischen Ladeziel und Abladeziel, bis Stopp-% oder max. Fahrten erreicht sind, dann parken. Optional Pause, wenn die Fahrten aufgebraucht sind und der Stand noch zu niedrig ist.
- **Laden und zurück (Zubringer)** – fällt der Stand des überwachten Anhängers unter X % und wird 15 s lang nichts mehr umgeladen, fährt er zum Ladeziel, lädt und kehrt zum Warteplatz zurück (wählbar oder automatisch das AD-Ziel, das seinem Standort am nächsten liegt). Nach N Minuten ohne Änderung parkt er und startet erst wieder, wenn sich am Füllstand etwas tut.
- **Ablauf (Courseplay)** – mehrere Schritte nacheinander: mit AutoDrive zu einem AD-Ziel fahren, dann einen gespeicherten Courseplay-Kurs abfahren (Mähen, Mulchen, Düngen …). Mit Abladeziel (z. B. Ladewagen) lädt AutoDrive ab, sobald er voll ist, und übergibt wieder an Courseplay. Nach dem letzten Schritt parkt das Fahrzeug und der Auftrag schaltet sich aus. Im Multiplayer werden die Kursdateien beim Speichern automatisch an den Server geschickt.

**Zwei Regeln**
- **Versorgen** – Start, wenn der Stand *unter* X % fällt, Stopp ab Y % (Futter, Stroh, Wasser …).
- **Abfuhr** – Start, wenn der Stand Y % *erreicht*, Stopp unter X % (z. B. Milch vom Stall zur Molkerei). Optional **Mindestpreis**: Der Auftrag startet erst, wenn die Verkaufsstelle am Abladeziel mindestens diesen Preis pro 1000 l zahlt. Läuft das Lager beim Laden leer, fährt das Fahrzeug mit der Teilladung los und parkt danach.

**Auftrags-Anhänger (Umkoppeln)**
Ein Auftrag kann an einen bestimmten Anhänger gebunden werden, z. B. den Milchauflieger. Hängt beim Start ein anderer Anhänger am Fahrzeug, stellt es diesen am Parkplatz ab, fährt rückwärts an den Auftrags-Anhänger auf dessen AD-Parkplatz, hält kurz vor der Deichsel und koppelt an. Nach dem Auftrag parkt es dort, stellt ihn ab und holt den anderen wieder.
Umgekoppelt wird nur, wenn der Auftrags-Anhänger auf seinem AD-Parkplatz steht und an keiner anderen Zugmaschine hängt. Ist der andere Anhänger nach dem Auftrag weg oder angehängt, stellt das Fahrzeug den Auftrags-Anhänger ab und parkt allein.

**Clever beim Laden und Abladen**
- Lädt nur so viel, wie ins Lager noch passt (mit Sicherheitspuffer) – niemand muss von Hand nachhelfen.
- Ist das Lager voll und bleibt ein Rest im Anhänger: Rest wird bei einem anderen Auftrag mit demselben Ladegut abgeladen, sonst am **Notabladeplatz** des Auftrags.
- **Auftrags-Ketten**: hat das Fahrzeug nach dem Abladen noch einen weiteren offenen Auftrag mit demselben Parkplatz, fährt es direkt weiter, statt erst zu parken.
- Manuell gestartete AD-Fahrten mit denselben Zielen werden vom passenden Auftrag „übernommen“.
- **Mehrere Ladeziele**: Ist das Lager am ersten Ladeziel leer, fährt das Fahrzeug zum nächsten weiter. Sind alle leer, startet der Auftrag gar nicht erst.
- **Lager am Ladeziel**: Automatisch zählt das vollste passende Lager im Umkreis von 80 m. Stehen mehrere Silos nebeneinander (z. B. Heu und Stroh), ordnest du im Auftrag unter „Lager an …“ oder im Reiter **„Lager“** (alle Ladeziele auf einen Blick, auch ohne Auftrag) das richtige fest zu; Rechtsklick entfernt die Zuordnung. Der Knopf **L#** oben im HUD zeigt dazu über jedem Lager im Spiel eine Nummer (L1, L2 …) mit Inhalt an.
- Ist noch **anderes Ladegut** im Anhänger (Rest eines anderen Auftrags), wird es zuerst bei einem passenden Auftrag abgeliefert.
- Nimmt das Abladeziel nichts mehr an, wird nach 30 s abgebrochen und der Rest anderswo abgeladen, statt endlos zu warten.

**Mehrere Aufträge, ein Fahrzeug**
- **Priorität 1–9** je Auftrag: Teilen sich Aufträge ein Fahrzeug, kommt die kleinere Zahl zuerst dran, bei gleicher Priorität der dringendste.
- **Reiter „Geplant“**: zeigt je Fahrzeug, was es gerade fährt und welche fälligen Aufträge in welcher Reihenfolge folgen. Per **Drag & Drop** umsortieren, **Rechtsklick** = als Nächstes, **„Auto“** = wieder automatisch.

**Fahrzeugwahl über den AD-Parkplatz**
Ein Auftrag kennt kein festes Fahrzeug, sondern einen AutoDrive-Parkplatz. Gestartet wird das Fahrzeug, dem dieser Parkplatz zugewiesen ist und das dort **samt Anhänger** steht (oder am Lade-/Abladeziel des Auftrags). Steht nur die Zugmaschine dort und der Anhänger woanders, wird das Gespann nicht verwendet. Traktor tauschen = einfach anderen Traktor mit passendem Anhänger hinstellen.

**HUD im AutoDrive-Stil**
- Öffnen/Schließen: **LStrg + LAlt + J** (im Spiel umbelegbar)
- An der grünen Kopfzeile verschiebbar, Position wird gespeichert
- Maus an/aus: dieselbe Taste wie bei AutoDrive (Standard: mittlere Maustaste)
- Liste aller Aufträge mit Füllstandsbalken, Status, Fahrtenzähler; An/Aus per Klick
- **Gruppen** (frei benennbar oder automatisch nach Gebäude), auf- und zuklappbar; Aufträge **kopieren**
- Gleichnamige Gebäude bekommen eine Nummer („Kuhstall #2“)
- Editor mit Pull-down-Listen (nach Entfernung sortiert, AD-Ordner) und +/-Zählern (Mausrad = fein)
- Maus über einem Fahrzeug oder Anhänger im Spiel: Name, AD-Parkplatz und zugehöriger Auftrag
- **Parken schicken**: **LStrg + LAlt + P** schickt das nächste Auftragsfahrzeug in der Umgebung zum Parkplatz und beendet seinen Auftrag; im HUD gibt es dafür je Auftrag einen Park-Knopf

**Speicherung**
Aufträge und Lager-Zuordnungen liegen im Savegame-Ordner als `autoDriveJobs.xml`, HUD-Position und gewählter Reiter in `modSettings/FS25_AutoDriveJobs.xml`.

### Installation

1. Unter [Releases](../../releases/latest) die Datei **`FS25_AutoDriveJobs.zip`** herunterladen – **nicht** über den grünen „Code → Download ZIP“-Knopf (der Ordner darin wird vom Spiel nicht erkannt).
2. Die Zip **ungeöffnet** in den Mod-Ordner kopieren: `Dokumente/My Games/FarmingSimulator2025/mods`
3. Im Spiel zusammen mit FS25_AutoDrive aktivieren.

### Schnellstart

1. In AutoDrive: Ziele für Laden, Abladen und einen Parkplatz anlegen; dem Fahrzeug im AD-HUD den Parkplatz zuweisen und es dort abstellen.
2. **LStrg + LAlt + J** → **+** (Neuer Auftrag).
3. Objekt wählen (Stall, Silo, … oder Anhänger) → Messwert wählen → Parkplatz → Ladegut → Ladeziel → Abladeziel → Start-% / Stopp-% / Fahrten → **Speichern**.
4. Fertig. Der Auftrag zeigt in der Liste, was er gerade tut („bereit, Stand ok“, „fährt“, „Pause noch 8 min“, …) oder woran es hängt („Fahrzeug mit Anhänger steht weder am Parkplatz noch am Lade-/Abladeziel“).

### Hinweise

- Am Fahrzeug sollten die AD-Optionen **„Ziele rotieren“** und **„automatisches Ablade-/Ladeziel“** aus sein – sonst überschreibt AutoDrive die Auftragsziele.
- Zubringer: die Start-Schwelle unter dem AD-„Entladefüllstand“ des Fahrzeugs halten (Standard 100 % → kein Problem), sonst fährt AD ohne zu laden zurück.
- Pausen und Wartezeiten laufen in **Echtzeit**-Minuten.
- Liest ein Auftrag das falsche Lager („Lager am Ladeziel leer“, obwohl etwas drin ist): Im Log steht, welche Lager geprüft wurden. Das richtige im Auftrag unter „Lager an …“ zuordnen.
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

**Three driving modes**
- **Pick up and deliver** – shuttle between load and unload target until the stop % or the max. number of trips is reached, then park. Optional pause when the trips are used up and the level is still too low.
- **Load and return (feeder)** – when the watched trailer falls below X % and nothing has been transferred for 15 s, it drives to the load target, loads and returns to its waiting place (chosen, or automatically the AD target nearest to where it stood). After N minutes without any change it parks and only starts again when the level changes.
- **Sequence (Courseplay)** – several steps in a row: drive to an AD target with AutoDrive, then run a saved Courseplay course (mowing, mulching, fertilising …). With an unload target (e.g. a loader wagon) AutoDrive unloads when it is full and hands back to Courseplay. After the last step the vehicle parks and the job switches itself off. In multiplayer the course files are sent to the server automatically when the job is saved.

**Two rules**
- **Supply** – start when the level falls *below* X %, stop at Y % (food, straw, water …).
- **Haul away** – start when the level *reaches* Y %, stop below X % (e.g. milk from the barn to the dairy). Optional **minimum price**: the job only starts when the selling station at the unload target pays at least this price per 1000 l. If the source runs empty while loading, the vehicle leaves with the partial load and parks afterwards.

**Job trailer (trailer swap)**
A job can be bound to one trailer, e.g. the milk trailer. If another trailer hangs on the vehicle when the job starts, it drops that one at the park position, reverses to the job trailer at its AD park position, stops right before the drawbar and attaches it. After the job it parks there, drops it and fetches the other one again.
The swap only happens if the job trailer stands at its AD park position and hangs on no other vehicle. If the other trailer is gone or attached elsewhere after the job, the vehicle drops the job trailer and parks alone.

**Smart loading and unloading**
- Loads only what still fits into the storage (with a safety margin) – nobody has to help by hand.
- Storage full and a rest left in the trailer: the rest is unloaded at another job with the same fill type, otherwise at the job's **emergency unload point**.
- **Job chaining**: if the vehicle has another open job with the same park position, it continues right away instead of parking first.
- Manually started AD runs with the same targets are adopted by the matching job.
- **Several load targets**: if the storage at the first one is empty, the vehicle goes on to the next. If all are empty the job does not start at all.
- **Storage at the load target**: by default the fullest fitting storage within 80 m counts. If several silos stand side by side (e.g. hay and straw), set the right one in the job under "Storage at …" or in the **"Storages"** tab (all load targets at a glance, also without a job); right click removes it. The **L#** button at the top of the HUD shows a number (L1, L2 …) with the contents above every storage in the world.
- If **another fill type** is still on the trailer (rest of another job), it is delivered to a fitting job first.
- If the unload target does not take anything any more, unloading is given up after 30 s and the rest goes elsewhere instead of waiting forever.

**Several jobs, one vehicle**
- **Priority 1–9** per job: if jobs share a vehicle, the lower number goes first; with the same priority the most urgent one.
- **"Planned" tab**: shows per vehicle what it is driving now and which due jobs follow in which order. **Drag & drop** to reorder, **right click** = next, **"Auto"** = automatic order again.

**Vehicle selection via AD park position**
A job does not store a fixed vehicle but an AutoDrive park position. The vehicle that has this park position assigned and stands there **together with its trailer** (or at the load / unload target of the job) is started. If only the tractor stands there and the trailer somewhere else, the combination is not used. Swapping tractors = park another tractor with a fitting trailer there.

**HUD in AutoDrive style**
- Open / close: **LCtrl + LAlt + J** (rebindable)
- Drag by the green header, position is saved
- Mouse on/off: same key as AutoDrive (default: middle mouse button)
- List of all jobs with level bar, status, trip counter; on/off with one click
- **Groups** (named freely or automatically by building), collapsible; **copy** jobs
- Buildings with the same name get a number ("Cow barn #2")
- Editor with pull-down lists (sorted by distance, AD folders) and +/- counters (mouse wheel = fine steps)
- Mouse over a vehicle or trailer in the world: name, AD park position and its job
- **Send to park**: **LCtrl + LAlt + P** sends the nearest job vehicle around you to its park position and ends its job; the HUD has a park button per job

**Saving**
Jobs and storage assignments are stored in the savegame folder as `autoDriveJobs.xml`, the HUD position and the chosen tab in `modSettings/FS25_AutoDriveJobs.xml`.

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
- If a job reads the wrong storage ("storage at the load target is empty" although there is something in it): the log says which storages were checked. Set the right one in the job under "Storage at …".
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
- **Courseplay-Team / Courseplay team** – FS25_Courseplay, dessen Schnittstelle die Fahrweise „Ablauf“ nutzt / whose interface the "Sequence" mode uses
