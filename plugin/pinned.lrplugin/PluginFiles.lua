--[[
  PluginFiles.lua
  ---------------
  What a complete installation of this plugin contains, and what to say when
  one of those files is not there.

  WHY THIS EXISTS
  ---------------
  A user on 0.3.0 reported "An internal error has occurred. Could not load
  toolkit script: ExportPresets", and that message is worth reading carefully.
  Lightroom words a Lua *syntax* failure differently -- "error loading toolkit
  script `json' ([string "json.lua"]:134: ')' expected near '|')" -- and names
  the line. "Could not load toolkit script: X" is what `require` raises when
  the loader could not get hold of X.lua at all.

  So the failure is a file that is not on disk, and nothing in the plugin was
  able to say so. What the user saw instead was an internal error naming a
  module they have never heard of, from a menu item that had worked the day
  before, with no suggested action.

  Two things made that worse than it had to be:

    * RenderPhoto and SettingsDialog require ExportPresets at the top of the
      file, so one absent module takes out the whole Observation Panel *and*
      Settings -- including the screen a user would go to to turn the feature
      off. A missing file for one feature removed every feature.

    * The plugin already knows how to download and verify its own release. It
      simply had no way to be told "do that again, the copy on disk is wrong",
      because the updater only ever offers a *newer* version and a repair is by
      definition a reinstall of the one you already have.

  So this module answers one question -- which of the files that ship are
  missing -- and turns the answer into a sentence that names the repair. The
  list is checked against the folder by a test, because a manifest that has
  drifted from what ships would report a healthy install as broken, and that is
  a worse failure than the one it is here to catch.

  WHAT IT DELIBERATELY DOES NOT DO
  --------------------------------
  It does not check file contents, sizes or hashes. The archive's checksum is
  verified before it is ever unpacked (UpdateInstall.stage), so "the bytes on
  disk are wrong" is not a state the updater can produce; "a file is absent" is,
  because applying an update is a file-by-file copy that can stop part way.

  It requires nothing but the SDK. Every other module in this plugin requires
  Log, and a module whose job is to explain a missing file should not be the
  next thing that cannot load because a different file is missing.
--]]

local LrDialogs   = import "LrDialogs"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"
local LrPrefs     = import "LrPrefs"

local PluginFiles = {}

--- The preference PluginInit sets when it applies an update during startup.
--
-- Written by PluginInit and read here, as a bare string on both sides rather
-- than through Settings. The whole point of this flag is a session where a
-- module might not be loadable, so the two files that need it must not have to
-- load a third to agree on the name. test_plugin_files_lua.py pins them
-- together.
--
-- Cleared at the top of every launch, so "set" means "this launch", not "at
-- some point in the past".
PluginFiles.APPLIED_AT_STARTUP_PREF = "update_applied_at_startup"

--- Every file a released copy of this plugin contains.
--
-- Kept in alphabetical order, and pinned to the contents of the plugin folder
-- by test_plugin_files_lua.py. Adding a file to the folder without adding it
-- here fails that test rather than shipping a repair that does not notice the
-- file is gone.
--
-- The shell scripts and the placeholder image are here for the same reason the
-- Lua is: install_update.sh missing is an updater that cannot update, and
-- no-photo.png missing is a panel with a hole in it. Neither raises on load,
-- which is precisely why neither would otherwise be noticed.
PluginFiles.FILES = {
  "Clipboard.lua",
  "CustomMetadata.lua",
  "ExportPresets.lua",
  "InatAPI.lua",
  "InatAuth.lua",
  "InatOAuth.lua",
  "Info.lua",
  "Jobs.lua",
  "LinkObservation.lua",
  "Log.lua",
  "MatchCore.lua",
  "ObservationPanel.lua",
  "ObservationPanelMenu.lua",
  "PanelCore.lua",
  "PluginFiles.lua",
  "PluginInfoProvider.lua",
  "PluginInit.lua",
  "PluginShutdown.lua",
  "PluginUrls.lua",
  "RenderPhoto.lua",
  "ReverseSync.lua",
  "ReverseSyncDialog.lua",
  "Settings.lua",
  "SettingsDialog.lua",
  "SettingsMenu.lua",
  "Sha256.lua",
  "SyncCore.lua",
  "TagsetInat.lua",
  "ThumbCache.lua",
  "UpdateCore.lua",
  "UpdateInstall.lua",
  "Updater.lua",
  "UploadCore.lua",
  "URLHandler.lua",
  "WindowFix.lua",
  "fix_window_z_order.ps1",
  "install_update.ps1",
  "install_update.sh",
  "json.lua",
  "no-photo.png",
}

--- The files from FILES that are not in the plugin folder.
--
-- @param pluginPath  defaults to the running plugin
-- @return a list of names, empty when the installation is complete
function PluginFiles.missing(pluginPath)
  pluginPath = pluginPath or _PLUGIN.path

  local absent = {}

  for _, name in ipairs(PluginFiles.FILES) do
    local path = LrPathUtils.child(pluginPath, name)

    -- Guarded, and the result compared against "file" rather than tested for
    -- truth: LrFileUtils.exists returns the string "directory" for a folder,
    -- which is truthy and is not a file the loader could read.
    local ok, what = pcall(LrFileUtils.exists, path)
    if not ok or what ~= "file" then
      absent[#absent + 1] = name
    end
  end

  return absent
end

--- The sentence to show someone whose installation is incomplete, or nil.
--
-- nil when nothing is missing, because the caller's other possible reason for
-- asking -- a real bug in a module that did load -- must not be dressed up as
-- a broken install. Being told to repair a plugin that is not damaged sends a
-- user round a download they did not need and leaves the actual fault
-- unreported.
function PluginFiles.brokenInstallText(pluginPath)
  local absent = PluginFiles.missing(pluginPath)
  if #absent == 0 then return nil end

  local count = #absent
  local noun  = count == 1 and "file is" or "files are"

  return count .. " " .. noun .. " missing from this plugin's folder:\n\n"
    .. table.concat(absent, ", ") .. "\n\n"
    .. "This usually means an update did not finish copying. Open "
    .. "File \226\150\184 Plug-in Manager, select Pinned for iNaturalist, and "
    .. "press Repair Installation to download this release again and put them "
    .. "back."
end

--- The tag of an update applied during this launch, or nil.
--
-- Set by PluginInit when it applies a staged update that the shutdown hook
-- never got to. See staleSessionText for why anyone cares.
function PluginFiles.appliedAtStartup()
  local ok, prefs = pcall(LrPrefs.prefsForPlugin, nil)
  if not ok or not prefs then return nil end

  local tag = prefs[PluginFiles.APPLIED_AT_STARTUP_PREF]
  if type(tag) ~= "string" or tag == "" then return nil end
  return tag
end

--- Record that this launch applied an update. Called by PluginInit only.
function PluginFiles.setAppliedAtStartup(tag)
  local ok, prefs = pcall(LrPrefs.prefsForPlugin, nil)
  if not ok or not prefs then return false end

  prefs[PluginFiles.APPLIED_AT_STARTUP_PREF] = tag or nil
  return true
end

--- The sentence for a module that is on disk but that Lightroom will not load.
--
-- THE FAILURE THIS EXPLAINS
-- -------------------------
-- Lightroom decides which toolkit scripts a plugin has when it loads the
-- plugin, which is *before* LrInitPlugin runs. A file that was not in the
-- folder at that moment cannot be required for the rest of that session, even
-- though it is sitting right there on disk.
--
-- That matters because applying an update at startup is a supported path: it
-- is what happens when the shutdown hook never ran. Files that already existed
-- are overwritten and load normally, so the update looks like it worked --
-- until something requires a module the release *added*, which is the one file
-- Lightroom is not expecting.
--
-- Two users' worth of the same shape:
--
--   0.3.0 added ExportPresets.lua   -> "Could not load toolkit script: ExportPresets"
--   0.3.2 added PluginFiles.lua     -> "Could not load toolkit script: PluginFiles"
--
-- Both applied at startup, both logged a complete file count, both times the
-- file was present. Nothing is damaged and a repair would download a folder
-- that is already correct, so this has to be told apart from a missing file --
-- the cure is a restart and nothing else.
function PluginFiles.staleSessionText(tag)
  tag = tag or PluginFiles.appliedAtStartup()
  if not tag then return nil end

  return "The update to " .. tostring(tag) .. " finished after Lightroom had "
    .. "already started, so Lightroom is still working from the list of files "
    .. "the plugin had when it launched and cannot load the new ones.\n\n"
    .. "Nothing is broken and nothing needs downloading again. Quit Lightroom "
    .. "and start it again, and the update will be in use."
end

--- Report a failure that might be a missing file, or let it through.
--
-- Menu item scripts call this. Lightroom runs one top to bottom when it is
-- clicked and reports anything that escapes as "An internal error has
-- occurred", which for a missing module names a Lua file and no action -- so
-- the case worth intercepting is exactly the one this module can explain.
--
-- Anything else is re-raised untouched, deliberately. Swallowing a genuine bug
-- into a dialog about reinstalling would be trading a reportable error for a
-- wrong answer, and the stack Lightroom prints is the only diagnostic a user
-- can send.
function PluginFiles.report(err, pluginPath)
  -- Missing first. If a file really is absent, a repair is the answer whether
  -- or not an update was applied during this launch.
  local text = PluginFiles.brokenInstallText(pluginPath)
  local title = "Pinned could not load part of itself"

  if not text then
    -- Nothing absent, so the other explanation this module can offer is a
    -- module Lightroom will not load until it is restarted.
    text = PluginFiles.staleSessionText()
    title = "Restart Lightroom to finish updating"
  end

  if not text then error(err, 0) end

  LrDialogs.message(title, text, "critical")
  return text
end

--- Run something that requires modules, explaining a broken install if it
--- fails for that reason.
--
-- @param action  a function taking no arguments
function PluginFiles.protect(action, pluginPath)
  local ok, err = pcall(action)
  if ok then return true end

  PluginFiles.report(err, pluginPath)
  return false
end

return PluginFiles
