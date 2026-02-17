-- sDrugRework/sourceC.lua
addEventHandler("onClientResourceStart", resourceRoot, function()
    triggerServerEvent("sDrugRework:clientReady", resourceRoot)
end)


local placing = false
local placingData = nil
local ghostObj = nil
local ghostRotZ = 0

-- =========================================================
-- Mortar & Pestle UI (BASE) - sGui compatible
-- =========================================================

-- Mortar input pool (example items)
local MORTAR_INPUT_ITEMS = {
    { id = 14,  name = "Kokalevél" },
    { id = 15,  name = "Mákszalma" },
    { id = 432, name = "Parazen virág" },
}

-- input itemId -> output itemId (+ optional ratio)
local MORTAR_RECIPES = {
    [14]  = { out = 791, ratio = 1, name = "Kokain paszta" },
    [15]  = { out = 183, ratio = 1, name = "Mák cuccos" },
    [432] = { out = 184, ratio = 1, name = "Parazen next" },
}

local mortarUI = {
    window = false,
    inputSlot = false,
    outputSlot = false,
    grindBtn = false,
    addBtn = false,
    menu = false,
    menuBtns = {},
    selectedInputId = false,
    selectedInputName = false,
    menuInner = false,
    menuBorder = false,   -- optional rename, but we’ll keep compatibility
    inputIcon = false,
    inputIconPath = false,
    inputQty = 1,
    inputQtyText = false,
    qtyPlusBtn = false,
    qtyMinusBtn = false,
    outputIcon = false,
    outputQtyText = false,
    outputItemId = false,
    outputQty = 0,
    tipLabel = false,
}

-- =========================================================
-- Mortar minigame (client)
-- =========================================================

local MORTAR_MINIGAME = {
    fillPerClick = 0.08,  -- CONFIG: how much one click fills (0..1)
}

local mortarGame = {
    active = false,
    progress = 0,
    outId = false,
    outQty = 0,
    sound = false,
}

local function mortar_makeFaIcon(name, size)
    -- Best case: sGui exports it (some setups do)
    if exports.sGui.getFaIconFilename then
        return exports.sGui:getFaIconFilename(name, size, "solid")
    end

    -- Fallback: if it's global somehow (usually not across resources)
    if type(getFaIconFilename) == "function" then
        return getFaIconFilename(name, size, "solid")
    end

    return false
end

local function mortar_itemPicPath(itemId)
    if not exports.sItems or not exports.sItems.getItemPic then
        return false
    end

    local rel = exports.sItems:getItemPic(tonumber(itemId))
    if not rel or rel == "" then
        return false
    end

    -- If it’s already resource-qualified, keep it
    if type(rel) == "string" and rel:sub(1, 1) == ":" then
        return rel
    end

    -- sItems returns "files/items/..", but dxDrawImage needs ":resource/..." to access other resources
    return ":sItems/" .. rel
end

local function mortar_isValid(el)
    return tonumber(el) and exports.sGui:isGuiElementValid(el)
end

local function mortarGame_startSound()
    if isElement(mortarGame.sound) then return end

    -- resource-relative path
    mortarGame.sound = playSound("files/mortarandpestle.mp3", true) -- true = loop
end

local function mortarGame_stopSound()
    if isElement(mortarGame.sound) then
        stopSound(mortarGame.sound)
    end
    mortarGame.sound = false
end

local function mortarGame_stop(refund)
    if not mortarGame.active then return end

    mortarGame_stopSound()

    mortarGame.active = false
    mortarGame.progress = 0

    removeEventHandler("onClientRender", root, mortarGame_render)
    removeEventHandler("onClientClick", root, mortarGame_click)
    unbindKey("backspace", "down", mortarGame_cancelKey)
    unbindKey("escape", "down", mortarGame_cancelKey)

    showCursor(false)
    setPedAnimation(localPlayer, false)

    if refund then
        triggerServerEvent("sDrugRework:cancelMortarGrind", resourceRoot)
        exports.sGui:showInfobox("e", "Mivel kiléptél a minigame-ből így visszakaptad az alapanyagot.")
    end
end

function mortarGame_cancelKey()
    mortarGame_stop(true)
end

function mortarGame_render()
    if not mortarGame.active then return end

    local sx, sy = guiGetScreenSize()

    -- Bottom middle bar
    local bw, bh = 420, 18
    local bx = (sx - bw) / 2
    local by = sy - 120

    dxDrawRectangle(bx, by, bw, bh, tocolor(0, 0, 0, 160))
    dxDrawRectangle(bx + 2, by + 2, (bw - 4) * math.min(1, mortarGame.progress), bh - 4, tocolor(255, 255, 255, 200))

    -- Above head bar
    local px, py, pz = getElementPosition(localPlayer)
    local wx, wy, wz = px, py, pz + 1.05
    local sx2, sy2 = getScreenFromWorldPosition(wx, wy, wz)
    if sx2 and sy2 then
        local hw, hh = 120, 10
        local hx, hy = sx2 - hw/2, sy2 - 40

        dxDrawRectangle(hx, hy, hw, hh, tocolor(0, 0, 0, 160))
        dxDrawRectangle(hx + 2, hy + 2, (hw - 4) * math.min(1, mortarGame.progress), hh - 4, tocolor(255, 255, 255, 200))
    end
end

function mortarGame_click(button, state)
    if not mortarGame.active then return end
    if button ~= "left" or state ~= "down" then return end

    mortarGame.progress = mortarGame.progress + (MORTAR_MINIGAME.fillPerClick or 0.08)

    if mortarGame.progress >= 1 then
        mortarGame.progress = 1

        -- Success
        exports.sGui:showInfobox("s", "Siker!")
        triggerServerEvent("sDrugRework:finishMortarGrind", resourceRoot)

        mortarGame_stop(false)
    end
end

local function mortar_isCursorInGuiEl(el)
    if not mortar_isValid(el) or not isCursorShowing() then return false end

    local cx, cy = getCursorPosition()
    if not cx or not cy then return false end

    local sx, sy = guiGetScreenSize()
    local mx, my = cx * sx, cy * sy

    -- Real (absolute) position for hit-test
    local ex, ey = exports.sGui:getGuiRealPosition(el)
    local ew, eh = exports.sGui:getGuiSize(el)

    return (mx >= ex and mx <= ex + ew and my >= ey and my <= ey + eh)
end

local function mortar_tipDestroy()
    if mortar_isValid(mortarUI.tipLabel) then
        exports.sGui:deleteGuiElement(mortarUI.tipLabel)
    end
    mortarUI.tipLabel = false
end

local function mortar_tipShow(text)
    if not text or text == "" or not isCursorShowing() then
        mortar_tipDestroy()
        return
    end

    local cx, cy = getCursorPosition()
    if not cx or not cy then
        mortar_tipDestroy()
        return
    end

    local sx, sy = guiGetScreenSize()
    local x = math.floor(cx * sx + 16)
    local y = math.floor(cy * sy + 18)

    -- Size the label to the text (so it doesn't clip)
    local font = "default-bold"
    local scale = 1
    local w = math.floor(dxGetTextWidth(text, scale, font)) + 6
    local h = 18

    -- Clamp on screen
    if x + w > sx - 5 then x = sx - w - 5 end
    if y + h > sy - 5 then y = sy - h - 5 end
    if x < 5 then x = 5 end
    if y < 5 then y = 5 end

    if not mortar_isValid(mortarUI.tipLabel) then
        mortarUI.tipLabel = exports.sGui:createGuiElement("label", x, y, w, h, nil, true)
        exports.sGui:setLabelAlignment(mortarUI.tipLabel, "left", "top")
        exports.sGui:setLabelShadow(mortarUI.tipLabel, tocolor(0, 0, 0, 200), 1, 1) -- shadow support in sGui :contentReference[oaicite:1]{index=1}
        exports.sGui:setLabelColor(mortarUI.tipLabel, tocolor(255, 255, 255, 255))
    else
        exports.sGui:setGuiPosition(mortarUI.tipLabel, x, y, true) -- absolute positioning supported :contentReference[oaicite:2]{index=2}
        exports.sGui:setGuiSize(mortarUI.tipLabel, w, h)           -- supported :contentReference[oaicite:3]{index=3}
    end

    exports.sGui:setLabelText(mortarUI.tipLabel, text)
end

local function mortar_clearOutputUi()
    if mortar_isValid(mortarUI.outputIcon) then exports.sGui:deleteGuiElement(mortarUI.outputIcon) end
    if mortar_isValid(mortarUI.outputQtyText) then exports.sGui:deleteGuiElement(mortarUI.outputQtyText) end

    mortarUI.outputIcon = false
    mortarUI.outputQtyText = false
    mortarUI.outputItemId = false
    mortarUI.outputQty = 0
end

local function mortar_calcOutput()
    mortarUI.outputItemId = false
    mortarUI.outputQty = 0

    local inId = tonumber(mortarUI.selectedInputId)
    if not inId then return end

    local r = MORTAR_RECIPES[inId]
    if not r or not r.out then return end

    local ratio = tonumber(r.ratio) or 1
    local q = tonumber(mortarUI.inputQty) or 1
    if q < 1 then q = 1 end

    mortarUI.outputItemId = tonumber(r.out)
    mortarUI.outputQty = math.max(1, math.floor(q * ratio))
end

local function mortar_refreshOutputUi()
    mortar_calcOutput()

    -- If no valid output, clear preview
    if not mortarUI.outputItemId or mortarUI.outputQty <= 0 then
        mortar_clearOutputUi()
        return
    end

    local pic = mortar_itemPicPath(mortarUI.outputItemId)
    if not pic then
        mortar_clearOutputUi()
        return
    end

    -- Position inside output slot (same way as input icon)
    local rx, ry = exports.sGui:getGuiPosition(mortarUI.outputSlot)
    local sw, sh = exports.sGui:getGuiSize(mortarUI.outputSlot)

    local iconPad = 4
    local iconSize = sh - iconPad*2 -- fits slot height

    -- Create / update icon
    if not mortar_isValid(mortarUI.outputIcon) then
        mortarUI.outputIcon = exports.sGui:createGuiElement(
            "image",
            rx + iconPad, ry + iconPad,
            iconSize, iconSize,
            mortarUI.window
        )
    end
    exports.sGui:setImageFile(mortarUI.outputIcon, pic)
    local inId = tonumber(mortarUI.selectedInputId)
    local r = inId and MORTAR_RECIPES[inId]
    local outName = (r and r.name) or "Output"

    exports.sGui:guiSetTooltip(mortarUI.outputIcon, outName)

    -- Qty label to the right of the icon, vertically centered
    local qtyX = rx + iconPad + iconSize + 6
    local qtyW = sw - (qtyX - rx) - iconPad

    if not mortar_isValid(mortarUI.outputQtyText) then
        mortarUI.outputQtyText = exports.sGui:createGuiElement(
            "label",
            qtyX, ry,
            qtyW, sh,
            mortarUI.window
        )
        exports.sGui:setLabelAlignment(mortarUI.outputQtyText, "left", "center")
    end

    exports.sGui:setLabelText(mortarUI.outputQtyText, "x" .. tostring(mortarUI.outputQty))
end

-- Helper: apply SkyRPG color scheme correctly
local function mortar_setPanelStyle(el)
    if not mortar_isValid(el) then return end

    exports.sGui:setGuiBackground(el, "sightblue")
    exports.sGui:setGuiBackgroundBorder(el, 2, "sightmidgrey")

    -- Important: prevents auto fading / red fallback
    if exports.sGui.setGuiBackgroundAlpha then
        exports.sGui:setGuiBackgroundAlpha(el, 255)
    end
end

local function mortar_setQty(q)
    q = tonumber(q) or 1
    if q < 1 then q = 1 end
    mortarUI.inputQty = q

    if mortar_isValid(mortarUI.inputQtyText) then
        exports.sGui:setLabelText(mortarUI.inputQtyText, tostring(mortarUI.inputQty))
    end
    mortar_refreshOutputUi()
end

local function mortar_clearQtyUi()
    if mortar_isValid(mortarUI.inputQtyText) then exports.sGui:deleteGuiElement(mortarUI.inputQtyText) end
    if mortar_isValid(mortarUI.qtyPlusBtn) then exports.sGui:deleteGuiElement(mortarUI.qtyPlusBtn) end
    if mortar_isValid(mortarUI.qtyMinusBtn) then exports.sGui:deleteGuiElement(mortarUI.qtyMinusBtn) end

    mortarUI.inputQtyText = false
    mortarUI.qtyPlusBtn = false
    mortarUI.qtyMinusBtn = false
end

local function mortar_buildQtyUi()
    -- Only show when an input item is selected (i.e. icon exists)
    if not mortar_isValid(mortarUI.inputIcon) then
        mortar_clearQtyUi()
        return
    end

    local ix, iy = exports.sGui:getGuiPosition(mortarUI.inputIcon)
    local iw, ih = exports.sGui:getGuiSize(mortarUI.inputIcon)

    -- +/- button size
    local b = 18

    -- Minus (top-left)
    if not mortar_isValid(mortarUI.qtyMinusBtn) then
        mortarUI.qtyMinusBtn = exports.sGui:createGuiElement("button", ix - 2, iy - 2, b, b, mortarUI.window)
        exports.sGui:setButtonText(mortarUI.qtyMinusBtn, "-")
        exports.sGui:setGuiBackground(mortarUI.qtyMinusBtn, "solid", "sightgrey2")
        exports.sGui:setGuiHover(mortarUI.qtyMinusBtn, "solid", "sightgrey1")
        exports.sGui:guiSetTooltip(mortarUI.qtyMinusBtn, "Decrease amount")
    end

    -- Plus (top-right)
    if not mortar_isValid(mortarUI.qtyPlusBtn) then
        mortarUI.qtyPlusBtn = exports.sGui:createGuiElement("button", ix + iw - b + 2, iy - 2, b, b, mortarUI.window)
        exports.sGui:setButtonText(mortarUI.qtyPlusBtn, "+")
        exports.sGui:setGuiBackground(mortarUI.qtyPlusBtn, "solid", "sightgrey2")
        exports.sGui:setGuiHover(mortarUI.qtyPlusBtn, "solid", "sightgrey1")
        exports.sGui:guiSetTooltip(mortarUI.qtyPlusBtn, "Increase amount")
    end

    -- Count label (bottom-right)
    if not mortar_isValid(mortarUI.inputQtyText) then
        mortarUI.inputQtyText = exports.sGui:createGuiElement("label", ix + iw - 26, iy + ih - 20, 24, 18, mortarUI.window)
        exports.sGui:setLabelAlignment(mortarUI.inputQtyText, "right", "center")
        exports.sGui:setGuiBackground(mortarUI.inputQtyText, "solid", "sightgrey3")
    end

    mortar_setQty(mortarUI.inputQty or 1)
end

local function mortar_setInputIcon(itemId)
    -- remove icon
    if not itemId then
        if mortar_isValid(mortarUI.inputIcon) then
            exports.sGui:deleteGuiElement(mortarUI.inputIcon)
        end
        mortarUI.inputIcon = false
        mortar_clearQtyUi()
        mortar_setQty(1)
        return
    end

    local pic = mortar_itemPicPath(itemId)
    if not pic then
        exports.sGui:showInfobox("e", "Nincs kép! ID: " .. tostring(itemId))
        return
    end

    -- inputSlot is a child of the window, so we want RELATIVE coords to the window
    local rx, ry = exports.sGui:getGuiPosition(mortarUI.inputSlot)
    local iw, ih = exports.sGui:getGuiSize(mortarUI.inputSlot)

    -- Create image element if missing
    if not mortar_isValid(mortarUI.inputIcon) then
        mortarUI.inputIcon = exports.sGui:createGuiElement(
            "image",
            rx + 4, ry + 4,
            iw - 8, ih - 8,
            mortarUI.window
        )
    end

    -- IMPORTANT: sGui images use setImageFile(), not setGuiBackground()
    exports.sGui:setImageFile(mortarUI.inputIcon, pic)
    exports.sGui:guiSetTooltip(mortarUI.inputIcon, mortarUI.selectedInputName or "Input")
    mortar_setQty(1)
    mortar_buildQtyUi()
end
-- Creates a bordered panel from 2 background-drawn gui elements.
-- Uses correct sGui API: setGuiBackground(el, "solid", "colorCode")
local function mortar_createBorderedRect(parent, x, y, w, h, borderPx, borderColor, bgColor)
    borderPx = tonumber(borderPx) or 2

    -- Any unknown type still gets renderBackground() via drawGuiElement()
    local outer = exports.sGui:createGuiElement("mortar_box", x, y, w, h, parent, true)
    exports.sGui:setGuiBackground(outer, "solid", borderColor)

    local inner = exports.sGui:createGuiElement("mortar_box", x + borderPx, y + borderPx, w - borderPx*2, h - borderPx*2, parent, true)
    exports.sGui:setGuiBackground(inner, "solid", bgColor)

    return outer, inner
end

local function mortar_destroy()
    if mortar_isValid(mortarUI.window) then
        exports.sGui:deleteGuiElement(mortarUI.window)
    end

    mortarUI.window = false
    mortarUI.inputSlot = false
    mortarUI.outputSlot = false
    mortarUI.grindBtn = false
    mortarUI.inputSlotBorder = false
    mortarUI.outputSlotBorder = false
    mortarUI.grindBorder = false
    mortarUI.addBtn = false
    mortarUI.inputIcon = false
    mortarUI.inputIconPath = false
    mortar_clearQtyUi()
    mortarUI.inputQty = 1
    mortarUI.qtyPlusBtn = false
    mortarUI.qtyMinusBtn = false
    mortarUI.inputQtyText = false
    mortar_clearOutputUi()
    mortar_tipDestroy()
end

local function mortar_getCursorPixels()
    local cx, cy = getCursorPosition()
    if not cx or not cy then return 0, 0 end
    local sx, sy = guiGetScreenSize()
    return math.floor(cx * sx), math.floor(cy * sy)
end

local function mortar_menuDestroy()
    -- delete menu buttons
    if mortarUI.menuBtns then
        for el, _ in pairs(mortarUI.menuBtns) do
            if mortar_isValid(el) then
                exports.sGui:deleteGuiElement(el)
            end
        end
    end
    mortarUI.menuBtns = {}

    -- delete inner
    if mortar_isValid(mortarUI.menuInner) then
        exports.sGui:deleteGuiElement(mortarUI.menuInner)
    end
    mortarUI.menuInner = false

    -- delete outer/border
    if mortar_isValid(mortarUI.menu) then
        exports.sGui:deleteGuiElement(mortarUI.menu)
    end
    mortarUI.menu = false
end

local function mortar_menuOpen()
    -- toggle behavior
    if mortar_isValid(mortarUI.menu) then
        mortar_menuDestroy()
        return
    end

    if not mortar_isValid(mortarUI.addBtn) then return end
    if not mortar_isValid(mortarUI.window) then return end

    -- RELATIVE to the window (this is what we need since menu is parented to window)
    local bx, by = exports.sGui:getGuiPosition(mortarUI.addBtn)
    local bw, bh = exports.sGui:getGuiSize(mortarUI.addBtn)

    local w = 220
    local rowH = 30
    local pad = 2
    local h = pad*2 + (#MORTAR_INPUT_ITEMS * rowH)

    -- open to the right of the + icon (relative coords)
    local mx = bx + bw + 6
    local my = by

    -- Keep it INSIDE the window bounds (relative clamp)
    local winW, winH = exports.sGui:getGuiSize(mortarUI.window)

    if mx + w > winW then
        mx = bx - w - 6 -- open left if no space right
    end
    if my + h > winH then
        my = winH - h - 6
    end
    if my < 6 then my = 6 end

    -- Outer (border)
    mortarUI.menu = exports.sGui:createGuiElement("mortar_box", mx, my, w, h, mortarUI.window, true)
    exports.sGui:setGuiBackground(mortarUI.menu, "solid", "sightblue")

    -- Inner (fill)
    mortarUI.menuInner = exports.sGui:createGuiElement("mortar_box", mx + 2, my + 2, w - 4, h - 4, mortarUI.window, true)
    exports.sGui:setGuiBackground(mortarUI.menuInner, "solid", "sightgrey2")

    mortarUI.menuBtns = {}

    for i = 1, #MORTAR_INPUT_ITEMS do
        local it = MORTAR_INPUT_ITEMS[i]
        local ry = my + pad + (i - 1) * rowH

        local b = exports.sGui:createGuiElement("button", mx + pad + 2, ry + 2, w - (pad * 2) - 4, rowH - 4, mortarUI.window)
        exports.sGui:setButtonText(b, string.format("%s", it.name, it.id)) --(ID: %d)

        exports.sGui:setGuiBackground(b, "solid", "sightgrey2")
        exports.sGui:setGuiHover(b, "solid", "sightgrey1")

        -- Add item icon before the name (small enough to fit in the row)
        local pic = mortar_itemPicPath(it.id)
        if pic then
            exports.sGui:setButtonIcon(b, pic)
        end

        mortarUI.menuBtns[b] = { id = it.id, name = it.name }
    end
end

local function mortar_open()
    if mortar_isValid(mortarUI.window) then
        return
    end

    local sx, sy = guiGetScreenSize()
    local w, h = 460, 260
    local x, y = math.floor((sx - w) / 2), math.floor((sy - h) / 2)

    -- Create window
    mortarUI.window = exports.sGui:createGuiElement("window", x, y, w, h)

    -- IMPORTANT: Your sGui expects font as STRING like "18/BebasNeueRegular.otf"
    exports.sGui:setWindowTitle(mortarUI.window, "18/BebasNeueRegular.otf", "Mozsár")
    exports.sGui:setWindowCloseButton(mortarUI.window, "sDrugRework:mortarClose", "times", "sightred")

    -- Layout
    -- Layout constants inside window
    local pad = 18

    -- Slot size for item icons (72x72)
    local slotW, slotH = 72, 72

    -- Vertical placement
    local midY = 90

    -- Center the whole input/output layout nicely
    local centerX = w / 2
    local leftX  = math.floor(centerX - slotW - 120)
    local rightX = math.floor(centerX + 120)

    -- Labels
    local inputLbl = exports.sGui:createGuiElement("label", leftX, midY - 24, slotW, 20, mortarUI.window)
    exports.sGui:setLabelText(inputLbl, "Alapanyag")
    exports.sGui:setLabelAlignment(inputLbl, "center", "center")

    local outputLbl = exports.sGui:createGuiElement("label", rightX, midY - 24, slotW, 20, mortarUI.window)
    exports.sGui:setLabelText(outputLbl, "Termék")
    exports.sGui:setLabelAlignment(outputLbl, "center", "center")

    -- Slot rectangles:
    -- Any unknown type will still render via renderBackground() in your sGui,
    -- so we can safely use a custom type like "rect".
    -- Input slot (border + inner background)
    mortarUI.inputSlotBorder, mortarUI.inputSlot = mortar_createBorderedRect(
        mortarUI.window,
        leftX, midY,
        slotW, slotH,
        2,
        "sightgrey3",     -- border
        "sightgrey2"      -- fill
    )
    -- + button next to the input slot (top-right side)
    local plusSize = 22
    local plusX = leftX + slotW + 10
    local plusY = midY - 2

    mortarUI.addBtn = exports.sGui:createGuiElement("button", plusX, plusY, plusSize, plusSize, mortarUI.window)

    -- Style
    exports.sGui:setGuiBackground(mortarUI.addBtn, "solid", "sightgrey2")
    exports.sGui:setGuiHover(mortarUI.addBtn, "solid", "sightgrey1") -- subtle hover overlay
    exports.sGui:setButtonText(mortarUI.addBtn, "") -- icon only
    exports.sGui:guiSetTooltip(mortarUI.addBtn, "Add input item")

    -- Icon (FontAwesome "plus")
    local icon = mortar_makeFaIcon("plus", 18)
    if icon then
        exports.sGui:setButtonIcon(mortarUI.addBtn, icon)
    else
        -- fallback if fa generation isn't exported: show a simple "+"
        exports.sGui:setButtonText(mortarUI.addBtn, "+")
        exports.sGui:setButtonTextAlign(mortarUI.addBtn, "center", "center")
    end

    mortarUI.outputSlotBorder, mortarUI.outputSlot = mortar_createBorderedRect(
        mortarUI.window,
        rightX, midY,
        slotW, slotH,
        2,
        "sightgrey3",
        "sightgrey2"
    )

    -- Arrow
    local arrowW = rightX - (leftX + slotW)
    local arrowX = leftX + slotW
    local arrowY = midY + slotH/2 - 10
    local arrow = exports.sGui:createGuiElement("label", arrowX, arrowY, arrowW, 20, mortarUI.window)
    exports.sGui:setLabelText(arrow, "----->")
    exports.sGui:setLabelAlignment(arrow, "center", "center")

    -- Grind button: make a bordered container, put the button inside it
    local btnW, btnH = 140, 36
    local btnX = math.floor((w - btnW) / 2)
    local btnY = h - pad - btnH

    -- Border behind the button
    mortarUI.grindBorder, _ = mortar_createBorderedRect(
        mortarUI.window,
        btnX, btnY,
        btnW, btnH,
        2,
        "sightgrey3",     -- border
        "sightgrey3"
    )

    -- Button inside the border
    mortarUI.grindBtn = exports.sGui:createGuiElement("button", btnX + 2, btnY + 2, btnW - 4, btnH - 4, mortarUI.window)
    exports.sGui:setButtonText(mortarUI.grindBtn, "Őrlés")

    -- Button fill (different from border)
    exports.sGui:setGuiBackground(mortarUI.grindBtn, "solid", "sightblue")
end

-- Close event from the window X
addEvent("sDrugRework:mortarClose", true)
addEventHandler("sDrugRework:mortarClose", root, function(...)
    mortar_menuDestroy()
    mortar_destroy()
end)

-- Debug command to test
addCommandHandler("mortarui", function()
    mortar_open()
end)

-- TEMP: detect Grind click (uses sGui hover element)
addEventHandler("onClientClick", root, function(button, state)
    if button ~= "left" or state ~= "down" then return end
    if not mortar_isValid(mortarUI.grindBtn) then return end

    local hoverEl = exports.sGui:getGuiHoverElement()
    -- Grind button clicked
    if hoverEl and mortar_isValid(mortarUI.grindBtn) and hoverEl == mortarUI.grindBtn then
        if not mortarUI.selectedInputId then
            exports.sGui:showInfobox("e", "Kérlek válassz alapanyagot!")
            return
        end

        local inputId = tonumber(mortarUI.selectedInputId)
        local inputQty = tonumber(mortarUI.inputQty) or 1
        if inputQty < 1 then inputQty = 1 end

        -- Request server to validate + take items, then start minigame
        triggerServerEvent("sDrugRework:requestMortarGrind", resourceRoot, inputId, inputQty)
        return
    end
    -- Qty buttons
    if hoverEl and mortar_isValid(mortarUI.qtyPlusBtn) and hoverEl == mortarUI.qtyPlusBtn then
        mortar_setQty((mortarUI.inputQty or 1) + 1)
        return
    end

    if hoverEl and mortar_isValid(mortarUI.qtyMinusBtn) and hoverEl == mortarUI.qtyMinusBtn then
        mortar_setQty((mortarUI.inputQty or 1) - 1) -- mortar_setQty clamps to 1
        return
    end
end)

addEventHandler("onClientClick", root, function(button, state)
    if button ~= "left" or state ~= "up" then return end
    if not mortar_isValid(mortarUI.window) then return end
    if not isCursorShowing() then return end

    local hoverEl = exports.sGui:getGuiHoverElement()

    -- 1) PLUS BUTTON: toggle menu (open/close) and STOP
    if hoverEl and mortar_isValid(mortarUI.addBtn) and hoverEl == mortarUI.addBtn then
        mortar_menuOpen() -- this already toggles
        return
    end

    -- 2) MENU ITEM: pick and close
    if hoverEl and mortarUI.menuBtns and mortarUI.menuBtns[hoverEl] then
        local pick = mortarUI.menuBtns[hoverEl]
        mortarUI.selectedInputId = pick.id
        mortarUI.selectedInputName = pick.name
        mortar_setInputIcon(pick.id)
        mortar_refreshOutputUi()

        --exports.sGui:showInfobox("i", "Selected input: " .. pick.name .. " (ID: " .. pick.id .. ")")
        mortar_menuDestroy()
        return
    end

    -- 3) CLICKED OUTSIDE MENU: close it
    if mortar_isValid(mortarUI.menu) then
        -- If you clicked something that is NOT part of the menu, close it
        -- (background/inner are not in menuBtns, so this is safe)
        mortar_menuDestroy()
    end
end)

addEventHandler("onClientRender", root, function()
    if not mortar_isValid(mortarUI.window) then
        mortar_tipDestroy()
        return
    end
    if not isCursorShowing() then
        mortar_tipDestroy()
        return
    end

    if mortar_isCursorInGuiEl(mortarUI.inputIcon) then
        mortar_tipShow(mortarUI.selectedInputName or "Input")
        return
    end

    if mortar_isCursorInGuiEl(mortarUI.outputIcon) then
        local inId = tonumber(mortarUI.selectedInputId)
        local r = inId and MORTAR_RECIPES[inId]
        mortar_tipShow((r and r.name) or "Output")
        return
    end

    mortar_tipDestroy()
end)

addEvent("sDrugRework:startMortarMinigame", true)
addEventHandler("sDrugRework:startMortarMinigame", resourceRoot, function(outId, outQty)
    outId = tonumber(outId)
    outQty = tonumber(outQty) or 0
    if not outId or outQty <= 0 then return end

    -- Close Mortar UI
    if mortar_destroy then mortar_destroy() end

    mortarGame.active = true
    mortarGame.progress = 0
    mortarGame.outId = outId
    mortarGame.outQty = outQty

    mortarGame_startSound()

    -- Animation while grinding (loop)
    setPedAnimation(localPlayer, "INT_HOUSE", "wash_up", -1, true, false, false, false)

    showCursor(true)

    addEventHandler("onClientRender", root, mortarGame_render)
    addEventHandler("onClientClick", root, mortarGame_click)

    bindKey("backspace", "down", mortarGame_cancelKey)
    bindKey("escape", "down", mortarGame_cancelKey)

    exports.sGui:showInfobox("i", "Őrlés folyamatban... Kattints a bal egérgombbal folyamatosan, amíg a csík meg nem telik. A minigame elhagyásához nyomd meg az 'ESC' gombot.")
end)

-- =========================================================
-- Extraction UI (sGui) + Mixing minigame
-- =========================================================

-- CONFIG: set these item IDs (must match server)
local EXTRACT_ITEM_COCA_PASTE    = 791 -- Kokain paszta (mortar output)
local EXTRACT_ITEM_LIGHTER_FLUID = 23   -- TODO
-- REQUIRED CONFIG (these must match server)
local EXTRACT_ITEM_COLD_MIX = EXTRACT_ITEM_COLD_MIX or 792      -- you already have this set somewhere
local EXTRACT_ITEM_STAGE2_ITEM17 = 792
local EXTRACT_ITEM_BAKING_SODA = 26
local EXTRACT_ITEM_HEATED_ALKALOID = 795 -- TODO: set your "Hevített Alkaloidkeverék" item ID
local EXTRACT_ITEM_WET_BASE        = 793  -- output (Tiszta Kokain Bázis (Nedves))

local function extract_itemPicPath(itemId)
    if not exports.sItems or not exports.sItems.getItemPic then return false end
    local rel = exports.sItems:getItemPic(tonumber(itemId))
    if not rel or rel == "" then return false end
    if type(rel) == "string" and rel:sub(1, 1) == ":" then return rel end
    return ":sItems/" .. rel
end

local function sg_center(el)
    if not (el and exports.sGui:isGuiElementValid(el)) then return end
    local sw, sh = guiGetScreenSize()
    local w, h = exports.sGui:getGuiSize(el)
    local x = math.floor((sw - w) / 2)
    local y = math.floor((sh - h) / 2)
    exports.sGui:setGuiPosition(el, x, y, true) -- absolute
end

local extractUI = {
    window = false,
    recipeBtn = false,
    recipeMenu = false,
    recipeMenuBtns = {},
    selectedRecipeKey = false,

    -- left panel
    leftIcon1 = false,
    leftIcon2 = false,
    mixBtn = false,

    -- visuals
    line1 = false,
    line2 = false,
}

local EXTRACT_RECIPES_C = {
    { key = "cocaine_base", name = "Kokain bázis" },
    -- add more later:
    -- { key = "xxx", name = "..." },
}

local function extract_safeDelete(el)
    if el and exports.sGui and exports.sGui.isGuiElementValid and exports.sGui:isGuiElementValid(el) then
        exports.sGui:deleteGuiElement(el)
    end
    return false
end

local function extract_close()
    extractUI.window = extract_safeDelete(extractUI.window)
    extractUI.recipeMenu = extract_safeDelete(extractUI.recipeMenu)
    extractUI.recipeMenuBtns = {}
    extractUI.selectedRecipeKey = false
end

addEvent("sDrugRework:closeExtractUI", true)
addEventHandler("sDrugRework:closeExtractUI", root, function()
    extract_close()
end)

local function extract_destroyRecipeMenu()
    extractUI.recipeMenu = extract_safeDelete(extractUI.recipeMenu)
    extractUI.recipeMenuBtns = {}
end

local function extract_openRecipeMenu()
    extract_destroyRecipeMenu()
    if not extractUI.window or not exports.sGui:isGuiElementValid(extractUI.window) then return end

    -- simple dropdown under recipe button
    local x, y, w, h = 20, 56, 220, 28 * #EXTRACT_RECIPES_C
    extractUI.recipeMenu = exports.sGui:createGuiElement("rectangle", x, y, w, h, extractUI.window)
    exports.sGui:setGuiBackground(extractUI.recipeMenu, "solid", {0, 0, 0, 180})

    extractUI.recipeMenuBtns = {}
    for i = 1, #EXTRACT_RECIPES_C do
        local r = EXTRACT_RECIPES_C[i]
        local btn = exports.sGui:createGuiElement("button", 0, (i-1)*28, w, 28, extractUI.recipeMenu)
        exports.sGui:setGuiText(btn, r.name)
        exports.sGui:setGuiFont(btn, "12/BebasNeueRegular.otf")
        guiSetTooltip(btn, r.name, "right", "down")
        extractUI.recipeMenuBtns[btn] = r.key
    end
end

local function extract_selectRecipe(recipeKey)
    extractUI.selectedRecipeKey = recipeKey
    extract_destroyRecipeMenu()

    if extractUI.recipeBtn and exports.sGui:isGuiElementValid(extractUI.recipeBtn) then
        exports.sGui:setGuiText(extractUI.recipeBtn, "Recept: " .. tostring(recipeKey))
    end

    -- for now we only implement cocaine_base left panel; later we’ll switch layouts here
end

local function sg_faPath(name, size, style, border, color, border2)
    -- base file (no tick suffix yet)
    local base = exports.sGui:getFaIconFilename(name, size, style, false, border, color, border2)
    local ticks = exports.sGui:getFaTicks()
    local suf = (ticks and ticks[base]) or ""
    return ":sGui/" .. base .. suf
end

local extractClickHandlerInstalled = false

local function extract_onClick(btn, state)
    if btn ~= "left" or state ~= "up" then return end
    if not (extractUI.window and exports.sGui:isGuiElementValid(extractUI.window)) then return end

    local h = exports.sGui:getGuiHoverElement()
    if not h then return end

    -- Separation
    if h == extractUI.sepBtn then
        triggerServerEvent("sDrugRework:requestExtractSeparate", resourceRoot)
        return
    end

    -- Heat
    if h == extractUI.heatBtn then
        triggerServerEvent("sDrugRework:requestExtractHeat", resourceRoot)
        return
    end

    -- Mix
    if h == extractUI.mixBtn then
        triggerServerEvent("sDrugRework:requestExtractMix", resourceRoot, "cocaine_base")
        return
    end
end

function extract_open()
    if extractUI.window and exports.sGui:isGuiElementValid(extractUI.window) then
        -- already open
        return
    end

    -- Window
    extractUI.window = exports.sGui:createGuiElement("window", 0, 0, 560, 260)
    exports.sGui:setWindowTitle(extractUI.window, "18/BebasNeueRegular.otf", "Extraction")
    exports.sGui:setWindowCloseButton(extractUI.window, "sDrugRework:closeExtractUI", "times", "sightred")
    exports.sGui:setGuiColorScheme(extractUI.window, "dark") -- if your scheme exists; safe if it doesn't
    sg_center(extractUI.window)

    -- Recipe select button (top-left)
    --extractUI.recipeBtn = exports.sGui:createGuiElement("button", 20, 18, 220, 30, extractUI.window)
    --exports.sGui:setButtonText(extractUI.recipeBtn, "Recept kiválasztása")
    --exports.sGui:setButtonFont(extractUI.recipeBtn, "12/BebasNeueRegular.otf")
    --exports.sGui:guiSetTooltip(extractUI.recipeBtn, "Recept kiválasztása", "right", "down")

    -- 2 vertical separator lines (3 halves)
    -- window inner area roughly from y=60..240
    extractUI.line1 = exports.sGui:createGuiElement("rectangle", 560/3, 60, 2, 180, extractUI.window)
    extractUI.line2 = exports.sGui:createGuiElement("rectangle", (560/3)*2, 60, 2, 180, extractUI.window)
    exports.sGui:setGuiBackground(extractUI.line1, "solid", {255, 255, 255, 35})
    exports.sGui:setGuiBackground(extractUI.line2, "solid", {255, 255, 255, 35})

    -- helper: set text on label safely (sGui API differences)
    local function sg_setLabelText(el, text)
        if exports.sGui.setLabelText then
            exports.sGui:setLabelText(el, text)
        elseif exports.sGui.setGuiText then
            exports.sGui:setGuiText(el, text)
        end
    end

    local function sg_setLabelFont(el, font)
        if exports.sGui.setLabelFont then
            exports.sGui:setLabelFont(el, font)
        elseif exports.sGui.setGuiFont then
            exports.sGui:setGuiFont(el, font)
        end
    end

    extractUI.stage1Label = exports.sGui:createGuiElement("label", 0, 62, 200, 22, extractUI.window)
    sg_setLabelText(extractUI.stage1Label, "Stage 1")
    sg_setLabelFont(extractUI.stage1Label, "16/BebasNeueRegular.otf")

    extractUI.mixIcon = exports.sGui:createGuiElement("image", 83, 99, 32, 32, extractUI.window)
    exports.sGui:setImageFile(extractUI.mixIcon, sg_faPath("plus", 32, "solid"))

    -- LEFT panel (only implemented for cocaine_base for now)
    -- icons 16x16 + 16x16
    extractUI.leftIcon1 = exports.sGui:createGuiElement("image", 30, 90, 48, 48, extractUI.window)
    extractUI.leftIcon2 = exports.sGui:createGuiElement("image", 120, 90, 48, 48, extractUI.window)

    local pic1 = extract_itemPicPath(EXTRACT_ITEM_COCA_PASTE)
    local pic2 = extract_itemPicPath(EXTRACT_ITEM_LIGHTER_FLUID)
    if pic1 then exports.sGui:setImageFile(extractUI.leftIcon1, pic1) end
    if pic2 then exports.sGui:setImageFile(extractUI.leftIcon2, pic2) end

    exports.sGui:guiSetTooltip(extractUI.leftIcon1, "Coca Paste", "right", "down")
    exports.sGui:guiSetTooltip(extractUI.leftIcon2, "Lighter Fluid", "right", "down")

    extractUI.mixBtn = exports.sGui:createGuiElement("button", 30, 170, 140, 32, extractUI.window)
    exports.sGui:setButtonText(extractUI.mixBtn, "Keverés")
    exports.sGui:setButtonFont(extractUI.mixBtn, "14/BebasNeueRegular.otf")

    -- ===== MIDDLE panel: Stage 2 (Heating) =====
    extractUI.stage2Label = exports.sGui:createGuiElement("label", 560/3 + 0, 62, 220, 22, extractUI.window)
    sg_setLabelText(extractUI.stage2Label, "Stage 2")
    sg_setLabelFont(extractUI.stage2Label, "16/BebasNeueRegular.otf")

    -- Fire FA icon (use your existing fa helper if you have it; otherwise you can skip this image)
    extractUI.fireIcon = exports.sGui:createGuiElement("image", 560/3 + 85, 97, 32, 32, extractUI.window)
    exports.sGui:setImageFile(extractUI.fireIcon, sg_faPath("fire", 32, "solid"))
    -- Two 64x64 icons
    extractUI.midIcon1 = exports.sGui:createGuiElement("image", 560/3 + 32, 90, 48, 48, extractUI.window)
    extractUI.midIcon2 = exports.sGui:createGuiElement("image", 560/3 + 120, 90, 48, 48, extractUI.window)

    local pic17 = extract_itemPicPath(EXTRACT_ITEM_STAGE2_ITEM17)
    local pic26 = extract_itemPicPath(EXTRACT_ITEM_BAKING_SODA)
    if pic17 then exports.sGui:setImageFile(extractUI.midIcon1, pic17) end
    if pic26 then exports.sGui:setImageFile(extractUI.midIcon2, pic26) end

    exports.sGui:guiSetTooltip(extractUI.midIcon1, "Item #17")
    exports.sGui:guiSetTooltip(extractUI.midIcon2, "Szódabikarbóna")

    -- Heat button (lower)
    extractUI.heatBtn = exports.sGui:createGuiElement("button", 560/3 + 30, 170, 140, 32, extractUI.window)
    exports.sGui:setButtonText(extractUI.heatBtn, "Felmelegítés")
    exports.sGui:setButtonFont(extractUI.heatBtn, "14/BebasNeueRegular.otf")

    -- ===== RIGHT panel: Stage 3 (Separation) =====
    extractUI.stage3Label = exports.sGui:createGuiElement("label", (560/3)*2 + 20, 62, 220, 22, extractUI.window)
    sg_setLabelText(extractUI.stage3Label, "Stage 3")
    sg_setLabelFont(extractUI.stage3Label, "16/BebasNeueRegular.otf")

    -- input icon (64x64)
    extractUI.rightIcon = exports.sGui:createGuiElement("image", (560/3)*2 + 85, 95, 64, 64, extractUI.window)
    local pic50 = extract_itemPicPath(EXTRACT_ITEM_HEATED_ALKALOID)
    if pic50 then exports.sGui:setImageFile(extractUI.rightIcon, pic50) end
    exports.sGui:guiSetTooltip(extractUI.rightIcon, "Hevített Alkaloidkeverék")

    -- arrows-alt fa icon under it (32x32)
    extractUI.arrowsIcon = exports.sGui:createGuiElement("image", (560/3)*2 + 101, 165, 32, 32, extractUI.window)
    if sg_faPath then
        exports.sGui:setImageFile(extractUI.arrowsIcon, sg_faPath("arrows-alt", 32, "solid"))
    end
    exports.sGui:guiSetTooltip(extractUI.arrowsIcon, "Elkülönítés")

    -- button
    extractUI.sepBtn = exports.sGui:createGuiElement("button", (560/3)*2 + 30, 205, 220, 36, extractUI.window)
    exports.sGui:setButtonText(extractUI.sepBtn, "Elkülönítés")
    exports.sGui:setButtonFont(extractUI.sepBtn, "14/BebasNeueRegular.otf")
    exports.sGui:guiSetTooltip(extractUI.sepBtn, "Elkülönítés")

    -- Click handling using hover element like your other UIs
    if not extractClickHandlerInstalled then
        addEventHandler("onClientClick", root, extract_onClick)
        extractClickHandlerInstalled = true
    end
end

-- debug command if you want
addCommandHandler("extractui", function()
    extract_open()
end)

local EXTRACT_GAME = {
    active = false,
    startTick = 0,
    duration = 5000,
    presses = 0,
    pressesNeeded = 40,
    wasCursor = false,
    sent = false,
    watchdog = false
}

local extractSndMix = false
local extractSndHeat = false
local extractSndSep = false

local function extract_stopMixSound()
    if isElement(extractSndMix) then
        destroyElement(extractSndMix)
    end
    extractSndMix = false
end

local function extract_stopHeatSound()
    if isElement(extractSndHeat) then
        destroyElement(extractSndHeat)
    end
    extractSndHeat = false
end

local function extract_stopSepSound()
    if isElement(extractSndSep) then destroyElement(extractSndSep) end
    extractSndSep = false
end

local function extract_stopAllMinigameSounds()
    extract_stopMixSound()
    extract_stopHeatSound()
    extract_stopSepSound()
end


local function extract_gameCleanup()
    removeEventHandler("onClientRender", root, extract_gameRender)
    removeEventHandler("onClientKey", root, extract_gameKey)
    extract_stopMixSound()

    if isTimer(EXTRACT_GAME.watchdog) then killTimer(EXTRACT_GAME.watchdog) end
    EXTRACT_GAME.watchdog = false

    EXTRACT_GAME.active = false
end

local function extract_gameFinish(success)
    if not EXTRACT_GAME.active or EXTRACT_GAME.sent then return end
    EXTRACT_GAME.sent = true

    extract_gameCleanup()
    extract_stopMixSound()
    triggerServerEvent("sDrugRework:finishExtractMix", resourceRoot, success and true or false)
end

function extract_gameKey(key, press)
    if not EXTRACT_GAME.active or not press then return end

    if key == "space" then
        EXTRACT_GAME.presses = EXTRACT_GAME.presses + 1
        if EXTRACT_GAME.presses >= EXTRACT_GAME.pressesNeeded then
            extract_gameFinish(true)
        end

    elseif key == "escape" then
        extract_gameFinish(false)

    elseif key == "m" then
        -- IMPORTANT: let your own mouse-mode script work again
        -- we finish+cleanup so cursor won't be stuck
        extract_gameFinish(false)
    end
end

function extract_gameRender()
    if not EXTRACT_GAME.active then return end

    local now = getTickCount()
    local elapsed = now - EXTRACT_GAME.startTick
    local left = math.max(0, EXTRACT_GAME.duration - elapsed)

    local progress = math.min(1, EXTRACT_GAME.presses / EXTRACT_GAME.pressesNeeded)

    local sx, sy = guiGetScreenSize()
    local w, h = 360, 22
    local x, y = sx/2 - w/2, sy/2 + 90

    dxDrawRectangle(x, y, w, h, tocolor(0, 0, 0, 180))
    dxDrawRectangle(x+2, y+2, (w-4) * progress, h-4, tocolor(255, 255, 255, 210))
    dxDrawText(string.format("Keverés... %0.1fs  (%d/%d)", left/1000, EXTRACT_GAME.presses, EXTRACT_GAME.pressesNeeded),
        x, y - 26, x+w, y, tocolor(255,255,255,220), 1, "default-bold", "center", "bottom")

    if elapsed >= EXTRACT_GAME.duration then
        extract_gameFinish(false)
    end
end

addEvent("sDrugRework:startExtractMixMinigame", true)
addEventHandler("sDrugRework:startExtractMixMinigame", resourceRoot, function()
    if extract_close then extract_close() end

    extract_stopMixSound()
    extractSndMix = playSound("files/mixing.mp3", false)

    EXTRACT_GAME.active = true
    EXTRACT_GAME.sent = false
    EXTRACT_GAME.startTick = getTickCount()
    EXTRACT_GAME.presses = 0

    addEventHandler("onClientRender", root, extract_gameRender)
    addEventHandler("onClientKey", root, extract_gameKey)

    EXTRACT_GAME.watchdog = setTimer(function()
        if EXTRACT_GAME.active and not EXTRACT_GAME.sent then
            extract_gameFinish(false)
        end
    end, EXTRACT_GAME.duration + 800, 1)
end)

addEventHandler("onClientResourceStop", resourceRoot, function()
    if EXTRACT_GAME.active then
        extract_gameCleanup()
        extract_stopAllMinigameSounds()
    end
end)

-- =========================================================
-- Stage 2 Heating Minigame (no cursor control!)
-- =========================================================

local HEAT_GAME = {
    active = false,
    startTick = 0,

    heat = 0,             -- 0..100
    heating = false,

    orangeMin = 62,       -- target band (upper-middle)
    orangeMax = 75,
    failAt = 92,          -- too hot threshold

    holdNeedMs = 3000,    -- must hold in orange for 3s
    holdMs = 0,

    lastTick = 0,
    sent = false
}

local function heat_cleanup()
    removeEventHandler("onClientRender", root, heat_render)
    removeEventHandler("onClientKey", root, heat_key)
    extract_stopHeatSound()
    HEAT_GAME.active = false
end

local function heat_finish(success)
    if not HEAT_GAME.active or HEAT_GAME.sent then return end
    HEAT_GAME.sent = true
    extract_stopAllMinigameSounds()
    heat_cleanup()
    extract_stopHeatSound()
    triggerServerEvent("sDrugRework:finishExtractHeat", resourceRoot, success and true or false)
end

function heat_key(key, press)
    if not HEAT_GAME.active then return end

    if key == "space" then
        HEAT_GAME.heating = press and true or false
    elseif key == "escape" and press then
        heat_finish(false)
    end
end

local function draw_heat_bar(x, y, w, h, heat)
    -- background
    dxDrawRectangle(x, y, w, h, tocolor(0,0,0,180))

    -- segments (bottom->top)
    local function seg(y0, y1, r,g,b,a)
        dxDrawRectangle(x+2, y0, w-4, y1-y0, tocolor(r,g,b,a))
    end

    local innerH = h - 4
    local top = y + 2
    local bottom = y + 2 + innerH

    -- zone boundaries by % of bar height
    local function yAt(pctFromBottom) -- pct 0..1
        return bottom - innerH * pctFromBottom
    end

    -- blue 0-40%, yellow 40-60%, orange 60-80%, red 80-100%
    seg(yAt(1.00), yAt(0.80), 220,  60,  60, 200) -- red top band
    seg(yAt(0.80), yAt(0.60), 255, 140,  30, 200) -- orange
    seg(yAt(0.60), yAt(0.40), 255, 220,  60, 200) -- yellow
    seg(yAt(0.40), yAt(0.00),  60, 140, 255, 200) -- blue bottom band

    -- current heat line
    local pct = math.max(0, math.min(1, heat / 100))
    local lineY = bottom - innerH * pct
    dxDrawRectangle(x, lineY-1, w, 2, tocolor(255,255,255,240))

    return lineY
end

function heat_render()
    if not HEAT_GAME.active then return end

    local now = getTickCount()
    local dt = now - (HEAT_GAME.lastTick > 0 and HEAT_GAME.lastTick or now)
    HEAT_GAME.lastTick = now
    if dt < 0 then dt = 0 end

    -- heat physics
    local upPerSec = 28   -- heating speed
    local downPerSec = 20 -- cooling speed

    if HEAT_GAME.heating then
        HEAT_GAME.heat = HEAT_GAME.heat + upPerSec * (dt / 1000)
    else
        HEAT_GAME.heat = HEAT_GAME.heat - downPerSec * (dt / 1000)
    end
    if HEAT_GAME.heat < 0 then HEAT_GAME.heat = 0 end
    if HEAT_GAME.heat > 100 then HEAT_GAME.heat = 100 end

    -- fail if too hot
    if HEAT_GAME.heat >= HEAT_GAME.failAt then
        heat_finish(false)
        return
    end

    -- hold logic (must be continuously inside orange band)
    if HEAT_GAME.heat >= HEAT_GAME.orangeMin and HEAT_GAME.heat <= HEAT_GAME.orangeMax then
        HEAT_GAME.holdMs = HEAT_GAME.holdMs + dt
    else
        HEAT_GAME.holdMs = 0
    end

    if HEAT_GAME.holdMs >= HEAT_GAME.holdNeedMs then
        heat_finish(true)
        return
    end

    -- draw
    local sx, sy = guiGetScreenSize()
    local barW, barH = 46, 320
    local x = sx/2 - barW/2
    local y = sy/2 - barH/2

    local lineY = draw_heat_bar(x, y, barW, barH, HEAT_GAME.heat)

    -- Celsius text next to line (map 0..100 => 20..200°C for flavor)
    local c = math.floor(20 + (HEAT_GAME.heat/100) * 180)
    dxDrawText(tostring(c) .. " °C", x + barW + 12, lineY - 10, x + barW + 200, lineY + 10,
        tocolor(255,255,255,230), 1, "default-bold", "left", "center")

    -- instruction + hold progress
    local holdPct = math.floor((HEAT_GAME.holdMs / HEAT_GAME.holdNeedMs) * 100)
    dxDrawText("Tartsd az ORANGE zónában 3 mp-ig!\nSPACE: fűtés (elengeded -> hűl)\nTartás: " .. holdPct .. "%", 
        0, y + barH + 18, sx, y + barH + 80, tocolor(255,255,255,220), 1, "default-bold", "center", "top")
end

addEvent("sDrugRework:startExtractHeatMinigame", true)
addEventHandler("sDrugRework:startExtractHeatMinigame", resourceRoot, function()
    -- destroy GUI now (no cursor touching!)
    if extract_close then extract_close() end

    extract_stopHeatSound()
    extractSndHeat = playSound("files/heating.mp3", true) -- loop

    HEAT_GAME.active = true
    HEAT_GAME.sent = false
    HEAT_GAME.heat = 0
    HEAT_GAME.heating = false
    HEAT_GAME.holdMs = 0
    HEAT_GAME.lastTick = getTickCount()

    addEventHandler("onClientRender", root, heat_render)
    addEventHandler("onClientKey", root, heat_key)
end)

addEventHandler("onClientResourceStop", resourceRoot, function()
    if HEAT_GAME.active then
        heat_cleanup()
    end
end)

-- =========================================================
-- Stage 3 Separation Minigame
-- 3 rounds, need 2 successes. Space when line is in green zone.
-- =========================================================

local SEP_GAME = {
    active = false,
    sent = false,

    round = 1,
    wins = 0,
    losses = 0,

    pos = 0,            -- 0..1 line position from bottom to top
    speed = 0.22,       -- increases each round
    lastTick = 0,

    greenStart = 0.0,   -- 0..1
    greenEnd = 0.0
}

local function sep_cleanup()
    removeEventHandler("onClientRender", root, sep_render)
    removeEventHandler("onClientKey", root, sep_key)
    SEP_GAME.active = false
    extract_stopSepSound()
end

local function sep_finish(success)
    if not SEP_GAME.active or SEP_GAME.sent then return end
    SEP_GAME.sent = true
    sep_cleanup()
    triggerServerEvent("sDrugRework:finishExtractSeparate", resourceRoot, success and true or false)
end

local function sep_newGreenZone()
    -- green bar random position; slightly smaller as difficulty rises
    local baseSize = 0.20
    local size = baseSize - (SEP_GAME.round - 1) * 0.04 -- round1:0.20, r2:0.16, r3:0.12
    if size < 0.10 then size = 0.10 end

    local start = math.random() * (1.0 - size)
    SEP_GAME.greenStart = start
    SEP_GAME.greenEnd = start + size
end

local function sep_nextRound()
    SEP_GAME.round = SEP_GAME.round + 1

    -- early fail: if already 2 losses you cannot reach 2 wins
    if SEP_GAME.losses >= 2 then
        sep_finish(false)
        return
    end

    -- early success: if already 2 wins you’re done
    if SEP_GAME.wins >= 2 then
        sep_finish(true)
        return
    end

    if SEP_GAME.round > 3 then
        -- after 3 rounds: success if wins>=2
        sep_finish(SEP_GAME.wins >= 2)
        return
    end

    SEP_GAME.pos = 0
    SEP_GAME.speed = 0.22 + (SEP_GAME.round - 1) * 0.12 -- r1 0.22, r2 0.34, r3 0.46
    sep_newGreenZone()
end

function sep_key(key, press)
    if not SEP_GAME.active or not press then return end

    if key == "space" then
        local p = SEP_GAME.pos
        if p >= SEP_GAME.greenStart and p <= SEP_GAME.greenEnd then
            SEP_GAME.wins = SEP_GAME.wins + 1
        else
            SEP_GAME.losses = SEP_GAME.losses + 1
        end
        sep_nextRound()
        return
    elseif key == "escape" then
        sep_finish(false)
        return
    end
end

function sep_render()
    if not SEP_GAME.active then return end

    local now = getTickCount()
    local dt = now - (SEP_GAME.lastTick > 0 and SEP_GAME.lastTick or now)
    SEP_GAME.lastTick = now
    if dt < 0 then dt = 0 end

    SEP_GAME.pos = SEP_GAME.pos + SEP_GAME.speed * (dt / 1000)
    if SEP_GAME.pos > 1.0 then
        -- missed the timing window -> counts as fail for this round
        SEP_GAME.losses = SEP_GAME.losses + 1
        sep_nextRound()
        return
    end

    local sx, sy = guiGetScreenSize()
    local barW, barH = 54, 320
    local x = sx/2 - barW/2
    local y = sy/2 - barH/2

    -- background
    dxDrawRectangle(x, y, barW, barH, tocolor(0,0,0,180))

    -- green zone
    local gY1 = y + barH - (barH * SEP_GAME.greenEnd)
    local gY2 = y + barH - (barH * SEP_GAME.greenStart)
    dxDrawRectangle(x+2, gY1, barW-4, gY2 - gY1, tocolor(60, 200, 90, 200))

    -- moving line
    local lineY = y + barH - (barH * SEP_GAME.pos)
    dxDrawRectangle(x, lineY-1, barW, 2, tocolor(255,255,255,240))

    -- UI text
    dxDrawText(
        string.format("Elkülönítés  (Kör: %d/3)  Siker: %d  Hiba: %d\nSPACE amikor a vonal ZÖLD-ben van",
            SEP_GAME.round, SEP_GAME.wins, SEP_GAME.losses),
        0, y + barH + 18, sx, y + barH + 70,
        tocolor(255,255,255,220), 1, "default-bold", "center", "top"
    )
end

addEvent("sDrugRework:startExtractSeparateMinigame", true)
addEventHandler("sDrugRework:startExtractSeparateMinigame", resourceRoot, function()
    -- close UI, do NOT touch cursor
    if extract_close then extract_close() end

    extract_stopAllMinigameSounds()
    extractSndSep = playSound("files/separating.mp3", true) -- loop until finished

    SEP_GAME.active = true
    SEP_GAME.sent = false
    SEP_GAME.round = 1
    SEP_GAME.wins = 0
    SEP_GAME.losses = 0
    SEP_GAME.pos = 0
    SEP_GAME.speed = 0.22
    SEP_GAME.lastTick = getTickCount()
    sep_newGreenZone()

    addEventHandler("onClientRender", root, sep_render)
    addEventHandler("onClientKey", root, sep_key)
end)

addEventHandler("onClientResourceStop", resourceRoot, function()
    if SEP_GAME.active then
        sep_cleanup()
    end
end)

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
    mortar = "Mozsár",
    extract = "Kivonás",
    dry = "Szárítás",
    pickup = "Asztal felvétele",
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

    local hoverEl = exports.sGui:getGuiHoverElement() -- returns sGui element id (number)
    if not hoverEl or not wbIcons.byEl or not wbIcons.byEl[hoverEl] then return end

    local arg = wbIcons.byEl[hoverEl]

    if arg == "mortar" then
        mortar_open()
        return

    elseif arg == "extract" then
        extract_open()
        return

    elseif arg == "dry" then
        if not currentIconBench or not isElement(currentIconBench) then
            exports.sGui:showInfobox("e", "Nincs asztal a közelben!")
            return
        end

        local benchId = tonumber(getElementData(currentIconBench, "drugworkbench.id"))
        if not benchId then
            exports.sGui:showInfobox("e", "Hibás asztal azonosító!")
            return
        end

        dry_open(benchId)
        return

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

-- =========================================================
-- Drying Rack (client UI + timer display)
-- depends on: placedById[benchId] = {obj=element,...}
-- =========================================================

local DRY_CFG = {
    BASE_IN = 793,
    ACETONE = 794,
}

local dryUI = {
    open = false,
    benchId = false,
    window = false,
    slots = { [1]=false,[2]=false,[3]=false,[4]=false,[5]=false },
    active = false,
    endAt = 0,
    durationSec = 10,

    slotBg = {},
    slotIcon = {},
    plusBtn = {},
    takeBtn = {},
    startBtn = false,
    infoLbl = false,

    menu = false,
    menuBtn = false,
    menuSlot = false,
    menuBtnItem = {}, -- [btnId] = itemId
}

local DRY_COMPAT = {
    baseSlots = {
        { id = 793, name = "Kokain bázis" },
        -- future examples:
        -- { id = 120, name = "Metamfetamin bázis" },
        -- { id = 121, name = "Heroin bázis" },
    },

    midSlots = {
        { id = 794, name = "Aceton" },
        -- future examples:
        -- { id = 130, name = "Izopropil alkohol" },
        -- { id = 131, name = "Etanol" },
    }
}

local function dry_getCompatList(slotIndex)
    if slotIndex == 3 then
        return DRY_COMPAT.midSlots
    end
    return DRY_COMPAT.baseSlots
end

local dryTimers = {} -- [benchId] = endAtUnix

local function sg_setVisible(el, visible, childrenToo)
    if el and exports.sGui:isGuiElementValid(el) then
        exports.sGui:setGuiRenderDisabled(el, not visible, childrenToo or false)
    end
end

local function sg_setDisabled(el, disabled)
    if el and exports.sGui:isGuiElementValid(el) then
        exports.sGui:setElementDisabled(el, disabled and true or false)
    end
end

local function dry_isValid(el)
    return tonumber(el) and exports.sGui:isGuiElementValid(el)
end

local function dry_close()
    if dryUI.menu and dry_isValid(dryUI.menu) then exports.sGui:deleteGuiElement(dryUI.menu) end
    if dryUI.menuBtn and dry_isValid(dryUI.menuBtn) then exports.sGui:deleteGuiElement(dryUI.menuBtn) end
    dryUI.menu, dryUI.menuBtn, dryUI.menuSlot = false, false, false

    if dryUI.window and dry_isValid(dryUI.window) then
        exports.sGui:deleteGuiElement(dryUI.window)
    end

    dryUI.open = false
    dryUI.benchId = false
    dryUI.window = false
    dryUI.startBtn = false
    dryUI.infoLbl = false

    for i=1,5 do
        dryUI.slotBg[i] = false
        dryUI.slotIcon[i] = false
        dryUI.plusBtn[i] = false
        dryUI.takeBtn[i] = false
    end
end

local function dry_itemPic(itemId)
    if not exports.sItems or not exports.sItems.getItemPic then return false end
    local rel = exports.sItems:getItemPic(tonumber(itemId))
    if not rel or rel == "" then return false end
    if rel:sub(1,1) == ":" then return rel end
    return ":sItems/" .. rel
end

local function dry_slotWant(slotIndex)
    return (slotIndex == 3) and DRY_CFG.ACETONE or DRY_CFG.BASE_IN
end

local function dry_refresh()
    if not dry_isValid(dryUI.window) then return end

    -- info
    if dry_isValid(dryUI.infoLbl) then
        if dryUI.active and (dryUI.endAt or 0) > 0 then
        local now = getRealTime().timestamp
        local left = math.max(0, (dryUI.endAt or 0) - now)

        local mm = math.floor(left / 60)
        local ss = left % 60

        exports.sGui:setLabelText(dryUI.infoLbl, string.format("Folyamatban... (%d:%02d)", mm, ss))
        elseif dryUI.active then
            exports.sGui:setLabelText(dryUI.infoLbl, "Folyamatban...")
        else
            exports.sGui:setLabelText(dryUI.infoLbl, "Készítsd elő a szárítást.")
        end
    end

    -- slots
    for i=1,5 do
        local itemId = tonumber(dryUI.slots[i]) or false

        if dry_isValid(dryUI.plusBtn[i]) then
            sg_setVisible(dryUI.plusBtn[i], (not dryUI.active) and (not itemId))
        end
        if dry_isValid(dryUI.takeBtn[i]) then
            sg_setVisible(dryUI.takeBtn[i], (not dryUI.active) and (itemId ~= false))
        end

        if itemId then
            local pic = dry_itemPic(itemId)
            if pic then
                if not dry_isValid(dryUI.slotIcon[i]) then
                    local x,y = exports.sGui:getGuiPosition(dryUI.slotBg[i])
                    local w,h = exports.sGui:getGuiSize(dryUI.slotBg[i])
                    dryUI.slotIcon[i] = exports.sGui:createGuiElement("image", x+4, y+4, w-8, h-8, dryUI.window)
                end
                exports.sGui:setImageFile(dryUI.slotIcon[i], pic)
            end
        else
            if dry_isValid(dryUI.slotIcon[i]) then exports.sGui:deleteGuiElement(dryUI.slotIcon[i]) end
            dryUI.slotIcon[i] = false
        end
    end

    -- start enabled?
    if dry_isValid(dryUI.startBtn) and exports.sGui.setGuiDisabled then
        local canStart = false
        if not dryUI.active and tonumber(dryUI.slots[3]) == DRY_CFG.ACETONE then
            for _, idx in ipairs({1,2,4,5}) do
                if tonumber(dryUI.slots[idx]) == DRY_CFG.BASE_IN then
                    canStart = true
                    break
                end
            end
        end
        sg_setDisabled(dryUI.startBtn, not canStart)
    end
end

local function dry_openMenu(slotIndex)
    if dryUI.active then return end

    -- destroy old menu
    if dryUI.menu and dry_isValid(dryUI.menu) then exports.sGui:deleteGuiElement(dryUI.menu) end
    if dryUI.menuBtns then
        for _, b in ipairs(dryUI.menuBtns) do
            if dry_isValid(b) then exports.sGui:deleteGuiElement(b) end
        end
    end
    dryUI.menu, dryUI.menuBtns, dryUI.menuSlot = false, {}, slotIndex

    local list = dry_getCompatList(slotIndex) or {}
    if #list <= 0 then
        exports.sGui:showInfobox("e", "Nincs kompatibilis item beállítva ehhez a slothoz!")
        return
    end

    local bx, by = exports.sGui:getGuiPosition(dryUI.plusBtn[slotIndex])

    local rowH = 30
    local pad = 6
    local mw = 260
    local mh = pad*2 + (#list * rowH)

    dryUI.menu = exports.sGui:createGuiElement("rectangle", bx + 28, by, mw, mh, dryUI.window)
    exports.sGui:setGuiBackground(dryUI.menu, "solid", "sightgrey3")
    exports.sGui:setGuiBackgroundBorder(dryUI.menu, 2, "sightmidgrey")

    for i=1, #list do
        local data = list[i]
        local itemId = tonumber(data.id)
        local name = tostring(data.name or ("Item #" .. tostring(itemId)))

        local btnY = by + pad + (i-1)*rowH
        local btn = exports.sGui:createGuiElement("button", bx + 30, btnY, mw - 4, rowH - 2, dryUI.window)
        exports.sGui:setButtonText(btn, name)
        exports.sGui:setGuiBackground(btn, "solid", "sightgrey2")
        exports.sGui:setGuiHover(btn, "solid", "sightgrey1")
        exports.sGui:guiSetTooltip(btn, "Berakás")

        dryUI.menuBtnItem[btn] = itemId
        table.insert(dryUI.menuBtns, btn)
    end
end

function dry_open(benchId)
    benchId = tonumber(benchId)
    if not benchId then return end
    if dryUI.open then return end

    dryUI.open = true
    dryUI.benchId = benchId

    local sx, sy = guiGetScreenSize()
    local w, h = 520, 360
    local x, y = math.floor((sx - w) / 2), math.floor((sy - h) / 2)

    dryUI.window = exports.sGui:createGuiElement("window", x, y, w, h)
    exports.sGui:setWindowTitle(dryUI.window, "18/BebasNeueRegular.otf", "Szárítás")
    exports.sGui:setWindowCloseButton(dryUI.window, "sDrugRework:dryClose", "times", "sightred")

    dryUI.infoLbl = exports.sGui:createGuiElement("label", 18, 50, w-36, 24, dryUI.window)
    exports.sGui:setLabelAlignment(dryUI.infoLbl, "center", "center")
    exports.sGui:setLabelText(dryUI.infoLbl, "Betöltés...")

    local slotW, slotH = 48, 48
    local cx = w/2
    local topY = 90
    local midY = 90 + slotH + 34
    local botY = midY + slotH + 34

    local pos = {
        [1] = { cx - slotW - 110, topY },
        [2] = { cx + 110,        topY },
        [3] = { cx - slotW/2,    midY },
        [4] = { cx - slotW - 110, botY },
        [5] = { cx + 110,         botY },
    }

    for i=1,5 do
        local px, py = pos[i][1], pos[i][2]

        dryUI.slotBg[i] = exports.sGui:createGuiElement("rectangle", px, py, slotW, slotH, dryUI.window)
        exports.sGui:setGuiBackground(dryUI.slotBg[i], "solid", "sightgrey3")
        exports.sGui:setGuiBackgroundBorder(dryUI.slotBg[i], 2, "sightmidgrey")

        dryUI.plusBtn[i] = exports.sGui:createGuiElement("button", px + slotW + 8, py + 2, 26, 26, dryUI.window)
        exports.sGui:setButtonText(dryUI.plusBtn[i], "+")
        exports.sGui:setGuiBackground(dryUI.plusBtn[i], "solid", "sightgrey2")
        exports.sGui:setGuiHover(dryUI.plusBtn[i], "solid", "sightgrey1")
        exports.sGui:guiSetTooltip(dryUI.plusBtn[i], "Berakás")

        dryUI.takeBtn[i] = exports.sGui:createGuiElement("button", px, py + slotH + 6, slotW, 26, dryUI.window)
        exports.sGui:setButtonText(dryUI.takeBtn[i], "Kivétel")
        exports.sGui:setGuiBackground(dryUI.takeBtn[i], "solid", "sightgrey2")
        exports.sGui:setGuiHover(dryUI.takeBtn[i], "solid", "sightgrey1")
        sg_setVisible(dryUI.takeBtn[i], false)
    end

    dryUI.startBtn = exports.sGui:createGuiElement("button", w/2 - 110, h - 64, 220, 38, dryUI.window)
    exports.sGui:setButtonText(dryUI.startBtn, "Szárítás")
    exports.sGui:setGuiBackground(dryUI.startBtn, "solid", "sightgrey2")
    exports.sGui:setGuiHover(dryUI.startBtn, "solid", "sightgrey1")

    -- request server state
    triggerServerEvent("sDrugRework:dryRequestState", resourceRoot, benchId)
end

addEvent("sDrugRework:dryClose", true)
addEventHandler("sDrugRework:dryClose", root, function()
    dry_close()
end)

-- One shared click handler (don’t add new handlers each time you open)
addEventHandler("onClientClick", root, function(btn, st)
    if btn ~= "left" or st ~= "up" then return end
    if not dryUI.open or not dry_isValid(dryUI.window) then return end
    if not isCursorShowing() then return end

    local hoverEl = exports.sGui:getGuiHoverElement()

    -- menu buttons (multiple)
    if dryUI.menuBtns and #dryUI.menuBtns > 0 then
        for _, b in ipairs(dryUI.menuBtns) do
            if hoverEl == b then
                local itemId = tonumber(dryUI.menuBtnItem and dryUI.menuBtnItem[b])
                local slotIndex = tonumber(dryUI.menuSlot)

                if slotIndex and itemId then
                    triggerServerEvent("sDrugRework:dryPutItem", resourceRoot, dryUI.benchId, slotIndex, itemId)
                end

                -- close menu after choosing
                if dryUI.menu and dry_isValid(dryUI.menu) then
                    exports.sGui:deleteGuiElement(dryUI.menu)
                end

                for _, bb in ipairs(dryUI.menuBtns) do
                    if dry_isValid(bb) then
                        exports.sGui:deleteGuiElement(bb)
                    end
                end

                dryUI.menu = false
                dryUI.menuBtns = {}
                dryUI.menuSlot = false
                dryUI.menuBtnItem = {} -- IMPORTANT: clear mapping
                return
            end
        end
    end

    -- plus/take
    for i=1,5 do
        if hoverEl == dryUI.plusBtn[i] then
            dry_openMenu(i)
            return
        elseif hoverEl == dryUI.takeBtn[i] then
            triggerServerEvent("sDrugRework:dryTakeItem", resourceRoot, dryUI.benchId, i)
            return
        end
    end

    -- start
    if hoverEl == dryUI.startBtn then
        triggerServerEvent("sDrugRework:dryStart", resourceRoot, dryUI.benchId)
        dry_close() -- close immediately after clicking start
        return
    end
end)

addEvent("sDrugRework:dryReceiveState", true)
addEventHandler("sDrugRework:dryReceiveState", resourceRoot, function(benchId, slots, active, endAt, durationSec)
    benchId = tonumber(benchId)
    if not benchId then return end
    if dryUI.benchId ~= benchId then return end

    dryUI.slots = slots or dryUI.slots
    dryUI.active = active and true or false
    dryUI.endAt = tonumber(endAt) or 0
    dryUI.durationSec = tonumber(durationSec) or dryUI.durationSec

    dry_refresh()
end)

addEvent("sDrugRework:dryTimerUpdate", true)
addEventHandler("sDrugRework:dryTimerUpdate", resourceRoot, function(benchId, endAt)
    benchId = tonumber(benchId)
    endAt = tonumber(endAt)
    if benchId and endAt then
        dryTimers[benchId] = endAt
    end
end)

addEvent("sDrugRework:dryTimerClear", true)
addEventHandler("sDrugRework:dryTimerClear", resourceRoot, function(benchId)
    benchId = tonumber(benchId)
    if benchId then
        dryTimers[benchId] = nil
    end
end)

-- 3D timer above bench
addEventHandler("onClientRender", root, function()
    local now = getRealTime().timestamp

    for benchId, endAt in pairs(dryTimers) do
        local entry = placedById and placedById[benchId]
        if entry and isElement(entry.obj) then
            local bx, by, bz = getElementPosition(entry.obj)

            local px, py, pz = getElementPosition(localPlayer)
            if getDistanceBetweenPoints3D(px, py, pz, bx, by, bz) <= 18 then
                local left = (endAt or 0) - now
                if left > 0 then
                    local mins = math.ceil(left / 60)
                    local sx, sy = getScreenFromWorldPosition(bx, by, bz + 1.05)
                    if sx and sy then
                        local mm = math.floor(left / 60)
                        local ss = left % 60
                        dxDrawText(string.format("Szárítás: %d:%02d", mm, ss), sx-140, sy-28, sx+140, sy,
                            tocolor(255,255,255,220), 1, "default-bold", "center", "center")
                    end
                end
            end
        end
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