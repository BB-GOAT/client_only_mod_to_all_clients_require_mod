GLOBAL.setmetatable(env, {
    __index = function(_, k)
        return GLOBAL.rawget(GLOBAL, k)
    end
})

local lang = GetModConfigData("language") or "auto"
if lang == "auto" then
    lang = GLOBAL.LanguageTranslator.defaultlang
end

local chinese_languages =
{
    zh = "zh", -- Chinese for Steam
    zhr = "zh", -- Chinese for WeGame
    ch = "zh", -- Chinese mod
    chs = "zh", -- Chinese mod
    sc = "zh", -- simple Chinese
    chinese = "zh", -- Chinese mod
    zht = "zh", -- traditional Chinese for Steam
	tc = "zh", -- traditional Chinese
	cht = "zh", -- Chinese mod
}

if chinese_languages[lang] then
    lang = chinese_languages[lang]
else
    lang = "en"
end

local DEBUG_print = GetModConfigData("DEBUGPrint", true) and function(...) print("[客户端MOD转为服务器MOD]", ...) end or function(...) end

local function UpdateModSettings(mod_list)
    DEBUG_print("更新数据......")
    local modconfig = KnownModIndex:LoadModConfigurationOptions(modname)
    for _,j in pairs (modconfig) do
        if j.name == "client_mods_list" then
            j.saved = mod_list
            break
        end
    end

    KnownModIndex:SaveConfigurationOptions(function() end, modname, modconfig, false)
end

-- 三处采集共用同一套规则，关闭选项 false 不能回退到默认值。
local function CollectModSettings(name)
    local known_mod = KnownModIndex.savedata.known_mods[name]
    if not (known_mod and known_mod.modinfo) then
        return
    end
    local config = {}
    for _, option in pairs(known_mod.modinfo.configuration_options or {}) do
        if type(option) == "table" and option.name then
            local value = option.saved
            if value == nil then
                value = option.default
            end
            config[option.name] = value
        end
    end
    local info = KnownModIndex:InitializeModInfo(name)
    if info.failed then
        return
    end
    return {
        version = string.lower(TrimString(info.version or "")),
        config = config,
    }
end

local function fn(self)
    if self[modname .. "_hooked_mods_tab"] then
        return
    end
    local mod_list = {}
    local ImageButton = require "widgets/imagebutton"
    if ShardSaveGameIndex then
        local saved_list = table.typecheckedgetfield(ShardSaveGameIndex.slot_cache, "table", self.save_slot, "Master", "enabled_mods", modname, "configuration_options", "client_mods_list") or {}
        for name, data in pairs(saved_list) do
            mod_list[name] = data
        end
    end

    DEBUG_print("自动更新数据...")
    for k,_ in pairs(mod_list) do
        mod_list[k] = CollectModSettings(k)
    end

    self[modname .. "_hooked_mods_tab"] = true

    local function SaveModList()
        if KnownModIndex:IsModEnabledAny(modname) then
            for name in pairs(mod_list) do
                mod_list[name] = CollectModSettings(name)
            end
            UpdateModSettings(mod_list)
        end
    end

    -- 创建和退出时保存都要更新清单；每个界面只包装一次。
    local oldCreate = self.Create
    self.Create = function(self, ...)
        SaveModList()
        return oldCreate(self, ...)
    end
    local oldSaveChanges = self.SaveChanges
    self.SaveChanges = function(self, ...)
        if self:IsDirty() and self:CanResume() then
            SaveModList()
        end
        return oldSaveChanges(self, ...)
    end

    local _ApplyDataToWidget = self.mods_tab.mods_scroll_list.update_fn
    self.mods_tab.mods_scroll_list.update_fn = function(context, widget, data, index)
        _ApplyDataToWidget(context, widget, data, index)
        if not data then return end

        local opt = widget.moditem
        local name = opt.parent.data.mod.modname
        local known_mod = KnownModIndex.savedata.known_mods[name]
        local info = known_mod and known_mod.modinfo
        local can_convert = self.mods_tab.currentmodtype == "client"
            and KnownModIndex:IsModEnabledAny(modname)
            and info and info.client_only_mod and not info.all_clients_require_mod
        if not can_convert then
            if opt.add_to_server_mod then
                opt.add_to_server_mod:Hide()
            end
            if info and info.all_clients_require_mod then
                mod_list[name] = nil
            end
            return
        end
        local function refresh()
            if mod_list[opt.parent.data.mod.modname] then
                opt.add_to_server_mod:SetTextures("images/ui.xml", "checkbox_on.tex", "checkbox_on_highlight.tex", "checkbox_on_disabled.tex", nil, nil, {1,1}, {0,0}) --打勾状态
            else
                opt.add_to_server_mod:SetTextures("images/ui.xml", "checkbox_off.tex", "checkbox_off_highlight.tex", "checkbox_off_disabled.tex", nil, nil, {1,1}, {0,0}) -- 不打勾状态
            end
        end

        if not opt.add_to_server_mod then
            opt.add_to_server_mod = opt:AddChild(ImageButton("images/ui.xml", "checkbox_off.tex", "checkbox_off_highlight.tex", "checkbox_off_disabled.tex", nil, nil, {1,1}, {0,0}))
            opt.add_to_server_mod:SetPosition(140, 20, 0)
            opt.add_to_server_mod:SetHoverText(lang == "zh" and "添加至服务器模组列表(所有玩家都会加载此模组,服务器不会加载)" or "Add to server mod list (all players will load this mod, but the server will not).")
            opt.add_to_server_mod:SetOnClick(function()
                if mod_list[opt.parent.data.mod.modname] then
                    mod_list[opt.parent.data.mod.modname] = nil
                else
                    mod_list[opt.parent.data.mod.modname] = CollectModSettings(opt.parent.data.mod.modname)
                end
                self:MakeDirty()
                refresh()
            end)

            opt.add_to_server_mod:MoveToFront()
            opt.add_to_server_mod.scale_on_focus = false
        end

        opt.add_to_server_mod:Show()
        refresh()
    end
end

-- 修改创建世界界面, 这里需要延迟1帧等待界面生成
if rawget(GLOBAL, "TheFrontEnd") ~= nil then
	scheduler:ExecuteInTime(0, function()
		for _, screen in ipairs(GLOBAL.TheFrontEnd.screenstack) do
			if screen.name == "ServerCreationScreen" then
				fn(screen)
				break
			end
		end
	end)
end