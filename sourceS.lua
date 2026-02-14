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

        -- ✅ IMPORTANT: send benches to all currently online players AFTER load
        for _, p in ipairs(getElementsByType("player")) do
            sendAllBenchesToPlayer(p)
        end
    end, connection, "SELECT id, benchType, x, y, z, rz, interior, dimension FROM drug_workbenches")
end)

addEventHandler("onPlayerJoin", root, function()
    -- wait a moment so client resources are up
    setTimer(function(p)
        if isElement(p) then
            sendAllBenchesToPlayer(p)
        end
    end, 2000, 1, source)
end)

addEventHandler("onPlayerResourceStart", root, function(startedRes)
    if startedRes and startedRes ~= getThisResource() then return end
    sendAllBenchesToPlayer(source)
end)


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



