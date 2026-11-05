--
-- AutoDrive Jobs - Courseplay course files from the player to the server
--
-- The Courseplay course manager saves course files on the PC of the player who saves them. Sequence jobs
-- run on the server, which looks in ITS course folder. When a player (multiplayer client) saves a sequence
-- job, the files of its courses are read on his PC and sent along; the server writes them into its
-- Courseplay course folder under the same path. From then on the server has them, also after a restart.
--
--   ADJCourseUploadEvent : client -> server, one part of one course file (path, part i of n, xml text)
--

ADJobs.UPLOAD_CHUNK = 16000           -- characters per event
ADJobs.UPLOAD_MAX = 8 * 1024 * 1024   -- the server refuses bigger files
ADJobs.uploads = {}                   -- server: [connection][path] = {count, parts, received}
ADJobs.uploadedPaths = {}             -- client: [path] = true (sent in this session)

-------------------------------------------------------------------------------------------------
-- event
-------------------------------------------------------------------------------------------------

ADJCourseUploadEvent = {}
local ADJCourseUploadEvent_mt = Class(ADJCourseUploadEvent, Event)
InitEventClass(ADJCourseUploadEvent, "ADJCourseUploadEvent")

function ADJCourseUploadEvent.emptyNew()
    return Event.new(ADJCourseUploadEvent_mt)
end

function ADJCourseUploadEvent.new(path, index, count, data)
    local self = ADJCourseUploadEvent.emptyNew()
    self.path, self.index, self.count, self.data = path, index, count, data
    return self
end

function ADJCourseUploadEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, ADJobs.NET_VERSION)
    streamWriteString(streamId, self.path or "")
    streamWriteUInt16(streamId, self.index or 1)
    streamWriteUInt16(streamId, self.count or 1)
    streamWriteString(streamId, self.data or "")
end

function ADJCourseUploadEvent:readStream(streamId, connection)
    local v = streamReadUInt8(streamId)
    self.path = streamReadString(streamId)
    self.index = streamReadUInt16(streamId)
    self.count = streamReadUInt16(streamId)
    self.data = streamReadString(streamId)
    if v ~= ADJobs.NET_VERSION then
        return
    end
    self:run(connection)
end

function ADJCourseUploadEvent:run(connection)
    if g_server ~= nil then
        ADJobs.receiveCoursePart(connection, self.path, self.index, self.count, self.data)
    end
end

-------------------------------------------------------------------------------------------------
-- client: send
-------------------------------------------------------------------------------------------------

--- reads a course file of the local Courseplay course folder as text (nil if not possible)
function ADJobs.readLocalCourse(path, job)
    if saveXMLFileToMemory == nil then
        return nil, "saveXMLFileToMemory fehlt"
    end
    local file = ADJobs.findCpCourseFile(path, job)
    if file == nil or file.fullPath == nil then
        return nil, "Datei nicht gefunden"
    end
    local handle = loadXMLFile("adjCourseUpload", file.fullPath)
    if handle == nil or handle == 0 then
        return nil, "nicht lesbar: " .. tostring(file.fullPath)
    end
    local ok, data = pcall(saveXMLFileToMemory, handle)
    delete(handle)
    if not ok or type(data) ~= "string" or data == "" then
        return nil, "nicht lesbar: " .. tostring(file.fullPath)
    end
    return data
end

--- multiplayer client: sends the course files of the steps of a sequence job to the server
function ADJobs.uploadSequenceCourses(job)
    if g_server or not g_client or job == nil or job.driveMode ~= "sequence" then
        return 0
    end
    local sent = 0
    for _, step in ipairs(ADJobs.getSteps(job)) do
        local path = step.course or ""
        if path ~= "" and path:sub(1, #ADJobs.CP_VEHICLE_PREFIX) ~= ADJobs.CP_VEHICLE_PREFIX then
            local data, err = ADJobs.readLocalCourse(path, job)
            if data == nil then
                Logging.warning("[AD Jobs] Kurs '%s' kann nicht an den Server geschickt werden (%s)", path, tostring(err))
            else
                local count = math.max(1, math.ceil(#data / ADJobs.UPLOAD_CHUNK))
                local connection = g_client:getServerConnection()
                for i = 1, count do
                    local part = data:sub((i - 1) * ADJobs.UPLOAD_CHUNK + 1, i * ADJobs.UPLOAD_CHUNK)
                    connection:sendEvent(ADJCourseUploadEvent.new(path, i, count, part))
                end
                ADJobs.uploadedPaths[path] = true
                sent = sent + 1
                Logging.info("[AD Jobs] Courseplay-Kurs '%s' an den Server geschickt (%d Zeichen, %d Teile)", path, #data, count)
            end
        end
    end
    return sent
end

-------------------------------------------------------------------------------------------------
-- server: receive and store
-------------------------------------------------------------------------------------------------

--- a path below the course folder: no "..", no drive, no leading slash
function ADJobs.isSafeCoursePath(path)
    if type(path) ~= "string" or path == "" or #path > 400 then
        return false
    end
    if path:find("%.%.") or path:find(":") or path:find("\\") or path:sub(1, 1) == "/" then
        return false
    end
    for part in path:gmatch("[^/]+") do
        if part == "." then
            return false
        end
    end
    return true
end

function ADJobs.receiveCoursePart(connection, path, index, count, data)
    if not ADJobs.isSafeCoursePath(path) or count < 1 or count > math.ceil(ADJobs.UPLOAD_MAX / ADJobs.UPLOAD_CHUNK) or index < 1 or index > count then
        Logging.warning("[AD Jobs] Kurs-Upload abgelehnt: '%s'", tostring(path))
        return
    end
    local key = connection or "local"
    ADJobs.uploads[key] = ADJobs.uploads[key] or {}
    local u = ADJobs.uploads[key][path]
    -- a part that is already there means the file is sent again (new upload): start over
    if u == nil or u.count ~= count or u.parts[index] ~= nil then
        u = {count = count, parts = {}, received = 0}
        ADJobs.uploads[key][path] = u
    end
    u.received = u.received + 1
    u.parts[index] = data
    if u.received < count then
        return
    end
    ADJobs.uploads[key][path] = nil
    local text = table.concat(u.parts)
    ADJobs.storeServerCourse(path, text)
end

--- writes a course file into the Courseplay course folder of the server; true on success
function ADJobs.storeServerCourse(path, text)
    if #text > ADJobs.UPLOAD_MAX or not text:find("<") then
        Logging.warning("[AD Jobs] Kurs '%s' vom Spieler ungültig - nicht gespeichert", path)
        return false
    end
    local cp = ADJobs.resolveCourseplay()
    local root = nil
    if cp ~= nil then
        pcall(function()
            root = cp.courseStorage:getRootDirectory():getFullPath()
        end)
    end
    if root == nil then
        Logging.warning("[AD Jobs] Kurs '%s' vom Spieler: Courseplay-Kursordner des Servers unbekannt", path)
        return false
    end
    if loadXMLFileFromMemory == nil or saveXMLFileTo == nil then
        Logging.warning("[AD Jobs] Kurs '%s' vom Spieler: das Spiel kann keine XML-Datei aus dem Speicher schreiben", path)
        return false
    end
    local handle = loadXMLFileFromMemory("adjCourseStore", text)
    if handle == nil or handle == 0 then
        Logging.warning("[AD Jobs] Kurs '%s' vom Spieler ist keine gültige XML-Datei", path)
        return false
    end
    -- folders below the course folder
    local dir = root
    local parts = {}
    for p in path:gmatch("[^/]+") do
        table.insert(parts, p)
    end
    for i = 1, #parts - 1 do
        dir = dir .. "/" .. parts[i]
        createFolder(dir)
    end
    local full = root .. "/" .. path
    local ok, res = pcall(saveXMLFileTo, handle, full)
    delete(handle)
    if not ok or res == false then
        Logging.warning("[AD Jobs] Kurs '%s' konnte auf dem Server nicht gespeichert werden (%s)", path, tostring(res))
        return false
    end
    -- Courseplay should see it in its own list too
    pcall(function()
        if cp.courseStorage.refresh ~= nil then
            cp.courseStorage:refresh()
        end
    end)
    Logging.info("[AD Jobs] Courseplay-Kurs '%s' vom Spieler auf dem Server gespeichert: %s", path, full)
    return true
end
