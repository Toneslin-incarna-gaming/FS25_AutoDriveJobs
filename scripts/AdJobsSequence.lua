--
-- AutoDrive Jobs - sequence jobs with Courseplay ("Ablauf")
--
-- A job with driveMode "sequence" is a list of steps. Every step:
--   1. AutoDrive drives to an AD target (optional - empty: Courseplay drives there itself)
--   2. the Courseplay course of the step is loaded into the vehicle and started at its first waypoint
--   3. when Courseplay has finished the course, the next step follows
--   With an unload target (forage wagon, loader wagon ...): AutoDrive "pick up and deliver" between
--   the AD target (field) and the unload target with the Courseplay helper switched on - Courseplay works
--   until the wagon is full, AutoDrive unloads, drives back and hands over to Courseplay again (AutoDrive's
--   own Courseplay integration), until the course is done; a rest is unloaded, then the next step.
-- After the last step the vehicle drives to its AD park position and the job switches itself off.
-- Switching the job on starts again with step 1.
--
-- Uses the interface Courseplay offers other mods (vehicle functions appendLoadedCpCourse,
-- startCpAtFirstWp, getIsCpFieldWorkActive, getCpFieldWorkProgress).
--
-- Config field: job.steps = "marker>course|marker>course|..." (course = path below the CP course folder)
-- Runtime:      job.seq = {i, phase, since, ...} (server), job.seqResume (saved: step to go on with)
-- Synced:       job.seqIndex, job.seqCount, job.seqPhase, job.seqPct
--

ADJobs.ST_SEQ = 16                     -- HUD state: sequence running (see seqPhase)
ADJobs.SEQ_PH_DRIVE = 1                -- AutoDrive drives to the AD target of the step
ADJobs.SEQ_PH_CPSTART = 2              -- Courseplay course loaded / started, waiting for it to run
ADJobs.SEQ_PH_CP = 3                   -- Courseplay works
ADJobs.SEQ_PH_PARK = 4                 -- all done, drives to the park position
ADJobs.SEQ_PH_ADCP = 5                 -- AutoDrive + Courseplay together (Courseplay works, AutoDrive unloads when full)
ADJobs.SEQ_PH_UNLOAD = 6               -- unloads what is left after the course (shown also while AD unloads in phase 5)
ADJobs.SEQ_IDLE_TIME = 5000            -- ms neither Courseplay nor AutoDrive must be active before the step counts as over
ADJobs.SEQ_ADCP_START_TIMEOUT = 15 * 60000 -- ms AutoDrive may take to reach the field and hand over to Courseplay
ADJobs.SEQ_CP_START_TIMEOUT = 30000    -- ms Courseplay may take to become active
ADJobs.SEQ_DONE_PROGRESS = 0.95        -- course progress from which a stop of Courseplay counts as "finished"
ADJobs.SEQ_HANDOVER_TIME = 3000        -- ms Courseplay stands (wagon full) before AutoDrive is sent unloading
ADJobs.SEQ_HANDOVER_RETRY = 20000      -- ms before a hand-over that did not start AutoDrive is tried again
ADJobs.SEQ_RESTART_WAIT = 30000        -- ms the AutoDrive flag "restart Courseplay" alone keeps a step alive

-------------------------------------------------------------------------------------------------
-- Courseplay
-------------------------------------------------------------------------------------------------

--- the Courseplay object (g_Courseplay lives in the script environment of the Courseplay mod)
function ADJobs.resolveCourseplay()
    if ADJobs.CP ~= nil then
        return ADJobs.CP
    end
    if g_Courseplay ~= nil then
        ADJobs.CP = g_Courseplay
        ADJobs.CPFile = File
        return ADJobs.CP
    end
    local globalEnv = getfenv(0)
    local candidates = {"FS25_Courseplay"}
    if g_modManager ~= nil and g_modManager.getActiveMods ~= nil then
        for _, mod in ipairs(g_modManager:getActiveMods()) do
            table.insert(candidates, mod.modName)
        end
    end
    for _, modName in ipairs(candidates) do
        local env = globalEnv[modName]
        if type(env) == "table" and type(env.g_Courseplay) == "table" then
            ADJobs.CP = env.g_Courseplay
            ADJobs.CPFile = env.File
            Logging.info("[AD Jobs] Courseplay gefunden in '%s'", modName)
            return ADJobs.CP
        end
    end
    return nil
end

--- all saved Courseplay courses of this map: {path = "Folder/Course", name = "Course", folder = "Folder"}
--- (refresh = read the course folder from disk again first)
function ADJobs.getCpCourses(refresh)
    local list = {}
    local cp = ADJobs.resolveCourseplay()
    if cp == nil or cp.courseStorage == nil then
        return list
    end
    if refresh ~= false then
        pcall(function()
            if cp.courseStorage.refresh ~= nil then
                cp.courseStorage:refresh()
            end
        end)
    end
    local function walk(dir, prefix, depth)
        if dir == nil or depth > 8 then
            return
        end
        for _, f in ipairs(dir:getFiles() or {}) do
            table.insert(list, {path = prefix .. f:getName(), name = f:getName(), folder = prefix, file = f})
        end
        for _, d in ipairs(dir:getDirectories() or {}) do
            walk(d, prefix .. d:getName() .. "/", depth + 1)
        end
    end
    local ok, err = pcall(walk, cp.courseStorage:getRootDirectory(), "", 0)
    if not ok and not ADJobs._cpWalkErrorShown then
        ADJobs._cpWalkErrorShown = true
        Logging.warning("[AD Jobs] Courseplay-Kursordner lesen: %s", tostring(err))
    end
    if #list == 0 and type(ADJobs.CPFile) == "table" then
        -- Courseplay's directory tree is empty (not read yet / read failed): scan the folder ourselves
        local root = nil
        pcall(function()
            root = cp.courseStorage:getRootDirectory():getFullPath()
        end)
        for _, e in ipairs(ADJobs.scanCpCourseDir(root)) do
            local okF, f = pcall(function()
                return ADJobs.CPFile(e.dir, e.name, nil)
            end)
            if okF and f ~= nil then
                table.insert(list, {path = e.path, name = e.name, folder = e.path:sub(1, #e.path - #e.name), file = f})
            end
        end
        if #list > 0 and not ADJobs._cpOwnScanLogged then
            ADJobs._cpOwnScanLogged = true
            Logging.info("[AD Jobs] Courseplay-Kursliste leer - %d Kurse über den Kursordner %s gelesen", #list, tostring(root))
        end
    end
    return list
end

local function lower(s)
    return string.lower(tostring(s or ""))
end

--- "Feld11_düngen" -> "feld11_d?ngen": umlauts and other non-ASCII characters are folded to one "?", so a
--- name matches whatever encoding (UTF-8, Windows code page) the file system or the savegame delivered
local function fold(s)
    return (lower(s):gsub("[\128-\255]+", "?"))
end

local function hex(s)
    return (tostring(s or ""):gsub(".", function(c)
        return string.format("%02X ", string.byte(c))
    end))
end

--- own scan of the Courseplay course folder with the game engine (independent of the directory tree
--- Courseplay keeps in memory): {path = "Folder/Course", name, dir = full path of the folder}
function ADJobs.scanCpCourseDir(root)
    local list = {}
    if root == nil or root == "" or getFiles == nil then
        return list
    end
    local function scan(dir, prefix, depth)
        if depth > 8 then
            return
        end
        local files, dirs = {}, {}
        local target = {}
        function target.cb(_, name, isDirectory)
            if isDirectory then
                table.insert(dirs, name)
            else
                table.insert(files, name)
            end
        end
        getFiles(dir, "cb", target)
        for _, n in ipairs(files) do
            table.insert(list, {path = prefix .. n, name = n, dir = dir})
        end
        for _, d in ipairs(dirs) do
            scan(dir .. "/" .. d, prefix .. d .. "/", depth + 1)
        end
    end
    local ok, err = pcall(scan, root, "", 0)
    if not ok and not ADJobs._cpScanErrorShown then
        ADJobs._cpScanErrorShown = true
        Logging.warning("[AD Jobs] Courseplay-Kursordner mit der Engine lesen: %s", tostring(err))
    end
    return list
end

--- the entry of a course list that matches a stored path: exact, then ignoring upper / lower case, then
--- with folded umlauts, then a course of that name in any folder (if there is only one)
local function pickCourse(list, path)
    local wantName = tostring(path or ""):match("([^/]+)$") or ""
    local function noXml(s)
        return (tostring(s):gsub("%.xml$", ""))
    end
    for _, c in ipairs(list) do
        if c.path == path or noXml(c.path) == path then
            return c, "exakt"
        end
    end
    for _, c in ipairs(list) do
        if lower(noXml(c.path)) == lower(path) then
            return c, "Schreibweise"
        end
    end
    for _, c in ipairs(list) do
        if fold(noXml(c.path)) == fold(path) then
            return c, "Umlaute"
        end
    end
    for _, key in ipairs({lower, fold}) do
        local found, count = nil, 0
        for _, c in ipairs(list) do
            if key(noXml(c.name)) == key(wantName) then
                found, count = c, count + 1
            end
        end
        if count == 1 then
            return found, "Name"
        end
    end
    return nil
end

ADJobs.CP_VEHICLE_PREFIX = "@"   -- step course "@Name" = the course of that name loaded in a vehicle (no file)

--- name of the Courseplay course loaded in a vehicle ("" = unnamed, nil = none)
local function loadedCourseName(v)
    if v == nil or v.isDeleted or v.hasCpCourse == nil or v.getFieldWorkCourse == nil then
        return nil
    end
    local okHas, has = pcall(v.hasCpCourse, v)
    if not okHas or not has then
        return nil
    end
    local okC, course = pcall(v.getFieldWorkCourse, v)
    if not okC or course == nil or course.getName == nil then
        return nil
    end
    return tostring(course:getName() or ""), course
end

--- named Courseplay courses that are loaded in vehicles of the farm (Courseplay keeps them in the savegame,
--- CpAssignedCourses.xml - also courses that were never saved in the course manager):
--- {path = "@Name", name, vehicle, course}
function ADJobs.getVehicleCpCourses(farmId)
    local list, seen = {}, {}
    for _, v in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if farmId == nil or farmId == 0 or v.getOwnerFarmId == nil or v:getOwnerFarmId() == farmId then
            local name, course = loadedCourseName(v)
            if name ~= nil and name ~= "" then
                table.insert(list, {path = ADJobs.CP_VEHICLE_PREFIX .. name, name = name, vehicle = v, course = course, dup = seen[fold(name)] ~= nil})
                seen[fold(name)] = true
            end
        end
    end
    return list
end

--- the vehicle course for a stored path ("@Name" or a file path): the job vehicle itself first, then any
--- other vehicle with a course of that name
function ADJobs.findVehicleCpCourse(path, vehicle, farmId)
    local wantName = tostring(path or ""):gsub("^" .. ADJobs.CP_VEHICLE_PREFIX, ""):match("([^/]+)$") or ""
    if wantName == "" then
        return nil
    end
    local ownName, ownCourse = loadedCourseName(vehicle)
    if ownName ~= nil and fold(ownName) == fold(wantName) then
        return ownCourse, vehicle
    end
    for _, e in ipairs(ADJobs.getVehicleCpCourses(farmId)) do
        if e.vehicle ~= vehicle and fold(e.name) == fold(wantName) then
            return e.course, e.vehicle
        end
    end
    return nil
end

--- the Courseplay course that is loaded in the vehicle right now has the name of the stored course?
--- (then it can be run without reading the file)
function ADJobs.vehicleHasCpCourse(vehicle, path)
    if vehicle == nil or vehicle.hasCpCourse == nil or vehicle.getCurrentCpCourseName == nil then
        return false, nil
    end
    local okHas, has = pcall(vehicle.hasCpCourse, vehicle)
    if not okHas or not has then
        return false, nil
    end
    local okName, name = pcall(vehicle.getCurrentCpCourseName, vehicle)
    if not okName or name == nil then
        return false, nil
    end
    local wantName = tostring(path or ""):match("([^/]+)$") or ""
    return fold(name) == fold(wantName), name
end

--- writes what the engine sees in the Courseplay course folder (and next to it) to the log, once per path
local folderLogged = {}
function ADJobs.logCpCourseFolder(root, path)
    if root == nil or folderLogged[path] or getFiles == nil then
        return
    end
    folderLogged[path] = true
    local lines = {}
    local function list(dir, indent, depth)
        local entries = {}
        local target = {}
        function target.cb(_, name, isDirectory)
            table.insert(entries, {name = name, dir = isDirectory})
        end
        pcall(getFiles, dir, "cb", target)
        if #entries == 0 then
            table.insert(lines, indent .. "(leer / nicht lesbar)")
        end
        for i, e in ipairs(entries) do
            if i > 40 then
                table.insert(lines, indent .. "...")
                break
            end
            table.insert(lines, indent .. (e.dir and "[" .. e.name .. "]" or e.name) .. "  (" .. hex(e.name) .. ")")
            if e.dir and depth < 3 then
                list(dir .. "/" .. e.name, indent .. "    ", depth + 1)
            end
        end
    end
    local parent = root:match("^(.*)/[^/]+$")
    if parent ~= nil then
        table.insert(lines, "Kursordner aller Karten: " .. parent)
        list(parent, "  ", 2)
    end
    table.insert(lines, "Kursordner dieser Karte: " .. root)
    list(root, "  ", 0)
    Logging.warning("[AD Jobs] Inhalt des Courseplay-Kursordners laut Engine:\n%s", table.concat(lines, "\n"))
end

--- the course file for a stored path. Looked up in the list Courseplay keeps (also after reading the folder
--- again), then in an own scan of the course folder, then built directly from the path.
function ADJobs.findCpCourseFile(path, job)
    local cpList = {}
    for pass = 1, 2 do
        cpList = ADJobs.getCpCourses(pass == 2)
        local c, how = pickCourse(cpList, path)
        if c ~= nil then
            if c.path ~= path then
                Logging.info("[AD Jobs] Courseplay-Kurs '%s' gefunden als '%s' (%s)", tostring(path), c.path, how)
            end
            return c.file
        end
    end
    -- not in Courseplay's list: scan the folder with the engine and build the File object ourselves
    -- (Courseplay loads any File object that points into its course folder)
    local root = nil
    pcall(function()
        root = ADJobs.CP.courseStorage:getRootDirectory():getFullPath()
    end)
    local ownList = ADJobs.scanCpCourseDir(root)
    local c, how = pickCourse(ownList, path)
    if c ~= nil and type(ADJobs.CPFile) == "table" then
        local ok, f = pcall(function()
            return ADJobs.CPFile(c.dir, c.name, nil)
        end)
        if ok and f ~= nil then
            Logging.info("[AD Jobs] Courseplay-Kurs '%s' im Kursordner gefunden (%s: %s)", tostring(path), how, c.path)
            return f
        end
    end
    ADJobs.logCpCourseFolder(root, path)
    -- last try: the File object straight from the path (fileExists may say no for names with umlauts
    -- although the file is there - Courseplay reports whether it could load it)
    if root ~= nil and (path or "") ~= "" and type(ADJobs.CPFile) == "table" then
        local full = root .. "/" .. path
        local parentPath, name = full:match("^(.*)/([^/]+)$")
        local ok, f = pcall(function()
            return ADJobs.CPFile(parentPath, name, nil)
        end)
        if ok and f ~= nil then
            Logging.info("[AD Jobs] Courseplay-Kurs '%s' nicht in der Kursliste - Versuch direkt über den Dateipfad %s (vorhanden laut Engine: %s)",
                tostring(path), full, tostring(fileExists ~= nil and fileExists(full)))
            return f, true
        end
    end
    -- not found: say what was searched and what is there (server and players may have different course folders)
    local function names(list, max)
        local t = {}
        for i, e in ipairs(list) do
            if i > max then
                table.insert(t, "...")
                break
            end
            table.insert(t, e.path)
        end
        return #t > 0 and table.concat(t, ", ") or "keine"
    end
    Logging.warning("[AD Jobs] Auftrag %s: Courseplay-Kurs '%s' nicht gefunden (Bytes: %s). Kursordner: %s - Liste von Courseplay (%d): %s - eigener Scan (%d): %s",
        job ~= nil and tostring(job.id) or "?", tostring(path), hex(tostring(path):match("([^/]+)$")), tostring(root), #cpList, names(cpList, 25), #ownList, names(ownList, 25))
    return nil
end

--- loads the course into the vehicle (without starting Courseplay); true or false, error code
function ADJobs.loadCpCourse(job, vehicle, path)
    if vehicle.appendLoadedCpCourse == nil then
        return false, 30
    end
    local isVehicleCourse = tostring(path or ""):sub(1, #ADJobs.CP_VEHICLE_PREFIX) == ADJobs.CP_VEHICLE_PREFIX
    local file = nil
    if not isVehicleCourse then
        file = ADJobs.findCpCourseFile(path, job)
    end
    local ok, loaded = false, nil
    if file ~= nil then
        ok, loaded = pcall(vehicle.appendLoadedCpCourse, vehicle, file)
    end
    if file == nil or not ok or loaded == false then
        -- no file (course only assigned to a vehicle, never saved in the course manager): take the course of
        -- that name from the job vehicle or copy it from the vehicle that has it
        local course, src = ADJobs.findVehicleCpCourse(path, vehicle, job.farmId)
        if course ~= nil and src == vehicle then
            Logging.info("[AD Jobs] Auftrag %d '%s': nutze den im Fahrzeug geladenen Courseplay-Kurs '%s'", job.id, tostring(job.name), tostring(course:getName()))
            ok, loaded = true, nil
        elseif course ~= nil and vehicle.cpCopyCourse ~= nil then
            local okCopy, err = pcall(vehicle.cpCopyCourse, vehicle, course)
            if okCopy then
                Logging.info("[AD Jobs] Auftrag %d '%s': Courseplay-Kurs '%s' von %s übernommen", job.id, tostring(job.name), tostring(course:getName()), ADJobs.getVehicleName(src))
                ok, loaded = true, nil
            else
                Logging.warning("[AD Jobs] Auftrag %d '%s': Kurs von %s übernehmen fehlgeschlagen: %s", job.id, tostring(job.name), ADJobs.getVehicleName(src), tostring(err))
            end
        elseif isVehicleCourse then
            Logging.warning("[AD Jobs] Auftrag %d '%s': kein Fahrzeug hat den Courseplay-Kurs '%s' geladen", job.id, tostring(job.name), tostring(path):sub(#ADJobs.CP_VEHICLE_PREFIX + 1))
        end
    end
    if file == nil and not ok then
        return false, 31
    end
    if not ok or loaded == false then
        Logging.warning("[AD Jobs] Auftrag %d '%s': Kursdatei '%s' (%s) - Courseplay konnte sie nicht laden (%s)", job.id, tostring(job.name), path, tostring(file ~= nil and file.fullPath), ok and "Datei nicht lesbar" or tostring(loaded))
        return false, 31
    end
    -- a new course starts at its first waypoint (AutoDrive hands over with "start at last waypoint")
    if vehicle.rememberCpLastWaypointIx ~= nil then
        pcall(vehicle.rememberCpLastWaypointIx, vehicle, 1)
    end
    return true
end

--- AutoDrive "pick up and deliver" field -> unload target with the Courseplay helper: AutoDrive drives to
--- the field and hands over to Courseplay, unloads when Courseplay reports "full" and hands over again
function ADJobs.startAdCp(job, vehicle, step)
    local fieldIdx = ADJobs.getMarkerIndexByName(step.marker)
    local unloadIdx = ADJobs.getMarkerIndexByName(step.unload)
    if fieldIdx == nil or unloadIdx == nil then
        return false, 34
    end
    if vehicle.cpStartStopDriver == nil then
        return false, 30
    end
    local ok, err = ADJobs.loadCpCourse(job, vehicle, step.course)
    if not ok then
        return false, err
    end
    local sm = vehicle.ad.stateModule
    if job.seq.savedAd == nil then
        -- (no "a and b or nil": the helper switch is false when it is off)
        local saved = {}
        if sm.getLoopCounter ~= nil then
            saved.loop = sm:getLoopCounter()
        end
        if sm.getStartHelper ~= nil then
            saved.helper = sm:getStartHelper() == true
        end
        if sm.getUsedHelper ~= nil then
            saved.used = sm:getUsedHelper()
        end
        job.seq.savedAd = saved
        ADJobs.saveMarkers(job, sm)
    end
    ADJobs.suspendRotate(job, vehicle)
    sm:setMode(ADJobs.AD.MODE_PICKUPANDDELIVER or 2)
    ADJobs.disableAutomaticTargets(sm)
    if sm.setLoopCounter ~= nil then
        sm:setLoopCounter(0) -- unlimited: Courseplay decides when the field is done
    end
    if sm.setLoopsDone ~= nil then
        sm:setLoopsDone(0)
    end
    if sm.setUsedHelper ~= nil then
        sm:setUsedHelper(1) -- ADStateModule.HELPER_CP
    end
    if sm.setStartHelper ~= nil then
        sm:setStartHelper(true)
    end
    sm:raiseDirtyFlag()
    ADJobs.AD:StartDriving(vehicle, fieldIdx, unloadIdx, nil, nil, nil)
    ADJobs.wakeVehicle(vehicle)
    if not sm:isActive() then
        return false, 34
    end
    return true
end

--- gives the vehicle its AutoDrive settings from before an AutoDrive + Courseplay step back
function ADJobs.restoreAdCp(job, vehicle)
    local seq = job.seq
    if seq == nil or seq.savedAd == nil or vehicle == nil or vehicle.ad == nil then
        return
    end
    local sm = vehicle.ad.stateModule
    local s = seq.savedAd
    seq.savedAd = nil
    if s.loop ~= nil and sm.setLoopCounter ~= nil then
        sm:setLoopCounter(s.loop)
    end
    if s.used ~= nil and sm.setUsedHelper ~= nil then
        sm:setUsedHelper(s.used)
    end
    if s.helper ~= nil and sm.setStartHelper ~= nil then
        sm:setStartHelper(s.helper)
    end
    if not sm:isActive() then
        ADJobs.restoreMarkers(job, sm)
    end
    sm:raiseDirtyFlag()
end

--- loads the course into the vehicle and starts Courseplay at the first waypoint; true on success
function ADJobs.startCpCourse(job, vehicle, path)
    if vehicle.appendLoadedCpCourse == nil or vehicle.startCpAtFirstWp == nil then
        return false, 30
    end
    local ok, err = ADJobs.loadCpCourse(job, vehicle, path)
    if not ok then
        return false, err
    end
    if not ADJobs.startCpJob(job, vehicle, false) then
        return false, 32
    end
    return true
end

--- starts the Courseplay course loaded in the vehicle at its first (atLast = false) or last remembered
--- waypoint; true if Courseplay accepted the start
function ADJobs.startCpJob(job, vehicle, atLast)
    local fn = atLast and vehicle.startCpAtLastWp or vehicle.startCpAtFirstWp
    -- the Courseplay function uses the local player (single player / host); a dedicated server starts the job itself
    local started = false
    local player = g_currentMission.playerSystem ~= nil and g_currentMission.playerSystem.getLocalPlayer ~= nil and g_currentMission.playerSystem:getLocalPlayer() or nil
    if fn ~= nil and g_client ~= nil and player ~= nil then
        local ok, r = pcall(fn, vehicle)
        started = ok and r == true
        if not ok then
            Logging.warning("[AD Jobs] Auftrag %d '%s': Courseplay-Start: %s", job.id, tostring(job.name), tostring(r))
        end
    end
    if not started then
        local ok, r = pcall(function()
            local spec = vehicle.spec_cpAIFieldWorker
            local cpJob = spec ~= nil and (atLast and spec.cpJobStartAtLastWp or spec.cpJobStartAtFirstWp) or nil
            if cpJob == nil or not vehicle:hasCpCourse() or not vehicle:getCanStartCpFieldWork() then
                return false
            end
            local farmId = vehicle:getOwnerFarmId()
            vehicle:updateAIFieldWorkerImplementData()
            cpJob:applyCurrentState(vehicle, g_currentMission, farmId, true, false)
            if vehicle.getCpLaneOffsetSetting ~= nil then
                cpJob:getCpJobParameters().laneOffset:setValue(vehicle:getCpLaneOffsetSetting():getValue())
            end
            cpJob:setValues()
            if not cpJob:validate(false) then
                return false
            end
            g_currentMission.aiSystem:startJob(cpJob, farmId)
            return true
        end)
        started = ok and r == true
        if not ok then
            Logging.warning("[AD Jobs] Auftrag %d '%s': Courseplay-Start (Server): %s", job.id, tostring(job.name), tostring(r))
        end
    end
    return started
end

local function cpActive(vehicle)
    if vehicle.getIsCpFieldWorkActive ~= nil then
        local ok, r = pcall(vehicle.getIsCpFieldWorkActive, vehicle)
        if ok and r then
            return true
        end
    end
    return vehicle.getIsAIActive ~= nil and vehicle:getIsAIActive()
end

local function cpProgress(vehicle)
    if vehicle.getCpFieldWorkProgress ~= nil then
        local ok, p, _, isLast = pcall(vehicle.getCpFieldWorkProgress, vehicle)
        if ok and type(p) == "number" then
            return p, isLast == true
        end
    end
    return nil, false
end

function ADJobs.stopCp(vehicle)
    if vehicle.getIsAIActive == nil or not vehicle:getIsAIActive() or vehicle.stopCurrentAIJob == nil then
        return
    end
    pcall(function()
        local msg = AIMessageSuccessStoppedByUser ~= nil and AIMessageSuccessStoppedByUser.new() or nil
        vehicle:stopCurrentAIJob(msg)
    end)
end

--- every WATCH_INTERVAL while Courseplay works: remember how far it got (it may finish between two rule checks)
function ADJobs.sampleSequence(job, vehicle)
    local seq = job.seq
    if seq == nil or (seq.phase ~= ADJobs.SEQ_PH_CP and seq.phase ~= ADJobs.SEQ_PH_CPSTART and seq.phase ~= ADJobs.SEQ_PH_ADCP) or not cpActive(vehicle) then
        return
    end
    local p, isLast = cpProgress(vehicle)
    if p ~= nil then
        seq.lastProgress = p
        seq.pct = p
        seq.lastWasEnd = isLast
    end
end

-------------------------------------------------------------------------------------------------
-- steps
-------------------------------------------------------------------------------------------------

--- "m1>c1|m2>c2" -> {{marker = "m1", course = "c1"}, ...}
function ADJobs.getSteps(job)
    local steps = {}
    for part in string.gmatch(job.steps or "", "[^|]+") do
        local fields = {}
        for f in string.gmatch(part .. ">", "(.-)>") do
            table.insert(fields, f)
        end
        if #fields == 1 then
            fields = {"", fields[1]}
        end
        table.insert(steps, {marker = fields[1] or "", course = fields[2] or "", unload = fields[3] or ""})
    end
    return steps
end

function ADJobs.setSteps(job, steps)
    local parts = {}
    for _, s in ipairs(steps) do
        local p = (s.marker or "") .. ">" .. (s.course or "")
        if (s.unload or "") ~= "" then
            p = p .. ">" .. s.unload
        end
        table.insert(parts, p)
    end
    job.steps = table.concat(parts, "|")
end

-------------------------------------------------------------------------------------------------
-- running a sequence (server, every CHECK_INTERVAL)
-------------------------------------------------------------------------------------------------

local function setPhase(job, phase)
    job.seq.phase = phase
    job.seq.since = g_time
    job.seqPhase = phase
    ADJobs.lastSyncKey = nil
end

local function publish(job)
    local seq = job.seq
    local n = #ADJobs.getSteps(job)
    job.seqCount = n
    job.seqIndex = seq ~= nil and seq.i or 0
    job.seqPhase = seq ~= nil and seq.phase or 0
    if seq ~= nil and seq.phase == ADJobs.SEQ_PH_ADCP then
        local v = job._veh
        if v ~= nil and v.ad ~= nil and v.ad.stateModule:isActive() and not cpActive(v) then
            job.seqPhase = seq.cpSeen and ADJobs.SEQ_PH_UNLOAD or ADJobs.SEQ_PH_DRIVE
        end
    end
    local stepPct = seq ~= nil and seq.pct or 0
    job.seqPct = math.floor(stepPct * 100 + 0.5)
    -- the level bar shows the progress of the whole sequence
    if seq ~= nil and n > 0 then
        local done = (seq.i - 1) + (seq.phase == ADJobs.SEQ_PH_PARK and 1 or stepPct)
        job.percent = math.max(0, math.min(100, done / n * 100))
    else
        job.percent = 0
    end
    job.low, job.high = 0, 100
end

--- stops the sequence; errCode (optional) is shown; park = send the vehicle to its park position
function ADJobs.stopSequence(job, vehicle, errCode, park)
    vehicle = vehicle or job._veh
    if vehicle ~= nil and not vehicle.isDeleted then
        ADJobs.stopCp(vehicle)
        if vehicle.ad ~= nil then
            vehicle.ad.restartCP = false
            if vehicle.ad.stateModule:isActive() then
                ADJobs.stopDriving(vehicle)
            end
        end
        ADJobs.restoreAdCp(job, vehicle)
        if park then
            ADJobs.parkVehicle(job, vehicle)
        end
    end
    job.seq = nil
    job.seqResume = nil
    job.running = false
    job.seqError = errCode
    if errCode ~= nil then
        job.active = false
        job.state, job.msgCode = ADJobs.ST_ERROR, errCode
    else
        job.state, job.msgCode = job.active and ADJobs.ST_WAIT or ADJobs.ST_OFF, 0
    end
    publish(job)
    ADJobs.lastSyncKey = nil
end

local function beginStep(job, vehicle)
    local steps = ADJobs.getSteps(job)
    local step = steps[job.seq.i]
    if step == nil then
        -- all done: park
        setPhase(job, ADJobs.SEQ_PH_PARK)
        job.seq.pct = 1
        if not ADJobs.parkVehicle(job, vehicle) then
            -- no park position / already there
            job.seq.parkStarted = false
        else
            job.seq.parkStarted = true
        end
        Logging.info("[AD Jobs] Auftrag %d '%s': alle %d Schritte erledigt - %s parkt", job.id, tostring(job.name), #steps, ADJobs.getVehicleName(vehicle))
        return
    end
    job.seq.pct = 0
    job.seq.cpSeen, job.seq.lastProgress, job.seq.lastWasEnd, job.seq.idleSince = false, nil, false, nil
    if (step.unload or "") ~= "" then
        -- forage / loader wagon: AutoDrive + Courseplay, unloading whenever the wagon is full
        setPhase(job, ADJobs.SEQ_PH_ADCP)
        local ok, err = ADJobs.startAdCp(job, vehicle, step)
        if not ok then
            Logging.warning("[AD Jobs] Auftrag %d '%s': Schritt %d - AutoDrive/Courseplay startet nicht (Code %s)", job.id, tostring(job.name), job.seq.i, tostring(err))
            ADJobs.stopSequence(job, vehicle, err or 32, false)
            return
        end
        Logging.info("[AD Jobs] Auftrag %d '%s': Schritt %d/%d - AutoDrive fährt zu '%s', Courseplay fährt Kurs '%s', abladen bei '%s'",
            job.id, tostring(job.name), job.seq.i, #steps, step.marker, step.course, step.unload)
        return
    end
    if (step.marker or "") ~= "" and ADJobs.getMarkerIndexByName(step.marker) ~= nil then
        setPhase(job, ADJobs.SEQ_PH_DRIVE)
        job.seq.adSeen = false
        if not ADJobs.driveToMarker(vehicle, step.marker) then
            ADJobs.stopSequence(job, vehicle, 34, false)
            return
        end
        Logging.info("[AD Jobs] Auftrag %d '%s': Schritt %d/%d - fährt zu '%s'", job.id, tostring(job.name), job.seq.i, #steps, step.marker)
    else
        setPhase(job, ADJobs.SEQ_PH_CPSTART)
        job.seq.cpRequested = false
    end
end

--- Courseplay stopped because the wagon is full: AutoDrive "pick up and deliver" unloads (second target),
--- drives back to the field (first target) and hands over to Courseplay at its last waypoint - the same as
--- AutoDrive does on Courseplay's "full" event. True if AutoDrive drives.
function ADJobs.handOverToAdUnload(job, vehicle)
    local sm = vehicle.ad.stateModule
    if sm.getMode ~= nil and sm:getMode() ~= (ADJobs.AD.MODE_PICKUPANDDELIVER or 2) then
        sm:setMode(ADJobs.AD.MODE_PICKUPANDDELIVER or 2)
        ADJobs.disableAutomaticTargets(sm)
    end
    if sm.setUsedHelper ~= nil then
        sm:setUsedHelper(1)
    end
    if sm.setStartHelper ~= nil then
        sm:setStartHelper(true)
    end
    vehicle.ad.isCpFull = true
    sm:raiseDirtyFlag()
    if type(ADJobs.AD.handleCPFieldWorker) == "function" then
        pcall(ADJobs.AD.handleCPFieldWorker, ADJobs.AD, vehicle)
    end
    if not sm:isActive() and sm.getCurrentMode ~= nil then
        -- older / other AutoDrive: start the mode the same way
        vehicle.ad.restartCP = true
        pcall(function()
            sm:getCurrentMode():start()
        end)
    end
    ADJobs.wakeVehicle(vehicle)
    local ok = sm:isActive()
    if ok then
        Logging.info("[AD Jobs] Auftrag %d '%s': Ladewagen voll - AutoDrive fährt abladen und übergibt danach wieder an Courseplay", job.id, tostring(job.name))
    else
        Logging.warning("[AD Jobs] Auftrag %d '%s': Ladewagen voll, AutoDrive startet nicht zum Abladen (Modus %s, Helfer %s/%s)", job.id, tostring(job.name),
            tostring(sm.getMode ~= nil and sm:getMode()), tostring(sm.getStartHelper ~= nil and sm:getStartHelper()), tostring(sm.getUsedHelper ~= nil and sm:getUsedHelper()))
    end
    return ok
end

--- the sequence of a job; called from ADJobs.updateJob instead of the fill level rules
function ADJobs.updateSequence(job)
    job.state = job.state or ADJobs.ST_OFF
    local vehicle = ADJobs.findVehicle(job)

    -- switched off by the player during a run
    if not job.active then
        if job.seq ~= nil then
            Logging.info("[AD Jobs] Auftrag %d '%s': Ablauf ausgeschaltet", job.id, tostring(job.name))
            ADJobs.stopSequence(job, vehicle, nil, true)
        end
        if job.seqError ~= nil then
            job.state, job.msgCode = ADJobs.ST_ERROR, job.seqError
        else
            job.state, job.msgCode = ADJobs.ST_OFF, 0
        end
        publish(job)
        return
    end
    job.seqError = nil

    local steps = ADJobs.getSteps(job)
    if #steps == 0 then
        job.state, job.msgCode = ADJobs.ST_ERROR, 35
        publish(job)
        return
    end
    if ADJobs.resolveCourseplay() == nil then
        job.state, job.msgCode = ADJobs.ST_ERROR, 30
        publish(job)
        return
    end
    if vehicle == nil or vehicle.ad == nil then
        if job.seq ~= nil then
            -- the vehicle is gone (sold / reset) in the middle of the sequence
            Logging.warning("[AD Jobs] Auftrag %d '%s': Fahrzeug während des Ablaufs verloren - Ablauf gestoppt", job.id, tostring(job.name))
            ADJobs.stopSequence(job, nil, 2, false)
            return
        end
        job.state, job.msgCode = ADJobs.ST_ERROR, 14
        publish(job)
        return
    end

    -- start (switched on): step 1, or the step it was at when the game was saved
    if job.seq == nil then
        -- busy: another job, AutoDrive, a helper (Courseplay ...) or the player driving it by hand
        local busy = vehicle.ad.stateModule:isActive() or (vehicle.getIsAIActive ~= nil and vehicle:getIsAIActive())
            or (vehicle.getIsControlled ~= nil and vehicle:getIsControlled())
        for _, other in ipairs(ADJobs.jobs) do
            if other ~= job and (other.running or other.swap ~= nil or other.restRun ~= nil) and other._veh == vehicle then
                busy = true
            end
        end
        if busy then
            job.state, job.msgCode = ADJobs.ST_NOTREADY, 7
            publish(job)
            return
        end
        local startAt = math.max(1, math.min(#steps, job.seqResume or 1))
        job.seq = {i = startAt}
        job._veh = vehicle
        job.running = true
        job.startTime = g_time
        Logging.info("[AD Jobs] Auftrag %d '%s': Ablauf startet bei Schritt %d/%d mit %s", job.id, tostring(job.name), startAt, #steps, ADJobs.getVehicleName(vehicle))
        beginStep(job, vehicle)
        if job.seq == nil then
            return
        end
    end

    local seq = job.seq
    local sm = vehicle.ad.stateModule
    job.seqResume = seq.i
    job.state, job.msgCode = ADJobs.ST_SEQ, 0

    if seq.phase == ADJobs.SEQ_PH_DRIVE then
        local step = steps[seq.i]
        if sm:isActive() then
            seq.adSeen = true
        elseif g_time - seq.since > ADJobs.START_GRACE or seq.adSeen then
            local idx = ADJobs.getMarkerIndexByName(step.marker)
            if idx ~= nil and ADJobs.isNearMarker(vehicle, idx) then
                setPhase(job, ADJobs.SEQ_PH_CPSTART)
                seq.cpRequested = false
            else
                -- AutoDrive did not get there (e.g. the vehicle stands on the field, away from the AD network,
                -- after a restart): let Courseplay drive to the start of its course itself
                Logging.info("[AD Jobs] Auftrag %d '%s': Schritt %d - AutoDrive erreicht '%s' nicht (Fahrzeug abseits des AD-Netzes?) - Courseplay fährt selbst zum Kurs",
                    job.id, tostring(job.name), seq.i, tostring(step.marker))
                setPhase(job, ADJobs.SEQ_PH_CPSTART)
                seq.cpRequested = false
            end
        end

    elseif seq.phase == ADJobs.SEQ_PH_CPSTART then
        local step = steps[seq.i]
        if not seq.cpRequested then
            seq.cpRequested = true
            seq.cpRequestedAt = g_time
            local ok, err = ADJobs.startCpCourse(job, vehicle, step.course)
            if not ok then
                Logging.warning("[AD Jobs] Auftrag %d '%s': Schritt %d - Courseplay-Kurs '%s' startet nicht (Code %s)", job.id, tostring(job.name), seq.i, tostring(step.course), tostring(err))
                ADJobs.stopSequence(job, vehicle, err or 32, false)
                return
            end
            Logging.info("[AD Jobs] Auftrag %d '%s': Schritt %d/%d - Courseplay fährt Kurs '%s'", job.id, tostring(job.name), seq.i, #steps, tostring(step.course))
        elseif cpActive(vehicle) then
            setPhase(job, ADJobs.SEQ_PH_CP)
            seq.cpSeen = true
        elseif g_time - seq.cpRequestedAt > ADJobs.SEQ_CP_START_TIMEOUT then
            ADJobs.stopSequence(job, vehicle, 32, false)
            return
        end

    elseif seq.phase == ADJobs.SEQ_PH_CP then
        if cpActive(vehicle) then
            local p, isLast = cpProgress(vehicle)
            if p ~= nil then
                seq.lastProgress = p
                seq.pct = p
                seq.lastWasEnd = isLast
            end
        else
            local p = seq.lastProgress or 0
            if seq.lastWasEnd or p >= ADJobs.SEQ_DONE_PROGRESS then
                Logging.info("[AD Jobs] Auftrag %d '%s': Schritt %d/%d fertig", job.id, tostring(job.name), seq.i, #steps)
                seq.i = seq.i + 1
                job.seqResume = seq.i
                beginStep(job, vehicle)
            else
                Logging.warning("[AD Jobs] Auftrag %d '%s': Schritt %d - Courseplay bei %d %% beendet - Ablauf gestoppt", job.id, tostring(job.name), seq.i, math.floor(p * 100))
                ADJobs.stopSequence(job, vehicle, 33, false)
                return
            end
        end

    elseif seq.phase == ADJobs.SEQ_PH_ADCP then
        local working = cpActive(vehicle)
        if working then
            seq.cpSeen = true
        end
        if working or sm:isActive() then
            seq.idleSince = nil
            if not seq.cpSeen and g_time - seq.since > ADJobs.SEQ_ADCP_START_TIMEOUT then
                ADJobs.stopSequence(job, vehicle, 32, false)
                return
            end
        else
            seq.idleSince = seq.idleSince or g_time
            local idle = g_time - seq.idleSince
            local p = seq.lastProgress or 0
            local courseDone = seq.lastWasEnd or p >= ADJobs.SEQ_DONE_PROGRESS
            local rest = 0
            for _, r in ipairs(ADJobs.getRest(vehicle)) do
                rest = rest + r.level
            end
            -- Courseplay stopped before the end of the course with something loaded (wagon full): Courseplay for
            -- FS25 does not tell AutoDrive about it, so the job starts AutoDrive's unloading itself. AutoDrive
            -- drives to the unload target, back to the field and hands over to Courseplay at its last waypoint.
            if seq.cpSeen and not courseDone and rest > 50 and idle >= ADJobs.SEQ_HANDOVER_TIME
                and (seq.handoverAt == nil or g_time - seq.handoverAt > ADJobs.SEQ_HANDOVER_RETRY) then
                seq.handoverAt = g_time
                seq.handovers = (seq.handovers or 0) + 1
                if ADJobs.handOverToAdUnload(job, vehicle) then
                    -- (the retry timer only counts for hand-overs that did not start AutoDrive)
                    seq.idleSince, seq.handoverAt, seq.failedHandovers = nil, nil, 0
                    publish(job)
                    return
                end
                seq.failedHandovers = (seq.failedHandovers or 0) + 1
            end
            -- AutoDrive's "restart Courseplay" flag alone keeps the step alive only for a while
            local waitRestart = vehicle.ad.restartCP == true and idle < ADJobs.SEQ_RESTART_WAIT
            local waitHandover = seq.handoverAt ~= nil and g_time - seq.handoverAt < ADJobs.SEQ_HANDOVER_RETRY and (seq.failedHandovers or 0) < 3
            if not seq.cpSeen and not seq.cpDirectTried and idle >= ADJobs.SEQ_HANDOVER_TIME then
                -- AutoDrive stopped before it handed over (vehicle on the field away from the AD network, e.g.
                -- after a restart): Courseplay starts directly at its last waypoint; AutoDrive stays set up for
                -- the unloading
                seq.cpDirectTried = true
                if ADJobs.startCpJob(job, vehicle, true) then
                    Logging.info("[AD Jobs] Auftrag %d '%s': Schritt %d - AutoDrive hat nicht an Courseplay übergeben - Courseplay startet direkt am letzten Wegpunkt",
                        job.id, tostring(job.name), seq.i)
                    seq.idleSince = nil
                    publish(job)
                    return
                end
            end
            if idle >= ADJobs.SEQ_IDLE_TIME and not waitRestart and not waitHandover then
                ADJobs.restoreAdCp(job, vehicle)
                if not seq.cpSeen then
                    ADJobs.stopSequence(job, vehicle, 32, false)
                    return
                end
                if not courseDone then
                    Logging.warning("[AD Jobs] Auftrag %d '%s': Schritt %d - Courseplay bei %d %% beendet (%d l geladen, Übergaben an AutoDrive: %d) - Ablauf gestoppt",
                        job.id, tostring(job.name), seq.i, math.floor(p * 100), math.floor(rest), seq.handovers or 0)
                    ADJobs.stopSequence(job, vehicle, 33, false)
                    return
                end
                -- course done: unload the rest (AutoDrive may have done it already), then the next step
                local step = steps[seq.i]
                if rest > 50 and ADJobs.getMarkerIndexByName(step.unload) ~= nil then
                    local idx = ADJobs.getMarkerIndexByName(step.unload)
                    ADJobs.startDriveTo(vehicle, idx, ADJobs.AD.MODE_DELIVERTO or 3)
                    setPhase(job, ADJobs.SEQ_PH_UNLOAD)
                    Logging.info("[AD Jobs] Auftrag %d '%s': Schritt %d - Kurs fertig, lädt %d l Rest bei '%s' ab", job.id, tostring(job.name), seq.i, math.floor(rest), step.unload)
                else
                    Logging.info("[AD Jobs] Auftrag %d '%s': Schritt %d/%d fertig", job.id, tostring(job.name), seq.i, #steps)
                    seq.i = seq.i + 1
                    job.seqResume = seq.i
                    beginStep(job, vehicle)
                end
            end
        end

    elseif seq.phase == ADJobs.SEQ_PH_UNLOAD then
        if not sm:isActive() and g_time - seq.since > ADJobs.START_GRACE then
            Logging.info("[AD Jobs] Auftrag %d '%s': Schritt %d/%d fertig", job.id, tostring(job.name), seq.i, #steps)
            seq.i = seq.i + 1
            job.seqResume = seq.i
            beginStep(job, vehicle)
        end

    elseif seq.phase == ADJobs.SEQ_PH_PARK then
        if not sm:isActive() and (not seq.parkStarted or g_time - seq.since > ADJobs.START_GRACE) then
            Logging.info("[AD Jobs] Auftrag %d '%s': Ablauf fertig, Auftrag ausgeschaltet", job.id, tostring(job.name))
            job.seq = nil
            job.seqResume = nil
            job.running = false
            job.active = false
            job.tripsTotal = (job.tripsTotal or 0) + 1
            job.state, job.msgCode = ADJobs.ST_OFF, 0
        end
    end
    if job.seq ~= nil and job.seq.phase == ADJobs.SEQ_PH_CP and vehicle.ad ~= nil then
        job.pauseLeft = 0
    end
    publish(job)
end
