-- Isolated AOTC runtime audio experiment; never included in the production installer.
-- The modern 337-slot sound bank is hybridized with 198 historical sound payloads.
ModInfo = {
    ModName = "AOTC_Soviet_Historical_Test",
    Version = 1,
    Author = "Ahad of the Curve",
    Desc = "Reversible original Soviet announcer voice experiment"
}
Mod = {
    install = function()
        local source = CCLib.work_dir .. "\\mods\\AOTC_Soviet_Historical_Test\\hitspark_alt3.snd-wav"
        local file = io.open(source, "rb")
        if not file then
            return false, "Missing AOTC Soviet test bank: " .. source
        end
        file:close()
        local ok = CCLib.gfsAddFile("characters-win", "characters/hitspark_alt3.snd-wav", source)
        if not ok then
            return false, "SkullLoader declined Soviet test sound-bank overlay"
        end
        if not CCLib.gfsCommitChanges() then
            return false, "SkullLoader failed to commit characters-win data02 overlay"
        end
        print("[AOTC] Soviet historical announcer test installed into data02 (337 sound slots).")
        return true
    end,
    update = function()
        return Mod.install()
    end
}
