-- RadialCast v1.3
-- Out of combat: hold middle mouse, flick, release to cast.
-- In combat (BETA): hold middle mouse, hover a slot, click to cast
-- (left, right, mouse 4 or mouse 5; chosen in /rcast).
-- Hold Shift or Ctrl while the wheel is open to swap rings live.
-- /rcast = settings window with the ring editor built in (Base / Shift / Ctrl tabs).
-- /rcast reset = clear all rings (asks to confirm).
-- /rcast disable [base,shift,ctrl] / enable [...] / status

local ADDON = ...
local MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\media\\"

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------
local SIZE = 420           -- base wheel diameter in pixels (the Size setting scales it)
local BIND = "BUTTON3"     -- middle mouse (Shift/Ctrl variants are bound automatically)

-- Defaults for the settings panel. Saved per character once changed.
-- The combat wheel's slots are live secure buttons for the whole fight,
-- so a left-click on one casts it even while the wheel is closed.
local DEFAULTS = {
    scale   = 1,      -- wheel size multiplier
    cursor  = true,   -- open at cursor (false = screen center)
    padding = 0.20,   -- wheel stays this far (fraction of screen) from every edge
    dim     = 0.35,   -- background dim while open (0 = off)
    combatCast = true,  -- BETA: hover + click casting in combat
    combatButton = "LeftButton", -- which mouse button casts in combat
    combatX = 0,      -- combat wheel offset from screen center, in pixels
    combatY = 0,
    debug   = false,  -- print selection on release
}


-- Rings, in tab order. Ctrl wins if both modifiers are held.
-- color = ring indicator text; tint = multiplier on the cyan wedge art.
local RINGS = {
    { key = "base",  label = "Base",  color = { 0.43, 0.84, 0.94 }, tint = { 1, 1,    1    } },
    { key = "shift", label = "Shift", color = { 0.78, 0.58, 1.00 }, tint = { 1, 0.65, 1    } },
    { key = "ctrl",  label = "Ctrl",  color = { 0.55, 1.00, 0.40 }, tint = { 1, 1,    0.43 } },
}
local RING_BY_KEY = {}
for _, r in ipairs(RINGS) do RING_BY_KEY[r.key] = r end

-- Mouse buttons that can cast from the combat wheel (middle opens it).
-- Named by physical position: on most mice Button4 is the back thumb
-- button and Button5 is forward (mouse software can remap these).
local CAST_BUTTONS = {
    { key = "LeftButton",  short = "Left",    verb = "left-click",                    tip = "Left mouse button" },
    { key = "RightButton", short = "Right",   verb = "right-click",                   tip = "Right mouse button" },
    { key = "Button4",     short = "Back",    verb = "press your back thumb button",  tip = "Back thumb button (mouse button 4)" },
    { key = "Button5",     short = "Forward", verb = "press your forward thumb button", tip = "Forward thumb button (mouse button 5)" },
}
local ALL_MOUSE = { "LeftButton", "RightButton", "MiddleButton", "Button4", "Button5" }

local TYPE_COLORS = {
    spell = { 0.72, 0.50, 1.00 },
    item  = { 0.90, 0.80, 0.55 },
    macro = { 0.85, 0.85, 0.85 },
}

------------------------------------------------------------
-- Geometry (matches the 512px art)
------------------------------------------------------------
local N         = 8
local SEG       = 2 * math.pi / N
local K         = SIZE / 512
local ICON_R    = 174 * K
local INNER_R   = 104 * K
local ICON_SIZE = 56 * K
local HIT_SIZE  = 84 * K
local atan2     = math.atan2 or function(y, x) return math.atan(y, x) end

local db
local activeRing = "base"
local editing = false
local selected
local Open, Close, Refresh, SyncCombatButtons
local originX, originY   -- cursor position when the wheel opened
local curScale = 1        -- scale of the wheel as currently shown
local applied = { x = 0, y = 0, scale = 1, combat = false, button = "LeftButton" }  -- live combat state
local AfterEdit           -- set by the settings panel
local embedded = false    -- true while the editor lives inside the settings window
local CloseSettings       -- set by the settings panel
local SyncSettings        -- set by the settings panel

local function S(key)
    local v = db and db.settings and db.settings[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

------------------------------------------------------------
-- API shims (retail vs classic names)
------------------------------------------------------------
local function SpellIcon(x)
    if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(x) end
    if GetSpellTexture then return GetSpellTexture(x) end
end
local function SpellName(id)
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    if GetSpellInfo then return (GetSpellInfo(id)) end
end
local function ItemIcon(x)
    if C_Item and C_Item.GetItemIconByID then return C_Item.GetItemIconByID(x) end
    if GetItemIcon then return GetItemIcon(x) end
end
local function ItemName(id)
    if C_Item and C_Item.GetItemNameByID then return C_Item.GetItemNameByID(id) end
    if GetItemInfo then return (GetItemInfo(id)) end
end
local function PickupSpellAny(x)
    if C_Spell and C_Spell.PickupSpell then C_Spell.PickupSpell(x)
    elseif PickupSpell then PickupSpell(x) end
end
local function PickupItemAny(x)
    if C_Item and C_Item.PickupItem then C_Item.PickupItem(x)
    elseif PickupItem then PickupItem(x) end
end

local function SpellCD(x)
    if C_Spell and C_Spell.GetSpellCooldown then
        local info = C_Spell.GetSpellCooldown(x)
        if info then return info.startTime, info.duration, info.modRate end
    elseif GetSpellCooldown then
        local st, dur = GetSpellCooldown(x)
        return st, dur
    end
end
local function ItemCD(id)
    if C_Container and C_Container.GetItemCooldown then
        local st, dur = C_Container.GetItemCooldown(id)
        return st, dur
    elseif GetItemCooldown then
        local st, dur = GetItemCooldown(id)
        return st, dur
    end
end
local function SlotCD(s)
    if s.type == "spell" then return SpellCD(s.id or s.name) end
    if s.type == "item" and s.id then return ItemCD(s.id) end
    if s.type == "macro" then
        local sid = GetMacroSpell and GetMacroSpell(s.name)
        if sid then return SpellCD(sid) end
        local _, link = GetMacroItem and GetMacroItem(s.name)
        local iid = link and tonumber(link:match("item:(%d+)"))
        if iid then return ItemCD(iid) end
    end
end

local function FormatCD(left)
    if left >= 3600 then return ("%dh"):format(math.ceil(left / 3600)), 1, 1, 1 end
    if left >= 60   then return ("%dm"):format(math.ceil(left / 60)), 1, 1, 1 end
    if left >= 3    then return ("%d"):format(math.ceil(left)), 1, 1, 1 end
    return ("%.1f"):format(left), 1, 0.25, 0.25
end

local function SlotIcon(s)
    if not s then return nil end
    if s.type == "spell" then return SpellIcon(s.id or s.name) end
    if s.type == "item"  then return ItemIcon(s.id or s.name) end
    if s.type == "macro" then
        local _, icon = GetMacroInfo(s.name)
        return icon or s.icon
    end
end

local function PickupSlot(s)
    if s.type == "spell" then PickupSpellAny(s.id or s.name)
    elseif s.type == "item" then PickupItemAny(s.id or s.name)
    elseif s.type == "macro" and PickupMacro then PickupMacro(s.name) end
end

-- Turn whatever is on the cursor into a slot entry.
local function SlotFromCursor()
    local kind, a, b, c = GetCursorInfo()
    if kind == "spell" then
        local name = c and SpellName(c)
        if not name and GetSpellBookItemName then name = GetSpellBookItemName(a, b) end
        if name then return { type = "spell", id = c, name = name } end
    elseif kind == "item" then
        return { type = "item", id = a, name = ItemName(a) or ("item:" .. a) }
    elseif kind == "macro" then
        local name, icon = GetMacroInfo(a)
        if name then return { type = "macro", name = name, icon = icon } end
    end
end

-- Slots of the ring currently shown.
local function Slots()
    return db.rings[activeRing]
end

local function RingEnabled(key)
    return db and not db.disabled and not (db.ringOff and db.ringOff[key])
end

-- Ring the held modifiers point at, skipping disabled rings. Returns nil
-- when nothing enabled fits, and callers keep the current ring.
local function ModifierRing()
    if IsControlKeyDown() and RingEnabled("ctrl") then return "ctrl" end
    if IsShiftKeyDown() and RingEnabled("shift") then return "shift" end
    if RingEnabled("base") then return "base" end
end

local function ResetRings()
    db.rings = {}
    for _, r in ipairs(RINGS) do
        db.rings[r.key] = {}
        for i = 1, N do db.rings[r.key][i] = false end
    end
end

------------------------------------------------------------
-- Frames
------------------------------------------------------------
local dim = CreateFrame("Frame", nil, UIParent)
dim:SetAllPoints(UIParent)
dim:SetFrameStrata("HIGH")
local dimTex = dim:CreateTexture(nil, "BACKGROUND")
dimTex:SetAllPoints()
dimTex:SetColorTexture(0, 0, 0, 1)
dim:Hide()

local wheel = CreateFrame("Frame", "RadialCastWheel", UIParent)
wheel:SetSize(SIZE, SIZE)
wheel:SetFrameStrata("DIALOG")
wheel:SetClampedToScreen(true)
wheel:SetMovable(true)
wheel:Hide()

-- Escape closes the editor. (Not using UISpecialFrames: WoW closes
-- those whenever the spellbook opens.) Every other key passes through.
wheel:SetScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" and editing then
        if not InCombatLockdown() then self:SetPropagateKeyboardInput(false) end
        if embedded and CloseSettings then CloseSettings() else self:Hide() end
    end
end)

local bg = wheel:CreateTexture(nil, "BACKGROUND")
bg:SetAllPoints()
bg:SetTexture(MEDIA .. "wheel")

local hl = wheel:CreateTexture(nil, "BORDER")
hl:SetAllPoints()
hl:SetTexture(MEDIA .. "highlight")
hl:Hide()

local function Text(font, size, r, g, b, y)
    local fs = wheel:CreateFontString(nil, "OVERLAY")
    if not fs:SetFont(font, size, "") then fs:SetFontObject(GameFontNormal) end
    fs:SetTextColor(r, g, b)
    fs:SetPoint("CENTER", 0, y)
    fs:SetWidth(180 * K)
    fs:SetWordWrap(true)
    return fs
end
local title    = Text("Fonts\\MORPHEUS.TTF", 18, 0.90, 0.85, 0.75, 26 * K)
local category = Text("Fonts\\FRIZQT__.TTF", 12, 0.72, 0.50, 1.00, 8 * K)
local label    = Text("Fonts\\MORPHEUS.TTF", 16, 1, 1, 1, -24 * K)

-- Ring indicator: a single disabled tab-style button in the hub,
-- under the spell name, showing which ring is active.
local ringBadge = CreateFrame("Button", nil, wheel, "UIPanelButtonTemplate")
ringBadge:SetSize(70, 20)
ringBadge:SetPoint("CENTER", wheel, "CENTER", 0, -54 * K)
ringBadge:EnableMouse(false)
ringBadge:Disable()

local function UpdateRingIndicator()
    ringBadge:SetText(RING_BY_KEY[activeRing].label)
    ringBadge:SetShown(not editing)   -- the editor has its own tabs
    local t = RING_BY_KEY[activeRing].tint
    hl:SetVertexColor(t[1], t[2], t[3])
end

local hint = wheel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
hint:SetPoint("TOP", wheel, "BOTTOM", 0, -8)
hint:SetTextColor(0.85, 0.80, 0.70)
hint:SetWidth(SIZE)
hint:SetWordWrap(true)

local complete = CreateFrame("Button", nil, wheel, "UIPanelButtonTemplate")
complete:SetSize(140, 26)
complete:SetPoint("TOP", hint, "BOTTOM", 0, -8)
complete:SetText("COMPLETE")
complete:Hide()

-- Ring tabs above the wheel (edit mode only)
local tabs = {}
local tabRow = CreateFrame("Frame", nil, wheel)
tabRow:SetSize(3 * 86, 24)
tabRow:SetPoint("BOTTOM", wheel, "TOP", 0, 6)
tabRow:Hide()
for idx, r in ipairs(RINGS) do
    local tab = CreateFrame("Button", nil, tabRow, "UIPanelButtonTemplate")
    tab:SetSize(80, 22)
    tab:SetPoint("LEFT", (idx - 1) * 86, 0)
    tab:SetText(r.label)
    tab.key = r.key
    tabs[idx] = tab
end

-- "Ring is off" overlay (edit mode only). Dims the ring using the wheel
-- art tinted black, blocks editing, and offers an Enable button.
local offOverlay = CreateFrame("Frame", nil, wheel)
offOverlay:SetAllPoints()
offOverlay:EnableMouse(true)
offOverlay:Hide()
local offShade = offOverlay:CreateTexture(nil, "BACKGROUND")
offShade:SetAllPoints()
offShade:SetTexture(MEDIA .. "wheel")
offShade:SetVertexColor(0, 0, 0, 0.75)
local offText = offOverlay:CreateFontString(nil, "OVERLAY")
if not offText:SetFont("Fonts\\MORPHEUS.TTF", 18, "") then offText:SetFontObject(GameFontNormalLarge) end
offText:SetTextColor(0.90, 0.85, 0.75)
offText:SetPoint("CENTER", 0, 22)
local offBtn = CreateFrame("Button", nil, offOverlay, "UIPanelButtonTemplate")
offBtn:SetSize(150, 26)
offBtn:SetPoint("CENTER", 0, -16)

local function UpdateOffOverlay()
    local off = editing and db and not RingEnabled(activeRing)
    -- The hub text sits right where the overlay message goes, so hide it
    -- (and the highlight wedge) while the ring is off.
    title:SetShown(not off)
    category:SetShown(not off)
    label:SetShown(not off)
    if off then hl:Hide() end
    if off then
        offOverlay:SetFrameLevel(wheel:GetFrameLevel() + 20)  -- above the slot hit areas
        if db.disabled then
            offText:SetText("RadialCast is disabled")
            offBtn:SetText("Enable RadialCast")
        else
            offText:SetText(RING_BY_KEY[activeRing].label .. " ring is off")
            offBtn:SetText("Enable")
        end
        offOverlay:Show()
    else
        offOverlay:Hide()
    end
end

local fade = wheel:CreateAnimationGroup()
local fa = fade:CreateAnimation("Alpha")
fa:SetFromAlpha(0)
fa:SetToAlpha(1)
fa:SetDuration(0.08)

------------------------------------------------------------
-- Selection display
------------------------------------------------------------
local icons, pluses, hits, cells = {}, {}, {}, {}

-- Classic action-button art that ships with the client.
local TEX_BORDER = "Interface\\Buttons\\UI-Quickslot2"        -- button frame
local TEX_SOCKET = "Interface\\Buttons\\UI-Quickslot"         -- empty recessed slot
local TEX_HILITE = "Interface\\Buttons\\ButtonHilight-Square" -- hover glow
local FRAME_RATIO = 66 / 36  -- the frame art is drawn larger than the icon it wraps

local function SizeCell(j, scale)
    local c, sz = cells[j], ICON_SIZE * scale
    c.back:SetSize(sz + 4, sz + 4)
    c.socket:SetSize(sz * FRAME_RATIO, sz * FRAME_RATIO)
    c.border:SetSize(sz * FRAME_RATIO, sz * FRAME_RATIO)
    c.hilite:SetSize(sz, sz)
    icons[j]:SetSize(sz, sz)
end

local function SetSelected(i)
    if i == selected then return end
    selected = i
    for j, t in ipairs(icons) do
        local v = (editing or j == i) and 1 or 0.6
        t:SetVertexColor(v, v, v)
        SizeCell(j, (j == i) and 1.12 or 1)
        cells[j].hilite:SetShown(j == i)
        pluses[j]:SetAlpha(j == i and 1 or 0.5)
    end
    if not i then
        hl:Hide()
        label:SetText("")
        category:SetText("")
        return
    end
    hl:SetRotation(-(i - 0.5) * SEG)  -- SetRotation is counterclockwise
    hl:Show()
    local s = db and Slots()[i]
    if s then
        label:SetText(s.name or "?")
        category:SetText(s.type:upper())
        local c = TYPE_COLORS[s.type] or TYPE_COLORS.spell
        category:SetTextColor(c[1], c[2], c[3])
    else
        label:SetText("Empty")
        category:SetText(editing and "" or "/rcast to customize")
        category:SetTextColor(0.80, 0.70, 0.50)
    end
end

local function ClearCD(c)
    if c.cd.Clear then c.cd:Clear() else c.cd:SetCooldown(0, 0) end
    c.cdStart, c.cdDur = nil, nil
    c.cdText:SetText("")
end

local function UpdateCooldown(i)
    local c, s = cells[i], Slots()[i]
    if not s then ClearCD(c) return end
    local start, dur, rate = SlotCD(s)
    local ok = pcall(function()
        if start and dur and dur > 0 then
            if c.cdStart ~= start or c.cdDur ~= dur then
                c.cd:SetCooldown(start, dur, rate)
                c.cdStart, c.cdDur = start, dur
            end
            local left = start + dur - GetTime()
            if dur > 1.5 and left > 0 then       -- no number for the GCD
                local txt, r, g, b = FormatCD(left)
                c.cdText:SetText(txt)
                c.cdText:SetTextColor(r, g, b)
            else
                c.cdText:SetText("")
            end
        elseif c.cdDur then
            ClearCD(c)
        else
            c.cdText:SetText("")
        end
    end)
    if not ok then
        -- If the client hides cooldown math from addons, still hand the
        -- values to the swipe, which can display them natively.
        if start and dur then pcall(c.cd.SetCooldown, c.cd, start, dur) end
        c.cdText:SetText("")
    end
end

-- Each slot is isolated: a cooldown API problem can't break the wheel.
local function UpdateCooldowns()
    for i = 1, N do pcall(UpdateCooldown, i) end
end

function Refresh()
    if not db then return end
    UpdateRingIndicator()
    for i = 1, N do pcall(ClearCD, cells[i]) end  -- slot contents may have changed
    for i = 1, N do
        local s = Slots()[i]
        icons[i]:SetTexture(SlotIcon(s) or 134400)
        icons[i]:SetShown(s and true or false)
        pluses[i]:SetShown(not s)
        cells[i].socket:SetShown(not s)
    end
    UpdateCooldowns()
    local sel = selected
    selected = -1
    SetSelected(sel)
    UpdateOffOverlay()   -- last, so selection can't re-show hub text or the wedge
end

------------------------------------------------------------
-- Slots: icon, empty marker, and an edit-mode hit area
------------------------------------------------------------
local function OpenSpellbook()
    if InCombatLockdown() then
        print("|cff6fd6f0RadialCast|r: can't open the spellbook in combat")
        return
    end
    if PlayerSpellsUtil and PlayerSpellsUtil.OpenToSpellBookTab then
        PlayerSpellsUtil.OpenToSpellBookTab()          -- retail 11.x
    elseif SpellBookFrame and not SpellBookFrame:IsShown() and ToggleSpellBook then
        ToggleSpellBook(BOOKTYPE_SPELL or "spell")     -- classic / older retail
    end
end

local function DropOn(i)
    local new = SlotFromCursor()
    if not new then return end
    local old = Slots()[i]
    Slots()[i] = new
    ClearCursor()
    if old then PickupSlot(old) end  -- swap: old entry goes on the cursor
    Refresh()
    SyncCombatButtons()
end

for i = 1, N do
    local a = (i - 0.5) * SEG
    local x, y = math.sin(a) * ICON_R, math.cos(a) * ICON_R

    -- Layers, back to front: black backing, empty socket, icon,
    -- classic frame, hover glow.
    local back = wheel:CreateTexture(nil, "ARTWORK", nil, -3)
    back:SetPoint("CENTER", x, y)
    back:SetColorTexture(0, 0, 0, 0.85)

    local socket = wheel:CreateTexture(nil, "ARTWORK", nil, -2)
    socket:SetPoint("CENTER", x, y)
    socket:SetTexture(TEX_SOCKET)
    socket:SetAlpha(0.9)

    local t = wheel:CreateTexture(nil, "ARTWORK", nil, 0)
    t:SetPoint("CENTER", x, y)
    t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icons[i] = t

    local border = wheel:CreateTexture(nil, "OVERLAY", nil, 0)
    border:SetPoint("CENTER", x, y - 1)  -- the art sits 1px low in Blizzard's own buttons too
    border:SetTexture(TEX_BORDER)

    local hilite = wheel:CreateTexture(nil, "OVERLAY", nil, 1)
    hilite:SetPoint("CENTER", x, y)
    hilite:SetTexture(TEX_HILITE)
    hilite:SetBlendMode("ADD")
    hilite:Hide()

    -- Cooldown swipe tracks the icon (and its hover scale) exactly.
    local cd = CreateFrame("Cooldown", nil, wheel, "CooldownFrameTemplate")
    cd:SetAllPoints(t)
    if cd.SetHideCountdownNumbers then cd:SetHideCountdownNumbers(true) end
    if cd.SetDrawEdge then cd:SetDrawEdge(false) end

    -- Our own countdown text, on a layer above the swipe.
    local over = CreateFrame("Frame", nil, wheel)
    over:SetAllPoints(t)
    over:SetFrameLevel(cd:GetFrameLevel() + 2)
    local cdText = over:CreateFontString(nil, "OVERLAY")
    if not cdText:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE") then
        cdText:SetFontObject(NumberFontNormalLarge or GameFontHighlightLarge)
    end
    cdText:SetPoint("CENTER")

    cells[i] = { back = back, socket = socket, border = border, hilite = hilite,
                 cd = cd, cdText = cdText }
    SizeCell(i, 1)

    -- Empty-slot marker: a thin gold plus
    local plus = CreateFrame("Frame", nil, wheel)
    plus:SetSize(ICON_SIZE, ICON_SIZE)
    plus:SetPoint("CENTER", x, y)
    local arm = ICON_SIZE * 0.42
    for _, dims in ipairs({ { arm, 2 }, { 2, arm } }) do
        local bar = plus:CreateTexture(nil, "ARTWORK")
        bar:SetSize(dims[1], dims[2])
        bar:SetPoint("CENTER")
        bar:SetColorTexture(0.80, 0.70, 0.50, 1)
    end
    plus:SetAlpha(0.5)
    plus:Hide()
    pluses[i] = plus

    local hit = CreateFrame("Button", nil, wheel)
    hit:SetSize(HIT_SIZE, HIT_SIZE)
    hit:SetPoint("CENTER", x, y)
    hit:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    hit:RegisterForDrag("LeftButton")
    hit:EnableMouse(false)
    hits[i] = hit

    hit:SetScript("OnEnter", function(self)
        SetSelected(i)
        local s = Slots()[i]
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if s and s.type == "spell" and s.id and GameTooltip.SetSpellByID then
            GameTooltip:SetSpellByID(s.id)
        elseif s and s.type == "item" and s.id and GameTooltip.SetItemByID then
            GameTooltip:SetItemByID(s.id)
        elseif s then
            GameTooltip:SetText(s.name or "?")
        end
        if s then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Click to open your spellbook", 0.7, 0.7, 0.7)
            GameTooltip:AddLine("Drag to pick up  ·  Right-click to clear", 0.7, 0.7, 0.7)
        else
            GameTooltip:SetText("Empty slot")
            GameTooltip:AddLine("Click to open your spellbook", 1, 1, 1)
            GameTooltip:AddLine("Drag a spell, item, or macro here", 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    hit:SetScript("OnLeave", function()
        SetSelected(nil)
        GameTooltip:Hide()
    end)
    hit:SetScript("OnReceiveDrag", function() DropOn(i) end)
    hit:SetScript("OnClick", function(_, btn)
        if btn == "RightButton" then
            Slots()[i] = false
            Refresh()
            SyncCombatButtons()
        elseif GetCursorInfo() then
            DropOn(i)
        else
            OpenSpellbook()   -- empty or filled: open it so they can pick/change
        end
    end)
    hit:SetScript("OnDragStart", function()
        local s = Slots()[i]
        if not s then return end
        Slots()[i] = false
        PickupSlot(s)
        Refresh()
        SyncCombatButtons()
    end)
end

-- Center hub: drag to move the wheel in edit mode
local hub = CreateFrame("Button", nil, wheel)
hub:SetSize(INNER_R * 1.6, INNER_R * 1.6)
hub:SetPoint("CENTER")
hub:RegisterForDrag("LeftButton")
hub:EnableMouse(false)
hub:SetScript("OnDragStart", function() wheel:StartMoving() end)
hub:SetScript("OnDragStop", function() wheel:StopMovingOrSizing() end)

local function ShowRing(key)
    activeRing = key
    for _, tab in ipairs(tabs) do
        if tab.key == key then tab:LockHighlight() else tab:UnlockHighlight() end
        tab:SetText(RING_BY_KEY[tab.key].label)
        tab:SetEnabled(RingEnabled(tab.key) and true or false)
    end
    Refresh()
end

for _, tab in ipairs(tabs) do
    tab:SetScript("OnClick", function(self)
        ClearCursor()
        ShowRing(self.key)
    end)
end

------------------------------------------------------------
-- Modes
------------------------------------------------------------
local function SetEditing(on)
    editing = on
    for i = 1, N do hits[i]:EnableMouse(on) end
    hub:EnableMouse(on and not embedded)      -- no dragging inside the window
    complete:SetShown(on and not embedded)    -- closing the window finishes editing
    tabRow:SetShown(on)
    -- Keyboard only in edit mode, and only set up out of combat so keys
    -- can never get swallowed.
    if on and not InCombatLockdown() then
        wheel:EnableKeyboard(true)
        wheel:SetPropagateKeyboardInput(true)
    else
        wheel:EnableKeyboard(false)
    end
    title:SetText(on and "Customize" or "Quick Spell")
    if on and embedded then
        hint:SetText("Drag spells, items, or macros onto a slot  ·  Click a slot to open your spellbook  ·  Right-click clears")
    elseif on then
        hint:SetText("Drag spells, items, or macros onto a slot  ·  Right-click clears  ·  Drag center to move")
    else
        hint:SetText("Move mouse to select  ·  Shift / Ctrl swap rings  ·  Release to confirm")
    end
    Refresh()
end

local function OpenEditor()
    if wheel:IsShown() then wheel:Hide() end
    SetEditing(true)
    ShowRing("base")
    curScale = S("scale")
    wheel:SetScale(curScale)
    wheel:ClearAllPoints()
    wheel:SetPoint("CENTER", UIParent, "CENTER")
    selected = -1
    SetSelected(nil)
    wheel:Show()
    fade:Play()
end

complete:SetScript("OnClick", function()
    wheel:Hide()
    print("|cff6fd6f0RadialCast|r: wheel saved")
    if AfterEdit then AfterEdit() end
end)

wheel:SetScript("OnHide", function()
    dim:Hide()
    GameTooltip:Hide()
    if editing then SetEditing(false) end
end)

local cdTimer = 0

local function UpdateSelection()
    -- Live ring swap: Shift/Ctrl change the slot contents instantly.
    -- Aim is untouched, so you stay on the same segment.
    local ring = ModifierRing() or activeRing
    if ring ~= activeRing then
        activeRing = ring
        Refresh()
    end
    -- Direction is measured from where the cursor was on press, so it
    -- still works when the wheel got pushed inward by PADDING.
    local scale = UIParent:GetEffectiveScale()
    local mx, my = GetCursorPosition()
    local dx, dy = mx / scale - originX, my / scale - originY
    local dead = INNER_R * curScale
    if dx * dx + dy * dy < dead * dead then
        SetSelected(nil)
        return
    end
    local a = atan2(dx, dy)
    if a < 0 then a = a + 2 * math.pi end
    SetSelected(math.floor(a / SEG) % N + 1)
end

wheel:SetScript("OnUpdate", function(self, elapsed)
    -- Order matters: closing and selection first, cosmetics last, so a
    -- problem in one can't freeze the others.
    if not editing then
        if IsMouseButtonDown and not IsMouseButtonDown("MiddleButton") then
            Close()
            return
        end
        UpdateSelection()
    end
    cdTimer = cdTimer + (elapsed or 0)
    if cdTimer >= 0.1 then
        cdTimer = 0
        UpdateCooldowns()
    end
end)

local combatOffNotified = false

function Open()
    if editing then return end
    if InCombatLockdown() and not applied.combat then
        if not combatOffNotified then
            combatOffNotified = true
            print("|cff6fd6f0RadialCast|r: combat casting is off. Turn it on in /rcast (BETA).")
        end
        return
    end
    wheel:ClearAllPoints()
    if InCombatLockdown() then
        -- Visuals must sit exactly on top of the secure buttons, so use
        -- where they really are (settings changed mid-fight wait for later).
        curScale = applied.scale
        wheel:SetScale(curScale)
        wheel:SetPoint("CENTER", UIParent, "CENTER", applied.x / curScale, applied.y / curScale)
        originX = UIParent:GetWidth() / 2 + applied.x
        originY = UIParent:GetHeight() / 2 + applied.y
        local verb = "left-click"
        for _, b in ipairs(CAST_BUTTONS) do if b.key == applied.button then verb = b.verb end end
        hint:SetText("Hover a spell and " .. verb .. " to cast  ·  Shift / Ctrl swap rings")
    else
        hint:SetText("Move mouse to select  ·  Shift / Ctrl swap rings  ·  Release to confirm")
        curScale = S("scale")
        wheel:SetScale(curScale)
        local w, h = UIParent:GetWidth(), UIParent:GetHeight()
        local x, y
        if S("cursor") then
            local cx, cy = GetCursorPosition()
            local s = UIParent:GetEffectiveScale()
            x, y = cx / s, cy / s
            originX, originY = x, y
            -- Keep the whole wheel inside a box inset by the padding setting.
            -- If the screen is too small for that, fall back to centered.
            local pad, half = S("padding"), SIZE * curScale / 2
            local minX, maxX = w * pad + half, w * (1 - pad) - half
            local minY, maxY = h * pad + half, h * (1 - pad) - half
            x = (minX <= maxX) and math.max(minX, math.min(maxX, x)) or w / 2
            y = (minY <= maxY) and math.max(minY, math.min(maxY, y)) or h / 2
        else
            x, y = w / 2, h / 2
            originX, originY = x, y
        end
        -- SetPoint offsets are in the wheel's own (scaled) units.
        wheel:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x / curScale, y / curScale)
    end
    activeRing = ModifierRing() or activeRing
    cdTimer = 0
    Refresh()
    selected = -1
    SetSelected(nil)
    local d = S("dim")
    dim:SetAlpha(d)
    if d > 0 then dim:Show() end
    wheel:Show()
    fade:Play()
end

function Close()
    if editing or not wheel:IsShown() then return end
    wheel:Hide()
    if S("debug") then
        local s = selected and Slots()[selected]
        print("|cff6fd6f0RadialCast|r: " .. (s and s.name or "cancelled"))
    end
end

------------------------------------------------------------
-- Combat buttons: 8 real secure buttons at a fixed spot, shown by the
-- game itself whenever you're in combat (no snippets needed). Each holds
-- all three rings via modifier attributes, which the game resolves at
-- click time: plain = Base, shift- = Shift, ctrl- / ctrl-shift- = Ctrl.
------------------------------------------------------------
local combatFrame = CreateFrame("Frame", "RadialCastCombatFrame", UIParent, "SecureFrameTemplate")
combatFrame:SetSize(SIZE, SIZE)
combatFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
combatFrame:SetFrameStrata("DIALOG")
combatFrame:Hide()

local combatBtns = {}
for i = 1, N do
    local a = (i - 0.5) * SEG
    local b = CreateFrame("Button", "RadialCastCombat" .. i, combatFrame, "SecureActionButtonTemplate")
    b:SetSize(HIT_SIZE, HIT_SIZE)
    b:SetPoint("CENTER", math.sin(a) * ICON_R, math.cos(a) * ICON_R)
    b:RegisterForClicks("LeftButtonUp")
    b:SetAttribute("useOnKeyDown", false)
    -- Let middle (wheel) and right (camera) clicks through to the game.
    if b.SetPassThroughButtons then
        pcall(b.SetPassThroughButtons, b, "MiddleButton", "RightButton")
    end
    -- Close the wheel once a click casts (insecure hook, allowed in combat).
    b:HookScript("PostClick", function()
        if wheel:IsShown() and not editing then
            Close()
            selected = nil   -- don't let the later middle release reuse it
        end
    end)
    combatBtns[i] = b
end

-- Which ring each modifier prefix casts from, skipping disabled rings.
-- nil = no attributes for that prefix, so the game falls back to Base.
local ALL_PREFIXES = { "", "shift-", "ctrl-", "ctrl-shift-" }
local function RingForPrefix(prefix)
    if prefix == "" then return RingEnabled("base") and "base" or nil end
    if prefix == "shift-" then return RingEnabled("shift") and "shift" or nil end
    if prefix == "ctrl-" then return RingEnabled("ctrl") and "ctrl" or nil end
    if RingEnabled("ctrl") then return "ctrl" end          -- ctrl-shift-
    if RingEnabled("shift") then return "shift" end
end

local function ClearPrefix(btn, prefix)
    for _, k in ipairs({ "type", "spell", "item", "macro" }) do
        btn:SetAttribute(prefix .. k, nil)
    end
end

local function ApplySlot(btn, prefix, s)
    for _, k in ipairs({ "spell", "item", "macro" }) do
        btn:SetAttribute(prefix .. k, nil)
    end
    if not s then
        -- Empty modifier slots get a do-nothing type so they don't fall
        -- back to the Base spell. Empty Base slots just have no type.
        btn:SetAttribute(prefix .. "type", prefix ~= "" and "radialnone" or nil)
        return
    end
    btn:SetAttribute(prefix .. "type", s.type)
    if s.type == "item" and s.id then
        btn:SetAttribute(prefix .. "item", "item:" .. s.id)
    else
        btn:SetAttribute(prefix .. s.type, s.name)
    end
end

local combatPending = false
function SyncCombatButtons()
    if not db then return end
    if InCombatLockdown() then combatPending = true return end
    combatPending = false
    for i = 1, N do
        for _, prefix in ipairs(ALL_PREFIXES) do
            local ring = RingForPrefix(prefix)
            if ring then
                ApplySlot(combatBtns[i], prefix, db.rings[ring][i])
            else
                ClearPrefix(combatBtns[i], prefix)
            end
        end
    end
end

------------------------------------------------------------
-- Trigger: secure action button. PreClick sets the action out of
-- combat; in combat attributes are locked, so nothing casts.
------------------------------------------------------------
local trigger = CreateFrame("Button", "RadialCastTrigger", UIParent, "SecureActionButtonTemplate")
trigger:RegisterForClicks("AnyDown", "AnyUp")
trigger:SetAttribute("useOnKeyDown", false)

local function ClearAction()
    for _, k in ipairs({ "type", "spell", "item", "macro" }) do
        trigger:SetAttribute(k, nil)
    end
end

trigger:SetScript("PreClick", function(_, _, down)
    if editing then return end
    if down then
        if not InCombatLockdown() then ClearAction() end
        Open()
        return
    end
    local s = selected and Slots()[selected]
    if s and not InCombatLockdown() then
        trigger:SetAttribute("type", s.type)
        if s.type == "item" and s.id then
            trigger:SetAttribute("item", "item:" .. s.id)
        else
            trigger:SetAttribute(s.type, s.name)
        end
    end
    -- In combat, casting happens by left-clicking the hovered slot instead.
end)

trigger:SetScript("PostClick", function(_, _, down)
    if down or editing then return end
    Close()
    if not InCombatLockdown() then ClearAction() end
end)

------------------------------------------------------------
-- Load, bind, slash commands
------------------------------------------------------------
------------------------------------------------------------
-- Activation: which middle-mouse bindings exist, and whether the combat
-- buttons are live. Bindings are locked in combat, so changes made
-- mid-fight wait for PLAYER_REGEN_ENABLED.
------------------------------------------------------------
local BIND_RULES = {
    { "",            function() return RingEnabled("base") end },
    { "SHIFT-",      function() return RingEnabled("shift") end },
    { "CTRL-",       function() return RingEnabled("ctrl") end },
    { "CTRL-SHIFT-", function() return RingEnabled("ctrl") or RingEnabled("shift") end },
}

local function AnyRingEnabled()
    return RingEnabled("base") or RingEnabled("shift") or RingEnabled("ctrl")
end

-- Move/scale the combat buttons to match settings (out of combat only).
local function ApplyCombatLayout()
    local sc, x, y = S("scale"), S("combatX"), S("combatY")
    combatFrame:SetScale(sc)
    combatFrame:ClearAllPoints()
    combatFrame:SetPoint("CENTER", UIParent, "CENTER", x / sc, y / sc)
    applied.x, applied.y, applied.scale = x, y, sc

    -- Only the chosen button casts; every other mouse button passes
    -- through to the game, even over the invisible slots.
    local key = S("combatButton")
    local pass = {}
    for _, k in ipairs(ALL_MOUSE) do if k ~= key then pass[#pass + 1] = k end end
    for _, b in ipairs(combatBtns) do
        b:RegisterForClicks(key .. "Up")
        if b.SetPassThroughButtons then pcall(b.SetPassThroughButtons, b, unpack(pass)) end
    end
    applied.button = key
end

local statePending = false
local function ApplyActivation()
    if InCombatLockdown() then statePending = true return false end
    statePending = false
    ApplyCombatLayout()
    ClearOverrideBindings(trigger)
    for _, rule in ipairs(BIND_RULES) do
        if rule[2]() then
            SetOverrideBindingClick(trigger, true, rule[1] .. BIND, "RadialCastTrigger")
        end
    end
    applied.combat = AnyRingEnabled() and S("combatCast") and true or false
    if applied.combat then
        -- The game shows/hides these itself, so it works in combat.
        RegisterStateDriver(combatFrame, "visibility", "[combat] show; hide")
    else
        UnregisterStateDriver(combatFrame, "visibility")
        combatFrame:Hide()
    end
    SyncCombatButtons()
    return true
end

offBtn:SetScript("OnClick", function()
    if db.disabled then
        db.disabled = false
    else
        db.ringOff = db.ringOff or {}
        db.ringOff[activeRing] = nil
    end
    ApplyActivation()
    ShowRing(activeRing)
    if SyncSettings then SyncSettings() end
end)

local function RequestCombatLayout()
    if InCombatLockdown() then statePending = true return false end
    ApplyCombatLayout()
    return true
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:SetScript("OnEvent", function(_, event, arg)
    if event == "ADDON_LOADED" and arg == ADDON then
        -- Layouts are per character. The first character to load v0.6
        -- inherits the old account-wide layout; everyone else starts empty.
        if not RadialCastCharDB then
            RadialCastCharDB = {}
            local acct = RadialCastDB
            if acct and not acct.migrated and (acct.rings or acct.slots) then
                RadialCastCharDB.rings = acct.rings
                RadialCastCharDB.slots = acct.slots
                print("|cff6fd6f0RadialCast|r: moved your existing layout to this character")
            end
            RadialCastDB = { migrated = true }
        end
        db = RadialCastCharDB
        if not db.rings then
            local old = db.slots      -- v0.4 single-ring layout
            ResetRings()
            if old then
                for i = 1, N do db.rings.base[i] = old[i] or false end
            end
            db.slots = nil
        end
        for _, r in ipairs(RINGS) do
            db.rings[r.key] = db.rings[r.key] or {}
            for i = 1, N do
                if db.rings[r.key][i] == nil then db.rings[r.key][i] = false end
            end
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if statePending then ApplyActivation()
        elseif combatPending then SyncCombatButtons() end
    elseif event == "PLAYER_LOGIN" then
        ApplyActivation()
        if db.disabled then
            print("|cff6fd6f0RadialCast|r: disabled (/rcast enable to turn it back on)")
        end
        SetEditing(false)
        local any = false
        for _, r in ipairs(RINGS) do
            for i = 1, N do if db.rings[r.key][i] then any = true end end
        end
        if not any then
            print("|cff6fd6f0RadialCast|r: type /rcast to set up your wheel")
        end
    end
end)

SLASH_RADIALCAST1 = "/rcast"
SLASH_RADIALCAST2 = "/radialcast"
------------------------------------------------------------
-- Settings panel (/rcast)
------------------------------------------------------------
local PANEL_W, PANEL_H = 800, 700
local LEFT_W = 340
local panel
local controls = {}

local function SetSetting(key, value)
    db.settings = db.settings or {}
    db.settings[key] = value
end

local function Section(parent, text, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", 18, y)
    fs:SetText(text)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", 18, y - 20)
    line:SetPoint("TOPRIGHT", -18, y - 20)
    line:SetColorTexture(0.8, 0.7, 0.5, 0.35)
    return fs
end

local function BetaChip(parent, anchor)
    local chip = CreateFrame("Frame", nil, parent)
    chip:SetSize(40, 16)
    chip:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
    local bg = chip:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.85, 0.45, 0.10, 0.9)
    local t = chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t:SetPoint("CENTER", 0, 0)
    t:SetText("BETA")
    return chip
end

local function Checkbox(parent, label, x, y, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb:SetPoint("TOPLEFT", x, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    fs:SetText(label)
    cb.label = fs
    cb:SetScript("OnClick", function(self)
        set(self:GetChecked() and true or false)
        if panel and panel.Sync then panel:Sync() end
    end)
    cb.Sync = function(self) self:SetChecked(get() and true or false) end
    controls[#controls + 1] = cb
    return cb
end

local function Slider(parent, label, y, minV, maxV, step, fmt, get, set)
    local title = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", 22, y)
    title:SetText(label)
    local val = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    val:SetPoint("TOPRIGHT", -22, y)
    local labels = { title, val }

    local sl = CreateFrame("Slider", nil, parent)
    sl:SetOrientation("HORIZONTAL")
    sl:SetSize(LEFT_W - 44, 18)
    sl:SetPoint("TOPLEFT", 22, y - 16)
    sl:EnableMouse(true)
    local track = sl:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT", 0, 0)
    track:SetPoint("RIGHT", 0, 0)
    track:SetHeight(4)
    track:SetColorTexture(0.30, 0.26, 0.20, 1)
    sl:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local thumb = sl:GetThumbTexture()
    if thumb then thumb:SetSize(32, 32) end
    sl:SetMinMaxValues(minV, maxV)
    sl:SetValueStep(step)
    if sl.SetObeyStepOnDrag then sl:SetObeyStepOnDrag(true) end

    sl:SetScript("OnValueChanged", function(self, v)
        v = math.floor(v / step + 0.5) * step
        val:SetText(fmt(v))
        if not self.syncing then set(v) end
    end)
    sl:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(self:GetValue() + delta * step)
    end)
    sl.Sync = function(self)
        self.syncing = true
        self:SetValue(get())
        val:SetText(fmt(get()))
        self.syncing = false
    end
    -- Grey out + block input (used when a feature is off).
    sl.SetActive = function(self, on)
        self:EnableMouse(on)
        self:SetAlpha(on and 1 or 0.35)
        for _, fs in ipairs(labels) do fs:SetAlpha(on and 1 or 0.35) end
    end
    controls[#controls + 1] = sl
    return sl
end

local function Pct(v) return ("%d%%"):format(math.floor(v * 100 + 0.5)) end
local function Px(v) return ("%+d px"):format(v) end

StaticPopupDialogs["RADIALCAST_CLEAR"] = {
    text = "Clear every slot in the Base, Shift, and Ctrl rings for this character?\n\nThis can't be undone.",
    button1 = "Clear all",
    button2 = CANCEL or "Cancel",
    OnShow = function(self)
        self:SetFrameStrata("FULLSCREEN_DIALOG")   -- never hidden behind the settings window
    end,
    OnAccept = function()
        ResetRings()
        Refresh()
        SyncCombatButtons()
        print("|cff6fd6f0RadialCast|r: all rings cleared")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    showAlert = true,
    preferredIndex = 3,
}

local function CombatNote()
    return InCombatLockdown() and "|cffff8080In combat: size and combat settings apply when combat ends.|r"
        or "Size and combat settings apply out of combat."
end

-- Move the live editor into the window's right column, and back out.
local function EmbedEditor(host)
    if wheel:IsShown() then wheel:Hide() end   -- resets any play/editor state
    embedded = true
    wheel:SetParent(host)
    wheel:SetFrameStrata("DIALOG")
    wheel:SetFrameLevel(host:GetFrameLevel() + 5)
    -- Fit the ring (plus tabs above and hint below) into the column.
    local w, h = host:GetWidth(), host:GetHeight()
    curScale = math.min((w - 30) / SIZE, (h - 150) / SIZE)
    wheel:SetScale(curScale)
    wheel:ClearAllPoints()
    wheel:SetPoint("CENTER", host, "CENTER", 0, -6 / curScale)
    SetEditing(true)
    ShowRing("base")
    selected = -1
    SetSelected(nil)
    wheel:Show()
end

local function ReleaseEditor()
    if not embedded then return end
    wheel:Hide()          -- OnHide ends edit mode
    embedded = false
    wheel:SetParent(UIParent)
    wheel:SetFrameStrata("DIALOG")
    SetEditing(false)
end

local function CreatePanel()
    local ok, f = pcall(CreateFrame, "Frame", "RadialCastSettings", UIParent, "BasicFrameTemplateWithInset")
    if not ok or not f then
        f = CreateFrame("Frame", "RadialCastSettings", UIParent)
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.06, 0.05, 0.04, 0.95)
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 2, 2)
    end
    f:SetSize(PANEL_W, PANEL_H)
    f:SetPoint("RIGHT", UIParent, "RIGHT", -40, 0)   -- leaves room for the spellbook
    f:SetFrameStrata("DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    -- Not in UISpecialFrames on purpose: WoW closes those whenever the
    -- spellbook opens. Escape is handled by the embedded editor instead.

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOP", 0, -6)
    title:SetText("RadialCast")

    -- Columns
    local left = CreateFrame("Frame", nil, f)
    left:SetPoint("TOPLEFT", 6, -24)
    left:SetPoint("BOTTOMLEFT", 6, 6)
    left:SetWidth(LEFT_W)

    local right = CreateFrame("Frame", nil, f)
    right:SetPoint("TOPLEFT", left, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", -6, 6)

    local divider = f:CreateTexture(nil, "ARTWORK")
    divider:SetWidth(1)
    divider:SetPoint("TOPLEFT", right, "TOPLEFT", 0, -12)
    divider:SetPoint("BOTTOMLEFT", right, "BOTTOMLEFT", 0, 12)
    divider:SetColorTexture(0.8, 0.7, 0.5, 0.25)

    ---------------- left column: settings ----------------
    Section(left, "General", -10)
    Checkbox(left, "Enable RadialCast", 18, -38,
        function() return not db.disabled end,
        function(v) db.disabled = not v; ApplyActivation() end)
    local ringBoxes = {}
    local ringText = { base = "Base ring  (middle mouse)", shift = "Shift ring  (Shift + middle)",
                       ctrl = "Ctrl ring  (Ctrl + middle)" }
    for idx, r in ipairs(RINGS) do
        local key = r.key
        ringBoxes[#ringBoxes + 1] = Checkbox(left, ringText[key], 40, -38 - idx * 26,
            function() return not (db.ringOff and db.ringOff[key]) end,
            function(v)
                db.ringOff = db.ringOff or {}
                db.ringOff[key] = (not v) or nil
                ApplyActivation()
            end)
    end

    Section(left, "Wheel", -160)
    Checkbox(left, "Open at cursor  (off = screen center)", 18, -188,
        function() return S("cursor") end,
        function(v) SetSetting("cursor", v) end)
    Slider(left, "Size", -224, 0.6, 1.4, 0.05, Pct,
        function() return S("scale") end,
        function(v) SetSetting("scale", v); RequestCombatLayout() end)
    Slider(left, "Edge padding", -270, 0, 0.30, 0.01, Pct,
        function() return S("padding") end,
        function(v) SetSetting("padding", v) end)
    Slider(left, "Background dim", -316, 0, 0.6, 0.05, Pct,
        function() return S("dim") end,
        function(v) SetSetting("dim", v) end)

    local combatHeader = Section(left, "Combat", -366)
    BetaChip(left, combatHeader)
    local combatBox = Checkbox(left, "Enable combat casting", 18, -394,
        function() return S("combatCast") end,
        function(v) SetSetting("combatCast", v); ApplyActivation() end)
    combatBox:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Combat casting (BETA)")
        GameTooltip:AddLine("In combat, hold middle mouse, hover a slot, and click it with your chosen "
            .. "mouse button to cast.", 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("The wheel's slots stay clickable (invisibly) at the combat position for the "
            .. "whole fight, so that button casts a slot even while the wheel is closed. Other mouse "
            .. "buttons always pass through to the game.", 1, 0.82, 0.3, true)
        GameTooltip:Show()
    end)
    combatBox:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- "Cast with" button row
    local castLabel = left:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    castLabel:SetPoint("TOPLEFT", 22, -430)
    castLabel:SetText("Cast with")
    local castRow = { buttons = {} }
    local bw = math.floor((LEFT_W - 44 - 3 * 4) / 4)
    for idx, info in ipairs(CAST_BUTTONS) do
        local b = CreateFrame("Button", nil, left, "UIPanelButtonTemplate")
        b:SetSize(bw, 22)
        b:SetPoint("TOPLEFT", 22 + (idx - 1) * (bw + 4), -448)
        b:SetText(info.short)
        b:SetScript("OnClick", function()
            SetSetting("combatButton", info.key)
            RequestCombatLayout()
            if panel and panel.Sync then panel:Sync() end
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(info.tip)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b.key = info.key
        castRow.buttons[idx] = b
    end
    castRow.Sync = function(self)
        local cur = S("combatButton")
        for _, b in ipairs(self.buttons) do
            if b.key == cur then b:LockHighlight() else b:UnlockHighlight() end
        end
    end
    castRow.SetActive = function(self, on)
        for _, b in ipairs(self.buttons) do b:SetEnabled(on) end
        castLabel:SetAlpha(on and 1 or 0.35)
    end
    controls[#controls + 1] = castRow

    local combatSliders = {
        castRow,
        Slider(left, "Combat wheel horizontal", -490, -600, 600, 10, Px,
            function() return S("combatX") end,
            function(v) SetSetting("combatX", v); RequestCombatLayout() end),
        Slider(left, "Combat wheel vertical", -536, -400, 400, 10, Px,
            function() return S("combatY") end,
            function(v) SetSetting("combatY", v); RequestCombatLayout() end),
    }

    local note = left:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", 22, -584)
    note:SetWidth(LEFT_W - 44)
    note:SetJustifyH("LEFT")

    local clear = CreateFrame("Button", nil, left, "UIPanelButtonTemplate")
    clear:SetSize(LEFT_W - 44, 26)
    clear:SetPoint("BOTTOMLEFT", 22, 14)
    clear:SetText("Clear all rings")
    clear:SetScript("OnClick", function() StaticPopup_Show("RADIALCAST_CLEAR") end)

    ---------------- right column: live ring editor ----------------
    local save = CreateFrame("Button", nil, right, "UIPanelButtonTemplate")
    save:SetSize(120, 26)
    save:SetPoint("BOTTOMRIGHT", -16, 14)
    save:SetText("Save")
    save:SetScript("OnClick", function() f:Hide() end)   -- OnHide confirms in chat

    local layoutTitle = right:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    layoutTitle:SetPoint("TOPLEFT", 18, -10)
    layoutTitle:SetText("Layout")

    function f:Sync()
        for _, c in ipairs(controls) do c:Sync() end
        local on = not db.disabled
        for _, cb in ipairs(ringBoxes) do
            cb:SetEnabled(on)
            cb.label:SetAlpha(on and 1 or 0.4)
        end
        local combatOn = S("combatCast") and true or false
        for _, sl in ipairs(combatSliders) do sl:SetActive(combatOn) end
        note:SetText(CombatNote())
        if editing then ShowRing(activeRing) end   -- tabs + "ring is off" overlay
    end
    f:SetScript("OnShow", function(self)
        self:Sync()
        EmbedEditor(right)
    end)
    f:SetScript("OnHide", function()
        ReleaseEditor()
        print("|cff6fd6f0RadialCast|r: settings saved")
    end)
    f:RegisterEvent("PLAYER_REGEN_ENABLED")
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:SetScript("OnEvent", function(self) if self:IsShown() then note:SetText(CombatNote()) end end)
    return f
end

local function ToggleSettings()
    panel = panel or CreatePanel()
    panel:SetShown(not panel:IsShown())
end

CloseSettings = function()
    if panel then panel:Hide() end
end

SyncSettings = function()
    if panel and panel:IsShown() then panel:Sync() end
end

local function Status()
    if db.disabled then return "disabled" end
    local parts = {}
    for _, r in ipairs(RINGS) do
        parts[#parts + 1] = r.label .. (RingEnabled(r.key) and " on" or " off")
    end
    return table.concat(parts, ", ")
end

SlashCmdList.RADIALCAST = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    local cmd, rest = msg:match("^(%S*)%s*(.-)$")

    if cmd == "reset" then
        StaticPopup_Show("RADIALCAST_CLEAR")   -- same confirmation as the button

    elseif cmd == "disable" or cmd == "enable" then
        local off = (cmd == "disable")
        db.ringOff = db.ringOff or {}
        if rest == "" then
            db.disabled = off
            if not off then db.ringOff = {} end   -- plain enable = everything on
        else
            local list, bad = {}, {}
            for word in rest:gmatch("[^,%s]+") do
                if RING_BY_KEY[word] then list[#list + 1] = word else bad[#bad + 1] = word end
            end
            if #bad > 0 then
                print("|cff6fd6f0RadialCast|r: unknown ring '" .. table.concat(bad, ", ")
                      .. "' (use base, shift, ctrl)")
                return
            end
            for _, k in ipairs(list) do db.ringOff[k] = off or nil end
            if not off then db.disabled = false end
        end
        local ok = ApplyActivation()
        if editing then ShowRing(activeRing) end   -- refresh "(off)" tab labels
        if panel and panel:IsShown() then panel:Sync() end
        print("|cff6fd6f0RadialCast|r: " .. Status()
              .. (ok and "" or " (applies when combat ends)"))

    elseif cmd == "status" then
        print("|cff6fd6f0RadialCast|r: " .. Status())

    else
        -- /rcast and /rcast edit both open the settings window
        if editing and not embedded then wheel:Hide() end
        ToggleSettings()
    end
end