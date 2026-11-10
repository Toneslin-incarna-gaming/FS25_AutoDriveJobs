--
-- AutoDrive Jobs - HUD in AutoDrive style (client side)
--
-- One panel that looks and works like the AutoDrive HUD:
--   * list view  : all jobs, on/off, edit, delete, level bar, status
--   * editor view: every setting is a row with an AD icon and a pull down list (with AD folders)
--                  or a counter (+ / -, mouse wheel), saved with one click
-- The panel can be moved by dragging the green header bar.
-- The vehicle of a job is chosen by its AutoDrive park position.
--

ADJobsHud = {}
local H = ADJobsHud

local function txt(...)
    return ADJobs.txt(...)
end

H.x = 0.015
H.top = 0.86
H.view = "list"
H.listScroll = 0
H.planScroll = 0
H.tab = "jobs"        -- "jobs" = all jobs, "plan" = planned jobs per vehicle (drag & drop order)
H.showStorages = false  -- numbers L1, L2 ... above the storages in the world
H.dnd = nil           -- drag & drop of a planned job: {id, veh, name, x0, y0, active}
H.boxes = {}
H.mouseX, H.mouseY = -1, -1
H.open = nil          -- key of the expanded pull down list
H.pdScroll = 0
H.pdEntries = {}
H.folders = {}        -- [listKey .. "|" .. group] = open?
H.draft = nil
H.showMissing = false
H.positionLoaded = false

local MAX_JOB_ROWS = 8
local MAX_LIST_ROWS = 14
local NEAREST_COUNT = 8

local C_TEXT = {1, 1, 1, 1}
local C_HOVER = {0.51, 0.67, 0.05, 1}           -- AutoDrive hover colour
local C_SPECIAL = {0.66, 0.83, 0.34, 1}         -- AutoDrive "special" colour (selected entry, folders)
local C_GREY = {0.72, 0.72, 0.72, 1}
local C_RED = {1, 0.35, 0.3, 1}

-------------------------------------------------------------------------------------------------
-- sizes (like AutoDrive: pixel values * ui scale)
-------------------------------------------------------------------------------------------------

local M = {}

local function getUiScale()
    local s = 1
    if g_gameSettings ~= nil then
        s = g_gameSettings:getValue("uiScale") or 1
    end
    if ADJobs.AD ~= nil and ADJobs.AD.getSetting ~= nil then
        local ok, v = pcall(ADJobs.AD.getSetting, "guiScale")
        if ok and type(v) == "number" and v > 0 then
            s = v
        end
    end
    return s
end

local function updateMetrics()
    local s = getUiScale()
    local function px(v)
        local w, _ = getNormalizedScreenValues(v * s, 0)
        return w
    end
    local function py(v)
        local _, h = getNormalizedScreenValues(0, v * s)
        return h
    end
    M.px, M.py = px, py
    M.gapX, M.gapY = px(3), py(3)
    M.w = px(520)
    M.headerH = py(20)
    M.rowH = py(27)
    M.iconW, M.iconH = px(24), py(24)
    M.smallW, M.smallH = px(18), py(18)
    M.headW, M.headH = px(16), py(16)
    M.itemH = py(19)
    M.jobH = py(68)
    M.tabH = py(22)
    M.planH = py(40)
    M.font = 0.0115 * s
    M.small = 0.0098 * s
end

-------------------------------------------------------------------------------------------------
-- drawing helpers (AutoDrive textures "ad_gui.*", plain rectangles as fallback)
-------------------------------------------------------------------------------------------------

local overlays = {}

local function getOverlay(name)
    local o = overlays[name]
    if o == nil then
        o = false
        if g_overlayManager ~= nil and g_overlayManager.createOverlay ~= nil then
            local ok, ov = pcall(g_overlayManager.createOverlay, g_overlayManager, "ad_gui." .. name, 0, 0, 0.01, 0.01)
            if ok and type(ov) == "table" and ov.overlayId ~= nil and ov.overlayId ~= 0 then
                o = ov
            end
        end
        overlays[name] = o
    end
    return o or nil
end

--- area covered by an expanded pull down list; everything else is not drawn there
local function isOccluded(x, y, w, h)
    local o = H.occluder
    if o == nil or H.drawingList then
        return false
    end
    w, h = w or 0, h or 0
    return x + w > o.x and x < o.x + o.w and y + h > o.y and y < o.y + o.h
end

local function drawSlice(name, x, y, w, h, r, g, b, a)
    if isOccluded(x, y, w, h) then
        return true
    end
    local o = getOverlay(name)
    if o ~= nil then
        renderOverlay(o.overlayId, x, y, w, h)
        return true
    end
    if r ~= nil then
        drawFilledRect(x, y, w, h, r, g, b, a or 1)
    end
    return false
end

function H.deleteOverlays()
    for _, o in pairs(overlays) do
        if o and o.delete ~= nil then
            pcall(o.delete, o)
        end
    end
    overlays = {}
end

local function drawText(x, y, size, text, color, bold, align)
    if H.occluder ~= nil and not H.drawingList then
        local w = getTextWidth(size, tostring(text or ""))
        local left = x
        if align == RenderText.ALIGN_CENTER then
            left = x - w / 2
        elseif align == RenderText.ALIGN_RIGHT then
            left = x - w
        end
        if isOccluded(left, y, w, size * 0.8) then
            return
        end
    end
    local c = color or C_TEXT
    setTextBold(bold == true)
    setTextColor(c[1], c[2], c[3], c[4] or 1)
    setTextAlignment(align or RenderText.ALIGN_LEFT)
    renderText(x, y, size, tostring(text or ""))
end

--- y position for text that is vertically centred in a box
local function textY(y, h, size)
    return y + (h - size) / 2 + size * 0.12
end

--- shortens a text to maxWidth with ".." (binary search over UTF-8 characters, few getTextWidth calls);
--- the result is remembered for a few seconds (the same texts are drawn every frame)
local fitCache, fitCacheTime, fitCacheCount = {}, 0, 0
local function fit(text, maxWidth, size)
    text = tostring(text or "")
    if maxWidth <= 0 then
        return ""
    end
    if g_time - fitCacheTime > 5000 or fitCacheCount > 3000 then
        fitCache, fitCacheTime, fitCacheCount = {}, g_time, 0
    end
    local key = string.format("%.4f|%.4f|%s", maxWidth, size, text)
    local cached = fitCache[key]
    if cached ~= nil then
        return cached
    end
    local result = text
    if getTextWidth(size, text) > maxWidth then
        result = nil
    end
    if result == nil then
    local chars = {}
    for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        chars[#chars + 1] = ch
    end
    local lo, hi = 0, #chars
    while lo < hi do
        local mid = math.ceil((lo + hi) / 2)
        if getTextWidth(size, table.concat(chars, "", 1, mid) .. "..") <= maxWidth then
            lo = mid
        else
            hi = mid - 1
        end
    end
        result = table.concat(chars, "", 1, lo) .. ".."
    end
    fitCache[key] = result
    fitCacheCount = fitCacheCount + 1
    return result
end

local function isInside(x, y, w, h)
    local mx, my = H.mouseX, H.mouseY
    return mx >= x and mx <= x + w and my >= y and my <= y + h
end

local function inArea(a, px, py)
    return a ~= nil and px >= a.x and px <= a.x + a.w and py >= a.y and py <= a.y + a.h
end

--- clickable area; the last added box wins (= drawn on top)
local function addBox(x, y, w, h, onClick, onWheel, onRight)
    local box = {x = x, y = y, w = w, h = h, onClick = onClick, onWheel = onWheel, onRight = onRight}
    table.insert(H.boxes, box)
    return box
end

local function iconButton(name, x, y, w, h, fallback, onClick, onRight, onWheel)
    if isOccluded(x, y, w, h) then
        addBox(x, y, w, h, onClick, onWheel, onRight)
        return
    end
    if not drawSlice(name, x, y, w, h) then
        drawFilledRect(x, y, w, h, 0.32, 0.32, 0.32, 0.95)
        drawText(x + w / 2, textY(y, h, M.small), M.small, fallback or "?", C_TEXT, true, RenderText.ALIGN_CENTER)
    end
    if isInside(x, y, w, h) then
        drawFilledRect(x, y, w, h, 1, 1, 1, 0.18)
    end
    addBox(x, y, w, h, onClick, onWheel, onRight)
end

local function textButton(x, y, w, h, label, onClick, r, g, b)
    if isOccluded(x, y, w, h) then
        addBox(x, y, w, h, onClick)
        return
    end
    drawFilledRect(x, y, w, h, r or 0.22, g or 0.22, b or 0.22, 0.95)
    local hover = isInside(x, y, w, h)
    if hover then
        drawFilledRect(x, y, w, h, 1, 1, 1, 0.12)
    end
    drawText(x + w / 2, textY(y, h, M.font), M.font, fit(label, w - 2 * M.gapX, M.font), hover and C_HOVER or C_TEXT, true, RenderText.ALIGN_CENTER)
    addBox(x, y, w, h, onClick)
end

local function drawBackground(x, y, w, h)
    drawSlice("Background", x, y, w, h, 0.1, 0.1, 0.1, 0.88)
end

--- green AutoDrive header bar with the title and icons on the right; returns nothing
local function drawHeader(x, top, w, title, buttons)
    local y = top - M.headerH
    if not g_inputBinding:getShowMouseCursor() then
        title = title .. "   -   " .. txt("hintMouse")
    end
    drawSlice("Header", x, y, w, M.headerH, 0.3, 0.45, 0.05, 0.95)
    local bx = x + w - M.headW - M.gapX
    local by = y + (M.headerH - M.headH) / 2
    for _, b in ipairs(buttons) do
        if b.text ~= nil then
            -- text button (switch): green when on
            local tw = math.max(M.px(28), getTextWidth(M.small, b.text) + 4 * M.gapX)
            local tx = bx + M.headW - tw
            local hover = isInside(tx, by, tw, M.headH)
            if b.on then
                drawFilledRect(tx, by, tw, M.headH, C_HOVER[1], C_HOVER[2], C_HOVER[3], 0.95)
            else
                drawFilledRect(tx, by, tw, M.headH, 0.18, 0.18, 0.18, 0.95)
            end
            if hover then
                drawFilledRect(tx, by, tw, M.headH, 1, 1, 1, 0.18)
                if b.tip ~= nil then
                    H.nextTooltip = b.tip
                    if H.view == "edit" then
                        H.nextHint = b.tip
                    end
                end
            end
            drawText(tx + tw / 2, textY(by, M.headH, M.small), M.small, b.text, C_TEXT, true, RenderText.ALIGN_CENTER)
            addBox(tx, by, tw, M.headH, b[3])
            bx = tx - M.headW - M.gapX
        else
            iconButton(b[1], bx, by, M.headW, M.headH, b[2], b[3])
            bx = bx - M.headW - M.gapX
        end
    end
    local titleW = bx + M.headW - x - 3 * M.gapX
    drawText(x + 2 * M.gapX, textY(y, M.headerH, M.font), M.font, fit(title, titleW, M.font), C_TEXT, true)
    -- area to drag the panel (without the icons)
    H.dragArea = {x = x, y = y, w = bx + M.headW - x, h = M.headerH}
end

-------------------------------------------------------------------------------------------------
-- general helpers
-------------------------------------------------------------------------------------------------

local function getFarmId()
    if g_currentMission.getFarmId ~= nil then
        return g_currentMission:getFarmId()
    end
    return g_currentMission.player and g_currentMission.player.farmId or 1
end

local function cameraPosition()
    local camera = g_cameraManager ~= nil and g_cameraManager:getActiveCamera()
    if camera ~= nil and camera ~= 0 then
        local x, _, z = getWorldTranslation(camera)
        return x, z
    end
    return 0, 0
end

local function getCurrentVehicle()
    local current = nil
    if g_localPlayer ~= nil and g_localPlayer.getCurrentVehicle ~= nil then
        current = g_localPlayer:getCurrentVehicle()
    end
    if current ~= nil and current.getRootVehicle ~= nil then
        current = current:getRootVehicle()
    end
    return current
end

local function warn(key)
    g_currentMission:showBlinkingWarning(txt(key), 3000)
end

local function fillTypeTitle(name)
    local ft = g_fillTypeManager:getFillTypeIndexByName(name or "")
    local fillType = ft and g_fillTypeManager:getFillTypeByIndex(ft)
    if fillType ~= nil then
        return fillType.title or fillType.name
    end
    return tostring(name)
end

function ADJobs.getStatusText(job)
    local s = job.state or 0
    local text
    if s == ADJobs.ST_PAUSE then
        text = txt("st4", job.pauseLeft or 0)
    elseif s == ADJobs.ST_WAITPLACE then
        text = txt("st7", job.pauseLeft or 0)
    elseif s == ADJobs.ST_SEQ then
        local n, i, ph = job.seqCount or 0, job.seqIndex or 0, job.seqPhase or 0
        if ph == ADJobs.SEQ_PH_DRIVE then
            local step = ADJobs.getSteps(job)[i]
            text = txt("seqDrive", i, n, step ~= nil and tostring(step.marker) or "?")
        elseif ph == ADJobs.SEQ_PH_CPSTART then
            text = txt("seqCpStart", i, n)
        elseif ph == ADJobs.SEQ_PH_CP then
            text = txt("seqCp", i, n, job.seqPct or 0)
        elseif ph == ADJobs.SEQ_PH_ADCP then
            text = txt("seqCpAd", i, n, job.seqPct or 0)
        elseif ph == ADJobs.SEQ_PH_UNLOAD then
            text = txt("seqUnload", i, n)
        else
            text = txt("seqPark")
        end
        return text
    elseif s == ADJobs.ST_RESTRUN then
        return txt("st15", tostring(job.restMarker or "?"))
    elseif s == ADJobs.ST_STANDING then
        text = txt("st14", job.pauseLeft or 0)
        if (job.standWhere or 0) > 0 then
            text = text .. " " .. txt("stand" .. job.standWhere)
        end
        return text
    elseif s == ADJobs.ST_PRICE then
        text = txt("st13", math.floor(job.price or 0), math.floor(job.minPrice or 0))
    else
        text = txt("st" .. s)
    end
    if (job.msgCode or 0) > 0 then
        text = text .. ": " .. txt("msg" .. job.msgCode)
    end
    return text
end

local function statusColor(job)
    local s = job.state or 0
    if s == ADJobs.ST_ERROR then
        return C_RED
    elseif s == ADJobs.ST_RUN or s == ADJobs.ST_STOPPING or s == ADJobs.ST_TOPARK or s == ADJobs.ST_DUMP or s == ADJobs.ST_SWAP or s == ADJobs.ST_SENTPARK or s == ADJobs.ST_RESTRUN or s == ADJobs.ST_SEQ then
        return {0.4, 0.9, 1, 1}
    elseif s == ADJobs.ST_NOTREADY or s == ADJobs.ST_PAUSE or s == ADJobs.ST_PRICE or s == ADJobs.ST_STANDING then
        return {1, 0.8, 0.3, 1}
    elseif s == ADJobs.ST_OFF or s == ADJobs.ST_IDLEPARKED then
        return {0.6, 0.6, 0.6, 1}
    end
    return {0.5, 1, 0.5, 1}
end

--- vehicles at a park position, as short text (cached for one second)
local parkCache = {}
local function parkVehicleText(parkName, farmId)
    local key = tostring(parkName) .. "|" .. tostring(farmId)
    local c = parkCache[key]
    if c ~= nil and g_time - c.time < 1000 then
        return c.text, c.count, c.atPark
    end
    local idx = ADJobs.getMarkerIndexByName(parkName)
    local list = ADJobs.getVehiclesAtPark(idx, farmId)
    local names, atPark = {}, false
    for i, e in ipairs(list) do
        if i == 1 then
            -- the vehicle that would be started (nearest to the park position) with its trailer
            table.insert(names, ADJobs.getVehicleName(e.vehicle) .. " " .. ADJobs.getImplementText(e.vehicle))
        end
        if e.dist <= ADJobs.PARK_DISTANCE and ADJobs.isCombinationNearMarker(e.vehicle, idx) then
            atPark = true
        end
    end
    local text = table.concat(names, ", ")
    if #list > 1 then
        text = text .. string.format("  (+%d)", #list - 1)
    end
    if #list == 0 then
        text = txt("vehicleNone")
    end
    parkCache[key] = {time = g_time, text = text, count = #list, atPark = atPark}
    return text, #list, atPark
end

-------------------------------------------------------------------------------------------------
-- position of the panel (saved in modSettings)
-------------------------------------------------------------------------------------------------

local function settingsPath()
    if getUserProfileAppPath == nil then
        return nil
    end
    return getUserProfileAppPath() .. "modSettings/FS25_AutoDriveJobs.xml"
end

function H.loadPosition()
    H.positionLoaded = true
    pcall(function()
        local path = settingsPath()
        if path == nil or not fileExists(path) then
            return
        end
        local xml = loadXMLFile("adJobsHud", path)
        if xml == nil or xml == 0 then
            return
        end
        H.x = getXMLFloat(xml, "adJobsHud#x") or H.x
        H.top = getXMLFloat(xml, "adJobsHud#top") or H.top
        local tab = getXMLString(xml, "adJobsHud#tab")
        if tab == "jobs" or tab == "plan" or tab == "storages" then
            H.tab = tab
        end
        local i = 0
        while true do
            local key = string.format("adJobsHud.closedGroup(%d)", i)
            local name = getXMLString(xml, key .. "#name")
            if name == nil then
                break
            end
            H.groupOpen[name] = false
            i = i + 1
        end
        delete(xml)
    end)
end

function H.savePosition()
    pcall(function()
        local path = settingsPath()
        if path == nil then
            return
        end
        createFolder(getUserProfileAppPath() .. "modSettings")
        local xml = createXMLFile("adJobsHud", path, "adJobsHud")
        if xml == nil or xml == 0 then
            return
        end
        setXMLFloat(xml, "adJobsHud#x", H.x)
        setXMLFloat(xml, "adJobsHud#top", H.top)
        setXMLString(xml, "adJobsHud#tab", H.tab or "jobs")
        local i = 0
        for name, open in pairs(H.groupOpen) do
            if open == false then
                setXMLString(xml, string.format("adJobsHud.closedGroup(%d)#name", i), name)
                i = i + 1
            end
        end
        saveXMLFile(xml)
        delete(xml)
    end)
end

local function clampPosition(height)
    H.x = math.max(0, math.min(H.x, 1 - M.w))
    H.top = math.max(height or 0.1, math.min(H.top, 1))
end

-------------------------------------------------------------------------------------------------
-- list view
-------------------------------------------------------------------------------------------------

local function drawLevelBar(job, x, y, w, h)
    drawFilledRect(x, y, w, h, 0.22, 0.22, 0.22, 0.95)
    local p = job.percent or -1
    if p >= 0 then
        local r, g, b = 0.9, 0.75, 0.15
        if job.direction == "empty" then
            -- haul away: red = must be hauled, blue = empty enough
            if p >= (job.high or 100) then
                r, g, b = 0.85, 0.2, 0.15
            elseif p <= (job.low or 0) then
                r, g, b = C_HOVER[1], C_HOVER[2], C_HOVER[3]
            end
        elseif p < (job.low or 0) then
            r, g, b = 0.85, 0.2, 0.15
        elseif p >= (job.high or 100) or job.driveMode == "load" then
            r, g, b = C_HOVER[1], C_HOVER[2], C_HOVER[3]
        end
        drawFilledRect(x, y, w * p / 100, h, r, g, b, 0.95)
        local markW = M.px(1.5)
        drawFilledRect(x + w * (job.low or 0) / 100, y, markW, h, 1, 1, 1, 0.9)
        if job.driveMode ~= "load" then
            drawFilledRect(x + w * math.min(job.high or 100, 99.5) / 100, y, markW, h, 1, 1, 1, 0.9)
        end
        drawText(x + w / 2, textY(y, h, M.small), M.small, string.format("%d %%", math.floor(p + 0.5)), C_TEXT, true, RenderText.ALIGN_CENTER)
    else
        drawText(x + w / 2, textY(y, h, M.small), M.small, "?", C_TEXT, true, RenderText.ALIGN_CENTER)
    end
end

--- park position, vehicle and the trailer attached to it right now
local function jobVehicleLine(job)
    local veh = (job.vehicleName ~= nil and job.vehicleName ~= "") and job.vehicleName or txt("vehicleNone")
    local text = veh
    if (job.parkMarker or "") ~= "" then
        text = string.format("P %s: %s", job.parkMarker, veh)
    end
    local implement, hasImplement = nil, true
    local vehicle = ADJobs.getVehicleByUid(job.vehicleUid)
    if vehicle ~= nil and (job.vehicleName or "") ~= "" then
        implement, hasImplement = ADJobs.getImplementText(vehicle)
    end
    return text, implement, hasImplement
end

local function jobTargetLine(job)
    if job.driveMode == "sequence" then
        local parts = {}
        for i, s in ipairs(ADJobs.getSteps(job)) do
            local course = tostring(s.course or "?"):gsub("^@", ""):match("([^/]+)$") or "?"
            if (s.unload or "") ~= "" then
                course = course .. " -> " .. s.unload
            end
            if (s.marker or "") ~= "" then
                table.insert(parts, string.format("%d. %s: %s", i, s.marker, course))
            else
                table.insert(parts, string.format("%d. %s", i, course))
            end
        end
        return table.concat(parts, "  ->  ")
    end
    if job.driveMode == "load" then
        local back = (job.unloadMarker ~= nil and job.unloadMarker ~= "") and job.unloadMarker or txt("autoShort")
        return txt("line2Load", job.loadMarker or "?", back)
    end
    local extra = #ADJobs.getLoadMarkers(job) - 1
    local load = job.loadMarker or "?"
    if extra > 0 then
        load = string.format("%s (+%d)", load, extra)
    end
    return string.format("%s  ->  %s", load, job.unloadMarker or "?")
end

--- the group a job is shown in: its own group name, otherwise the watched object
function ADJobs.getJobGroup(job)
    if (job.group or "") ~= "" then
        return job.group
    end
    return tostring(job.placeableName or "?")
end

H.groupOpen = {}       -- [group name] = false when collapsed (saved with the HUD position)

--- list items: {group = name, jobs = {...}, h} headers for groups with 2+ jobs, {job, indent, h} rows
function H.buildListItems(jobs)
    -- order of the list = order of the priority (1 first), the same priority in the order of creation
    local sorted = {}
    for i, job in ipairs(jobs) do
        sorted[i] = {job = job, i = i}
    end
    table.sort(sorted, function(a, b)
        local pa, pb = ADJobs.getPrio(a.job), ADJobs.getPrio(b.job)
        if pa ~= pb then
            return pa < pb
        end
        return a.i < b.i
    end)
    jobs = {}
    for i, e in ipairs(sorted) do
        jobs[i] = e.job
    end
    local order, byGroup = {}, {}
    for _, job in ipairs(jobs) do
        local g = ADJobs.getJobGroup(job)
        if byGroup[g] == nil then
            byGroup[g] = {}
            table.insert(order, g)
        end
        table.insert(byGroup[g], job)
    end
    local items = {}
    for _, g in ipairs(order) do
        local list = byGroup[g]
        if #list >= 2 then
            local open = H.groupOpen[g] ~= false
            table.insert(items, {group = g, jobs = list, open = open, h = M.rowH})
            if open then
                for _, job in ipairs(list) do
                    table.insert(items, {job = job, indent = true, h = M.jobH})
                end
            end
        else
            table.insert(items, {job = list[1], h = M.jobH})
        end
    end
    return items
end

--- header line of a group: "+/- name (n)" and a summary (running / problems / most urgent level)
function H.drawGroupHeader(it, x, rowTop, w)
    local y = rowTop - it.h
    local hover = isInside(x, y, w, it.h)
    drawFilledRect(x, y, w, it.h, C_SPECIAL[1], C_SPECIAL[2], C_SPECIAL[3], hover and 0.22 or 0.12)
    addBox(x, y, w, it.h, function()
        if it.open then
            H.groupOpen[it.group] = false
        else
            H.groupOpen[it.group] = nil
        end
        H.savePosition()
    end, function(dir)
        H.listScroll = H.listScroll - dir
    end)
    local running, problems, active = 0, 0, 0
    for _, job in ipairs(it.jobs) do
        local s = job.state or 0
        if s == ADJobs.ST_RUN or s == ADJobs.ST_STOPPING or s == ADJobs.ST_DUMP or s == ADJobs.ST_SWAP or s == ADJobs.ST_TOPARK or s == ADJobs.ST_STANDING or s == ADJobs.ST_SEQ then
            running = running + 1
        elseif s == ADJobs.ST_ERROR or s == ADJobs.ST_NOTREADY then
            problems = problems + 1
        end
        if job.active then
            active = active + 1
        end
    end
    local ty = textY(y, it.h, M.font)
    local label = string.format("%s  %s  (%d)", it.open and "-" or "+", it.group, #it.jobs)
    -- summary right
    local parts = {}
    table.insert(parts, txt("grpActive", active, #it.jobs))
    if running > 0 then
        table.insert(parts, txt("grpRunning", running))
    end
    if problems > 0 then
        table.insert(parts, txt("grpProblems", problems))
    end
    local summary = table.concat(parts, "  ·  ")
    local sumW = math.min(getTextWidth(M.small, summary), w * 0.45)
    local sumColor = problems > 0 and {1, 0.8, 0.3, 1} or (running > 0 and {0.4, 0.9, 1, 1} or C_GREY)
    drawText(x + w - 2 * M.gapX, textY(y, it.h, M.small), M.small, fit(summary, sumW, M.small), sumColor, false, RenderText.ALIGN_RIGHT)
    drawText(x + 2 * M.gapX, ty, M.font, fit(label, w - sumW - 6 * M.gapX, M.font), hover and C_HOVER or C_TEXT, true)
end

--- the texts of a job row (name of the value, limits, vehicle, targets, status): not built every frame
local rowTextCache = {}
local ROW_TEXT_TIME = 500
local function rowTexts(job)
    local c = rowTextCache[job.id]
    if c ~= nil and c.job == job and g_time - c.time < ROW_TEXT_TIME then
        return c
    end
    c = {job = job, time = g_time}
    c.what = string.format("%s: %s", tostring(job.placeableName or "?"), ADJobs.getMeasureLabel(job))
    if job.driveMode == "sequence" then
        c.what = txt("modeSeqShort")
    end
    if job.driveMode == "sequence" then
        c.limits = string.format("%s   %s", txt("seqLimits", #ADJobs.getSteps(job)), txt("seqRuns", job.tripsTotal or 0))
    elseif job.driveMode == "load" then
        c.limits = string.format("%s   %s %d (%s)", txt("limitLoad", math.floor(job.low or 0)), txt("colTrips"), job.tripsDone or 0, txt("tripsTotal", job.tripsTotal or 0))
    else
        local trips = (job.maxTrips or 0) > 0 and string.format("%d/%d", job.tripsDone or 0, job.maxTrips) or string.format("%d", job.tripsDone or 0)
        trips = trips .. string.format(" (%s)", txt("tripsTotal", job.tripsTotal or 0))
        if job.direction == "empty" then
            c.limits = string.format("%s / <%d %%   %s %s", txt("limitEmpty", math.floor(job.high or 0)), math.floor(job.low or 0), txt("colTrips"), trips)
        else
            c.limits = string.format("%d / %d %%   %s %s", math.floor(job.low or 0), math.floor(job.high or 0), txt("colTrips"), trips)
        end
    end
    c.limits = txt("prioShort", ADJobs.getPrio(job)) .. "   " .. c.limits
    c.veh, c.impl, c.hasImpl = jobVehicleLine(job)
    c.target = jobTargetLine(job)
    c.status = ADJobs.getStatusText(job)
    rowTextCache[job.id] = c
    return c
end

function H.drawList()
    local jobs = ADJobs.jobs
    -- hover hint of the previous frame is shown in the header (like the AutoDrive tool tips)
    local tooltip = H.nextTooltip
    H.nextTooltip = nil
    H.tooltip = tooltip
    local count = #jobs
    -- display items: group headers (groups with 2+ jobs, collapsible) and job rows
    local items = H.buildListItems(jobs)
    local maxBodyH = MAX_JOB_ROWS * M.jobH
    local nItems = #items
    -- the last scroll position at which the rest still fills the list
    local maxScroll, acc = 0, 0
    for i = nItems, 1, -1 do
        acc = acc + items[i].h
        if acc > maxBodyH then
            maxScroll = i
            break
        end
    end
    H.listScroll = math.max(0, math.min(H.listScroll, maxScroll))
    local visible, bodyH = {}, 0
    for i = H.listScroll + 1, nItems do
        local it = items[i]
        if bodyH + it.h > maxBodyH + 0.0001 then
            break
        end
        bodyH = bodyH + it.h
        table.insert(visible, it)
    end
    if count == 0 then
        bodyH = M.rowH * 1.4
    end
    local totalH = M.headerH + M.tabH + bodyH + 3 * M.gapY
    clampPosition(totalH)
    local x, top, w = H.x, H.top, M.w
    local bottom = top - totalH
    H.area = {x = x, y = bottom, w = w, h = totalH}

    drawBackground(x, bottom, w, totalH)
    -- wheel over the whole list scrolls it
    addBox(x, bottom, w, totalH, nil, function(dir)
        H.listScroll = H.listScroll - dir
    end)

    local title = txt("title")
    if H.tooltip ~= nil then
        title = H.tooltip
    elseif ADJobs.AD ~= nil and not ADJobs.hooksInstalled then
        -- fallback mode (AutoDrive internals changed): the player should know the jobs behave differently
        title = txt("hookOff")
    end
    if maxScroll > 0 then
        title = string.format("%s  (%d / %d)", title, H.listScroll + 1, maxScroll + 1)
    end
    drawHeader(x, top, w, title, {
        {"input_toggleHud_1", "X", function()
            ADJobs.toggleHud()
        end},
        {"plusSign", "+", function()
            H.newJob()
        end},
        {nil, nil, function()
            H.showStorages = not H.showStorages
        end, text = "L#", on = H.showStorages, tip = txt("tipStorageNums")},
    })
    H.drawTabs(x, top - M.headerH - M.gapY, w)

    if count == 0 then
        drawText(x + 2 * M.gapX, textY(bottom + M.gapY, bodyH, M.font), M.font, fit(txt("noJobs"), w - 4 * M.gapX, M.font), C_GREY)
        return
    end

    local barW, barH = M.px(78), M.py(15)
    local rowTop = top - M.headerH - 2 * M.gapY - M.tabH
    for i, it in ipairs(visible) do
      if it.group ~= nil then
        H.drawGroupHeader(it, x, rowTop, w)
        rowTop = rowTop - it.h
      else
        local job = it.job
        local rowY = rowTop - M.jobH
        local indent = it.indent and M.px(10) or 0
        if i % 2 == 0 then
            drawFilledRect(x, rowY, w, M.jobH, 1, 1, 1, 0.04)
        end
        if indent > 0 then
            drawFilledRect(x + M.px(3), rowY + M.gapY, M.px(2), M.jobH - 2 * M.gapY, C_SPECIAL[1], C_SPECIAL[2], C_SPECIAL[3], 0.6)
        end
        local rowHover = isInside(x, rowY, w, M.jobH)
        if rowHover then
            drawFilledRect(x, rowY, w, M.jobH, 1, 1, 1, 0.06)
        end
        -- click on the row = edit
        addBox(x, rowY, w, M.jobH, function()
            H.editJob(job)
        end, function(dir)
            H.listScroll = H.listScroll - dir
        end)

        -- on / off switch: icon with "AN" / "AUS" below, the whole column is clickable
        local iy = rowTop - M.gapY - M.iconH
        local swX, swY, swW, swH = x + M.gapX + indent, rowY + M.gapY, M.iconW, M.jobH - 2 * M.gapY
        local swHover = isInside(swX, swY, swW, swH)
        if swHover then
            drawFilledRect(swX, swY, swW, swH, 1, 1, 1, 0.12)
        end
        if not drawSlice(job.active and "input_start_stop_2" or "input_start_stop_1", swX, iy, M.iconW, M.iconH) then
            drawFilledRect(swX, iy, M.iconW, M.iconH, 0.32, 0.32, 0.32, 0.95)
        end
        local swColor = job.active and C_HOVER or {0.6, 0.6, 0.6, 1}
        if swHover then
            swColor = C_TEXT
        end
        drawText(swX + swW / 2, rowTop - M.py(42), M.small, job.active and txt("on"):upper() or txt("off"):upper(), swColor, true, RenderText.ALIGN_CENTER)
        addBox(swX, swY, swW, swH, function()
            ADJChangeEvent.sendEvent(ADJChangeEvent.OP_TOGGLE, {id = job.id})
        end, function(dir)
            H.listScroll = H.listScroll - dir
        end)
        if swHover then
            H.nextTooltip = job.active and txt("tipDeactivate") or txt("tipActivate")
        end

        -- delete, edit (right)
        local bx = x + w - M.gapX - M.smallW
        local by = rowTop - M.gapY - M.smallH
        iconButton("minusSign", bx, by, M.smallW, M.smallH, "-", function()
            YesNoDialog.show(function(_, yes)
                if yes then
                    ADJChangeEvent.sendEvent(ADJChangeEvent.OP_DELETE, {id = job.id})
                end
            end, H, txt("confirmDelete", job.name or ""))
        end)
        bx = bx - M.gapX - M.smallW
        iconButton("input_editMapMarker_1", bx, by, M.smallW, M.smallH, "E", function()
            H.editJob(job)
        end)
        -- send the vehicle of the job to its park position and end the job
        bx = bx - M.gapX - M.smallW
        if isInside(bx, by, M.smallW, M.smallH) then
            H.nextTooltip = txt("tipPark")
        end
        iconButton("input_parkVehicle_1", bx, by, M.smallW, M.smallH, "P", function()
            ADJChangeEvent.sendEvent(ADJChangeEvent.OP_PARK, {id = job.id})
        end)
        local barX = bx - 2 * M.gapX - barW
        drawLevelBar(job, barX, rowTop - M.gapY - M.py(1) - barH, barW, barH)

        -- texts
        local tx = x + 3 * M.gapX + M.iconW + indent
        local c = job.active and C_TEXT or C_GREY
        local y1 = rowTop - M.py(15)
        local maxW1 = barX - tx - 2 * M.gapX
        local name = fit(job.name, maxW1 * 0.55, M.font)
        drawText(tx, y1, M.font, name, rowHover and C_HOVER or c, true)
        local nameW = getTextWidth(M.font, name) + 3 * M.gapX
        local rt = rowTexts(job)
        drawText(tx + nameW, y1, M.small, fit(rt.what, maxW1 - nameW, M.small), C_GREY)

        local limits = rt.limits
        local y2 = rowTop - M.py(31)
        local vehText, implText, hasImpl = rt.veh, rt.impl, rt.hasImpl
        local maxW2 = x + w - tx - 2 * M.gapX
        vehText = fit(vehText, implText ~= nil and maxW2 * 0.6 or maxW2, M.small)
        drawText(tx, y2, M.small, vehText, c)
        if implText ~= nil then
            local ix = tx + getTextWidth(M.small, vehText) + 2 * M.gapX
            drawText(ix, y2, M.small, fit(implText, tx + maxW2 - ix, M.small), hasImpl and C_SPECIAL or {1, 0.8, 0.3, 1})
        end

        local y3 = rowTop - M.py(46)
        drawText(tx, y3, M.small, fit(rt.target, x + w - tx - 2 * M.gapX, M.small), c)

        -- status left, limits and trips right
        local y4 = rowTop - M.py(61)
        local limitsW = math.min(getTextWidth(M.small, limits), (x + w - tx) * 0.55)
        drawText(x + w - 2 * M.gapX, y4, M.small, fit(limits, limitsW, M.small), C_GREY, false, RenderText.ALIGN_RIGHT)
        drawText(tx, y4, M.small, fit(rt.status, x + w - tx - limitsW - 5 * M.gapX, M.small), statusColor(job), true)
        rowTop = rowTop - M.jobH
      end
    end

    -- scroll bar
    if maxScroll > 0 then
        local trackY, trackH = bottom + M.gapY, bodyH
        local thumbH = trackH * #visible / nItems
        local thumbY = trackY + trackH - thumbH - (trackH - thumbH) * H.listScroll / maxScroll
        drawFilledRect(x + w - M.px(3), thumbY, M.px(2), thumbH, C_HOVER[1], C_HOVER[2], C_HOVER[3], 0.9)
    end
end

-------------------------------------------------------------------------------------------------
-- tabs and "Geplant" view: per vehicle the job it drives right now and the jobs that are due, in the
-- order they get the vehicle; the due jobs can be dragged into another order (right click: next)
-------------------------------------------------------------------------------------------------

local C_RUN = {0.4, 0.9, 1, 1}

--- number of due jobs that wait for their vehicle
local function planCount()
    local n = 0
    for _, job in ipairs(ADJobs.jobs) do
        if (job.planPos or 0) > 0 and not job.planCur then
            n = n + 1
        end
    end
    return n
end

--- tab bar below the header; top = upper edge
function H.drawTabs(x, top, w)
    local h = M.tabH
    local y = top - h
    local nSources = 0
    for _, _ in pairs(ADJobs.markerSources or {}) do
        nSources = nSources + 1
    end
    local tabs = {{"jobs", txt("tabJobs", #ADJobs.jobs)}, {"plan", txt("tabPlan", planCount())}, {"storages", txt("tabStorages", nSources)}}
    local tx = x + M.gapX
    for _, t in ipairs(tabs) do
        local key, label = t[1], t[2]
        local tw = math.max(M.px(130), getTextWidth(M.font, label) + 6 * M.gapX)
        local sel = H.tab == key
        local hover = not sel and isInside(tx, y, tw, h)
        if sel then
            drawFilledRect(tx, y, tw, h, 0.3, 0.45, 0.05, 0.95)
        else
            drawFilledRect(tx, y, tw, h, 0.2, 0.2, 0.2, 0.9)
            if hover then
                drawFilledRect(tx, y, tw, h, 1, 1, 1, 0.1)
            end
        end
        drawText(tx + tw / 2, textY(y, h, M.font), M.font, label, sel and C_TEXT or (hover and C_HOVER or C_GREY), true, RenderText.ALIGN_CENTER)
        addBox(tx, y, tw, h, function()
            if H.tab ~= key then
                H.tab = key
                H.dnd = nil
                H.open = nil
                H.savePosition()
            end
        end)
        tx = tx + tw + M.gapX
    end
    drawFilledRect(x + M.gapX, y, w - 2 * M.gapX, M.py(1.5), 0.3, 0.45, 0.05, 0.95)
end

--- display items of the plan: {veh = group} header per vehicle, {job, veh, num} rows
function H.buildPlanItems()
    local groups, order = {}, {}
    for _, job in ipairs(ADJobs.jobs) do
        if (job.planPos or 0) > 0 then
            local key = job.planVeh or ""
            local g = groups[key]
            if g == nil then
                local name = (job.planVehName or "") ~= "" and job.planVehName or txt("planNoVehicle")
                g = {key = key, name = name, jobs = {}, queued = {}, manual = false, running = 0}
                groups[key] = g
                table.insert(order, g)
            end
            table.insert(g.jobs, job)
        end
    end
    for _, g in ipairs(order) do
        table.sort(g.jobs, function(a, b)
            return (a.planPos or 0) < (b.planPos or 0)
        end)
        for _, job in ipairs(g.jobs) do
            if job.planCur then
                g.running = g.running + 1
            else
                table.insert(g.queued, job.id)
                if (job.planOrder or 0) > 0 then
                    g.manual = true
                end
            end
        end
    end
    -- vehicles by name, "without vehicle" last
    table.sort(order, function(a, b)
        if (a.key == "") ~= (b.key == "") then
            return b.key == ""
        end
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.key < b.key
    end)
    local items = {}
    for _, g in ipairs(order) do
        table.insert(items, {veh = g, h = M.rowH})
        local n = 0
        for _, job in ipairs(g.jobs) do
            local num = nil
            if not job.planCur then
                n = n + 1
                num = n
            end
            table.insert(items, {job = job, veh = g, num = num, h = M.planH})
        end
    end
    return items
end

--- sends the new order of the due jobs of one vehicle to the server
local function sendPlanOrder(g, ids, reset)
    if g_server == nil and not reset then
        -- client: show the new order right away (the server confirms it with the next status update)
        local pos = 0
        for _, job in ipairs(g.jobs) do
            if job.planCur then
                pos = pos + 1
                job.planPos = pos
            end
        end
        for n, id in ipairs(ids) do
            local job = ADJobs.getJobById(id)
            if job ~= nil then
                pos = pos + 1
                job.planPos = pos
                job.planOrder = n
            end
        end
    end
    ADJChangeEvent.sendEvent(ADJChangeEvent.OP_REORDER, {id = 0, planIds = (reset and "R" or "") .. table.concat(ids, ",")})
end

--- moves job id in the queue of vehicle group g before / after anchorId (nil: to the top)
local function moveInPlan(g, id, anchorId, after)
    local ids = {}
    for _, q in ipairs(g.queued) do
        if q ~= id then
            table.insert(ids, q)
        end
    end
    local pos = 1
    if anchorId ~= nil then
        for i, q in ipairs(ids) do
            if q == anchorId then
                pos = after and i + 1 or i
                break
            end
        end
    end
    table.insert(ids, pos, id)
    local same = #ids == #g.queued
    for i = 1, #ids do
        if ids[i] ~= g.queued[i] then
            same = false
        end
    end
    if not same then
        sendPlanOrder(g, ids, false)
    end
end

--- where a dragged job would go: after the last visible row of its vehicle whose middle is above the
--- mouse, otherwise before the first one; returns {anchor, after, lineY} or nil
local function planDropTarget(d, my)
    local slots = H.planSlots ~= nil and H.planSlots[d.veh] or nil
    if slots == nil then
        return nil
    end
    local others = {}
    for _, s in ipairs(slots) do
        if s.id ~= d.id then
            table.insert(others, s)
        end
    end
    if #others == 0 then
        return nil
    end
    local last = nil
    for _, s in ipairs(others) do
        if my < s.y + s.h / 2 then
            last = s
        end
    end
    if last == nil then
        return {anchor = others[1].id, after = false, lineY = others[1].y + others[1].h}
    end
    return {anchor = last.id, after = true, lineY = last.y}
end

function H.dropPlan(d, my)
    local g = H.planGroups ~= nil and H.planGroups[d.veh] or nil
    local t = planDropTarget(d, my)
    if g ~= nil and t ~= nil then
        moveInPlan(g, d.id, t.anchor, t.after)
    end
end

--- three short lines: "can be dragged"
local function drawGrip(x, y, h, hover)
    local gw, gh = M.px(9), M.py(1.5)
    local cy = y + h / 2
    local a = hover and 1 or 0.55
    for k = -1, 1 do
        drawFilledRect(x, cy + k * M.py(4) - gh / 2, gw, gh, 1, 1, 1, a)
    end
end

function H.drawPlan()
    local tooltip = H.nextTooltip
    H.nextTooltip = nil
    H.tooltip = tooltip
    local items = H.buildPlanItems()
    local maxBodyH = MAX_JOB_ROWS * M.jobH
    local nItems = #items
    local maxScroll, acc = 0, 0
    for i = nItems, 1, -1 do
        acc = acc + items[i].h
        if acc > maxBodyH then
            maxScroll = i
            break
        end
    end
    H.planScroll = math.max(0, math.min(H.planScroll, maxScroll))
    local visible, bodyH = {}, 0
    for i = H.planScroll + 1, nItems do
        local it = items[i]
        if bodyH + it.h > maxBodyH + 0.0001 then
            break
        end
        bodyH = bodyH + it.h
        table.insert(visible, it)
    end
    if nItems == 0 then
        bodyH = M.rowH * 1.4
    end
    local totalH = M.headerH + M.tabH + bodyH + 3 * M.gapY
    clampPosition(totalH)
    local x, top, w = H.x, H.top, M.w
    local bottom = top - totalH
    H.area = {x = x, y = bottom, w = w, h = totalH}

    local function wheel(dir)
        H.planScroll = H.planScroll - dir
    end
    drawBackground(x, bottom, w, totalH)
    addBox(x, bottom, w, totalH, nil, wheel)

    local title = txt("title")
    if H.tooltip ~= nil then
        title = H.tooltip
    elseif ADJobs.AD ~= nil and not ADJobs.hooksInstalled then
        title = txt("hookOff")
    end
    if maxScroll > 0 then
        title = string.format("%s  (%d / %d)", title, H.planScroll + 1, maxScroll + 1)
    end
    drawHeader(x, top, w, title, {
        {"input_toggleHud_1", "X", function()
            ADJobs.toggleHud()
        end},
        {"plusSign", "+", function()
            H.newJob()
        end},
        {nil, nil, function()
            H.showStorages = not H.showStorages
        end, text = "L#", on = H.showStorages, tip = txt("tipStorageNums")},
    })
    H.drawTabs(x, top - M.headerH - M.gapY, w)

    H.planSlots, H.planGroups = {}, {}
    if nItems == 0 then
        H.dnd = nil
        drawText(x + 2 * M.gapX, textY(bottom + M.gapY, bodyH, M.font), M.font, fit(txt("planEmpty"), w - 4 * M.gapX, M.font), C_GREY)
        return
    end

    local d = (H.dnd ~= nil and H.dnd.active) and H.dnd or nil
    local barW, barH = M.px(78), M.py(15)
    local colW = M.px(34)
    local rowTop = top - M.headerH - 2 * M.gapY - M.tabH
    local odd = false
    for _, it in ipairs(visible) do
        local g = it.veh
        H.planGroups[g.key] = g
        if it.job == nil then
            -- vehicle: name, number of due jobs; "Auto" puts the order back to automatic
            local y = rowTop - it.h
            drawFilledRect(x, y, w, it.h, C_SPECIAL[1], C_SPECIAL[2], C_SPECIAL[3], 0.12)
            addBox(x, y, w, it.h, nil, wheel)
            local rx = x + w - 2 * M.gapX
            if g.manual then
                local bw, bh = M.px(46), it.h - 2 * M.gapY
                local bx = rx - bw
                textButton(bx, y + M.gapY, bw, bh, txt("planAuto"), function()
                    sendPlanOrder(g, g.queued, true)
                end)
                if isInside(bx, y + M.gapY, bw, bh) then
                    H.nextTooltip = txt("tipPlanAuto")
                end
                rx = bx - 2 * M.gapX
            end
            local parts = {}
            if g.manual then
                table.insert(parts, txt("planManual"))
            end
            table.insert(parts, txt("planCount", #g.queued))
            local summary = table.concat(parts, "  ·  ")
            local sumW = math.min(getTextWidth(M.small, summary), w * 0.45)
            drawText(rx, textY(y, it.h, M.small), M.small, fit(summary, sumW, M.small), g.manual and C_SPECIAL or C_GREY, false, RenderText.ALIGN_RIGHT)
            drawText(x + 2 * M.gapX, textY(y, it.h, M.font), M.font, fit(g.name, rx - sumW - x - 5 * M.gapX, M.font), C_TEXT, true)
            rowTop = y
            odd = false
        else
            local job = it.job
            local rowY = rowTop - it.h
            local dragged = d ~= nil and d.id == job.id
            odd = not odd
            if job.planCur then
                drawFilledRect(x, rowY, w, it.h, C_RUN[1], C_RUN[2], C_RUN[3], 0.1)
            elseif not odd then
                drawFilledRect(x, rowY, w, it.h, 1, 1, 1, 0.04)
            end
            local rowHover = d == nil and isInside(x, rowY, w, it.h)
            if rowHover then
                drawFilledRect(x, rowY, w, it.h, 1, 1, 1, 0.06)
                H.nextTooltip = job.planCur and txt("tipPlanRunning") or txt("tipPlanDrag")
            end
            local box = addBox(x, rowY, w, it.h, function()
                H.editJob(job)
            end, wheel, (not job.planCur) and function()
                moveInPlan(g, job.id, nil)
            end or nil)
            if not job.planCur then
                box.dnd = {id = job.id, veh = g.key, name = job.name}
                H.planSlots[g.key] = H.planSlots[g.key] or {}
                table.insert(H.planSlots[g.key], {id = job.id, y = rowY, h = it.h})
            end

            -- left column: "now" for the running job, grip + position for the due ones
            if job.planCur then
                drawText(x + M.gapX + colW / 2, textY(rowY, it.h, M.small), M.small, txt("planNow"), C_RUN, true, RenderText.ALIGN_CENTER)
            else
                drawGrip(x + 2 * M.gapX, rowY, it.h, rowHover)
                drawText(x + M.gapX + M.px(24), textY(rowY, it.h, M.font), M.font, tostring(it.num or ""), rowHover and C_HOVER or C_TEXT, true, RenderText.ALIGN_CENTER)
            end

            local barX = x + w - 2 * M.gapX - barW
            drawLevelBar(job, barX, rowTop - M.gapY - M.py(1) - barH, barW, barH)

            local tx = x + M.gapX + colW + M.gapX
            local rt = rowTexts(job)
            local y1 = rowTop - M.py(15)
            local maxW1 = barX - tx - 2 * M.gapX
            local name = fit(job.name, maxW1 * 0.55, M.font)
            drawText(tx, y1, M.font, name, rowHover and C_HOVER or C_TEXT, true)
            local nameW = getTextWidth(M.font, name) + 3 * M.gapX
            local what = rt.what
            if it.num == 1 then
                what = txt("planNext") .. "  ·  " .. what
            end
            drawText(tx + nameW, y1, M.small, fit(what, maxW1 - nameW, M.small), it.num == 1 and C_SPECIAL or C_GREY)

            local y2 = rowTop - M.py(32)
            local limits = rt.limits
            local limitsW = math.min(getTextWidth(M.small, limits), (x + w - tx) * 0.5)
            drawText(x + w - 2 * M.gapX, y2, M.small, fit(limits, limitsW, M.small), C_GREY, false, RenderText.ALIGN_RIGHT)
            drawText(tx, y2, M.small, fit(rt.status, x + w - tx - limitsW - 5 * M.gapX, M.small), statusColor(job), true)

            if dragged then
                drawFilledRect(x, rowY, w, it.h, 0, 0, 0, 0.5)
            end
            rowTop = rowY
        end
    end

    -- dragging: line where the job goes and its name at the mouse
    if d ~= nil then
        local t = planDropTarget(d, H.mouseY)
        if t ~= nil then
            drawFilledRect(x + M.gapX, t.lineY - M.py(1.5), w - 2 * M.gapX, M.py(3), C_HOVER[1], C_HOVER[2], C_HOVER[3], 1)
        end
        local gw, gh = M.px(220), M.py(20)
        local gx = math.min(H.mouseX + M.px(12), 1 - gw)
        local gy = H.mouseY - gh / 2
        drawFilledRect(gx, gy, gw, gh, 0.3, 0.45, 0.05, 0.95)
        drawText(gx + 2 * M.gapX, textY(gy, gh, M.font), M.font, fit(d.name or "", gw - 4 * M.gapX, M.font), C_TEXT, true)
        H.nextTooltip = txt("tipPlanDrop")
    end

    if maxScroll > 0 then
        local trackY, trackH = bottom + M.gapY, bodyH
        local thumbH = trackH * #visible / nItems
        local thumbY = trackY + trackH - thumbH - (trackH - thumbH) * H.planScroll / maxScroll
        drawFilledRect(x + w - M.px(3), thumbY, M.px(2), thumbH, C_HOVER[1], C_HOVER[2], C_HOVER[3], 0.9)
    end
end

-------------------------------------------------------------------------------------------------
-- editor: entries of the pull down lists
-------------------------------------------------------------------------------------------------

local function markerGroupName(marker)
    local g = marker.group
    if g == nil or g == "" or g == "All" then
        return txt("grpDefault")
    end
    return g
end

--- all AD targets: {name, x, z, group}
local function getMarkers()
    local list = {}
    if not ADJobs.resolveAutoDrive() then
        return list
    end
    for _, marker in pairs(ADJobs.GM:getMapMarkers()) do
        if marker.name ~= nil and marker.isADDebug ~= true then
            local wp = ADJobs.GM:getWayPointById(marker.id)
            if wp ~= nil then
                table.insert(list, {name = marker.name, x = wp.x, z = wp.z, group = markerGroupName(marker)})
            end
        end
    end
    return list
end

--- sorts entries: groups in the order of groupOrder (rest alphabetical), then by sortKey
local function sortEntries(entries, groupOrder)
    local rank = {}
    for i, g in ipairs(groupOrder or {}) do
        rank[g] = i
    end
    table.sort(entries, function(a, b)
        local ga, gb = a.group or "", b.group or ""
        if ga ~= gb then
            local ra, rb = rank[ga] or 1000, rank[gb] or 1000
            if ra ~= rb then
                return ra < rb
            end
            return ga:lower() < gb:lower()
        end
        local ka, kb = a.sort or 0, b.sort or 0
        if ka ~= kb then
            if type(ka) == "string" then
                return ka < kb
            end
            return ka < kb
        end
        return tostring(a.label):lower() < tostring(b.label):lower()
    end)
    return entries
end

local function objectEntries(d)
    local farmId = getFarmId()
    local cx, cz = cameraPosition()
    local current = getCurrentVehicle()
    local entries = {}
    for _, placeable in ipairs(g_currentMission.placeableSystem.placeables) do
        if placeable:getOwnerFarmId() == farmId then
            local ok, options = pcall(ADJobs.getMeasureOptions, placeable)
            if ok and #options > 0 then
                local x, _, z = getWorldTranslation(placeable.rootNode)
                local dist = MathUtil.vector2Length(x - cx, z - cz)
                table.insert(entries, {label = ADJobs.getPlaceableLabel(placeable), sub = string.format("%d m", math.floor(dist)), sort = dist,
                    group = txt("grpBuildings"), value = placeable, selected = placeable == d.placeableObject})
            end
        end
    end
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        -- every trailer / tanker on its own (attached or not), with its own load
        if vehicle:getOwnerFarmId() == farmId and not vehicle.isDeleted and ADJobs.isTransportVehicle(vehicle) then
            local ok, options = pcall(ADJobs.getMeasureOptions, vehicle)
            if ok and #options > 0 then
                local x, _, z = getWorldTranslation(vehicle.rootNode)
                local dist = MathUtil.vector2Length(x - cx, z - cz)
                local where = string.format("%d m", math.floor(dist))
                local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
                if root ~= vehicle then
                    local rootName = root.getFullName ~= nil and root:getFullName() or "?"
                    where = txt("attachedTo", rootName) .. "  " .. where
                end
                if vehicle == current or (root == current and current ~= nil) then
                    dist = -1
                end
                local okCargo, cargo = pcall(ADJobs.getCargoText, vehicle)
                local sub = okCargo and string.format("%s   %s", cargo, where) or where
                table.insert(entries, {label = ADJobs.getVehicleName(vehicle), sub = sub, sort = dist,
                    group = txt("grpVehicles"), value = vehicle, selected = vehicle == d.placeableObject})
            end
        end
    end
    return sortEntries(entries, {txt("grpBuildings"), txt("grpVehicles")})
end

local function measureEntries(d)
    local entries = {}
    if d.placeableObject == nil then
        return entries
    end
    local ok, options = pcall(ADJobs.getMeasureOptions, d.placeableObject)
    if not ok then
        return entries
    end
    for i, o in ipairs(options) do
        local label, sub = o.label:match("^(.-)%s+(%(.*%))$")
        table.insert(entries, {label = label or o.label, sub = sub, sort = i, value = o,
            selected = o.kind == d.sourceKind and o.fillTypeName == d.fillTypeName})
    end
    return entries
end

local function modeEntries(d)
    return {
        {label = txt("modeDeliverShort"), value = "deliver", sort = 1, selected = d.driveMode ~= "load" and d.driveMode ~= "sequence"},
        {label = txt("modeLoadShort"), value = "load", sort = 2, selected = d.driveMode == "load"},
        {label = txt("modeSeqShort"), value = "sequence", sort = 3, selected = d.driveMode == "sequence"},
    }
end

local function modeTitle(mode)
    if mode == "load" then
        return txt("modeLoadShort")
    elseif mode == "sequence" then
        return txt("modeSeqShort")
    end
    return txt("modeDeliverShort")
end

local function directionEntries(d)
    return {
        {label = txt("dirFill"), value = "fill", sort = 1, selected = d.direction ~= "empty"},
        {label = txt("dirEmpty"), value = "empty", sort = 2, selected = d.direction == "empty"},
    }
end

--- trailers / tankers of the farm the job can be bound to (the vehicle swaps to this one before a run)
local function swapTrailerEntries(d)
    local entries = {{label = txt("swapNone"), value = "", sort = -2, group = txt("grpAuto"), selected = (d.swapTrailerUid or "") == ""}}
    local farmId = d.farmId or getFarmId()
    local cx, cz = cameraPosition()
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle:getOwnerFarmId() == farmId and not vehicle.isDeleted and vehicle.spec_attachable ~= nil
            and vehicle.getUniqueId ~= nil and ADJobs.hasOwnCargo(vehicle) then
            local uid = vehicle:getUniqueId()
            local x, _, z = getWorldTranslation(vehicle.rootNode)
            local dist = MathUtil.vector2Length(x - cx, z - cz)
            local where = string.format("%d m", math.floor(dist))
            local root = vehicle.getRootVehicle ~= nil and vehicle:getRootVehicle() or vehicle
            if root ~= vehicle then
                local rootName = root.getFullName ~= nil and root:getFullName() or "?"
                where = txt("attachedTo", rootName) .. "  " .. where
            end
            local okCargo, cargo = pcall(ADJobs.getCargoText, vehicle)
            local sub = okCargo and string.format("%s   %s", cargo, where) or where
            table.insert(entries, {label = ADJobs.getVehicleName(vehicle), sub = sub, sort = dist, group = txt("grpVehicles"),
                value = uid, selected = uid == d.swapTrailerUid})
        end
    end
    return sortEntries(entries, {txt("grpAuto"), txt("grpVehicles")})
end

--- AD targets usable as the stand of the job trailer (not the park position: the other trailer stands there)
local function swapMarkerEntries(d)
    local auto = ADJobs.getSwapMarker({swapTrailerUid = d.swapTrailerUid, swapMarker = ""})
    local autoLabel = auto ~= "" and txt("swapAuto", auto) or txt("swapAutoNone")
    local entries = {{label = autoLabel, value = "", sort = 0, group = txt("grpAuto"), selected = (d.swapMarker or "") == ""}}
    for _, m in ipairs(getMarkers()) do
        if m.name ~= d.parkMarker then
            table.insert(entries, {label = m.name, value = m.name, sort = m.name:lower(), group = m.group, selected = m.name == d.swapMarker})
        end
    end
    return sortEntries(entries, {txt("grpAuto"), txt("grpDefault")})
end

local function swapTrailerName(d)
    local v = ADJobs.getVehicleByUid(d.swapTrailerUid)
    if v ~= nil then
        return ADJobs.getVehicleName(v)
    end
    if (d.swapTrailerName or "") ~= "" then
        return d.swapTrailerName .. " (?)"
    end
    return txt("msg23")
end

--- park positions that are assigned to own AD vehicles (or to tools attached to them)
local function parkEntries(d)
    local entries = {}
    if not ADJobs.resolveAutoDrive() then
        return entries
    end
    local farmId = d.farmId or getFarmId()
    local byIdx = {}
    for _, vehicle in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if vehicle.ad ~= nil and vehicle.ad.stateModule ~= nil and vehicle:getOwnerFarmId() == farmId
            and (vehicle.getRootVehicle == nil or vehicle:getRootVehicle() == vehicle) then
            for idx, _ in pairs(ADJobs.getParkIndices(vehicle)) do
                byIdx[idx] = byIdx[idx] or {}
                table.insert(byIdx[idx], vehicle)
            end
        end
    end
    for idx, vehicles in pairs(byIdx) do
        local marker = ADJobs.GM:getMapMarkerById(idx)
        if marker ~= nil and marker.name ~= nil then
            local wp = ADJobs.GM:getWayPointById(marker.id)
            local names, atPark = {}, false
            for i, v in ipairs(vehicles) do
                if i <= 2 then
                    table.insert(names, ADJobs.getVehicleName(v) .. " " .. ADJobs.getImplementText(v))
                end
                if wp ~= nil and ADJobs.isCombinationNearMarker(v, idx) then
                    atPark = true
                end
            end
            local sub = table.concat(names, ", ")
            if #vehicles > 2 then
                sub = sub .. string.format(" +%d", #vehicles - 2)
            end
            if atPark then
                sub = sub .. "  (" .. txt("atPark") .. ")"
            end
            table.insert(entries, {label = marker.name, sub = sub, sort = marker.name:lower(), group = markerGroupName(marker),
                value = marker.name, selected = marker.name == d.parkMarker})
        end
    end
    return sortEntries(entries, {txt("grpDefault")})
end

local function fillTypeEntries(d)
    local entries = {{label = txt("keepFtShort"), value = "", sort = 0, selected = (d.loadFillTypeName or "") == ""}}
    local fts = {}
    if d.candidates ~= nil then
        for _, ft in ipairs(d.candidates) do
            table.insert(fts, ft)
        end
    else
        local ft = g_fillTypeManager:getFillTypeIndexByName(d.fillTypeName or "")
        if ft ~= nil then
            table.insert(fts, ft)
        end
    end
    for i, ft in ipairs(fts) do
        local name = g_fillTypeManager:getFillTypeNameByIndex(ft)
        table.insert(entries, {label = fillTypeTitle(name), value = name, sort = i, selected = name == d.loadFillTypeName})
    end
    return entries
end

--- load target + more load targets of a draft, in order
local function loadTargetsOf(d)
    local list, seen = {}, {}
    local function add(n)
        if n ~= nil and n ~= "" and not seen[n] then
            seen[n] = true
            table.insert(list, n)
        end
    end
    add(d.loadMarker)
    for n in string.gmatch(d.extraLoadMarkers or "", "[^|]+") do
        add(n)
    end
    return list
end

local function loadTargetsText(d)
    local list = loadTargetsOf(d)
    if #list == 0 then
        return nil
    end
    return table.concat(list, ", ")
end

--- fill type the job loads (for the storage at the load target)
local function sourceFt(d)
    local n = (d.loadFillTypeName or "") ~= "" and d.loadFillTypeName or d.fillTypeName
    return g_fillTypeManager:getFillTypeIndexByName(n or ""), n
end

--- "Stroh 12000 l, Heu 300 l" (what is in a storage)
local function contentsText(p, max)
    local parts = {}
    for i, c in ipairs(ADJobs.getStorageContents(p)) do
        if i > (max or 2) then
            break
        end
        local fillType = g_fillTypeManager:getFillTypeByIndex(c.ft)
        table.insert(parts, string.format("%s %d l", fillType ~= nil and tostring(fillType.title) or "?", math.floor(c.level)))
    end
    if #parts == 0 then
        return txt("storageEmpty")
    end
    return table.concat(parts, ", ")
end

--- value of the row "storage at <target>"
local function sourceValue(d, markerName)
    local fixed = ADJobs.getStorageByUid(ADJobs.markerSources[markerName])
    if fixed ~= nil then
        return ADJobs.getStorageTitle(fixed) .. "  -  " .. contentsText(fixed.p, 2)
    end
    if ADJobs.markerSources[markerName] ~= nil then
        return txt("srcMissing")
    end
    local ft = sourceFt(d)
    if ft == nil then
        return txt("srcAutoEntry", ADJobs.SOURCE_RADIUS)
    end
    local _, names = ADJobs.getSourceLevel(markerName, ft)
    return names ~= nil and txt("srcAuto", names) or txt("srcAutoNone")
end

--- storages for an AD target: all near it, further away only those that keep the job's fill type
local function sourceEntries(d, markerName)
    local ft, ftName = sourceFt(d)
    local cur = ADJobs.markerSources[markerName]
    local curE = ADJobs.getStorageByUid(cur)
    local entries = {{label = txt("srcAutoEntry", ADJobs.SOURCE_RADIUS), value = "", sort = "", group = txt("grpAuto"), selected = cur == nil}}
    local mx, mz = ADJobs.getMarkerPosition(markerName)
    for _, e in ipairs(ADJobs.getStoragePlaceables()) do
        local dist = mx ~= nil and MathUtil.vector2Length(e.x - mx, e.z - mz) or 0
        local level = ft ~= nil and ADJobs.measurePlaceableFt(e.p, ft) or nil
        local near = dist <= 2 * ADJobs.SOURCE_RADIUS
        if near or level ~= nil or e == curE or ft == nil then
            local amount
            if level ~= nil then
                amount = string.format("%s %d l", fillTypeTitle(ftName), math.floor(level))
                local others = contentsText(e.p, 2)
                if level < 0.5 and others ~= txt("storageEmpty") then
                    amount = amount .. "  (" .. others .. ")"
                end
            else
                amount = contentsText(e.p, 2)
                if ft ~= nil then
                    amount = txt("srcNoFt", fillTypeTitle(ftName)) .. ": " .. amount
                end
            end
            table.insert(entries, {label = string.format("%s  -  %s  (%d m)", ADJobs.getStorageTitle(e), amount, math.floor(dist)), value = e.key,
                sort = string.format("%08d", math.floor(dist)), group = near and txt("srcGrpNear") or txt("srcGrpOther"), selected = e == curE})
        end
    end
    return sortEntries(entries, {txt("grpAuto"), txt("srcGrpNear"), txt("srcGrpOther")})
end

-------------------------------------------------------------------------------------------------
-- "Lager" tab: storage of AD targets without opening a job
-------------------------------------------------------------------------------------------------

H.storageExtra = {}   -- AD targets added in the "Lager" tab (listed until the game is closed)
H.storageScroll = 0
H.storageClosed = {}  -- [group] = true when collapsed

--- removes the fixed storage of an AD target (automatic again)
local function clearSource(name)
    if ADJobs.markerSources[name] ~= nil then
        ADJobs.setMarkerSource(name, "")
        ADJChangeEvent.sendEvent(ADJChangeEvent.OP_SOURCE, {id = 0, loadMarker = name, placeableUid = ""})
    end
    H.storageExtra[name] = nil
end

--- group of an AD target in the tab: the fill type its jobs load, else what its storage holds
local function storageGroupOf(t)
    if t.ftName ~= nil then
        return fillTypeTitle(t.ftName)
    end
    local fixed = ADJobs.getStorageByUid(ADJobs.markerSources[t.name])
    if fixed ~= nil then
        local c = ADJobs.getStorageContents(fixed.p)[1]
        local fillType = c ~= nil and g_fillTypeManager:getFillTypeByIndex(c.ft) or nil
        if fillType ~= nil then
            return tostring(fillType.title)
        end
    end
    return txt("storGrpOther")
end

--- AD targets of the tab: load targets of all jobs, targets with a storage set, targets added by hand
local function storageTargets()
    local byName, order = {}, {}
    local function add(name, job)
        if name == nil or name == "" then
            return
        end
        local t = byName[name]
        if t == nil then
            t = {name = name, jobs = {}}
            byName[name] = t
            table.insert(order, t)
        end
        if job ~= nil then
            table.insert(t.jobs, job)
            local n = (job.loadFillTypeName or "") ~= "" and job.loadFillTypeName or job.fillTypeName
            if t.ftName == nil and (n or "") ~= "" then
                t.ftName = n
            end
        end
    end
    for _, job in ipairs(ADJobs.jobs) do
        if job.driveMode ~= "sequence" then
            for _, n in ipairs(ADJobs.getLoadMarkers(job)) do
                add(n, job)
            end
        end
    end
    for name, _ in pairs(ADJobs.markerSources or {}) do
        add(name)
    end
    for name, _ in pairs(H.storageExtra) do
        add(name)
    end
    table.sort(order, function(a, b)
        return a.name:lower() < b.name:lower()
    end)
    return order
end

--- "+ add load target": every other AD target, nearest to the camera first
local function storageAddEntries()
    local shown = {}
    for _, t in ipairs(storageTargets()) do
        shown[t.name] = true
    end
    local cx, cz = cameraPosition()
    local entries = {}
    for _, m in ipairs(getMarkers()) do
        if not shown[m.name] then
            local dist = MathUtil.vector2Length(m.x - cx, m.z - cz)
            table.insert(entries, {label = m.name, sub = string.format("%d m", math.floor(dist)), value = m.name, sort = dist, group = m.group})
        end
    end
    return sortEntries(entries, {txt("grpDefault")})
end

--- rows of the tab: grouped by fill type, one per AD target (pull down = its storage), last row adds a target
local function storageRows()
    local rows = {}
    local groups, order = {}, {}
    for _, t in ipairs(storageTargets()) do
        local g = storageGroupOf(t)
        if groups[g] == nil then
            groups[g] = {}
            table.insert(order, g)
        end
        table.insert(groups[g], t)
    end
    local other = txt("storGrpOther")
    table.sort(order, function(a, b)
        if (a == other) ~= (b == other) then
            return b == other
        end
        return a:lower() < b:lower()
    end)
    for _, g in ipairs(order) do
        local fixedCount = 0
        for _, t in ipairs(groups[g]) do
            if ADJobs.markerSources[t.name] ~= nil then
                fixedCount = fixedCount + 1
            end
        end
        local closed = H.storageClosed[g] == true
        table.insert(rows, {key = "grp|" .. g, header = true, label = string.format("%s  %s  (%d)", closed and "+" or "-", g, #groups[g]),
            summary = txt("storGrpFixed", fixedCount, #groups[g]), click = function()
                H.storageClosed[g] = not closed or nil
                H.open = nil
            end})
        if not closed then
            for _, t in ipairs(groups[g]) do
                rows[#rows + 1] = t
            end
        end
    end
    local targets = rows
    rows = {}
    for _, t in ipairs(targets) do
      if t.header then
        table.insert(rows, t)
      else
        local name = t.name
        local pseudo = {loadFillTypeName = t.ftName}
        local users = {}
        for _, j in ipairs(t.jobs) do
            table.insert(users, tostring(j.name))
        end
        table.insert(rows, {key = "src|" .. name, icon = "zoom", fb = "L", label = name, value = sourceValue(pseudo, name),
            hint = (#users > 0 and txt("storUsedBy", table.concat(users, ", ")) or txt("storUnused")) .. "  ·  " .. txt("storRightHint"),
            list = function()
                return sourceEntries(pseudo, name)
            end,
            select = function(e)
                ADJobs.setMarkerSource(name, e.value)
                ADJChangeEvent.sendEvent(ADJChangeEvent.OP_SOURCE, {id = 0, loadMarker = name, placeableUid = e.value})
            end,
            right = function()
                clearSource(name)
            end})
      end
    end
    table.insert(rows, {key = "storAdd", icon = "plusSign", fb = "+", label = txt("storAdd"), value = txt("storAddValue"), hint = txt("storAddHint"),
        list = storageAddEntries,
        select = function(e)
            H.storageExtra[e.value] = true
            -- the storage list of the new target opens right away
            H.pendingOpen = "src|" .. e.value
        end})
    return rows
end

--- all AD targets except the unload target; ticked ones first with their number
local function loadTargetsEntries(d)
    local pos = {}
    for i, n in ipairs(loadTargetsOf(d)) do
        pos[n] = i
    end
    local entries = {}
    for _, m in ipairs(getMarkers()) do
        if m.name ~= d.unloadMarker then
            local i = pos[m.name]
            table.insert(entries, {label = (i ~= nil and string.format("[%d] ", i) or "[  ] ") .. m.name, value = m.name,
                sort = i ~= nil and string.format("%03d", i) or ("~" .. m.name:lower()), group = i ~= nil and txt("grpAuto") or m.group, selected = i ~= nil})
        end
    end
    return sortEntries(entries, {txt("grpAuto"), txt("grpDefault")})
end

local function emergencyEntries(d)
    local entries = {{label = txt("emergencyNone"), value = "", sort = 0, group = txt("grpAuto"), selected = (d.emergencyMarker or "") == ""}}
    for _, m in ipairs(getMarkers()) do
        if m.name ~= d.loadMarker and m.name ~= d.unloadMarker then
            table.insert(entries, {label = m.name, value = m.name, sort = m.name:lower(), group = m.group, selected = m.name == d.emergencyMarker})
        end
    end
    return sortEntries(entries, {txt("grpAuto"), txt("grpDefault")})
end

local function unloadEntries(d)
    local loadMode = d.driveMode == "load"
    local current = loadMode and "" or nil
    local ox, oz = cameraPosition()
    if d.placeableObject ~= nil and d.placeableObject.rootNode ~= nil then
        local x, _, z = getWorldTranslation(d.placeableObject.rootNode)
        ox, oz = x, z
    end
    local markers = {}
    for _, m in ipairs(getMarkers()) do
        if m.name ~= d.loadMarker then
            m.dist = MathUtil.vector2Length(m.x - ox, m.z - oz)
            table.insert(markers, m)
        end
    end
    local entries = {}
    if loadMode then
        table.insert(entries, {label = txt("returnAuto"), value = "", sort = 0, group = txt("grpAuto"), selected = (d.unloadMarker or "") == ""})
    end
    table.sort(markers, function(a, b)
        return a.dist < b.dist
    end)
    for i = 1, math.min(NEAREST_COUNT, #markers) do
        local m = markers[i]
        table.insert(entries, {label = m.name, sub = string.format("%d m", math.floor(m.dist)), value = m.name, sort = m.dist,
            group = txt("grpNearest"), selected = m.name == d.unloadMarker})
    end
    for _, m in ipairs(markers) do
        table.insert(entries, {label = m.name, sub = string.format("%d m", math.floor(m.dist)), value = m.name, sort = m.name:lower(),
            group = m.group, selected = m.name == d.unloadMarker})
    end
    return sortEntries(entries, {txt("grpAuto"), txt("grpNearest"), txt("grpDefault")})
end

-------------------------------------------------------------------------------------------------
-- editor: draft handling
-------------------------------------------------------------------------------------------------

local function copyJob(job)
    local draft = {}
    for k, v in pairs(job) do
        if type(k) == "string" and k:sub(1, 1) ~= "_" then
            draft[k] = v
        end
    end
    return draft
end

local function autoName(d)
    if d.placeableName == nil or d.sourceKind == nil then
        return ""
    end
    local short = ADJobs.getMeasureLabel(d)
    return string.format("%s - %s", tostring(d.placeableName), short)
end

function H.newJob()
    if not ADJobs.resolveAutoDrive() then
        warn("noAD")
        return
    end
    H.draft = {id = 0, active = true, low = 30, high = 90, maxTrips = 0, pauseMin = 10, driveMode = "deliver", direction = "fill", prio = ADJobs.PRIO_DEFAULT,
        swapTrailerUid = "", swapTrailerName = "", swapMarker = "", minPrice = 0,
        loadFillTypeName = "", unloadMarker = nil, parkMarker = nil, name = "", autoName = true, farmId = getFarmId()}
    H.view = "edit"
    H.open = nil
    H.showMissing = false
    H.pendingOpen = "object"
end

function H.editJob(job)
    if not ADJobs.resolveAutoDrive() then
        warn("noAD")
        return
    end
    local d = copyJob(job)
    d.autoName = false
    if d.farmId == nil or d.farmId == 0 then
        d.farmId = getFarmId()
    end
    local plc = ADJobs.findPlaceable(job)
    if plc ~= nil then
        d.placeableObject = plc
        local ok, options = pcall(ADJobs.getMeasureOptions, plc)
        if ok then
            for _, o in ipairs(options) do
                if o.kind == job.sourceKind and o.fillTypeName == job.fillTypeName then
                    d.candidates = o.candidates
                end
            end
        end
    end
    H.draft = d
    H.view = "edit"
    H.open = nil
    H.showMissing = false
end

--- "copy": the job being edited becomes a new job with the same settings; the object list opens so
--- the player only picks the next barn (targets, park position, levels ... stay)
function H.copyDraft()
    local d = H.draft
    if d == nil or d.id == 0 then
        return
    end
    local c = {}
    for k, v in pairs(d) do
        c[k] = v
    end
    c.id = 0
    if d.autoName or (d.name or "") == "" or d.name == autoName(d) then
        c.name, c.autoName = "", true
    else
        c.name, c.autoName = tostring(d.name) .. " " .. txt("copySuffix"), false
    end
    -- nothing of the running state of the original
    c.state, c.msgCode, c.tripsDone, c.tripsTotal, c.pauseLeft, c.percent, c.price = nil, nil, nil, nil, nil, nil, nil
    c.running, c.returnTrailerUid, c.parkRestore = nil, nil, nil
    H.draft = c
    H.open = nil
    H.showMissing = false
    H.pendingOpen = "object"
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, txt("copied"))
end

function H.closeEditor()
    H.view = "list"
    H.draft = nil
    H.open = nil
end

local function missingFields(d)
    local missing = {}
    if d.driveMode == "sequence" then
        if (d.parkMarker or "") == "" then
            missing.park = true
        end
        local steps = ADJobs.getSteps(d)
        if #steps == 0 then
            missing.addStep = true
        end
        for i, s in ipairs(steps) do
            if (s.course or "") == "" then
                missing["stepCourse" .. i] = true
            end
            if (s.unload or "") ~= "" and (s.marker or "") == "" then
                missing["stepTarget" .. i] = true
                missing.stepNeedsTarget = true
            end
        end
        return missing
    end
    if d.placeableObject == nil and (d.placeableUid or "") == "" then
        missing.object = true
    end
    if (d.sourceKind or "") == "" then
        missing.measure = true
    end
    if (d.parkMarker or "") == "" then
        missing.park = true
    end
    if (d.loadMarker or "") == "" then
        missing.load = true
    end
    if d.driveMode ~= "load" and (d.unloadMarker or "") == "" then
        missing.unload = true
    end
    if d.driveMode ~= "load" and (d.swapTrailerUid or "") ~= "" then
        -- trailer swap: the AD park position of the job trailer (own or chosen) is needed and must differ
        -- from the park position of the job
        local st = ADJobs.getSwapMarker(d)
        if st == "" or st == d.parkMarker then
            missing.swapMarker = true
        end
    end
    return missing
end

function H.saveDraft()
    local d = H.draft
    if d == nil then
        return
    end
    local missing = missingFields(d)
    if next(missing) ~= nil then
        H.showMissing = true
        warn(missing.swapMarker and "swapMissing" or (missing.stepNeedsTarget and "stepUnloadNeedsTarget" or "missing"))
        return
    end
    if d.driveMode == "sequence" then
        d.direction, d.minPrice, d.low, d.high = "fill", 0, 0, 100
        d.swapTrailerUid, d.swapTrailerName, d.swapMarker = "", "", ""
        d.placeableUid, d.placeableName, d.sourceKind, d.fillTypeName = "", txt("seqKind"), "sequence", ""
        if d.autoName or (d.name or "") == "" then
            local first = ADJobs.getSteps(d)[1]
            d.name = string.format("%s %s", txt("seqKind"), first ~= nil and (tostring(first.course):gsub("^@", ""):match("([^/]+)$")) or "")
            d.autoName = false
        end
    end
    if d.driveMode ~= "load" and d.high <= d.low then
        d.high = math.min(100, d.low + 1)
    end
    if d.driveMode == "load" then
        -- feeders always "fill" (they load for themselves); no trailer swap
        d.direction = "fill"
        d.swapTrailerUid, d.swapTrailerName, d.swapMarker = "", "", ""
    end
    d.direction = d.direction == "empty" and "empty" or "fill"
    if d.direction == "empty" then
        d.emergencyMarker = ""
    else
        d.minPrice = 0
    end
    if (d.swapTrailerUid or "") == "" then
        d.swapMarker = ""
    end
    if d.driveMode == "load" and d.unloadMarker == nil then
        d.unloadMarker = ""
    end
    if d.autoName or (d.name or "") == "" then
        d.name = autoName(d)
    end
    if d.active == nil then
        d.active = true
    end
    if d.driveMode == "sequence" and ADJobs.uploadSequenceCourses ~= nil then
        -- multiplayer: the course files are on this PC, the job runs on the server - send them first
        -- (same connection, so the server has them before the job is saved)
        pcall(ADJobs.uploadSequenceCourses, d)
    end
    ADJChangeEvent.sendEvent(ADJChangeEvent.OP_SAVE, d)
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, txt("wizSaved", d.name or ""))
    H.closeEditor()
end

local editGroup
local sequenceRows
local function editName()
    local d = H.draft
    local default = (d.name ~= nil and d.name ~= "") and d.name or autoName(d)
    TextInputDialog.show(function(_, text, clickOk)
        if clickOk and H.draft == d then
            local name = tostring(text or "")
            if name ~= "" then
                d.name = name
                d.autoName = false
            else
                d.autoName = true
            end
        end
    end, H, default, txt("wizName"), txt("wizName"), 40, g_i18n:getText("button_ok"))
end

--- groups for the pull down: automatic, all groups in use, "new group ..."
local function groupEntries(d)
    local entries = {{label = txt("groupAuto"), value = "", sort = 0, selected = (d.group or "") == ""}}
    local seen = {}
    for _, job in ipairs(ADJobs.jobs) do
        local g = job.group or ""
        if g ~= "" and not seen[g] then
            seen[g] = true
            table.insert(entries, {label = g, value = g, sort = 1, selected = g == d.group})
        end
    end
    if (d.group or "") ~= "" and not seen[d.group] then
        table.insert(entries, {label = d.group, value = d.group, sort = 1, selected = true})
    end
    table.insert(entries, {label = txt("groupNew"), value = "\1new", sort = 2})
    return entries
end

editGroup = function()
    local d = H.draft
    TextInputDialog.show(function(_, text, clickOk)
        if clickOk and H.draft == d then
            d.group = tostring(text or "")
        end
    end, H, d.group or "", txt("fGroup"), txt("fGroup"), 30, g_i18n:getText("button_ok"))
end

--- AD targets for a step (first entry: none - Courseplay drives there itself)
local function stepTargetEntries(i)
    return function(d)
        local cur = (ADJobs.getSteps(d)[i] or {}).marker or ""
        local entries = {{label = txt("stepTargetNone"), value = "", sort = "", group = txt("grpAuto"), selected = cur == ""}}
        for _, m in ipairs(getMarkers()) do
            table.insert(entries, {label = m.name, value = m.name, sort = m.name:lower(), group = m.group, selected = m.name == cur})
        end
        return sortEntries(entries, {txt("grpAuto"), txt("grpDefault")})
    end
end

--- unload targets for a step (first entry: none)
local function stepUnloadEntries(i)
    return function(d)
        local cur = (ADJobs.getSteps(d)[i] or {}).unload or ""
        local entries = {{label = txt("stepUnloadNone"), value = "", sort = "", group = txt("grpAuto"), selected = cur == ""}}
        for _, m in ipairs(getMarkers()) do
            table.insert(entries, {label = m.name, value = m.name, sort = m.name:lower(), group = m.group, selected = m.name == cur})
        end
        return sortEntries(entries, {txt("grpAuto"), txt("grpDefault")})
    end
end

--- saved Courseplay courses for a step (folders as groups); the first entry removes the step
local function stepCourseEntries(i)
    return function(d)
        local cur = (ADJobs.getSteps(d)[i] or {}).course or ""
        local entries = {{label = txt("stepRemove", i), value = "\1remove", sort = "", group = txt("grpAuto")}}
        -- courses loaded in vehicles (also courses that were never saved as a file)
        for _, c in ipairs(ADJobs.getVehicleCpCourses(d.farmId or getFarmId())) do
            if not c.dup then
                table.insert(entries, {label = c.name, sub = ADJobs.getVehicleName(c.vehicle), value = c.path, sort = c.name:lower(),
                    group = txt("grpCpVehicles"), selected = c.path == cur})
            end
        end
        for _, c in ipairs(ADJobs.getCpCourses()) do
            local folder = c.folder ~= "" and c.folder:sub(1, -2) or txt("grpDefault")
            table.insert(entries, {label = c.name, value = c.path, sort = c.name:lower(), group = folder, selected = c.path == cur})
        end
        return sortEntries(entries, {txt("grpAuto"), txt("grpCpVehicles"), txt("grpDefault")})
    end
end

--- editor rows of a sequence job: name, group, active (already in rows), mode, park position, the steps
sequenceRows = function(d, rows)
    table.insert(rows, {key = "mode", icon = "rotateTargets_1", fb = "F", label = txt("fMode"), value = modeTitle(d.driveMode), list = modeEntries,
        select = function(e)
            d.driveMode = e.value
            if e.value ~= "load" and d.unloadMarker == "" then
                d.unloadMarker = nil
            end
        end})
    local parkValue = nil
    if (d.parkMarker or "") ~= "" then
        parkValue = string.format("%s  -  %s", d.parkMarker, parkVehicleText(d.parkMarker, d.farmId))
    end
    table.insert(rows, {key = "park", icon = "input_parkVehicle_1", fb = "P", label = txt("fPark"), value = parkValue, list = parkEntries,
        emptyText = txt("noParks"),
        select = function(e)
            d.parkMarker = e.value
            parkCache = {}
        end})
    local steps = ADJobs.getSteps(d)
    for i, step in ipairs(steps) do
        table.insert(rows, {key = "stepTarget" .. i, icon = "marker", fb = tostring(i), label = txt("fStepTarget", i),
            value = (step.marker or "") ~= "" and step.marker or txt("stepTargetNone"), list = stepTargetEntries(i),
            select = function(e)
                local list = ADJobs.getSteps(d)
                if list[i] ~= nil then
                    list[i].marker = e.value
                    ADJobs.setSteps(d, list)
                end
            end})
        table.insert(rows, {key = "stepCourse" .. i, icon = "input_toggleLoadByFillLevel_1", fb = "C", label = txt("fStepCourse", i),
            value = (step.course or "") ~= "" and ((step.course:sub(1, 1) == "@") and (step.course:sub(2) .. "  (" .. txt("grpCpVehicles") .. ")") or step.course) or nil,
            list = stepCourseEntries(i), emptyText = txt("noCourses"),
            select = function(e)
                local list = ADJobs.getSteps(d)
                if e.value == "\1remove" then
                    table.remove(list, i)
                elseif list[i] ~= nil then
                    list[i].course = e.value
                end
                ADJobs.setSteps(d, list)
            end})
        table.insert(rows, {key = "stepUnload" .. i, icon = "input_toggleAutomaticUnloadTarget_1", fb = "U", label = txt("fStepUnload", i),
            value = (step.unload or "") ~= "" and step.unload or txt("stepUnloadNone"), list = stepUnloadEntries(i), hint = txt("stepUnloadHint"),
            select = function(e)
                local list = ADJobs.getSteps(d)
                if list[i] ~= nil then
                    list[i].unload = e.value
                    ADJobs.setSteps(d, list)
                end
            end})
    end
    table.insert(rows, {key = "addStep", icon = "plusSign", fb = "+", label = txt("stepAdd"), value = txt("seqLimits", #steps), hint = txt("stepAddHint"),
        click = function()
            local list = ADJobs.getSteps(d)
            table.insert(list, {marker = "", course = ""})
            ADJobs.setSteps(d, list)
            H.pendingOpen = "stepCourse" .. #list
        end})
    return rows
end

--- rows of the editor for the current draft
--- load fill type follows the watched value: the same fill type (first one if the value accepts several);
--- for values with many fill types (e.g. "food total", "total load") the AutoDrive setting is kept
local function applyMeasure(d, option)
    d.sourceKind, d.fillTypeName, d.candidates = option.kind, option.fillTypeName, option.candidates
    local cands = option.candidates or {}
    if #cands >= 1 and #cands <= 3 then
        d.loadFillTypeName = g_fillTypeManager:getFillTypeNameByIndex(cands[1]) or ""
    else
        d.loadFillTypeName = ""
    end
end

local function editorRows(d)
    local loadMode = d.driveMode == "load"
    local rows = {}

    local nameValue = d.name
    if d.autoName or (d.name or "") == "" then
        nameValue = autoName(d)
    end
    table.insert(rows, {key = "name", icon = "input_editMapMarker_1", fb = "N", label = txt("fName"), value = nameValue, click = editName})

    local groupValue = (d.group or "") ~= "" and d.group or txt("groupAuto")
    table.insert(rows, {key = "group", icon = "input_editMapMarker_1", fb = "G", label = txt("fGroup"), value = groupValue, list = groupEntries,
        hint = txt("groupHint"),
        select = function(e)
            if e.value == "\1new" then
                editGroup()
            else
                d.group = e.value
            end
        end})

    table.insert(rows, {key = "prio", icon = "loop_counter_active", fb = "!", label = txt("fPrio"), value = txt("prioValue", ADJobs.getPrio(d)),
        hint = txt("prioHint"),
        counter = function(delta)
            d.prio = math.max(1, math.min(9, ADJobs.getPrio(d) + (delta > 0 and 1 or -1)))
        end, step = 1})
    table.insert(rows, {key = "active", icon = d.active ~= false and "input_start_stop_2" or "input_start_stop_1", fb = "I", label = txt("fActive"),
        value = d.active ~= false and txt("activeYes") or txt("activeNo"), hint = d.driveMode == "sequence" and txt("seqHint") or nil, click = function()
            d.active = d.active == false
        end})
    if d.driveMode == "sequence" then
        return sequenceRows(d, rows)
    end

    table.insert(rows, {key = "object", icon = "tipper_load", fb = "O", label = txt("fObject"), value = d.placeableName, list = objectEntries,
        select = function(e)
            local obj = e.value
            local isVehicle = obj.isVehicle or obj.spec_fillUnit ~= nil or obj.getRootVehicle ~= nil
            d.placeableObject = obj
            d.placeableName = isVehicle and ADJobs.getVehicleName(obj) or ADJobs.getPlaceableLabel(obj)
            d.placeableUid = obj.getUniqueId and obj:getUniqueId() or ""
            d.sourceKind, d.fillTypeName, d.candidates = nil, nil, nil
            if d.id == 0 then
                d.driveMode = isVehicle and "load" or "deliver"
            end
            -- the park position of the trailer (or of its tractor) is known: take it over
            if isVehicle then
                local park = ADJobs.getParkNameOfObject(obj)
                if park ~= nil then
                    d.parkMarker = park
                    parkCache = {}
                end
            end
            local options = measureEntries(d)
            if #options == 1 then
                applyMeasure(d, options[1].value)
            else
                H.pendingOpen = "measure"
            end
        end})

    local measureValue = nil
    if (d.sourceKind or "") ~= "" then
        measureValue = ADJobs.getMeasureLabel(d)
    end
    table.insert(rows, {key = "measure", icon = "zoom", fb = "M", label = txt("fMeasure"), value = measureValue, list = measureEntries,
        disabled = d.placeableObject == nil,
        select = function(e)
            applyMeasure(d, e.value)
        end})

    table.insert(rows, {key = "mode", icon = "rotateTargets_1", fb = "F", label = txt("fMode"),
        value = modeTitle(d.driveMode), list = modeEntries,
        select = function(e)
            d.driveMode = e.value
            if e.value == "load" and d.unloadMarker == nil then
                d.unloadMarker = ""
            elseif e.value ~= "load" and d.unloadMarker == "" then
                d.unloadMarker = nil
            end
        end})

    local emptyMode = not loadMode and d.direction == "empty"
    if not loadMode then
        -- rule direction: supply (start below X) or haul away / sell (start at Y)
        table.insert(rows, {key = "direction", icon = "input_toggleLoadByFillLevel_1", fb = "R", label = txt("fDirection"),
            value = emptyMode and txt("dirEmpty") or txt("dirFill"), list = directionEntries,
            select = function(e)
                d.direction = e.value
            end})
    end

    local parkValue = nil
    if (d.parkMarker or "") ~= "" then
        local vehicles = parkVehicleText(d.parkMarker, d.farmId)
        parkValue = string.format("%s  -  %s", d.parkMarker, vehicles)
    end
    table.insert(rows, {key = "park", icon = "input_parkVehicle_1", fb = "P", label = txt("fPark"), value = parkValue, list = parkEntries,
        emptyText = txt("noParks"), hint = (not loadMode and (d.swapTrailerUid or "") ~= "") and txt("swapParkHint") or nil,
        select = function(e)
            d.parkMarker = e.value
            parkCache = {}
        end})

    if not loadMode then
        -- trailer swap: the job runs only with this trailer; the vehicle swaps before / after a run
        local hasSwap = (d.swapTrailerUid or "") ~= ""
        table.insert(rows, {key = "swapTrailer", icon = "tipper_load", fb = "T", label = txt("fSwapTrailer"),
            value = hasSwap and swapTrailerName(d) or txt("swapNone"), list = swapTrailerEntries,
            select = function(e)
                d.swapTrailerUid = e.value
                d.swapTrailerName = e.value ~= "" and e.label or ""
                if e.value == "" then
                    d.swapMarker = ""
                end
            end})
        if hasSwap then
            local standValue = d.swapMarker
            if (standValue or "") == "" then
                local auto = ADJobs.getSwapMarker(d)
                standValue = auto ~= "" and txt("swapAuto", auto) or nil
            end
            table.insert(rows, {key = "swapMarker", icon = "marker", fb = "B", label = txt("fSwapMarker"),
                value = standValue, list = swapMarkerEntries, hint = txt("swapHint"),
                select = function(e)
                    d.swapMarker = e.value
                end})
        end
    end

    local ftValue = (d.loadFillTypeName or "") == "" and txt("keepFtShort") or fillTypeTitle(d.loadFillTypeName)
    table.insert(rows, {key = "loadFt", icon = "input_toggleLoadByFillLevel_1", fb = "L", label = txt("fLoadFt"), value = ftValue, list = fillTypeEntries,
        disabled = (d.sourceKind or "") == "",
        select = function(e)
            d.loadFillTypeName = e.value
        end})

    -- load targets: one row, several can be ticked - the first is the load target, the others are tried in
    -- this order when the storage at one is empty
    table.insert(rows, {key = "load", icon = "marker", fb = "1", label = txt("fLoads"), value = loadTargetsText(d), list = loadTargetsEntries,
        multi = true, hint = txt("loadsHint"),
        select = function(e)
            local list, found = {}, false
            for _, n in ipairs(loadTargetsOf(d)) do
                if n == e.value then
                    found = true
                else
                    table.insert(list, n)
                end
            end
            if not found then
                table.insert(list, e.value)
            end
            d.loadMarker = list[1]
            table.remove(list, 1)
            d.extraLoadMarkers = table.concat(list, "|")
            if d.unloadMarker == e.value and not found then
                d.unloadMarker = loadMode and "" or nil
            end
        end})

    -- storage at each load target: several silos side by side (hay / straw) - the right one by hand
    for _, name in ipairs(loadTargetsOf(d)) do
        local markerName = name
        table.insert(rows, {key = "src|" .. markerName, icon = "zoom", fb = "L", label = txt("fSource", markerName),
            value = sourceValue(d, markerName), list = function(dd)
                return sourceEntries(dd, markerName)
            end, hint = txt("srcHint"),
            select = function(e)
                -- applies to all jobs with this target: sent right away (not only with "save")
                ADJobs.setMarkerSource(markerName, e.value)
                ADJChangeEvent.sendEvent(ADJChangeEvent.OP_SOURCE, {id = 0, loadMarker = markerName, placeableUid = e.value})
            end,
            right = function()
                if ADJobs.markerSources[markerName] ~= nil then
                    ADJobs.setMarkerSource(markerName, "")
                    ADJChangeEvent.sendEvent(ADJChangeEvent.OP_SOURCE, {id = 0, loadMarker = markerName, placeableUid = ""})
                end
            end})
    end

    local unloadValue = d.unloadMarker
    if loadMode and (unloadValue or "") == "" then
        unloadValue = txt("autoShort")
    end
    table.insert(rows, {key = "unload", icon = "input_toggleAutomaticUnloadTarget_1", fb = "2", label = loadMode and txt("fReturn") or txt("fUnload"),
        value = unloadValue, list = unloadEntries,
        select = function(e)
            d.unloadMarker = e.value
        end})

    if not loadMode and not emptyMode then
        -- where a rest goes if too much was loaded and no other job with the same fill type has space
        -- (haul away: the sell point takes everything, no rest)
        local emValue = (d.emergencyMarker or "") ~= "" and d.emergencyMarker or txt("emergencyNone")
        table.insert(rows, {key = "emergency", icon = "warn_icon", fb = "!", label = txt("fEmergency"), value = emValue, list = emergencyEntries,
            select = function(e)
                d.emergencyMarker = e.value
            end})
    end

    local lowRow = {key = "low", icon = "input_toggleLoadByFillLevel_2", fb = "<", label = emptyMode and txt("fLowEmpty") or txt("fLow"),
        value = string.format("%d %%", math.floor(d.low or 0)),
        counter = function(delta)
            d.low = math.max(0, math.min(loadMode and 100 or 99, math.floor((d.low or 0) + delta)))
            if not loadMode and (d.high or 0) <= d.low then
                d.high = math.min(100, d.low + 1)
            end
        end, step = 5}
    local highRow = nil
    if not loadMode then
        highRow = {key = "high", icon = "input_toggleLoadByFillLevel_3", fb = ">", label = emptyMode and txt("fHighEmpty") or txt("fHigh"),
            value = string.format("%d %%", math.floor(d.high or 0)),
            counter = function(delta)
                d.high = math.max((d.low or 0) + 1, math.min(100, math.floor((d.high or 0) + delta)))
            end, step = 5}
    end
    if emptyMode then
        -- haul away: the start level ("start at") comes first, as for supply jobs
        table.insert(rows, highRow)
        table.insert(rows, lowRow)
    else
        table.insert(rows, lowRow)
        if highRow ~= nil then
            table.insert(rows, highRow)
        end
    end

    if not loadMode then
        if emptyMode then
            -- haul away: do not start below this price at the unload target
            local priceValue = txt("minPriceOff")
            if (d.minPrice or 0) > 0 then
                local now = ADJobs.getSellPrice(d)
                priceValue = txt("minPriceNow", math.floor(d.minPrice), now ~= nil and tostring(math.floor(now)) or txt("priceUnknown"))
            end
            table.insert(rows, {key = "minPrice", icon = "input_toggleLoadByFillLevel_3", fb = "€", label = txt("fMinPrice"),
                value = priceValue, hint = txt("minPriceHint"),
                counter = function(delta)
                    local step = 50
                    d.minPrice = math.max(0, math.min(100000, math.floor((d.minPrice or 0) / step + delta + 0.5) * step))
                end, step = 1})
        end
        table.insert(rows, {key = "trips", icon = "loop_counter_active", fb = "#", label = txt("fTrips"),
            value = (d.maxTrips or 0) > 0 and tostring(d.maxTrips) or txt("unlimited"),
            counter = function(delta)
                d.maxTrips = math.max(0, math.min(99, math.floor((d.maxTrips or 0) + delta)))
            end, step = 1})
    end
    if loadMode then
        -- feeder: how long it waits at the waiting place without any change before it parks
        table.insert(rows, {key = "pause", icon = "input_parkVehicle_1", fb = "P", label = txt("fParkAfter"),
            value = (d.pauseMin or 0) > 0 and txt("parkAfterValue", d.pauseMin) or txt("parkNever"),
            counter = function(delta)
                d.pauseMin = math.max(0, math.min(10000, math.floor((d.pauseMin or 0) + delta)))
            end, step = 5})
    elseif (d.maxTrips or 0) > 0 then
        table.insert(rows, {key = "pause", icon = "input_continue_1", fb = "P", label = txt("fPause"),
            value = string.format("%d %s", d.pauseMin or 0, txt("unitMin")),
            counter = function(delta)
                d.pauseMin = math.max(0, math.min(10000, math.floor((d.pauseMin or 0) + delta)))
            end, step = 5})
    end
    return rows
end

-------------------------------------------------------------------------------------------------
-- editor: drawing
-------------------------------------------------------------------------------------------------

--- builds the visible lines of a pull down list (AutoDrive style folders)
local function buildDisplay(key, entries)
    local groups, order = {}, {}
    for _, e in ipairs(entries) do
        local g = e.group or ""
        if groups[g] == nil then
            groups[g] = {}
            table.insert(order, g)
        end
        table.insert(groups[g], e)
    end
    local display = {}
    if #order <= 1 then
        for _, e in ipairs(entries) do
            table.insert(display, {entry = e})
        end
        return display
    end
    for i, g in ipairs(order) do
        local fk = key .. "|" .. g
        local open = H.folders[fk]
        if open == nil then
            open = i == 1
            for _, e in ipairs(groups[g]) do
                if e.selected then
                    open = true
                end
            end
            H.folders[fk] = open
        end
        table.insert(display, {folder = g, key = fk, open = open, count = #groups[g]})
        if open then
            for _, e in ipairs(groups[g]) do
                table.insert(display, {entry = e, indent = true})
            end
        end
    end
    return display
end

function H.openList(row)
    H.open = row.key
    H.pdScroll = 0
    H.pdEntries = row.list(H.draft) or {}
    -- folders: open the first one and the one with the selected entry
    for k, _ in pairs(H.folders) do
        if k:sub(1, #row.key + 1) == row.key .. "|" then
            H.folders[k] = nil
        end
    end
    -- scroll to the selected entry
    local display = buildDisplay(row.key, H.pdEntries)
    for i, line in ipairs(display) do
        if line.entry ~= nil and line.entry.selected then
            H.pdScroll = math.max(0, i - math.floor(MAX_LIST_ROWS / 2))
            break
        end
    end
end

local function pulldownGeometry(row, fx, fy, fw, fh)
    local display = buildDisplay(row.key, H.pdEntries)
    local n = math.max(1, math.min(MAX_LIST_ROWS, #display))
    H.pdScroll = math.max(0, math.min(H.pdScroll, math.max(0, #display - MAX_LIST_ROWS)))
    local listH = n * M.itemH + 2 * M.gapY
    local ly = fy - listH
    if ly < 0.005 then
        ly = fy + fh
    end
    return display, n, ly, listH
end

local function drawPulldown(row, fx, fy, fw, fh)
    local display, n, ly, listH = pulldownGeometry(row, fx, fy, fw, fh)
    H.pdArea = {x = fx, y = ly, w = fw, h = listH}
    drawFilledRect(fx, ly, fw, listH, 0.03, 0.03, 0.03, 0.98)
    local border = M.py(1)
    drawFilledRect(fx, ly + listH - border, fw, border, C_HOVER[1], C_HOVER[2], C_HOVER[3], 1)
    drawFilledRect(fx, ly, fw, border, 0.4, 0.4, 0.4, 1)
    -- wheel anywhere on the list scrolls it, a click on empty space does nothing
    addBox(fx, ly, fw, listH, function()
    end, function(dir)
        H.pdScroll = H.pdScroll - dir
    end)

    if #display == 0 then
        local text = row.emptyText or txt("emptyList")
        drawText(fx + 2 * M.gapX, textY(ly + M.gapY, M.itemH, M.small), M.small, fit(text, fw - 4 * M.gapX, M.small), C_GREY)
        return
    end

    for i = 1, n do
        local line = display[i + H.pdScroll]
        if line == nil then
            break
        end
        local iy = ly + listH - M.gapY - i * M.itemH
        local hover = isInside(fx, iy, fw, M.itemH)
        if hover then
            drawFilledRect(fx, iy, fw, M.itemH, 1, 1, 1, 0.1)
        end
        local ty = textY(iy, M.itemH, M.small)
        if line.folder ~= nil then
            local label = string.format("%s  %s  (%d)", line.open and "-" or "+", line.folder, line.count)
            drawText(fx + 2 * M.gapX, ty, M.small, fit(label, fw - 4 * M.gapX, M.small), hover and C_HOVER or C_SPECIAL, true)
            addBox(fx, iy, fw, M.itemH, function()
                H.folders[line.key] = not line.open
            end, function(dir)
                H.pdScroll = H.pdScroll - dir
            end)
        else
            local e = line.entry
            local x0 = fx + 2 * M.gapX + (line.indent and M.px(12) or 0)
            local avail = fx + fw - 2 * M.gapX - x0
            local subW = 0
            if e.sub ~= nil and e.sub ~= "" then
                subW = math.min(getTextWidth(M.small, e.sub), avail * 0.55)
                drawText(fx + fw - 2 * M.gapX - M.px(4), ty, M.small, fit(e.sub, subW, M.small), C_GREY, false, RenderText.ALIGN_RIGHT)
            end
            local color = C_TEXT
            if hover then
                color = C_HOVER
            elseif e.selected then
                color = C_SPECIAL
            end
            drawText(x0, ty, M.small, fit(e.label, avail - subW - 3 * M.gapX, M.small), color, e.selected)
            addBox(fx, iy, fw, M.itemH, function()
                if row.multi then
                    -- several can be chosen: toggle, refresh the list, keep it open
                    row.select(e)
                    H.pdEntries = row.list(H.draft) or {}
                    return
                end
                H.open = nil
                row.select(e)
            end, function(dir)
                H.pdScroll = H.pdScroll - dir
            end)
        end
    end
    -- scroll bar
    if #display > MAX_LIST_ROWS then
        local trackY, trackH = ly + M.gapY, n * M.itemH
        local thumbH = trackH * MAX_LIST_ROWS / #display
        local thumbY = trackY + trackH - thumbH - (trackH - thumbH) * H.pdScroll / (#display - MAX_LIST_ROWS)
        drawFilledRect(fx + fw - M.px(3), thumbY, M.px(2), thumbH, C_HOVER[1], C_HOVER[2], C_HOVER[3], 0.9)
    end
end

--- mode nil: the job editor (H.draft); mode "storages": the "Lager" tab (same rows and pull down lists)
function H.drawEditor(mode)
    local storageMode = mode == "storages"
    local d = storageMode and {id = -1} or H.draft
    local rows = storageMode and storageRows() or editorRows(d)
    local missing = (not storageMode and H.showMissing) and missingFields(d) or {}
    local maxScroll = 0
    if storageMode then
        -- the tab can get long: scroll it with the mouse wheel
        maxScroll = math.max(0, #rows - MAX_LIST_ROWS)
        -- a list that should open by itself: scroll its row into view
        if H.pendingOpen ~= nil then
            for i, row in ipairs(rows) do
                if row.key == H.pendingOpen and (i <= H.storageScroll or i > H.storageScroll + MAX_LIST_ROWS) then
                    H.storageScroll = i - 1
                end
            end
        end
        H.storageScroll = math.max(0, math.min(H.storageScroll, maxScroll))
        local part = {}
        for i = H.storageScroll + 1, math.min(#rows, H.storageScroll + MAX_LIST_ROWS) do
            table.insert(part, rows[i])
        end
        rows = part
    end
    local buttonH = M.py(24)
    local tabSpace = storageMode and (M.tabH + M.gapY) or 0
    local buttonSpace = storageMode and 0 or (buttonH + M.gapY * 2)
    local totalH = M.headerH + M.gapY + tabSpace + #rows * M.rowH + M.gapY * 2 + buttonSpace
    clampPosition(totalH)
    local x, top, w = H.x, H.top, M.w
    local bottom = top - totalH
    H.area = {x = x, y = bottom, w = w, h = totalH}
    drawBackground(x, bottom, w, totalH)
    addBox(x, bottom, w, totalH, function()
    end, storageMode and function(dir)
        H.storageScroll = H.storageScroll - dir
    end or nil)

    -- hover hint of a row (previous frame) is shown in the header, like the tool tips of the list
    local hint = H.nextHint
    H.nextHint = nil
    local storageButton = {nil, nil, function()
        H.showStorages = not H.showStorages
    end, text = "L#", on = H.showStorages, tip = txt("tipStorageNums")}
    if storageMode then
        local tip = H.nextTooltip
        H.nextTooltip = nil
        local title = hint or tip or txt("title")
        if maxScroll > 0 then
            title = string.format("%s  (%d / %d)", title, H.storageScroll + 1, maxScroll + 1)
        end
        drawHeader(x, top, w, title, {
            {"input_toggleHud_1", "X", function()
                ADJobs.toggleHud()
            end},
            {"plusSign", "+", function()
                H.newJob()
            end},
            storageButton,
        })
        H.drawTabs(x, top - M.headerH - M.gapY, w)
    else
        drawHeader(x, top, w, hint or (d.id == 0 and txt("hudNew") or string.format("%s: %s", txt("hudEdit"), tostring(d.name))), {
            {"input_toggleHud_1", "X", function()
                H.closeEditor()
            end},
            storageButton,
        })
    end
    local rowsTop = top - M.headerH - M.gapY - tabSpace

    local openRow, openGeo = nil, nil
    local fieldX = x + 2 * M.gapX + M.iconW
    local fieldW = x + w - M.gapX - fieldX
    -- list that should open by itself (e.g. after choosing the object)
    if H.pendingOpen ~= nil then
        for _, row in ipairs(rows) do
            if H.pendingOpen == row.key and row.list ~= nil and not row.disabled then
                H.openList(row)
            end
        end
        H.pendingOpen = nil
    end
    -- pre pass: where will the expanded list be? (nothing else may be drawn there)
    H.occluder = nil
    for i, row in ipairs(rows) do
        if H.open == row.key and row.list ~= nil then
            local rowTop = rowsTop - (i - 1) * M.rowH
            local iy = rowTop - (M.rowH - M.iconH) / 2 - M.iconH
            local _, _, ly, listH = pulldownGeometry(row, fieldX, iy, fieldW, M.iconH)
            H.occluder = {x = fieldX, y = ly, w = x + w - fieldX, h = listH}
        end
    end
    for i, row in ipairs(rows) do
        local rowTop = rowsTop - (i - 1) * M.rowH
        local iy = rowTop - (M.rowH - M.iconH) / 2 - M.iconH
      if row.header then
        -- group line ("Lager" tab): click = open / close
        local hy, hh = rowTop - M.rowH + M.gapY / 2, M.rowH - M.gapY
        local hover = isInside(x + M.gapX, hy, w - 2 * M.gapX, hh) and H.open == nil
        drawFilledRect(x + M.gapX, hy, w - 2 * M.gapX, hh, C_SPECIAL[1], C_SPECIAL[2], C_SPECIAL[3], hover and 0.25 or 0.14)
        local sumW = 0
        if row.summary ~= nil then
            sumW = getTextWidth(M.small, row.summary)
            drawText(x + w - 3 * M.gapX, textY(hy, hh, M.small), M.small, row.summary, C_GREY, false, RenderText.ALIGN_RIGHT)
        end
        drawText(x + 3 * M.gapX, textY(hy, hh, M.font), M.font, fit(row.label, w - sumW - 8 * M.gapX, M.font), hover and C_HOVER or C_SPECIAL, true)
        addBox(x + M.gapX, hy, w - 2 * M.gapX, hh, row.click, storageMode and function(dir)
            H.storageScroll = H.storageScroll - dir
        end or nil)
      else
        -- icon on the left (like the AutoDrive HUD)
        if not drawSlice(row.icon, x + M.gapX, iy, M.iconW, M.iconH) then
            drawFilledRect(x + M.gapX, iy, M.iconW, M.iconH, 0.32, 0.32, 0.32, 0.95)
            drawText(x + M.gapX + M.iconW / 2, textY(iy, M.iconH, M.small), M.small, row.fb, C_TEXT, true, RenderText.ALIGN_CENTER)
        end

        local fy, fh = iy, M.iconH
        local fw = fieldW
        if row.counter ~= nil then
            fw = fieldW - 2 * (M.iconW + M.gapX)
        end
        local hover = not row.disabled and isInside(fieldX, fy, fw, fh) and H.open == nil
        drawSlice("4xlongBorderFilled", fieldX, fy, fw, fh, 0.25, 0.25, 0.25, 0.95)
        if hover then
            drawFilledRect(fieldX, fy, fw, fh, 1, 1, 1, 0.08)
            if row.hint ~= nil then
                H.nextHint = row.hint
            end
        end
        local ty = textY(fy, fh, M.font)
        local labelText = row.label .. ":"
        local labelColor = missing[row.key] and C_RED or C_GREY
        drawText(fieldX + 2 * M.gapX, ty, M.small, labelText, labelColor, false)
        local labelW = math.max(getTextWidth(M.small, labelText), M.px(92))
        local vx = fieldX + 3 * M.gapX + labelW
        local arrowSpace = row.list ~= nil and (M.smallW + 2 * M.gapX) or M.gapX
        local value = row.value
        local valueColor = hover and C_HOVER or C_TEXT
        if value == nil or value == "" then
            value = txt("choose")
            valueColor = missing[row.key] and C_RED or C_GREY
        end
        if row.disabled then
            valueColor = {0.5, 0.5, 0.5, 1}
        end
        if row.key == "name" and (d.autoName or (d.name or "") == "") and not hover then
            valueColor = C_GREY
        end
        drawText(vx, ty, M.font, fit(value, fieldX + fw - arrowSpace - vx, M.font), valueColor, H.open == row.key)
        if row.list ~= nil then
            local ax = fieldX + fw - M.smallW - M.gapX
            drawSlice(H.open == row.key and "arrowCollapse" or "arrowExpand", ax, fy + (fh - M.smallH) / 2, M.smallW, M.smallH)
        end

        if row.counter ~= nil then
            local step = row.step or 1
            local bx = fieldX + fw + M.gapX
            addBox(fieldX, fy, fw, fh, function()
                row.counter(step)
            end, function(dir)
                row.counter(dir)
            end, function()
                row.counter(-step)
            end)
            iconButton("minusSign", bx, fy, M.iconW, M.iconH, "-", function()
                row.counter(-step)
            end, nil, function(dir)
                row.counter(dir)
            end)
            iconButton("plusSign", bx + M.iconW + M.gapX, fy, M.iconW, M.iconH, "+", function()
                row.counter(step)
            end, nil, function(dir)
                row.counter(dir)
            end)
        elseif not row.disabled then
            addBox(fieldX, fy, fw, fh, function()
                if row.list ~= nil then
                    if H.open == row.key then
                        H.open = nil
                    else
                        H.openList(row)
                    end
                elseif row.click ~= nil then
                    row.click()
                end
            end, storageMode and function(dir)
                H.storageScroll = H.storageScroll - dir
            end or nil, row.right)
        end

        if H.open == row.key then
            openRow, openGeo = row, {fieldX, fy, fw, fh}
        end
      end
    end

    -- buttons at the bottom (job editor only)
    if not storageMode then
    local by = bottom + 2 * M.gapY
    local count = d.id ~= 0 and 4 or 2
    local bw = (w - (count + 1) * 2 * M.gapX) / count
    local bx = x + 2 * M.gapX
    textButton(bx, by, bw, buttonH, txt("save"), function()
        H.saveDraft()
    end, 0.3, 0.45, 0.05)
    bx = bx + bw + 2 * M.gapX
    textButton(bx, by, bw, buttonH, txt("cancel"), function()
        H.closeEditor()
    end)
    if d.id ~= 0 then
        bx = bx + bw + 2 * M.gapX
        textButton(bx, by, bw, buttonH, txt("copy"), function()
            H.copyDraft()
        end)
        bx = bx + bw + 2 * M.gapX
        textButton(bx, by, bw, buttonH, txt("resetShort"), function()
            ADJChangeEvent.sendEvent(ADJChangeEvent.OP_RESET, {id = d.id})
        end)
    end
    end

    -- the expanded list is drawn last (on top of everything)
    H.pdArea = nil
    if openRow ~= nil then
        H.drawingList = true
        drawPulldown(openRow, openGeo[1], openGeo[2], openGeo[3], openGeo[4])
        H.drawingList = false
    else
        H.open = nil
    end
    H.occluder = nil
end

-------------------------------------------------------------------------------------------------
-- entry points
-------------------------------------------------------------------------------------------------

function H.onOpen()
    if not H.positionLoaded then
        H.loadPosition()
    end
    parkCache = {}
end

function H.onClose()
    H.open = nil
    H.drag = nil
    H.dnd = nil
end

function H.draw()
    updateMetrics()
    H.boxes = {}
    H.occluder = nil
    H.drawingList = false
    H.dragArea = nil
    if H.view == "edit" and H.draft ~= nil then
        H.drawEditor()
    else
        H.view = "list"
        H.pdArea = nil
        if H.tab == "plan" then
            H.drawPlan()
        elseif H.tab == "storages" then
            H.drawEditor("storages")
        else
            H.drawList()
        end
    end
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

--- mouse cursor was hidden (middle mouse button): no hover, no dragging
function H.onMouseHidden()
    H.mouseX, H.mouseY = -1, -1
    H.dnd = nil
    if H.drag ~= nil then
        H.drag = nil
        H.savePosition()
    end
end

-------------------------------------------------------------------------------------------------
-- info at the mouse cursor: trailer / vehicle under the cursor with its AutoDrive park position
-------------------------------------------------------------------------------------------------

local tip = {time = -math.huge}

--- distance of point (px, py) to the segment a-b (screen units, x scaled by the aspect ratio)
local function segDist(px, py, ax, ay, bx, by)
    local aspect = g_screenAspectRatio or (16 / 9)
    px, ax, bx = px * aspect, ax * aspect, bx * aspect
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local t = l2 > 0 and math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / l2)) or 0
    local cx, cy = ax + t * dx, ay + t * dy
    return math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2)
end

--- the trailer (or AD vehicle) under the cursor; checked every 100 ms
local function vehicleUnderCursor(mx, my)
    local camera = g_cameraManager ~= nil and g_cameraManager:getActiveCamera()
    if camera == nil or camera == 0 then
        return nil
    end
    local cx, cy, cz = getWorldTranslation(camera)
    local best, bestScore = nil, math.huge
    for _, v in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if not v.isDeleted and v.rootNode ~= nil and (v.spec_attachable ~= nil or v.ad ~= nil) then
            local x, y, z = getWorldTranslation(v.rootNode)
            local camDist = MathUtil.vector3Length(x - cx, y - cy, z - cz)
            if camDist < 150 then
                local half = (v.size ~= nil and v.size.length or 6) / 2
                local h = math.min(2.5, (v.size ~= nil and v.size.height or 3) / 2)
                local ax, ay, az = localToWorld(v.rootNode, 0, h, half)
                local bx, by, bz = localToWorld(v.rootNode, 0, h, -half)
                local sax, say, sad = project(ax, ay, az)
                local sbx, sby, sbd = project(bx, by, bz)
                if sad ~= nil and sbd ~= nil and sad > 0 and sad < 1 and sbd > 0 and sbd < 1 then
                    -- the width of the vehicle on screen gets smaller with the distance
                    local width = (v.size ~= nil and v.size.width or 3) / math.max(camDist, 1) * 0.5
                    local d = segDist(mx, my, sax, say, sbx, sby)
                    if d <= math.max(0.015, width) then
                        local score = d + camDist * 0.0005
                        if score < bestScore then
                            best, bestScore = v, score
                        end
                    end
                end
            end
        end
    end
    return best
end

local function parkNameOf(v)
    local idx = nil
    if v.advd ~= nil and type(v.advd.parkDestination) == "number" and v.advd.parkDestination >= 1 then
        idx = v.advd.parkDestination
    elseif v.ad ~= nil and ADJobs.AD ~= nil and ADJobs.AD.GetParkDestination ~= nil then
        local ok, p = pcall(ADJobs.AD.GetParkDestination, ADJobs.AD, v)
        if ok and type(p) == "number" and p >= 1 then
            idx = p
        end
    end
    local marker = idx ~= nil and ADJobs.GM ~= nil and ADJobs.GM:getMapMarkerById(idx) or nil
    return marker ~= nil and marker.name or nil
end

local function tooltipLines(v)
    local lines = {}
    table.insert(lines, {text = ADJobs.getVehicleName(v), bold = true})
    local park = parkNameOf(v)
    table.insert(lines, {text = park ~= nil and txt("tipParkAt", park) or txt("tipNoPark"), color = park ~= nil and C_SPECIAL or C_GREY})
    local attacher = v.getAttacherVehicle ~= nil and v:getAttacherVehicle() or nil
    if attacher ~= nil then
        local root = attacher.getRootVehicle ~= nil and attacher:getRootVehicle() or attacher
        table.insert(lines, {text = txt("attachedTo", ADJobs.getVehicleName(root)), color = C_GREY})
    end
    local uid = v.getUniqueId ~= nil and v:getUniqueId() or nil
    for _, job in ipairs(ADJobs.jobs) do
        if uid ~= nil and job.swapTrailerUid == uid then
            table.insert(lines, {text = txt("tipJobTrailer", tostring(job.name)), color = C_HOVER})
        elseif uid ~= nil and job.vehicleUid == uid then
            table.insert(lines, {text = txt("tipJobVehicle", tostring(job.name)), color = C_HOVER})
        end
    end
    return lines
end

function H.drawWorldTooltip(mx, my)
    updateMetrics()
    if g_time - tip.time > 100 then
        tip.time, tip.mx, tip.my = g_time, mx, my
        tip.vehicle = vehicleUnderCursor(mx, my)
        tip.lines = tip.vehicle ~= nil and tooltipLines(tip.vehicle) or nil
    end
    local lines = tip.lines
    if lines == nil or tip.vehicle == nil or tip.vehicle.isDeleted then
        return
    end
    local lineH = M.py(16)
    local w = 0
    for _, l in ipairs(lines) do
        w = math.max(w, getTextWidth(l.bold and M.font or M.small, l.text))
    end
    w = w + 4 * M.gapX
    local h = #lines * lineH + 2 * M.gapY
    local x = mx + M.px(14)
    local y = my - M.py(10) - h
    if x + w > 1 then
        x = mx - M.px(14) - w
    end
    if y < 0 then
        y = my + M.py(14)
    end
    local occluder = H.occluder
    H.occluder = nil
    drawFilledRect(x, y, w, h, 0, 0, 0, 0.78)
    drawFilledRect(x, y + h - M.py(2), w, M.py(2), C_HOVER[1], C_HOVER[2], C_HOVER[3], 1)
    for i, l in ipairs(lines) do
        local ly = y + h - M.gapY - i * lineH
        drawText(x + 2 * M.gapX, textY(ly, lineH, l.bold and M.font or M.small), l.bold and M.font or M.small, l.text, l.color or C_TEXT, l.bold == true)
    end
    H.occluder = occluder
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

--- numbers L1, L2 ... above all storages near the camera (HUD button "L#"): name, contents and the AD
--- targets this storage is set for
function H.drawStorageNumbers()
    updateMetrics()
    local camera = g_cameraManager ~= nil and g_cameraManager:getActiveCamera()
    if camera == nil or camera == 0 then
        return
    end
    local cx, cy, cz = getWorldTranslation(camera)
    local assigned = {}
    for name, key in pairs(ADJobs.markerSources or {}) do
        local e = ADJobs.getStorageByUid(key)
        if e ~= nil then
            assigned[e.p] = assigned[e.p] or {}
            table.insert(assigned[e.p], name)
        end
    end
    for _, e in ipairs(ADJobs.getStoragePlaceables()) do
        local x, y, z = ADJobs.getStorageLabelPos(e.p)
        local dist = MathUtil.vector3Length(x - cx, y - cy, z - cz)
        if dist < 300 then
            local sx, sy, sd = project(x, y, z)
            if sd ~= nil and sd > 0 and sd < 1 and sx > 0 and sx < 1 and sy > 0 and sy < 1 then
                local lines = {{text = "L" .. e.num, size = M.font * (dist < 80 and 1.9 or 1.4), color = C_HOVER, bold = true}}
                if dist < 150 then
                    table.insert(lines, {text = tostring(e.p.getName ~= nil and e.p:getName() or "?"), size = M.small, color = C_TEXT, bold = true})
                    table.insert(lines, {text = contentsText(e.p, 3), size = M.small, color = C_GREY})
                end
                local names = assigned[e.p]
                if names ~= nil then
                    table.sort(names)
                    table.insert(lines, {text = "<- " .. table.concat(names, ", "), size = M.small, color = C_SPECIAL, bold = true})
                end
                local bw, bh = 0, 0
                for _, l in ipairs(lines) do
                    setTextBold(l.bold == true)
                    bw = math.max(bw, getTextWidth(l.size, l.text))
                    bh = bh + l.size * 1.15
                end
                bw = bw + 4 * M.gapX
                bh = bh + 2 * M.gapY
                local bx, by = sx - bw / 2, sy
                drawFilledRect(bx, by, bw, bh, 0, 0, 0, 0.6)
                drawFilledRect(bx, by, M.px(2), bh, C_HOVER[1], C_HOVER[2], C_HOVER[3], 0.9)
                local ty = by + bh - M.gapY
                for _, l in ipairs(lines) do
                    ty = ty - l.size * 1.15
                    setTextBold(l.bold == true)
                    setTextColor(l.color[1], l.color[2], l.color[3], l.color[4] or 1)
                    setTextAlignment(RenderText.ALIGN_CENTER)
                    renderText(sx, ty + l.size * 0.15, l.size, l.text)
                end
            end
        end
    end
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

function H.isMouseOver()
    return inArea(H.area, H.mouseX, H.mouseY) or (H.open ~= nil and inArea(H.pdArea, H.mouseX, H.mouseY))
end

local function hit(box, px, py)
    return px >= box.x and px <= box.x + box.w and py >= box.y and py <= box.y + box.h
end

function H.mouseEvent(posX, posY, isDown, isUp, button)
    H.mouseX, H.mouseY = posX, posY

    -- moving the panel
    if H.drag ~= nil then
        if isUp and button == Input.MOUSE_BUTTON_LEFT then
            H.drag = nil
            H.savePosition()
        else
            H.x = posX - H.drag.dx
            H.top = posY - H.drag.dy
        end
        return
    end

    -- drag & drop of a planned job ("Geplant" tab)
    if H.dnd ~= nil then
        local d = H.dnd
        if isUp and button == Input.MOUSE_BUTTON_LEFT then
            H.dnd = nil
            if d.active then
                if inArea(H.area, posX, posY) then
                    H.dropPlan(d, posY)
                end
                return
            end
            -- not moved: an ordinary click (opens the job, see below)
        elseif not isDown and not isUp then
            if not d.active and (math.abs(posY - d.y0) > M.py(5) or math.abs(posX - d.x0) > M.px(5)) then
                d.active = true
            end
            if d.active then
                return
            end
        end
    end

    local inPanel = inArea(H.area, posX, posY)
    local inList = H.open ~= nil and inArea(H.pdArea, posX, posY)

    -- a click next to an expanded list closes it (like in AutoDrive)
    if H.open ~= nil and not inList then
        if isDown and (button == Input.MOUSE_BUTTON_LEFT or button == Input.MOUSE_BUTTON_RIGHT) then
            H.open = nil
            H.swallowUp = true
        end
        return
    end
    if not inPanel and not inList then
        H.swallowUp = nil
        return
    end

    local wheel = 0
    if isDown and button == Input.MOUSE_BUTTON_WHEEL_UP then
        wheel = 1
    elseif isDown and button == Input.MOUSE_BUTTON_WHEEL_DOWN then
        wheel = -1
    end
    if wheel ~= 0 then
        for i = #H.boxes, 1, -1 do
            local box = H.boxes[i]
            if box.onWheel ~= nil and hit(box, posX, posY) then
                box.onWheel(wheel)
                return
            end
        end
        return
    end

    if isDown and button == Input.MOUSE_BUTTON_LEFT and H.dragArea ~= nil and hit(H.dragArea, posX, posY) then
        H.drag = {dx = posX - H.x, dy = posY - H.top}
        return
    end

    -- left button down on a planned job: it may be dragged (it becomes a drag once the mouse moves)
    if isDown and button == Input.MOUSE_BUTTON_LEFT and H.view == "list" and H.tab == "plan" then
        for i = #H.boxes, 1, -1 do
            local box = H.boxes[i]
            if hit(box, posX, posY) then
                if box.dnd ~= nil then
                    H.dnd = {id = box.dnd.id, veh = box.dnd.veh, name = box.dnd.name, x0 = posX, y0 = posY, active = false}
                end
                break
            end
        end
    end

    if isUp and (button == Input.MOUSE_BUTTON_LEFT or button == Input.MOUSE_BUTTON_RIGHT) then
        if H.swallowUp then
            H.swallowUp = nil
            return
        end
        local right = button == Input.MOUSE_BUTTON_RIGHT
        for i = #H.boxes, 1, -1 do
            local box = H.boxes[i]
            if hit(box, posX, posY) then
                local fn = right and box.onRight or box.onClick
                if fn ~= nil then
                    fn()
                    return
                end
            end
        end
    end
end
