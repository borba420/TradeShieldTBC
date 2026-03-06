local ADDON_NAME = ...

local TradeShield = CreateFrame("Frame")
TradeShield:RegisterEvent("ADDON_LOADED")
TradeShield:RegisterEvent("PLAYER_LOGIN")
TradeShield:RegisterEvent("TRADE_SHOW")
TradeShield:RegisterEvent("TRADE_CLOSED")
TradeShield:RegisterEvent("TRADE_PLAYER_ITEM_CHANGED")
TradeShield:RegisterEvent("TRADE_TARGET_ITEM_CHANGED")
TradeShield:RegisterEvent("TRADE_MONEY_CHANGED")
TradeShield:RegisterEvent("TRADE_ACCEPT_UPDATE")
TradeShield:RegisterEvent("MAIL_SHOW")
TradeShield:RegisterEvent("MAIL_SEND_INFO_UPDATE")
TradeShield:RegisterEvent("SEND_MAIL_MONEY_CHANGED")
TradeShield:RegisterEvent("SEND_MAIL_COD_CHANGED")

local MAX_TRADE_SLOTS = 7
local DEFAULT_MINIMAP_ICON = "Interface\\Icons\\INV_Misc_Bag_09"

local defaults = {
    mode = "strict", -- strict | normal
    strictStableSeconds = 2,
    minTargetGold = nil, -- integer gold amount
    sound = true,
    soundOnlyRisk = true,
    soundMail = false,
    soundThrottleSec = 1.5,
    incidents = {},
    mailWhitelist = {},
    minimap = {
        hide = false,
    },
}

local state = {
    active = false,
    tradePartner = nil,
    playerSlots = {},
    targetSlots = {},
    playerMoney = 0,
    targetMoney = 0,
    playerAccepted = 0,
    targetAccepted = 0,
    lastChangeAt = 0,
    lastMailRiskHash = nil,
    lastSoundAt = 0,
    pendingSlotChecks = {},
}

local function now()
    return GetTime and GetTime() or 0
end

local function color(msg)
    return "|cffff7f00TradeShield|r " .. msg
end

local function trim(s)
    if not s then
        return ""
    end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalizeRecipientName(name)
    return string.lower(trim(name or ""))
end

local function isMailWhitelisted(name)
    local whitelist = TradeShieldTBCDB.mailWhitelist or {}
    local key = normalizeRecipientName(name)
    if key == "" then
        return false
    end
    return whitelist[key] == true
end

local function cloneDefaults(dst, src)
    for k, v in pairs(src) do
        if type(v) == "table" then
            if type(dst[k]) ~= "table" then
                dst[k] = {}
            end
            cloneDefaults(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = v
        end
    end
end

local function safePlayAlert(isRisk)
    if not TradeShieldTBCDB.sound then
        return
    end

    if TradeShieldTBCDB.soundOnlyRisk and not isRisk then
        return
    end

    local t = now()
    local throttle = TradeShieldTBCDB.soundThrottleSec or 1.5
    if state.lastSoundAt and (t - state.lastSoundAt) < throttle then
        return
    end

    state.lastSoundAt = t

    if PlaySound then
        if SOUNDKIT and SOUNDKIT.RAID_WARNING then
            PlaySound(SOUNDKIT.RAID_WARNING, "Master")
        else
            PlaySound("RaidWarning")
        end
    end
end

local function alert(msg, isRisk, suppressSound)
    DEFAULT_CHAT_FRAME:AddMessage(color(msg))
    if UIErrorsFrame and UIErrorsFrame.AddMessage then
        UIErrorsFrame:AddMessage("TradeShield: " .. msg, 1, 0.1, 0.1)
    end
    if not suppressSound then
        safePlayAlert(isRisk)
    end
end

local function getTradePartnerName()
    if TradeFrameRecipientNameText and TradeFrameRecipientNameText.GetText then
        local n = TradeFrameRecipientNameText:GetText()
        if n and n ~= "" then
            return n
        end
    end

    if UnitName then
        local n = UnitName("NPC")
        if n and n ~= "" then
            return n
        end
    end

    return "Unknown"
end

local function getItemIDFromLink(link)
    if not link then
        return nil
    end

    local id = string.match(link, "item:(%d+):")
    if id then
        return tonumber(id)
    end
    return nil
end

local function isEmptyItem(item)
    if not item then
        return true
    end

    local hasIdentity = (item.link and item.link ~= "")
        or (item.name and item.name ~= "")
        or item.id
        or item.texture

    if not hasIdentity then
        return true
    end

    local c = item.count
    if c and c <= 0 then
        return true
    end

    return false
end

local function snapshotSlot(isTarget, slot)
    local link, name, texture, count, quality

    if isTarget then
        if GetTradeTargetItemLink then
            link = GetTradeTargetItemLink(slot)
        end
        if GetTradeTargetItemInfo then
            name, texture, count, quality = GetTradeTargetItemInfo(slot)
        end
    else
        if GetTradePlayerItemLink then
            link = GetTradePlayerItemLink(slot)
        end
        if GetTradePlayerItemInfo then
            name, texture, count, quality = GetTradePlayerItemInfo(slot)
        end
    end

    local item = {
        link = link,
        id = getItemIDFromLink(link),
        name = name,
        texture = texture,
        count = count or 1,
        quality = quality or -1,
    }

    if isEmptyItem(item) then
        return nil
    end

    return item
end

local function incident(partner, reason)
    if not partner or partner == "" then
        return
    end

    local t = TradeShieldTBCDB.incidents[partner]
    if not t then
        t = { count = 0, lastReason = "", lastAt = 0 }
        TradeShieldTBCDB.incidents[partner] = t
    end

    t.count = (t.count or 0) + 1
    t.lastReason = reason
    t.lastAt = time()
end

local function markTradeChanged(riskReason)
    state.lastChangeAt = now()
    if state.active and riskReason then
        incident(state.tradePartner, riskReason)
    end
end

local function describeSlot(item)
    if not item or (not item.link and not item.name and not item.id and not item.texture) then
        return "empty"
    end
    if item.link and item.link ~= "" then
        return item.link
    end
    if item.name and item.name ~= "" then
        return item.name
    end
    if item.id then
        return string.format("item:%d", item.id)
    end
    if item.texture then
        return string.format("item(icon:%s)", tostring(item.texture))
    end
    return "empty"
end

local function sameItemIdentity(oldItem, newItem)
    if not oldItem or not newItem then
        return false
    end

    if oldItem.id and newItem.id then
        return oldItem.id == newItem.id
    end

    if oldItem.link and newItem.link then
        return oldItem.link == newItem.link
    end

    if oldItem.name and newItem.name then
        return oldItem.name == newItem.name
    end

    if oldItem.texture and newItem.texture then
        local oldQuality = oldItem.quality or -1
        local newQuality = newItem.quality or -1
        return oldItem.texture == newItem.texture and oldQuality == newQuality
    end

    return false
end

local function sameStack(oldItem, newItem)
    if not sameItemIdentity(oldItem, newItem) then
        return false
    end

    local oldCount = oldItem.count or 1
    local newCount = newItem.count or 1
    return oldCount == newCount
end

local function isSameIconSwap(oldItem, newItem)
    if not oldItem or not newItem then
        return false
    end
    if not oldItem.texture or not newItem.texture or oldItem.texture ~= newItem.texture then
        return false
    end
    if sameStack(oldItem, newItem) then
        return false
    end

    local oldKey = oldItem.id or oldItem.link or oldItem.name
    local newKey = newItem.id or newItem.link or newItem.name
    if oldKey and newKey and oldKey ~= newKey then
        return true
    end

    return false
end

local function wasAcceptArmed()
    return state.playerAccepted == 1 or state.targetAccepted == 1
end

local function compareSlotAndWarn(isTarget, slot, oldItem, newItem)
    if isEmptyItem(oldItem) then
        oldItem = nil
    end
    if isEmptyItem(newItem) then
        newItem = nil
    end

    local emittedAlert = false
    local sideLabel = isTarget and "Target" or "Your"

    if oldItem and newItem and sameStack(oldItem, newItem) then
        return emittedAlert
    end

    if (not oldItem) and (not newItem) then
        return emittedAlert
    end

    local sameIconSwap = isSameIconSwap(oldItem, newItem)

    local armed = wasAcceptArmed()
    local riskReason = nil
    if isTarget and armed then
        riskReason = "target changed trade after accept-ready"
    elseif isTarget and sameIconSwap and state.targetAccepted == 1 then
        riskReason = "target same-icon swap after accept"
    end

    local oldCount = oldItem and (oldItem.count or 1) or 0
    local newCount = newItem and (newItem.count or 1) or 0
    local stackCountChanged = oldItem and newItem and sameItemIdentity(oldItem, newItem) and (oldCount ~= newCount)

    if sameIconSwap then
        if isTarget then
            alert(string.format("%s slot %d swapped to same-icon item: %s -> %s", sideLabel, slot, describeSlot(oldItem), describeSlot(newItem)), true)
            emittedAlert = true
        end
        markTradeChanged(riskReason)
        return emittedAlert
    end

    if stackCountChanged then
        if isTarget then
            local dropped = newCount < oldCount
            local countRisk = dropped or armed
            local countReason = riskReason
            if dropped then
                countReason = "target reduced stack count"
            end
            alert(string.format("%s slot %d stack changed: %s x%d -> x%d", sideLabel, slot, describeSlot(newItem), oldCount, newCount), countRisk)
            emittedAlert = true
            markTradeChanged(countReason)
        else
            markTradeChanged(nil)
        end
        return emittedAlert
    end

    if oldItem and not newItem then
        if isTarget then
            alert(string.format("%s slot %d item removed: %s", sideLabel, slot, describeSlot(oldItem)), wasAcceptArmed())
            emittedAlert = true
        end
        markTradeChanged(riskReason)
        return emittedAlert
    end

    if (not oldItem) and newItem then
        if isTarget then
            alert(string.format("%s slot %d item added: %s", sideLabel, slot, describeSlot(newItem)), wasAcceptArmed())
            emittedAlert = true
        end
        markTradeChanged(riskReason)
        return emittedAlert
    end

    if isTarget then
        alert(string.format("%s slot %d changed: %s -> %s", sideLabel, slot, describeSlot(oldItem), describeSlot(newItem)), wasAcceptArmed())
        emittedAlert = true
    end
    markTradeChanged(riskReason)
    return emittedAlert
end

local function refreshSlot(isTarget, slot)
    local slots = isTarget and state.targetSlots or state.playerSlots
    local oldItem = slots[slot]
    local newItem = snapshotSlot(isTarget, slot)

    local emitted = compareSlotAndWarn(isTarget, slot, oldItem, newItem)
    slots[slot] = newItem

    return oldItem, newItem, emitted
end

local retryTicker = CreateFrame("Frame")
retryTicker:Hide()
retryTicker:SetScript("OnUpdate", function(self)
    if not state.active then
        wipe(state.pendingSlotChecks)
        self:Hide()
        return
    end

    local t = now()
    local hasPending = false

    for key, check in pairs(state.pendingSlotChecks) do
        if t >= check.nextAt then
            local slots = check.isTarget and state.targetSlots or state.playerSlots
            local oldItem = slots[check.slot]
            local newItem = snapshotSlot(check.isTarget, check.slot)

            if (not oldItem and not newItem) or (oldItem and newItem and sameStack(oldItem, newItem)) then
                state.pendingSlotChecks[key] = nil
            else
                local emitted = compareSlotAndWarn(check.isTarget, check.slot, oldItem, newItem)
                slots[check.slot] = newItem

                if emitted then
                    state.pendingSlotChecks[key] = nil
                else
                    check.attempts = check.attempts - 1
                    if check.attempts <= 0 then
                        state.pendingSlotChecks[key] = nil
                    else
                        check.nextAt = t + 0.08
                        hasPending = true
                    end
                end
            end
        else
            hasPending = true
        end
    end

    if not hasPending and not next(state.pendingSlotChecks) then
        self:Hide()
    end
end)

local function queueSlotRefresh(isTarget, slot)
    local key = (isTarget and "T" or "P") .. tostring(slot)
    state.pendingSlotChecks[key] = {
        isTarget = isTarget,
        slot = slot,
        attempts = 8,
        nextAt = now() + 0.08,
    }
    retryTicker:Show()
end

local function refreshMoney()
    local oldPlayer = state.playerMoney or 0
    local oldTarget = state.targetMoney or 0

    local pMoney = GetPlayerTradeMoney and GetPlayerTradeMoney() or 0
    local tMoney = GetTargetTradeMoney and GetTargetTradeMoney() or 0

    if pMoney ~= oldPlayer then
        markTradeChanged(nil)
    end

    if tMoney ~= oldTarget then
        alert(string.format("Target offered gold changed: %.2fg -> %.2fg", oldTarget / 10000, tMoney / 10000), wasAcceptArmed())
        local riskReason = nil
        if wasAcceptArmed() and tMoney < oldTarget then
            riskReason = "target reduced gold after accept-ready"
        end
        markTradeChanged(riskReason)
    end

    state.playerMoney = pMoney
    state.targetMoney = tMoney

    if TradeShieldTBCDB.minTargetGold and tMoney < (TradeShieldTBCDB.minTargetGold * 10000) then
        alert(string.format("Target gold below minimum: offered %.2fg, expected at least %dg", tMoney / 10000, TradeShieldTBCDB.minTargetGold), true)
    end
end

local function resetTradeState()
    state.active = false
    state.tradePartner = nil
    state.playerSlots = {}
    state.targetSlots = {}
    state.playerMoney = 0
    state.targetMoney = 0
    state.playerAccepted = 0
    state.targetAccepted = 0
    state.lastChangeAt = 0
    wipe(state.pendingSlotChecks)
    retryTicker:Hide()
end

local function fullTradeSnapshot()
    state.tradePartner = getTradePartnerName()

    for i = 1, MAX_TRADE_SLOTS do
        state.playerSlots[i] = snapshotSlot(false, i)
        state.targetSlots[i] = snapshotSlot(true, i)
    end

    state.playerMoney = GetPlayerTradeMoney and GetPlayerTradeMoney() or 0
    state.targetMoney = GetTargetTradeMoney and GetTargetTradeMoney() or 0
    state.playerAccepted = 0
    state.targetAccepted = 0
    state.lastChangeAt = now()
    wipe(state.pendingSlotChecks)
end

local function strictGuard(playerAccepted, targetAccepted)
    if not state.active then
        return
    end

    if TradeShieldTBCDB.mode ~= "strict" then
        return
    end

    if playerAccepted ~= 1 or targetAccepted ~= 1 then
        return
    end

    local stableFor = now() - (state.lastChangeAt or 0)
    if stableFor < TradeShieldTBCDB.strictStableSeconds then
        alert(string.format("Strict mode blocked accept: trade changed %.1fs ago (need %.1fs stable)", stableFor, TradeShieldTBCDB.strictStableSeconds), true)
        if CancelTrade then
            CancelTrade()
        end
        markTradeChanged("strict mode blocked unsafe accept")
    end
end

local function formatAge(sec)
    if not sec or sec < 60 then
        return "<1m"
    end
    if sec < 3600 then
        return string.format("%dm", math.floor(sec / 60))
    end
    return string.format("%dh", math.floor(sec / 3600))
end

local function warnIfKnownPartner()
    local partner = state.tradePartner
    if not partner then
        return
    end

    local rec = TradeShieldTBCDB.incidents[partner]
    if not rec then
        return
    end

    local age = time() - (rec.lastAt or time())
    DEFAULT_CHAT_FRAME:AddMessage(color(string.format("Caution: %s has %d prior risk flags (last %s ago)", partner, rec.count or 0, formatAge(age))))
end

local function getSendMailState()
    local target = ""
    if SendMailNameEditBox and SendMailNameEditBox.GetText then
        target = SendMailNameEditBox:GetText() or ""
    end

    local cod = GetSendMailCOD and GetSendMailCOD() or 0
    local money = GetSendMailMoney and GetSendMailMoney() or 0

    local maxQuality = -1
    local itemCount = 0
    local attachCount = ATTACHMENTS_MAX_SEND or 12

    if GetSendMailItem then
        for i = 1, attachCount do
            local _, _, count, quality = GetSendMailItem(i)
            if quality then
                itemCount = itemCount + 1
                if quality > maxQuality then
                    maxQuality = quality
                end
            elseif count and count > 0 then
                itemCount = itemCount + 1
            end
        end
    end

    return {
        target = target,
        cod = cod,
        money = money,
        maxQuality = maxQuality,
        itemCount = itemCount,
    }
end

local function maybeWarnMailRisk()
    local m = getSendMailState()

    if m.target == "" then
        return
    end

    if isMailWhitelisted(m.target) then
        return
    end

    local hash = table.concat({ m.target, m.cod, m.money, m.maxQuality, m.itemCount }, "|")
    if hash == state.lastMailRiskHash then
        return
    end
    state.lastMailRiskHash = hash

    local suppressSound = not TradeShieldTBCDB.soundMail or not TradeShieldTBCDB.sound

    if m.itemCount > 0 and m.cod == 0 and m.money == 0 and m.maxQuality >= 3 then
        alert(string.format("Mail risk: sending %d item(s) (max quality %d) with no COD/money to %s", m.itemCount, m.maxQuality, m.target), true, suppressSound)
        return
    end

    if m.cod > 0 and m.itemCount == 0 then
        alert(string.format("Mail risk: COD set to %.2fg but no attachments", m.cod / 10000), true, suppressSound)
        return
    end
end

local function printStatus()
    local minGoldText = TradeShieldTBCDB.minTargetGold and tostring(TradeShieldTBCDB.minTargetGold) .. "g" or "off"
    local soundMode = TradeShieldTBCDB.soundOnlyRisk and "risk-only" or "all"
    local whitelistCount = 0
    for _ in pairs(TradeShieldTBCDB.mailWhitelist or {}) do
        whitelistCount = whitelistCount + 1
    end
    local mailSound = TradeShieldTBCDB.soundMail and "on" or "off"
    DEFAULT_CHAT_FRAME:AddMessage(color(string.format("mode=%s stable=%.1fs minTarget=%s sound=%s(%s) mailSound=%s whitelist=%d throttle=%.1fs", TradeShieldTBCDB.mode, TradeShieldTBCDB.strictStableSeconds, minGoldText, tostring(TradeShieldTBCDB.sound), soundMode, mailSound, whitelistCount, TradeShieldTBCDB.soundThrottleSec or 1.5)))
end

local function formatWhitelistNames()
    local names = {}
    for name in pairs(TradeShieldTBCDB.mailWhitelist or {}) do
        if name and name ~= "" then
            table.insert(names, name)
        end
    end
    table.sort(names)
    return names
end

local function listMailWhitelist()
    local names = formatWhitelistNames()
    if #names == 0 then
        DEFAULT_CHAT_FRAME:AddMessage(color("Mail whitelist: none"))
        return
    end
    DEFAULT_CHAT_FRAME:AddMessage(color("Mail whitelist:"))
    for _, name in ipairs(names) do
        DEFAULT_CHAT_FRAME:AddMessage(color("  - " .. name))
    end
end

local function addMailWhitelist(rawName)
    local name = normalizeRecipientName(rawName)
    if name == "" then
        DEFAULT_CHAT_FRAME:AddMessage(color("Invalid recipient name."))
        return
    end
    TradeShieldTBCDB.mailWhitelist[name] = true
    DEFAULT_CHAT_FRAME:AddMessage(color("Mail whitelist added: " .. name))
end

local function removeMailWhitelist(rawName)
    local name = normalizeRecipientName(rawName)
    if name == "" then
        DEFAULT_CHAT_FRAME:AddMessage(color("Invalid recipient name."))
        return
    end
    if TradeShieldTBCDB.mailWhitelist[name] then
        TradeShieldTBCDB.mailWhitelist[name] = nil
        DEFAULT_CHAT_FRAME:AddMessage(color("Mail whitelist removed: " .. name))
    else
        DEFAULT_CHAT_FRAME:AddMessage(color("Recipient not in whitelist: " .. name))
    end
end

local function handleSlash(msg)
    msg = (msg or ""):lower()

    if msg == "" or msg == "help" then
        DEFAULT_CHAT_FRAME:AddMessage(color("/ts mode strict|normal"))
        DEFAULT_CHAT_FRAME:AddMessage(color("/ts stable <seconds>"))
        DEFAULT_CHAT_FRAME:AddMessage(color("/ts mingold <gold|off>"))
        DEFAULT_CHAT_FRAME:AddMessage(color("/ts sound on|off|all|risk"))
        DEFAULT_CHAT_FRAME:AddMessage(color("/ts mailsound on|off"))
        DEFAULT_CHAT_FRAME:AddMessage(color("/ts mailwl add|remove|list [name]"))
        DEFAULT_CHAT_FRAME:AddMessage(color("/ts status"))
        return
    end

    local cmd, arg = msg:match("^(%S+)%s*(.-)$")
    if cmd == "mode" then
        if arg == "strict" or arg == "normal" then
            TradeShieldTBCDB.mode = arg
            printStatus()
            return
        end
    elseif cmd == "stable" then
        local s = tonumber(arg)
        if s and s >= 0 and s <= 10 then
            TradeShieldTBCDB.strictStableSeconds = s
            printStatus()
            return
        end
    elseif cmd == "mingold" then
        if arg == "off" or arg == "0" then
            TradeShieldTBCDB.minTargetGold = nil
            printStatus()
            return
        end
        local g = tonumber(arg)
        if g and g >= 0 then
            TradeShieldTBCDB.minTargetGold = math.floor(g)
            printStatus()
            return
        end
    elseif cmd == "sound" then
        if arg == "on" then
            TradeShieldTBCDB.sound = true
            printStatus()
            return
        elseif arg == "off" then
            TradeShieldTBCDB.sound = false
            printStatus()
            return
        elseif arg == "all" then
            TradeShieldTBCDB.sound = true
            TradeShieldTBCDB.soundOnlyRisk = false
            printStatus()
            return
        elseif arg == "risk" then
            TradeShieldTBCDB.sound = true
            TradeShieldTBCDB.soundOnlyRisk = true
            printStatus()
            return
        end
    elseif cmd == "mailsound" then
        if arg == "on" then
            TradeShieldTBCDB.soundMail = true
            printStatus()
            return
        elseif arg == "off" then
            TradeShieldTBCDB.soundMail = false
            printStatus()
            return
        end
    elseif cmd == "mailwl" then
        local action, target = arg:match("^(%S+)%s*(.-)$")
        if action == "add" then
            addMailWhitelist(target)
            return
        elseif action == "remove" then
            removeMailWhitelist(target)
            return
        elseif action == "list" or action == "" then
            listMailWhitelist()
            return
        end
    elseif cmd == "status" then
        printStatus()
        return
    end

    DEFAULT_CHAT_FRAME:AddMessage(color("Invalid command. Use /ts help"))
end

local iconDataObject = nil

local function createMinimapButton()
    if iconDataObject then
        return
    end

    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not LDB or not DBIcon then
        return
    end

    iconDataObject = LDB:NewDataObject("TradeShieldTBC", {
        type = "data source",
        text = "TS",
        icon = DEFAULT_MINIMAP_ICON,
        OnTooltipShow = function(tooltip)
            tooltip:AddLine("TradeShield TBC")
            tooltip:AddLine(" ")
            tooltip:AddLine("Left click: print status", 1, 1, 1)
            tooltip:AddLine("Right click: toggle all sounds", 1, 1, 1)
            tooltip:AddLine("Use /ts help for settings", 0.7, 0.7, 0.7)
        end,
        OnClick = function(_, button)
            if button == "RightButton" then
                TradeShieldTBCDB.sound = not TradeShieldTBCDB.sound
                DEFAULT_CHAT_FRAME:AddMessage(color("Sound " .. (TradeShieldTBCDB.sound and "enabled" or "disabled")))
            else
                printStatus()
            end
        end
    })

    if not iconDataObject then
        return
    end

    DBIcon:Register("TradeShieldTBC", iconDataObject, TradeShieldTBCDB.minimap or {})
    DBIcon:Show("TradeShieldTBC")
end

TradeShield:SetScript("OnEvent", function(_, event, ...)

    if event == "PLAYER_LOGIN" then
        createMinimapButton()
        return
    end
    if event == "ADDON_LOADED" then
        local loadedName = ...
        if loadedName ~= ADDON_NAME then
            return
        end

        if type(TradeShieldTBCDB) ~= "table" then
            TradeShieldTBCDB = {}
        end
        cloneDefaults(TradeShieldTBCDB, defaults)

        SLASH_TRADESHIELDTBC1 = "/ts"
        SLASH_TRADESHIELDTBC2 = "/tradeshield"
        SlashCmdList.TRADESHIELDTBC = handleSlash
        createMinimapButton()


        DEFAULT_CHAT_FRAME:AddMessage(color("loaded. /ts help"))
        return
    end

    if event == "TRADE_SHOW" then
        state.active = true
        fullTradeSnapshot()
        warnIfKnownPartner()
        return
    end

    if event == "TRADE_CLOSED" then
        resetTradeState()
        return
    end

    if event == "TRADE_PLAYER_ITEM_CHANGED" then
        local slot = ...
        if state.active and type(slot) == "number" and slot >= 1 and slot <= MAX_TRADE_SLOTS then
            refreshSlot(false, slot)
            queueSlotRefresh(false, slot)
        end
        return
    end

    if event == "TRADE_TARGET_ITEM_CHANGED" then
        local slot = ...
        if state.active and type(slot) == "number" and slot >= 1 and slot <= MAX_TRADE_SLOTS then
            refreshSlot(true, slot)
            queueSlotRefresh(true, slot)
        end
        return
    end

    if event == "TRADE_MONEY_CHANGED" then
        if state.active then
            refreshMoney()
        end
        return
    end

    if event == "TRADE_ACCEPT_UPDATE" then
        local playerAccepted, targetAccepted = ...
        state.playerAccepted = playerAccepted or 0
        state.targetAccepted = targetAccepted or 0
        strictGuard(state.playerAccepted, state.targetAccepted)
        return
    end

    if event == "MAIL_SHOW" then
        state.lastMailRiskHash = nil
        maybeWarnMailRisk()
        return
    end

    if event == "MAIL_SEND_INFO_UPDATE" or event == "SEND_MAIL_MONEY_CHANGED" or event == "SEND_MAIL_COD_CHANGED" then
        maybeWarnMailRisk()
        return
    end
end)


















