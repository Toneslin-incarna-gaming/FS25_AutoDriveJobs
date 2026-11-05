--
-- AutoDrive Jobs (AD-Aufträge)
-- Rule based supply jobs for AutoDrive:
--   "if <fill level of a building> falls below X %, and <vehicle> is standing at its AutoDrive park
--    position, then drive 'pick up and deliver' between <load target> and <unload target> until the
--    level reaches Y % or N trips are done, then park again."
--   Rule direction "empty" (haul away / sell): start at or above Y %, stop below X %.
--   A job can be bound to one trailer; if another one hangs on the vehicle it swaps them first
--   (see AdJobsSwap.lua).
--
-- The rules run on the server. Clients only show the HUD and send changes to the server.
--

ADJobs = {}
ADJobs.MOD_NAME = g_currentModName
ADJobs.MOD_DIR = g_currentModDirectory
-- version comes from modDesc.xml (single source of truth)
ADJobs.VERSION = "1.6.0.0"
do
    local mod = g_modManager ~= nil and g_modManager.getModByName ~= nil and g_modManager:getModByName(g_currentModName)
    if mod ~= nil and mod.version ~= nil then
        ADJobs.VERSION = mod.version
    end
end
ADJobs.NET_VERSION = 6          -- bump whenever the stream layout of the events changes

ADJobs.jobs = {}
ADJobs.orphans = {}              -- deleted jobs whose vehicle is still finishing its trip
ADJobs.nextId = 1
ADJobs.hudVisible = false

ADJobs.CHECK_INTERVAL = 2000     -- ms between two rule checks on the server
ADJobs.SYNC_INTERVAL = 5000      -- ms between two status updates to the clients
ADJobs.WATCH_INTERVAL = 250      -- ms between two checks of the loading / unloading progress of a running job
ADJobs.START_GRACE = 15000       -- ms after a start in which an inactive AD is not seen as "finished"
ADJobs.PARK_DISTANCE = 25        -- m, vehicle must be this close to its park position to be started
ADJobs.STABLE_TIME = 15000       -- ms the watched level must be unchanged before a "load" job starts (no overloading going on)
ADJobs.LOOP_RESTORE_TIMEOUT = 60000 -- ms after loading a savegame in which the loop counter of a vehicle is restored
ADJobs.CONSUMABLES = {DIESEL = true, DEF = true, AIR = true, ELECTRICCHARGE = true, METHANE = true, SILAGE_ADDITIVE = true}

ADJobs.ST_OFF = 0
ADJobs.ST_WAIT = 1
ADJobs.ST_RUN = 2
ADJobs.ST_STOPPING = 3
ADJobs.ST_PAUSE = 4
ADJobs.ST_NOTREADY = 5
ADJobs.ST_ERROR = 6
ADJobs.ST_WAITPLACE = 7    -- feeder stands at its waiting place, parks if nothing changes
ADJobs.ST_TOPARK = 8       -- feeder: nothing changed, drives to the park position
ADJobs.ST_IDLEPARKED = 9   -- feeder parked, starts again only when its level changes
ADJobs.ST_DUMP = 10        -- unloads a rest (too much loaded) at another job / the emergency unload point
ADJobs.ST_SWAP = 11        -- swapping trailers before / after a run (see AdJobsSwap.lua)
ADJobs.ST_SENTPARK = 12    -- the player ended the run (park key / HUD button / AutoDrive taken over), vehicle parks
ADJobs.ST_PRICE = 13       -- haul away: the price at the unload target is below the minimum price of the job
ADJobs.ST_RESTRUN = 15     -- delivers a rest of another fill type (blocks the start) where there is space
ADJobs.ST_STANDING = 14    -- running, but the vehicle stands still (pauseLeft = seconds, msgCode 0/1/2 = on the way / load / unload target)
ADJobs.STAND_SHOW_TIME = 15000   -- ms standing before the list says "stands" instead of "driving"
ADJobs.UNLOAD_STALL_TIME = 30000 -- ms at the unload target with a rest that does not get less -> give up unloading
ADJobs.DELIVER_FIRST_LEVEL = 0.9 -- trailer at least this full with the job's fill type -> deliver first instead of loading
ADJobs.PRICE_CACHE_TIME = 10000 -- ms the price at the unload target is cached
ADJobs.SELL_STATION_RADIUS = 150 -- m, a selling station this close to the unload target counts as "the" target
ADJobs.HAUL_EMPTY_TIME = 5000    -- ms nothing is loaded any more while the source is empty -> drive off with what is loaded
ADJobs.SOURCE_RADIUS = 80        -- m, a storage this close to a load target is "the" source of that target
ADJobs.SOURCE_EMPTY_LEVEL = 100 -- l, a storage at a load target with less than this counts as empty
ADJobs.LOAD_SWITCH_EMPTY_TIME = 4000  -- ms standing at an empty source (known level 0) before the next load target is tried
ADJobs.LOAD_SWITCH_STALL_TIME = 15000 -- ms standing at a load target without anything being loaded before the next one is tried
ADJobs.HAUL_STALL_TIME = 30000   -- ms nothing is loaded and the source does not change -> loading stalled, drive off
ADJobs.PARK_PAUSE_MIN = 10 -- min a job pauses after the player ended it (at least; "pause" of the job if longer)
ADJobs.QUICK_END_TIME = 90000 -- ms; AutoDrive off again this soon after the start without a delivery = "ended right away"
ADJobs.PARK_KEY_RADIUS = 80 -- m, the park key sends the nearest job vehicle within this radius (not the own one) to its park position

-------------------------------------------------------------------------------------------------
-- texts (German / English)
-------------------------------------------------------------------------------------------------

local TEXTS = {
    title = {"AutoDrive Aufträge", "AutoDrive Jobs"},
    on = {"An", "On"},
    off = {"Aus", "Off"},
    edit = {"Ändern", "Edit"},
    noJobs = {"Noch keine Aufträge. Mit '+ Neuer Auftrag' anlegen.", "No jobs yet. Create one with '+ New job'."},
    colTrips = {"Fahrten", "Trips"},
    tripsTotal = {"gesamt %d", "total %d"},
    st0 = {"aus", "off"},
    st1 = {"bereit, Stand ok", "ready, level ok"},
    st2 = {"fährt", "driving"},
    hintMouse = {"Maus an: AutoDrive-Taste 'Maus an/aus'", "mouse on: AutoDrive key 'mouse on/off'"},
    st3 = {"Ziel erreicht, lädt noch ab / fährt zum Parkplatz", "target reached, unloading / driving to park position"},
    st4 = {"Pause noch %d min", "pause, %d min left"},
    st5 = {"wartet", "waiting"},
    st6 = {"Fehler", "error"},
    st7 = {"am Warteplatz, parkt in %d min ohne Änderung", "at waiting place, parks in %d min without change"},
    st8 = {"keine Änderung, fährt zum Parkplatz", "no change, driving to park position"},
    st10 = {"lädt Rest an anderer Stelle ab", "unloading the rest elsewhere"},
    fEmergency = {"Notabladeplatz", "Emergency unload"},
    emergencyNone = {"keiner (mit Rest parken)", "none (park with the rest)"},
    st9 = {"geparkt, startet wieder wenn sich der Füllstand ändert", "parked, starts again when the level changes"},
    msg1 = {"Objekt nicht gefunden", "object not found"},
    msg2 = {"Fahrzeug nicht gefunden", "vehicle not found"},
    msg3 = {"Ladeziel nicht gefunden", "load target not found"},
    msg4 = {"Abladeziel nicht gefunden", "unload target not found"},
    msg5 = {"am Fahrzeug ist kein AD-Parkplatz gesetzt", "no AD park position set for the vehicle"},
    msg6 = {"Fahrzeug steht weder am Parkplatz noch am Lade-/Abladeziel", "vehicle is neither at its park position nor at the load / unload target"},
    msg7 = {"Fahrzeug ist beschäftigt", "vehicle is busy"},
    msg8 = {"kein Anhänger / kein Laderaum", "no trailer / no load space"},
    msg9 = {"Messwert nicht lesbar", "value not readable"},
    msg10 = {"AutoDrive-Start fehlgeschlagen", "AutoDrive start failed"},
    msg11 = {"anderer Auftrag nutzt das Fahrzeug", "another job uses the vehicle"},
    noAD = {"AutoDrive ist nicht geladen", "AutoDrive is not loaded"},
    unlimited = {"unbegrenzt", "unlimited"},
    kindFood = {"Futter", "Food"},
    kindFoodGroup = {"Futtergruppe", "Food group"},
    kindFoodTotal = {"Futter gesamt", "Food total"},
    kindRobot = {"Roboter-Bunker", "Robot bunker"},
    fActive = {"Aktiv", "Active"},
    noTrailer = {"ohne Anhänger", "no trailer"},
    cargoEmpty = {"leer", "empty"},
    attachedTo = {"an %s", "on %s"},
    activeYes = {"Ja - startet automatisch", "yes - starts automatically"},
    activeNo = {"Nein - deaktiviert", "no - deactivated"},
    tipActivate = {"Klick: Auftrag aktivieren", "Click: activate job"},
    tipDeactivate = {"Klick: Auftrag deaktivieren (laufende Fahrt wird beendet, dann parken)", "Click: deactivate job (current trip is finished, then park)"},
    kindStorage = {"Lager", "Storage"},
    wizName = {"Name des Auftrags", "Name of the job"},
    wizSaved = {"Auftrag gespeichert: %s", "Job saved: %s"},
    confirmDelete = {"Auftrag '%s' löschen?", "Delete job '%s'?"},
    msg12 = {"Füllstand ändert sich noch (wird gerade umgeladen)", "level is still changing (transfer in progress)"},
    vehicleTotal = {"Ladung gesamt", "total load"},
    returnAuto = {"automatisch: AD-Ziel, das dem Standort beim Losfahren am nächsten liegt", "automatic: AD target nearest to where the vehicle stood"},
    autoShort = {"auto (Ziel am Standort)", "auto (target where it stood)"},
    limitLoad = {"Start < %d %%", "start < %d %%"},
    line2Load = {"lädt bei %s  ->  Warteplatz %s", "loads at %s  ->  waiting place %s"},
    msg13 = {"Parkplatz nicht gefunden", "park position not found"},
    msg14 = {"kein Fahrzeug hat diesen Parkplatz zugewiesen", "no vehicle has this park position assigned"},
    msg15 = {"zu wenig Platz im Lager", "not enough space in the storage"},
    msg16 = {"Fahrzeug steht nicht am Parkplatz oder Warteplatz", "vehicle is not at its park position or waiting place"},
    msg17 = {"der überwachte Anhänger hängt nicht an diesem Fahrzeug", "the watched trailer is not attached to this vehicle"},
    msg18 = {"angehängtes Gerät passt nicht zum Ladegut", "attached implement does not fit the fill type"},
    msg19 = {"AutoDrive 'Ziele rotieren' am Fahrzeug ausschalten", "turn off AutoDrive 'rotate targets' for this vehicle"},
    hookOff = {"Hinweis: Stopp erst nach der nächsten Fahrt (AutoDrive-Version prüfen)", "note: stop only after the next trip (check AutoDrive version)"},
    -- HUD (AutoDrive style)
    hudNew = {"Neuer Auftrag", "New job"},
    hudEdit = {"Auftrag bearbeiten", "Edit job"},
    fName = {"Name", "Name"},
    fObject = {"Überwacht", "Watched"},
    fMeasure = {"Messwert", "Value"},
    fMode = {"Fahrweise", "Mode"},
    fPark = {"Parkplatz", "Park position"},
    fLoadFt = {"Ladegut", "Fill type"},
    fLoad = {"Ladeziel", "Load target"},
    fUnload = {"Abladeziel", "Unload target"},
    fReturn = {"Warteplatz", "Waiting place"},
    fParkAfter = {"Parken nach", "Park after"},
    parkAfterValue = {"%d min ohne Änderung", "%d min without change"},
    parkNever = {"nie (bleibt am Warteplatz)", "never (stays at waiting place)"},
    fLow = {"Start unter", "Start below"},
    fHigh = {"Stopp ab", "Stop at"},
    fTrips = {"Fahrten max.", "Max. trips"},
    fPause = {"Pause", "Pause"},
    choose = {"bitte wählen", "please choose"},
    modeDeliverShort = {"Abholen und Liefern", "Pick up and deliver"},
    modeLoadShort = {"Laden und zurück (Zubringer)", "Load and return (feeder)"},
    keepFtShort = {"AD-Einstellung behalten", "keep AD setting"},
    grpBuildings = {"Gebäude", "Buildings"},
    grpVehicles = {"Fahrzeuge / Anhänger", "Vehicles / trailers"},
    grpNearest = {"Nächste zum Objekt", "Nearest to the object"},
    grpDefault = {"Standard", "Default"},
    grpAuto = {"Automatisch", "Automatic"},
    atPark = {"steht dort", "parked there"},
    noParks = {"Kein Fahrzeug hat einen AD-Parkplatz. Im AutoDrive-HUD Ziel wählen und Parkplatz zuweisen.", "No vehicle has an AD park position. Choose a target in the AutoDrive HUD and assign the park position."},
    emptyList = {"(keine Einträge)", "(no entries)"},
    save = {"Speichern", "Save"},
    cancel = {"Abbrechen", "Cancel"},
    resetShort = {"Pause/Fehler zurücksetzen", "Reset pause/error"},
    missing = {"Bitte alle rot markierten Felder ausfüllen", "Please fill in all fields marked red"},
    unitMin = {"min", "min"},
    vehicleNone = {"kein Fahrzeug", "no vehicle"},
    -- rule direction (version 1.6)
    st11 = {"koppelt um", "swapping trailer"},
    msg20 = {"Auftrags-Anhänger hängt nicht am Fahrzeug", "job trailer is not attached"},
    msg21 = {"Ankoppeln fehlgeschlagen - steht der Anhänger auf seinem AD-Parkplatz?", "attach failed - is the trailer at its AD park position?"},
    msg22 = {"Umkoppeln abgebrochen (Zeitüberschreitung)", "trailer swap aborted (timeout)"},
    msg23 = {"Auftrags-Anhänger nicht gefunden (verkauft?)", "job trailer not found (sold?)"},
    msg30 = {"Courseplay ist nicht geladen / Fahrzeug kann kein Courseplay", "Courseplay is not loaded / vehicle cannot run Courseplay"},
    msg31 = {"Courseplay-Kurs nicht gefunden", "Courseplay course not found"},
    msg32 = {"Courseplay startet nicht - passendes Gerät angehängt?", "Courseplay does not start - fitting implement attached?"},
    msg33 = {"Courseplay vorzeitig beendet - Ablauf gestoppt", "Courseplay stopped early - sequence stopped"},
    msg34 = {"AD-Ziel des Schritts nicht erreicht", "AD target of the step not reached"},
    msg35 = {"keine Schritte angelegt", "no steps defined"},
    msg36 = {"interner Fehler (siehe log.txt)", "internal error (see log.txt)"},
    fPrio = {"Priorität", "Priority"},
    prioValue = {"%d  (1 = zuerst, 9 = zuletzt)", "%d  (1 = first, 9 = last)"},
    prioShort = {"Prio %d", "prio %d"},
    prioHint = {"Teilen sich Aufträge ein Fahrzeug, kommt die kleinere Zahl zuerst dran; bei gleicher Priorität der dringendste (niedrigster bzw. bei Abfuhr höchster Füllstand). Ein laufender Auftrag wird nicht unterbrochen", "if jobs share a vehicle the smaller number goes first; with the same priority the most urgent one (lowest level, haul away: highest). A running job is not interrupted"},
    msg38 = {"AutoDrive beendet die Fahrt sofort wieder - Ladeziel/Trigger und AD-Meldung prüfen", "AutoDrive ends the run right away - check load target / trigger and the AD message"},
    msg37 = {"Lager am Abladeziel voll - kein Platz für eine weitere Ladung", "storage at the unload target is full - no space for another load"},
    grpCpVehicles = {"in Fahrzeugen geladen", "loaded in vehicles"},
    modeSeqShort = {"Ablauf (Courseplay)", "Sequence (Courseplay)"},
    seqKind = {"Ablauf", "Sequence"},
    seqDrive = {"Schritt %d/%d: fährt zu %s", "step %d/%d: driving to %s"},
    seqCpStart = {"Schritt %d/%d: startet Courseplay", "step %d/%d: starting Courseplay"},
    seqCp = {"Schritt %d/%d: Courseplay %d %%", "step %d/%d: Courseplay %d %%"},
    seqPark = {"alle Schritte erledigt, parkt", "all steps done, parking"},
    seqLimits = {"%d Schritte", "%d steps"},
    seqRuns = {"Durchläufe %d", "runs %d"},
    fStepTarget = {"%d. AD-Ziel", "%d. AD target"},
    fStepCourse = {"%d. CP-Kurs", "%d. CP course"},
    fStepUnload = {"%d. Abladeziel", "%d. Unload target"},
    stepUnloadNone = {"keins (Mähen, Mulchen ...)", "none (mowing, mulching ...)"},
    stepUnloadHint = {"Ladewagen o. ä.: ist er voll, lädt AutoDrive hier ab und übergibt danach wieder an Courseplay (AD-Ziel des Schritts = Übergabepunkt am Feld)", "loader wagon etc.: when full AutoDrive unloads here and hands back to Courseplay (AD target of the step = hand-over point at the field)"},
    seqCpAd = {"Schritt %d/%d: Courseplay %d %% (lädt bei Bedarf ab)", "step %d/%d: Courseplay %d %% (unloads when full)"},
    seqUnload = {"Schritt %d/%d: fährt abladen", "step %d/%d: driving to unload"},
    stepUnloadNeedsTarget = {"Schritt mit Abladeziel braucht ein AD-Ziel am Feld", "a step with an unload target needs an AD target at the field"},
    stepTargetNone = {"keins (Courseplay fährt selbst hin)", "none (Courseplay drives there itself)"},
    stepRemove = {"Schritt %d entfernen", "remove step %d"},
    stepAdd = {"+ Schritt hinzufügen", "+ add step"},
    stepAddHint = {"Jeder Schritt: mit AutoDrive zum Ziel fahren, dann den Courseplay-Kurs abfahren", "every step: drive to the target with AutoDrive, then run the Courseplay course"},
    noCourses = {"Keine Courseplay-Kurse gespeichert (oder Courseplay nicht geladen)", "no Courseplay courses saved (or Courseplay not loaded)"},
    seqHint = {"Aktivieren startet bei Schritt 1; nach dem letzten Schritt parkt das Fahrzeug und der Auftrag schaltet sich aus", "switching on starts at step 1; after the last step the vehicle parks and the job switches itself off"},
    msg29 = {"am Ladeziel wurde nichts geladen - Wegpunkt im Ladetrigger? Ladegut im AD-HUD?", "nothing was loaded at the load target - waypoint inside the load trigger? fill type in the AD HUD?"},
    msg28 = {"Rest im Anhänger: kein Auftrag mit diesem Ladegut hat Platz (Notabladeplatz setzen)", "rest on the trailer: no job with this fill type has space (set an emergency unload point)"},
    st15 = {"liefert Rest ab bei %s", "delivering the rest to %s"},
    msg27 = {"Lager am Ladeziel leer", "storage at the load target is empty"},
    msg26 = {"im Anhänger ist noch anderes Ladegut - erst abladen (oder Notabladeplatz setzen)", "the trailer still holds another fill type - unload it first (or set an emergency unload point)"},
    msg25 = {"Abladeziel nahm die Ladung nicht an - Messwert und Abladestelle prüfen", "unload target did not take the load - check value and unload point"},
    msg24 = {"AD-Parkplatz des Anhängers nicht gefunden", "AD park position of the trailer not found"},
    fDirection = {"Regel", "Rule"},
    dirFill = {"Versorgen: Start unter X %, Stopp ab Y %", "Supply: start below X %, stop at Y %"},
    dirEmpty = {"Abfuhr: Start ab Y %, Stopp unter X %", "Haul away: start at Y %, stop below X %"},
    dirFillShort = {"Versorgen", "Supply"},
    dirEmptyShort = {"Abfuhr", "Haul away"},
    fLowEmpty = {"Stopp unter", "Stop below"},
    fHighEmpty = {"Start ab", "Start at"},
    limitEmpty = {"Start >= %d %%", "start >= %d %%"},
    st12 = {"vom Spieler beendet, Fahrzeug parkt", "ended by the player, vehicle parks"},
    tipPark = {"Klick: Fahrzeug zum Parkplatz schicken, Auftrag beenden", "Click: send vehicle to its park position, end the job"},
    parkSent = {"Auftrag '%s' beendet, %s fährt zum Parkplatz", "job '%s' ended, %s drives to the park position"},
    parkNoVehicle = {"Kein Auftragsfahrzeug im Umkreis von %d m (im Auftrags-HUD: Park-Knopf)", "no job vehicle within %d m (job HUD: park button)"},
    parkNoDest = {"%s hat keinen AutoDrive-Parkplatz", "%s has no AutoDrive park position"},
    st14 = {"steht seit %d s", "standing for %d s"},
    stand1 = {"am Ladeziel", "at the load target"},
    stand2 = {"am Abladeziel - Rest wird nicht angenommen?", "at the unload target - rest not accepted?"},
    st13 = {"wartet auf Preis: %d €/1000 l, Minimum %d", "waiting for price: %d €/1000 l, minimum %d"},
    fMinPrice = {"Mindestpreis", "Minimum price"},
    minPriceOff = {"aus (Preis egal)", "off (any price)"},
    minPriceValue = {"%d € / 1000 l", "%d € / 1000 l"},
    minPriceNow = {"%d € / 1000 l   (aktuell %s)", "%d € / 1000 l   (now %s)"},
    minPriceHint = {"Startet nur, wenn die Verkaufsstelle am Abladeziel mindestens diesen Preis zahlt", "starts only when the selling station at the unload target pays at least this price"},
    priceUnknown = {"?", "?"},
    fExtraLoad = {"Weitere Ladeziele", "More load targets"},
    fLoads = {"Ladeziele", "Load targets"},
    loadsHint = {"Mehrere wählbar: [1] wird zuerst angefahren; ist das Lager dort leer, geht es mit [2], [3] ... weiter", "several possible: [1] is used first; if its storage is empty the vehicle goes on to [2], [3] ..."},
    extraLoadNone = {"keine", "none"},
    extraLoadHint = {"Ist das Lager am Ladeziel leer, fährt das Fahrzeug zum nächsten dieser Ziele weiter (Reihenfolge = Auswahl)", "if the storage at the load target is empty the vehicle goes on to the next of these targets (order = selection)"},
    tipParkAt = {"AD-Parkplatz: %s", "AD park position: %s"},
    tipNoPark = {"kein AD-Parkplatz", "no AD park position"},
    tipJobTrailer = {"Auftrags-Anhänger: %s", "job trailer: %s"},
    tipJobVehicle = {"Auftrag: %s", "job: %s"},
    fGroup = {"Gruppe", "Group"},
    groupAuto = {"automatisch (nach überwachtem Objekt)", "automatic (by watched object)"},
    groupNew = {"+ neue Gruppe ...", "+ new group ..."},
    groupHint = {"Aufträge einer Gruppe werden in der Liste zusammengefasst und lassen sich zuklappen", "jobs of a group are shown together in the list and can be collapsed"},
    grpActive = {"%d/%d an", "%d/%d on"},
    grpRunning = {"%d fahren", "%d driving"},
    grpProblems = {"%d mit Problem", "%d with a problem"},
    srcFixedShort = {"zugeordnet", "set by hand"},
    fSource = {"Lager an %s", "Storage at %s"},
    srcAuto = {"automatisch: %s", "automatic: %s"},
    srcAutoNone = {"automatisch (kein Lager im Umkreis gefunden)", "automatic (no storage found nearby)"},
    srcAutoEntry = {"automatisch (vollstes Lager im Umkreis von %d m)", "automatic (fullest storage within %d m)"},
    srcHint = {"Gilt für alle Aufträge mit diesem Ladeziel. Nummern L1, L2 ... im Spiel anzeigen: Knopf 'L#' oben im HUD", "applies to all jobs with this load target. Show the numbers L1, L2 ... in the world: button 'L#' at the top of the HUD"},
    srcGrpNear = {"in der Nähe", "nearby"},
    srcGrpOther = {"weitere Lager", "other storages"},
    srcEntry = {"%s  -  %s %s  (%d m)", "%s  -  %s %s  (%d m)"},
    srcNoFt = {"lagert kein %s", "does not store %s"},
    tipStorageNums = {"Lager-Nummern im Spiel anzeigen / ausblenden (Zuordnung im Auftrag: 'Lager an ...')", "show / hide storage numbers in the world (assign in the job: 'Storage at ...')"},
    storageEmpty = {"leer", "empty"},
    tabJobs = {"Aufträge (%d)", "Jobs (%d)"},
    tabPlan = {"Geplant (%d)", "Planned (%d)"},
    planEmpty = {"Nichts geplant - gerade ist kein aktiver Auftrag fällig.", "Nothing planned - no active job is due right now."},
    planNoVehicle = {"ohne Fahrzeug", "without vehicle"},
    planNow = {"jetzt", "now"},
    planNext = {"als Nächstes", "next"},
    planManual = {"von Hand sortiert", "sorted by hand"},
    planAuto = {"Auto", "Auto"},
    planCount = {"%d fällig", "%d due"},
    tipPlanAuto = {"Reihenfolge wieder automatisch (Prio, dann Füllstand)", "order automatic again (priority, then level)"},
    tipPlanDrag = {"Ziehen: Reihenfolge ändern  ·  Klick: bearbeiten  ·  Rechtsklick: als Nächstes", "drag: change order  ·  click: edit  ·  right click: next"},
    tipPlanRunning = {"hat das Fahrzeug gerade - nicht verschiebbar", "has the vehicle right now - cannot be moved"},
    tipPlanDrop = {"Loslassen: hier einreihen", "release: queue here"},
    copy = {"Kopieren", "Copy"},
    copySuffix = {"(Kopie)", "(copy)"},
    copied = {"Kopie angelegt - Objekt wählen, anpassen und speichern", "copy created - choose the object, adjust and save"},
    fSwapTrailer = {"Auftrags-Anhänger", "Job trailer"},
    fSwapMarker = {"AD-Parkplatz Auftrags-Anh.", "AD park pos. of job trailer"},
    swapAuto = {"automatisch: %s", "automatic: %s"},
    swapAutoNone = {"automatisch (dem Anhänger ist kein AD-Parkplatz zugewiesen)", "automatic (no AD park position assigned to the trailer)"},
    swapParkHint = {"Parkplatz = AD-Parkplatz des anderen Anhängers (dort steht er, wenn der Auftrags-Anhänger dran ist)", "park position = AD park position of the other trailer (it stays there while the job trailer is on)"},
    swapNone = {"keiner (nicht umkoppeln)", "none (no swap)"},
    swapHint = {"AD-Parkplatz des Anhängers (rückwärts eingeparkt); das Fahrzeug fährt rückwärts an die Deichsel und koppelt an", "AD park position of the trailer (reversed in); the vehicle reverses to the drawbar and attaches"},
    swapMissing = {"Umkoppeln: dem Auftrags-Anhänger in AutoDrive einen Parkplatz zuweisen oder hier wählen (nicht der Parkplatz des Auftrags)", "swap: assign a park position to the job trailer in AutoDrive or choose one here (not the park position of the job)"},
}

local function txt(key, ...)
    local t = TEXTS[key]
    if t == nil then
        return key
    end
    local s = (g_languageShort == "de") and t[1] or t[2]
    if select("#", ...) > 0 then
        return string.format(s, ...)
    end
    return s
end
ADJobs.txt = txt

-------------------------------------------------------------------------------------------------
-- access to AutoDrive (separate script environment)
-------------------------------------------------------------------------------------------------

function ADJobs.resolveAutoDrive()
    if ADJobs.AD ~= nil then
        return true
    end
    if AutoDrive ~= nil and ADGraphManager ~= nil then
        ADJobs.AD = AutoDrive
        ADJobs.GM = ADGraphManager
        ADJobs.installHooks(getfenv(0))
        return true
    end
    local globalEnv = getfenv(0)
    local candidates = {"FS25_AutoDrive"}
    if g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
        for _, mod in ipairs(g_modManager:getActiveMods()) do
            table.insert(candidates, mod.modName)
        end
    end
    for _, modName in ipairs(candidates) do
        local env = globalEnv[modName]
        if type(env) == "table" and env.ADGraphManager ~= nil and env.AutoDrive ~= nil then
            ADJobs.AD = env.AutoDrive
            ADJobs.GM = env.ADGraphManager
            Logging.info("[AD Jobs] AutoDrive gefunden in '%s'", modName)
            ADJobs.installHooks(env)
            return true
        end
    end
    return false
end

--- name -> marker index. Cached; the cache checks itself (renamed / deleted markers are noticed and
--- the cache is rebuilt), so it can never return a wrong index.
local markerByName, markerCacheSource, markerCacheTime = {}, nil, -math.huge
local MARKER_REBUILD_MIN = 1000 -- ms; a name that is not there (deleted target) must not rebuild the cache every lookup

function ADJobs.getMarkerIndexByName(name)
    if name == nil or name == "" or not ADJobs.resolveAutoDrive() then
        return nil
    end
    local markers = ADJobs.GM:getMapMarkers()
    if type(markers) ~= "table" then
        return nil
    end
    local idx = markerByName[name]
    if markerCacheSource ~= markers or idx == nil or markers[idx] == nil or markers[idx].name ~= name then
        if markerCacheSource == markers and idx == nil and g_time - markerCacheTime < MARKER_REBUILD_MIN then
            return nil
        end
        markerByName, markerCacheSource, markerCacheTime = {}, markers, g_time
        for i, marker in pairs(markers) do
            if marker.name ~= nil then
                markerByName[marker.name] = i
            end
        end
        idx = markerByName[name]
    end
    return idx
end

function ADJobs.getMarkerPosition(name)
    local idx = ADJobs.getMarkerIndexByName(name)
    if idx == nil then
        return nil
    end
    local marker = ADJobs.GM:getMapMarkerById(idx)
    local wp = marker ~= nil and ADJobs.GM:getWayPointById(marker.id)
    if wp then
        return wp.x, wp.z
    end
    return nil
end

-------------------------------------------------------------------------------------------------
-- fill level sources of a placeable
-------------------------------------------------------------------------------------------------

local function isStorage(s)
    return type(s) == "table" and type(s.fillLevels) == "table"
end

--- all storages of a placeable (silo, husbandry storage, production point, factory, ...)
--- (cached for a few seconds: the list is needed very often, the specs of a placeable never change)
local storageCache = setmetatable({}, {__mode = "k"})
local STORAGE_CACHE_TIME = 10000

function ADJobs.getStorages(placeable)
    local cached = storageCache[placeable]
    if cached ~= nil and g_time - cached.time < STORAGE_CACHE_TIME then
        return cached.list
    end
    local list, seen = {}, {}
    local function add(s)
        if isStorage(s) and not seen[s] then
            seen[s] = true
            table.insert(list, s)
        end
    end
    for key, spec in pairs(placeable) do
        if type(key) == "string" and key:sub(1, 5) == "spec_" and type(spec) == "table" and key ~= "spec_husbandryFood" then
            add(spec.storage)
            if type(spec.storages) == "table" then
                for _, s in pairs(spec.storages) do
                    add(s)
                end
            end
            if type(spec.productionPoint) == "table" then
                add(spec.productionPoint.storage)
            end
        end
    end
    storageCache[placeable] = {list = list, time = g_time}
    return list
end

local storageFtCache = setmetatable({}, {__mode = "k"})
local STORAGE_FT_CACHE_TIME = 60000

local function storageFillTypes(storage)
    local c = storageFtCache[storage]
    if c ~= nil and g_time - c.time < STORAGE_FT_CACHE_TIME then
        return c.set
    end
    local result = {}
    for ft, _ in pairs(storage.fillLevels) do
        result[ft] = true
    end
    if type(storage.fillTypes) == "table" then
        for k, v in pairs(storage.fillTypes) do
            if type(k) == "number" and v == true then
                result[k] = true
            elseif type(v) == "number" then
                result[v] = true
            end
        end
    end
    storageFtCache[storage] = {set = result, time = g_time}
    return result
end

local function storageCapacity(storage, ft)
    if storage.getCapacity ~= nil then
        local ok, cap = pcall(storage.getCapacity, storage, ft)
        if ok and type(cap) == "number" then
            return cap
        end
    end
    if type(storage.capacities) == "table" and storage.capacities[ft] ~= nil then
        return storage.capacities[ft]
    end
    return storage.capacity or 0
end

local function storageLevel(storage, ft)
    if storage.getFillLevel ~= nil then
        local ok, level = pcall(storage.getFillLevel, storage, ft)
        if ok and type(level) == "number" then
            return level
        end
    end
    return storage.fillLevels[ft] or 0
end

local function getFoodGroups(placeable)
    local spec = placeable.spec_husbandryFood
    if spec == nil or g_currentMission.animalFoodSystem == nil or spec.animalTypeIndex == nil then
        return {}
    end
    local animalFood = g_currentMission.animalFoodSystem:getAnimalFood(spec.animalTypeIndex)
    if animalFood == nil or animalFood.groups == nil then
        return {}
    end
    return animalFood.groups
end

-------------------------------------------------------------------------------------------------
-- bunkers of a feeding robot (e.g. Lely Vector): {fillTypes = {ft, ...}, getLevel(), getCapacity()}
-------------------------------------------------------------------------------------------------

local function numberField(t, names)
    for _, name in ipairs(names) do
        if type(t[name]) == "number" then
            return t[name]
        end
    end
    return nil
end

--- fill types of a robot bunker; accepts {ft = true}, {ft, ft} or a single index
local function spotFillTypes(spot)
    local result, seen = {}, {}
    local function add(ft)
        if type(ft) == "number" and not seen[ft] and g_fillTypeManager:getFillTypeNameByIndex(ft) ~= nil then
            seen[ft] = true
            table.insert(result, ft)
        end
    end
    for _, name in ipairs({"fillTypes", "fillTypeIndices", "supportedFillTypes", "fillTypeIndexes"}) do
        local t = spot[name]
        if type(t) == "table" then
            for k, v in pairs(t) do
                if v == true then
                    add(k)
                elseif type(v) == "number" then
                    add(v)
                elseif type(v) == "table" then
                    add(v.index)
                end
            end
        end
    end
    add(spot.fillTypeIndex)
    add(spot.fillType)
    -- stable order (e.g. straw before straw pellets)
    table.sort(result)
    return result
end

local robotLogged = setmetatable({}, {__mode = "k"})

function ADJobs.getRobotSpots(placeable)
    local spec = placeable.spec_husbandryFeedingRobot
    local robot = spec ~= nil and spec.feedingRobot or nil
    if type(robot) ~= "table" then
        return {}
    end
    local list = robot.unloadingSpots
    if type(list) ~= "table" or type(list[1]) ~= "table" then
        list = nil
        for _, v in pairs(robot) do
            if type(v) == "table" and type(v[1]) == "table" and numberField(v[1], {"fillLevel", "level"}) ~= nil then
                list = v
                break
            end
        end
    end
    local spots = {}
    for i, spot in ipairs(list or {}) do
        if type(spot) == "table" then
            local fts = spotFillTypes(spot)
            table.insert(spots, {
                index = i,
                fillTypes = fts,
                getLevel = function()
                    local level = numberField(spot, {"fillLevel", "level"})
                    if level == nil and robot.getFillLevel ~= nil and fts[1] ~= nil then
                        local ok, l = pcall(robot.getFillLevel, robot, fts[1])
                        level = ok and type(l) == "number" and l or nil
                    end
                    return level
                end,
                getCapacity = function()
                    local cap = numberField(spot, {"capacity", "maxFillLevel", "fillLevelMax"})
                    if cap == nil and robot.getCapacity ~= nil and fts[1] ~= nil then
                        local ok, c = pcall(robot.getCapacity, robot, fts[1])
                        cap = ok and type(c) == "number" and c or nil
                    end
                    return cap
                end,
            })
        end
    end
    -- diagnosis for the log, once per robot, if something could not be read
    if not robotLogged[robot] then
        local problem = #spots == 0
        for _, sp in ipairs(spots) do
            if #sp.fillTypes == 0 or sp.getLevel() == nil or sp.getCapacity() == nil then
                problem = true
            end
        end
        if problem then
            robotLogged[robot] = true
            local keys = {}
            for k, v in pairs(robot) do
                table.insert(keys, tostring(k) .. "=" .. type(v))
            end
            Logging.warning("[AD Jobs] Fütterungsroboter nicht vollständig lesbar. Felder: %s", table.concat(keys, ", "))
            local first = list ~= nil and list[1]
            if type(first) == "table" then
                keys = {}
                for k, v in pairs(first) do
                    table.insert(keys, tostring(k) .. "=" .. (type(v) == "number" and tostring(v) or type(v)))
                end
                Logging.warning("[AD Jobs] Bunker 1: %s", table.concat(keys, ", "))
            end
        end
    end
    return spots
end

function ADJobs.getRobotSpotTitle(spot)
    local names = {}
    for _, ft in ipairs(spot.fillTypes) do
        local fillType = g_fillTypeManager:getFillTypeByIndex(ft)
        table.insert(names, fillType and (fillType.title or fillType.name) or tostring(ft))
        if #names >= 2 then
            break
        end
    end
    if #names == 0 then
        return tostring(spot.index)
    end
    local title = table.concat(names, " / ")
    if #spot.fillTypes > 2 then
        title = title .. " ..."
    end
    return title
end

-------------------------------------------------------------------------------------------------
-- fill level of a vehicle combination (vehicle + everything attached)
-------------------------------------------------------------------------------------------------

function ADJobs.getVehicleUnits(vehicle)
    local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
    local list, seen = {}, {}
    local function add(v)
        if v ~= nil and not seen[v] then
            seen[v] = true
            table.insert(list, v)
        end
    end
    add(root)
    if root.getChildVehicles ~= nil then
        for _, v in pairs(root:getChildVehicles() or {}) do
            add(v)
        end
    end
    return list
end

local function isConsumable(ft)
    local name = g_fillTypeManager:getFillTypeNameByIndex(ft)
    return name ~= nil and ADJobs.CONSUMABLES[name] == true
end

local function unitIsCargo(fillUnit)
    for ft, _ in pairs(fillUnit.supportedFillTypes or {}) do
        if not isConsumable(ft) then
            return true
        end
    end
    return false
end

--- has the vehicle itself (not the combination) a fill unit for cargo?
function ADJobs.hasOwnCargo(v)
    local spec = v.spec_fillUnit
    if spec == nil or spec.fillUnits == nil then
        return false
    end
    for _, fillUnit in ipairs(spec.fillUnits) do
        if unitIsCargo(fillUnit) then
            return true
        end
    end
    return false
end

--- units that are measured for a watched vehicle: the trailer itself;
--- a tractor without own load space (jobs of version 1.2) -> the whole combination
function ADJobs.getMeasureUnits(vehicle)
    if ADJobs.hasOwnCargo(vehicle) then
        return {vehicle}
    end
    return ADJobs.getVehicleUnits(vehicle)
end

--- level, capacity of fill type ftName ("" = all cargo) of a watched vehicle (see getMeasureUnits)
function ADJobs.measureVehicle(vehicle, ftName)
    return ADJobs.measureUnits(ADJobs.getMeasureUnits(vehicle), ftName)
end

--- load space of the driving vehicle: the whole combination
function ADJobs.measureCombination(vehicle, ftName)
    return ADJobs.measureUnits(ADJobs.getVehicleUnits(vehicle), ftName)
end

function ADJobs.measureUnits(units, ftName)
    local ft = nil
    if ftName ~= nil and ftName ~= "" then
        ft = g_fillTypeManager:getFillTypeIndexByName(ftName)
        if ft == nil then
            return nil
        end
    end
    local level, capacity, found = 0, 0, false
    for _, v in ipairs(units) do
        local spec = v.spec_fillUnit
        if spec ~= nil and spec.fillUnits ~= nil then
            for i, fillUnit in ipairs(spec.fillUnits) do
                local supported = fillUnit.supportedFillTypes or {}
                local counts
                if ft ~= nil then
                    counts = supported[ft] == true
                else
                    counts = unitIsCargo(fillUnit)
                end
                if counts then
                    found = true
                    capacity = capacity + (v:getFillUnitCapacity(i) or 0)
                    local unitFt = v:getFillUnitFillType(i)
                    if ft == nil or unitFt == ft then
                        if ft ~= nil or not isConsumable(unitFt) then
                            level = level + (v:getFillUnitFillLevel(i) or 0)
                        end
                    end
                end
            end
        end
    end
    if not found then
        return nil
    end
    return level, capacity
end

--- pallets, big bags, sapling pallets ... are no transport vehicles
local function isPalletLike(v)
    return v.isPallet == true or v.spec_pallet ~= nil or v.spec_bigBag ~= nil or v.spec_treeSaplingPallet ~= nil
end

--- everything that can be filled up: trailers, tankers, loader / mixer wagons, spreaders, sprayers,
--- seeders, planters, front tanks ... (the vehicle itself, attached or not).
--- Not: pallets / big bags / saplings, combines and forage harvesters (filled by harvesting), shovels.
function ADJobs.isTransportVehicle(v)
    if isPalletLike(v) or v.spec_combine ~= nil or v.spec_shovel ~= nil then
        return false
    end
    return ADJobs.hasOwnCargo(v)
end

--- what is loaded right now, e.g. "Gülle 12000 / 20000 l" or "leer"
function ADJobs.getCargoText(vehicle)
    local levels, order = {}, {}
    for _, v in ipairs(ADJobs.getMeasureUnits(vehicle)) do
        local spec = v.spec_fillUnit
        if spec ~= nil and spec.fillUnits ~= nil and not isPalletLike(v) then
            for i, _ in ipairs(spec.fillUnits) do
                local ft = v:getFillUnitFillType(i)
                local level = v:getFillUnitFillLevel(i) or 0
                if ft ~= nil and level > 0.5 and not isConsumable(ft) then
                    if levels[ft] == nil then
                        levels[ft] = 0
                        table.insert(order, ft)
                    end
                    levels[ft] = levels[ft] + level
                end
            end
        end
    end
    local _, capacity = ADJobs.measureVehicle(vehicle, "")
    capacity = capacity or 0
    if capacity < 0 or capacity > 1e8 then
        -- e.g. "unlimited" fill units
        capacity = 0
    end
    if #order == 0 then
        return capacity > 0 and string.format("%s (%d l)", txt("cargoEmpty"), math.floor(capacity)) or txt("cargoEmpty")
    end
    local names, total = {}, 0
    for _, ft in ipairs(order) do
        local fillType = g_fillTypeManager:getFillTypeByIndex(ft)
        table.insert(names, fillType and (fillType.title or fillType.name) or tostring(ft))
        total = total + levels[ft]
    end
    if capacity > 0 then
        return string.format("%s %d / %d l", table.concat(names, ", "), math.floor(total), math.floor(capacity))
    end
    return string.format("%s %d l", table.concat(names, ", "), math.floor(total))
end

function ADJobs.getVehicleCargoFillTypes(vehicle)
    local fts = {}
    for _, v in ipairs(ADJobs.getMeasureUnits(vehicle)) do
        local spec = v.spec_fillUnit
        if spec ~= nil and spec.fillUnits ~= nil then
            for _, fillUnit in ipairs(spec.fillUnits) do
                for ft, _ in pairs(fillUnit.supportedFillTypes or {}) do
                    if not isConsumable(ft) then
                        fts[ft] = true
                    end
                end
            end
        end
    end
    return fts
end

--- the actual measurement (no error handling; see ADJobs.measure)
local function measureImpl(placeable, kind, fillTypeName)
    if kind == "vehicle" then
        return ADJobs.measureVehicle(placeable, fillTypeName)
    elseif kind == "robot" then
        local spot = ADJobs.getRobotSpots(placeable)[tonumber(fillTypeName) or -1]
        if spot == nil then
            return nil
        end
        return spot.getLevel(), spot.getCapacity()
    elseif kind == "food" or kind == "foodGroup" or kind == "foodTotal" then
        local spec = placeable.spec_husbandryFood
        if spec == nil then
            return nil
        end
        local cap = spec.capacity or 0
        if kind == "foodTotal" then
            return placeable:getTotalFood(), cap
        elseif kind == "food" then
            local ft = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
            if ft == nil then
                return nil
            end
            return spec.fillLevels[ft] or 0, cap
        else
            local group = getFoodGroups(placeable)[tonumber(fillTypeName) or -1]
            if group == nil then
                return nil
            end
            local sum = 0
            for _, ft in pairs(group.fillTypes) do
                sum = sum + (spec.fillLevels[ft] or 0)
            end
            return sum, cap
        end
    elseif kind == "storage" then
        local ft = g_fillTypeManager:getFillTypeIndexByName(fillTypeName)
        if ft == nil then
            return nil
        end
        local sumLevel, sumCap, found = 0, 0, false
        for _, storage in ipairs(ADJobs.getStorages(placeable)) do
            if storageFillTypes(storage)[ft] then
                found = true
                sumLevel = sumLevel + storageLevel(storage, ft)
                sumCap = sumCap + storageCapacity(storage, ft)
            end
        end
        if not found then
            return nil
        end
        return sumLevel, sumCap
    end
    return nil
end

--- returns level, capacity or nil if the value can not be read
function ADJobs.measure(placeable, kind, fillTypeName)
    if placeable == nil then
        return nil
    end
    local ok, level, capacity = pcall(measureImpl, placeable, kind, fillTypeName)
    if not ok or level == nil then
        return nil
    end
    return level, capacity
end

function ADJobs.getPercent(level, capacity)
    if level == nil or capacity == nil or capacity <= 0 then
        return -1
    end
    return math.max(0, math.min(100, level / capacity * 100))
end

local function fillTypeTitle(ft)
    local fillType = g_fillTypeManager:getFillTypeByIndex(ft)
    if fillType ~= nil then
        return fillType.title or fillType.name
    end
    return tostring(ft)
end

--- all values that can be watched on a placeable: {kind, fillTypeName, label, candidates = {ft,...}}
function ADJobs.getMeasureOptions(placeable)
    local options = {}
    if placeable.isVehicle or placeable.spec_fillUnit ~= nil or placeable.getRootVehicle ~= nil then
        local fts = ADJobs.getVehicleCargoFillTypes(placeable)
        local list = {}
        for ft, _ in pairs(fts) do
            table.insert(list, ft)
        end
        if #list == 0 then
            return options
        end
        table.sort(list, function(a, b)
            return fillTypeTitle(a) < fillTypeTitle(b)
        end)
        -- fill types that are loaded right now come first
        local loaded = {}
        for _, ft in ipairs(list) do
            local level = ADJobs.measureVehicle(placeable, g_fillTypeManager:getFillTypeNameByIndex(ft))
            if level ~= nil and level > 0 then
                table.insert(loaded, ft)
            end
        end
        local function addFt(ft)
            table.insert(options, {kind = "vehicle", fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(ft), label = fillTypeTitle(ft), candidates = {ft}})
        end
        for _, ft in ipairs(loaded) do
            addFt(ft)
        end
        table.insert(options, {kind = "vehicle", fillTypeName = "", label = txt("vehicleTotal"), candidates = list})
        for _, ft in ipairs(list) do
            if not table.contains(loaded, ft) then
                addFt(ft)
            end
        end
        for _, o in ipairs(options) do
            local level, cap = ADJobs.measureVehicle(placeable, o.fillTypeName)
            local p = ADJobs.getPercent(level, cap)
            if p >= 0 then
                o.label = string.format("%s  (%d %%, %d / %d l)", o.label, math.floor(p + 0.5), math.floor(level), math.floor(cap))
            end
        end
        return options
    end
    -- feeding robot: the components are in the robot bunkers, the trough only gets the mixture
    local robotSpots = ADJobs.getRobotSpots(placeable)
    for _, spot in ipairs(robotSpots) do
        table.insert(options, {kind = "robot", fillTypeName = tostring(spot.index), label = txt("kindRobot") .. ": " .. ADJobs.getRobotSpotTitle(spot), candidates = spot.fillTypes})
    end
    local hasRobot = #robotSpots > 0
    local spec = placeable.spec_husbandryFood
    if spec ~= nil then
        local all = {}
        for ft, _ in pairs(spec.supportedFillTypes or {}) do
            table.insert(all, ft)
        end
        table.sort(all)
        for i, group in ipairs(getFoodGroups(placeable)) do
            local cands = {}
            for _, ft in pairs(group.fillTypes) do
                table.insert(cands, ft)
            end
            local option = {kind = "foodGroup", fillTypeName = tostring(i), label = txt("kindFoodGroup") .. ": " .. tostring(group.title), candidates = cands}
            -- with a robot the trough only holds the mixture: hide empty single components
            if not hasRobot or (ADJobs.measure(placeable, option.kind, option.fillTypeName) or 0) > 0 then
                table.insert(options, option)
            end
        end
        for _, ft in ipairs(all) do
            local option = {kind = "food", fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(ft), label = txt("kindFood") .. ": " .. fillTypeTitle(ft), candidates = {ft}}
            if not hasRobot or (ADJobs.measure(placeable, option.kind, option.fillTypeName) or 0) > 0 then
                table.insert(options, option)
            end
        end
        table.insert(options, {kind = "foodTotal", fillTypeName = "", label = txt("kindFoodTotal"), candidates = all})
    end
    local fts = {}
    for _, storage in ipairs(ADJobs.getStorages(placeable)) do
        for ft, _ in pairs(storageFillTypes(storage)) do
            fts[ft] = true
        end
    end
    local list = {}
    for ft, _ in pairs(fts) do
        table.insert(list, ft)
    end
    table.sort(list, function(a, b)
        return fillTypeTitle(a) < fillTypeTitle(b)
    end)
    for _, ft in ipairs(list) do
        table.insert(options, {kind = "storage", fillTypeName = g_fillTypeManager:getFillTypeNameByIndex(ft), label = txt("kindStorage") .. ": " .. fillTypeTitle(ft), candidates = {ft}})
    end
    for _, o in ipairs(options) do
        local level, cap = ADJobs.measure(placeable, o.kind, o.fillTypeName)
        local p = ADJobs.getPercent(level, cap)
        if p >= 0 then
            o.label = string.format("%s  (%d %%, %d / %d l)", o.label, math.floor(p + 0.5), math.floor(level), math.floor(cap))
        end
    end
    return options
end

function ADJobs.getMeasureLabel(job)
    if job.sourceKind == "vehicle" and (job.fillTypeName == nil or job.fillTypeName == "") then
        return txt("vehicleTotal")
    elseif job.sourceKind == "foodTotal" then
        return txt("kindFoodTotal")
    elseif job.sourceKind == "robot" then
        local plc = ADJobs.findPlaceable(job)
        local spot = plc and ADJobs.getRobotSpots(plc)[tonumber(job.fillTypeName) or -1]
        return txt("kindRobot") .. ": " .. (spot and ADJobs.getRobotSpotTitle(spot) or tostring(job.fillTypeName))
    elseif job.sourceKind == "foodGroup" then
        local plc = ADJobs.findPlaceable(job)
        local group = plc and getFoodGroups(plc)[tonumber(job.fillTypeName) or -1]
        return txt("kindFoodGroup") .. ": " .. (group and tostring(group.title) or job.fillTypeName)
    else
        local ft = g_fillTypeManager:getFillTypeIndexByName(job.fillTypeName or "")
        local title = ft and fillTypeTitle(ft) or (job.fillTypeName or "?")
        -- where the value is read: the same prefix as in the list of values ("Lager: Stroh", "Futter: Heu")
        if job.sourceKind == "storage" then
            return txt("kindStorage") .. ": " .. title
        elseif job.sourceKind == "food" then
            return txt("kindFood") .. ": " .. title
        end
        return title
    end
end

-------------------------------------------------------------------------------------------------
-- finding the objects of a job
-------------------------------------------------------------------------------------------------

function ADJobs.findPlaceable(job)
    if job._plc ~= nil and not job._plc.isDeleted then
        return job._plc
    end
    job._plc = nil
    if job.placeableUid == nil or job.placeableUid == "" then
        return nil
    end
    if job.sourceKind == "vehicle" then
        for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
            if vehicle.getUniqueId ~= nil and vehicle:getUniqueId() == job.placeableUid then
                job._plc = vehicle
                return vehicle
            end
        end
        return nil
    end
    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        if placeable.getUniqueId ~= nil and placeable:getUniqueId() == job.placeableUid then
            job._plc = placeable
            return placeable
        end
    end
    return nil
end

--- name of a building with a number if the farm owns more of the same name ("Kuhstall #2");
--- numbered by the position on the map (west to east, then north to south): buildings do not move, so
--- the number stays the same after loading the savegame (the unique ids may not be there yet right after
--- loading, and their order says nothing to the player)
local labelCache = {time = -math.huge, labels = {}}
function ADJobs.getPlaceableLabel(placeable)
    if placeable == nil then
        return nil
    end
    local name = placeable.getName ~= nil and placeable:getName() or "?"
    if g_time - labelCache.time > 10000 then
        labelCache = {time = g_time, labels = {}}
        local byName = {}
        for _, p in ipairs(g_currentMission.placeableSystem.placeables) do
            if p.getName ~= nil then
                local key = tostring(p:getOwnerFarmId()) .. "|" .. tostring(p:getName())
                byName[key] = byName[key] or {}
                table.insert(byName[key], p)
            end
        end
        for _, list in pairs(byName) do
            if #list >= 2 then
                local pos = {}
                for _, p in ipairs(list) do
                    local x, z = 0, 0
                    if p.rootNode ~= nil and p.rootNode ~= 0 then
                        local px, _, pz = getWorldTranslation(p.rootNode)
                        x, z = math.floor(px + 0.5), math.floor(pz + 0.5)
                    end
                    pos[p] = {x = x, z = z}
                end
                table.sort(list, function(a, b)
                    local pa, pb = pos[a], pos[b]
                    if pa.x ~= pb.x then
                        return pa.x < pb.x
                    end
                    return pa.z < pb.z
                end)
                for i, p in ipairs(list) do
                    labelCache.labels[p] = string.format("%s #%d", tostring(p:getName()), i)
                end
            end
        end
    end
    return labelCache.labels[placeable] or name
end

--- all AD park positions (marker indices) of a root vehicle and the tools attached to it
--- (cached for a moment: asked for every job x every vehicle in one rule check)
local parkIndexCache = setmetatable({}, {__mode = "k"})
local parkListCache = {}
ADJobs.PARK_CACHE_TIME = 1000

--- forget the cached park positions (after the mod changed one itself)
function ADJobs.invalidateParkCache()
    parkIndexCache = setmetatable({}, {__mode = "k"})
    parkListCache = {}
end

function ADJobs.getParkIndices(root)
    if root == nil then
        return {}
    end
    local c = parkIndexCache[root]
    if c ~= nil and g_time - c.time < ADJobs.PARK_CACHE_TIME then
        return c.set
    end
    local set = ADJobs.readParkIndices(root)
    parkIndexCache[root] = {set = set, time = g_time}
    return set
end

function ADJobs.readParkIndices(root)
    local set = {}
    if root.ad ~= nil and root.ad.stateModule ~= nil and ADJobs.resolveAutoDrive() then
        local ok, idx = pcall(ADJobs.AD.GetParkDestination, ADJobs.AD, root)
        if ok and type(idx) == "number" and idx >= 1 then
            set[idx] = true
        end
    end
    for _, v in ipairs(ADJobs.getVehicleUnits(root)) do
        local advd = v.advd
        if advd ~= nil and type(advd.parkDestination) == "number" and advd.parkDestination >= 1 then
            set[advd.parkDestination] = true
        end
    end
    return set
end

--- park position belonging to a watched trailer / implement: its own AD park position,
--- otherwise the one of the vehicle it is attached to (name or nil)
function ADJobs.getParkNameOfObject(obj)
    if obj == nil or not ADJobs.resolveAutoDrive() then
        return nil
    end
    local idx = nil
    if obj.advd ~= nil and type(obj.advd.parkDestination) == "number" and obj.advd.parkDestination >= 1 then
        idx = obj.advd.parkDestination
    else
        local root = obj.getRootVehicle ~= nil and obj:getRootVehicle() or obj
        if root ~= nil and root.ad ~= nil and root.ad.stateModule ~= nil then
            local ok, p = pcall(ADJobs.AD.GetParkDestination, ADJobs.AD, root)
            if ok and type(p) == "number" and p >= 1 then
                idx = p
            end
        end
    end
    local marker = idx ~= nil and ADJobs.GM:getMapMarkerById(idx) or nil
    return marker ~= nil and marker.name or nil
end

--- AD vehicles (root vehicles) that have the park position markerIdx assigned, nearest to it first
function ADJobs.getVehiclesAtPark(markerIdx, farmId)
    if markerIdx == nil or not ADJobs.resolveAutoDrive() then
        return {}
    end
    local key = tostring(markerIdx) .. "|" .. tostring(farmId or 0)
    local c = parkListCache[key]
    if c ~= nil and g_time - c.time < ADJobs.PARK_CACHE_TIME then
        return c.list
    end
    local result = {}
    local marker = ADJobs.GM:getMapMarkerById(markerIdx)
    local wp = marker ~= nil and ADJobs.GM:getWayPointById(marker.id)
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and not vehicle.isDeleted
            and (vehicle.getRootVehicle == nil or vehicle:getRootVehicle() == vehicle)
            and (farmId == nil or farmId == 0 or vehicle:getOwnerFarmId() == farmId) then
            if ADJobs.getParkIndices(vehicle)[markerIdx] then
                local dist = math.huge
                if wp then
                    local x, _, z = getWorldTranslation(vehicle.rootNode)
                    dist = MathUtil.vector2Length(x - wp.x, z - wp.z)
                end
                table.insert(result, {vehicle = vehicle, dist = dist})
            end
        end
    end
    table.sort(result, function(a, b)
        return a.dist < b.dist
    end)
    parkListCache[key] = {list = result, time = g_time}
    return result
end

--- the vehicle of a job: the one that has the job's park position assigned
--- (while a run is going on, the vehicle that was started stays the job's vehicle)
function ADJobs.findVehicle(job)
    local cached = job._veh
    if cached ~= nil and cached.isDeleted then
        cached = nil
        job._veh = nil
    end
    -- during a run, a trailer swap and the time the swapped trailer is on board the vehicle stays fixed
    -- (with the job trailer attached the park position may only be known through the other trailer)
    if cached ~= nil and (job.running or job.swap ~= nil or (job.returnTrailerUid or "") ~= "" or job.parkMarker == nil or job.parkMarker == "") then
        return cached
    end
    if cached == nil and (job.returnTrailerUid or "") ~= "" then
        -- savegame loaded with the swapped trailer on board: the vehicle that carries the job trailer,
        -- otherwise the vehicle of the last run
        local trailer = ADJobs.getSwapTrailer(job)
        local v = trailer ~= nil and trailer.getAttacherVehicle ~= nil and trailer:getAttacherVehicle() or nil
        if v ~= nil and v.getRootVehicle ~= nil then
            v = v:getRootVehicle()
        end
        if v == nil or v.ad == nil then
            v = ADJobs.getVehicleByUid(job.vehicleUid)
        end
        if v ~= nil and v.ad ~= nil then
            job._veh = v
            job.vehicleUid = v.getUniqueId and v:getUniqueId() or job.vehicleUid
            job.vehicleName = ADJobs.getVehicleName(v)
            return v
        end
    end
    if job.parkMarker ~= nil and job.parkMarker ~= "" then
        local idx = ADJobs.getMarkerIndexByName(job.parkMarker)
        local list = ADJobs.getVehiclesAtPark(idx, job.farmId)
        local chosen = nil
        -- 1. at the park position, idle, right implement 2. at the park position and idle 3. nearest
        for _, e in ipairs(list) do
            if e.dist <= ADJobs.PARK_DISTANCE and not e.vehicle.ad.stateModule:isActive() and ADJobs.checkImplement(job, e.vehicle) == 0 then
                chosen = e.vehicle
                break
            end
        end
        if chosen == nil then
            for _, e in ipairs(list) do
                if e.dist <= ADJobs.PARK_DISTANCE and not e.vehicle.ad.stateModule:isActive() then
                    chosen = e.vehicle
                    break
                end
            end
        end
        if chosen == nil then
            -- not at the park position: the one with the right implement (e.g. the watched trailer)
            for _, e in ipairs(list) do
                if ADJobs.checkImplement(job, e.vehicle) == 0 then
                    chosen = e.vehicle
                    break
                end
            end
        end
        if chosen == nil and list[1] ~= nil then
            chosen = list[1].vehicle
        end
        job._veh = chosen
        if chosen ~= nil then
            job.vehicleUid = chosen.getUniqueId and chosen:getUniqueId() or job.vehicleUid
            job.vehicleName = ADJobs.getVehicleName(chosen)
        else
            job.vehicleName = ""
        end
        return chosen
    end
    -- jobs from version 1.1 without park position: fixed vehicle
    if job.vehicleUid == nil or job.vehicleUid == "" then
        return nil
    end
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle.getUniqueId ~= nil and vehicle:getUniqueId() == job.vehicleUid then
            job._veh = vehicle
            return vehicle
        end
    end
    return nil
end

--- jobs from version 1.1: take over the park position that is set at the vehicle
function ADJobs.migrateParkMarker(job)
    if (job.parkMarker or "") ~= "" or (job.vehicleUid or "") == "" or not ADJobs.resolveAutoDrive() then
        return
    end
    local vehicle = ADJobs.findVehicle(job)
    if vehicle == nil then
        return
    end
    local ok, idx = pcall(ADJobs.AD.GetParkDestination, ADJobs.AD, vehicle)
    local marker = ok and idx ~= nil and ADJobs.GM:getMapMarkerById(idx)
    if marker and marker.name ~= nil then
        job.parkMarker = marker.name
        job.farmId = job.farmId or vehicle:getOwnerFarmId()
        Logging.info("[AD Jobs] Auftrag %d '%s': Parkplatz '%s' übernommen", job.id, tostring(job.name), marker.name)
    end
end

--- names of everything attached to a vehicle (trailers, tools), e.g. "Krampe Bandit 750"
function ADJobs.getImplementNames(vehicle)
    local names = {}
    if vehicle == nil then
        return names
    end
    for i, v in ipairs(ADJobs.getVehicleUnits(vehicle)) do
        if i > 1 and v ~= vehicle then
            local name = v.getFullName ~= nil and v:getFullName() or nil
            if name ~= nil and name ~= "" then
                table.insert(names, name)
            end
        end
    end
    return names
end

--- "+ Krampe Bandit 750" or "ohne Anhänger"
function ADJobs.getImplementText(vehicle)
    local names = ADJobs.getImplementNames(vehicle)
    if #names == 0 then
        return txt("noTrailer"), false
    end
    return "+ " .. table.concat(names, ", "), true
end

local vehicleByUid = {}
local vehicleByUidMiss = {} -- PERF: uid -> g_time of the last failed lookup (negative cache)
ADJobs.UID_MISS_CACHE_MS = 5000
--- vehicle with this unique id (cached; works on clients too)
function ADJobs.getVehicleByUid(uid)
    if uid == nil or uid == "" then
        return nil
    end
    local v = vehicleByUid[uid]
    if v ~= nil and not v.isDeleted then
        return v
    end
    vehicleByUid[uid] = nil
    -- PERF: a uid that does not resolve (trailer sold, id changed between sessions) was looked up 5-10 times per
    -- rule check, each time a full scan over all vehicles. Remember the miss for a few seconds.
    local missTime = vehicleByUidMiss[uid]
    if missTime ~= nil and g_time ~= nil and g_time - missTime < ADJobs.UID_MISS_CACHE_MS then
        return nil
    end
    local vs = g_currentMission.vehicleSystem
    -- the game's own lookup first (FS25), then the list
    if vs ~= nil and vs.getVehicleByUniqueId ~= nil then
        local ok, found = pcall(vs.getVehicleByUniqueId, vs, uid)
        if ok and type(found) == "table" and not found.isDeleted then
            vehicleByUid[uid] = found
            return found
        end
    end
    for _, vehicle in ipairs(vs.vehicles) do
        local vuid = vehicle.getUniqueId ~= nil and vehicle:getUniqueId() or vehicle.uniqueId
        if vuid ~= nil and tostring(vuid) == tostring(uid) then
            vehicleByUid[uid] = vehicle
            vehicleByUidMiss[uid] = nil
            return vehicle
        end
    end
    vehicleByUidMiss[uid] = g_time or 0
    return nil
end

--- writes the vehicles of the farm with their unique ids to the log (to find out why a lookup failed)
--- PERF: the same reason is written at most once per minute - the rule check repeats a failed lookup every 2 s,
--- which used to produce up to 61 log lines each time on the server
local lastIdsLog = {}
ADJobs.IDS_LOG_REPEAT_MS = 60000
function ADJobs.logVehicleIds(reason)
    local key = tostring(reason)
    local last = lastIdsLog[key]
    if last ~= nil and g_time ~= nil and g_time - last < ADJobs.IDS_LOG_REPEAT_MS then
        return
    end
    lastIdsLog[key] = g_time or 0
    Logging.info("[AD Jobs] %s - Fahrzeuge:", tostring(reason))
    local n = 0
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        local uid = vehicle.getUniqueId ~= nil and vehicle:getUniqueId() or vehicle.uniqueId
        local name = vehicle.getFullName ~= nil and vehicle:getFullName() or "?"
        Logging.info("[AD Jobs]    %s  uid=%s  farm=%s", tostring(name), tostring(uid), tostring(vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or "?"))
        n = n + 1
        if n >= 60 then
            break
        end
    end
end

function ADJobs.getVehicleName(vehicle)
    if vehicle == nil then
        return "?"
    end
    local name = vehicle.getFullName and vehicle:getFullName() or "?"
    if vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle.ad.stateModule.getName ~= nil then
        local adName = vehicle.ad.stateModule:getName()
        if adName ~= nil and adName ~= "" then
            name = adName .. " - " .. name
        end
    end
    return name
end

function ADJobs.getJobById(id)
    for i, job in ipairs(ADJobs.jobs) do
        if job.id == id then
            return job, i
        end
    end
    return nil
end

-------------------------------------------------------------------------------------------------
-- server: changes from clients
-------------------------------------------------------------------------------------------------

local CONFIG_FIELDS = {"name", "active", "driveMode", "direction", "placeableUid", "placeableName", "sourceKind", "fillTypeName", "loadFillTypeName",
    "low", "high", "maxTrips", "pauseMin", "vehicleUid", "vehicleName", "loadMarker", "unloadMarker", "parkMarker", "farmId", "emergencyMarker",
    "swapTrailerUid", "swapTrailerName", "swapMarker", "minPrice", "group", "extraLoadMarkers", "steps", "prio"}

ADJobs.PRIO_DEFAULT = 5   -- 1 = most important ... 9 = least important

--- priority of a job (1..9, smaller = first)
function ADJobs.getPrio(job)
    local p = tonumber(job.prio) or ADJobs.PRIO_DEFAULT
    return math.max(1, math.min(9, math.floor(p)))
end

--- stops the AutoDrive run of a job after the current delivery (vehicle parks afterwards)
function ADJobs.requestStop(job)
    if ADJobs.hooksInstalled then
        -- the decision is made right after the next unloading (see ADJobs.beforeNextTask)
        return
    end
    if job.driveMode == "load" then
        -- a load run is a single trip, AutoDrive finishes it by itself
        return
    end
    local vehicle = ADJobs.findVehicle(job)
    if vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule:isActive() then
        local sm = vehicle.ad.stateModule
        sm:setLoopCounter(math.max(sm:getLoopsDone() or 0, 1))
        sm:raiseDirtyFlag()
        -- swapped trailer on board: AutoDrive parks at its stand, not at the park position (the other trailer stands there)
        ADJobs.redirectParkForSwap(job, vehicle)
    end
end

function ADJobs.applyChange(op, data)
    if g_server == nil then
        return
    end
    if op == ADJChangeEvent.OP_SAVE then
        if data.placeableObject ~= nil and data.placeableObject.getUniqueId ~= nil then
            data.placeableUid = data.placeableObject:getUniqueId()
            if data.sourceKind == "vehicle" then
                data.placeableName = ADJobs.getVehicleName(data.placeableObject)
            else
                data.placeableName = ADJobs.getPlaceableLabel(data.placeableObject) or data.placeableName
            end
        end
        if data.vehicleObject ~= nil and data.vehicleObject.getUniqueId ~= nil then
            data.vehicleUid = data.vehicleObject:getUniqueId()
            data.vehicleName = ADJobs.getVehicleName(data.vehicleObject)
        end
        if (data.parkMarker or "") ~= "" then
            local list = ADJobs.getVehiclesAtPark(ADJobs.getMarkerIndexByName(data.parkMarker), data.farmId)
            if list[1] ~= nil then
                data.vehicleUid = list[1].vehicle.getUniqueId and list[1].vehicle:getUniqueId() or ""
                data.vehicleName = ADJobs.getVehicleName(list[1].vehicle)
            end
        end
        local job = ADJobs.getJobById(data.id)
        if job == nil then
            job = {id = ADJobs.nextId, state = ADJobs.ST_WAIT, msgCode = 0, percent = -1, level = 0, capacity = 0, tripsDone = 0, pauseLeft = 0}
            ADJobs.nextId = ADJobs.nextId + 1
            table.insert(ADJobs.jobs, job)
        end
        if job.seq ~= nil then
            -- a running sequence is stopped (steps may have changed); it starts again at step 1
            ADJobs.stopSequence(job, job._veh, nil, false)
        end
        local vehicleChanged = job.vehicleUid ~= data.vehicleUid or job.parkMarker ~= data.parkMarker
        if vehicleChanged and job.running then
            ADJobs.requestStop(job)
            ADJobs.finishRun(job)
        end
        for _, key in ipairs(CONFIG_FIELDS) do
            job[key] = data[key]
        end
        job.direction = job.direction == "empty" and "empty" or "fill"
        job._plc = nil
        job._veh = nil
        job.pauseUntil = nil
        job.seqResume, job.seqError = nil, nil
        -- a trailer swap that is going on is dropped (the vehicle just finishes its current AD drive);
        -- returnTrailerUid stays so the other trailer still comes back on after the next run
        job.swap = nil
        if not ADJobs.usesSwap(job) then
            ADJobs.clearSwapCycle(job, job._veh)
        end
        -- the settings changed: forget the waiting place / idle parking state of a feeder and the
        -- "level is stable" timer, otherwise a parked feeder would wait for a level change forever
        job.waitSince, job.waitLevel, job.idleParkLevel, job._waitVehicle = nil, nil, nil, nil
        job.stableSince, job.lastLevel = g_time, nil
        Logging.info("[AD Jobs] Auftrag %d '%s' gespeichert", job.id, tostring(job.name))
    elseif op == ADJChangeEvent.OP_DELETE then
        local job, index = ADJobs.getJobById(data.id)
        if job ~= nil then
            if job.running then
                ADJobs.requestStop(job)
                -- the vehicle finishes its trip and parks by itself (loop counter runs out);
                -- give it its AutoDrive settings back as soon as it stands still
                table.insert(ADJobs.orphans, job)
            end
            table.remove(ADJobs.jobs, index)
        end
    elseif op == ADJChangeEvent.OP_TOGGLE then
        local job = ADJobs.getJobById(data.id)
        if job ~= nil then
            job.active = not job.active
            job.pauseUntil = nil
            if job.driveMode == "sequence" then
                -- switching a sequence on starts it again with step 1 (off: stopped in updateSequence)
                if job.active then
                    job.seqResume, job.seqError = nil, nil
                end
            elseif not job.active and job.running then
                ADJobs.requestStop(job)
                job.state = ADJobs.ST_STOPPING
            end
        end
    elseif op == ADJChangeEvent.OP_PARK then
        local job = ADJobs.getJobById(data.id)
        local vehicle = data.vehicleObject
        if vehicle ~= nil and vehicle.getRootVehicle ~= nil then
            vehicle = vehicle:getRootVehicle()
        end
        if job == nil and vehicle ~= nil then
            job = ADJobs.findJobOfVehicle(vehicle)
        end
        if job ~= nil then
            ADJobs.endJobAndPark(job, vehicle)
        elseif vehicle ~= nil then
            ADJobs.parkVehicle(nil, vehicle)
        end
    elseif op == ADJChangeEvent.OP_REORDER then
        ADJobs.applyPlanOrder(data.planIds)
    elseif op == ADJChangeEvent.OP_SOURCE then
        ADJobs.setMarkerSource(data.loadMarker, data.placeableUid)
        local e = ADJobs.getStorageByUid(data.placeableUid)
        Logging.info("[AD Jobs] Ladeziel '%s': Lager %s", tostring(data.loadMarker), e ~= nil and ADJobs.getStorageTitle(e) or "automatisch")
    elseif op == ADJChangeEvent.OP_RESET then
        local job = ADJobs.getJobById(data.id)
        if job ~= nil then
            job.pauseUntil = nil
            job.msgCode = 0
            job.stuckWarn = nil
            job.stuckLoadWarn = nil
            job.quickEndWarn, job._quickEnds, job._quickEndSince = nil, nil, nil
            if job.swap ~= nil then
                -- a stuck swap is dropped too; the rule decides afresh in the next tick
                job.swap = nil
                job.state = job.active and ADJobs.ST_WAIT or ADJobs.ST_OFF
            end
        end
    end
    ADJobs.lastSyncKey = nil
    ADJobs.sendSync()
end

function ADJobs.sendSync()
    if g_server ~= nil and g_server.broadcastEvent ~= nil then
        g_server:broadcastEvent(ADJSyncEvent.new(ADJobs.jobs), false)
    end
end

-------------------------------------------------------------------------------------------------
-- server: decision right after every unloading ("pick up and deliver")
--   AutoDrive decides at the end of an unloading whether it drives to the load target again.
--   Exactly there the job measures the level again and decides:
--     below "stop at"  -> one more trip
--     "stop at" reached / job off / trips used up -> next open job of this vehicle, otherwise park
-------------------------------------------------------------------------------------------------

function ADJobs.installHooks(env)
    if ADJobs.hooksInstalled or env == nil then
        return
    end
    local PDM = env.PickupAndDeliverMode
    if type(PDM) ~= "table" or type(PDM.getNextTask) ~= "function" or PDM.STATE_DELIVER_TO_NEXT_TARGET == nil
        or PDM.STATE_PICKUP == nil or PDM.STATE_PICKUP_FROM_NEXT_TARGET == nil then
        Logging.warning("[AD Jobs] PickupAndDeliverMode nicht (vollständig) gefunden - Stopp erst nach der nächsten Fahrt")
        return
    end
    ADJobs.PDM = PDM
    local original = PDM.getNextTask
    PDM.getNextTask = function(mode, ...)
        if g_server ~= nil then
            local ok, err = pcall(ADJobs.beforeNextTask, mode)
            if not ok then
                Logging.warning("[AD Jobs] Entscheidung nach dem Abladen fehlgeschlagen: %s", tostring(err))
            end
        end
        return original(mode, ...)
    end
    ADJobs.hooksInstalled = true
    Logging.info("[AD Jobs] Entscheidung nach dem Abladen aktiv")
end

local function getRunningJobOfVehicle(vehicle)
    for _, job in ipairs(ADJobs.jobs) do
        if (job.running or job.swap ~= nil) and job._veh == vehicle then
            return job
        end
    end
    return nil
end

local function freshPercent(job)
    local placeable = ADJobs.findPlaceable(job)
    local level, capacity = ADJobs.measure(placeable, job.sourceKind, job.fillTypeName)
    return ADJobs.getPercent(level, capacity), level, capacity
end

--- does the level ask for a run?   fill: below "low"   empty (haul away): at / above "high"
function ADJobs.needsRun(job, percent)
    local p = percent or job.percent or -1
    if p < 0 then
        return false
    end
    if job.direction == "empty" then
        return p >= (job.high or 100)
    end
    return p < (job.low or 0)
end

--- is the stop level reached?   fill: at / above "high"   empty: at / below "low"
function ADJobs.targetReached(job, percent)
    local p = percent or job.percent or -1
    if p < 0 then
        return false
    end
    if job.direction == "empty" then
        return p <= (job.low or 0)
    end
    return p >= (job.high or 100)
end

--- how urgent is a job (lower = more urgent), comparable between jobs of both directions
function ADJobs.urgency(job, percent)
    local p = percent or job.percent or -1
    if job.direction == "empty" then
        return 100 - p
    end
    return p
end

--- may this vehicle drive the job? (park position of the job is assigned to it)
function ADJobs.vehicleServesJob(vehicle, job)
    -- in the middle of a trailer swap cycle the park position of the vehicle is redirected: the vehicle
    -- that carries the job trailer is the one
    if (job.returnTrailerUid or "") ~= "" and job._veh == vehicle then
        return true
    end
    if (job.parkMarker or "") ~= "" then
        local idx = ADJobs.getMarkerIndexByName(job.parkMarker)
        if idx == nil or not ADJobs.getParkIndices(vehicle)[idx] then
            return false
        end
        return job.farmId == nil or job.farmId == 0 or vehicle:getOwnerFarmId() == job.farmId
    end
    return (job.vehicleUid or "") ~= "" and vehicle.getUniqueId ~= nil and vehicle:getUniqueId() == job.vehicleUid
end

--- most urgent open "pick up and deliver" job this vehicle can drive next
function ADJobs.findChainJob(current, vehicle)
    local best, bestUrgency = nil, math.huge
    for _, job in ipairs(ADJobs.jobs) do
        if job ~= current and job.active and not job.running and job.swap == nil and job.driveMode ~= "load"
            and (job.pauseUntil == nil or g_time >= job.pauseUntil)
            and ADJobs.vehicleServesJob(vehicle, job)
            and ADJobs.getMarkerIndexByName(job.loadMarker) ~= nil and ADJobs.getMarkerIndexByName(job.unloadMarker) ~= nil then
            local p = freshPercent(job)
            local free = ADJobs.getFreeSpace(job)
            local enoughSpace = free == nil or free >= ADJobs.getMinLoad(job, vehicle)
            -- checkImplement: a job bound to another trailer is never chained (the vehicle would have to swap first)
            -- order of the plan: by hand sorted first, then priority (1 before 9), then the most urgent level
            local u = ADJobs.planKey(job, p)
            if ADJobs.needsRun(job, p) and u < bestUrgency and enoughSpace and ADJobs.priceOk(job) and ADJobs.checkImplement(job, vehicle) == 0 then
                best, bestUrgency = job, u
            end
        end
    end
    return best
end

-------------------------------------------------------------------------------------------------
-- server: plan ("Geplant" tab) - per vehicle the job(s) it drives right now and the jobs that are due,
-- in the order they get the vehicle. The player can sort the due jobs by hand (drag & drop in the HUD):
-- job.planOrder 1..n comes before the automatic order (priority, then level). A job loses its place by
-- hand once it runs or is no longer due; jobs that become due later queue up behind the sorted ones.
-------------------------------------------------------------------------------------------------

ADJobs.PLAN_MANUAL_BASE = -100000

--- sort key of a job (lower = first): order by hand, then priority, then the most urgent level
function ADJobs.planKey(job, percent)
    if (job.planOrder or 0) > 0 then
        return ADJobs.PLAN_MANUAL_BASE + job.planOrder
    end
    local p = percent or job.percent or -1
    return ADJobs.getPrio(job) * 1000 + (p >= 0 and ADJobs.urgency(job, p) or 500)
end

--- the job has the vehicle right now (run, trailer swap or delivery of a foreign rest)
function ADJobs.isPlanCurrent(job)
    return job.running == true or job.swap ~= nil or job.restRun ~= nil
end

--- the job is due and waits for its turn
function ADJobs.isPlanQueued(job)
    if not job.active or ADJobs.isPlanCurrent(job) then
        return false
    end
    if job.driveMode == "sequence" then
        -- a sequence that is switched on waits for its vehicle
        return true
    end
    return ADJobs.needsRun(job)
end

local function planVehicleOf(job)
    if job.restRun ~= nil and job.restRun.vehicle ~= nil and not job.restRun.vehicle.isDeleted then
        return job.restRun.vehicle
    end
    if ADJobs.isPlanCurrent(job) and job._veh ~= nil and not job._veh.isDeleted then
        return job._veh
    end
    return ADJobs.findVehicle(job)
end

--- fills job.planPos (1.. per vehicle, 0 = not planned), job.planCur, job.planVeh / planVehName
function ADJobs.computePlan()
    local groups, order = {}, {}
    for i, job in ipairs(ADJobs.jobs) do
        local cur = ADJobs.isPlanCurrent(job)
        local queued = not cur and ADJobs.isPlanQueued(job)
        if job.running or (not cur and not queued) then
            -- its turn has come (or it is not due any more): the place by hand is used up
            job.planOrder = nil
        end
        job.planPos, job.planCur = 0, cur
        if cur or queued then
            local vehicle = planVehicleOf(job)
            local key, name = "", ""
            if vehicle ~= nil then
                key = vehicle.getUniqueId ~= nil and tostring(vehicle:getUniqueId()) or tostring(vehicle)
                name = ADJobs.getVehicleName(vehicle)
            end
            local g = groups[key]
            if g == nil then
                g = {key = key, name = name, list = {}}
                groups[key] = g
                table.insert(order, g)
            end
            table.insert(g.list, {job = job, i = i, cur = cur, k = cur and -1e9 or ADJobs.planKey(job)})
        end
    end
    for _, g in ipairs(order) do
        table.sort(g.list, function(a, b)
            if a.k ~= b.k then
                return a.k < b.k
            end
            return a.i < b.i
        end)
        for n, e in ipairs(g.list) do
            e.job.planPos = n
            e.job.planVeh = g.key
            e.job.planVehName = g.name
        end
    end
end

--- client asked for a new order of the due jobs of one vehicle ("R..." = back to the automatic order)
function ADJobs.applyPlanOrder(list)
    list = tostring(list or "")
    local reset = list:sub(1, 1) == "R"
    local n = 0
    for s in list:gmatch("%d+") do
        local job = ADJobs.getJobById(tonumber(s))
        if job ~= nil then
            if reset then
                job.planOrder = nil
            elseif not job.running then
                n = n + 1
                job.planOrder = n
            end
        end
    end
    ADJobs.computePlan()
    Logging.info("[AD Jobs] Geplante Reihenfolge %s: %s", reset and "zurückgesetzt" or "geändert", list)
end

--- hands the running AutoDrive run of vehicle over from job to nextJob
function ADJobs.chainTo(job, nextJob, vehicle)
    local sm = vehicle.ad.stateModule
    job.running = false
    job._parking = nil
    job._dumping, job._dumpTried = nil, nil
    nextJob._dumping, nextJob._dumpTried, nextJob._lastTrip, nextJob._watch = nil, nil, nil, nil
    job.state = job.active and ADJobs.ST_WAIT or ADJobs.ST_OFF
    job.msgCode = 0

    ADJobs.disableAutomaticTargets(sm)
    sm:setFirstMarker(ADJobs.getMarkerIndexByName(nextJob.loadMarker))
    sm:setSecondMarker(ADJobs.getMarkerIndexByName(nextJob.unloadMarker))
    if nextJob.loadFillTypeName ~= nil and nextJob.loadFillTypeName ~= "" then
        local ft = g_fillTypeManager:getFillTypeIndexByName(nextJob.loadFillTypeName)
        if ft ~= nil then
            sm:setFillType(ft)
        end
    end
    sm:setLoopsDone(0)
    sm:setLoopCounter(1)
    sm:raiseDirtyFlag()

    -- the AutoDrive settings of the vehicle from before the first job are handed on and restored at the end
    nextJob.savedLoopCounter = job.savedLoopCounter
    nextJob.savedFirst, nextJob.savedSecond, nextJob.savedFillType, nextJob.savedMode = job.savedFirst, job.savedSecond, job.savedFillType, job.savedMode
    job.savedFirst, job.savedSecond, job.savedFillType, job.savedMode = nil, nil, nil, nil
    nextJob.savedRotate, nextJob._rotateVehicle = job.savedRotate, job._rotateVehicle
    job.savedRotate, job._rotateVehicle = nil, nil
    -- a swapped trailer goes back on only when the whole chain is done; the swap stands of the first
    -- job are handed on (the next job may have no swap config of its own)
    if (job.returnTrailerUid or "") ~= "" then
        nextJob.returnTrailerUid = job.returnTrailerUid
        nextJob._swapFrom = job._swapFrom or job
        job.returnTrailerUid = ""
    end
    nextJob._veh = vehicle
    nextJob.vehicleUid = vehicle.getUniqueId and vehicle:getUniqueId() or nextJob.vehicleUid
    nextJob.vehicleName = ADJobs.getVehicleName(vehicle)
    nextJob.running = true
    nextJob._parking = nil
    nextJob.startTime = g_time
    nextJob.tripsDone = 0
    nextJob.pauseUntil = nil
    nextJob.state, nextJob.msgCode = ADJobs.ST_RUN, 0
    ADJobs.lastSyncKey = nil
    Logging.info("[AD Jobs] Auftrag %d '%s' fertig nach %d Fahrten, %s fährt weiter mit Auftrag %d '%s'",
        job.id, tostring(job.name), job.tripsDone, ADJobs.getVehicleName(vehicle), nextJob.id, tostring(nextJob.name))
end

--- free liters at the watched object (nil if unknown)
function ADJobs.getFreeSpace(job)
    if job.direction == "empty" then
        -- haul away: the watched object is the source. A selling point takes everything (nil = unlimited);
        -- a storage at the unload target (other silo, production ...) only takes what fits
        return ADJobs.getTargetFreeSpace(job)
    end
    local placeable = ADJobs.findPlaceable(job)
    local level, capacity = ADJobs.measure(placeable, job.sourceKind, job.fillTypeName)
    if level == nil or capacity == nil or capacity <= 0 then
        return nil
    end
    return math.max(0, capacity - level)
end

--- haul away: free liters for the job's fill type in the storage at the unload target (the emptiest fitting
--- storage within SOURCE_RADIUS, the watched building itself not counted); nil = no storage there (selling
--- point / unknown -> unlimited). Cached for a few seconds.
local targetFreeCache = {}
function ADJobs.getTargetFreeSpace(job)
    local markerName = job.unloadMarker
    local ftName = (job.loadFillTypeName or "") ~= "" and job.loadFillTypeName or job.fillTypeName
    local ft = g_fillTypeManager:getFillTypeIndexByName(ftName or "")
    if (markerName or "") == "" or ft == nil then
        return nil
    end
    local source = ADJobs.findPlaceable(job)
    local fixedUid = ADJobs.markerSources[markerName]
    local fixed = ADJobs.getStorageByUid(fixedUid)
    local key = markerName .. "|" .. tostring(ft) .. "|" .. tostring(job.placeableUid) .. "|" .. tostring(fixedUid or "")
    local c = targetFreeCache[key]
    if c ~= nil and g_time - c.time < 3000 then
        return c.free, c.name
    end
    local idx = ADJobs.getMarkerIndexByName(markerName)
    local marker = idx ~= nil and ADJobs.GM:getMapMarkerById(idx) or nil
    local wp = marker ~= nil and ADJobs.GM:getWayPointById(marker.id) or nil
    local free, name = nil, nil
    if wp ~= nil then
        for _, p in ipairs(g_currentMission.placeableSystem.placeables) do
            if p ~= source and p.rootNode ~= nil and (fixed == nil or fixed.p == p) then
                local x, _, z = getWorldTranslation(p.rootNode)
                if fixed ~= nil or MathUtil.vector2Length(x - wp.x, z - wp.z) < ADJobs.SOURCE_RADIUS then
                    local level, cap, found = 0, 0, false
                    for _, storage in ipairs(ADJobs.getStorages(p)) do
                        if storageFillTypes(storage)[ft] then
                            found = true
                            level = level + storageLevel(storage, ft)
                            cap = cap + storageCapacity(storage, ft)
                        end
                    end
                    if found and cap > 0 and cap < 1e9 then
                        local f = math.max(0, cap - level)
                        if free == nil or f > free then
                            free = f
                            name = ADJobs.getPlaceableLabel(p) or (p.getName ~= nil and p:getName()) or "?"
                        end
                    end
                end
            end
        end
    end
    targetFreeCache[key] = {time = g_time, free = free, name = name}
    return free, name
end

--- what the vehicle loads: level and capacity of the load fill type in the whole combination
function ADJobs.getLoad(job, vehicle)
    local level, capacity = ADJobs.measureCombination(vehicle, job.loadFillTypeName or "")
    if level == nil and (job.loadFillTypeName or "") ~= "" then
        level, capacity = ADJobs.measureCombination(vehicle, "")
    end
    return level or 0, capacity or 0
end

--- safety margin while loading: better a bit less than too much (nobody should have to help by hand).
--- rate = loading speed in l/ms (the load trigger needs a moment to stop)
function ADJobs.getLoadMargin(trailerCapacity, rate)
    return math.max(1000, (trailerCapacity or 0) * 0.05, (rate or 0) * 3000)
end

--- a trip only makes sense if at least this much fits into the storage
--- (margin + 500 l, so that the loading watch can never stop the loading right after the first liter)
function ADJobs.getMinLoad(job, vehicle)
    local _, capacity = ADJobs.getLoad(job, vehicle)
    return ADJobs.getLoadMargin(capacity, 0) + 500
end

--- AutoDrive "automatic pickup / unload target" would replace the targets of the job by the best
--- selling / pickup station (setMode only switches them off when the mode really changes)
function ADJobs.disableAutomaticTargets(sm)
    if sm.setAutomaticUnloadTarget ~= nil then
        sm:setAutomaticUnloadTarget(false)
    end
    if sm.setAutomaticPickupTarget ~= nil then
        sm:setAutomaticPickupTarget(false)
    end
end

--- is AutoDrive "rotate targets" switched on for this vehicle? (it would replace the job targets)
function ADJobs.hasRotateTargets(vehicle)
    local AD = ADJobs.AD
    if AD == nil or AD.getSetting == nil then
        return false
    end
    local ok, rt = pcall(AD.getSetting, "rotateTargets", vehicle)
    if not ok or rt == nil or rt == (AD.RT_NONE or 1) then
        return false
    end
    -- AutoDrive only rotates when folders are in use
    local okF, useFolders = pcall(AD.getSetting, "useFolders")
    return not okF or useFolders ~= false
end

--- can the rotate setting be switched for this vehicle alone? (AutoDrive keeps a copy per vehicle)
local function hasOwnRotateSetting(vehicle)
    local AD = ADJobs.AD
    return AD ~= nil and AD.getSettingState ~= nil and AD.setSettingState ~= nil
        and vehicle.ad ~= nil and type(vehicle.ad.settings) == "table" and vehicle.ad.settings.rotateTargets ~= nil
end

--- AutoDrive "rotate targets" would replace the targets of the job: switch it off for the run and
--- remember the player's setting (restored with the AutoDrive targets, see restoreMarkers)
function ADJobs.suspendRotate(job, vehicle)
    if not ADJobs.hasRotateTargets(vehicle) or not hasOwnRotateSetting(vehicle) then
        return
    end
    local ok, state = pcall(ADJobs.AD.getSettingState, "rotateTargets", vehicle)
    if not ok or state == nil then
        return
    end
    if job.savedRotate == nil then
        job.savedRotate = state
    end
    job._rotateVehicle = vehicle
    pcall(ADJobs.AD.setSettingState, "rotateTargets", 1, vehicle)
    Logging.info("[AD Jobs] Auftrag %d '%s': AutoDrive 'Ziele rotieren' an %s für die Fahrt ausgeschaltet", job.id, tostring(job.name), ADJobs.getVehicleName(vehicle))
end

function ADJobs.restoreRotate(job, vehicle)
    if job.savedRotate == nil then
        return
    end
    vehicle = vehicle or job._rotateVehicle or job._veh or ADJobs.getVehicleByUid(job.vehicleUid)
    if vehicle == nil or vehicle.isDeleted or not hasOwnRotateSetting(vehicle) then
        return
    end
    pcall(ADJobs.AD.setSettingState, "rotateTargets", job.savedRotate, vehicle)
    job.savedRotate, job._rotateVehicle = nil, nil
end

--- the vehicle drives "pick up and deliver" between the targets of this job, but the job does not
--- know it (game loaded, job edited, started by hand): take the run over again
function ADJobs.tryAdopt(job, vehicle)
    if job.running or job.swap ~= nil or job.driveMode == "load" or vehicle == nil or vehicle.ad == nil then
        return false
    end
    local sm = vehicle.ad.stateModule
    if not sm:isActive() or sm:getMode() ~= (ADJobs.AD.MODE_PICKUPANDDELIVER or 2) then
        return false
    end
    local first, second = sm:getFirstMarker(), sm:getSecondMarker()
    if first == nil or second == nil or not ADJobs.isLoadMarkerOf(job, first.name) or second.name ~= job.unloadMarker then
        return false
    end
    for _, other in ipairs(ADJobs.jobs) do
        if other ~= job and (other.running or other.swap ~= nil) and other._veh == vehicle then
            return false
        end
    end
    job.running = true
    job._parking = nil
    job._veh = vehicle
    job.vehicleUid = vehicle.getUniqueId and vehicle:getUniqueId() or job.vehicleUid
    job.vehicleName = ADJobs.getVehicleName(vehicle)
    job.startTime = g_time
    job.tripsDone = 0
    job.state, job.msgCode = ADJobs.ST_RUN, 0
    if ADJobs.hooksInstalled then
        sm:setLoopCounter((sm:getLoopsDone() or 0) + 1)
        sm:raiseDirtyFlag()
    end
    ADJobs.lastSyncKey = nil
    Logging.info("[AD Jobs] Auftrag %d '%s': laufende AutoDrive-Fahrt von %s übernommen", job.id, tostring(job.name), ADJobs.getVehicleName(vehicle))
    return true
end

--- while loading: load only what still fits into the storage, then drive off (AutoDrive "continue")
function ADJobs.watchLoading(job, vehicle)
    local PDM = ADJobs.PDM
    if PDM == nil or job.driveMode == "load" or vehicle.ad == nil then
        return
    end
    local sm = vehicle.ad.stateModule
    if not sm:isActive() or sm:getMode() ~= (ADJobs.AD.MODE_PICKUPANDDELIVER or 2) then
        return
    end
    local mode = sm:getCurrentMode()
    if mode == nil or mode.continue == nil then
        return
    end
    if ADJobs.watchUnloadStall(job, vehicle, mode) then
        return
    end
    if ADJobs.watchLoadSource(job, vehicle, mode) then
        return
    end
    if job.direction == "empty" then
        ADJobs.watchHaulLoading(job, vehicle, mode)
        return
    end
    local free = ADJobs.getFreeSpace(job)
    if job._dumping ~= nil then
        -- unloading a rest elsewhere: that place counts (emergency unload point: unknown -> no escape)
        free = job._dumping.job ~= nil and ADJobs.getFreeSpace(job._dumping.job) or nil
        if mode.state ~= PDM.STATE_DELIVER_TO_NEXT_TARGET then
            return
        end
    end
    if free == nil then
        return
    end
    local loaded, trailerCapacity = ADJobs.getLoad(job, vehicle)

    -- loading speed (liters per ms), for the follow-up of the load trigger
    local w = job._watch
    if w == nil or w.state ~= mode.state then
        w = {state = mode.state, lastLoaded = loaded, lastTime = g_time, rate = 0, stableSince = g_time}
        job._watch = w
    end
    local dt = g_time - w.lastTime
    if dt >= 200 then
        local rate = math.max(0, (loaded - w.lastLoaded) / dt)
        w.rate = math.max(rate, w.rate * 0.8)
        if math.abs(loaded - w.lastLoaded) > 0.5 then
            w.stableSince = g_time
        end
        w.lastLoaded, w.lastTime = loaded, g_time
    end

    if mode.state == PDM.STATE_PICKUP_FROM_NEXT_TARGET then
        -- loading: better a bit less than too much (nobody should have to help by hand)
        local margin = ADJobs.getLoadMargin(trailerCapacity, w.rate)
        if loaded > 0.5 and loaded >= free - margin then
            Logging.info("[AD Jobs] Auftrag %d '%s': %d l geladen, %d l frei im Lager (Puffer %d l) - fährt abladen",
                job.id, tostring(job.name), math.floor(loaded), math.floor(free), math.floor(margin))
            job._watch = nil
            mode:continue()
        end
    elseif mode.state == PDM.STATE_DELIVER_TO_NEXT_TARGET then
        -- unloading, but the storage is full and nothing moves any more: give up the rest,
        -- AutoDrive unloads it first at the next start; now: next job or park
        if job._dumping ~= nil then
            loaded = 0
            for _, r in ipairs(ADJobs.getRest(vehicle)) do
                loaded = loaded + r.level
            end
        end
        if loaded > 0.5 and free < 100 and g_time - w.stableSince > 10000 then
            Logging.info("[AD Jobs] Auftrag %d '%s': Lager voll, %d l bleiben im Anhänger - Abladen beendet",
                job.id, tostring(job.name), math.floor(loaded))
            job._watch = nil
            mode:continue()
        end
    end
end

--- haul away job while loading: the source runs empty (or the loading stalls) before the trailer is
--- full -> drive off with what is loaded, sell it and park afterwards; nothing loaded at all -> park now
function ADJobs.watchHaulLoading(job, vehicle, mode)
    local PDM = ADJobs.PDM
    if mode.state ~= PDM.STATE_PICKUP_FROM_NEXT_TARGET then
        job._watch = nil
        return
    end
    local loaded, trailerCapacity = ADJobs.getLoad(job, vehicle)
    local w = job._watch
    if w == nil or w.state ~= mode.state then
        w = {state = mode.state, lastLoaded = loaded, lastTime = g_time, stableSince = g_time}
        job._watch = w
    end
    -- the times only count once the vehicle stands at the load target (the pickup task of AutoDrive
    -- starts with the drive there - nothing is loaded on the way)
    local sm = vehicle.ad.stateModule
    local first = sm.getFirstMarker ~= nil and sm:getFirstMarker() or nil
    local fi = type(first) == "table" and first.name ~= nil and ADJobs.getMarkerIndexByName(first.name) or nil
    local speed = vehicle.getLastSpeed ~= nil and vehicle:getLastSpeed() or 0
    if fi == nil or not ADJobs.isNearMarker(vehicle, fi) or speed > 1 then
        w.since = nil
        w.stableSince = g_time
        w.lastLoaded = loaded
        return
    end
    w.since = w.since or g_time
    if g_time - w.lastTime >= 200 then
        if math.abs(loaded - w.lastLoaded) > 0.5 then
            w.stableSince = g_time
        end
        w.lastLoaded, w.lastTime = loaded, g_time
    end
    if trailerCapacity > 0 and loaded >= trailerCapacity - 1 then
        return -- full: AutoDrive drives off by itself
    end
    -- the storage at the unload target only takes this much: load no more than fits (then it is the last trip)
    local targetFree = ADJobs.getTargetFreeSpace(job)
    if targetFree ~= nil and loaded > 0.5 then
        local margin = ADJobs.getLoadMargin(trailerCapacity, 0)
        if loaded >= targetFree - margin then
            job._watch = nil
            job._lastTrip = true
            Logging.info("[AD Jobs] Auftrag %d '%s': %d l geladen, am Abladeziel nur noch %d l frei - fährt abladen und parkt danach",
                job.id, tostring(job.name), math.floor(loaded), math.floor(targetFree))
            mode:continue()
            return
        end
    end
    local sourceEmpty = (job.level or 0) <= 1
    if sourceEmpty then
        -- whoever makes the vehicle leave now (this watch or AutoDrive's own "continue on empty silo"):
        -- after this delivery there is nothing left to haul -> park
        job._lastTrip = true
    end
    local stalled = g_time - w.stableSince
    local sinceArrival = g_time - w.since
    local giveUp = (sourceEmpty and stalled >= ADJobs.HAUL_EMPTY_TIME and sinceArrival >= ADJobs.HAUL_EMPTY_TIME)
        or (stalled >= ADJobs.HAUL_STALL_TIME and sinceArrival >= ADJobs.HAUL_STALL_TIME and g_time - (job.stableSince or g_time) >= ADJobs.HAUL_STALL_TIME)
    if not giveUp then
        return
    end
    job._watch = nil
    if loaded > 0.5 then
        job._lastTrip = true
        Logging.info("[AD Jobs] Auftrag %d '%s': Lager leer / Laden stockt, %d l geladen - fährt verkaufen und parkt danach", job.id, tostring(job.name), math.floor(loaded))
        mode:continue()
    else
        Logging.info("[AD Jobs] Auftrag %d '%s': Lager leer / Laden stockt, nichts geladen - %s parkt", job.id, tostring(job.name), ADJobs.getVehicleName(vehicle))
        ADJobs.abortRunAndPark(job, vehicle)
        if not sourceEmpty then
            -- the source is not empty, but nothing was loaded (trigger not reached / does not load):
            -- do not start again right away
            job.pauseUntil = g_time + math.max(job.pauseMin or 0, ADJobs.PARK_PAUSE_MIN) * 60000
            job.stuckLoadWarn = true
        end
    end
end

--- ends a run on the spot (nothing to haul): AutoDrive settings back, vehicle drives to its park position
function ADJobs.abortRunAndPark(job, vehicle)
    local sm = vehicle.ad.stateModule
    ADJobs.stopDriving(vehicle)
    sm:setLoopCounter(job.savedLoopCounter or 0)
    ADJobs.restoreMarkers(job, sm)
    sm:raiseDirtyFlag()
    job.running = false
    job._parking, job._dumping, job._dumpTried, job._watch, job._lastTrip = nil, nil, nil, nil, nil
    job._parkVehicle = vehicle
    ADJobs.parkVehicle(job, vehicle)
    job.state, job.msgCode = ADJobs.ST_STOPPING, 0
    ADJobs.lastSyncKey = nil
end

--- AutoDrive waits at the unload target "until it is unloaded somehow" - without a time limit - when the
--- vehicle reached the target but no trigger takes the rest (wrong trigger, storage refuses the fill
--- type, trailer does not reach the trigger ...). After a while the job ends the unloading: the rest is
--- handled like a rest left by a full storage (other job with that fill type / emergency unload point /
--- park with it). Returns true if it decided.
function ADJobs.watchUnloadStall(job, vehicle, mode)
    local PDM = ADJobs.PDM
    if mode.state ~= PDM.STATE_DELIVER_TO_NEXT_TARGET then
        job._unWatch = nil
        return false
    end
    local loaded = 0
    for _, r in ipairs(ADJobs.getRest(vehicle)) do
        loaded = loaded + r.level
    end
    local sm = vehicle.ad.stateModule
    local target = sm.getSecondMarker ~= nil and sm:getSecondMarker() or nil
    local idx = type(target) == "table" and target.name ~= nil and ADJobs.getMarkerIndexByName(target.name) or nil
    local speed = vehicle.getLastSpeed ~= nil and vehicle:getLastSpeed() or 0
    if loaded <= 0.5 or idx == nil or not ADJobs.isNearMarker(vehicle, idx) or speed > 0.5 then
        job._unWatch = nil
        return false
    end
    local uw = job._unWatch
    if uw == nil then
        uw = {loaded = loaded, changed = g_time}
        job._unWatch = uw
    end
    if math.abs(loaded - uw.loaded) > 0.5 then
        uw.loaded, uw.changed = loaded, g_time
        return false
    end
    if g_time - uw.changed < ADJobs.UNLOAD_STALL_TIME then
        return false
    end
    job._unWatch = nil
    job._unloadStuck = true
    Logging.warning("[AD Jobs] Auftrag %d '%s': %s steht am Abladeziel '%s', %d l werden nicht abgeladen (kein passender Abladetrigger / Lager nimmt nicht an?) - Abladen beendet",
        job.id, tostring(job.name), ADJobs.getVehicleName(vehicle), tostring(target.name), math.floor(loaded))
    mode:continue()
    return true
end

-------------------------------------------------------------------------------------------------
-- several load targets: if the storage at one is empty the vehicle goes on to the next
-------------------------------------------------------------------------------------------------

--- load target of the job and the additional ones, in order, without doubles
function ADJobs.getLoadMarkers(job)
    local list, seen = {}, {}
    local function add(n)
        if n ~= nil and n ~= "" and not seen[n] then
            seen[n] = true
            table.insert(list, n)
        end
    end
    add(job.loadMarker)
    for n in string.gmatch(job.extraLoadMarkers or "", "[^|]+") do
        add(n)
    end
    return list
end

function ADJobs.isLoadMarkerOf(job, name)
    for _, n in ipairs(ADJobs.getLoadMarkers(job)) do
        if n == name then
            return true
        end
    end
    return false
end

local function jobLoadFillType(job, vehicle)
    local ftName = (job.loadFillTypeName or "") ~= "" and job.loadFillTypeName or nil
    local ft = ftName ~= nil and g_fillTypeManager:getFillTypeIndexByName(ftName) or nil
    if ft == nil and vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule.getFillType ~= nil then
        ft = vehicle.ad.stateModule:getFillType()
    end
    return ft
end

-------------------------------------------------------------------------------------------------
-- storages ("Lager"): numbers L1, L2 ... shown in the world (HUD button "L#"), and a fixed storage per
-- AD target. Without a fixed storage the fullest storage with the fill type within SOURCE_RADIUS counts;
-- several silos side by side (hay / straw) may need the right one set by hand.
-------------------------------------------------------------------------------------------------

ADJobs.markerSources = {}   -- [AD target name] = unique id of the placeable whose storage counts there

local storageListCache = {time = -math.huge, list = {}, byUid = {}}

--- all placeables with a storage, numbered by their position on the map (west to east, then north to
--- south): {p, num, uid, x, z}; also byUid. Cached for a few seconds.
function ADJobs.getStoragePlaceables()
    if g_time - storageListCache.time < 5000 then
        return storageListCache.list, storageListCache.byUid
    end
    local list, byUid = {}, {}
    if g_currentMission ~= nil and g_currentMission.placeableSystem ~= nil then
        for _, p in ipairs(g_currentMission.placeableSystem.placeables) do
            if not p.isDeleted and p.rootNode ~= nil and p.rootNode ~= 0 and #ADJobs.getStorages(p) > 0 then
                local x, _, z = getWorldTranslation(p.rootNode)
                table.insert(list, {p = p, x = math.floor(x + 0.5), z = math.floor(z + 0.5),
                    uid = p.getUniqueId ~= nil and tostring(p:getUniqueId()) or ""})
            end
        end
    end
    table.sort(list, function(a, b)
        if a.x ~= b.x then
            return a.x < b.x
        end
        return a.z < b.z
    end)
    for i, e in ipairs(list) do
        e.num = i
        if e.uid ~= "" then
            byUid[e.uid] = e
        end
    end
    storageListCache = {time = g_time, list = list, byUid = byUid}
    return list, byUid
end

function ADJobs.getStorageByUid(uid)
    if uid == nil or uid == "" then
        return nil
    end
    local _, byUid = ADJobs.getStoragePlaceables()
    return byUid[uid]
end

--- "L3 Heulager #2"
function ADJobs.getStorageTitle(e)
    if e == nil then
        return "?"
    end
    return string.format("L%d %s", e.num, tostring(ADJobs.getPlaceableLabel(e.p) or "?"))
end

--- liters of fill type ft in the storages of placeable p (nil = it does not store ft)
function ADJobs.measurePlaceableFt(p, ft)
    local sum, found = 0, false
    for _, storage in ipairs(ADJobs.getStorages(p)) do
        if storageFillTypes(storage)[ft] then
            found = true
            sum = sum + storageLevel(storage, ft)
        end
    end
    return found and sum or nil
end

--- contents of a placeable: list of {ft, level}, most first (only what is there)
function ADJobs.getStorageContents(p)
    local sums = {}
    for _, storage in ipairs(ADJobs.getStorages(p)) do
        for ft, level in pairs(storage.fillLevels) do
            if type(level) == "number" and level > 0.5 then
                sums[ft] = (sums[ft] or 0) + level
            end
        end
    end
    local list = {}
    for ft, level in pairs(sums) do
        table.insert(list, {ft = ft, level = level})
    end
    table.sort(list, function(a, b)
        return a.level > b.level
    end)
    return list
end

--- where the number of a storage is shown: above its load trigger (where vehicles load), else above the building
local labelPosCache = setmetatable({}, {__mode = "k"})
function ADJobs.getStorageLabelPos(p)
    local node = labelPosCache[p]
    if node == nil then
        node = false
        pcall(function()
            for key, spec in pairs(p) do
                if type(key) == "string" and key:sub(1, 5) == "spec_" and type(spec) == "table" then
                    local ls = spec.loadingStation
                    if type(ls) == "table" and type(ls.loadTriggers) == "table" then
                        for _, t in pairs(ls.loadTriggers) do
                            if type(t) == "table" and t.triggerNode ~= nil and t.triggerNode ~= 0 then
                                node = t.triggerNode
                                return
                            end
                        end
                    end
                end
            end
        end)
        labelPosCache[p] = node
    end
    if node and entityExists ~= nil and not entityExists(node) then
        labelPosCache[p] = nil
        node = false
    end
    local x, y, z = getWorldTranslation(node or p.rootNode)
    return x, y + 3, z
end

--- fixed storage of an AD target (set in the job editor); uid "" / nil = automatic again
function ADJobs.setMarkerSource(markerName, uid)
    if (markerName or "") == "" then
        return
    end
    if (uid or "") == "" then
        ADJobs.markerSources[markerName] = nil
    else
        ADJobs.markerSources[markerName] = uid
    end
end

--- level of fill type ft at an AD target: the fullest storage with that fill type within SOURCE_RADIUS
--- (several buildings may stand there - an empty straw storage next to the full one must not make the
--- target "empty"). Returns level (nil = no storage found / unknown) and the names of the buildings checked.
local sourceCache = {}
function ADJobs.getSourceLevel(markerName, ft)
    if markerName == nil or ft == nil then
        return nil
    end
    local fixedUid = ADJobs.markerSources[markerName]
    local key = markerName .. "|" .. tostring(ft) .. "|" .. tostring(fixedUid or "")
    local c = sourceCache[key]
    if c ~= nil and g_time - c.time < 3000 then
        return c.level, c.names
    end
    -- storage set by hand for this target: only that one counts (nil = it does not store this fill type)
    local fixed = ADJobs.getStorageByUid(fixedUid)
    if fixed ~= nil then
        local level = ADJobs.measurePlaceableFt(fixed.p, ft)
        local text = string.format("%s %s (%s)", ADJobs.getStorageTitle(fixed), level ~= nil and string.format("%d l", math.floor(level)) or "-", txt("srcFixedShort"))
        sourceCache[key] = {time = g_time, level = level, names = text}
        return level, text
    end
    local idx = ADJobs.getMarkerIndexByName(markerName)
    local marker = idx ~= nil and ADJobs.GM:getMapMarkerById(idx) or nil
    local wp = marker ~= nil and ADJobs.GM:getWayPointById(marker.id) or nil
    local level, names = nil, {}
    if wp ~= nil then
        for _, p in ipairs(g_currentMission.placeableSystem.placeables) do
            if p.rootNode ~= nil then
                local x, _, z = getWorldTranslation(p.rootNode)
                local d = MathUtil.vector2Length(x - wp.x, z - wp.z)
                if d < ADJobs.SOURCE_RADIUS then
                    local sum, found = 0, false
                    for _, storage in ipairs(ADJobs.getStorages(p)) do
                        if storageFillTypes(storage)[ft] then
                            found = true
                            sum = sum + storageLevel(storage, ft)
                        end
                    end
                    if found then
                        level = math.max(level or 0, sum)
                        local label = ADJobs.getPlaceableLabel ~= nil and ADJobs.getPlaceableLabel(p) or (p.getName ~= nil and p:getName()) or "?"
                        table.insert(names, string.format("%s %d l (%d m)", tostring(label), math.floor(sum), math.floor(d)))
                    end
                end
            end
        end
    end
    local text = #names > 0 and table.concat(names, ", ") or nil
    sourceCache[key] = {time = g_time, level = level, names = text}
    return level, text
end

--- first load target (in the order of the job) that is not excluded and not known to be empty; nil if none
function ADJobs.chooseLoadMarker(job, exclude, vehicle)
    local markers = ADJobs.getLoadMarkers(job)
    if #markers < 2 then
        return markers[1]
    end
    local ft = jobLoadFillType(job, vehicle or job._veh)
    for _, name in ipairs(markers) do
        if (exclude == nil or not exclude[name]) and ADJobs.getMarkerIndexByName(name) ~= nil then
            local level = ADJobs.getSourceLevel(name, ft)
            if level == nil or level >= ADJobs.SOURCE_EMPTY_LEVEL then
                return name
            end
        end
    end
    return nil
end

--- are the storages at all load targets known to be empty? (unknown = no) - then the job does not start
function ADJobs.allSourcesEmpty(job, vehicle)
    if job.direction == "empty" then
        return false -- haul away: the watched object is the source, its level decides
    end
    local ft = jobLoadFillType(job, vehicle)
    if ft == nil then
        return false
    end
    local checked = {}
    for _, name in ipairs(ADJobs.getLoadMarkers(job)) do
        local level, names = ADJobs.getSourceLevel(name, ft)
        if level == nil or level >= ADJobs.SOURCE_EMPTY_LEVEL then
            job._emptyLogged = nil
            return false
        end
        table.insert(checked, string.format("'%s': %s", name, tostring(names)))
    end
    -- say once which buildings were checked (to find a wrong match quickly)
    local text = table.concat(checked, "; ")
    if job._emptyLogged ~= text then
        job._emptyLogged = text
        Logging.info("[AD Jobs] Auftrag %d '%s': Lager am Ladeziel leer - geprüft: %s", job.id or 0, tostring(job.name), text)
    end
    return true
end

--- sets the AutoDrive load target of a running job to the best of its load targets
function ADJobs.selectLoadMarker(job, sm, exclude)
    if #ADJobs.getLoadMarkers(job) < 2 then
        return
    end
    local name = ADJobs.chooseLoadMarker(job, exclude) or job.loadMarker
    local idx = ADJobs.getMarkerIndexByName(name)
    if idx ~= nil then
        sm:setFirstMarker(idx)
    end
end

--- while the vehicle stands at a load target: the storage there is empty (or nothing is loaded for a
--- while) and the trailer is not full -> go on to the next load target; none left -> deliver what is
--- loaded, or park if nothing is. Returns true if it decided (the caller does nothing more).
function ADJobs.watchLoadSource(job, vehicle, mode)
    local PDM = ADJobs.PDM
    if mode.state ~= PDM.STATE_PICKUP_FROM_NEXT_TARGET or (#ADJobs.getLoadMarkers(job) < 2 and job.direction == "empty") then
        -- (haul away with one load target: watchHaulLoading decides)
        job._srcWatch = nil
        return false
    end
    local sm = vehicle.ad.stateModule
    local cur = sm.getFirstMarker ~= nil and sm:getFirstMarker() or nil
    local curName = type(cur) == "table" and cur.name or nil
    if curName == nil then
        return false
    end
    local loaded, capacity = ADJobs.getLoad(job, vehicle)
    if capacity > 0 and loaded >= capacity - 1 then
        return false
    end
    local sw = job._srcWatch
    if sw == nil or sw.marker ~= curName then
        sw = {marker = curName, loaded = loaded, changed = g_time}
        job._srcWatch = sw
    end
    if math.abs(loaded - sw.loaded) > 0.5 then
        sw.loaded, sw.changed = loaded, g_time
    end
    local idx = ADJobs.getMarkerIndexByName(curName)
    local speed = vehicle.getLastSpeed ~= nil and vehicle:getLastSpeed() or 0
    if idx == nil or not ADJobs.isNearMarker(vehicle, idx) or speed > 1 then
        sw.arrived = nil
        return false
    end
    sw.arrived = sw.arrived or g_time
    local standing = g_time - sw.arrived
    local idle = g_time - sw.changed
    local level = ADJobs.getSourceLevel(curName, jobLoadFillType(job, vehicle))
    local empty = (level ~= nil and level < ADJobs.SOURCE_EMPTY_LEVEL and standing >= ADJobs.LOAD_SWITCH_EMPTY_TIME and idle >= ADJobs.LOAD_SWITCH_EMPTY_TIME)
        or (standing >= ADJobs.LOAD_SWITCH_STALL_TIME and idle >= ADJobs.LOAD_SWITCH_STALL_TIME)
    if not empty then
        return false
    end
    job._srcWatch = nil
    job._triedLoad = job._triedLoad or {}
    job._triedLoad[curName] = true
    local nextName = nil
    if #ADJobs.getLoadMarkers(job) >= 2 then
        nextName = ADJobs.chooseLoadMarker(job, job._triedLoad, vehicle)
    end
    if nextName ~= nil then
        Logging.info("[AD Jobs] Auftrag %d '%s': Ladeziel '%s' leer (%d l geladen) - fährt weiter zu '%s'", job.id, tostring(job.name), curName, math.floor(loaded), nextName)
        job._switchLoad = nextName
        mode:continue()
        return true
    end
    job._triedLoad = nil
    if loaded > 0.5 then
        Logging.info("[AD Jobs] Auftrag %d '%s': alle Ladeziele leer - fährt mit %d l abladen", job.id, tostring(job.name), math.floor(loaded))
        if job.direction == "empty" then
            job._lastTrip = true
        end
        mode:continue()
    else
        Logging.info("[AD Jobs] Auftrag %d '%s': Ladeziel leer, nichts geladen - %s parkt", job.id, tostring(job.name), ADJobs.getVehicleName(vehicle))
        ADJobs.abortRunAndPark(job, vehicle)
        if level == nil or level >= ADJobs.SOURCE_EMPTY_LEVEL then
            -- the level of the storage is not known, or it is not empty but nothing was loaded (trigger not
            -- reached / wrong fill type): wait before trying again - otherwise the job would start again in the
            -- next check and abort again a few seconds later. With a known empty storage the start check waits
            -- until the storage has something again.
            job.pauseUntil = g_time + math.max(job.pauseMin or 0, ADJobs.PARK_PAUSE_MIN) * 60000
            if level ~= nil then
                job.stuckLoadWarn = true
            end
        end
    end
    return true
end

--- what is still in the combination: list of {ft, level}, most first
function ADJobs.getRest(vehicle)
    local levels = {}
    for _, v in ipairs(ADJobs.getVehicleUnits(vehicle)) do
        local spec = v.spec_fillUnit
        if spec ~= nil and spec.fillUnits ~= nil then
            for i, fillUnit in ipairs(spec.fillUnits) do
                local ft = v:getFillUnitFillType(i)
                local level = v:getFillUnitFillLevel(i) or 0
                if ft ~= nil and level > 0.5 and unitIsCargo(fillUnit) and not isConsumable(ft) then
                    levels[ft] = (levels[ft] or 0) + level
                end
            end
        end
    end
    local list = {}
    for ft, level in pairs(levels) do
        table.insert(list, {ft = ft, level = level})
    end
    table.sort(list, function(a, b)
        return a.level > b.level
    end)
    return list
end

--- where can the rest go? 1. another job with the same fill type and space, 2. emergency unload point of the job
function ADJobs.findDumpTarget(job, vehicle, rest)
    local ftName = g_fillTypeManager:getFillTypeNameByIndex(rest.ft)
    local tried = job._dumpTried or {}
    local best, bestFree = nil, 500
    for _, other in ipairs(ADJobs.jobs) do
        if other ~= job and other.driveMode ~= "load" and (other.unloadMarker or "") ~= "" and not tried[other.unloadMarker]
            and ADJobs.getMarkerIndexByName(other.unloadMarker) ~= nil
            and (other.loadFillTypeName == ftName or other.fillTypeName == ftName) then
            local free = ADJobs.getFreeSpace(other)
            if free ~= nil and free > bestFree then
                best, bestFree = {marker = other.unloadMarker, job = other}, free
            end
        end
    end
    if best ~= nil then
        return best
    end
    local em = job.emergencyMarker
    if em ~= nil and em ~= "" and not tried[em] and ADJobs.getMarkerIndexByName(em) ~= nil then
        return {marker = em}
    end
    return nil
end

function ADJobs.beforeNextTask(mode)
    local PDM = ADJobs.PDM
    -- loading finished / given up: the job may send the vehicle to another load target instead of unloading
    if mode ~= nil and mode.vehicle ~= nil and mode.state == PDM.STATE_PICKUP_FROM_NEXT_TARGET then
        local job = getRunningJobOfVehicle(mode.vehicle)
        if job ~= nil and job._switchLoad ~= nil then
            local idx = ADJobs.getMarkerIndexByName(job._switchLoad)
            job._switchLoad = nil
            if idx ~= nil and PDM.STATE_DELIVER ~= nil then
                local sm = mode.vehicle.ad.stateModule
                sm:setFirstMarker(idx)
                sm:raiseDirtyFlag()
                -- AutoDrive: "drive to the load target and load" comes next (the trip is not counted)
                mode.state = PDM.STATE_DELIVER
            end
        end
        return
    end
    -- only the decision right after an unloading
    if mode == nil or mode.vehicle == nil or mode.state ~= PDM.STATE_DELIVER_TO_NEXT_TARGET then
        return
    end
    local vehicle = mode.vehicle
    local job = getRunningJobOfVehicle(vehicle)
    if job == nil then
        for _, j in ipairs(ADJobs.jobs) do
            if ADJobs.vehicleServesJob(vehicle, j) and ADJobs.tryAdopt(j, vehicle) then
                job = j
                break
            end
        end
    end
    if job == nil or job.driveMode == "load" or job.driveMode == "sequence" then
        -- (sequence: AutoDrive + Courseplay run on their own, the job only watches)
        return
    end
    local sm = vehicle.ad.stateModule
    local loopsDone = sm:getLoopsDone() or 0
    -- one delivery done (our own count; AutoDrive resets its counter when parking)
    if job._dumping == nil then
        job.tripsDone = (job.tripsDone or 0) + 1
        job.tripsTotal = (job.tripsTotal or 0) + 1
    end
    local p = freshPercent(job)
    job.percent = p
    local tripsUsedUp = (job.maxTrips or 0) > 0 and job.tripsDone >= job.maxTrips
    local targetReached = ADJobs.targetReached(job, p)
    if job._lastTrip then
        -- haul away: the source ran empty during the last loading, nothing left to fetch
        targetReached = true
        job._lastTrip = nil
    end
    local free = ADJobs.getFreeSpace(job)
    local noSpace = free ~= nil and free < ADJobs.getMinLoad(job, vehicle)
    if job._unloadStuck then
        -- the unload target did not take the rest: do not go on loading, handle the rest / park, and pause
        -- the job - otherwise it would start again right away (the watched value did not change, e.g. the
        -- unload point fills another storage than the one the job watches)
        noSpace = true
        job._unloadStuck = nil
        job.stuckWarn = true
        job.pauseUntil = g_time + math.max(job.pauseMin or 0, ADJobs.PARK_PAUSE_MIN) * 60000
    elseif job._dumping == nil then
        job.stuckWarn = nil
    end
    job._triedLoad = nil
    if job.active and job._dumping == nil and not targetReached and not tripsUsedUp and not noSpace then
        -- go on: exactly one more trip (if the job loses track, AutoDrive parks after it)
        sm:setLoopCounter(loopsDone + 1)
        -- several load targets: the first one that still has something
        ADJobs.selectLoadMarker(job, sm, nil)
        sm:raiseDirtyFlag()
        ADJobs.deliverFirstIfLoaded(job, vehicle, mode)
        return
    end
    if tripsUsedUp and not targetReached and p >= 0 then
        job.pauseUntil = g_time + (job.pauseMin or 0) * 60000
    end
    if job._dumping ~= nil then
        Logging.info("[AD Jobs] Auftrag %d '%s': Rest bei '%s' abgeladen", job.id, tostring(job.name), tostring(job._dumping.marker))
        job._dumping = nil
    end
    local nextJob = ADJobs.findChainJob(job, vehicle)
    local rest = ADJobs.getRest(vehicle)
    if nextJob ~= nil and #rest > 0 then
        -- rest in the trailer (storage was full): only on to a job with the same load
        local ft = (nextJob.loadFillTypeName or "") ~= "" and nextJob.loadFillTypeName or nil
        local restLevel = ft ~= nil and ADJobs.measureCombination(vehicle, ft) or nil
        if restLevel == nil or restLevel <= 0.5 then
            nextJob = nil
        end
    end
    if nextJob ~= nil then
        ADJobs.chainTo(job, nextJob, vehicle)
        -- a rest of the same fill type is on board: the next job delivers it first
        ADJobs.deliverFirstIfLoaded(nextJob, vehicle, mode)
        return
    end
    -- rest in the trailer: unload it at another job with the same fill type or at the emergency unload point
    -- (not for haul away jobs: the sell point takes everything, a rest there is not ours to redistribute)
    if #rest > 0 and job.direction ~= "empty" then
        local target = ADJobs.findDumpTarget(job, vehicle, rest[1])
        if target ~= nil then
            job._dumpTried = job._dumpTried or {}
            job._dumpTried[target.marker] = true
            job._dumping = target
            sm:setSecondMarker(ADJobs.getMarkerIndexByName(target.marker))
            sm:raiseDirtyFlag()
            -- AutoDrive: "drive to the unload target" comes next
            mode.state = ADJobs.PDM.STATE_PICKUP
            job.state = ADJobs.ST_DUMP
            Logging.info("[AD Jobs] Auftrag %d '%s': %d l Rest - fährt zum Abladen nach '%s'%s", job.id, tostring(job.name),
                math.floor(rest[1].level), target.marker, target.job ~= nil and (" (Auftrag '" .. tostring(target.job.name) .. "')") or " (Notabladeplatz)")
            return
        end
    end
    -- nothing else to do: AutoDrive drives to the park position and switches off
    -- (loop counter 0 would mean "unlimited" for AutoDrive, so at least 1 trip counts as done)
    local done = math.max(loopsDone, 1)
    sm:setLoopsDone(done)
    sm:setLoopCounter(done)
    sm:raiseDirtyFlag()
    -- swapped trailer on board: park at its stand, the other trailer stands at the park position
    ADJobs.redirectParkForSwap(job, vehicle)
    job._parking = true
    job.state = ADJobs.ST_STOPPING
    Logging.info("[AD Jobs] Auftrag %d '%s': Stopp erreicht (%d %%), %s parkt", job.id, tostring(job.name), math.floor(p), ADJobs.getVehicleName(vehicle))
end

-------------------------------------------------------------------------------------------------
-- server: rule engine
-------------------------------------------------------------------------------------------------

function ADJobs.finishRun(job)
    local vehicle = ADJobs.findVehicle(job)
    if vehicle ~= nil and vehicle.ad ~= nil then
        local sm = vehicle.ad.stateModule
        if not ADJobs.hooksInstalled then
            job.tripsDone = sm:getLoopsDone() or job.tripsDone
        end
        if not sm:isActive() then
            -- give the vehicle its AutoDrive HUD settings back (loop counter, targets, fill type)
            sm:setLoopCounter(job.savedLoopCounter or 0)
            ADJobs.restoreMarkers(job, sm)
            sm:raiseDirtyFlag()
        end
    end
    job.running = false
    job._parking = nil
    job._dumping, job._dumpTried, job._lastTrip, job._watch = nil, nil, nil, nil
    Logging.info("[AD Jobs] Auftrag %d '%s' beendet nach %d Fahrten", job.id, tostring(job.name), job.tripsDone or 0)
    -- the vehicle parked (at the stand of the swapped trailer, if one is on board): put the trailer from
    -- before the run back on if needed (its own park position comes back once that is done)
    if (job.returnTrailerUid or "") == "" then
        ADJobs.restoreParkAfterSwap(job, vehicle)
    end
    ADJobs.afterRunSwapBack(job)
end

--- remembers the targets the player had chosen in the AutoDrive HUD before a run.
--- The fill type is NOT restored: AutoDrive loads with the fill type selected in its HUD, and jobs with
--- "keep AD setting" rely on the fill type the previous job left there (as in version 1.5.6).
function ADJobs.saveMarkers(job, sm)
    job.savedFirst = sm.getFirstMarkerId ~= nil and sm:getFirstMarkerId() or nil
    job.savedSecond = sm.getSecondMarkerId ~= nil and sm:getSecondMarkerId() or nil
    job.savedFillType = nil
    job.savedMode = sm.getMode ~= nil and sm:getMode() or nil
end

function ADJobs.restoreMarkers(job, sm)
    ADJobs.restoreRotate(job, nil)
    pcall(function()
        if type(job.savedMode) == "number" and job.savedMode >= 1 then
            sm:setMode(job.savedMode)
        end
        if type(job.savedFirst) == "number" and job.savedFirst >= 1 and ADJobs.GM:getMapMarkerById(job.savedFirst) ~= nil then
            sm:setFirstMarker(job.savedFirst)
        end
        if type(job.savedSecond) == "number" and job.savedSecond >= 1 and ADJobs.GM:getMapMarkerById(job.savedSecond) ~= nil then
            sm:setSecondMarker(job.savedSecond)
        end
    end)
    job.savedFirst, job.savedSecond, job.savedFillType, job.savedMode = nil, nil, nil, nil
end

-------------------------------------------------------------------------------------------------
-- selling price at the unload target (haul away jobs with a minimum price)
-------------------------------------------------------------------------------------------------

--- the selling station nearest to an AD marker that takes this fill type (nil if none within the radius)
function ADJobs.findSellStation(markerName, ft)
    local idx = ADJobs.getMarkerIndexByName(markerName)
    local marker = idx ~= nil and ADJobs.GM:getMapMarkerById(idx) or nil
    local wp = marker ~= nil and ADJobs.GM:getWayPointById(marker.id) or nil
    if wp == nil or ft == nil then
        return nil
    end
    local em = g_currentMission.economyManager
    if em == nil or em.getSellingStations == nil then
        return nil
    end
    local best, bestDist = nil, ADJobs.SELL_STATION_RADIUS
    for _, station in pairs(em:getSellingStations() or {}) do
        local takes = true
        if station.getIsFillTypeSupported ~= nil then
            local ok, r = pcall(station.getIsFillTypeSupported, station, ft)
            takes = ok and r == true
        elseif station.acceptedFillTypes ~= nil then
            takes = station.acceptedFillTypes[ft] == true
        end
        if takes then
            -- where is it? unload triggers, otherwise the placeable it belongs to
            local nodes = {}
            for _, trigger in ipairs(station.unloadTriggers or {}) do
                table.insert(nodes, trigger.exactFillRootNode or trigger.rootNode or trigger.triggerNode)
            end
            if station.owningPlaceable ~= nil then
                table.insert(nodes, station.owningPlaceable.rootNode)
            end
            table.insert(nodes, station.rootNode)
            for _, node in ipairs(nodes) do
                if node ~= nil and node ~= 0 then
                    local ok, x, _, z = pcall(getWorldTranslation, node)
                    if ok and x ~= nil then
                        local d = MathUtil.vector2Length(x - wp.x, z - wp.z)
                        if d < bestDist then
                            best, bestDist = station, d
                        end
                    end
                end
            end
        end
    end
    return best
end

--- current price in € per 1000 l for the load fill type of the job at its unload target (nil = unknown)
--- (cached for a few seconds; works on clients too, for the HUD)
function ADJobs.getSellPrice(job)
    local ftName = (job.loadFillTypeName or "") ~= "" and job.loadFillTypeName or job.fillTypeName
    local ft = g_fillTypeManager:getFillTypeIndexByName(ftName or "")
    if ft == nil or (job.unloadMarker or "") == "" then
        return nil
    end
    local c = job._priceCache
    if c ~= nil and c.marker == job.unloadMarker and c.ft == ft and g_time - c.time < ADJobs.PRICE_CACHE_TIME then
        return c.price
    end
    local price = nil
    local ok, station = pcall(ADJobs.findSellStation, job.unloadMarker, ft)
    if ok and station ~= nil and station.getEffectiveFillTypePrice ~= nil then
        local ok2, p = pcall(station.getEffectiveFillTypePrice, station, ft, job.farmId)
        if ok2 and type(p) == "number" and p > 0 then
            price = p * 1000
        end
    end
    job._priceCache = {marker = job.unloadMarker, ft = ft, time = g_time, price = price}
    return price
end

--- haul away job with a minimum price: is the price at the unload target high enough? (unknown price = yes)
function ADJobs.priceOk(job)
    if job.direction ~= "empty" or (job.minPrice or 0) <= 0 then
        return true
    end
    local price = ADJobs.getSellPrice(job)
    job.price = price or -1
    return price == nil or price >= job.minPrice
end

-------------------------------------------------------------------------------------------------
-- rest of another fill type on the trailer: deliver it where there is space (AutoDrive "deliver to")
-------------------------------------------------------------------------------------------------

local function jobFillType(j)
    local name = (j.loadFillTypeName or "") ~= "" and j.loadFillTypeName or j.fillTypeName
    return g_fillTypeManager:getFillTypeIndexByName(name or "")
end

--- the unload target that takes this rest: a job with that fill type and enough space at its storage
--- (haul away jobs: the selling station takes everything), else an emergency unload point of a job with
--- that fill type; jobs this vehicle works for come first, then the most space. Returns marker name, job
function ADJobs.findRestTarget(vehicle, ft, amount, exclude)
    local best, bestJob, bestScore = nil, nil, -math.huge
    for _, j in ipairs(ADJobs.jobs) do
        if j.driveMode ~= "load" and jobFillType(j) == ft and not j.stuckWarn then
            local candidates = {}
            local free = ADJobs.getFreeSpace(j)
            if (j.unloadMarker or "") ~= "" and (j.direction == "empty" or (free ~= nil and free >= amount)) then
                table.insert(candidates, {marker = j.unloadMarker, score = (free or 1e7)})
            end
            if (j.emergencyMarker or "") ~= "" then
                table.insert(candidates, {marker = j.emergencyMarker, score = -1e6})
            end
            local serves = ADJobs.vehicleServesJob(vehicle, j) and 1e8 or 0
            for _, c in ipairs(candidates) do
                if (exclude == nil or not exclude[c.marker]) and ADJobs.getMarkerIndexByName(c.marker) ~= nil then
                    local score = c.score + serves
                    if score > bestScore then
                        best, bestJob, bestScore = c.marker, j, score
                    end
                end
            end
        end
    end
    return best, bestJob
end

--- job blocked by a foreign rest (code 26): send the vehicle to deliver it; true if AutoDrive drives
ADJobs.REST_BLOCK_TIME = 10 * 60000 -- ms no automatic rest delivery for a vehicle after one failed / was stopped

function ADJobs.startRestDelivery(job, vehicle)
    local ft, amount = ADJobs.getForeignCargo(job, vehicle)
    if ft == nil or vehicle.ad == nil then
        return false
    end
    -- after a delivery that did not get rid of the rest, or that the player stopped: hands off for a while
    if vehicle._adjRestBlockedUntil ~= nil and g_time < vehicle._adjRestBlockedUntil then
        return false
    end
    if vehicle.getIsControlled ~= nil and vehicle:getIsControlled() then
        return false
    end
    -- a vehicle that an active sequence (Courseplay) job uses is left alone
    for _, j in ipairs(ADJobs.jobs) do
        if j.driveMode == "sequence" and j.active and (j._veh == vehicle or (j.seq == nil and ADJobs.vehicleServesJob(vehicle, j))) then
            return false
        end
    end
    -- a vehicle is only sent once at a time (several jobs may share it)
    for _, j in ipairs(ADJobs.jobs) do
        if j.restRun ~= nil and j.restRun.vehicle == vehicle then
            return j == job
        end
    end
    -- targets that did not take the rest are skipped for a while (the storage may get space again)
    if vehicle._adjRestTried == nil or g_time - (vehicle._adjRestTriedAt or 0) > 10 * 60000 then
        vehicle._adjRestTried, vehicle._adjRestTriedAt = {}, g_time
    end
    local marker, target = ADJobs.findRestTarget(vehicle, ft, amount, vehicle._adjRestTried)
    if marker == nil then
        return false
    end
    local idx = ADJobs.getMarkerIndexByName(marker)
    if not ADJobs.startDriveTo(vehicle, idx, ADJobs.AD.MODE_DELIVERTO or 3) then
        return false
    end
    local fillType = g_fillTypeManager:getFillTypeByIndex(ft)
    Logging.info("[AD Jobs] Auftrag %d '%s': %s liefert %d l %s bei '%s' ab (Auftrag '%s'), dann parken", job.id, tostring(job.name),
        ADJobs.getVehicleName(vehicle), math.floor(amount), fillType ~= nil and tostring(fillType.title) or tostring(ft), marker, tostring(target.name))
    job.restRun = {vehicle = vehicle, marker = marker, ft = ft, amount = amount, since = g_time}
    job.restMarker = marker
    job._veh = vehicle
    job.state, job.msgCode = ADJobs.ST_RESTRUN, 0
    ADJobs.lastSyncKey = nil
    return true
end

--- while a rest is delivered: done when AutoDrive is off again; at the target, nothing taken for a while ->
--- give up this target (the next check tries another one)
function ADJobs.updateRestDelivery(job)
    local rr = job.restRun
    local vehicle = rr.vehicle
    if vehicle == nil or vehicle.isDeleted or vehicle.ad == nil then
        job.restRun = nil
        return false
    end
    job.restMarker = rr.marker
    local sm = vehicle.ad.stateModule
    local rest = 0
    for _, r in ipairs(ADJobs.getRest(vehicle)) do
        if r.ft == rr.ft then
            rest = rest + r.level
        end
    end
    -- the player took over (sits in it): leave it to him
    if vehicle.getIsControlled ~= nil and vehicle:getIsControlled() then
        job.restRun = nil
        vehicle._adjRestBlockedUntil = g_time + ADJobs.REST_BLOCK_TIME
        Logging.info("[AD Jobs] Auftrag %d '%s': Rest-Lieferung - Spieler hat übernommen, keine automatische Rest-Lieferung für %d min", job.id, tostring(job.name), ADJobs.REST_BLOCK_TIME / 60000)
        return false
    end
    if not sm:isActive() then
        job.restRun = nil
        if rest > 50 then
            -- stopped (by the player or AutoDrive) or the target did not take it: do not send it again right away
            vehicle._adjRestTried = vehicle._adjRestTried or {}
            vehicle._adjRestTried[rr.marker] = true
            vehicle._adjRestBlockedUntil = g_time + ADJobs.REST_BLOCK_TIME
            Logging.info("[AD Jobs] Auftrag %d '%s': Rest-Lieferung beendet, %d l noch im Anhänger - keine automatische Rest-Lieferung für %d min",
                job.id, tostring(job.name), math.floor(rest), ADJobs.REST_BLOCK_TIME / 60000)
        else
            vehicle._adjRestTried = nil
            vehicle._adjRestBlockedUntil = nil
            Logging.info("[AD Jobs] Auftrag %d '%s': Rest abgeliefert", job.id, tostring(job.name))
        end
        return false
    end
    local idx = ADJobs.getMarkerIndexByName(rr.marker)
    local speed = vehicle.getLastSpeed ~= nil and vehicle:getLastSpeed() or 0
    if idx ~= nil and ADJobs.isNearMarker(vehicle, idx) and speed < 0.5 then
        if rr.atLevel == nil or math.abs(rr.atLevel - rest) > 0.5 then
            rr.atLevel, rr.atSince = rest, g_time
        elseif g_time - rr.atSince > ADJobs.UNLOAD_STALL_TIME then
            Logging.warning("[AD Jobs] Auftrag %d '%s': '%s' nimmt den Rest nicht an - parkt, keine automatische Rest-Lieferung für %d min", job.id, tostring(job.name), rr.marker, ADJobs.REST_BLOCK_TIME / 60000)
            vehicle._adjRestTried = vehicle._adjRestTried or {}
            vehicle._adjRestTried[rr.marker] = true
            vehicle._adjRestBlockedUntil = g_time + ADJobs.REST_BLOCK_TIME
            job.restRun = nil
            ADJobs.parkVehicle(nil, vehicle)
            return false
        end
    else
        rr.atLevel = nil
    end
    job.state, job.msgCode = ADJobs.ST_RESTRUN, 0
    return true
end

--- is the combination already (almost) full with the fill type of the job? Then AutoDrive should deliver
--- first instead of driving to the load target
function ADJobs.isLoadedForDelivery(job, vehicle)
    local loaded, capacity = ADJobs.getLoad(job, vehicle)
    if capacity > 0 and loaded >= capacity * ADJobs.DELIVER_FIRST_LEVEL then
        return true
    end
    -- a part load of the job's fill type and nothing to top it up with (storage at the load target empty):
    -- deliver what is there
    return loaded >= ADJobs.SOURCE_EMPTY_LEVEL and ADJobs.allSourcesEmpty(job, vehicle)
end

--- AutoDrive is about to drive to the load target (it always does after an unloading): if the trailer is
--- already full of the job's fill type, make "drive to the unload target" the next task instead
function ADJobs.deliverFirstIfLoaded(job, vehicle, mode)
    local PDM = ADJobs.PDM
    if PDM == nil or mode == nil or PDM.STATE_PICKUP == nil or not ADJobs.isLoadedForDelivery(job, vehicle) then
        return false
    end
    mode.state = PDM.STATE_PICKUP
    Logging.info("[AD Jobs] Auftrag %d '%s': Anhänger ist schon voll - fährt zuerst abladen", job.id, tostring(job.name))
    return true
end

--- cargo in the combination that does not belong to this job (e.g. a straw rest before a hay job):
--- returns fill type index and liters of the biggest such rest, or nil
function ADJobs.getForeignCargo(job, vehicle)
    local ftName = (job.loadFillTypeName or "") ~= "" and job.loadFillTypeName or nil
    local ft = ftName ~= nil and g_fillTypeManager:getFillTypeIndexByName(ftName) or nil
    if ft == nil and vehicle.ad ~= nil and vehicle.ad.stateModule.getFillType ~= nil then
        ft = vehicle.ad.stateModule:getFillType()
    end
    if ft == nil then
        return nil
    end
    for _, r in ipairs(ADJobs.getRest(vehicle)) do
        if r.ft ~= ft and r.level > 50 then
            return r.ft, r.level
        end
    end
    return nil
end

--- checks whether the vehicle can be started; returns msgCode (0 = ok), isError
function ADJobs.checkReady(job, vehicle)
    local parkIdx = nil
    if (job.parkMarker or "") ~= "" then
        parkIdx = ADJobs.getMarkerIndexByName(job.parkMarker)
        if parkIdx == nil then
            return 13, true
        end
        if vehicle == nil then
            return 14, true
        end
    end
    if vehicle == nil or vehicle.ad == nil then
        return 2, true
    end
    if ADJobs.getMarkerIndexByName(job.loadMarker) == nil then
        return 3, true
    end
    local loadMode = job.driveMode == "load"
    if (not loadMode or (job.unloadMarker or "") ~= "") and ADJobs.getMarkerIndexByName(job.unloadMarker) == nil then
        return 4, true
    end
    for _, other in ipairs(ADJobs.jobs) do
        if other ~= job and (other.running or other.swap ~= nil) and other._veh ~= nil and other._veh == vehicle then
            return 11, false
        end
    end
    local sm = vehicle.ad.stateModule
    if sm:isActive() or (vehicle.getIsControlled ~= nil and vehicle:getIsControlled())
        or (vehicle.getIsAIActive ~= nil and vehicle:getIsAIActive()) then
        return 7, false
    end
    if ADJobs.hasRotateTargets(vehicle) and not hasOwnRotateSetting(vehicle) then
        -- AutoDrive would replace the job targets by the next target of the folder
        return 19, true
    end
    local implCode = ADJobs.checkImplement(job, vehicle)
    if loadMode then
        -- the right implement must be attached
        if implCode ~= 0 then
            return implCode, false
        end
        if ADJobs.getForeignCargo(job, vehicle) ~= nil then
            return 26, false
        end
        if ADJobs.allSourcesEmpty(job, vehicle) then
            return 27, false
        end
        -- feeder: only from its park position or its waiting place (not while working on a field)
        local atPark = parkIdx ~= nil and ADJobs.isNearMarker(vehicle, parkIdx)
        local waitName = (job.unloadMarker or "") ~= "" and job.unloadMarker or job.returnMarker
        local waitIdx = ADJobs.getMarkerIndexByName(waitName)
        local atWait = waitIdx ~= nil and ADJobs.isNearMarker(vehicle, waitIdx)
        if not atPark and not atWait then
            return 16, false
        end
        -- nothing may be pumped / overloaded right now
        if g_time - (job.stableSince or g_time) < ADJobs.STABLE_TIME then
            return 12, false
        end
        return ADJobs.checkLoadSpace(vehicle)
    end
    parkIdx = parkIdx or ADJobs.AD:GetParkDestination(vehicle)
    if parkIdx == nil then
        return 5, true
    end
    local marker = ADJobs.GM:getMapMarkerById(parkIdx)
    local wp = marker ~= nil and ADJobs.GM:getWayPointById(marker.id)
    if not wp then
        return 5, true
    end
    local x, _, z = getWorldTranslation(vehicle.rootNode)
    local atPark = MathUtil.vector2Length(x - wp.x, z - wp.z) <= ADJobs.PARK_DISTANCE
    if not atPark and implCode == 0 then
        -- the combination stands at the load or unload target of the job (left there by hand or by another
        -- job): it is watched and started from there as well; AutoDrive delivers first if it is loaded
        local names = ADJobs.getLoadMarkers(job)
        table.insert(names, job.unloadMarker)
        for _, name in ipairs(names) do
            local idx = (name or "") ~= "" and ADJobs.getMarkerIndexByName(name) or nil
            if idx ~= nil and ADJobs.isNearMarker(vehicle, idx) then
                atPark = true
                break
            end
        end
    end
    if not atPark and ADJobs.usesSwap(job) and implCode == 0 then
        -- just swapped: the vehicle stands at the stand of the job trailer and starts from there
        local standIdx = ADJobs.getMarkerIndexByName(ADJobs.getSwapMarker(job))
        atPark = standIdx ~= nil and ADJobs.isNearMarker(vehicle, standIdx)
    end
    if not atPark then
        return 6, false
    end
    -- the right implement must be attached (checked after the park position: code 20 "job trailer
    -- not attached" then means "idle at the park position with the wrong trailer" -> swap trailers)
    if implCode ~= 0 then
        return implCode, false
    end
    -- something else is still loaded (rest of another job): AutoDrive would deliver it to this job's target
    local foreignFt, foreignLevel = ADJobs.getForeignCargo(job, vehicle)
    if foreignFt ~= nil then
        if job._foreignLogged ~= foreignFt then
            job._foreignLogged = foreignFt
            local fillType = g_fillTypeManager:getFillTypeByIndex(foreignFt)
            Logging.info("[AD Jobs] Auftrag %d '%s': %s hat noch %d l %s geladen - startet nicht", job.id, tostring(job.name),
                ADJobs.getVehicleName(vehicle), math.floor(foreignLevel), fillType ~= nil and tostring(fillType.title) or tostring(foreignFt))
        end
        return 26, false
    end
    job._foreignLogged = nil
    -- the storage at the load target is empty: do not drive there (a full trailer still delivers first)
    if ADJobs.allSourcesEmpty(job, vehicle) and not ADJobs.isLoadedForDelivery(job, vehicle) then
        return 27, false
    end
    return ADJobs.checkLoadSpace(vehicle)
end

function ADJobs.isNearMarker(vehicle, markerIdx)
    local marker = ADJobs.GM:getMapMarkerById(markerIdx)
    local wp = marker ~= nil and ADJobs.GM:getWayPointById(marker.id)
    if not wp then
        return false
    end
    local x, _, z = getWorldTranslation(vehicle.rootNode)
    return MathUtil.vector2Length(x - wp.x, z - wp.z) <= ADJobs.PARK_DISTANCE
end

--- is the right implement attached? 0 = ok, otherwise message code
---   watched object is a trailer: it must hang on this vehicle
---   load fill type set: some attached load space must take it
function ADJobs.checkImplement(job, vehicle)
    local units = ADJobs.getVehicleUnits(vehicle)
    -- job bound to one trailer: exactly that one must be part of the combination
    if ADJobs.usesSwap(job) and not ADJobs.hasTrailerUid(vehicle, job.swapTrailerUid) then
        return 20
    end
    if job.sourceKind == "vehicle" then
        local watched = ADJobs.findPlaceable(job)
        if watched ~= nil and watched ~= vehicle then
            local found = false
            for _, v in ipairs(units) do
                if v == watched then
                    found = true
                end
            end
            if not found then
                return 17
            end
        end
    end
    local ftName = job.loadFillTypeName
    if ftName ~= nil and ftName ~= "" then
        local ft = g_fillTypeManager:getFillTypeIndexByName(ftName)
        if ft ~= nil then
            for _, v in ipairs(units) do
                local spec = v.spec_fillUnit
                if spec ~= nil and spec.fillUnits ~= nil then
                    for _, fillUnit in ipairs(spec.fillUnits) do
                        if fillUnit.supportedFillTypes ~= nil and fillUnit.supportedFillTypes[ft] then
                            return 0
                        end
                    end
                end
            end
            return 18
        end
    end
    return 0
end

function ADJobs.checkLoadSpace(vehicle)
    local units = ADJobs.AD.getAllUnits(vehicle)
    if units == nil or #units == 0 then
        return 8, false
    end
    local _, capacity = ADJobs.AD.getAllFillLevels(units)
    if capacity == nil or capacity <= 0 then
        return 8, false
    end
    return 0, false
end

--- AD target nearest to the vehicle (except the load target), used as automatic return position
function ADJobs.getNearestMarkerName(vehicle, exceptName)
    local x, _, z = getWorldTranslation(vehicle.rootNode)
    local bestName, bestDist = nil, math.huge
    for _, marker in pairs(ADJobs.GM:getMapMarkers()) do
        if marker.name ~= exceptName then
            local wp = ADJobs.GM:getWayPointById(marker.id)
            if wp ~= nil then
                local d = MathUtil.vector2Length(wp.x - x, wp.z - z)
                if d < bestDist then
                    bestName, bestDist = marker.name, d
                end
            end
        end
    end
    return bestName
end

--- a parked vehicle nobody sits in is "sleeping": the game does not update it, so AutoDrive would
--- only drive off once the player enters it. Wake it (and everything attached) up.
function ADJobs.wakeVehicle(vehicle)
    for _, v in ipairs(ADJobs.getVehicleUnits(vehicle)) do
        if v.raiseActive ~= nil then
            v:raiseActive()
        end
    end
end

--- "Weizen (ausgewählt: Weizen, Gerste)" - what AutoDrive will try to load, for the log
function ADJobs.describeAdFillType(sm)
    local ok, text = pcall(function()
        local function title(ft)
            local fillType = ft ~= nil and g_fillTypeManager:getFillTypeByIndex(ft) or nil
            return fillType ~= nil and (fillType.title or fillType.name) or tostring(ft)
        end
        local names = {}
        if sm.getSelectedFillTypes ~= nil then
            for _, ft in ipairs(sm:getSelectedFillTypes() or {}) do
                table.insert(names, title(ft))
            end
        end
        return string.format("%s (ausgewählt: %s)", title(sm:getFillType()), #names > 0 and table.concat(names, ", ") or "-")
    end)
    return ok and text or "?"
end

function ADJobs.startRun(job, vehicle)
    local sm = vehicle.ad.stateModule
    job._triedLoad, job._switchLoad, job._srcWatch, job._unWatch, job._unloadStuck, job._standSince = nil, nil, nil, nil, nil, nil
    job._watch, job.stuckLoadWarn, job.quickEndWarn = nil, nil, nil
    local loadIdx = ADJobs.getMarkerIndexByName(ADJobs.chooseLoadMarker(job, nil) or job.loadMarker)
    local unloadName = job.unloadMarker
    if job.driveMode == "load" and (unloadName == nil or unloadName == "") then
        unloadName = ADJobs.getNearestMarkerName(vehicle, job.loadMarker)
    end
    local unloadIdx = ADJobs.getMarkerIndexByName(unloadName)
    if loadIdx == nil or unloadIdx == nil then
        return false
    end
    job.returnMarker = unloadName
    job.savedLoopCounter = sm:getLoopCounter()
    ADJobs.saveMarkers(job, sm)
    ADJobs.suspendRotate(job, vehicle)
    if job.driveMode == "load" then
        -- AutoDrive "Laden": 2nd target = load, 1st target = where to go afterwards, then AD switches off
        sm:setMode(ADJobs.AD.MODE_LOAD or 4)
        ADJobs.disableAutomaticTargets(sm)
        sm:raiseDirtyFlag()
        local fillTypeSet = false
        if job.loadFillTypeName ~= nil and job.loadFillTypeName ~= "" then
            local ft = g_fillTypeManager:getFillTypeIndexByName(job.loadFillTypeName)
            if ft ~= nil then
                sm:setFillType(ft)
                fillTypeSet = true
            end
        end
        ADJobs.AD:StartDriving(vehicle, unloadIdx, loadIdx, nil, nil, nil)
        ADJobs.wakeVehicle(vehicle)
        if sm:isActive() then
            job.running = true
            job.startTime = g_time
            Logging.info("[AD Jobs] Auftrag %d '%s' gestartet (Laden): %s, laden bei %s, zurück zu %s, Ladegut AD: %s", job.id, tostring(job.name), ADJobs.getVehicleName(vehicle), job.loadMarker, unloadName, ADJobs.describeAdFillType(sm))
            return true
        end
        ADJobs.restoreMarkers(job, sm)
        sm:raiseDirtyFlag()
        return false
    end
    sm:setMode(ADJobs.AD.MODE_PICKUPANDDELIVER or 2)
    ADJobs.disableAutomaticTargets(sm)
    -- with the hook the job decides after every unloading whether to go on (loop counter 0 = unlimited)
    sm:setLoopCounter(ADJobs.hooksInstalled and 1 or (job.maxTrips or 0))
    sm:setLoopsDone(0)
    if job.loadFillTypeName ~= nil and job.loadFillTypeName ~= "" then
        local ft = g_fillTypeManager:getFillTypeIndexByName(job.loadFillTypeName)
        if ft ~= nil then
            sm:setFillType(ft)
        end
    end
    sm:raiseDirtyFlag()
    ADJobs.AD:StartDriving(vehicle, loadIdx, unloadIdx, nil, nil, nil)
    ADJobs.wakeVehicle(vehicle)
    if sm:isActive() then
        job.running = true
        job.startTime = g_time
        job.tripsDone = 0
        -- AutoDrive delivers first only if the trailer reached the vehicle's "unload fill level" setting;
        -- a (nearly) full trailer of the job's fill type goes to the unload target right away
        if ADJobs.hooksInstalled and ADJobs.PDM ~= nil and ADJobs.isLoadedForDelivery(job, vehicle) and sm.getCurrentMode ~= nil then
            local mode = sm:getCurrentMode()
            if mode ~= nil and mode.state == ADJobs.PDM.STATE_PICKUP_FROM_NEXT_TARGET and mode.continue ~= nil then
                Logging.info("[AD Jobs] Auftrag %d '%s': Anhänger ist schon voll - fährt zuerst abladen", job.id, tostring(job.name))
                mode:continue()
            end
        end
        Logging.info("[AD Jobs] Auftrag %d '%s' gestartet: %s, %s -> %s, Ladegut AD: %s", job.id, tostring(job.name), ADJobs.getVehicleName(vehicle), job.loadMarker, unloadName, ADJobs.describeAdFillType(sm))
        return true
    end
    sm:setLoopCounter(job.savedLoopCounter or 0)
    ADJobs.restoreMarkers(job, sm)
    sm:raiseDirtyFlag()
    return false
end

function ADJobs.updateJob(job)
    ADJobs.migrateParkMarker(job)
    if job.driveMode == "sequence" then
        -- sequence of Courseplay courses (AdJobsSequence.lua): no fill level rules
        ADJobs.updateSequence(job)
        return
    end
    local placeable = ADJobs.findPlaceable(job)
    if placeable ~= nil and job.sourceKind ~= "vehicle" then
        local label = ADJobs.getPlaceableLabel(placeable)
        if label ~= nil and label ~= job.placeableName then
            -- e.g. "Kuhstall" -> "Kuhstall #2" once a second barn of that kind is there
            if job.name == string.format("%s - %s", tostring(job.placeableName), ADJobs.getMeasureLabel(job)) then
                job.name = string.format("%s - %s", label, ADJobs.getMeasureLabel(job))
            end
            job.placeableName = label
            ADJobs.lastSyncKey = nil
        end
    end
    local level, capacity = ADJobs.measure(placeable, job.sourceKind, job.fillTypeName)
    job.level = level or 0
    job.capacity = capacity or 0
    job.percent = ADJobs.getPercent(level, capacity)
    job.pauseLeft = 0
    if level == nil or job.lastLevel == nil or math.abs(level - job.lastLevel) > 0.5 then
        job.stableSince = g_time
    end
    job.lastLevel = level
    local loadMode = job.driveMode == "load"

    if job.running then
        local vehicle = ADJobs.findVehicle(job)
        if vehicle == nil or vehicle.ad == nil then
            job.running = false
            job.state, job.msgCode = ADJobs.ST_ERROR, 2
            return
        end
        local sm = vehicle.ad.stateModule
        if not loadMode and not ADJobs.hooksInstalled then
            job.tripsDone = sm:getLoopsDone() or 0
        end
        -- the player switched AutoDrive to another mode (own park key, "drive to" ...): the run is over
        if sm:isActive() and ADJobs.hooksInstalled and not job._parking and job._dumping == nil and sm.getMode ~= nil then
            local expected = loadMode and (ADJobs.AD.MODE_LOAD or 4) or (ADJobs.AD.MODE_PICKUPANDDELIVER or 2)
            if sm:getMode() ~= expected then
                ADJobs.endJobByPlayer(job, vehicle)
                return
            end
        end
        if sm:isActive() and loadMode then
            job.state, job.msgCode = ADJobs.ST_RUN, 0
        elseif sm:isActive() then
            local targetReached = not job.active or ADJobs.targetReached(job)
            if ADJobs.hooksInstalled then
                -- only the display; the vehicle is stopped / sent on right after the current unloading
                if job._dumping ~= nil then
                    job.state = ADJobs.ST_DUMP
                elseif job._parking then
                    job.state = ADJobs.ST_STOPPING
                else
                    job.state = targetReached and ADJobs.ST_STOPPING or ADJobs.ST_RUN
                end
            elseif job.state ~= ADJobs.ST_STOPPING and targetReached then
                ADJobs.requestStop(job)
                job.state = ADJobs.ST_STOPPING
            elseif job.state ~= ADJobs.ST_STOPPING then
                job.state = ADJobs.ST_RUN
            end
            job.msgCode = 0
            -- AutoDrive is active, but the vehicle has not moved for a while: say so (and where)
            local speed = vehicle.getLastSpeed ~= nil and vehicle:getLastSpeed() or 0
            if speed > 0.5 then
                job._standSince = nil
            else
                job._standSince = job._standSince or g_time
                local standing = g_time - job._standSince
                if standing >= ADJobs.STAND_SHOW_TIME and (job.state == ADJobs.ST_RUN or job.state == ADJobs.ST_STOPPING) then
                    local where = 0
                    local first = sm.getFirstMarker ~= nil and sm:getFirstMarker() or nil
                    local second = sm.getSecondMarker ~= nil and sm:getSecondMarker() or nil
                    local fi = type(first) == "table" and first.name ~= nil and ADJobs.getMarkerIndexByName(first.name) or nil
                    local si = type(second) == "table" and second.name ~= nil and ADJobs.getMarkerIndexByName(second.name) or nil
                    if si ~= nil and ADJobs.isNearMarker(vehicle, si) then
                        where = 2
                    elseif fi ~= nil and ADJobs.isNearMarker(vehicle, fi) then
                        where = 1
                    end
                    job.state = ADJobs.ST_STANDING
                    job.pauseLeft = math.floor(standing / 1000)
                    job.standWhere = where
                end
            end
        elseif g_time - (job.startTime or 0) > ADJobs.START_GRACE then
            if loadMode then
                job.running = false
                -- give the vehicle its AutoDrive HUD settings back (mode, targets, fill type)
                ADJobs.restoreMarkers(job, sm)
                sm:raiseDirtyFlag()
                job.tripsDone = (job.tripsDone or 0) + 1
                job.tripsTotal = (job.tripsTotal or 0) + 1
                -- still below the limit after loading (e.g. load target empty): wait before trying again
                if ADJobs.needsRun(job) then
                    job.pauseUntil = g_time + (job.pauseMin or 0) * 60000
                end
                job.stableSince = g_time
                -- now it stands at the waiting place: park if the level does not change for pauseMin minutes
                job.waitSince = g_time
                job.waitLevel = level
                job._waitVehicle = vehicle
                Logging.info("[AD Jobs] Auftrag %d '%s' beendet (Laden), Stand %d %%", job.id, tostring(job.name), math.floor(job.percent))
            else
                local short = (job.tripsDone or 0) == 0 and g_time - (job.startTime or 0) < ADJobs.QUICK_END_TIME
                ADJobs.finishRun(job)
                if (job.maxTrips or 0) > 0 and (job.tripsDone or 0) >= job.maxTrips and job.percent >= 0 and not ADJobs.targetReached(job) then
                    job.pauseUntil = g_time + (job.pauseMin or 0) * 60000
                end
                -- AutoDrive switched itself off again right after the start, without a single delivery (no load
                -- trigger reached, no route, AD error message ...): the rule would start it again in 2 s - a loop.
                -- Twice in a row: pause the job and say so.
                if short then
                    if job._quickEndSince == nil or g_time - job._quickEndSince > 10 * 60000 then
                        job._quickEndSince, job._quickEnds = g_time, 0
                    end
                    job._quickEnds = job._quickEnds + 1
                    if job._quickEnds >= 2 then
                        job._quickEnds, job._quickEndSince = 0, nil
                        job.pauseUntil = g_time + math.max(job.pauseMin or 0, ADJobs.PARK_PAUSE_MIN) * 60000
                        job.quickEndWarn = true
                        Logging.warning("[AD Jobs] Auftrag %d '%s': AutoDrive hat die Fahrt zweimal direkt nach dem Start ohne Abladen beendet - Pause %d min (Ladeziel '%s', Ladegut %s: Trigger erreichbar? AutoDrive-Meldung im Spiel beachten)",
                            job.id, tostring(job.name), math.max(job.pauseMin or 0, ADJobs.PARK_PAUSE_MIN), tostring(job.loadMarker), tostring(job.loadFillTypeName))
                    end
                else
                    job._quickEnds, job._quickEndSince = 0, nil
                end
            end
            if job.swap == nil then
                -- (finishRun may have started the swap back; then the swap owns the state)
                job.state = job.active and ADJobs.ST_WAIT or ADJobs.ST_OFF
            end
        end
        return
    end

    -- trailer swap going on: it owns the vehicle and the state until it is done
    if job.swap ~= nil and ADJobs.updateSwap(job) then
        return
    end
    -- delivering a rest of another fill type
    if job.restRun ~= nil and ADJobs.updateRestDelivery(job) then
        return
    end

    if not loadMode and ADJobs.hooksInstalled then
        local v = ADJobs.findVehicle(job)
        if v ~= nil and ADJobs.tryAdopt(job, v) then
            return
        end
    end
    -- the job trailer still hangs on from an earlier run (e.g. savegame loaded in the middle of a swap,
    -- or the job was switched off): put the other trailer back on as soon as the vehicle rests at the park position
    if job.savedRotate ~= nil and not job.running then
        local v = ADJobs.getVehicleByUid(job.vehicleUid)
        if v ~= nil and v.ad ~= nil and not v.ad.stateModule:isActive() then
            ADJobs.restoreRotate(job, v)
        end
    end
    if ADJobs.pendingSwapBack(job) then
        return
    end
    if not job.active then
        job.state, job.msgCode = ADJobs.ST_OFF, 0
        return
    end
    if placeable == nil then
        job.state, job.msgCode = ADJobs.ST_ERROR, 1
        return
    end
    if job.percent < 0 then
        job.state, job.msgCode = ADJobs.ST_ERROR, 9
        return
    end
    if loadMode and ADJobs.updateWaitingPlace(job, level) then
        return
    end
    if job.pauseUntil ~= nil then
        if g_time < job.pauseUntil then
            local pv = job._parkVehicle
            if pv ~= nil and not pv.isDeleted and pv.ad ~= nil and pv.ad.stateModule:isActive() then
                -- ended by the player: the vehicle is still on its way to the park position
                job.state = ADJobs.ST_SENTPARK
            else
                job._parkVehicle = nil
                job.state = ADJobs.ST_PAUSE
            end
            job.pauseLeft = math.ceil((job.pauseUntil - g_time) / 60000)
            job.msgCode = job.stuckWarn and 25 or (job.stuckLoadWarn and 29 or (job.quickEndWarn and 38 or 0))
            return
        end
        job.pauseUntil = nil
        job._parkVehicle = nil
    end

    local vehicle = ADJobs.findVehicle(job)
    local msgCode, isError = ADJobs.checkReady(job, vehicle)
    if not ADJobs.needsRun(job) then
        -- level ok, only report problems that need fixing
        job.state = isError and ADJobs.ST_ERROR or ADJobs.ST_WAIT
        job.msgCode = isError and msgCode or 0
        return
    end
    if not ADJobs.priceOk(job) then
        -- haul away: not worth it yet
        job.state = isError and ADJobs.ST_ERROR or ADJobs.ST_PRICE
        job.msgCode = isError and msgCode or 0
        return
    end
    if msgCode == 20 and ADJobs.usesSwap(job) and vehicle ~= nil then
        -- idle at the park position, but another trailer hangs on: swap trailers first
        if ADJobs.startSwap(job, vehicle, "out") then
            return
        end
        -- (job trailer gone / stands missing: startSwap has set the error)
        return
    end
    if msgCode == 26 and vehicle ~= nil then
        -- another fill type is still on the trailer: deliver it where there is space, then this job can start
        if ADJobs.startRestDelivery(job, vehicle) then
            return
        end
        job.state, job.msgCode = ADJobs.ST_NOTREADY, 28
        return
    end
    if msgCode ~= 0 then
        job.state = isError and ADJobs.ST_ERROR or ADJobs.ST_NOTREADY
        job.msgCode = msgCode
        return
    end
    if not loadMode then
        local free = ADJobs.getFreeSpace(job)
        if free ~= nil and free < ADJobs.getMinLoad(job, vehicle) then
            job.state, job.msgCode = ADJobs.ST_NOTREADY, job.direction == "empty" and 37 or 15
            return
        end
    end
    if ADJobs.startRun(job, vehicle) then
        job.waitSince, job.waitLevel, job.idleParkLevel = nil, nil, nil
        job._dumping, job._dumpTried, job._lastTrip, job._watch = nil, nil, nil, nil
        job.state, job.msgCode = ADJobs.ST_RUN, 0
    else
        job.state, job.msgCode = ADJobs.ST_ERROR, 10
    end
end

--- AutoDrive "drive to" / "deliver to" one marker: the modes only use the first target, so the
--- second target of the player's AutoDrive HUD is kept (StartDriving would overwrite it); true if AD drives
function ADJobs.startDriveTo(vehicle, idx, mode)
    local sm = vehicle.ad.stateModule
    sm:setMode(mode or ADJobs.AD.MODE_DRIVETO or 1)
    ADJobs.disableAutomaticTargets(sm)
    sm:raiseDirtyFlag()
    local second = sm.getSecondMarkerId ~= nil and sm:getSecondMarkerId() or nil
    ADJobs.AD:StartDriving(vehicle, idx, idx, nil, nil, nil)
    if type(second) == "number" and second >= 1 and second ~= idx and ADJobs.GM:getMapMarkerById(second) ~= nil then
        pcall(sm.setSecondMarker, sm, second)
    end
    ADJobs.wakeVehicle(vehicle)
    return sm:isActive()
end

--- feeder ("load and return"): drive to the park position (AutoDrive "park")
function ADJobs.sendToPark(job, vehicle)
    local parkIdx = ADJobs.getMarkerIndexByName(job.parkMarker) or ADJobs.AD:GetParkDestination(vehicle)
    if parkIdx == nil then
        return false
    end
    local marker = ADJobs.GM:getMapMarkerById(parkIdx)
    local wp = marker ~= nil and ADJobs.GM:getWayPointById(marker.id)
    if wp then
        local x, _, z = getWorldTranslation(vehicle.rootNode)
        if MathUtil.vector2Length(x - wp.x, z - wp.z) <= ADJobs.PARK_DISTANCE then
            return true -- already there
        end
    end
    Logging.info("[AD Jobs] Auftrag %d '%s': %d min keine Änderung, %s fährt zum Parkplatz", job.id, tostring(job.name), job.pauseMin or 0, ADJobs.getVehicleName(vehicle))
    return ADJobs.startDriveTo(vehicle, parkIdx)
end

-------------------------------------------------------------------------------------------------
-- "send to park": the player ends a job (key, HUD button, or by taking AutoDrive over)
-------------------------------------------------------------------------------------------------

--- the job this vehicle is working for right now (running / swapping), otherwise the first job it serves
function ADJobs.findJobOfVehicle(vehicle)
    if vehicle == nil then
        return nil
    end
    for _, job in ipairs(ADJobs.jobs) do
        if (job.running or job.swap ~= nil) and job._veh == vehicle then
            return job
        end
    end
    local uid = vehicle.getUniqueId ~= nil and vehicle:getUniqueId() or nil
    for _, job in ipairs(ADJobs.jobs) do
        if job._veh == vehicle or (uid ~= nil and job.vehicleUid == uid) then
            return job
        end
    end
    for _, job in ipairs(ADJobs.jobs) do
        if ADJobs.vehicleServesJob(vehicle, job) then
            return job
        end
    end
    return nil
end

--- AutoDrive "drive to" the park position of the vehicle (job: its park position, with the swapped
--- trailer on board the stand of that trailer); returns true if AutoDrive drives
function ADJobs.parkVehicle(job, vehicle)
    if vehicle == nil or vehicle.ad == nil or not ADJobs.resolveAutoDrive() then
        return false
    end
    local parkIdx = nil
    if job ~= nil then
        local cfg = job._swapFrom ~= nil and ADJobs.usesSwap(job._swapFrom) and job._swapFrom or job
        if (job.returnTrailerUid or "") ~= "" and ADJobs.usesSwap(cfg) and ADJobs.hasTrailerUid(vehicle, cfg.swapTrailerUid) then
            parkIdx = ADJobs.getMarkerIndexByName(ADJobs.getSwapMarker(cfg))
        end
        if parkIdx == nil and (job.parkMarker or "") ~= "" then
            parkIdx = ADJobs.getMarkerIndexByName(job.parkMarker)
        end
    end
    if parkIdx == nil then
        local ok, idx = pcall(ADJobs.AD.GetParkDestination, ADJobs.AD, vehicle)
        parkIdx = ok and type(idx) == "number" and idx >= 1 and idx or nil
    end
    if parkIdx == nil then
        return false
    end
    local marker = ADJobs.GM:getMapMarkerById(parkIdx)
    local wp = marker ~= nil and ADJobs.GM:getWayPointById(marker.id)
    local sm = vehicle.ad.stateModule
    if wp and not sm:isActive() then
        local x, _, z = getWorldTranslation(vehicle.rootNode)
        if MathUtil.vector2Length(x - wp.x, z - wp.z) <= ADJobs.PARK_DISTANCE then
            return true -- already there
        end
    end
    ADJobs.stopDriving(vehicle)
    return ADJobs.startDriveTo(vehicle, parkIdx)
end

--- ends whatever the job is doing with its vehicle and pauses the job
local function endJob(job, vehicle)
    local sm = vehicle ~= nil and vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if job.running and sm ~= nil and not sm:isActive() then
        sm:setLoopCounter(job.savedLoopCounter or 0)
        ADJobs.restoreMarkers(job, sm)
        sm:raiseDirtyFlag()
    end
    job.running = false
    job._parking, job._dumping, job._dumpTried, job._watch = nil, nil, nil, nil
    job.swap = nil
    job.waitSince, job.waitLevel, job.idleParkLevel, job._waitVehicle = nil, nil, nil, nil
    if vehicle ~= nil and (job.returnTrailerUid or "") ~= "" then
        -- swap aborted without the job trailer on board: nothing to swap back
        local cfg = job._swapFrom ~= nil and ADJobs.usesSwap(job._swapFrom) and job._swapFrom or job
        if not ADJobs.hasTrailerUid(vehicle, cfg.swapTrailerUid) then
            ADJobs.clearSwapCycle(job, vehicle)
        end
    end
    job.pauseUntil = g_time + math.max(job.pauseMin or 0, ADJobs.PARK_PAUSE_MIN) * 60000
    job.state, job.msgCode = ADJobs.ST_SENTPARK, 0
    ADJobs.lastSyncKey = nil
end

--- key / HUD button: end the job, the vehicle drives to its park position, the job pauses
function ADJobs.endJobAndPark(job, vehicle)
    vehicle = vehicle or job._veh or ADJobs.findVehicle(job)
    if vehicle ~= nil and vehicle.isDeleted then
        vehicle = nil
    end
    if job.restRun ~= nil then
        job.restRun = nil
        if vehicle ~= nil then
            vehicle._adjRestBlockedUntil = g_time + ADJobs.REST_BLOCK_TIME
        end
    end
    if job.driveMode == "sequence" then
        -- park key / button: stop Courseplay and the sequence, park, switch off
        job.active = false
        ADJobs.stopSequence(job, vehicle, nil, true)
        job.state = ADJobs.ST_OFF
        Logging.info("[AD Jobs] Auftrag %d '%s': Ablauf vom Spieler beendet, Fahrzeug parkt", job.id, tostring(job.name))
        return
    end
    local wasRunning = job.running or job.swap ~= nil
    endJob(job, vehicle)
    if vehicle == nil then
        return
    end
    job._parkVehicle = vehicle
    if ADJobs.parkVehicle(job, vehicle) then
        Logging.info("[AD Jobs] Auftrag %d '%s' vom Spieler beendet, %s fährt zum Parkplatz", job.id, tostring(job.name), ADJobs.getVehicleName(vehicle))
    else
        Logging.info("[AD Jobs] Auftrag %d '%s' vom Spieler beendet (%s: kein AutoDrive-Parkplatz / Start fehlgeschlagen)", job.id, tostring(job.name), ADJobs.getVehicleName(vehicle))
    end
    if not wasRunning and not vehicle.ad.stateModule:isActive() then
        -- nothing was going on and the vehicle already stands at the park position: no pause needed
        job.pauseUntil = nil
        job._parkVehicle = nil
        job.state = job.active and ADJobs.ST_WAIT or ADJobs.ST_OFF
    end
end

--- the player took AutoDrive over during a run (own park key, other mode / target): the job ends
function ADJobs.endJobByPlayer(job, vehicle)
    Logging.info("[AD Jobs] Auftrag %d '%s': AutoDrive von %s wurde umgeschaltet - Auftrag beendet", job.id, tostring(job.name), ADJobs.getVehicleName(vehicle))
    endJob(job, vehicle)
    job._parkVehicle = vehicle
end

--- feeder at its waiting place; returns true if the state is decided here
function ADJobs.updateWaitingPlace(job, level)
    -- parked because nothing happened: wait until the level changes (someone pumps / fills)
    if job.idleParkLevel ~= nil then
        if level ~= nil and math.abs(level - job.idleParkLevel) > 0.5 then
            job.idleParkLevel = nil
            return false
        end
        local v = job._waitVehicle
        if v ~= nil and not v.isDeleted and v.ad ~= nil and v.ad.stateModule:isActive() then
            job.state = ADJobs.ST_TOPARK
        else
            job.state = ADJobs.ST_IDLEPARKED
        end
        job.msgCode = 0
        return true
    end
    if job.waitSince == nil or (job.pauseMin or 0) <= 0 then
        return false
    end
    if level ~= nil and job.waitLevel ~= nil and math.abs(level - job.waitLevel) > 0.5 then
        -- something happens at the waiting place: start the time again
        job.waitSince, job.waitLevel = g_time, level
    end
    local vehicle = job._waitVehicle
    if vehicle == nil or vehicle.isDeleted then
        vehicle = ADJobs.findVehicle(job)
    end
    local busy = vehicle == nil or vehicle.ad == nil or vehicle.ad.stateModule:isActive()
        or (vehicle.getIsControlled ~= nil and vehicle:getIsControlled())
    if busy then
        -- somebody uses the vehicle: no parking now
        job.waitSince = g_time
        return false
    end
    local left = job.pauseMin * 60000 - (g_time - job.waitSince)
    if left <= 0 then
        job.waitSince, job.waitLevel = nil, nil
        job.pauseUntil = nil
        job.idleParkLevel = level or 0
        ADJobs.sendToPark(job, vehicle)
        job.state, job.msgCode = ADJobs.ST_TOPARK, 0
        return true
    end
    if job.pauseUntil ~= nil and g_time < job.pauseUntil then
        -- "still too low after loading": the pause is shown, after it the vehicle parks if nothing changed
        return false
    end
    if ADJobs.needsRun(job) then
        -- level dropped (pumped off): the normal start logic takes over
        return false
    end
    job.state, job.msgCode = ADJobs.ST_WAITPLACE, 0
    job.pauseLeft = math.ceil(left / 60000)
    return true
end

function ADJobs.serverUpdate(dt)
    ADJobs.checkTimer = (ADJobs.checkTimer or 0) + dt
    if ADJobs.checkTimer < ADJobs.CHECK_INTERVAL then
        return
    end
    ADJobs.checkTimer = 0
    if not ADJobs.resolveAutoDrive() then
        return
    end
    ADJobs.restorePendingLoopCounters()
    ADJobs.updateOrphans()
    -- priority: the most urgent job decides first, so it gets a shared vehicle (supply: lowest level first,
    -- haul away: fullest first); jobs that run or swap keep their place, unknown levels come last
    local order = {}
    for i, job in ipairs(ADJobs.jobs) do
        local busy = job.running or job.swap ~= nil or job.restRun ~= nil
        -- (order by hand from the "Geplant" tab first, then priority and level)
        local u = busy and -1e6 or ADJobs.planKey(job)
        table.insert(order, {job = job, u = u, i = i})
    end
    table.sort(order, function(a, b)
        if a.u ~= b.u then
            return a.u < b.u
        end
        return a.i < b.i
    end)
    for _, e in ipairs(order) do
        local job = e.job
        local ok, err = pcall(ADJobs.updateJob, job)
        if not ok then
            job.state, job.msgCode = ADJobs.ST_ERROR, 36
            if job._lastErr ~= tostring(err) then
                -- the same error is logged once, not every 2 seconds
                job._lastErr = tostring(err)
                Logging.warning("[AD Jobs] Fehler in Auftrag %s '%s': %s", tostring(job.id), tostring(job.name), tostring(err))
            end
        else
            job._lastErr = nil
        end
    end
    local okPlan, errPlan = pcall(ADJobs.computePlan)
    if not okPlan and ADJobs._planErr ~= tostring(errPlan) then
        ADJobs._planErr = tostring(errPlan)
        Logging.warning("[AD Jobs] Planung: %s", tostring(errPlan))
    end
    -- send the status to the clients if something changed (at most every SYNC_INTERVAL)
    ADJobs.syncTimer = (ADJobs.syncTimer or 0) + ADJobs.CHECK_INTERVAL
    if g_currentMission.missionDynamicInfo ~= nil and g_currentMission.missionDynamicInfo.isMultiplayer and ADJobs.syncTimer >= ADJobs.SYNC_INTERVAL then
        local parts = {}
        for _, job in ipairs(ADJobs.jobs) do
            table.insert(parts, string.format("%d:%d:%d:%d:%d:%d:%s:%s", job.id, job.state or 0, job.msgCode or 0, math.floor(job.percent or -1), job.tripsDone or 0, job.pauseLeft or 0, tostring(job.vehicleName), tostring(job.parkMarker)) .. ":" .. tostring(job.tripsTotal or 0) .. ":" .. tostring(math.floor(job.price or -1)) .. ":" .. tostring(job.seqIndex or 0) .. ":" .. tostring(job.seqPhase or 0) .. ":" .. tostring(job.seqPct or 0) .. ":" .. tostring(job.active)
                .. ":" .. tostring(job.planPos or 0) .. ":" .. tostring(job.planOrder or 0) .. ":" .. tostring(job.planVeh or ""))
        end
        local key = table.concat(parts, ";")
        if key ~= ADJobs.lastSyncKey then
            ADJobs.lastSyncKey = key
            ADJobs.syncTimer = 0
            ADJobs.sendSync()
        end
    end
end

-------------------------------------------------------------------------------------------------
-- savegame
-------------------------------------------------------------------------------------------------

function ADJobs.getSavePath()
    local dir = g_currentMission ~= nil and g_currentMission.missionInfo ~= nil and g_currentMission.missionInfo.savegameDirectory
    if dir == nil or dir == "" then
        return nil
    end
    return dir .. "/autoDriveJobs.xml"
end

function ADJobs.saveJobs()
    if g_server == nil then
        return
    end
    local path = ADJobs.getSavePath()
    if path == nil then
        return
    end
    local xml = createXMLFile("adJobs", path, "autoDriveJobs")
    if xml == nil or xml == 0 then
        return
    end
    setXMLInt(xml, "autoDriveJobs#nextId", ADJobs.nextId)
    for i, job in ipairs(ADJobs.jobs) do
        local key = string.format("autoDriveJobs.job(%d)", i - 1)
        setXMLInt(xml, key .. "#id", job.id)
        setXMLString(xml, key .. "#name", job.name or "")
        setXMLBool(xml, key .. "#active", job.active == true)
        setXMLString(xml, key .. "#driveMode", job.driveMode or "deliver")
        setXMLString(xml, key .. "#placeableUid", job.placeableUid or "")
        setXMLString(xml, key .. "#placeableName", job.placeableName or "")
        setXMLString(xml, key .. "#sourceKind", job.sourceKind or "")
        setXMLString(xml, key .. "#fillType", job.fillTypeName or "")
        setXMLString(xml, key .. "#loadFillType", job.loadFillTypeName or "")
        setXMLFloat(xml, key .. "#low", job.low or 0)
        setXMLFloat(xml, key .. "#high", job.high or 0)
        setXMLInt(xml, key .. "#maxTrips", job.maxTrips or 0)
        setXMLInt(xml, key .. "#pauseMin", job.pauseMin or 0)
        setXMLString(xml, key .. "#vehicleUid", job.vehicleUid or "")
        setXMLString(xml, key .. "#vehicleName", job.vehicleName or "")
        setXMLString(xml, key .. "#loadMarker", job.loadMarker or "")
        setXMLString(xml, key .. "#unloadMarker", job.unloadMarker or "")
        setXMLString(xml, key .. "#emergencyMarker", job.emergencyMarker or "")
        setXMLInt(xml, key .. "#tripsTotal", job.tripsTotal or 0)
        setXMLString(xml, key .. "#returnMarker", job.returnMarker or "")
        setXMLString(xml, key .. "#parkMarker", job.parkMarker or "")
        setXMLInt(xml, key .. "#farmId", job.farmId or 0)
        setXMLString(xml, key .. "#direction", job.direction or "fill")
        setXMLString(xml, key .. "#swapTrailerUid", job.swapTrailerUid or "")
        setXMLString(xml, key .. "#swapMarker", job.swapMarker or "")
        setXMLString(xml, key .. "#swapTrailerName", job.swapTrailerName or "")
        setXMLFloat(xml, key .. "#minPrice", job.minPrice or 0)
        setXMLString(xml, key .. "#group", job.group or "")
        setXMLString(xml, key .. "#extraLoadMarkers", job.extraLoadMarkers or "")
        setXMLString(xml, key .. "#steps", job.steps or "")
        setXMLInt(xml, key .. "#prio", ADJobs.getPrio(job))
        if job.driveMode == "sequence" and job.active and job.seqResume ~= nil then
            setXMLInt(xml, key .. "#seqResume", job.seqResume)
        end
        if job.savedRotate ~= nil then
            setXMLInt(xml, key .. "#savedRotate", job.savedRotate)
        end
        setXMLString(xml, key .. "#parkRestore", job.parkRestore or "")
        setXMLString(xml, key .. "#returnTrailerUid", job.returnTrailerUid or "")
        if (job.planOrder or 0) > 0 then
            setXMLInt(xml, key .. "#planOrder", job.planOrder)
        end
        if job.running and job.savedLoopCounter ~= nil and job.driveMode ~= "load" then
            setXMLInt(xml, key .. "#savedLoopCounter", job.savedLoopCounter)
        end
    end
    local n = 0
    local names = {}
    for name, _ in pairs(ADJobs.markerSources) do
        table.insert(names, name)
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local key = string.format("autoDriveJobs.source(%d)", n)
        setXMLString(xml, key .. "#marker", name)
        setXMLString(xml, key .. "#placeableUid", ADJobs.markerSources[name])
        n = n + 1
    end
    saveXMLFile(xml)
    delete(xml)
end

function ADJobs.loadJobs()
    ADJobs.jobs = {}
    ADJobs.nextId = 1
    local path = ADJobs.getSavePath()
    if path == nil or not fileExists(path) then
        return
    end
    local xml = loadXMLFile("adJobs", path)
    if xml == nil or xml == 0 then
        return
    end
    ADJobs.nextId = getXMLInt(xml, "autoDriveJobs#nextId") or 1
    ADJobs.markerSources = {}
    local si = 0
    while true do
        local key = string.format("autoDriveJobs.source(%d)", si)
        local marker = getXMLString(xml, key .. "#marker")
        if marker == nil then
            break
        end
        ADJobs.setMarkerSource(marker, getXMLString(xml, key .. "#placeableUid"))
        si = si + 1
    end
    local i = 0
    while true do
        local key = string.format("autoDriveJobs.job(%d)", i)
        if not hasXMLProperty(xml, key .. "#id") then
            break
        end
        local job = {
            id = getXMLInt(xml, key .. "#id"),
            name = getXMLString(xml, key .. "#name") or "",
            active = Utils.getNoNil(getXMLBool(xml, key .. "#active"), true),
            driveMode = getXMLString(xml, key .. "#driveMode") or "deliver",
            placeableUid = getXMLString(xml, key .. "#placeableUid") or "",
            placeableName = getXMLString(xml, key .. "#placeableName") or "",
            sourceKind = getXMLString(xml, key .. "#sourceKind") or "",
            fillTypeName = getXMLString(xml, key .. "#fillType") or "",
            loadFillTypeName = getXMLString(xml, key .. "#loadFillType") or "",
            low = getXMLFloat(xml, key .. "#low") or 30,
            high = getXMLFloat(xml, key .. "#high") or 90,
            maxTrips = getXMLInt(xml, key .. "#maxTrips") or 0,
            pauseMin = getXMLInt(xml, key .. "#pauseMin") or 0,
            vehicleUid = getXMLString(xml, key .. "#vehicleUid") or "",
            vehicleName = getXMLString(xml, key .. "#vehicleName") or "",
            loadMarker = getXMLString(xml, key .. "#loadMarker") or "",
            unloadMarker = getXMLString(xml, key .. "#unloadMarker") or "",
            emergencyMarker = getXMLString(xml, key .. "#emergencyMarker") or "",
            tripsTotal = getXMLInt(xml, key .. "#tripsTotal") or 0,
            returnMarker = getXMLString(xml, key .. "#returnMarker"),
            parkMarker = getXMLString(xml, key .. "#parkMarker") or "",
            farmId = getXMLInt(xml, key .. "#farmId") or 0,
            direction = getXMLString(xml, key .. "#direction") == "empty" and "empty" or "fill",
            swapTrailerUid = getXMLString(xml, key .. "#swapTrailerUid") or "",
            swapMarker = getXMLString(xml, key .. "#swapMarker") or "",
            swapTrailerName = getXMLString(xml, key .. "#swapTrailerName") or "",
            minPrice = getXMLFloat(xml, key .. "#minPrice") or 0,
            group = getXMLString(xml, key .. "#group") or "",
            extraLoadMarkers = getXMLString(xml, key .. "#extraLoadMarkers") or "",
            steps = getXMLString(xml, key .. "#steps") or "",
            prio = getXMLInt(xml, key .. "#prio") or ADJobs.PRIO_DEFAULT,
            seqResume = getXMLInt(xml, key .. "#seqResume"),
            savedRotate = getXMLInt(xml, key .. "#savedRotate"),
            parkRestore = getXMLString(xml, key .. "#parkRestore") or "",
            returnTrailerUid = getXMLString(xml, key .. "#returnTrailerUid") or "",
            planOrder = getXMLInt(xml, key .. "#planOrder"),
            state =ADJobs.ST_WAIT, msgCode = 0, percent = -1, level = 0, capacity = 0, tripsDone = 0, pauseLeft = 0
        }
        -- the game was saved during a run: give the vehicle its loop counter back once AD is idle
        job.pendingLoopRestore = getXMLInt(xml, key .. "#savedLoopCounter")
        table.insert(ADJobs.jobs, job)
        ADJobs.nextId = math.max(ADJobs.nextId, job.id + 1)
        i = i + 1
    end
    delete(xml)
    Logging.info("[AD Jobs] %d Aufträge geladen", #ADJobs.jobs)
end

-------------------------------------------------------------------------------------------------
-- mod event listener
-------------------------------------------------------------------------------------------------

function ADJobs:loadMap(name)
    ADJobs.resolveAutoDrive()
    if g_server ~= nil then
        ADJobs.loadJobs()
    end
end

function ADJobs:deleteMap()
    ADJobs.jobs = {}
    ADJobs.orphans = {}
    ADJobs.hudVisible = false
    ADJobsHud.onClose()
end

--- loop counter of jobs that were running when the game was saved (checked every CHECK_INTERVAL,
--- given up after LOOP_RESTORE_TIMEOUT - e.g. the vehicle was sold)
function ADJobs.restorePendingLoopCounters()
    for _, job in ipairs(ADJobs.jobs) do
        if job.pendingLoopRestore ~= nil then
            job.pendingLoopRestoreUntil = job.pendingLoopRestoreUntil or (g_time + ADJobs.LOOP_RESTORE_TIMEOUT)
            local vehicle = ADJobs.findVehicle(job)
            if vehicle ~= nil and vehicle.ad ~= nil and not vehicle.ad.stateModule:isActive() then
                vehicle.ad.stateModule:setLoopCounter(job.pendingLoopRestore)
                vehicle.ad.stateModule:raiseDirtyFlag()
                job.pendingLoopRestore = nil
            elseif vehicle ~= nil and vehicle.ad ~= nil then
                -- AD drives on after loading: watch it like a normal run
                job.running = true
                job.startTime = g_time
                job.savedLoopCounter = job.pendingLoopRestore
                job.pendingLoopRestore = nil
            elseif g_time > job.pendingLoopRestoreUntil then
                Logging.info("[AD Jobs] Auftrag %d '%s': Fahrzeug nicht gefunden, Rundenzähler wird nicht wiederhergestellt", job.id, tostring(job.name))
                job.pendingLoopRestore = nil
            end
        end
    end
end

--- deleted jobs whose vehicle was still driving: restore the AutoDrive settings once it stands still
function ADJobs.updateOrphans()
    for i = #ADJobs.orphans, 1, -1 do
        local job = ADJobs.orphans[i]
        local vehicle = job._veh
        if vehicle == nil or vehicle.isDeleted or vehicle.ad == nil then
            table.remove(ADJobs.orphans, i)
        elseif not vehicle.ad.stateModule:isActive() then
            pcall(ADJobs.finishRun, job)
            table.remove(ADJobs.orphans, i)
        end
    end
end

function ADJobs:update(dt)
    if g_dedicatedServer == nil then
        ADJobs.updateMouseToggle()
    end
    if g_server ~= nil then
        -- the loading / unloading progress is checked every WATCH_INTERVAL, not every frame
        ADJobs.watchTimer = (ADJobs.watchTimer or 0) + dt
        local doWatch = ADJobs.watchTimer >= ADJobs.WATCH_INTERVAL
        if doWatch then
            ADJobs.watchTimer = 0
        end
        for _, job in ipairs(ADJobs.jobs) do
            local vehicle = nil
            if job.running or job.swap ~= nil then
                vehicle = job._veh
            elseif job.restRun ~= nil then
                vehicle = job.restRun.vehicle
            elseif job.idleParkLevel ~= nil then
                -- feeder on its way to the park position
                vehicle = job._waitVehicle
            elseif job._parkVehicle ~= nil then
                vehicle = job._parkVehicle
            end
            if vehicle ~= nil and not vehicle.isDeleted and vehicle.ad ~= nil
                and vehicle.ad.stateModule:isActive() and not vehicle.forceIsActive then
                -- a parked vehicle nobody sits in is "sleeping": keep it awake every frame while AD drives
                ADJobs.wakeVehicle(vehicle)
            end
            -- PERF: the Courseplay progress is sampled every WATCH_INTERVAL (250 ms) instead of every frame -
            -- still far below the 2 s rule check it is meant to bridge
            if doWatch and job.seq ~= nil and vehicle ~= nil and not vehicle.isDeleted then
                pcall(ADJobs.sampleSequence, job, vehicle)
            end
            if job.swap ~= nil and vehicle ~= nil and not vehicle.isDeleted then
                -- reversing towards a trailer: stop right before the couplings touch (checked every frame)
                local ok, err = pcall(ADJobs.updateSwapFast, job, vehicle)
                if not ok and not job._swapErr then
                    job._swapErr = true
                    Logging.warning("[AD Jobs] Umkoppeln überwachen: %s", tostring(err))
                end
            end
            if doWatch and job.running and job.driveMode ~= "sequence" and vehicle ~= nil and not vehicle.isDeleted then
                local ok, err = pcall(ADJobs.watchLoading, job, vehicle)
                if not ok and not job._watchErr then
                    job._watchErr = true
                    Logging.warning("[AD Jobs] Beladung überwachen: %s", tostring(err))
                end
            end
        end
        ADJobs.serverUpdate(dt)
    end
end

--- is AutoDrive itself handling the middle mouse button right now? (player sits in an AD vehicle)
local function autoDriveHandlesMouseToggle()
    local vehicle = nil
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        vehicle = g_localPlayer:getCurrentVehicle()
    end
    if vehicle ~= nil and vehicle.getRootVehicle ~= nil then
        vehicle = vehicle:getRootVehicle()
    end
    return vehicle ~= nil and vehicle.ad ~= nil
end

function ADJobs:draw()
    -- storage numbers in the world (HUD button "L#"), below the HUD
    if ADJobs.hudVisible and ADJobsHud.showStorages and not g_gui:getIsGuiVisible() then
        local ok, err = pcall(ADJobsHud.drawStorageNumbers)
        if not ok and not ADJobs.storageNumErrorShown then
            ADJobs.storageNumErrorShown = true
            Logging.warning("[AD Jobs] Lager-Nummern: %s", tostring(err))
        end
    end
    if ADJobs.hudVisible and not g_gui:getIsGuiVisible() then
        local ok, err = pcall(ADJobsHud.draw)
        if not ok and not ADJobs.drawErrorShown then
            ADJobs.drawErrorShown = true
            Logging.warning("[AD Jobs] HUD: %s", tostring(err))
        end
    end
    -- mouse over a trailer / vehicle in the world: name and AutoDrive park position
    if not g_gui:getIsGuiVisible() and g_inputBinding:getShowMouseCursor() and ADJobs.mouseX ~= nil
        and not (ADJobs.hudVisible and ADJobsHud.isMouseOver()) then
        local ok, err = pcall(ADJobsHud.drawWorldTooltip, ADJobs.mouseX, ADJobs.mouseY)
        if not ok and not ADJobs.tooltipErrorShown then
            ADJobs.tooltipErrorShown = true
            Logging.warning("[AD Jobs] Fahrzeug-Info: %s", tostring(err))
        end
    end
end

--- AutoDrive action "mouse on / off" (key as set for AutoDrive in the controls)
--- cursor on = click in the HUD, camera stands still; cursor off = look around
function ADJobs.onToggleMouseAction()
    if g_gui:getIsGuiVisible() then
        return
    end
    -- our registration of the AutoDrive key may hide AutoDrive's own one, so in an AutoDrive vehicle
    -- the key must work even with the jobs HUD closed (AutoDrive itself only reacts in its vehicles)
    if not ADJobs.hudVisible and not autoDriveHandlesMouseToggle() then
        return
    end
    -- AutoDrive may react to the same key in the same frame (in AD vehicles) or not at all:
    -- decide in the next frame, then the cursor is switched exactly once
    ADJobs.mouseTogglePending = true
end

--- called every frame (client): carries out a pending mouse toggle
function ADJobs.updateMouseToggle()
    local shown = g_inputBinding:getShowMouseCursor()
    if ADJobs.mouseTogglePending then
        ADJobs.mouseTogglePending = false
        if ADJobs.lastCursorShown == nil or shown == ADJobs.lastCursorShown then
            -- nobody else switched it
            shown = not shown
            g_inputBinding:setShowMouseCursor(shown)
        end
    end
    ADJobs.lastCursorShown = shown
end

function ADJobs:mouseEvent(posX, posY, isDown, isUp, button)
    ADJobs.mouseX, ADJobs.mouseY = posX, posY
    if not ADJobs.hudVisible or g_gui:getIsGuiVisible() then
        return
    end
    -- fallback if the AutoDrive action could not be used: middle mouse button (AutoDrive default)
    if not ADJobs.toggleActionRegistered and isDown and button == Input.MOUSE_BUTTON_MIDDLE then
        ADJobs.mouseTogglePending = true
        return
    end
    if not g_inputBinding:getShowMouseCursor() then
        ADJobsHud.onMouseHidden()
        return
    end
    local ok, err = pcall(ADJobsHud.mouseEvent, posX, posY, isDown, isUp, button)
    if not ok then
        Logging.warning("[AD Jobs] HUD: %s", tostring(err))
    end
end

function ADJobs.toggleHud()
    ADJobs.hudVisible = not ADJobs.hudVisible
    if ADJobs.hudVisible then
        if not ADJobs.resolveAutoDrive() then
            g_currentMission:showBlinkingWarning(txt("noAD"), 3000)
        end
        if g_server == nil and g_client ~= nil then
            g_client:getServerConnection():sendEvent(ADJChangeEvent.new(ADJChangeEvent.OP_REQUEST, {id = 0}))
        end
        ADJobsHud.onOpen()
    else
        ADJobsHud.onClose()
    end
    g_inputBinding:setShowMouseCursor(ADJobs.hudVisible)
end

function ADJobs:keyEvent(unicode, sym, modifier, isDown)
end

--- park key: the nearest job vehicle around the player (not the one he sits in, e.g. the feeder waiting
--- next to the field) drives to its park position and its job ends
function ADJobs.onParkAction()
    local own = nil
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        own = g_localPlayer:getCurrentVehicle()
    end
    if own == nil and g_currentMission ~= nil then
        own = g_currentMission.controlledVehicle
    end
    if own ~= nil and own.getRootVehicle ~= nil then
        own = own:getRootVehicle()
    end
    -- where am I? (vehicle, otherwise the camera = player on foot)
    local px, pz = 0, 0
    if own ~= nil and own.rootNode ~= nil then
        local x, _, z = getWorldTranslation(own.rootNode)
        px, pz = x, z
    else
        local camera = g_cameraManager ~= nil and g_cameraManager:getActiveCamera()
        if camera ~= nil and camera ~= 0 then
            local x, _, z = getWorldTranslation(camera)
            px, pz = x, z
        end
    end
    local function isBusy(j)
        return j.state == ADJobs.ST_RUN or j.state == ADJobs.ST_SWAP or j.state == ADJobs.ST_STOPPING or j.state == ADJobs.ST_DUMP or j.state == ADJobs.ST_STANDING
            or j.state == ADJobs.ST_WAITPLACE or j.state == ADJobs.ST_TOPARK
    end
    -- nearest job vehicle within the radius; one that is working / waiting for its job wins over an idle one
    local best, bestVehicle, bestScore = nil, nil, math.huge
    for _, j in ipairs(ADJobs.jobs) do
        local v = ADJobs.getVehicleByUid(j.vehicleUid)
        if v ~= nil and v ~= own and v.ad ~= nil and v.rootNode ~= nil then
            local x, _, z = getWorldTranslation(v.rootNode)
            local dist = MathUtil.vector2Length(x - px, z - pz)
            if dist <= ADJobs.PARK_KEY_RADIUS then
                local score = dist + (isBusy(j) and 0 or ADJobs.PARK_KEY_RADIUS)
                if score < bestScore then
                    best, bestVehicle, bestScore = j, v, score
                end
            end
        end
    end
    if best == nil then
        g_currentMission:showBlinkingWarning(txt("parkNoVehicle", ADJobs.PARK_KEY_RADIUS), 3000)
        return
    end
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, txt("parkSent", tostring(best.name), ADJobs.getVehicleName(bestVehicle)))
    ADJChangeEvent.sendEvent(ADJChangeEvent.OP_PARK, {id = best.id, vehicleObject = bestVehicle})
end

-- save together with the savegame (same hook AutoDrive uses)
ItemSystem.save = Utils.prependedFunction(ItemSystem.save, function()
    local ok, err = pcall(ADJobs.saveJobs)
    if not ok then
        Logging.warning("[AD Jobs] Speichern fehlgeschlagen: %s", tostring(err))
    end
end)

-- while the HUD is open the mouse must not turn the camera (on foot and in vehicles)
--- the camera only stands still while the mouse is over the HUD (or the HUD is being moved);
--- everywhere else you can look around as usual
--- like AutoDrive: while the mouse cursor is shown the camera stands still,
--- with the middle mouse button the cursor is hidden and you can look around
local function isMouseLookBlocked(isMouse)
    if not ADJobs.hudVisible or isMouse == false or g_gui:getIsGuiVisible() then
        return false
    end
    return g_inputBinding:getShowMouseCursor()
end

local function blockLook(self, superFunc, actionName, inputValue, callbackState, isAnalog, isMouse, ...)
    if isMouseLookBlocked(isMouse) then
        return
    end
    return superFunc(self, actionName, inputValue, callbackState, isAnalog, isMouse, ...)
end

if PlayerInputComponent.onInputLookLeftRight ~= nil then
    PlayerInputComponent.onInputLookLeftRight = Utils.overwrittenFunction(PlayerInputComponent.onInputLookLeftRight, blockLook)
end
if PlayerInputComponent.onInputLookUpDown ~= nil then
    PlayerInputComponent.onInputLookUpDown = Utils.overwrittenFunction(PlayerInputComponent.onInputLookUpDown, blockLook)
end
if VehicleCamera ~= nil then
    if VehicleCamera.actionEventLookLeftRight ~= nil then
        VehicleCamera.actionEventLookLeftRight = Utils.overwrittenFunction(VehicleCamera.actionEventLookLeftRight, blockLook)
    end
    if VehicleCamera.actionEventLookUpDown ~= nil then
        VehicleCamera.actionEventLookUpDown = Utils.overwrittenFunction(VehicleCamera.actionEventLookUpDown, blockLook)
    end
    -- mouse wheel over the HUD scrolls the HUD, not the camera
    if VehicleCamera.zoomSmoothly ~= nil then
        VehicleCamera.zoomSmoothly = Utils.overwrittenFunction(VehicleCamera.zoomSmoothly, function(self, superFunc, offset, ...)
            if ADJobs.hudVisible and ADJobsHud ~= nil and ADJobsHud.isMouseOver() then
                return
            end
            return superFunc(self, offset, ...)
        end)
    end
end

-- global key (on foot and in vehicles)
local function addPlayerActionEvents(self, superFunc, ...)
    superFunc(self, ...)
    local _, id = g_inputBinding:registerActionEvent(InputAction.ADJ_HUD, ADJobs, function()
        ADJobs.toggleHud()
    end, false, true, false, true, nil, false)
    if id ~= nil then
        g_inputBinding:setActionEventTextVisibility(id, false)
    end
    if InputAction.ADJ_PARK ~= nil then
        local _, parkId = g_inputBinding:registerActionEvent(InputAction.ADJ_PARK, ADJobs, function()
            ADJobs.onParkAction()
        end, false, true, false, true, nil, false)
        if parkId ~= nil then
            g_inputBinding:setActionEventTextVisibility(parkId, false)
        end
    end
    -- mouse on / off: the same action (and therefore the same key) as AutoDrive ("ADToggleMouse")
    if InputAction.ADToggleMouse ~= nil then
        local ok, toggleId = g_inputBinding:registerActionEvent(InputAction.ADToggleMouse, ADJobs, ADJobs.onToggleMouseAction, false, true, false, true, nil, false)
        if ok and toggleId ~= nil then
            g_inputBinding:setActionEventTextVisibility(toggleId, false)
            ADJobs.toggleActionRegistered = true
        end
    end
end
PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.overwrittenFunction(
    PlayerInputComponent.registerGlobalPlayerActionEvents, addPlayerActionEvents)

addModEventListener(ADJobs)
print("[AD Jobs] geladen (v" .. ADJobs.VERSION .. ")")
