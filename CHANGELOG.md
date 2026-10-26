# Changelog

## 0.13.0 (2026-10-26)

### Mike Z's Soviet announcer now plays the right lines
- **Fixed:** earlier versions mixed original Soviet recordings into the *current* game's announcer bank one slot at a time. Lines landed on the wrong moments, because the current bank has extra takes that shift every clip number after them.
- 0.13 installs the **original Soviet announcer bank as a whole file**: its own cue list and all 198 of its own recordings. Every announcer moment now plays the line it was recorded for.
- **The Soviet voice is now optional:**
  - **Standalone:** `AOTC.cmd` asks `Restore Mike-Z's Soviet Voice? Y/N`. Y restores the original announcer; N keeps the current one. Everything else is always restored.
  - **Mod Manager:** import `AOTC-0.13.0-ModManager-Optional-soviet.zip` alongside the main mod and tick it to opt in.

### Skullgirls Mod Manager compatibility
- **Fixed:** importing into Skullgirls Mod Manager failed with *"The JSON value could not be converted to System.Version"*. The mod now uses a version number Mod Manager can read.
- The Soviet voice ships as its own small Mod Manager mod, so the main mod contains only the always-on restorations.

### Also in this release
- **New:** Eliza cutscenes.
- **Digital Art Compendium:** now complete, with all 56 images, including the 24 that were missing from 0.11, notably all of Filia's story art.
- **One installer for everything:**
  - **Version check:** it refuses to install on a game version it wasn't made for, rather than guessing.
  - **Re-censor:** removes exactly what was installed and returns the game to vanilla.
  - **Same content:** the Standalone and Mod Manager downloads are built from identical files.
