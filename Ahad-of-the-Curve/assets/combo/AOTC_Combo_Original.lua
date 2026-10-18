ModInfo = {
    ModName = "AOTC_Combo_Original",
    Version = 1,
    Author = "Ahad of the Curve",
    Desc = "Restores original English 16, 17 and 18 hit combo messages"
}
Mod = {
    install = function()
        local source = CCLib.work_dir .. "\\mods\\AOTC_Combo_Original\\en_loc.json"
        local file = io.open(source, "rb")
        if not file then
            return false, "Missing original combo labels preview: " .. source
        end
        file:close()
        local ok = CCLib.gfsAddFile("core", "core/localization/en_loc.json", source)
        if not ok then
            return false, "SkullLoader declined combo text overlay"
        end
        if not CCLib.gfsCommitChanges() then
            return false, "SkullLoader failed to commit combo localization"
        end
        return true
    end,
    update = function()
        return Mod.install()
    end
}
