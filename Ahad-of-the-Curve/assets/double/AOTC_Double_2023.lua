-- Isolated restoration of the historical Double ending illustration.
-- Leaves data01 archives unchanged; SkullLoader prepares its copy in data02.
ModInfo = {
    ModName = "AOTC_Double_2023",
    Version = 1,
    Author = "Ahad of the Curve",
    Desc = "Restores the April 2023 Double ending capture illustration"
}

Mod = {
    install = function()
        local source = CCLib.work_dir .. "\\mods\\AOTC_Double_2023\\End05.dxt1.dds"
        local file = io.open(source, "rb")
        if not file then
            return false, "Missing historical Double DDS: " .. source
        end
        file:close()

        local target = "story_art/Cinematics/Double/End/05.dxt1.dds"
        if not CCLib.gfsAddFile("story_art", target, source) then
            return false, "SkullLoader refused historical Double ending texture"
        end
        if not CCLib.gfsCommitChanges() then
            return false, "SkullLoader could not commit the Double texture to data02"
        end
        print("[AOTC] Original April 2023 Double ending texture installed.")
        return true
    end,
    update = function()
        return Mod.install()
    end
}
