ModInfo = {
    ModName = "AOTC_Beowulf_2023",
    Version = 1,
    Author = "Ahad of the Curve",
    Desc = "Restores five April 2023 Beowulf Act 5 story illustrations"
}

Mod = {
    install = function()
        local files = {"13.dds", "13_1.dds", "14.dds", "15.dds", "16.dds"}
        for _, filename in ipairs(files) do
            local source = CCLib.work_dir .. "\\mods\\AOTC_Beowulf_2023\\" .. filename
            local file = io.open(source, "rb")
            if not file then
                return false, "Missing Beowulf original texture: " .. source
            end
            file:close()
            if not CCLib.gfsAddFile("story_art", "story_art/Cinematics/Beowulf/" .. filename, source) then
                return false, "SkullLoader rejected Beowulf texture: " .. filename
            end
        end
        if not CCLib.gfsCommitChanges() then
            return false, "SkullLoader did not commit Beowulf art into data02"
        end
        print("[AOTC] Five original April 2023 Beowulf Act 5 illustrations installed.")
        return true
    end,
    update = function()
        return Mod.install()
    end
}
