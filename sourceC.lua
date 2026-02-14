-- sDrugRework/sourceC.lua

local placing = false
local placingData = nil
local ghostObj = nil
local ghostRotZ = 0


-- =========================================
-- placed workbenches client-side list
-- =========================================
local placedBenches = {} -- { obj=element, benchType=string, itemId=int, dbID=int }
local placedById = {} -- [id] = entry

local function destroyGhost()
    if isElement(ghostObj) then
        destroyElement(ghostObj)
    end
    ghostObj = nil
end

-- forward declarations (because removeEventHandler uses function refs)
local renderPlacement
local confirmPlacement
local cancelPlacement
local ROT_STEP = 1

local function rotateGhost(dir)
    if not placing or not isElement(ghostObj) then return end
    ghostRotZ = (ghostRotZ + (ROT_STEP * dir)) % 360
end

local function onMouseWheelUp()
    rotateGhost(1)
end

local function onMouseWheelDown()
    rotateGhost(-1)
end

local function stopPlacement()
    placing = false
    placingData = nil
    destroyGhost()
    removeEventHandler("onClientRender", root, renderPlacement)
    unbindKey("mouse1", "down", confirmPlacement)
    unbindKey("backspace", "down", cancelPlacement)
    unbindKey("mouse_wheel_up", "down", onMouseWheelUp)
    unbindKey("mouse_wheel_down", "down", onMouseWheelDown)
end

cancelPlacement = function()
    stopPlacement()
    exports.sGui:showInfobox("i", "Elhelyezés megszakítva.")
end

local function getCursorHitPosition()
    local cx, cy = getCursorPosition()
    if not cx then return nil end

    local sx, sy = guiGetScreenSize()
    cx, cy = cx * sx, cy * sy

    local camX, camY, camZ = getCameraMatrix()
    local wx, wy, wz = getWorldFromScreenPosition(cx, cy, 200)

    local hit, hx, hy, hz = processLineOfSight(
        camX, camY, camZ,
        wx, wy, wz,
        true, true, true, true, true, false, false, false,
        ghostObj
    )

    if hit then
        return hx, hy, hz
    end
    return nil
end

renderPlacement = function()
    if not placing or not placingData then return end
    if not isElement(ghostObj) then return end

    local x, y, z = getCursorHitPosition()
    if x then
        setElementPosition(ghostObj, x, y, z)
        setElementRotation(ghostObj, 0, 0, ghostRotZ)
    else
        -- fallback: in front of player
        local px, py, pz = getElementPosition(localPlayer)
        local _, _, prz = getElementRotation(localPlayer)
        local rad = math.rad(prz)
        local fx, fy = px + math.cos(rad) * 1.2, py + math.sin(rad) * 1.2
        setElementPosition(ghostObj, fx, fy, pz - 0.5)
        setElementRotation(ghostObj, 0, 0, ghostRotZ)
    end
end

confirmPlacement = function()
    if not placing or not placingData or not isElement(ghostObj) then return end

    local x, y, z = getElementPosition(ghostObj)

    triggerServerEvent("sDrugRework:placeWorkbench", resourceRoot, {
        x = x, y = y, z = z,
        rz = ghostRotZ,
        benchType = placingData.benchType,
        itemId = placingData.itemId,
        dbID = placingData.dbID
    })

    stopPlacement()
end

-- =========================================
-- Start placement from server
-- =========================================
addEvent("sDrugRework:startPlacement", true)
addEventHandler("sDrugRework:startPlacement", resourceRoot, function(data)
    if placing then
        cancelPlacement()
    end

    if type(data) ~= "table" then return end
    local benchType = tostring(data.benchType or "")
    if benchType == "" then return end

    local modelName = getWorkbenchModelName(benchType)
    if not modelName then
        exports.sGui:showInfobox("e", "Nincs model definiálva ehhez az asztalhoz!")
        return
    end

    local modelId = exports.sModloader:getModelId(modelName)
    if not modelId then
        exports.sGui:showInfobox("e", "Nem található a modell: " .. modelName)
        return
    end

    placing = true
    placingData = data
    ghostRotZ = select(3, getElementRotation(localPlayer)) or 0

    local px, py, pz = getElementPosition(localPlayer)
    ghostObj = createObject(modelId, px, py, pz)
    setElementInterior(ghostObj, getElementInterior(localPlayer))
    setElementDimension(ghostObj, getElementDimension(localPlayer))
    setElementAlpha(ghostObj, 160)
    setElementCollisionsEnabled(ghostObj, false)

    addEventHandler("onClientRender", root, renderPlacement)
    bindKey("mouse1", "down", confirmPlacement)
    bindKey("backspace", "down", cancelPlacement)
    bindKey("mouse_wheel_up", "down", onMouseWheelUp)
    bindKey("mouse_wheel_down", "down", onMouseWheelDown)

    exports.sGui:showInfobox("i", "Mozgasd az egeret, bal klikk: lerakás, Backspace: megszakítás.")
end)

-- =========================================
-- Create placed bench (client-side object)
-- =========================================
local function removePlacedWorkbenchById(id)
    local entry = placedById[id]
    if not entry then return false end

    if isElement(entry.obj) then
        destroyElement(entry.obj)
    end

    -- remove from array list
    for i = #placedBenches, 1, -1 do
        if placedBenches[i] and placedBenches[i].id == id then
            table.remove(placedBenches, i)
            break
        end
    end

    placedById[id] = nil
    return true
end

addEvent("sDrugRework:createPlacedWorkbench", true)
addEventHandler("sDrugRework:createPlacedWorkbench", resourceRoot, function(data)
    if type(data) ~= "table" then return end
    if not data.id or not data.benchType then return end
    if type(data.x) ~= "number" or type(data.y) ~= "number" or type(data.z) ~= "number" then return end

    local modelName = getWorkbenchModelName(data.benchType)
    if not modelName then return end

    local modelId = exports.sModloader:getModelId(modelName)
    if not modelId then return end

    -- If this bench already exists client-side, replace it (prevents duplicates)
    if placedById[data.id] then
        removePlacedWorkbenchById(data.id)
    end

    local obj = createObject(modelId, data.x, data.y, data.z)
    if not isElement(obj) then return end

    setElementRotation(obj, 0, 0, tonumber(data.rz) or 0)
    setElementInterior(obj, tonumber(data.interior) or 0)
    setElementDimension(obj, tonumber(data.dimension) or 0)

    -- Element data (synced false, as you had)
    setElementData(obj, "drugworkbench", true, false)
    setElementData(obj, "drugworkbench.type", data.benchType, false)
    setElementData(obj, "drugworkbench.id", data.id, false)

    local entry = {
        obj = obj,
        benchType = data.benchType,
        id = data.id
    }

    table.insert(placedBenches, entry)
    placedById[data.id] = entry
end)

-- Clean up all spawned benches if resource stops/restarts
addEventHandler("onClientResourceStop", resourceRoot, function()
    for i = #placedBenches, 1, -1 do
        local entry = placedBenches[i]
        if entry and isElement(entry.obj) then
            destroyElement(entry.obj)
        end
        placedBenches[i] = nil
    end
    placedById = {}
end)

-- #############################################
-- Workbench Icons (sGui + FontAwesome)
--  - Mortar & Pestle (left)
--  - Extract (tint / drop) (middle)
--  - Dry (wind) (right)
--  - Pick up Workbench (inbox-out) (below middle)
-- #############################################

local wbIcons = {
    root = false,
    bench = false,
    elements = {},
    visible = false
}

local currentIconBench = false

-- Tweakables
local ICON_SIZE = 34
local ICON_GAP  = 10
local ROW_Y_OFF = -35          -- row is slightly above the "anchor point"
local PICKUP_Y_OFF = 8         -- below the middle icon
local WORLD_Z_OFFSET = 0.95    -- how high above the bench to place the icons (meters)
local SHOW_DIST = 2.0          -- show icons when player is close
local SIDE_EXTRA_GAP = 15

-- FontAwesome icon names (solid set by default)
-- NOTE: If any name doesn't exist in your FA pack, sGui will fall back to "times".
local FA = {
    mortar = "mortar-pestle",
    extract = "tint",
    dry = "wind",
    pickup = "inbox-out",
}

local TOOLTIPS = {
    mortar = "Mortar & Pestle",
    extract = "Extract",
    dry = "Dry",
    pickup = "Pick up Workbench",
}

-- Utility: create one icon button
local function createIcon(parent, faName, tooltipText, clickArg)
    local el = exports.sGui:createGuiElement("image", 0, 0, ICON_SIZE, ICON_SIZE, parent)

    local file = exports.sGui:getFaIconFilename(faName, ICON_SIZE, "solid")
    exports.sGui:setImageFile(el, file)

    exports.sGui:setGuiHoverable(el, true)
    exports.sGui:setImageFadeHover(el, false)
    exports.sGui:guiSetTooltip(el, tooltipText, "right", "down")

    -- We DO NOT call setClickEvent / setClickArgument at all.
    -- We'll handle click via hover detection.
    wbIcons.byEl = wbIcons.byEl or {}
    wbIcons.byEl[el] = clickArg

    return el
end

local function destroyWorkbenchIcons()
    if wbIcons.root and exports.sGui:isGuiElementValid(wbIcons.root) then
        exports.sGui:deleteGuiElement(wbIcons.root)
    end
    wbIcons.root = false
    wbIcons.bench = false
    wbIcons.elements = {}
    wbIcons.visible = false
    wbIcons.byEl = {}
    currentIconBench = false
end

local function showWorkbenchIconsForBench(benchObj)
    destroyWorkbenchIcons()

    wbIcons.bench = benchObj
    currentIconBench = benchObj
    wbIcons.root = exports.sGui:createGuiElement("null", 0, 0, 1, 1) -- container with children :contentReference[oaicite:14]{index=14}

    -- Build 3 icons row + 1 below middle
    local mortar = createIcon(wbIcons.root, FA.mortar, TOOLTIPS.mortar, "mortar")
    local extract = createIcon(wbIcons.root, FA.extract, TOOLTIPS.extract, "extract")
    local dry = createIcon(wbIcons.root, FA.dry, TOOLTIPS.dry, "dry")
    local pickup = createIcon(wbIcons.root, FA.pickup, TOOLTIPS.pickup, "pickup")

    wbIcons.elements = {
        mortar = mortar,
        extract = extract,
        dry = dry,
        pickup = pickup
    }

    wbIcons.visible = true
end

-- Anchor update: keep icons positioned over the bench in screen space
local function updateWorkbenchIcons()
    if not wbIcons.visible or not isElement(wbIcons.bench) then
        destroyWorkbenchIcons()
        return
    end

    -- If player walks away, hide them (for now)
    local px, py, pz = getElementPosition(localPlayer)
    local bx, by, bz = getElementPosition(wbIcons.bench)
    if getDistanceBetweenPoints3D(px, py, pz, bx, by, bz) > SHOW_DIST then
        destroyWorkbenchIcons()
        return
    end

    -- Project bench world point to screen
    local sx, sy = getScreenFromWorldPosition(bx, by, bz + WORLD_Z_OFFSET)
    if not sx or not sy then
        -- off-screen
        return
    end

    -- Layout:
    -- [mortar] [extract] [dry]
    --          [pickup]
    local totalW = ICON_SIZE * 3 + ICON_GAP * 2 + SIDE_EXTRA_GAP * 2
    local startX = sx - totalW / 2
    local rowY = sy + ROW_Y_OFF

    exports.sGui:setGuiPosition(wbIcons.elements.mortar, startX, rowY) -- :contentReference[oaicite:15]{index=15}
    exports.sGui:setGuiPosition(wbIcons.elements.extract, startX + ICON_SIZE + ICON_GAP + SIDE_EXTRA_GAP, rowY) -- :contentReference[oaicite:16]{index=16}
    exports.sGui:setGuiPosition(wbIcons.elements.dry, startX + (ICON_SIZE + ICON_GAP) * 2 + SIDE_EXTRA_GAP * 2, rowY) -- :contentReference[oaicite:17]{index=17}

    -- pickup under the center icon
    local pickupX = startX + ICON_SIZE + ICON_GAP + SIDE_EXTRA_GAP
    exports.sGui:setGuiPosition(wbIcons.elements.pickup, pickupX, rowY + ICON_SIZE + PICKUP_Y_OFF) -- :contentReference[oaicite:18]{index=18}
end

addEventHandler("onClientRender", root, function()
    if wbIcons.visible then
        updateWorkbenchIcons()
    end
end)

addEventHandler("onClientClick", root, function(button, state)
    if button ~= "left" or state ~= "up" then return end
    if not wbIcons.visible then return end
    if not isCursorShowing() then return end

    local hoverEl = exports.sGui:getGuiHoverElement()  -- returns sGui element id (number)
    if not hoverEl or not wbIcons.byEl or not wbIcons.byEl[hoverEl] then return end

    local arg = wbIcons.byEl[hoverEl]

    if arg == "mortar" then
       exports.sGui:showInfobox("i", "Extract clicked (UI later).")  
elseif arg == "extract" then
        exports.sGui:showInfobox("i", "Extract clicked (UI later).")

    elseif arg == "dry" then
        exports.sGui:showInfobox("i", "Dry clicked (UI later).")

    elseif arg == "pickup" then
        if not currentIconBench or not isElement(currentIconBench) then
            exports.sGui:showInfobox("e", "Nincs asztal a közelben!")
            return
        end

        local benchId = tonumber(getElementData(currentIconBench, "drugworkbench.id"))
        if not benchId then
            exports.sGui:showInfobox("e", "Hibás asztal azonosító!")
            return
        end

        triggerServerEvent("sDrugRework:pickupWorkbench", resourceRoot, benchId)
    end
end)

-- ################################################
-- DEMO hook:
-- Call this when you detect the player is near a bench,
-- or temporarily call it manually for testing.
-- ################################################
function sDrugRework_showIconsForNearestWorkbench()
    local px, py, pz = getElementPosition(localPlayer)
    local nearest, bestDist = nil, 999

    -- If you already have placedBenches in your sourceC.lua,
    -- you can iterate those instead of scanning all objects.
    for _, obj in ipairs(getElementsByType("object", root, true)) do
        if getElementData(obj, "drugworkbench.id") then
            local x, y, z = getElementPosition(obj)
            local d = getDistanceBetweenPoints3D(px, py, pz, x, y, z)
            if d < bestDist then
                bestDist = d
                nearest = obj
            end
        end
    end

    if nearest and bestDist <= SHOW_DIST then
        showWorkbenchIconsForBench(nearest)
    end
end

-- =========================================
-- Near workbench detection (client)
-- Shows the 4 icon buttons when near a bench.
-- =========================================

local ICON_SHOW_DIST = 2.0
local NEAR_SCAN_MS = 200

local function getNearestWorkbench(maxDist)
    local px, py, pz = getElementPosition(localPlayer)
    local pint = getElementInterior(localPlayer)
    local pdim = getElementDimension(localPlayer)

    local bestEntry, bestDist = nil, maxDist or 9999

    for i = 1, #placedBenches do
        local entry = placedBenches[i]
        if entry and isElement(entry.obj) then
            if getElementInterior(entry.obj) == pint and getElementDimension(entry.obj) == pdim then
                local x, y, z = getElementPosition(entry.obj)
                local d = getDistanceBetweenPoints3D(px, py, pz, x, y, z)
                if d < bestDist then
                    bestDist = d
                    bestEntry = entry
                end
            end
        end
    end

    return bestEntry, bestDist
end

-- We’ll use these two functions from the icon module you already have / will have:
-- showWorkbenchIconsForBench(obj)
-- destroyWorkbenchIcons()
--
-- If you kept them local in another file, expose wrappers like:
-- sDrugReworkShowWorkbenchIcons(obj), sDrugReworkHideWorkbenchIcons()

setTimer(function()
    if placing then
        if currentIconBench then
            destroyWorkbenchIcons()
            currentIconBench = false
        end
        return
    end

    -- Only show icons if player is in cursor mode
    if not isCursorShowing() then
        if currentIconBench then
            destroyWorkbenchIcons()
            currentIconBench = false
        end
        return
    end

    local nearest, dist = getNearestWorkbench(ICON_SHOW_DIST)
    if nearest and isElement(nearest.obj) then
        if currentIconBench ~= nearest.obj then
            showWorkbenchIconsForBench(nearest.obj)
            currentIconBench = nearest.obj
        end
    else
        if currentIconBench then
            destroyWorkbenchIcons()
            currentIconBench = false
        end
    end
end, NEAR_SCAN_MS, 0)


addEvent("sDrugRework:removePlacedWorkbench", true)
addEventHandler("sDrugRework:removePlacedWorkbench", resourceRoot, function(id)
    id = tonumber(id)
    if not id then return end

    -- If your icons are currently attached to this bench, hide them
    if currentIconBench and isElement(currentIconBench) then
        local bid = getElementData(currentIconBench, "drugworkbench.id")
        if tonumber(bid) == id then
            destroyWorkbenchIcons()
            currentIconBench = false
        end
    end

    removePlacedWorkbenchById(id)
end)