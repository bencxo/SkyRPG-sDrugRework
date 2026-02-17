-- sDrugRework/sourceS.lua
-- make sure this resource has access to exports: sItems, sGui, sModloader (client only) etc.

local connection = exports.sConnection:getConnection()
local loadedBenches = {} -- [id] = row
local dryRacks = {} -- [benchId] = { slots=table, active=bool, startedAt=int, endAt=int, durationSec=int }

local function sendAllBenchesToPlayer(player)
    for _, row in pairs(loadedBenches) do
        triggerClientEvent(player, "sDrugRework:createPlacedWorkbench", resourceRoot, row)
    end
end

addEventHandler("onResourceStart", resourceRoot, function()
    dbQuery(function(qh)
        local res = dbPoll(qh, 0)
        loadedBenches = {}

        if type(res) == "table" then
            for _, row in ipairs(res) do
                -- normalize types
                row.id = tonumber(row.id)
                row.x = tonumber(row.x)
                row.y = tonumber(row.y)
                row.z = tonumber(row.z)
                row.rz = tonumber(row.rz)
                row.interior = tonumber(row.interior) or 0
                row.dimension = tonumber(row.dimension) or 0

                loadedBenches[row.id] = row
            end
        end
    end, connection, "SELECT id, benchType, x, y, z, rz, interior, dimension FROM drug_workbenches")
    local function loadDryRacks()
        dryRacks = {}

        dbQuery(function(qh)
            local rows = dbPoll(qh, 0) or {}
            for i=1,#rows do
                local r = rows[i]
                local benchId = tonumber(r.benchId)
                if benchId then
                    dryRacks[benchId] = {
                        slots = decodeSlots(r.slotsJson),
                        active = tonumber(r.active) == 1,
                        startedAt = tonumber(r.startedAt) or 0,
                        endAt = tonumber(r.endAt) or 0,
                        durationSec = tonumber(r.durationSec) or (DRY_CFG.DURATION_SEC or 600)
                    }
                end
            end

            -- finalize any expired on boot
            local n = nowUnix()
            for benchId, st in pairs(dryRacks) do
                if st.active and st.endAt > 0 and n >= st.endAt then
                    st.active = false
                    st.startedAt = 0
                    st.endAt = 0
                    -- convert all base slots to output
                    for _, idx in ipairs({1,2,4,5}) do
                        if tonumber(st.slots[idx]) == DRY_CFG.BASE_IN then
                            st.slots[idx] = DRY_CFG.BASE_OUT
                        end
                    end
                    dbExec(connection, "UPDATE drug_drying_racks SET slotsJson=?, active=0, startedAt=0, endAt=0 WHERE benchId=?",
                        encodeSlots(st.slots), benchId
                    )
                end
            end
        end, connection, "SELECT * FROM drug_drying_racks")
    end

    addEventHandler("onResourceStart", resourceRoot, function()
        loadDryRacks()
    end)
end)

addEvent("sDrugRework:clientReady", true)
addEventHandler("sDrugRework:clientReady", resourceRoot, function()
    local player = client
    if not isElement(player) then return end
    sendAllBenchesToPlayer(player)
    -- after sending benches
    for benchId, st in pairs(dryRacks) do
        if st.active and st.endAt and st.endAt > 0 then
            triggerClientEvent(client, "sDrugRework:dryTimerUpdate", resourceRoot, benchId, st.endAt)
        end
    end
end)

local function sitems_hasAtLeast(player, itemId, amount)
    local row = exports.sItems:hasItem(player, itemId) -- IMPORTANT: no amount param
    if not row then return false end
    local have = tonumber(row.amount) or 0
    return have >= (amount or 1)
end

local function sitems_take(player, itemId, amount)
    -- Your takeItem uses (dataType, dataValue, amount)
    exports.sItems:takeItem(player, "itemId", itemId, amount or 1)
    -- cannot trust return value because it returns true only when stack is deleted
    return true
end

local function sitems_give(player, itemId, amount)
    -- use your server's giveItem export name (most likely giveItem)
    if exports.sItems.giveItem then
        return exports.sItems:giveItem(player, itemId, amount or 1)
    end
    return false
end

-- =========================================================
-- Mortar grind server logic
-- =========================================================

local MORTAR_RECIPES = {
    [14]  = { out = 791, ratio = 1 },
    [15]  = { out = 183, ratio = 1 },
    [432] = { out = 184, ratio = 1 },
}

-- pending crafts (items already taken, waiting for minigame finish/cancel)
-- pending[player] = { inId=, inQty=, outId=, outQty= }
local pending = {}

-- =========================================================
-- Drying rack (persistent) - CONFIG
-- =========================================================
local DRY_CFG = {
    BASE_IN  = 793,   -- coca base
    ACETONE  = 794,   -- acetone
    BASE_OUT = 17,  -- TODO: SET THIS to your "dried base" itemId
    DURATION_SEC = 1 * 10, -- 10 minutes
    NEAR_DIST = 4.0
}

local function nowUnix()
    return getRealTime().timestamp
end

local function isPlayerNearBench(player, benchRow)
    if not isElement(player) or not benchRow then return false end
    local px, py, pz = getElementPosition(player)
    return getDistanceBetweenPoints3D(px, py, pz, benchRow.x, benchRow.y, benchRow.z) <= (DRY_CFG.NEAR_DIST or 4.0)
end

local function defaultDrySlots()
    -- 5 slots: 1,2,3(mid),4,5
    return { [1]=false, [2]=false, [3]=false, [4]=false, [5]=false }
end

local function decodeSlots(str)
    if type(str) ~= "string" or str == "" then return defaultDrySlots() end
    local ok, t = pcall(fromJSON, str)
    if not ok or type(t) ~= "table" then return defaultDrySlots() end
    -- normalize missing keys
    for i=1,5 do if t[i] == nil then t[i] = false end end
    return t
end

local function encodeSlots(t)
    return toJSON(t or defaultDrySlots(), true) or toJSON(defaultDrySlots(), true)
end


addEvent("sDrugRework:requestPlaceWorkbench", true)
addEventHandler("sDrugRework:requestPlaceWorkbench", root, function(payload)
    local player = client or source
    if not isElement(player) then return end
    if type(payload) ~= "table" then return end

    local itemId = tonumber(payload.itemId)
    local dbID = tonumber(payload.dbID)
    local benchType = tostring(payload.benchType or "")

    if not itemId or not dbID or benchType == "" then
        return
    end

    -- (Optional) basic sanity: only allow known types
    if not workbenchDefs or not workbenchDefs[benchType] then
        exports.sGui:showInfobox(player, "e", "Ismeretlen vegyi asztal típus!")
        return
    end

    triggerClientEvent(player, "sDrugRework:startPlacement", resourceRoot, {
        itemId = itemId,
        dbID = dbID,
        benchType = benchType
    })
end)

addEvent("sDrugRework:placeWorkbench", true)
addEventHandler("sDrugRework:placeWorkbench", root, function(payload)
    local player = client or source
    if not isElement(player) then return end
    if type(payload) ~= "table" then return end

    local x, y, z = tonumber(payload.x), tonumber(payload.y), tonumber(payload.z)
    local rz = tonumber(payload.rz) or 0
    local benchType = tostring(payload.benchType or "")
    local itemId = tonumber(payload.itemId)
    local dbID = tonumber(payload.dbID)

    if not x or not y or not z or benchType == "" or not itemId or not dbID then
        return
    end

    if not workbenchDefs[benchType] then
        exports.sGui:showInfobox(player, "e", "Ismeretlen vegyi asztal típus!")
        return
    end

    -- remove the exact item instance only now (on successful placement)
    local taken = exports.sItems:takeItem(player, "dbID", dbID, 1)
    if not taken then
        exports.sGui:showInfobox(player, "e", "Nem található az asztal az inventoryban!")
        return
    end

    local interior = getElementInterior(player)
    local dimension = getElementDimension(player)

    dbQuery(function(qh)
        local _, _, insertId = dbPoll(qh, 0)
        insertId = tonumber(insertId)

        if not insertId then
            exports.sGui:showInfobox(player, "e", "Adatbázis hiba (nem mentette el az asztalt)!")
            -- give back item if save fails (safe)
            exports.sItems:giveItem(player, itemId, 1)
            return
        end

        local row = {
            id = insertId,
            benchType = benchType,
            x = x, y = y, z = z,
            rz = rz,
            interior = interior,
            dimension = dimension
        }

        loadedBenches[insertId] = row

        -- send to ALL players (so everyone sees it)
        triggerClientEvent(root, "sDrugRework:createPlacedWorkbench", resourceRoot, row)

    end, connection, "INSERT INTO drug_workbenches (benchType, x, y, z, rz, interior, dimension) VALUES (?,?,?,?,?,?,?)",
        benchType, x, y, z, rz, interior, dimension
    )

end)

addEvent("sDrugRework:pickupWorkbench", true)
addEventHandler("sDrugRework:pickupWorkbench", root, function(benchId)
    local player = client or source
    if not isElement(player) then return end

    benchId = tonumber(benchId)
    if not benchId then return end

    local row = loadedBenches[benchId]
    if not row then
        exports.sGui:showInfobox(player, "e", "Ez az asztal már nem létezik!")
        return
    end

    local benchType = tostring(row.benchType or "")
    local itemId = getWorkbenchItemId(benchType)
    if not itemId then
        exports.sGui:showInfobox(player, "e", "Nincs item definiálva ehhez az asztalhoz!")
        return
    end

    -- Optional inventory space check
    if exports.sItems.hasSpaceForItem and not exports.sItems:hasSpaceForItem(player, itemId, 1) then
        exports.sGui:showInfobox(player, "e", "Nincs hely az inventorydban!")
        return
    end

    dbQuery(function(qh)
        dbPoll(qh, 0)

        loadedBenches[benchId] = nil

        exports.sItems:giveItem(player, itemId, 1)
        exports.sGui:showInfobox(player, "s", "Felvetted a workbenchet.")

        triggerClientEvent(root, "sDrugRework:removePlacedWorkbench", resourceRoot, benchId)
    end, connection, "DELETE FROM drug_workbenches WHERE id = ? LIMIT 1", benchId)
end)



local function countItemAmount(player, itemId)
    local total = 0
    while true do
        local st = exports.sItems:hasItem(player, itemId) -- returns one stack (first match)
        if not st then break end
        total = total + (tonumber(st.amount) or 1)

        -- TEMP HACK: to avoid infinite loop we must stop after one stack,
        -- because hasItem always returns first match.
        -- We will NOT use this for counting across many stacks.
        -- Instead: we will take by dbID in a loop and re-check hasItem as stacks change.
        break
    end
    return total
end

local function takeItemAmountSafe(player, itemId, amount)
    amount = tonumber(amount) or 1
    if amount <= 0 then return true end

    local remaining = amount

    while remaining > 0 do
        local st = exports.sItems:hasItem(player, itemId)
        if not st or not st.dbID then
            return false
        end

        local stackAmt = tonumber(st.amount) or 1
        local takeNow = remaining
        if takeNow > stackAmt then takeNow = stackAmt end

        -- CRITICAL: take by dbID so we don't over-remove multiple stacks
        exports.sItems:takeItem(player, "dbID", st.dbID, takeNow)

        remaining = remaining - takeNow
    end

    return true
end

local function hasEnoughForAmount(player, itemId, amountNeeded)
    amountNeeded = tonumber(amountNeeded) or 1
    if amountNeeded <= 0 then return false end

    -- We cannot reliably count all stacks with hasItem() alone.
    -- But we CAN validate by simulating: check -> take safe -> refund on fail.
    -- That’s heavy and annoying, so instead we do this:
    -- - try to take in a protected way, if it fails, refund what we took.
    -- We'll do real validation in the request handler below.
    return true
end


addEvent("sDrugRework:requestMortarGrind", true)
addEventHandler("sDrugRework:requestMortarGrind", resourceRoot, function(inputId, inputQty)
    local player = client
    if not isElement(player) then return end
    if pending[player] then
        triggerClientEvent(player, "showInfobox", player, "e", "Már folyamatban van egy őrlés!")
        return
    end

    inputId = tonumber(inputId)
    inputQty = tonumber(inputQty) or 1
    if not inputId or inputQty < 1 then return end

    local r = MORTAR_RECIPES[inputId]
    if not r or not r.out then
        triggerClientEvent(player, "showInfobox", player, "e", "Ehhez nincs recept!")
        return
    end

    local outId = tonumber(r.out)
    local ratio = tonumber(r.ratio) or 1
    local outQty = math.max(1, math.floor(inputQty * ratio))

    -- Validate + take input safely.
    -- We'll attempt to take in a loop; if we can't finish, refund what we took.
    local taken = 0
    while taken < inputQty do
        local st = exports.sItems:hasItem(player, inputId)
        if not st or not st.dbID then
            break
        end

        local stackAmt = tonumber(st.amount) or 1
        local need = inputQty - taken
        local takeNow = need
        if takeNow > stackAmt then takeNow = stackAmt end

        exports.sItems:takeItem(player, "dbID", st.dbID, takeNow)
        taken = taken + takeNow
    end

    if taken < inputQty then
        -- refund what we already took
        if taken > 0 then
            exports.sItems:giveItem(player, inputId, taken)
        end
        triggerClientEvent(player, "showInfobox", player, "e", "Nincs alapanyag az őrléshez.")
        return
    end

    pending[player] = { inId = inputId, inQty = inputQty, outId = outId, outQty = outQty }

    triggerClientEvent(player, "sDrugRework:startMortarMinigame", resourceRoot, outId, outQty)
end)

addEvent("sDrugRework:finishMortarGrind", true)
addEventHandler("sDrugRework:finishMortarGrind", resourceRoot, function()
    local player = client
    if not isElement(player) then return end

    local p = pending[player]
    if not p then return end

    exports.sItems:giveItem(player, p.outId, p.outQty)
    pending[player] = nil
end)

addEvent("sDrugRework:cancelMortarGrind", true)
addEventHandler("sDrugRework:cancelMortarGrind", resourceRoot, function()
    local player = client
    if not isElement(player) then return end

    local p = pending[player]
    if not p then return end

    -- Refund input
    exports.sItems:giveItem(player, p.inId, p.inQty)
    pending[player] = nil
end)

addEventHandler("onPlayerQuit", root, function()
    pending[source] = nil
end)

-- =========================================================
-- Extraction server logic
-- =========================================================

-- CONFIG: set these item IDs
local EXTRACT_ITEM_COCA_PASTE   = 182   -- Kokain paszta (your mortar output already uses 182)
local EXTRACT_ITEM_LIGHTER_FLUID = 23    -- TODO: set lighter fluid item ID
-- ===== Stage 2 (Heating) server config =====
local EXTRACT_ITEM_COLD_MIX         = EXTRACT_ITEM_COLD_MIX or 17     -- your cold mix id
local EXTRACT_ITEM_STAGE2_ITEM17    = 17
local EXTRACT_ITEM_BAKING_SODA      = 26
local EXTRACT_ITEM_HEATED_ALKALOID = 50 -- TODO: set your "Hevített Alkaloidkeverék" item ID
local EXTRACT_ITEM_WET_BASE        = 51  -- output (Tiszta Kokain Bázis (Nedves))

-- pendingHeat[player] = { outId=, outQty= }
local pendingHeat = pendingHeat or {}
local pendingExtract = {}
local pendingSep = pendingSep or {}

-- recipeKey -> recipe data
local EXTRACT_RECIPES = {
    -- "kokain bázis" mixing step
    cocaine_base = {
        name = "Kokain bázis",
        inputs = {
            { id = EXTRACT_ITEM_COCA_PASTE, qty = 1 },
            { id = EXTRACT_ITEM_LIGHTER_FLUID, qty = 1 },
        },
        out = { id = EXTRACT_ITEM_COLD_MIX, qty = 1 }
    }
}

-- pendingExtract[player] = { recipeKey=, outId=, outQty= }


local function takeAmountByItemId(player, itemId, qty)
    qty = tonumber(qty) or 1
    if qty <= 0 then return true end

    local taken = 0
    while taken < qty do
        local st = exports.sItems:hasItem(player, itemId)
        if not st or not st.dbID then
            break
        end

        local stackAmt = tonumber(st.amount) or 1
        local need = qty - taken
        local takeNow = need
        if takeNow > stackAmt then takeNow = stackAmt end

        exports.sItems:takeItem(player, "dbID", st.dbID, takeNow)
        taken = taken + takeNow
    end

    if taken < qty then
        -- refund what we took
        if taken > 0 then
            exports.sItems:giveItem(player, itemId, taken)
        end
        return false
    end

    return true
end

addEvent("sDrugRework:requestExtractMix", true)
addEventHandler("sDrugRework:requestExtractMix", resourceRoot, function(recipeKey)
    local player = client
    if not isElement(player) then return end

    recipeKey = tostring(recipeKey or "")
    local r = EXTRACT_RECIPES[recipeKey]
    if not r then
        exports.sGui:showInfobox(player, "e", "Ismeretlen recept!")
        return
    end

    if pendingExtract[player] then
        exports.sGui:showInfobox(player, "e", "Már folyamatban van egy kivonás!")
        return
    end

    -- Sanity: IDs must be configured
    if not r.out or not r.out.id or r.out.id == 0 then
        exports.sGui:showInfobox(player, "e", "A recept nincs beállítva (hiányzó output ID)!")
        return
    end
    for i = 1, #r.inputs do
        if not r.inputs[i].id or r.inputs[i].id == 0 then
            exports.sGui:showInfobox(player, "e", "A recept nincs beállítva (hiányzó input ID)!")
            return
        end
    end

    -- Take all inputs; if any fail, refund previous inputs and abort
    local takenList = {} -- { {id=, qty=} ... } for refund
    for i = 1, #r.inputs do
        local inId = tonumber(r.inputs[i].id)
        local inQty = tonumber(r.inputs[i].qty) or 1

        local ok = takeAmountByItemId(player, inId, inQty)
        if not ok then
            -- refund everything already taken
            for k = 1, #takenList do
                exports.sItems:giveItem(player, takenList[k].id, takenList[k].qty)
            end
            exports.sGui:showInfobox(player, "e", "Nincs meg minden szükséges alapanyag!")
            return
        end

        takenList[#takenList + 1] = { id = inId, qty = inQty }
    end

    pendingExtract[player] = {
        recipeKey = recipeKey,
        outId = tonumber(r.out.id),
        outQty = tonumber(r.out.qty) or 1
    }

    -- Start client minigame (5s space spam bar)
    triggerClientEvent(player, "sDrugRework:startExtractMixMinigame", resourceRoot, recipeKey)
end)

addEvent("sDrugRework:finishExtractMix", true)
addEventHandler("sDrugRework:finishExtractMix", resourceRoot, function(success)
    local player = client
    if not isElement(player) then return end

    local p = pendingExtract[player]
    if not p then return end
    pendingExtract[player] = nil

    success = success and true or false

    if success then
        exports.sItems:giveItem(player, p.outId, p.outQty)
        exports.sGui:showInfobox(player, "s", "Sikeres keverés! Elkészült a kémiai keverék.")
    else
        -- inputs are already consumed, so just message
        exports.sGui:showInfobox(player, "e", "Elrontottad a keverést! Az alapanyagok tönkrementek.")
    end
end)

addEventHandler("onPlayerQuit", root, function()
    pendingExtract[source] = nil
end)

local function hasEnough(player, itemId, need)
    need = tonumber(need) or 1
    local c = exports.sItems:getItemCount(player, itemId) or 0
    return c >= need
end

local function takeById(player, itemId, need)
    need = tonumber(need) or 1
    local taken = 0

    while taken < need do
        local st = exports.sItems:hasItem(player, itemId) -- NO amount param!
        if not st or not st.dbID then break end

        local stackAmt = tonumber(st.amount) or 1
        local left = need - taken
        local takeNow = (left < stackAmt) and left or stackAmt

        exports.sItems:takeItem(player, "dbID", st.dbID, takeNow)
        taken = taken + takeNow
    end

    return taken == need
end

addEvent("sDrugRework:requestExtractHeat", true)
addEventHandler("sDrugRework:requestExtractHeat", resourceRoot, function()
    local player = client
    if not isElement(player) then return end

    if pendingHeat[player] then
        exports.sGui:showInfobox(player, "e", "Már folyamatban van egy melegítés!")
        return
    end

    -- 1) PRE-CHECK totals (NO taking yet)
    if not hasEnough(player, EXTRACT_ITEM_COLD_MIX, 1)
    or not hasEnough(player, EXTRACT_ITEM_STAGE2_ITEM17, 1)
    or not hasEnough(player, EXTRACT_ITEM_BAKING_SODA, 1) then
        exports.sGui:showInfobox(player, "e", "Nincs meg minden szükséges alapanyag!")
        return
    end

    -- 2) TAKE all (should succeed now)
    local ok1 = takeById(player, EXTRACT_ITEM_COLD_MIX, 1)
    local ok2 = takeById(player, EXTRACT_ITEM_STAGE2_ITEM17, 1)
    local ok3 = takeById(player, EXTRACT_ITEM_BAKING_SODA, 1)

    if not (ok1 and ok2 and ok3) then
        -- safety refund (this should rarely happen now)
        if ok1 then exports.sItems:giveItem(player, EXTRACT_ITEM_COLD_MIX, 1) end
        if ok2 then exports.sItems:giveItem(player, EXTRACT_ITEM_STAGE2_ITEM17, 1) end
        if ok3 then exports.sItems:giveItem(player, EXTRACT_ITEM_BAKING_SODA, 1) end

        exports.sGui:showInfobox(player, "e", "Hiba történt az alapanyag levonásnál!")
        return
    end

    pendingHeat[player] = { outId = EXTRACT_ITEM_HEATED_ALKALOID, outQty = 1 }
    triggerClientEvent(player, "sDrugRework:startExtractHeatMinigame", resourceRoot)
end)

addEvent("sDrugRework:finishExtractHeat", true)
addEventHandler("sDrugRework:finishExtractHeat", resourceRoot, function(success)
    local player = client
    if not isElement(player) then return end

    local p = pendingHeat[player]
    if not p then return end
    pendingHeat[player] = nil

    if success then
        exports.sItems:giveItem(player, p.outId, p.outQty)
        exports.sGui:showInfobox(player, "s", "Siker! Elkészült a hevített alkaloidkeverék.")
    else
        exports.sGui:showInfobox(player, "e", "Túlhevítetted / elrontottad! Az anyag tönkrement.")
    end
end)

addEventHandler("onPlayerQuit", root, function()
    pendingHeat[source] = nil
end)

addEvent("sDrugRework:requestExtractSeparate", true)
addEventHandler("sDrugRework:requestExtractSeparate", resourceRoot, function()
    local player = client
    if not isElement(player) then return end

    if pendingSep[player] then
        exports.sGui:showInfobox(player, "e", "Már folyamatban van egy elkülönítés!")
        return
    end

    -- pre-check total (safe with stacked items)
    local c = exports.sItems:getItemCount(player, EXTRACT_ITEM_HEATED_ALKALOID) or 0
    if c < 1 then
        exports.sGui:showInfobox(player, "e", "Nincs nálad Hevített Alkaloidkeverék!")
        return
    end

    -- take input (NO refund on fail)
    local ok = takeById(player, EXTRACT_ITEM_HEATED_ALKALOID, 1) -- use your existing helper
    if not ok then
        exports.sGui:showInfobox(player, "e", "Nem sikerült levonni az alapanyagot!")
        return
    end

    pendingSep[player] = { outId = EXTRACT_ITEM_WET_BASE, outQty = 1 }
    triggerClientEvent(player, "sDrugRework:startExtractSeparateMinigame", resourceRoot)
end)

addEvent("sDrugRework:finishExtractSeparate", true)
addEventHandler("sDrugRework:finishExtractSeparate", resourceRoot, function(success)
    local player = client
    if not isElement(player) then return end

    local p = pendingSep[player]
    if not p then return end
    pendingSep[player] = nil

    if success then
        exports.sItems:giveItem(player, p.outId, p.outQty)
        exports.sGui:showInfobox(player, "s", "Siker! Tiszta Kokain Bázis (Nedves) elkészült.")
    else
        exports.sGui:showInfobox(player, "e", "Elrontottad az elkülönítést! Az anyag tönkrement.")
    end
end)

addEventHandler("onPlayerQuit", root, function()
    pendingSep[source] = nil
end)

addEvent("sDrugRework:dryRequestState", true)
addEventHandler("sDrugRework:dryRequestState", resourceRoot, function(benchId)
    local player = client
    benchId = tonumber(benchId)
    if not benchId or not loadedBenches[benchId] then return end

    local benchRow = loadedBenches[benchId]
    if not isPlayerNearBench(player, benchRow) then
        exports.sGui:showInfobox(player, "e", "Túl messze vagy az asztaltól!")
        return
    end

    local st = dryRacks[benchId]
    if not st then
        st = { slots = defaultDrySlots(), active=false, startedAt=0, endAt=0, durationSec = DRY_CFG.DURATION_SEC }
        dryRacks[benchId] = st
        dbExec(connection, "INSERT IGNORE INTO drug_drying_racks (benchId, slotsJson, active, startedAt, endAt, durationSec) VALUES (?,?,?,?,?,?)",
            benchId, encodeSlots(st.slots), 0, 0, 0, st.durationSec
        )
    end

    -- if active but expired, finalize on demand too
    local n = nowUnix()
    if st.active and st.endAt > 0 and n >= st.endAt then
        st.active = false
        st.startedAt = 0
        st.endAt = 0
        for _, idx in ipairs({1,2,4,5}) do
            if tonumber(st.slots[idx]) == DRY_CFG.BASE_IN then
                st.slots[idx] = DRY_CFG.BASE_OUT
            end
        end
        dbExec(connection, "UPDATE drug_drying_racks SET slotsJson=?, active=0, startedAt=0, endAt=0 WHERE benchId=?",
            encodeSlots(st.slots), benchId
        )
        triggerClientEvent(root, "sDrugRework:dryTimerClear", resourceRoot, benchId)
    end

    triggerClientEvent(player, "sDrugRework:dryReceiveState", resourceRoot, benchId, st.slots, st.active, st.endAt, st.durationSec)
end)

addEvent("sDrugRework:dryPutItem", true)
addEventHandler("sDrugRework:dryPutItem", resourceRoot, function(benchId, slotIndex, itemId)
    local player = client
    benchId = tonumber(benchId)
    slotIndex = tonumber(slotIndex)
    itemId = tonumber(itemId)

    if not benchId or not loadedBenches[benchId] then return end
    if not slotIndex or slotIndex < 1 or slotIndex > 5 then return end
    if not itemId then return end

    local benchRow = loadedBenches[benchId]
    if not isPlayerNearBench(player, benchRow) then
        exports.sGui:showInfobox(player, "e", "Túl messze vagy az asztaltól!")
        return
    end

    local st = dryRacks[benchId]
    if not st then
        st = { slots = defaultDrySlots(), active=false, startedAt=0, endAt=0, durationSec = DRY_CFG.DURATION_SEC }
        dryRacks[benchId] = st
        dbExec(connection, "INSERT IGNORE INTO drug_drying_racks (benchId, slotsJson, active, startedAt, endAt, durationSec) VALUES (?,?,?,?,?,?)",
            benchId, encodeSlots(st.slots), 0, 0, 0, st.durationSec
        )
    end

    if st.active then
        exports.sGui:showInfobox(player, "e", "Szárítás közben nem lehet pakolni!")
        return
    end

    if st.slots[slotIndex] then
        exports.sGui:showInfobox(player, "e", "Ez a slot már foglalt!")
        return
    end

    -- compatibility rules
    local need = false
    if slotIndex == 3 then need = DRY_CFG.ACETONE else need = DRY_CFG.BASE_IN end
    if itemId ~= need then
        exports.sGui:showInfobox(player, "e", "Nem megfelelő item ehhez a slothoz!")
        return
    end

    if not sitems_hasAtLeast(player, itemId, 1) then
        exports.sGui:showInfobox(player, "e", "Nincs nálad elegendő alapanyag!")
        return
    end

    sitems_take(player, itemId, 1)

    st.slots[slotIndex] = itemId
    dbExec(connection, "UPDATE drug_drying_racks SET slotsJson=? WHERE benchId=?", encodeSlots(st.slots), benchId)

    triggerClientEvent(player, "sDrugRework:dryReceiveState", resourceRoot, benchId, st.slots, st.active, st.endAt, st.durationSec)
end)

addEvent("sDrugRework:dryTakeItem", true)
addEventHandler("sDrugRework:dryTakeItem", resourceRoot, function(benchId, slotIndex)
    local player = client
    benchId = tonumber(benchId)
    slotIndex = tonumber(slotIndex)

    if not benchId or not loadedBenches[benchId] then return end
    if not slotIndex or slotIndex < 1 or slotIndex > 5 then return end

    local benchRow = loadedBenches[benchId]
    if not isPlayerNearBench(player, benchRow) then
        exports.sGui:showInfobox(player, "e", "Túl messze vagy az asztaltól!")
        return
    end

    local st = dryRacks[benchId]
    if not st then return end

    if st.active then
        exports.sGui:showInfobox(player, "e", "Szárítás közben nem lehet kivenni!")
        return
    end

    local it = tonumber(st.slots[slotIndex])
    if not it then return end

    if not exports.sItems:hasSpaceForItem(player, it, 1) then
        exports.sGui:showInfobox(player, "e", "Nincs elég hely az inventoryban!")
        return
    end

    st.slots[slotIndex] = false
    dbExec(connection, "UPDATE drug_drying_racks SET slotsJson=? WHERE benchId=?", encodeSlots(st.slots), benchId)

    sitems_give(player, it, 1)
    triggerClientEvent(player, "sDrugRework:dryReceiveState", resourceRoot, benchId, st.slots, st.active, st.endAt, st.durationSec)
end)

addEvent("sDrugRework:dryStart", true)
addEventHandler("sDrugRework:dryStart", resourceRoot, function(benchId)
    local player = client
    benchId = tonumber(benchId)
    if not benchId or not loadedBenches[benchId] then return end

    local benchRow = loadedBenches[benchId]
    if not isPlayerNearBench(player, benchRow) then
        exports.sGui:showInfobox(player, "e", "Túl messze vagy az asztaltól!")
        return
    end

    local st = dryRacks[benchId]
    if not st then return end
    if st.active then
        exports.sGui:showInfobox(player, "e", "Már zajlik a szárítás!")
        return
    end

    if tonumber(st.slots[3]) ~= DRY_CFG.ACETONE then
        exports.sGui:showInfobox(player, "e", "Kell aceton a középső slotba!")
        return
    end

    local hasBase = false
    for _, idx in ipairs({1,2,4,5}) do
        if tonumber(st.slots[idx]) == DRY_CFG.BASE_IN then
            hasBase = true
            break
        end
    end
    if not hasBase then
        exports.sGui:showInfobox(player, "e", "Tegyél be legalább 1 kokain bázist!")
        return
    end

    -- consume acetone
    st.slots[3] = false

    local n = nowUnix()
    st.active = true
    st.startedAt = n
    st.durationSec = DRY_CFG.DURATION_SEC
    st.endAt = n + st.durationSec

    dbExec(connection, "UPDATE drug_drying_racks SET slotsJson=?, active=1, startedAt=?, endAt=?, durationSec=? WHERE benchId=?",
        encodeSlots(st.slots), st.startedAt, st.endAt, st.durationSec, benchId
    )

    exports.sGui:showInfobox(player, "s", "Szárítás elindítva!")
    triggerClientEvent(root, "sDrugRework:dryTimerUpdate", resourceRoot, benchId, st.endAt)
    triggerClientEvent(player, "sDrugRework:dryReceiveState", resourceRoot, benchId, st.slots, st.active, st.endAt, st.durationSec)
end)