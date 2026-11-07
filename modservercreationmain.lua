GLOBAL.setmetatable(env, {
    __index = function(_, k)
        return GLOBAL.rawget(GLOBAL, k)
    end
})

local lang = GetModConfigData("language") or "auto"
if lang == "auto" then
    lang = GLOBAL.LanguageTranslator.defaultlang
end

local chinese_languages = {
    zh = true, zhr = true, zht = true,
    ch = true, chs = true, sc = true, chinese = true, tc = true, cht = true,
}
local function L(zh, en)
    return chinese_languages[lang] and zh or en
end

-- 房间草稿不引用模组索引中的配置表，避免编辑房间时改动个人配置。
local function Copy(value)
    if type(value) ~= "table" then
        return value
    end
    local result = {}
    for k, v in pairs(value) do
        result[k] = Copy(v)
    end
    return result
end

local RoomDraft = {}
RoomDraft.__index = RoomDraft

function RoomDraft:Reset(saved)
    self.selected = {}
    self.entries = {}
    for name, data in pairs(type(saved) == "table" and saved or {}) do
        if type(name) == "string" and type(data) == "table" then
            self.selected[name] = true
            self.entries[name] = Copy(data)
        end
    end
end

function RoomDraft:Get(name)
    if not self.entries[name] then
        self.entries[name] = self.capture(name)
    end
    return self.entries[name]
end

function RoomDraft:Toggle(name)
    if self.selected[name] then
        self.selected[name] = nil
    elseif self:Get(name) then
        self.selected[name] = true
    else
        return false
    end
    return true
end

function RoomDraft:SetConfig(name, settings)
    local entry = self:Get(name)
    if not entry then
        return false
    end
    entry.config = entry.config or {}
    for _, option in pairs(settings or {}) do
        if option.name then
            local value = option.saved
            if value == nil then
                value = option.default
            end
            entry.config[option.name] = Copy(value)
        end
    end
    return true
end

function RoomDraft:Export()
    local result = {}
    for name in pairs(self.selected) do
        local entry = Copy(self.entries[name])
        -- 保存时只更新版本快照，不重新采集个人设置。
        local version = self.version(name)
        if version then
            entry.version = version
        end
        result[name] = entry
    end
    return result
end

local function NewRoomDraft(saved, capture, version)
    local draft = setmetatable({ capture = capture, version = version }, RoomDraft)
    draft:Reset(saved)
    return draft
end

local ModFilterBar = require "widgets/redux/modfilterbar"
local ModConfigurationScreen = require "screens/redux/modconfigurationscreen"

local function CreateRoomFilterBar(tab, draft, normalbar, filter_category)
    -- 两套筛选栏分别保存搜索和筛选状态，原版列表仍使用 client 类型。
    local roombar = tab.mods_page:AddChild(ModFilterBar(tab, filter_category))
    local strings = STRINGS.UI.MODSSCREEN
    roombar:AddChild(roombar:AddModTypeFilter(strings.WORKSHOP_FILTER_FMT, "workshop_filter.tex", "local_filter.tex", "workshoplocal_filter.tex", "workshopfilter", IsWorkshopMod, function(name) return not IsWorkshopMod(name) end))
    -- 兼容【模组合集】模组：其 AddModStatusFilter 会替换传入的判断函数，房间状态按钮需独立注册。
    local statusbutton = roombar:AddChild(require("widgets/redux/templates").IconButton("images/button_icons2.xml", "enableddisabled_filter.tex"))
    statusbutton:SetScale(0.9)
    local statusstate = "both"
    statusbutton.SetFilterState = function(self, state)
        statusstate = state == "enabled" and "enabled" or state == "disabled" and "disabled" or "both"
        if state == "enabled" then
            roombar.filters.statusfilter = function(name) return draft.selected[name] == true end
            self.icon:SetTexture("images/button_icons2.xml", "enabled_filter.tex")
            self:SetHoverText(L("筛选：已加入房间", "Filter: In room"))
        elseif state == "disabled" then
            roombar.filters.statusfilter = function(name) return not draft.selected[name] end
            self.icon:SetTexture("images/button_icons2.xml", "disabled_filter.tex")
            self:SetHoverText(L("筛选：未加入房间", "Filter: Not in room"))
        else
            roombar.filters.statusfilter = nil
            self.icon:SetTexture("images/button_icons2.xml", "enableddisabled_filter.tex")
            self:SetHoverText(L("筛选：全部房间客户端模组", "Filter: All room client mods"))
        end
        if not roombar.no_refresh_modstab then
            tab:RefreshModFilter(roombar:_ConstructFilter())
        end
    end
    statusbutton:SetOnClick(function()
        local state = statusstate == "enabled" and "disabled" or statusstate == "disabled" and "both" or "enabled"
        statusbutton:SetFilterState(state)
        Profile:SetCustomizationFilterState(roombar.filter_category, "statusfilter", state)
    end)
    table.insert(roombar.filter_btns, { btnid = "statusfilter", widget = statusbutton })
    roombar:_UpdatePositions()
    roombar:AddChild(roombar:AddSearch())
    roombar:SetPosition(normalbar:GetPosition())
    roombar:Hide()
    return roombar
end

local function OpenRoomConfiguration(name, entry, apply)
    -- 兼容【配置扩展】模组：它替换打开入口而非原版页面，每次打开时选择已加载的扩展页面。
    local ConfigurationScreen = package.loaded["widgets/remi_newmodconfigurationscreen"] or ModConfigurationScreen
    local dialog = ConfigurationScreen(name, false)
    local config = entry.config or {}
    for i, option in ipairs(dialog.options) do
        local value = config[option.name]
        if value == nil then value = option.default end
        option.value = Copy(value)
        if dialog.optionwidgets then
            -- 原版滚动列表单独保存初始值和当前选择。
            local data = dialog.optionwidgets[i]
            data.initial_value = Copy(value)
            data.selected_value = option.value
        else
            -- 兼容【配置扩展】模组：分组、搜索和控件共享选项对象，初始值和显示缓存需同步。
            option.initial_value = Copy(value)
            option.displaystr = nil
        end
    end
    dialog.started_default = dialog:IsDefaultSettings()
    dialog.options_scroll_list:RefreshView()
    dialog:MakeDirty(false)
    dialog.Apply = function(self)
        if self:IsDirty() then
            apply(self:CollectSettings())
        end
        self:MakeDirty(false)
        TheFrontEnd:PopScreen()
    end
    TheFrontEnd:PushScreen(dialog)
end

local function InstallRoomClientPage(screen, converter)
    local tab = screen.mods_tab
    local hookkey = converter .. "_room_client_page"
    if not tab or tab[hookkey] then
        return
    end
    tab[hookkey] = true
    local key = "room_client_mods"
    local title = L("房间客户端模组", "Room Client Mods")
    local tooltip = L("选择所有玩家进入此房间时需要加载的客户端模组，并设置房间提供的默认配置。服务器不运行这些模组。", "Choose the client mods all players need in this room and their room defaults. The server does not run these mods.")

    local function Version(name)
        local info = KnownModIndex:GetModInfo(name)
        return info and not info.failed and string.lower(TrimString(info.version or "")) or nil
    end
    local function CanConvert(name)
        local info = KnownModIndex:GetModInfo(name)
        return info and not info.failed and info.client_only_mod and not info.all_clients_require_mod
    end
    local function Capture(name)
        if not CanConvert(name) then
            return
        end
        local config = {}
        for _, option in pairs(KnownModIndex:LoadModConfigurationOptions(name, false) or {}) do
            if type(option) == "table" and option.name then
                local value = option.saved
                if value == nil then
                    value = option.default
                end
                config[option.name] = Copy(value)
            end
        end
        return { version = Version(name), config = config }
    end
    local function SavedList(slot)
        local mods = ShardSaveGameIndex:GetSlotEnabledServerMods(slot)
        local config = mods[converter] and mods[converter].configuration_options
        return config and config.client_mods_list
    end
    local draft = NewRoomDraft(SavedList(screen.save_slot), Capture, Version)
    local room_mode = false
    local last_modnames = {}
    local subscreener = tab.subscreener
    local normalbar = tab.modfilterbar

    local roombar = CreateRoomFilterBar(tab, draft, normalbar, converter .. "_roomfilter")

    local oldRefreshFilter = tab.RefreshModFilter
    tab.RefreshModFilter = function(self, _, ...)
        -- 两套筛选栏共享列表，隐藏页面的回调不能覆盖当前页面的筛选条件。
        return oldRefreshFilter(self, self.modfilterbar:_ConstructFilter(), ...)
    end

    local button = subscreener:MenuButton(title, key, tooltip, tab.tooltip)
    button.hover_overlay:SetSize(260, 68)
    button.hover_overlay:SetPosition(-90, 0)
    button.bg:ScaleToSize(140, 68)
    button.bg:SetPosition(-55, 0)
    for _, label in ipairs({ button.text, button.text_shadow }) do
        label:SetRegionSize(140, 40)
        label:SetPosition(-55, 0)
    end
    button:SetTextSize(20)
    local menu = subscreener.menu
    menu:AddCustomItem(button)
    -- 原版菜单从下向上排列，新入口放在客户端模组下面。
    table.remove(menu.items)
    table.insert(menu.items, 1, button)
    subscreener.sub_screens[key] = tab.mods_page

    -- 原版透明背景高于菜单行距，且边框、文字也参与命中，会抢占相邻按钮。
    -- 仅保留各行自己的透明背景用于鼠标命中，装饰尺寸和手柄焦点保持原样。
    for _, item in ipairs(menu.items) do
        item.image:SetClickable(false)
        item.hover_overlay:SetClickable(false)
        item.text:SetClickable(false)
        item.text_shadow:SetClickable(false)
        item.bg:ScaleToSize(140, math.abs(menu.offset) - 2)
        item.bg:SetPosition(-55, 0)
    end

    local function LayoutMenu(visible)
        local position = 0
        for _, item in ipairs(menu.items) do
            if item ~= button or visible then
                item:SetPosition(0, menu.offset * position - (visible and menu.offset or 0))
                position = position + 1
            end
        end
        if visible then button:Show() else button:Hide() end
        menu:DoFocusHookups()
        -- 原版换页键遍历 ordered_keys，需要一并排除隐藏入口。
        subscreener.ordered_keys = subscreener:_CreatedOrderedKeyList()
        if not visible then
            for i, value in ipairs(subscreener.ordered_keys) do
                if value == key then
                    table.remove(subscreener.ordered_keys, i)
                    break
                end
            end
            subscreener.buttons.client:SetFocusChangeDir(MOVE_DOWN, tab.allmodsmenu)
        end
    end
    local menu_visible
    local function RefreshAvailability()
        local available = not not KnownModIndex:IsModEnabledAny(converter)
        if not available and room_mode then
            subscreener:OnMenuButtonSelected("client")
        end
        if available ~= menu_visible then
            menu_visible = available
            LayoutMenu(available)
        end
    end

    local oldSelection = subscreener.post_menu_selection_fn
    subscreener:SetPostMenuSelectionAction(function(selection)
        local next_room = selection == key
        if next_room ~= room_mode then
            -- 两个客户端页面有各自的最后选中项。
            last_modnames[room_mode and key or "client"] = tab.last_client_modname
            room_mode = next_room
            tab.last_client_modname = last_modnames[room_mode and key or "client"]
            tab.modfilterbar:Hide()
            tab.modfilterbar = room_mode and roombar or normalbar
            tab.mods_page.focus_forward = tab.modfilterbar:BuildFocusFinder()
            tab.mods_filter_fn = tab.modfilterbar:_ConstructFilter()
            tab:UpdateModsOrder(true)
        end
        oldSelection(selection == key and "client" or selection)
        tab.modfilterbar:RefreshFilterState()
    end)

    local oldStatus = tab.GetBestModStatus
    tab.GetBestModStatus = function(self, name)
        if room_mode then
            local info = KnownModIndex:GetModInfo(name)
            if not info or info.failed or KnownModIndex:IsModKnownBad(name) then
                return "DISABLED_ERROR"
            end
            return draft.selected[name] and "WORKING_NORMALLY" or "DISABLED_MANUAL"
        end
        return oldStatus(self, name)
    end
    local oldApplyData = tab.mods_scroll_list.update_fn
    tab.mods_scroll_list.update_fn = function(context, widget, data, ...)
        oldApplyData(context, widget, data, ...)
        if not data or data.is_downloading then
            return
        end
        local opt = widget.moditem
        if room_mode then
            local name = data.mod.modname
            local can_convert = CanConvert(name)
            opt:SetModReadOnly(not can_convert)
            opt:SetModEnabled(draft.selected[name])
            if can_convert and tab:GetBestModStatus(name) ~= "DISABLED_ERROR" then
                opt.status:SetString(draft.selected[name] and L("已加入房间", "In room") or L("未加入房间", "Not in room"))
            end
            opt.checkbox:SetHoverText(L("加入或移出房间客户端模组", "Add or remove this room client mod"))
        else
            opt.checkbox:ClearHoverText()
        end
    end

    local oldDetails = tab.ShowModDetails
    tab.ShowModDetails = function(self, ...)
        oldDetails(self, ...)
        if room_mode and self.currentmodname then
            if not CanConvert(self.currentmodname) then
                self.detailwarning:SetString(L("此模组由服务器模组页面管理，无法在此转换。", "Manage this mod on the Server Mods page."))
                self:DisableConfigButton()
            elseif self:GetBestModStatus(self.currentmodname) ~= "DISABLED_ERROR" then
                self.detailwarning:SetString(draft.selected[self.currentmodname]
                    and L("已加入房间；所有玩家需要加载。", "Added to this room; required for all players.")
                    or L("未加入房间；勾选后所有玩家需要加载。", "Select this mod to require it for all players."))
            end
        end
    end
    local oldEnable = tab.EnableCurrent
    tab.EnableCurrent = function(self, index, ...)
        if not room_mode then
            return oldEnable(self, index, ...)
        end
        local data = self.optionwidgets_client[index]
        if data and not data.is_downloading and CanConvert(data.mod.modname) and draft:Toggle(data.mod.modname) then
            self.last_client_modname = data.mod.modname
            screen:MakeDirty()
            -- 状态筛选下切换后，条目必须立即移入或移出结果。
            self:UpdateModsOrder(true)
            self.mods_scroll_list:RefreshView()
        end
    end

    local oldConfigure = tab.ConfigureSelectedMod
    tab.ConfigureSelectedMod = function(self, ...)
        if not room_mode then
            return oldConfigure(self, ...)
        end
        local name = self.currentmodname
        if not self.modconfigable or not name or not CanConvert(name) then
            return
        end
        local entry = draft:Get(name)
        if not entry then return end
        OpenRoomConfiguration(name, entry, function(settings)
            if draft:SetConfig(name, settings) then
                screen:MakeDirty()
            end
        end)
    end

    local oldOrder = tab.UpdateModsOrder
    tab.UpdateModsOrder = function(self, ...)
        RefreshAvailability()
        return oldOrder(self, ...)
    end
    local oldSlot = tab.SetDataForSlot
    tab.SetDataForSlot = function(self, slot, ...)
        if slot ~= self.slotnum then
            draft:Reset(SavedList(slot))
            last_modnames[key] = nil
        end
        return oldSlot(self, slot, ...)
    end

    local function SaveList()
        if not KnownModIndex:IsModEnabledAny(converter) then return end
        local options = Copy(KnownModIndex:LoadModConfigurationOptions(converter, false) or {})
        local list = draft:Export()
        for _, option in pairs(options) do
            if option.name == "client_mods_list" then
                option.saved = list
                break
            end
        end
        KnownModIndex:SaveConfigurationOptions(function() end, converter, options, false)
    end
    -- Apply 在创建流程中真正提交模组选项；退出保存走 SaveChanges。
    local oldApply = tab.Apply
    tab.Apply = function(self, ...)
        SaveList()
        return oldApply(self, ...)
    end
    local oldSave = screen.SaveChanges
    screen.SaveChanges = function(self, ...)
        if self:IsDirty() and self:CanResume() then SaveList() end
        return oldSave(self, ...)
    end
    RefreshAvailability()
    tab:UpdateModsOrder(true)
end

-- 修改创建世界界面, 这里需要延迟1帧等待界面生成
if rawget(GLOBAL, "TheFrontEnd") then
    scheduler:ExecuteInTime(0, function()
        for _, screen in ipairs(GLOBAL.TheFrontEnd.screenstack) do
            if screen.name == "ServerCreationScreen" then
                InstallRoomClientPage(screen, modname)
                break
            end
        end
    end)
end