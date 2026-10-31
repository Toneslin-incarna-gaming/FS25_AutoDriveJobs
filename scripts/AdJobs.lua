--
-- AutoDrive Jobs (AD-Aufträge)
-- Rule based supply jobs for AutoDrive:
--   "if <fill level of a building> falls below X %, and <vehicle> is standing at its AutoDrive park
--    position, then drive 'pick up and deliver' between <load target> and <unload target> until the
--    level reaches Y % or N trips are done, then park again."
--
-- The rules run on the server. Clients only show the HUD and send changes to the server.
--

ADJobs = {}
ADJobs.MOD_NAME = g_currentModName
ADJobs.MOD_DIR = g_currentModDirectory
-- version comes from modDesc.xml (single source of truth)
ADJobs.VERSION = "1.5.7.0"
do
    local mod = g_modManager ~= nil and g_modManager.getModByName ~= nil and g_modManager:getModByName(g_currentModName)
    if mod ~= nil and mod.version ~= nil then
        ADJobs.VERSION = mod.version
    end
end
ADJobs.NET_VERSION = 2           -- bump whenever the stream layout of the events changes

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
    msg6 = {"Fahrzeug steht nicht am Parkplatz", "vehicle is not at its park position"},
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
local markerByName, markerCacheSource = {}, nil

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
        markerByName, markerCacheSource = {}, markers
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

local function storageFillTypes(storage)
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
        return txt("kindRobot") .. " " .. (spot and ADJobs.getRobotSpotTitle(spot) or tostring(job.fillTypeName))
    elseif job.sourceKind == "foodGroup" then
        local plc = ADJobs.findPlaceable(job)
        local group = plc and getFoodGroups(plc)[tonumber(job.fillTypeName) or -1]
        return txt("kindFoodGroup") .. " " .. (group and tostring(group.title) or job.fillTypeName)
    else
        local ft = g_fillTypeManager:getFillTypeIndexByName(job.fillTypeName or "")
        return ft and fillTypeTitle(ft) or (job.fillTypeName or "?")
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

--- all AD park positions (marker indices) of a root vehicle and the tools attached to it
function ADJobs.getParkIndices(root)
    local set = {}
    if root == nil then
        return set
    end
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
    local result = {}
    if markerIdx == nil or not ADJobs.resolveAutoDrive() then
        return result
    end
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
    if cached ~= nil and (job.running or job.parkMarker == nil or job.parkMarker == "") then
        return cached
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
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle.getUniqueId ~= nil and vehicle:getUniqueId() == uid then
            vehicleByUid[uid] = vehicle
            return vehicle
        end
    end
    return nil
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

local CONFIG_FIELDS = {"name", "active", "driveMode", "placeableUid", "placeableName", "sourceKind", "fillTypeName", "loadFillTypeName",
    "low", "high", "maxTrips", "pauseMin", "vehicleUid", "vehicleName", "loadMarker", "unloadMarker", "parkMarker", "farmId", "emergencyMarker"}

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
                data.placeableName = data.placeableObject:getName() or data.placeableName
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
        local vehicleChanged = job.vehicleUid ~= data.vehicleUid or job.parkMarker ~= data.parkMarker
        if vehicleChanged and job.running then
            ADJobs.requestStop(job)
            ADJobs.finishRun(job)
        end
        for _, key in ipairs(CONFIG_FIELDS) do
            job[key] = data[key]
        end
        job._plc = nil
        job._veh = nil
        job.pauseUntil = nil
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
            if not job.active and job.running then
                ADJobs.requestStop(job)
                job.state = ADJobs.ST_STOPPING
            end
        end
    elseif op == ADJChangeEvent.OP_RESET then
        local job = ADJobs.getJobById(data.id)
        if job ~= nil then
            job.pauseUntil = nil
            job.msgCode = 0
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
        if job.running and job._veh == vehicle then
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

--- may this vehicle drive the job? (park position of the job is assigned to it)
function ADJobs.vehicleServesJob(vehicle, job)
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
    local best, bestPercent = nil, math.huge
    for _, job in ipairs(ADJobs.jobs) do
        if job ~= current and job.active and not job.running and job.driveMode ~= "load"
            and (job.pauseUntil == nil or g_time >= job.pauseUntil)
            and ADJobs.vehicleServesJob(vehicle, job)
            and ADJobs.getMarkerIndexByName(job.loadMarker) ~= nil and ADJobs.getMarkerIndexByName(job.unloadMarker) ~= nil then
            local p = freshPercent(job)
            local free = ADJobs.getFreeSpace(job)
            local enoughSpace = free == nil or free >= ADJobs.getMinLoad(job, vehicle)
            if p >= 0 and p < (job.low or 0) and p < bestPercent and enoughSpace and ADJobs.checkImplement(job, vehicle) == 0 then
                best, bestPercent = job, p
            end
        end
    end
    return best
end

--- hands the running AutoDrive run of vehicle over from job to nextJob
function ADJobs.chainTo(job, nextJob, vehicle)
    local sm = vehicle.ad.stateModule
    job.running = false
    job._parking = nil
    job._dumping, job._dumpTried = nil, nil
    nextJob._dumping, nextJob._dumpTried = nil, nil
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
    local placeable = ADJobs.findPlaceable(job)
    local level, capacity = ADJobs.measure(placeable, job.sourceKind, job.fillTypeName)
    if level == nil or capacity == nil or capacity <= 0 then
        return nil
    end
    return math.max(0, capacity - level)
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

--- the vehicle drives "pick up and deliver" between the targets of this job, but the job does not
--- know it (game loaded, job edited, started by hand): take the run over again
function ADJobs.tryAdopt(job, vehicle)
    if job.running or job.driveMode == "load" or vehicle == nil or vehicle.ad == nil then
        return false
    end
    local sm = vehicle.ad.stateModule
    if not sm:isActive() or sm:getMode() ~= (ADJobs.AD.MODE_PICKUPANDDELIVER or 2) then
        return false
    end
    local first, second = sm:getFirstMarker(), sm:getSecondMarker()
    if first == nil or second == nil or first.name ~= job.loadMarker or second.name ~= job.unloadMarker then
        return false
    end
    for _, other in ipairs(ADJobs.jobs) do
        if other ~= job and other.running and other._veh == vehicle then
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
    if job == nil or job.driveMode == "load" then
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
    local targetReached = p >= 0 and p >= (job.high or 100)
    local free = ADJobs.getFreeSpace(job)
    local noSpace = free ~= nil and free < ADJobs.getMinLoad(job, vehicle)
    if job.active and job._dumping == nil and not targetReached and not tripsUsedUp and not noSpace then
        -- go on: exactly one more trip (if the job loses track, AutoDrive parks after it)
        sm:setLoopCounter(loopsDone + 1)
        sm:raiseDirtyFlag()
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
        return
    end
    -- rest in the trailer: unload it at another job with the same fill type or at the emergency unload point
    if #rest > 0 then
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
    job._dumping, job._dumpTried = nil, nil
    Logging.info("[AD Jobs] Auftrag %d '%s' beendet nach %d Fahrten", job.id, tostring(job.name), job.tripsDone or 0)
end

--- remembers the targets / fill type the player had chosen in the AutoDrive HUD before a run
function ADJobs.saveMarkers(job, sm)
    job.savedFirst = sm.getFirstMarkerId ~= nil and sm:getFirstMarkerId() or nil
    job.savedSecond = sm.getSecondMarkerId ~= nil and sm:getSecondMarkerId() or nil
    job.savedFillType = sm.getFillType ~= nil and sm:getFillType() or nil
    job.savedMode = sm.getMode ~= nil and sm:getMode() or nil
end

function ADJobs.restoreMarkers(job, sm)
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
        if type(job.savedFillType) == "number" and job.savedFillType >= 1 then
            sm:setFillType(job.savedFillType)
        end
    end)
    job.savedFirst, job.savedSecond, job.savedFillType, job.savedMode = nil, nil, nil, nil
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
        if other ~= job and other.running and other._veh ~= nil and other._veh == vehicle then
            return 11, false
        end
    end
    local sm = vehicle.ad.stateModule
    if sm:isActive() or (vehicle.getIsControlled ~= nil and vehicle:getIsControlled())
        or (vehicle.getIsAIActive ~= nil and vehicle:getIsAIActive()) then
        return 7, false
    end
    if ADJobs.hasRotateTargets(vehicle) then
        -- AutoDrive would replace the job targets by the next target of the folder
        return 19, true
    end
    -- the right implement must be attached
    local implCode = ADJobs.checkImplement(job, vehicle)
    if implCode ~= 0 then
        return implCode, false
    end
    if loadMode then
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
    if MathUtil.vector2Length(x - wp.x, z - wp.z) > ADJobs.PARK_DISTANCE then
        return 6, false
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

function ADJobs.startRun(job, vehicle)
    local sm = vehicle.ad.stateModule
    local loadIdx = ADJobs.getMarkerIndexByName(job.loadMarker)
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
            Logging.info("[AD Jobs] Auftrag %d '%s' gestartet (Laden): %s, laden bei %s, zurück zu %s", job.id, tostring(job.name), ADJobs.getVehicleName(vehicle), job.loadMarker, unloadName)
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
        Logging.info("[AD Jobs] Auftrag %d '%s' gestartet: %s, %s -> %s", job.id, tostring(job.name), ADJobs.getVehicleName(vehicle), job.loadMarker, unloadName)
        return true
    end
    sm:setLoopCounter(job.savedLoopCounter or 0)
    ADJobs.restoreMarkers(job, sm)
    sm:raiseDirtyFlag()
    return false
end

function ADJobs.updateJob(job)
    ADJobs.migrateParkMarker(job)
    local placeable = ADJobs.findPlaceable(job)
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
        if sm:isActive() and loadMode then
            job.state, job.msgCode = ADJobs.ST_RUN, 0
        elseif sm:isActive() then
            local targetReached = not job.active or (job.percent >= 0 and job.percent >= job.high)
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
        elseif g_time - (job.startTime or 0) > ADJobs.START_GRACE then
            if loadMode then
                job.running = false
                -- give the vehicle its AutoDrive HUD settings back (mode, targets, fill type)
                ADJobs.restoreMarkers(job, sm)
                sm:raiseDirtyFlag()
                job.tripsDone = (job.tripsDone or 0) + 1
                job.tripsTotal = (job.tripsTotal or 0) + 1
                -- still below the limit after loading (e.g. load target empty): wait before trying again
                if job.percent >= 0 and job.percent < job.low then
                    job.pauseUntil = g_time + (job.pauseMin or 0) * 60000
                end
                job.stableSince = g_time
                -- now it stands at the waiting place: park if the level does not change for pauseMin minutes
                job.waitSince = g_time
                job.waitLevel = level
                job._waitVehicle = vehicle
                Logging.info("[AD Jobs] Auftrag %d '%s' beendet (Laden), Stand %d %%", job.id, tostring(job.name), math.floor(job.percent))
            else
                ADJobs.finishRun(job)
                if (job.maxTrips or 0) > 0 and (job.tripsDone or 0) >= job.maxTrips and job.percent >= 0 and job.percent < (job.high or 100) then
                    job.pauseUntil = g_time + (job.pauseMin or 0) * 60000
                end
            end
            job.state = job.active and ADJobs.ST_WAIT or ADJobs.ST_OFF
        end
        return
    end

    if not loadMode and ADJobs.hooksInstalled then
        local v = ADJobs.findVehicle(job)
        if v ~= nil and ADJobs.tryAdopt(job, v) then
            return
        end
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
            job.state = ADJobs.ST_PAUSE
            job.pauseLeft = math.ceil((job.pauseUntil - g_time) / 60000)
            job.msgCode = 0
            return
        end
        job.pauseUntil = nil
    end

    local vehicle = ADJobs.findVehicle(job)
    local msgCode, isError = ADJobs.checkReady(job, vehicle)
    if job.percent >= job.low then
        -- level ok, only report problems that need fixing
        job.state = isError and ADJobs.ST_ERROR or ADJobs.ST_WAIT
        job.msgCode = isError and msgCode or 0
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
            job.state, job.msgCode = ADJobs.ST_NOTREADY, 15
            return
        end
    end
    if ADJobs.startRun(job, vehicle) then
        job.waitSince, job.waitLevel, job.idleParkLevel = nil, nil, nil
        job._dumping, job._dumpTried = nil, nil
        job.state, job.msgCode = ADJobs.ST_RUN, 0
    else
        job.state, job.msgCode = ADJobs.ST_ERROR, 10
    end
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
    local sm = vehicle.ad.stateModule
    sm:setMode(ADJobs.AD.MODE_DRIVETO or 1)
    sm:raiseDirtyFlag()
    ADJobs.AD:StartDriving(vehicle, parkIdx, parkIdx, nil, nil, nil)
    ADJobs.wakeVehicle(vehicle)
    Logging.info("[AD Jobs] Auftrag %d '%s': %d min keine Änderung, %s fährt zum Parkplatz", job.id, tostring(job.name), job.pauseMin or 0, ADJobs.getVehicleName(vehicle))
    return sm:isActive()
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
    if job.percent >= 0 and job.percent < job.low then
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
    for _, job in ipairs(ADJobs.jobs) do
        local ok, err = pcall(ADJobs.updateJob, job)
        if not ok then
            job.state, job.msgCode = ADJobs.ST_ERROR, 9
            Logging.warning("[AD Jobs] Fehler in Auftrag %s: %s", tostring(job.id), tostring(err))
        end
    end
    -- send the status to the clients if something changed (at most every SYNC_INTERVAL)
    ADJobs.syncTimer = (ADJobs.syncTimer or 0) + ADJobs.CHECK_INTERVAL
    if g_currentMission.missionDynamicInfo ~= nil and g_currentMission.missionDynamicInfo.isMultiplayer and ADJobs.syncTimer >= ADJobs.SYNC_INTERVAL then
        local parts = {}
        for _, job in ipairs(ADJobs.jobs) do
            table.insert(parts, string.format("%d:%d:%d:%d:%d:%d:%s:%s", job.id, job.state or 0, job.msgCode or 0, math.floor(job.percent or -1), job.tripsDone or 0, job.pauseLeft or 0, tostring(job.vehicleName), tostring(job.parkMarker)) .. ":" .. tostring(job.tripsTotal or 0))
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
        if job.running and job.savedLoopCounter ~= nil and job.driveMode ~= "load" then
            setXMLInt(xml, key .. "#savedLoopCounter", job.savedLoopCounter)
        end
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
            state = ADJobs.ST_WAIT, msgCode = 0, percent = -1, level = 0, capacity = 0, tripsDone = 0, pauseLeft = 0
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
            if job.running then
                vehicle = job._veh
            elseif job.idleParkLevel ~= nil then
                -- feeder on its way to the park position
                vehicle = job._waitVehicle
            end
            if vehicle ~= nil and not vehicle.isDeleted and vehicle.ad ~= nil
                and vehicle.ad.stateModule:isActive() and not vehicle.forceIsActive then
                -- a parked vehicle nobody sits in is "sleeping": keep it awake every frame while AD drives
                ADJobs.wakeVehicle(vehicle)
            end
            if doWatch and job.running and vehicle ~= nil and not vehicle.isDeleted then
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
    if ADJobs.hudVisible and not g_gui:getIsGuiVisible() then
        local ok, err = pcall(ADJobsHud.draw)
        if not ok and not ADJobs.drawErrorShown then
            ADJobs.drawErrorShown = true
            Logging.warning("[AD Jobs] HUD: %s", tostring(err))
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
