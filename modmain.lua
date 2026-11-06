GLOBAL.setmetatable(env, {
    __index = function(_, k)
        return GLOBAL.rawget(GLOBAL, k)
    end
})

-- 不支持独行长路/无洞穴世界
if not TheNet:IsDedicated() and not TheNet:GetIsClient() then
    AddPrefabPostInit("world", function(inst)
        if TheNet:GetIsServer() then
            inst:DoTaskInTime(3, function()
                c_announce("[客户端MOD转为服务器MOD] 检测到当前服务器 未开启洞穴世界 或 开启了独行长路Mod，本模组停止运行！")
                c_announce("[Convert client mod to server mod] The current server was detected to have Cave World disabled or Don't Starve Alone mod enabled. This mod has stopped running!")
            end)
        end
    end)
    return
end

-- 同一轮加载只安装一次补丁，避免入口被其他模组重复调用时再次包装
if ModManager._client_mod_conversion_initialized then
    return
end

local DEBUG_print = GetModConfigData("DEBUGPrint", true) and function(...)
    print("[客户端MOD转为服务器MOD]", ...)
end or function() end

local function Warn(...)
    print("[客户端MOD转为服务器MOD]", ...)
end

local function CopyValues(values)
    local result = {}
    if type(values) == "table" then
        for k, v in pairs(values) do
            result[k] = v
        end
    end
    return result
end

-- 配置值可以是 false；只有 nil 才表示需要回退
local function FirstDefined(a, b, c)
    if a ~= nil then
        return a
    elseif b ~= nil then
        return b
    end
    return c
end

-- 不直接改写 GetModConfigData 返回的表，避免污染本模组的临时配置
local clientmods = {}
local configured_mods = GetModConfigData("client_mods_list")
if type(configured_mods) == "table" then
    for name, data in pairs(configured_mods) do
        if type(name) == "string" and name ~= modname and type(data) == "table" then
            clientmods[name] = {version = data.version, config = CopyValues(data.config)}
        else
            Warn("忽略无效的转换配置：", name)
        end
    end
end

local known_mods = KnownModIndex.savedata.known_mods

if TheNet:IsDedicated() then
    -- 专服只公布下载要求和配置，不把客户端模组加入执行列表
    for name, data in pairs(clientmods) do
        local known_mod = known_mods[name] or {}
        known_mods[name] = known_mod
        local info = known_mod.modinfo or {}
        known_mod.modinfo = info
        info.client_only_mod = false
        info.all_clients_require_mod = true
        if type(data.version) == "string" and data.version ~= "" then
            info.version = data.version
            info.version_compatible = data.version
        else
            info.version = info.version or ""
        end

        local options = {}
        for option, value in pairs(data.config) do
            options[#options + 1] = {name = option, saved = value}
        end
        info.configuration_options = options
    end

    local OldGetEnabledServerModNames = ModManager.GetEnabledServerModNames
    ModManager.GetEnabledServerModNames = function(self, ...)
        local names = OldGetEnabledServerModNames(self, ...)
        if IsNotConsole() then
            for name in pairs(clientmods) do
                if not table.contains(names, name) then
                    names[#names + 1] = name
                end
            end
        end
        return names
    end

    -- mods.lua 的 GetEnabledServerModsConfigData 会再次调用此方法
    -- 转换配置必须来自转换清单，不能被专服磁盘上的旧客户端配置覆盖
    local OldLoadModConfigurationOptions = KnownModIndex.LoadModConfigurationOptions
    KnownModIndex.LoadModConfigurationOptions = function(self, name, ...)
        if clientmods[name] then
            return self.savedata.known_mods[name].modinfo.configuration_options
        end
        return OldLoadModConfigurationOptions(self, name, ...)
    end

    ModManager._client_mod_conversion_initialized = true
    return
end

local listing = TheNet:GetServerListing()
if (listing and listing.client_mods_disabled) or KnownModIndex:IsModEnabledAny("workshop-2860210553") then
    for _, description in pairs(listing and listing.mods_description or {}) do
        local name = description.mod_name
        local known_mod = known_mods[name]
        local info = known_mod and known_mod.modinfo
        if info and info.client_only_mod and info.all_clients_require_mod and not clientmods[name] then
            -- 双标志模组也需要解除临时禁用，但保留已有转换配置
            clientmods[name] = {config = {}}
        end
    end
end

for name in pairs(clientmods) do
    local known_mod = known_mods[name]
    if not (known_mod and known_mod.modinfo and not known_mod.modinfo.failed
        and KnownModIndex:IsModTempEnabled(name) and KnownModIndex:IsModCompatibleWithMode(name)) then
        Warn("跳过未被服务器临时启用、未下载或不兼容的模组：", name)
        clientmods[name] = nil
    end
end
if not next(clientmods) then
    return
end

-- 原版 LoadMods 此时正用 ipairs 遍历 mods；已执行的前缀不能移动
local loading_index
for i, mod in ipairs(ModManager.mods) do
    if mod.modname == modname and ModManager.currentlyloadingmod == modname then
        loading_index = i
        break
    end
end
if not loading_index then
    Warn("未找到当前模组的加载位置，本轮停止转换，避免破坏模组加载顺序")
    return
end
ModManager._client_mod_conversion_initialized = true

local OldGetModConfigurationName = KnownModIndex.GetModConfigurationName
KnownModIndex.GetModConfigurationName = function(self, name, client_config, ...)
    if clientmods[name] then
        -- 转换前的纯客户端模组一直使用无 _CLIENT 后缀的文件
        client_config = false
    end
    return OldGetModConfigurationName(self, name, client_config, ...)
end

local function SetOptionValue(known_mod, option, value)
    -- modutil.lua 会依次读取这些字段，必须保持同一个最终值
    option.saved = value
    option.saved_client = value
    option.saved_server = value
    known_mod.temp_config_options[option.name] = value
end

for name, data in pairs(clientmods) do
    local known_mod = known_mods[name]
    local info = known_mod.modinfo
    local server_values = CopyValues(known_mod.temp_config_options)
    for option, value in pairs(data.config) do
        server_values[option] = value
    end

    info.configuration_options = info.configuration_options or {}
    -- 清掉以前加载遗留的字段，再从原客户端配置文件读取本地保存值
    for _, option in pairs(info.configuration_options) do
        option.saved = nil
        option.saved_client = nil
        option.saved_server = nil
    end
    KnownModIndex:LoadModConfigurationOptions(name, false)
    known_mod.temp_config_options = known_mod.temp_config_options or {}
    for _, option in pairs(info.configuration_options) do
        if type(option) == "table" and option.name then
            SetOptionValue(known_mod, option, FirstDefined(option.saved, server_values[option.name], option.default))
        end
    end

    info.all_clients_require_mod = true
    info.client_only_mod = false
    known_mod.temp_disabled = false
    DEBUG_print("已转换客户端模组：", name)
end

local OldIsModEnabled = KnownModIndex.IsModEnabled
KnownModIndex.IsModEnabled = function(self, name, ...)
    if clientmods[name] then
        return true
    end
    return OldIsModEnabled(self, name, ...)
end

local OldGetModConfigurationOptions = KnownModIndex.GetModConfigurationOptions_Internal
KnownModIndex.GetModConfigurationOptions_Internal = function(self, name, force_local_options, ...)
    if clientmods[name] then
        force_local_options = true
    end
    return OldGetModConfigurationOptions(self, name, force_local_options, ...)
end

-- 游戏内重新加载或保存配置时，也要同步三套字段和临时配置
local OldUpdateConfigurationOptions = KnownModIndex.UpdateConfigurationOptions
KnownModIndex.UpdateConfigurationOptions = function(self, options, savedata, client_config, ...)
    for name in pairs(clientmods) do
        local known_mod = self.savedata.known_mods[name]
        if known_mod and known_mod.modinfo.configuration_options == options then
            for _, saved in pairs(savedata) do
                if saved.saved ~= nil then
                    for _, option in pairs(options) do
                        if option.name == saved.name then
                            SetOptionValue(known_mod, option, saved.saved)
                        end
                    end
                end
            end
            break
        end
    end
    return OldUpdateConfigurationOptions(self, options, savedata, client_config, ...)
end

local OldSetConfigurationOption = KnownModIndex.SetConfigurationOption
KnownModIndex.SetConfigurationOption = function(self, name, option_name, value, ...)
    local known_mod = clientmods[name] and self.savedata.known_mods[name]
    if known_mod then
        for _, option in pairs(known_mod.modinfo.configuration_options) do
            if option.name == option_name then
                SetOptionValue(known_mod, option, value)
            end
        end
    end
    return OldSetConfigurationOption(self, name, option_name, value, ...)
end

local function Priority(info)
    return tonumber(info.priority) or 0
end

local function ModPrioritySort(a, b)
    local ai, bi = a.modinfo, b.modinfo
    if ai and bi then
        local ap, bp = Priority(ai), Priority(bi)
        if ap ~= bp then
            return ap > bp
        end
        return stringidsorter(type(ai.name) == "string" and ai.name or a.modname,
            type(bi.name) == "string" and bi.name or b.modname)
    end
    return stringidsorter(a.modname, b.modname)
end

local remaining, present, added = {}, {}, {}
for i, mod in ipairs(ModManager.mods) do
    present[mod.modname] = true
    if i > loading_index then
        remaining[#remaining + 1] = mod
    elseif i < loading_index and clientmods[mod.modname] then
        Warn("此模组已先于转换层初始化，无法回溯其初始化期间的配置读取：", mod.modname)
    end
end
for name in pairs(clientmods) do
    if not present[name] then
        local mod = CreateEnvironment(name, false)
        mod.modinfo = known_mods[name].modinfo
        remaining[#remaining + 1] = mod
        added[mod] = true
        if not table.contains(ModManager.modnames, name) then
            ModManager.modnames[#ModManager.modnames + 1] = name
        end
        DEBUG_print("补入尚未执行的模组列表：", name)
    end
end

-- 只重排未执行部分，新模组继续由原版负责路径、manifest 和两个入口
local register = {}
table.sort(remaining, ModPrioritySort)
for i, mod in ipairs(remaining) do
    ModManager.mods[loading_index + i] = mod
    if added[mod] then
        register[#register + 1] = mod
    end
end
if #register > 0 then
    kleiregistermods(register)
end