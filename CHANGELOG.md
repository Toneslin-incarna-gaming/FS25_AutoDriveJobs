# Changelog – AutoDrive Aufträge / AutoDrive Jobs

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
