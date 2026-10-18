-- Historical Parasoul character-selection colors (only palettes altered
-- by the 2023 artwork revisions). Combat FOIT is owned by Egret loader.
ModInfo = {
    ModName = "AOTC_Parasoul_Select_Historical",
    Version = 1,
    Author = "Ahad of the Curve",
    Desc = "Parasoul original character-select armband colors"
}
Mod = {
    install = function()
        local folder = CCLib.work_dir .. "\\mods\\AOTC_Parasoul_Select_Historical\\"
        local palettes = {4,6,8,9,11,12,13,16,22,24,25,27,28}
        for _, index in ipairs(palettes) do
            local name = "parasoul_" .. index .. "p.dds"
            local path = folder .. name
            local file = io.open(path, "rb")
            if not file then return false, "Missing Parasoul palette " .. path end
            file:close()
            if not CCLib.gfsAddFile("sprites","sprites/" .. name,path) then
                return false, "Failed staging palette " .. name
            end
        end
        if not CCLib.gfsCommitChanges() then
            return false, "Failed to commit Parasoul character-select palettes"
        end
        print("[AOTC] 13 historical Parasoul select palettes loaded.")
        return true
    end,
    update = function()
        return Mod.install()
    end
}
