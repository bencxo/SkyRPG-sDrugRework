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
    { id = 14,  name = "Cocaine Leaf" },
    { id = 15,  name = "Poppy Straw" },
    { id = 432, name = "Parazen Flower" },
}

-- input itemId -> output itemId (+ optional ratio)
local MORTAR_RECIPES = {
    [14]  = { out = 182, ratio = 1, name = "Coca Paste" },
    [15]  = { out = 183, ratio = 1, name = "Poppy Resin" },
    [432] = { out = 184, ratio = 1, name = "Parazen Extract" },
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
        exports.sGui:showInfobox("e", "Cancelled.")
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
        exports.sGui:showInfobox("s", "Success!")
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
    end

    -- Plus (top-right)
    if not mortar_isValid(mortarUI.qtyPlusBtn) then
        mortarUI.qtyPlusBtn = exports.sGui:createGuiElement("button", ix + iw - b + 2, iy - 2, b, b, mortarUI.window)
        exports.sGui:setButtonText(mortarUI.qtyPlusBtn, "+")
        exports.sGui:setGuiBackground(mortarUI.qtyPlusBtn, "solid", "sightgrey2")
        exports.sGui:setGuiHover(mortarUI.qtyPlusBtn, "solid", "sightgrey1")
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
        exports.sGui:showInfobox("e", "No item picture found for ID: " .. tostring(itemId))
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
        exports.sGui:setButtonText(b, string.format("%s (ID: %d)", it.name, it.id))

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
    exports.sGui:setWindowTitle(mortarUI.window, "18/BebasNeueRegular.otf", "Mortar & Pestle")
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
    exports.sGui:setLabelText(inputLbl, "Input")
    exports.sGui:setLabelAlignment(inputLbl, "center", "center")

    local outputLbl = exports.sGui:createGuiElement("label", rightX, midY - 24, slotW, 20, mortarUI.window)
    exports.sGui:setLabelText(outputLbl, "Output")
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
    exports.sGui:setButtonText(mortarUI.grindBtn, "Grind")

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
            exports.sGui:showInfobox("e", "Select an input item first.")
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

        exports.sGui:showInfobox("i", "Selected input: " .. pick.name .. " (ID: " .. pick.id .. ")")
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

    exports.sGui:showInfobox("i", "Click to grind...")
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

    local hoverEl = exports.sGui:getGuiHoverElement() -- returns sGui element id (number)
    if not hoverEl or not wbIcons.byEl or not wbIcons.byEl[hoverEl] then return end

    local arg = wbIcons.byEl[hoverEl]

    if arg == "mortar" then
        mortar_open()
        return

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