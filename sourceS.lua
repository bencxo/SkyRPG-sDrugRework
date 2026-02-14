-- sDrugRework/sourceS.lua
-- make sure this resource has access to exports: sItems, sGui, sModloader (client only) etc.

local connection = exports.sConnection:getConnection()
local loadedBenches = {} -- [id] = row

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
end)

addEvent("sDrugRework:clientReady", true)
addEventHandler("sDrugRework:clientReady", resourceRoot, function()
    local player = client
    if not isElement(player) then return end
    sendAllBenchesToPlayer(player)
end)

-- =========================================================
-- Mortar grind server logic
-- =========================================================

local MORTAR_RECIPES = {
    [14]  = { out = 182, ratio = 1 },
    [15]  = { out = 183, ratio = 1 },
    [432] = { out = 184, ratio = 1 },
}

-- pending crafts (items already taken, waiting for minigame finish/cancel)
-- pending[player] = { inId=, inQty=, outId=, outQty= }
local pending = {}


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
        triggerClientEvent(player, "showInfobox", player, "e", "You don't have the required input items.")
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