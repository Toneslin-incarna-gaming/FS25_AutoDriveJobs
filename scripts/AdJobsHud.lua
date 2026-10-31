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

--- shortens a text to maxWidth with ".." (binary search over UTF-8 characters, few getTextWidth calls)
local function fit(text, maxWidth, size)
    text = tostring(text or "")
    if maxWidth <= 0 then
        return ""
    end
    if getTextWidth(size, text) <= maxWidth then
        return text
    end
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
    return table.concat(chars, "", 1, lo) .. ".."
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
    table.insert(H.boxes, {x = x, y = y, w = w, h = h, onClick = onClick, onWheel = onWheel, onRight = onRight})
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
        iconButton(b[1], bx, by, M.headW, M.headH, b[2], b[3])
        bx = bx - M.headW - M.gapX
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
    elseif s == ADJobs.ST_RUN or s == ADJobs.ST_STOPPING or s == ADJobs.ST_TOPARK or s == ADJobs.ST_DUMP then
        return {0.4, 0.9, 1, 1}
    elseif s == ADJobs.ST_NOTREADY or s == ADJobs.ST_PAUSE then
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
        if e.dist <= ADJobs.PARK_DISTANCE then
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
        if p < (job.low or 0) then
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
    if job.driveMode == "load" then
        local back = (job.unloadMarker ~= nil and job.unloadMarker ~= "") and job.unloadMarker or txt("autoShort")
        return txt("line2Load", job.loadMarker or "?", back)
    end
    return string.format("%s  ->  %s", job.loadMarker or "?", job.unloadMarker or "?")
end

function H.drawList()
    local jobs = ADJobs.jobs
    -- hover hint of the previous frame is shown in the header (like the AutoDrive tool tips)
    local tooltip = H.nextTooltip
    H.nextTooltip = nil
    H.tooltip = tooltip
    local count = #jobs
    H.listScroll = math.max(0, math.min(H.listScroll, math.max(0, count - MAX_JOB_ROWS)))
    local shown = math.min(MAX_JOB_ROWS, count)
    local bodyH = count == 0 and M.rowH * 1.4 or shown * M.jobH
    local totalH = M.headerH + bodyH + 2 * M.gapY
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
    if count > MAX_JOB_ROWS then
        title = string.format("%s  (%d-%d / %d)", title, H.listScroll + 1, H.listScroll + shown, count)
    end
    drawHeader(x, top, w, title, {
        {"input_toggleHud_1", "X", function()
            ADJobs.toggleHud()
        end},
        {"plusSign", "+", function()
            H.newJob()
        end},
    })

    if count == 0 then
        drawText(x + 2 * M.gapX, textY(bottom + M.gapY, bodyH, M.font), M.font, fit(txt("noJobs"), w - 4 * M.gapX, M.font), C_GREY)
        return
    end

    local barW, barH = M.px(78), M.py(15)
    for i = 1, shown do
        local job = jobs[i + H.listScroll]
        local rowTop = top - M.headerH - M.gapY - (i - 1) * M.jobH
        local rowY = rowTop - M.jobH
        if i % 2 == 0 then
            drawFilledRect(x, rowY, w, M.jobH, 1, 1, 1, 0.04)
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
        local swX, swY, swW, swH = x + M.gapX, rowY + M.gapY, M.iconW, M.jobH - 2 * M.gapY
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
        local barX = bx - 2 * M.gapX - barW
        drawLevelBar(job, barX, rowTop - M.gapY - M.py(1) - barH, barW, barH)

        -- texts
        local tx = x + 3 * M.gapX + M.iconW
        local c = job.active and C_TEXT or C_GREY
        local y1 = rowTop - M.py(15)
        local maxW1 = barX - tx - 2 * M.gapX
        local name = fit(job.name, maxW1 * 0.55, M.font)
        drawText(tx, y1, M.font, name, rowHover and C_HOVER or c, true)
        local nameW = getTextWidth(M.font, name) + 3 * M.gapX
        local what = string.format("%s: %s", tostring(job.placeableName or "?"), ADJobs.getMeasureLabel(job))
        drawText(tx + nameW, y1, M.small, fit(what, maxW1 - nameW, M.small), C_GREY)

        local limits
        if job.driveMode == "load" then
            limits = string.format("%s   %s %d (%s)", txt("limitLoad", math.floor(job.low or 0)), txt("colTrips"), job.tripsDone or 0, txt("tripsTotal", job.tripsTotal or 0))
        else
            local trips = (job.maxTrips or 0) > 0 and string.format("%d/%d", job.tripsDone or 0, job.maxTrips) or string.format("%d", job.tripsDone or 0)
            trips = trips .. string.format(" (%s)", txt("tripsTotal", job.tripsTotal or 0))
            limits = string.format("%d / %d %%   %s %s", math.floor(job.low or 0), math.floor(job.high or 0), txt("colTrips"), trips)
        end
        local y2 = rowTop - M.py(31)
        local vehText, implText, hasImpl = jobVehicleLine(job)
        local maxW2 = x + w - tx - 2 * M.gapX
        vehText = fit(vehText, implText ~= nil and maxW2 * 0.6 or maxW2, M.small)
        drawText(tx, y2, M.small, vehText, c)
        if implText ~= nil then
            local ix = tx + getTextWidth(M.small, vehText) + 2 * M.gapX
            drawText(ix, y2, M.small, fit(implText, tx + maxW2 - ix, M.small), hasImpl and C_SPECIAL or {1, 0.8, 0.3, 1})
        end

        local y3 = rowTop - M.py(46)
        drawText(tx, y3, M.small, fit(jobTargetLine(job), x + w - tx - 2 * M.gapX, M.small), c)

        -- status left, limits and trips right
        local y4 = rowTop - M.py(61)
        local limitsW = math.min(getTextWidth(M.small, limits), (x + w - tx) * 0.55)
        drawText(x + w - 2 * M.gapX, y4, M.small, fit(limits, limitsW, M.small), C_GREY, false, RenderText.ALIGN_RIGHT)
        drawText(tx, y4, M.small, fit(ADJobs.getStatusText(job), x + w - tx - limitsW - 5 * M.gapX, M.small), statusColor(job), true)
    end

    -- scroll bar
    if count > MAX_JOB_ROWS then
        local trackY, trackH = bottom + M.gapY, bodyH
        local thumbH = trackH * MAX_JOB_ROWS / count
        local thumbY = trackY + trackH - thumbH - (trackH - thumbH) * H.listScroll / (count - MAX_JOB_ROWS)
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
                table.insert(entries, {label = tostring(placeable:getName()), sub = string.format("%d m", math.floor(dist)), sort = dist,
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
        {label = txt("modeDeliverShort"), value = "deliver", sort = 1, selected = d.driveMode ~= "load"},
        {label = txt("modeLoadShort"), value = "load", sort = 2, selected = d.driveMode == "load"},
    }
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
                if wp ~= nil then
                    local x, _, z = getWorldTranslation(v.rootNode)
                    if MathUtil.vector2Length(x - wp.x, z - wp.z) <= ADJobs.PARK_DISTANCE then
                        atPark = true
                    end
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

local function loadEntries(d)
    local entries = {}
    for _, m in ipairs(getMarkers()) do
        table.insert(entries, {label = m.name, value = m.name, sort = m.name:lower(), group = m.group, selected = m.name == d.loadMarker})
    end
    return sortEntries(entries, {txt("grpDefault")})
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
    H.draft = {id = 0, active = true, low = 30, high = 90, maxTrips = 0, pauseMin = 10, driveMode = "deliver",
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

function H.closeEditor()
    H.view = "list"
    H.draft = nil
    H.open = nil
end

local function missingFields(d)
    local missing = {}
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
    return missing
end

function H.saveDraft()
    local d = H.draft
    if d == nil then
        return
    end
    if next(missingFields(d)) ~= nil then
        H.showMissing = true
        warn("missing")
        return
    end
    if d.driveMode ~= "load" and d.high <= d.low then
        d.high = math.min(100, d.low + 1)
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
    ADJChangeEvent.sendEvent(ADJChangeEvent.OP_SAVE, d)
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, txt("wizSaved", d.name or ""))
    H.closeEditor()
end

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

    table.insert(rows, {key = "active", icon = d.active ~= false and "input_start_stop_2" or "input_start_stop_1", fb = "I", label = txt("fActive"),
        value = d.active ~= false and txt("activeYes") or txt("activeNo"), click = function()
            d.active = d.active == false
        end})

    table.insert(rows, {key = "object", icon = "tipper_load", fb = "O", label = txt("fObject"), value = d.placeableName, list = objectEntries,
        select = function(e)
            local obj = e.value
            local isVehicle = obj.isVehicle or obj.spec_fillUnit ~= nil or obj.getRootVehicle ~= nil
            d.placeableObject = obj
            d.placeableName = isVehicle and ADJobs.getVehicleName(obj) or obj:getName()
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
        value = loadMode and txt("modeLoadShort") or txt("modeDeliverShort"), list = modeEntries,
        select = function(e)
            d.driveMode = e.value
            if e.value == "load" and d.unloadMarker == nil then
                d.unloadMarker = ""
            elseif e.value ~= "load" and d.unloadMarker == "" then
                d.unloadMarker = nil
            end
        end})

    local parkValue = nil
    if (d.parkMarker or "") ~= "" then
        local vehicles = parkVehicleText(d.parkMarker, d.farmId)
        parkValue = string.format("%s  -  %s", d.parkMarker, vehicles)
    end
    table.insert(rows, {key = "park", icon = "input_parkVehicle_1", fb = "P", label = txt("fPark"), value = parkValue, list = parkEntries,
        emptyText = txt("noParks"),
        select = function(e)
            d.parkMarker = e.value
            parkCache = {}
        end})

    local ftValue = (d.loadFillTypeName or "") == "" and txt("keepFtShort") or fillTypeTitle(d.loadFillTypeName)
    table.insert(rows, {key = "loadFt", icon = "input_toggleLoadByFillLevel_1", fb = "L", label = txt("fLoadFt"), value = ftValue, list = fillTypeEntries,
        disabled = (d.sourceKind or "") == "",
        select = function(e)
            d.loadFillTypeName = e.value
        end})

    table.insert(rows, {key = "load", icon = "marker", fb = "1", label = txt("fLoad"), value = d.loadMarker, list = loadEntries,
        select = function(e)
            d.loadMarker = e.value
            if d.unloadMarker == e.value then
                d.unloadMarker = loadMode and "" or nil
            end
        end})

    local unloadValue = d.unloadMarker
    if loadMode and (unloadValue or "") == "" then
        unloadValue = txt("autoShort")
    end
    table.insert(rows, {key = "unload", icon = "input_toggleAutomaticUnloadTarget_1", fb = "2", label = loadMode and txt("fReturn") or txt("fUnload"),
        value = unloadValue, list = unloadEntries,
        select = function(e)
            d.unloadMarker = e.value
        end})

    if not loadMode then
        -- where a rest goes if too much was loaded and no other job with the same fill type has space
        local emValue = (d.emergencyMarker or "") ~= "" and d.emergencyMarker or txt("emergencyNone")
        table.insert(rows, {key = "emergency", icon = "warn_icon", fb = "!", label = txt("fEmergency"), value = emValue, list = emergencyEntries,
            select = function(e)
                d.emergencyMarker = e.value
            end})
    end

    table.insert(rows, {key = "low", icon = "input_toggleLoadByFillLevel_2", fb = "<", label = txt("fLow"),
        value = string.format("%d %%", math.floor(d.low or 0)),
        counter = function(delta)
            d.low = math.max(0, math.min(loadMode and 100 or 99, math.floor((d.low or 0) + delta)))
            if not loadMode and (d.high or 0) <= d.low then
                d.high = math.min(100, d.low + 1)
            end
        end, step = 5})

    if not loadMode then
        table.insert(rows, {key = "high", icon = "input_toggleLoadByFillLevel_3", fb = ">", label = txt("fHigh"),
            value = string.format("%d %%", math.floor(d.high or 0)),
            counter = function(delta)
                d.high = math.max((d.low or 0) + 1, math.min(100, math.floor((d.high or 0) + delta)))
            end, step = 5})
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

function H.drawEditor()
    local d = H.draft
    local rows = editorRows(d)
    local missing = H.showMissing and missingFields(d) or {}
    local buttonH = M.py(24)
    local totalH = M.headerH + M.gapY + #rows * M.rowH + M.gapY * 2 + buttonH + M.gapY * 2
    clampPosition(totalH)
    local x, top, w = H.x, H.top, M.w
    local bottom = top - totalH
    H.area = {x = x, y = bottom, w = w, h = totalH}
    drawBackground(x, bottom, w, totalH)
    addBox(x, bottom, w, totalH, function()
    end)

    drawHeader(x, top, w, d.id == 0 and txt("hudNew") or string.format("%s: %s", txt("hudEdit"), tostring(d.name)), {
        {"input_toggleHud_1", "X", function()
            H.closeEditor()
        end},
    })

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
            local rowTop = top - M.headerH - M.gapY - (i - 1) * M.rowH
            local iy = rowTop - (M.rowH - M.iconH) / 2 - M.iconH
            local _, _, ly, listH = pulldownGeometry(row, fieldX, iy, fieldW, M.iconH)
            H.occluder = {x = fieldX, y = ly, w = x + w - fieldX, h = listH}
        end
    end
    for i, row in ipairs(rows) do
        local rowTop = top - M.headerH - M.gapY - (i - 1) * M.rowH
        local iy = rowTop - (M.rowH - M.iconH) / 2 - M.iconH
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
            end)
        end

        if H.open == row.key then
            openRow, openGeo = row, {fieldX, fy, fw, fh}
        end
    end

    -- buttons at the bottom
    local by = bottom + 2 * M.gapY
    local count = d.id ~= 0 and 3 or 2
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
        textButton(bx, by, bw, buttonH, txt("resetShort"), function()
            ADJChangeEvent.sendEvent(ADJChangeEvent.OP_RESET, {id = d.id})
        end)
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
        H.drawList()
    end
    setTextBold(false)
    setTextColor(1, 1, 1, 1)
    setTextAlignment(RenderText.ALIGN_LEFT)
end

--- mouse cursor was hidden (middle mouse button): no hover, no dragging
function H.onMouseHidden()
    H.mouseX, H.mouseY = -1, -1
    if H.drag ~= nil then
        H.drag = nil
        H.savePosition()
    end
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
