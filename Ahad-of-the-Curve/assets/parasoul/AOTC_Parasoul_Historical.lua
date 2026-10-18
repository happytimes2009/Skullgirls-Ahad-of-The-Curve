-- Isolated AOTC Parasoul cutscene restoration. Original data01 stays untouched.
ModInfo = {
    ModName = "AOTC_Parasoul_Historical",
    Version = 1,
    Author = "Ahad of the Curve",
    Desc = "Five April 2023 Parasoul cutscene DDS files plus 2014 Black Egret soldier portrait"
}

Mod = {
    install = function()
        local base = CCLib.work_dir .. "\\mods\\AOTC_Parasoul_Historical\\"
        local paths = {
            {"Intro02.dxt1.dds", "story_art/Cinematics/Parasoul/Intro/02.dxt1.dds"},
            {"Intro07.dxt1.dds", "story_art/Cinematics/Parasoul/Intro/07.dxt1.dds"},
            {"Intro08.dxt1.dds", "story_art/Cinematics/Parasoul/Intro/08.dxt1.dds"},
            {"End08.dxt1.dds", "story_art/Cinematics/Parasoul/End/08.dxt1.dds"},
            {"End10.dxt1.dds", "story_art/Cinematics/Parasoul/End/10.dxt1.dds"}
        }

        local config = io.open(base .. "TargetPath.txt", "rb")
        if not config then
            return false, "Missing validated target path for historical Egret portrait"
        end
        local soldierTarget = config:read("*a")
        config:close()
        soldierTarget = soldierTarget:gsub("%s+$", "")
        if not soldierTarget:match("^story_art/") or
           not soldierTarget:lower():match("/npcs/genericsoldier%.dds$") then
            return false, "Unexpected Black Egret portrait target path"
        end
        table.insert(paths, {"GenericSoldier.dds", soldierTarget})

        for _, entry in ipairs(paths) do
            local source = base .. entry[1]
            local file = io.open(source, "rb")
            if not file then
                return false, "Missing Parasoul historical texture: " .. source
            end
            file:close()
            if not CCLib.gfsAddFile("story_art", entry[2], source) then
                return false, "SkullLoader rejected Parasoul story-art path: " .. entry[2]
            end
        end
        if not CCLib.gfsCommitChanges() then
            return false, "SkullLoader could not commit Parasoul assets to data02"
        end
        print("[AOTC] Parasoul: five restored 2023 cutscene images and one 2014 Egret portrait installed.")
        return true
    end,
    update = function()
        return Mod.install()
    end
}
