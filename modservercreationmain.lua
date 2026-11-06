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

if chinese_languages[lang] ~= nil then
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

local mod_list = {}
local function fn(self)
    local ImageButton = require "widgets/imagebutton"
    if ShardSaveGameIndex then
        mod_list = table.typecheckedgetfield(ShardSaveGameIndex.slot_cache, "table", self.save_slot, "Master", "enabled_mods", modname, "configuration_options", "client_mods_list") or {}
    end

    DEBUG_print("自动更新数据...")
    for k,_ in pairs(mod_list) do
        local known_mod = KnownModIndex.savedata.known_mods[k]
        if known_mod then
            local version = KnownModIndex:InitializeModInfo(k).version
            version = TrimString(version or "")
            version = string.lower(version)

            DEBUG_print("要转换为服务器的客户端MOD：", k, "版本号：", version)
            local temp_config = {}
            local mod_options = known_mod.modinfo and known_mod.modinfo.configuration_options or {}
            for k,v in pairs(mod_options) do
                if type(v) == "table" then
                    temp_config[v.name] = mod_options[k].saved or v.default
                end
            end

            mod_list[k] = {
                    version = version,
                    config = temp_config
            }
        else
            mod_list[k] = nil
        end
    end

    if not self[modname .. "_hooked_mods_tab"] then
        self[modname .. "_hooked_mods_tab"] = true
        local _ApplyDataToWidget = self.mods_tab.mods_scroll_list.update_fn
        self.mods_tab.mods_scroll_list.update_fn = function(context, widget, data, index)
            _ApplyDataToWidget(context, widget, data, index)
            if data == nil then return end

            local opt = widget.moditem
            local function refresh()
                if mod_list[opt.parent.data.mod.modname] then
                    opt.add_to_server_mod:SetTextures("images/ui.xml", "checkbox_on.tex", "checkbox_on_highlight.tex", "checkbox_on_disabled.tex", nil, nil, {1,1}, {0,0}) --打勾状态
                else
                    opt.add_to_server_mod:SetTextures("images/ui.xml", "checkbox_off.tex", "checkbox_off_highlight.tex", "checkbox_off_disabled.tex", nil, nil, {1,1}, {0,0}) -- 不打勾状态
                end
            end

            if opt.add_to_server_mod == nil then -- 如果没创建按钮
                if self.mods_tab.currentmodtype == "client" then -- 仅在客户端模组列表页面添加按钮
                    opt.add_to_server_mod = opt:AddChild(ImageButton("images/ui.xml", "checkbox_off.tex", "checkbox_off_highlight.tex", "checkbox_off_disabled.tex", nil, nil, {1,1}, {0,0}))
                    opt.add_to_server_mod:SetPosition(140, 20, 0)
                    opt.add_to_server_mod:SetHoverText(lang == "zh" and "添加至服务器模组列表(所有玩家都会加载此模组,服务器不会加载)" or "Add to server mod list (all players will load this mod, but the server will not).")
                    opt.add_to_server_mod:SetOnClick(function() -- 按下按钮后
                        if mod_list[opt.parent.data.mod.modname] then
                            mod_list[opt.parent.data.mod.modname] = nil
                        else
                            local known_mod = KnownModIndex.savedata.known_mods[opt.parent.data.mod.modname]
                            if known_mod then
                                local temp_config = {}
                                local mod_options = known_mod.modinfo.configuration_options or {}
                                for k,v in pairs(mod_options) do
                                    if type(v) == "table" then
                                        temp_config[v.name] = mod_options[k].saved or v.default
                                    end
                                end

                                local version = KnownModIndex:InitializeModInfo(opt.parent.data.mod.modname).version
                                version = TrimString(version or "")
                                version = string.lower(version)

                                mod_list[opt.parent.data.mod.modname] = {
                                    version = version,
                                    config = temp_config
                                }
                            end
                        end
                        refresh() -- 切换开关状态也需要刷新
                    end)

                    local oldCreate = self.Create
                    self.Create = function(self, warnedOffline, warnedDisabledMods, warnedOutOfDateMods, ...)
                        for k in pairs(mod_list) do
                            local known_mod = KnownModIndex.savedata.known_mods[k]
                            if known_mod then
                                local temp_config = {}
                                local mod_options = known_mod.modinfo.configuration_options or {}
                                for k1,v1 in pairs(mod_options) do
                                    if type(v1) == "table" then
                                        temp_config[v1.name] = mod_options[k1].saved or v1.default
                                    end
                                end

                                local version = KnownModIndex:InitializeModInfo(k).version
                                version = TrimString(version or "")
                                version = string.lower(version)

                                mod_list[k] = {
                                    version = version,
                                    config = temp_config
                                }
                            end
                        end
                        UpdateModSettings(mod_list)
                        oldCreate(self, warnedOffline, warnedDisabledMods, warnedOutOfDateMods, ...)
                    end

                    opt.add_to_server_mod:MoveToFront()
                    opt.add_to_server_mod.scale_on_focus = false
                end
            elseif KnownModIndex.savedata.known_mods[opt.parent.data.mod.modname] and KnownModIndex.savedata.known_mods[opt.parent.data.mod.modname].modinfo.all_clients_require_mod then -- 如果模组有 all_clients_require_mod 字段
                opt.add_to_server_mod:Hide() -- 隐藏按钮
                mod_list[opt.parent.data.mod.modname] = nil
            elseif opt.add_to_server_mod and self.mods_tab.currentmodtype == "client" and KnownModIndex:IsModEnabledAny(modname) then -- 客户端模组页面
                opt.add_to_server_mod:Show() -- 显示按钮
            elseif opt.add_to_server_mod and self.mods_tab.currentmodtype == "server" then -- 服务器模组页面
                opt.add_to_server_mod:Hide() -- 隐藏按钮
            end

            if opt.add_to_server_mod then
                refresh() -- 实时刷新
            end
        end
    end
end

-- 修改创建世界界面, 这里需要延迟1帧等待界面生成, 由modworldgenmain触发
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