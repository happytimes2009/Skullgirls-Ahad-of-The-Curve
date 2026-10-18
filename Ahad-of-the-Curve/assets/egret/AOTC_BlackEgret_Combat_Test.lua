-- Isolated candidate: 48 April 2023 Black Egret animation components.
-- Does not restore Parasoul's own gameplay sprite armband.
-- Uses only loader-created data02 archives; never changes data01.
ModInfo = {
    ModName = "AOTC_BlackEgret_Combat_Test",
    Version = 1,
    Author = "Ahad of the Curve",
    Desc = "Experimental 48-frame Black Egret armband restoration (not production)"
}

Mod = {
    install = function()
        local base = CCLib.work_dir .. "\\mods\\AOTC_BlackEgret_Combat_Test\\"
        local entries = {
            {"characters-art", "characters/parasoul.art", "parasoul.art"},
            {"characters-foits", "characters/parasoul.foit", "parasoul.foit"}
        }
        for _, entry in ipairs(entries) do
            local source = base .. entry[3]
            local file = io.open(source, "rb")
            if not file then
                return false, "Missing Egret test asset: " .. source
            end
            file:close()
            if not CCLib.gfsAddFile(entry[1], entry[2], source) then
                return false, "SkullLoader rejected Egret test entry: " .. entry[2]
            end
        end
        if not CCLib.gfsCommitChanges() then
            return false, "Could not commit Black Egret test archives to data02"
        end
        print("[AOTC] Experimental Black Egret ART+FOIT overlay staged (48 frames).")
        return true
    end,
    update = function()
        return Mod.install()
    end
}
