-- AOTC Big Band story art restoration for SkullLoader.
-- Source art/script files are staged by tools/Stage-BigBand-SkullLoader-Mod.ps1.
-- SkullLoader writes modified GFS archives in data02; do not alter data01.
ModInfo = {
    ModName = "AOTC_BigBand_2023",
    Version = 1,
    Author = "Ahad of the Curve",
    Desc = "Restores the April 2023 Big Band opening script and artwork"
}

Mod = {
    install = function()
        local base = CCLib.work_dir .. "\\mods\\AOTC_BigBand_2023\\"
        local files = {
            {"core", "core/arcade/story/BigBandIntro.ini", base .. "BigBandIntro.ini"},
            {"story_art", "story_art/Cinematics/BigBand/03_1.dds", base .. "03_1.dds"},
            {"story_art", "story_art/Cinematics/BigBand/03_2.dds", base .. "03_2.dds"}
        }

        for _, item in ipairs(files) do
            local file = io.open(item[3], "rb")
            if not file then
                return false, "Missing AOTC Big Band asset: " .. item[3]
            end
            file:close()
            local ok = CCLib.gfsAddFile(item[1], item[2], item[3])
            if not ok then
                return false, "SkullLoader refused GFS asset: " .. item[2]
            end
        end
        local committed = CCLib.gfsCommitChanges()
        if not committed then
            return false, "SkullLoader failed to commit AOTC Big Band data02 changes"
        end
        print("[AOTC] Big Band April 2023 story script and art staged with SkullLoader.")
        return true
    end,
    update = function()
        return Mod.install()
    end
}
