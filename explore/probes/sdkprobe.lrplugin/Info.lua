--[[
  Info.lua
  --------
  Manifest for the SDK probe: a throwaway plugin that answers questions about
  the Lightroom SDK which cannot be answered by dumping binaries.

  Deliberately a separate plugin rather than a menu item bolted onto
  pinned.lrplugin. It reads the catalog and builds dialogs; nothing it does
  should ever be able to ship by accident, and installing it does not disturb
  the copy of the real plugin Lightroom already points at.

  Its toolkit identifier is distinct from the real plugin's, so both can be
  installed at once.
--]]

return {
  LrSdkVersion        = 10.0,
  LrSdkMinimumVersion = 6.0,

  LrToolkitIdentifier = "com.github.inat-lightroom.sdkprobe",
  LrPluginName        = "iNat SDK Probe",

  -- Writes a new .lua file into this folder during init, so LateLoadProbeMenu
  -- can ask whether Lightroom will load it. See ProbeInit.lua.
  LrInitPlugin = "ProbeInit.lua",

  LrExportMenuItems = {
    {
      -- RENAME TEST -- ANSWERED. The title changed and the id deliberately
      -- did not, and this read "(renamed)" after a plain Reload Plug-in.
      -- So renames do NOT need a full Lightroom launch, and the note that
      -- claimed they did has been removed from the real plugin's Info.lua.
      title = "iNat Probe: Catalog APIs (renamed)…",
      file  = "CatalogProbeMenu.lua",
      id    = "inat_probe_catalog",
    },
    {
      title = "iNat Probe: Scrolled View…",
      file  = "ScrollProbeMenu.lua",
      id    = "inat_probe_scroll",
    },
    {
      title = "iNat Probe: Suggestion Rows…",
      file  = "RowProbeMenu.lua",
      id    = "inat_probe_rows",
    },
    {
      title = "iNat Probe: Thumbnails…",
      file  = "ThumbProbeMenu.lua",
      id    = "inat_probe_thumbs",
    },
    {
      title = "iNat Probe: Edit Field Commit…",
      file  = "EditCommitProbeMenu.lua",
      id    = "inat_probe_edit_commit",
    },
    {
      title = "iNat Probe: Export Presets…",
      file  = "ExportPresetProbeMenu.lua",
      id    = "inat_probe_export_presets",
    },
    {
      title = "iNat Probe: Plugin Reload…",
      file  = "ReloadProbeMenu.lua",
      id    = "inat_probe_reload",
    },
    {
      title = "iNat Probe: Late File Load…",
      file  = "LateLoadProbeMenu.lua",
      id    = "inat_probe_late_load",
    },
    {
      title = "iNat Probe: Missing Script…",
      file  = "MissingScriptProbeMenu.lua",
      id    = "inat_probe_missing_script",
    },
    {
      -- Raises on purpose, to show Lightroom's own dialog rather than a
      -- caught string. Run the one above first.
      title = "iNat Probe: Missing Script (uncaught)…",
      file  = "MissingScriptRawMenu.lua",
      id    = "inat_probe_missing_script_raw",
    },
    {
      -- DECLARED-SCRIPT TEST. There is no NoSuchDeclaredScript.lua and there
      -- never will be. Everything else in this plugin reaches a module
      -- through require; this reaches one the way Lightroom itself does,
      -- by name, out of this manifest.
      --
      -- Why it matters: substrate.dll carries three different failures and
      -- require only produces two of them.
      --
      --   error loading toolkit script `%s' (%s)                 require
      --   Could not load script %s: doesn't seem to be in the toolkit.
      --                                                          require, absent
      --   Could not load toolkit script: %s                      loadScript
      --
      -- The reporter's screenshot is the third one, word for word, and the
      -- third one sits next to "loadScript" and "name conflict for module"
      -- in the binary rather than next to require's wrapper. Clicking this
      -- should produce it. If it does, the message has nothing to do with
      -- require and names the script Lightroom was asked for by name.
      title = "iNat Probe: Missing Declared Script…",
      file  = "NoSuchDeclaredScript.lua",
      id    = "inat_probe_missing_declared",
    },
    {
      -- ANSWERED the wrong way: declared-and-absent gives "No script by the
      -- name X.lua", which is a fourth string and still not the reporter's.
      -- A file that is present and unloadable is the remaining class.
      title = "iNat Probe: Present But Unloadable…",
      file  = "UnreadableProbeMenu.lua",
      id    = "inat_probe_unloadable",
    },
    {
      -- DeclaredEmpty.lua is on disk and is zero bytes. Through require that
      -- gives "it appears to be in toolkit, but loading failed" -- a fifth
      -- string, still wrapped, still not the reporter's.
      --
      -- Every require failure so far arrives wrapped:
      --   error loading toolkit script `X' (reason)
      -- The reporter's has no wrapper, no backticks, no reason, and names
      -- PluginFiles with no .lua. So it is not require. This asks the only
      -- untried caller: Lightroom loading a DECLARED script that is present
      -- and will not load. Declared-and-absent already gave "No script by
      -- the name X.lua", so this is the remaining cell in the table.
      title = "iNat Probe: Declared Empty…",
      file  = "DeclaredEmpty.lua",
      id    = "inat_probe_declared_empty",
    },
    {
      -- Same path, failing for a different reason, so a match can be
      -- attributed to "declared script would not load" rather than to
      -- "zero bytes" specifically.
      title = "iNat Probe: Declared Broken…",
      file  = "DeclaredBroken.lua",
      id    = "inat_probe_declared_broken",
    },
  },

  VERSION = { major = 0, minor = 0, revision = 1, display = "probe" },
}
