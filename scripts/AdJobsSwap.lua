--
-- AutoDrive Jobs - trailer swap
--
-- A job can be bound to one trailer ("job trailer", e.g. the milk trailer). Two AD park positions:
--   A = the park position of the job = AD park position of the trailer not in use (the vehicle rests
--       here with that trailer; AutoDrive reverses the trailer onto the waypoint)
--   B = the AD park position of the job trailer (assigned to the trailer in AutoDrive; job field
--       "swapMarker" only overrides it)
-- The waypoint is where the TRAILER stands, so a vehicle without trailer "driving to" it reverses
-- towards the drawbar of that trailer. The mod watches the distance of the couplings every frame,
-- stops AutoDrive right before they touch and attaches (see updateSwapFast).
-- If another trailer hangs on the vehicle when the job wants to start, the vehicle swaps:
--   1. detach that trailer at A (where it stands)
--   2. reverse towards B, attach the job trailer, start the run from there
--   3. while the job trailer is on board the AD park position of the vehicle is redirected to B (the
--      other trailer stands at A) - whoever parks it, AutoDrive or the player, it ends up at B
--   4. as soon as the vehicle rests with the job trailer and the job does not need it: detach the job
--      trailer at B, reverse towards A, attach the other trailer again, park position back to A
--
-- Config fields of a job:   swapTrailerUid, swapMarker
-- Runtime fields (saved):   job.returnTrailerUid (which trailer goes back on), job.parkRestore (own park position)
-- Runtime fields (not saved): job.swap (phase table)
--
-- Everything here runs on the server only (called from ADJobs.updateJob).
--

ADJobs.ST_SWAP = 11                    -- HUD state: swapping trailers
ADJobs.SWAP_ATTACH_DIST = 3.0          -- m between the two coupling nodes for a normal attach
ADJobs.SWAP_ATTACH_DIST_MAX = 7.0      -- m, above that no attach (would look like teleporting)
ADJobs.SWAP_ATTACH_ANGLE = math.rad(60)
ADJobs.SWAP_SETTLE_TIME = 1500         -- ms to wait after an attach before driving off
ADJobs.SWAP_STAND_DIST = 6             -- m, "vehicle stands at the marker" for the swap stands (tighter than PARK_DISTANCE)
ADJobs.SWAP_TIMEOUT = 10 * 60000       -- ms a single swap phase may take before the job reports an error
ADJobs.SWAP_STOP_DIST = 1.2            -- m between the couplings at which AutoDrive is stopped while reversing towards a trailer
ADJobs.SWAP_STOP_SPEED = 12            -- km/h, above that the vehicle is stopped a bit earlier (braking distance)
ADJobs.SWAP_IDLE_TIME = 60000          -- ms a vehicle with the job trailer must rest away from the stands before it swaps back by itself

-------------------------------------------------------------------------------------------------
-- helpers
-------------------------------------------------------------------------------------------------

--- the job trailer: by its unique id; if that does not resolve any more (ids may change between sessions)
--- by its name among the trailers of the farm - a unique match is adopted and the id is updated
function ADJobs.getSwapTrailer(job)
    local trailer = ADJobs.getVehicleByUid(job.swapTrailerUid)
    if trailer ~= nil then
        return trailer
    end
    local name = job.swapTrailerName or ""
    if name == "" then
        return nil
    end
    -- PERF: the name scan over all vehicles (one string per trailer) runs 5-10 times per rule check while the
    -- trailer is missing; remember a miss for a few seconds (same interval as the uid cache)
    if job._swapTrailerMiss ~= nil and g_time ~= nil and g_time - job._swapTrailerMiss < (ADJobs.UID_MISS_CACHE_MS or 5000) then
        return nil
    end
    local found, count = nil, 0
    for _, v in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if not v.isDeleted and v.spec_attachable ~= nil and ADJobs.hasOwnCargo(v)
            and (job.farmId == nil or job.farmId == 0 or v:getOwnerFarmId() == job.farmId)
            and ADJobs.getVehicleName(v) == name then
            found, count = v, count + 1
        end
    end
    if count == 1 and found.getUniqueId ~= nil then
        local newUid = found:getUniqueId()
        Logging.info("[AD Jobs] Auftrag %d '%s': Auftrags-Anhänger '%s' über den Namen gefunden (UID '%s' -> '%s')",
            job.id or 0, tostring(job.name), name, tostring(job.swapTrailerUid), tostring(newUid))
        if newUid ~= nil and newUid ~= "" then
            job.swapTrailerUid = newUid
        end
        job._swapTrailerMiss = nil
        return found
    end
    job._swapTrailerMiss = g_time or 0
    return nil
end

--- the AD park position of the job trailer: the one chosen in the job, otherwise ("automatic") the park
--- position assigned to the trailer itself in AutoDrive; "" if there is none
function ADJobs.getSwapMarker(job)
    if (job.swapMarker or "") ~= "" then
        return job.swapMarker
    end
    local trailer = ADJobs.getSwapTrailer(job)
    local advd = trailer ~= nil and trailer.advd or nil
    if advd ~= nil and type(advd.parkDestination) == "number" and advd.parkDestination >= 1 and ADJobs.resolveAutoDrive() then
        local marker = ADJobs.GM:getMapMarkerById(advd.parkDestination)
        if marker ~= nil and marker.name ~= nil then
            return marker.name
        end
    end
    return ""
end

--- does this job use the trailer swap at all?
function ADJobs.usesSwap(job)
    return (job.swapTrailerUid or "") ~= "" and ADJobs.getSwapMarker(job) ~= ""
end

--- is the trailer with this uid part of the combination?
function ADJobs.hasTrailerUid(vehicle, uid)
    if (uid or "") == "" then
        return false
    end
    for _, v in ipairs(ADJobs.getVehicleUnits(vehicle)) do
        local vuid = v.getUniqueId ~= nil and v:getUniqueId() or v.uniqueId
        if v ~= vehicle and vuid ~= nil and tostring(vuid) == tostring(uid) then
            return true
        end
    end
    return false
end

--- a free trailer of the farm standing at an AD marker (for the swap back when the id of the
--- trailer from before the run does not resolve any more)
function ADJobs.findFreeTrailerAt(markerName, farmId, exclude)
    local idx = ADJobs.getMarkerIndexByName(markerName)
    local marker = idx ~= nil and ADJobs.GM:getMapMarkerById(idx) or nil
    local wp = marker ~= nil and ADJobs.GM:getWayPointById(marker.id) or nil
    if wp == nil then
        return nil
    end
    local best, bestDist = nil, ADJobs.PARK_DISTANCE
    for _, v in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if v ~= exclude and not v.isDeleted and v.spec_attachable ~= nil and v.rootNode ~= nil
            and (v.getAttacherVehicle == nil or v:getAttacherVehicle() == nil)
            and (farmId == nil or farmId == 0 or v:getOwnerFarmId() == farmId) then
            local x, _, z = getWorldTranslation(v.rootNode)
            local d = MathUtil.vector2Length(x - wp.x, z - wp.z)
            if d <= bestDist then
                best, bestDist = v, d
            end
        end
    end
    return best
end

--- the implements hanging directly on the vehicle (not what hangs on those)
local function directImplements(vehicle)
    local list = {}
    if vehicle.getAttachedImplements ~= nil then
        for _, impl in ipairs(vehicle:getAttachedImplements()) do
            if impl.object ~= nil then
                table.insert(list, impl.object)
            end
        end
    end
    return list
end

local function vehicleStands(vehicle)
    local speed = vehicle.getLastSpeed ~= nil and vehicle:getLastSpeed() or 0
    return speed < 0.5
end

local function isNearMarkerName(vehicle, markerName, dist)
    local idx = ADJobs.getMarkerIndexByName(markerName)
    local marker = idx ~= nil and ADJobs.GM:getMapMarkerById(idx) or nil
    local wp = marker ~= nil and ADJobs.GM:getWayPointById(marker.id) or nil
    if wp == nil then
        return false
    end
    local x, _, z = getWorldTranslation(vehicle.rootNode)
    return MathUtil.vector2Length(x - wp.x, z - wp.z) <= (dist or ADJobs.SWAP_STAND_DIST)
end

--- AutoDrive "drive to" a marker (same as ADJobs.sendToPark, but any marker); false if AD did not start
function ADJobs.driveToMarker(vehicle, markerName)
    local idx = ADJobs.getMarkerIndexByName(markerName)
    if idx == nil then
        return false
    end
    return ADJobs.startDriveTo(vehicle, idx)
end

--- stops AutoDrive (external API, otherwise the vehicle function, otherwise the state module)
function ADJobs.stopDriving(vehicle)
    local sm = vehicle.ad ~= nil and vehicle.ad.stateModule or nil
    if sm == nil or not sm:isActive() then
        return true
    end
    if ADJobs.AD ~= nil and type(ADJobs.AD.StopDriving) == "function" then
        pcall(ADJobs.AD.StopDriving, ADJobs.AD, vehicle)
    end
    if sm:isActive() and vehicle.stopAutoDrive ~= nil then
        pcall(vehicle.stopAutoDrive, vehicle)
    end
    if sm:isActive() and sm.setActive ~= nil then
        pcall(sm.setActive, sm, false)
        pcall(sm.raiseDirtyFlag, sm)
    end
    -- make sure the vehicle brakes (AD may have left a motor state behind)
    if vehicle.setCruiseControlState ~= nil and Drivable ~= nil then
        pcall(vehicle.setCruiseControlState, vehicle, Drivable.CRUISECONTROL_STATE_OFF)
    end
    return not sm:isActive()
end

--- distance between the nearest pair of coupling nodes of vehicle and trailer (nil if none fits)
function ADJobs.couplingDistance(vehicle, trailer)
    local aj = vehicle.spec_attacherJoints
    local at = trailer.spec_attachable
    if aj == nil or at == nil then
        return nil
    end
    local best = nil
    for i, joint in ipairs(aj.attacherJoints or {}) do
        local free = vehicle.getImplementByJointDescIndex == nil or vehicle:getImplementByJointDescIndex(i) == nil
        if free and joint.jointTransform ~= nil then
            for _, input in ipairs(at.inputAttacherJoints or {}) do
                if input.jointType == joint.jointType and input.node ~= nil then
                    local x1, y1, z1 = getWorldTranslation(joint.jointTransform)
                    local x2, y2, z2 = getWorldTranslation(input.node)
                    local d = MathUtil.vector3Length(x1 - x2, y1 - y2, z1 - z2)
                    if best == nil or d < best then
                        best = d
                    end
                end
            end
        end
    end
    return best
end

--- attach exactly this trailer; true on success, false + reason otherwise
function ADJobs.attachTrailer(vehicle, trailer)
    if trailer == nil or trailer.isDeleted then
        return false, "gone"
    end
    if trailer.getAttacherVehicle ~= nil and trailer:getAttacherVehicle() ~= nil then
        return false, "attachedElsewhere"
    end
    ADJobs.wakeVehicle(trailer)
    -- 1. the normal way (same checks as the player's attach key, with a wider distance)
    local distSq = ADJobs.SWAP_ATTACH_DIST * ADJobs.SWAP_ATTACH_DIST
    local ok, info = pcall(vehicle.findVehicleInAttachRange, vehicle, {trailer}, distSq, ADJobs.SWAP_ATTACH_ANGLE)
    if ok and info ~= nil and info.attachable == trailer and vehicle.attachImplementFromInfo ~= nil then
        local ok2 = pcall(vehicle.attachImplementFromInfo, vehicle, info)
        if ok2 and ADJobs.hasTrailerUid(vehicle, trailer:getUniqueId()) then
            return true
        end
    end
    -- 2. the vehicle did not stop exactly: attach the nearest compatible joint pair as long as it is not absurd
    local dist = ADJobs.couplingDistance(vehicle, trailer)
    if dist == nil then
        return false, "noJoint"
    end
    if dist > ADJobs.SWAP_ATTACH_DIST_MAX then
        return false, "tooFar"
    end
    local aj = vehicle.spec_attacherJoints
    local at = trailer.spec_attachable
    for i, joint in ipairs(aj.attacherJoints or {}) do
        local free = vehicle.getImplementByJointDescIndex == nil or vehicle:getImplementByJointDescIndex(i) == nil
        if free then
            for j, input in ipairs(at.inputAttacherJoints or {}) do
                if input.jointType == joint.jointType then
                    -- AttacherJoints:attachImplement(object, inputJointDescIndex, jointDescIndex, noEventSend, index, startLowered, noSmoothAttach)
                    local ok3 = pcall(vehicle.attachImplement, vehicle, trailer, j, i, false, nil, nil, false)
                    if ok3 and ADJobs.hasTrailerUid(vehicle, trailer:getUniqueId()) then
                        return true
                    end
                end
            end
        end
    end
    return false, "attachFailed"
end

--- detach everything that hangs directly on the vehicle; returns true when nothing hangs there any more
function ADJobs.detachAll(vehicle)
    local left = false
    for _, obj in ipairs(directImplements(vehicle)) do
        local allowed = obj.isDetachAllowed == nil or obj:isDetachAllowed()
        if allowed then
            pcall(vehicle.detachImplementByObject, vehicle, obj)
        else
            left = true
        end
    end
    return not left and #directImplements(vehicle) == 0
end

-------------------------------------------------------------------------------------------------
-- state machine
-------------------------------------------------------------------------------------------------

--- the job whose swap config is used (a chained job uses the config of the job that swapped)
local function swapConfig(job)
    local src = job._swapFrom
    if src ~= nil and ADJobs.usesSwap(src) then
        return src
    end
    return job
end

--- the AD park position of the job: its park marker, otherwise the one set at the vehicle
local function parkMarkerName(job, vehicle)
    if (job.parkMarker or "") ~= "" then
        return job.parkMarker
    end
    if vehicle ~= nil and ADJobs.resolveAutoDrive() then
        local ok, idx = pcall(ADJobs.AD.GetParkDestination, ADJobs.AD, vehicle)
        local marker = ok and type(idx) == "number" and ADJobs.GM:getMapMarkerById(idx) or nil
        if marker ~= nil then
            return marker.name
        end
    end
    return ""
end

-------------------------------------------------------------------------------------------------
-- AD park position of the vehicle (redirected to the stand of the job trailer for the last drive)
-------------------------------------------------------------------------------------------------

--- sets the AutoDrive park position of a vehicle / trailer (AD "advd" data); true if it could be set
function ADJobs.setParkDestination(obj, idx)
    local advd = obj ~= nil and obj.advd or nil
    if advd == nil or idx == nil then
        return false
    end
    if advd.parkDestination == idx then
        return true -- already set (no network event every rule check)
    end
    ADJobs.invalidateParkCache()
    local done = false
    if type(advd.setParkDestination) == "function" then
        -- AutoDrive API (synchronises the clients); the signature differs between versions, so check the result
        local ok = pcall(advd.setParkDestination, advd, obj, idx, true)
        done = ok and advd.parkDestination == idx
        if not done then
            ok = pcall(advd.setParkDestination, advd, idx)
            done = ok and advd.parkDestination == idx
        end
    end
    if not done then
        advd.parkDestination = idx
    end
    return true
end

--- called when the last drive of a run begins: with the swapped trailer on board the vehicle must park
--- at the stand of that trailer, because the other trailer stands at the park position
function ADJobs.redirectParkForSwap(job, vehicle)
    if (job.returnTrailerUid or "") == "" or vehicle == nil or vehicle.ad == nil then
        return
    end
    local cfg = swapConfig(job)
    if not ADJobs.usesSwap(cfg) or not ADJobs.hasTrailerUid(vehicle, cfg.swapTrailerUid) then
        return
    end
    local standName = ADJobs.getSwapMarker(cfg)
    local standIdx = ADJobs.getMarkerIndexByName(standName)
    if standIdx == nil then
        return
    end
    local first = (job.parkRestore or "") == ""
    if first then
        job.parkRestore = parkMarkerName(job, vehicle)
    end
    ADJobs.setParkDestination(vehicle, standIdx)
    ADJobs.setParkDestination(ADJobs.getSwapTrailer(cfg), standIdx)
    if first then
        Logging.info("[AD Jobs] Auftrag %d '%s': %s parkt solange am Stellplatz '%s' (Parkplatz '%s' ist belegt)", job.id, tostring(job.name),
            ADJobs.getVehicleName(vehicle), tostring(standName), tostring(job.parkRestore))
    end
end

--- the swap cycle is over (other trailer back on, or nothing to swap back any more): forget the
--- trailer from before the run and give the vehicle its own park position back
function ADJobs.clearSwapCycle(job, vehicle)
    job.returnTrailerUid = ""
    job._swapFrom = nil
    ADJobs.restoreParkAfterSwap(job, vehicle)
end

--- gives the vehicle its own park position back (after the redirected drive, or after a savegame load)
function ADJobs.restoreParkAfterSwap(job, vehicle)
    if (job.parkRestore or "") == "" then
        return
    end
    vehicle = vehicle or job._veh or ADJobs.getVehicleByUid(job.vehicleUid)
    local idx = ADJobs.getMarkerIndexByName(job.parkRestore)
    if vehicle ~= nil and idx ~= nil then
        ADJobs.setParkDestination(vehicle, idx)
    end
    job.parkRestore = ""
end

-------------------------------------------------------------------------------------------------
-- state machine
-------------------------------------------------------------------------------------------------

--- begins a swap; false (with the error set at the job) if it can not start.
--- direction "out": job trailer on (other one stays at the park position A, job trailer is fetched at B)
--- direction "back": the trailer from before the run on (job trailer stays at B, other one is fetched at A)
function ADJobs.startSwap(job, vehicle, direction)
    local cfg = swapConfig(job)
    local parkName = parkMarkerName(job, vehicle)
    local wantUid, dropMarker, pickMarker
    if direction == "out" then
        -- remember what hangs on the vehicle now, it comes back on after the job
        local current = directImplements(vehicle)[1]
        job.returnTrailerUid = current ~= nil and current.getUniqueId ~= nil and current:getUniqueId() or ""
        wantUid, dropMarker, pickMarker = cfg.swapTrailerUid, parkName, ADJobs.getSwapMarker(cfg)
    else
        wantUid, dropMarker, pickMarker = job.returnTrailerUid, ADJobs.getSwapMarker(cfg), parkName
    end
    local wanted = direction == "out" and ADJobs.getSwapTrailer(cfg) or ADJobs.getVehicleByUid(wantUid)
    if wanted == nil and direction == "back" then
        -- id of the trailer from before the run does not resolve (changed between sessions?):
        -- take the free trailer standing at the park position
        wanted = ADJobs.findFreeTrailerAt(parkName, job.farmId, ADJobs.getSwapTrailer(cfg))
        if wanted ~= nil and wanted.getUniqueId ~= nil then
            Logging.info("[AD Jobs] Auftrag %d '%s': Anhänger für das Zurückkoppeln am Parkplatz gefunden: %s", job.id, tostring(job.name), ADJobs.getVehicleName(wanted))
            wantUid = wanted:getUniqueId()
            job.returnTrailerUid = wantUid
        end
    end
    if wanted == nil then
        job.state, job.msgCode = ADJobs.ST_ERROR, 23
        ADJobs.logVehicleIds(string.format("Auftrag %d '%s': Anhänger mit UID '%s' (%s) nicht gefunden", job.id, tostring(job.name), tostring(wantUid),
            direction == "out" and tostring(cfg.swapTrailerName) or "Rückkoppeln"))
        return false
    end
    if direction == "out" then
        wantUid = wanted:getUniqueId()
    end
    if ADJobs.getMarkerIndexByName(dropMarker) == nil or ADJobs.getMarkerIndexByName(pickMarker) == nil then
        job.state, job.msgCode = ADJobs.ST_ERROR, 24
        return false
    end
    job.swap = {direction = direction, wantUid = wantUid, dropMarker = dropMarker, pickMarker = pickMarker,
        phase = "toDrop", since = g_time, adSeen = false}
    job._veh = vehicle
    job.state, job.msgCode = ADJobs.ST_SWAP, 0
    ADJobs.lastSyncKey = nil
    Logging.info("[AD Jobs] Auftrag %d '%s': %s koppelt um (%s): Anhänger ab bei '%s', %s an bei '%s'", job.id, tostring(job.name),
        ADJobs.getVehicleName(vehicle), direction, tostring(dropMarker), ADJobs.getVehicleName(ADJobs.getVehicleByUid(wantUid)), tostring(pickMarker))
    return true
end

local function phaseTo(job, phase)
    job.swap.phase = phase
    job.swap.since = g_time
    job.swap.adSeen = false
end

--- drives to a marker and reports arrival; returns "driving", "arrived" or "failed"
local function driveStep(job, vehicle, markerName, nearDist)
    local swap = job.swap
    local sm = vehicle.ad.stateModule
    if sm:isActive() then
        swap.adSeen = true
        return "driving"
    end
    if swap.adSeen then
        -- AD switched off: it stopped at the marker
        return vehicleStands(vehicle) and "arrived" or "driving"
    end
    if isNearMarkerName(vehicle, markerName, nearDist) and vehicleStands(vehicle) then
        return "arrived"
    end
    if not ADJobs.driveToMarker(vehicle, markerName) then
        return "failed"
    end
    return "driving"
end

local function finishSwap(job, state)
    job.swap = nil
    job.state, job.msgCode = state, 0
end

--- one tick of the swap; returns true while the swap decides the job state
function ADJobs.updateSwap(job)
    local swap = job.swap
    if swap == nil then
        return false
    end
    local vehicle = job._veh
    if vehicle == nil or vehicle.isDeleted or vehicle.ad == nil then
        finishSwap(job, ADJobs.ST_ERROR)
        job.msgCode = 2
        return true
    end
    -- the player took over: do not fight with him, try again later
    if vehicle.getIsControlled ~= nil and vehicle:getIsControlled() then
        job.state, job.msgCode = ADJobs.ST_NOTREADY, 7
        return true
    end
    if g_time - (swap.since or g_time) > ADJobs.SWAP_TIMEOUT then
        finishSwap(job, ADJobs.ST_ERROR)
        job.msgCode = 22
        Logging.warning("[AD Jobs] Auftrag %d '%s': Umkoppeln abgebrochen (Phase %s dauert zu lange)", job.id, tostring(job.name), tostring(swap.phase))
        return true
    end
    job.state, job.msgCode = ADJobs.ST_SWAP, 0

    local wanted = ADJobs.getVehicleByUid(swap.wantUid)

    if swap.phase == "toDrop" then
        if ADJobs.hasTrailerUid(vehicle, swap.wantUid) then
            -- the right one already hangs there (player did it by hand)
            finishSwap(job, job.active and ADJobs.ST_WAIT or ADJobs.ST_OFF)
            if swap.direction == "back" then
                ADJobs.clearSwapCycle(job, vehicle)
            else
                ADJobs.redirectParkForSwap(job, vehicle)
            end
            return false
        end
        if #directImplements(vehicle) == 0 then
            -- nothing to drop: straight to the pick-up
            phaseTo(job, "toPick")
            return true
        end
        -- "out": the vehicle already rests at the park position (that is where the other trailer stays);
        -- "back": AutoDrive parked at the stand of the job trailer. Drive only if it stands somewhere else.
        local r = driveStep(job, vehicle, swap.dropMarker, ADJobs.PARK_DISTANCE)
        if r == "arrived" then
            phaseTo(job, "detach")
        elseif r == "failed" then
            finishSwap(job, ADJobs.ST_ERROR)
            job.msgCode = 10
        end

    elseif swap.phase == "detach" then
        if ADJobs.detachAll(vehicle) then
            Logging.info("[AD Jobs] Auftrag %d '%s': Anhänger bei '%s' abgekoppelt", job.id, tostring(job.name), tostring(swap.dropMarker))
            phaseTo(job, "toPick")
        end
        -- otherwise: isDetachAllowed() false (unloading, cover open ...) - wait

    elseif swap.phase == "toPick" then
        if wanted == nil then
            finishSwap(job, ADJobs.ST_ERROR)
            job.msgCode = 23
            return true
        end
        -- the marker is the park position of the trailer itself: the vehicle reverses towards its drawbar.
        -- updateSwapFast (every frame) stops AutoDrive right before the couplings touch; if AutoDrive
        -- stops by itself (end of the route reached, blocked) the attach is tried as well
        if not swap.adSeen and vehicleStands(vehicle) then
            local dist = ADJobs.couplingDistance(vehicle, wanted)
            if dist ~= nil and dist <= ADJobs.SWAP_ATTACH_DIST then
                -- already standing at the drawbar (e.g. savegame loaded right here)
                phaseTo(job, "attach")
                return true
            end
        end
        local r = driveStep(job, vehicle, swap.pickMarker, 0)
        if r == "arrived" then
            phaseTo(job, "attach")
        elseif r == "failed" then
            finishSwap(job, ADJobs.ST_ERROR)
            job.msgCode = 10
        end

    elseif swap.phase == "attach" then
        if not vehicleStands(vehicle) then
            return true
        end
        local ok, reason = ADJobs.attachTrailer(vehicle, wanted)
        if ok then
            Logging.info("[AD Jobs] Auftrag %d '%s': %s bei '%s' angekoppelt", job.id, tostring(job.name), ADJobs.getVehicleName(wanted), tostring(swap.pickMarker))
            phaseTo(job, "settle")
        else
            finishSwap(job, ADJobs.ST_ERROR)
            job.msgCode = 21
            Logging.warning("[AD Jobs] Auftrag %d '%s': Ankoppeln fehlgeschlagen (%s)", job.id, tostring(job.name), tostring(reason))
        end

    elseif swap.phase == "settle" then
        if g_time - swap.since >= ADJobs.SWAP_SETTLE_TIME then
            if swap.direction == "out" then
                -- done: the vehicle stands at the stand of the job trailer, the normal start logic takes over
                -- in this tick (checkReady accepts that stand as start position). From now on the vehicle
                -- parks at this stand, whoever sends it to park.
                finishSwap(job, ADJobs.ST_WAIT)
                ADJobs.redirectParkForSwap(job, vehicle)
                return false
            end
            -- back: the vehicle stands at its park position with the trailer from before the run
            ADJobs.clearSwapCycle(job, vehicle)
            finishSwap(job, job.active and ADJobs.ST_WAIT or ADJobs.ST_OFF)
            Logging.info("[AD Jobs] Auftrag %d '%s': Umkoppeln fertig, %s steht am Parkplatz", job.id, tostring(job.name), ADJobs.getVehicleName(vehicle))
        end
    end
    return true
end

--- every frame while reversing towards a trailer: stop AutoDrive right before the couplings touch
function ADJobs.updateSwapFast(job, vehicle)
    local swap = job.swap
    if swap == nil or swap.phase ~= "toPick" or vehicle.ad == nil then
        return
    end
    local sm = vehicle.ad.stateModule
    if not sm:isActive() then
        return
    end
    swap.adSeen = true
    local trailer = ADJobs.getVehicleByUid(swap.wantUid)
    if trailer == nil then
        return
    end
    local dist = ADJobs.couplingDistance(vehicle, trailer)
    if dist == nil then
        return
    end
    swap.lastDist = dist
    local speed = vehicle.getLastSpeed ~= nil and vehicle:getLastSpeed() or 0
    local stopDist = ADJobs.SWAP_STOP_DIST
    if speed > ADJobs.SWAP_STOP_SPEED then
        stopDist = stopDist + (speed - ADJobs.SWAP_STOP_SPEED) * 0.15
    end
    if dist <= stopDist then
        ADJobs.stopDriving(vehicle)
        Logging.info("[AD Jobs] Auftrag %d '%s': %s hält vor %s (Kupplungsabstand %.1f m)", job.id, tostring(job.name),
            ADJobs.getVehicleName(vehicle), ADJobs.getVehicleName(trailer), dist)
        phaseTo(job, "attach")
    end
end

--- is a swap back due? (job trailer still on from an earlier run, nothing running)
local function swapBackDue(job)
    if job.running or job.swap ~= nil or (job.returnTrailerUid or "") == "" then
        return false
    end
    if not ADJobs.usesSwap(swapConfig(job)) then
        ADJobs.clearSwapCycle(job, nil)
        return false
    end
    -- the same trailer is needed again right away (level already over the limit again)? keep it on
    if job.active and ADJobs.needsRun(job) and (job.pauseUntil == nil or g_time >= job.pauseUntil) then
        return false
    end
    return true
end

local function vehicleIdle(vehicle)
    return vehicle ~= nil and not vehicle.isDeleted and vehicle.ad ~= nil and not vehicle.ad.stateModule:isActive()
        and not (vehicle.getIsControlled ~= nil and vehicle:getIsControlled())
        and not (vehicle.getIsAIActive ~= nil and vehicle:getIsAIActive())
end

--- called when a run has finished and the vehicle parks: put the other trailer back on if needed
function ADJobs.afterRunSwapBack(job)
    if not swapBackDue(job) then
        return false
    end
    local vehicle = ADJobs.findVehicle(job)
    if not vehicleIdle(vehicle) then
        return false
    end
    return ADJobs.startSwap(job, vehicle, "back")
end

--- called every tick while nothing runs: a swap back that is still open (savegame loaded in the
--- middle of it, job switched off, vehicle was busy when the run ended) starts as soon as the
--- vehicle rests at its park position or at the stand of the job trailer; true if the swap owns the state now
function ADJobs.pendingSwapBack(job)
    if not swapBackDue(job) then
        return false
    end
    local vehicle = ADJobs.findVehicle(job)
    if vehicle == nil then
        vehicle = ADJobs.getVehicleByUid(job.vehicleUid)
    end
    if vehicle == nil or vehicle.isDeleted then
        return false
    end
    -- the job trailer is not on any more (player swapped by hand): nothing to swap back
    if not ADJobs.hasTrailerUid(vehicle, swapConfig(job).swapTrailerUid) then
        ADJobs.clearSwapCycle(job, vehicle)
        return false
    end
    -- the vehicle still carries the job trailer: it keeps parking at the stand of that trailer
    ADJobs.redirectParkForSwap(job, vehicle)
    if not vehicleIdle(vehicle) or not vehicleStands(vehicle) then
        job._idleSince = nil
        return false
    end
    -- other jobs may be using the vehicle
    for _, other in ipairs(ADJobs.jobs) do
        if other ~= job and (other.running or other.swap ~= nil) and other._veh == vehicle then
            return false
        end
    end
    local parkIdx = ADJobs.getMarkerIndexByName(parkMarkerName(job, vehicle))
    local standIdx = ADJobs.getMarkerIndexByName(ADJobs.getSwapMarker(swapConfig(job)))
    local atPark = parkIdx ~= nil and ADJobs.isNearMarker(vehicle, parkIdx)
    local atStand = standIdx ~= nil and ADJobs.isNearMarker(vehicle, standIdx)
    if not atPark and not atStand then
        -- somewhere else (the player drove it): only after it rested for a while and no pause is running
        -- (a pause means the player just ended something with it)
        job._idleSince = job._idleSince or g_time
        if job.pauseUntil ~= nil and g_time < job.pauseUntil then
            return false
        end
        if g_time - job._idleSince < ADJobs.SWAP_IDLE_TIME then
            return false
        end
    end
    job._idleSince = nil
    return ADJobs.startSwap(job, vehicle, "back")
end
