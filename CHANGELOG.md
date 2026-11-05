# Changelog – AutoDrive Aufträge / AutoDrive Jobs

## 1.6.2.0

**Neu / New**
- Reiter „Geplant“: je Fahrzeug der laufende Auftrag und die fälligen Aufträge in ihrer Reihenfolge; per Drag & Drop umsortieren, Rechtsklick = als Nächstes, „Auto“ = wieder automatisch
  *"Planned" tab: per vehicle the running job and the due jobs in their order; reorder by drag & drop, right click = next, "Auto" = automatic again*
- Knopf „L#“: Nummern L1, L2 … mit Inhalt über allen Lagern im Spiel; im Auftrag pro Ladeziel ein Lager fest zuordnen („Lager an …“), z. B. bei Heu- und Strohsilos nebeneinander
  *"L#" button: numbers L1, L2 … with contents above every storage in the world; set one storage per load target in the job ("Storage at …"), e.g. hay and straw silos side by side*
- Fahrweise „Ablauf (Courseplay)“: mehrere Schritte aus AD-Ziel und Courseplay-Kurs, optional mit Abladeziel (Ladewagen); Kursdateien werden im Multiplayer automatisch an den Server geschickt
  *"Sequence (Courseplay)" mode: several steps of AD target and Courseplay course, optionally with an unload target (loader wagon); course files are sent to the server automatically in multiplayer*
- Priorität 1–9 je Auftrag / *priority 1–9 per job*
- Mehrere Ladeziele: ist das Lager an einem leer, geht es zum nächsten / *several load targets: if the storage at one is empty, the vehicle goes on to the next*
- Gruppen (auf-/zuklappbar) und Aufträge kopieren; gleichnamige Gebäude bekommen eine Nummer („Kuhstall #2“)
  *groups (collapsible) and copying jobs; buildings with the same name get a number ("Cow barn #2")*
- Maus über Fahrzeug/Anhänger: Name, AD-Parkplatz und Auftrag / *mouse over a vehicle / trailer: name, AD park position and job*

**Geändert / Changed**
- Anderes Ladegut im Anhänger wird vor dem Start bei einem passenden Auftrag abgeliefert
  *another fill type on the trailer is delivered to a fitting job before the start*
- Abladeziel nimmt nichts an: nach 30 s Abbruch, Rest wird anderswo abgeladen / *unload target takes nothing: given up after 30 s, the rest goes elsewhere*
- Ist das Lager an allen Ladezielen leer, startet der Auftrag nicht / *if the storage at all load targets is empty, the job does not start*
- Status „steht seit … s“ mit Ort (Lade-/Abladeziel) / *status "standing for … s" with the place (load / unload target)*
- Beendet AutoDrive die Fahrt zweimal direkt nach dem Start, pausiert der Auftrag mit Hinweis
  *if AutoDrive ends the run twice right after the start, the job pauses with a hint*
- Netzwerkversion 6 – Server und alle Spieler brauchen 1.6.2.0 / *network version 6 – server and all players need 1.6.2.0*

## 1.6.0.0

**Neu / New**
- Regel „Abfuhr“: Start ab Y %, Stopp unter X % – z. B. Milch zur Molkerei; bestehende Aufträge bleiben „Versorgen“
  *Rule "Haul away": start at Y %, stop below X % – e.g. milk to the dairy; existing jobs stay "Supply"*
- Auftrags-Anhänger: Fahrzeug koppelt vor und nach dem Auftrag selbst um / *job trailer: the vehicle swaps trailers by itself before and after the job*
- Mindestpreis für Abfuhr-Aufträge / *minimum price for haul away jobs*
- Lager leer beim Laden: mit Teilladung los, danach parken / *source empty while loading: leave with the partial load, park afterwards*
- Parken schicken: LStrg + LAlt + P und Park-Knopf je Auftrag im HUD / *send to park: LCtrl + LAlt + P and a park button per job in the HUD*

**Geändert / Changed**
- „Abholen und Liefern“ startet auch am Lade- oder Abladeziel; ein voller Anhänger fährt zuerst abladen
  *"Pick up and deliver" also starts at the load or unload target; a full trailer delivers first*
- Parkplatz und Ladeziel dürfen derselbe AD-Punkt sein / *park position and load target may be the same AD target*
- Kein Notabladeplatz bei Abfuhr-Aufträgen / *no emergency unload point for haul away jobs*
- Netzwerkversion 3 / *network version 3*

## 1.5.7.0

**Behoben / Fixed**
- AutoDrive „automatisches Ablade-/Ladeziel“ wird beim Start eines Auftrags am Fahrzeug abgeschaltet – vorher konnte AutoDrive das Auftragsziel durch die bestbezahlte Verkaufsstation ersetzen
  *AutoDrive "automatic unload / pickup target" is switched off when a job starts – before, AutoDrive could replace the job target by the best paying selling station*
- Neue Meldung, wenn am Fahrzeug AutoDrive „Ziele rotieren“ aktiv ist
  *New message when AutoDrive "rotate targets" is active on the vehicle*
- Keine Fahrten mehr mit fast leerem Anhänger, wenn im Lager nur wenig Platz ist
  *No more trips with an almost empty trailer when the storage has little space left*
- Bearbeiten eines Zubringer-Auftrags setzt Warteplatz- und Park-Zustand zurück
  *Editing a feeder job resets its waiting place / parked state*
- Nach einem Auftrag bekommt das Fahrzeug seine AutoDrive-Einstellungen zurück (Modus, Ziele, Ladegut, Rundenzähler)
  *After a job the vehicle gets its AutoDrive settings back (mode, targets, fill type, loop counter)*
- Sauberer Fallback, falls sich AutoDrive intern ändert; Hinweis dazu in der HUD-Kopfzeile
  *Clean fallback if AutoDrive changes internally; hint in the HUD header*

**Performance**
- Beladungsüberwachung alle 250 ms statt in jedem Frame / *loading watch every 250 ms instead of every frame*
- Zielsuche und Lagerlisten werden gecacht / *target lookup and storage lists are cached*
- Keine Dauer-Fahrzeugsuche mehr nach dem Laden eines Spielstands / *no endless vehicle search after loading a savegame*
- Schnellere Textkürzung im HUD / *faster text shortening in the HUD*

**Sonstiges / Other**
- Versionsprüfung im Multiplayer: klare Logmeldung bei unterschiedlichen Mod-Versionen
  *Version check in multiplayer: clear log message if server and client run different versions*
- Alte, ungenutzte Texte und Code entfernt / *old unused texts and code removed*

## 1.5.6.0
- Erste Veröffentlichung auf GitHub / *first release on GitHub*
