--
-- AutoDrive Jobs - network events
--   ADJChangeEvent : client -> server, create / update / delete / toggle a job, request the list
--   ADJSyncEvent   : server -> clients, complete job list with status
--
-- Every event starts with ADJobs.NET_VERSION. A client with another mod version than the server
-- would otherwise read the stream wrong and desynchronise silently.
--

local function readVersion(streamId, what)
    local v = streamReadUInt8(streamId)
    if v ~= ADJobs.NET_VERSION then
        if not ADJobs.netVersionWarned then
            ADJobs.netVersionWarned = true
            Logging.warning("[AD Jobs] %s: andere Mod-Version auf der Gegenseite (Netzwerk %d, hier %d) - bitte auf allen Rechnern dieselbe Version installieren",
                what, v, ADJobs.NET_VERSION)
        end
        return false
    end
    return true
end

local function objectId(obj)
    if obj == nil then
        return 0
    end
    local id = NetworkUtil.getObjectId(obj)
    return id or 0
end

local function writeJob(streamId, job, withStatus)
    streamWriteInt32(streamId, job.id or 0)
    streamWriteString(streamId, job.name or "")
    streamWriteBool(streamId, job.active == true)
    streamWriteString(streamId, job.driveMode or "deliver")
    streamWriteString(streamId, job.placeableUid or "")
    streamWriteString(streamId, job.placeableName or "")
    streamWriteString(streamId, job.sourceKind or "")
    streamWriteString(streamId, job.fillTypeName or "")
    streamWriteString(streamId, job.loadFillTypeName or "")
    streamWriteFloat32(streamId, job.low or 0)
    streamWriteFloat32(streamId, job.high or 0)
    streamWriteInt32(streamId, job.maxTrips or 0)
    streamWriteInt32(streamId, job.pauseMin or 0)
    streamWriteString(streamId, job.vehicleUid or "")
    streamWriteString(streamId, job.vehicleName or "")
    streamWriteString(streamId, job.loadMarker or "")
    streamWriteString(streamId, job.unloadMarker or "")
    streamWriteString(streamId, job.parkMarker or "")
    streamWriteInt32(streamId, job.farmId or 0)
    streamWriteString(streamId, job.emergencyMarker or "")
    -- object references chosen in the wizard (only used client -> server)
    streamWriteInt32(streamId, objectId(job.placeableObject))
    streamWriteInt32(streamId, objectId(job.vehicleObject))
    streamWriteBool(streamId, withStatus)
    if withStatus then
        streamWriteInt8(streamId, job.state or 0)
        streamWriteInt8(streamId, job.msgCode or 0)
        streamWriteFloat32(streamId, job.percent or -1)
        streamWriteFloat32(streamId, job.level or 0)
        streamWriteFloat32(streamId, job.capacity or 0)
        streamWriteInt32(streamId, job.tripsDone or 0)
        streamWriteInt32(streamId, job.pauseLeft or 0)
        streamWriteInt32(streamId, job.tripsTotal or 0)
    end
end

local function readJob(streamId)
    local job = {}
    job.id = streamReadInt32(streamId)
    job.name = streamReadString(streamId)
    job.active = streamReadBool(streamId)
    job.driveMode = streamReadString(streamId)
    job.placeableUid = streamReadString(streamId)
    job.placeableName = streamReadString(streamId)
    job.sourceKind = streamReadString(streamId)
    job.fillTypeName = streamReadString(streamId)
    job.loadFillTypeName = streamReadString(streamId)
    job.low = streamReadFloat32(streamId)
    job.high = streamReadFloat32(streamId)
    job.maxTrips = streamReadInt32(streamId)
    job.pauseMin = streamReadInt32(streamId)
    job.vehicleUid = streamReadString(streamId)
    job.vehicleName = streamReadString(streamId)
    job.loadMarker = streamReadString(streamId)
    job.unloadMarker = streamReadString(streamId)
    job.parkMarker = streamReadString(streamId)
    job.farmId = streamReadInt32(streamId)
    job.emergencyMarker = streamReadString(streamId)
    local placeableId = streamReadInt32(streamId)
    local vehicleId = streamReadInt32(streamId)
    if placeableId ~= 0 then
        job.placeableObject = NetworkUtil.getObject(placeableId)
    end
    if vehicleId ~= 0 then
        job.vehicleObject = NetworkUtil.getObject(vehicleId)
    end
    if streamReadBool(streamId) then
        job.state = streamReadInt8(streamId)
        job.msgCode = streamReadInt8(streamId)
        job.percent = streamReadFloat32(streamId)
        job.level = streamReadFloat32(streamId)
        job.capacity = streamReadFloat32(streamId)
        job.tripsDone = streamReadInt32(streamId)
        job.pauseLeft = streamReadInt32(streamId)
        job.tripsTotal = streamReadInt32(streamId)
    end
    return job
end

-------------------------------------------------------------------------------------------------

ADJChangeEvent = {}
local ADJChangeEvent_mt = Class(ADJChangeEvent, Event)
InitEventClass(ADJChangeEvent, "ADJChangeEvent")

ADJChangeEvent.OP_SAVE = 1
ADJChangeEvent.OP_DELETE = 2
ADJChangeEvent.OP_TOGGLE = 3
ADJChangeEvent.OP_REQUEST = 4
ADJChangeEvent.OP_RESET = 5

function ADJChangeEvent.emptyNew()
    return Event.new(ADJChangeEvent_mt)
end

function ADJChangeEvent.new(op, job)
    local self = ADJChangeEvent.emptyNew()
    self.op = op
    self.job = job or {id = 0}
    return self
end

function ADJChangeEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, ADJobs.NET_VERSION)
    streamWriteInt8(streamId, self.op)
    writeJob(streamId, self.job, false)
end

function ADJChangeEvent:readStream(streamId, connection)
    if not readVersion(streamId, "ADJChangeEvent") then
        return
    end
    self.op = streamReadInt8(streamId)
    self.job = readJob(streamId)
    self:run(connection)
end

function ADJChangeEvent:run(connection)
    if g_server ~= nil then
        if self.op == ADJChangeEvent.OP_REQUEST then
            connection:sendEvent(ADJSyncEvent.new(ADJobs.jobs))
        else
            ADJobs.applyChange(self.op, self.job)
        end
    end
end

function ADJChangeEvent.sendEvent(op, job)
    if g_server ~= nil then
        ADJobs.applyChange(op, job)
    else
        g_client:getServerConnection():sendEvent(ADJChangeEvent.new(op, job))
    end
end

-------------------------------------------------------------------------------------------------

ADJSyncEvent = {}
local ADJSyncEvent_mt = Class(ADJSyncEvent, Event)
InitEventClass(ADJSyncEvent, "ADJSyncEvent")

function ADJSyncEvent.emptyNew()
    return Event.new(ADJSyncEvent_mt)
end

function ADJSyncEvent.new(jobs)
    local self = ADJSyncEvent.emptyNew()
    self.jobs = jobs
    return self
end

function ADJSyncEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, ADJobs.NET_VERSION)
    streamWriteUInt16(streamId, #self.jobs)
    for _, job in ipairs(self.jobs) do
        writeJob(streamId, job, true)
    end
end

function ADJSyncEvent:readStream(streamId, connection)
    if not readVersion(streamId, "ADJSyncEvent") then
        return
    end
    local n = streamReadUInt16(streamId)
    local jobs = {}
    for i = 1, n do
        jobs[i] = readJob(streamId)
    end
    if g_server == nil then
        ADJobs.jobs = jobs
    end
end

function ADJSyncEvent:run(connection)
end
