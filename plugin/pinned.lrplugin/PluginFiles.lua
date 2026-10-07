--[[
  PluginFiles.lua
  ---------------
  What a complete installation of this plugin contains, and what to say when
  one of those files is not there.

  WHY THIS EXISTS
  ---------------
  A user on 0.3.0 reported "An internal error has occurred. Could not load
  toolkit script: ExportPresets", and a second user-visible failure of the
  same shape followed on 0.3.2 naming PluginFiles.

  The wording was read three different ways across three releases -- a missing
  file, a file Lightroom would not bind, a file it could not read -- and each
  reading was shipped before anyone tried to produce the message on purpose.
  When that was finally done, seven deliberate failures produced seven
  different strings and none of them matched the report:

    require, no file        error loading toolkit script `X' (Could not load
                            script X.lua: doesn't seem to be in the toolkit.)
    require, zero bytes     ... it appears to be in toolkit, but loading failed
    require, unreadable     ... it appears to be in toolkit, but loading failed
    require, bad parse      error loading toolkit script `X' ([string ...]:1: ...)
    declared, no file       No script by the name X.lua
    declared, zero bytes    Could not load script X.lua: it appears to be in
                            toolkit, but loading failed
    declared, bad parse     [string "X.lua"]:1: ...

  So this module does NOT know why that user's plugin failed, and must not
  pretend to. What it knows is narrower and still useful: which files that
  ship are not usable on disk right now, and that a reinstall is how to get
  them back. See docs/lightroom-sdk-notes.md for the full table and the probe
  that produced it.

  Two things made the original report worse than it had to be, and both are
  still worth guarding:

    * RenderPhoto and SettingsDialog require ExportPresets at the top of the
      file, so one absent module takes out the whole Observation Panel *and*
      Settings -- including the screen a user would go to to turn the feature
      off. A missing file for one feature removed every feature.

    * The plugin already knows how to download and verify its own release. It
      simply had no way to be told "do that again, the copy on disk is wrong",
      because the updater only ever offers a *newer* version and a repair is by
      definition a reinstall of the one you already have.

  So this module answers one question -- which of the files that ship are
  unusable -- and turns the answer into a sentence that names the repair. The
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

local PluginFiles = {}

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
  "NameStyle.lua",
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
  "TaxonomyDialog.lua",
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

--- Why a file that should ship cannot be used, or nil if it is fine.
--
-- "Does the file exist" is not the question worth asking, and asking it was a
-- real weakness: LrFileUtils.exists returns the string "directory" for a
-- folder wearing a .lua name and "file" for something with no read
-- permission, and both are truthy. A folder whose files are all present and
-- half of them unreadable would have been reported as healthy, which is
-- exactly the experience of being told nothing is wrong while nothing works.
--
-- Each check is guarded separately so that a failure to *ask* is never
-- reported as a failure of the file.
local function unusable(path)
  local ok, what = pcall(LrFileUtils.exists, path)
  if not ok then return "could not be checked" end
  if what == "directory" then return "is a folder, not a file" end
  if what ~= "file" then return "is missing" end

  -- Both of the checks below are optional in the sense that matters: if the
  -- SDK call is not there, or raises, the file is left alone rather than
  -- accused. Reporting a healthy installation as damaged sends a user round
  -- a download they did not need and teaches them to ignore the warning,
  -- which is worse than missing the case this is trying to catch.
  if type(LrFileUtils.isReadable) == "function" then
    local asked, readable = pcall(LrFileUtils.isReadable, path)
    if asked and readable == false then return "cannot be read" end
  end

  -- Zero bytes parses to an empty chunk, so Lua will not complain, but
  -- Lightroom's loader does and a module that returns nothing is not the
  -- module anything expected. A plausible result of a copy that created the
  -- destination and wrote nothing into it.
  if type(LrFileUtils.fileAttributes) == "function" then
    local asked, attributes = pcall(LrFileUtils.fileAttributes, path)
    if asked and type(attributes) == "table"
      and attributes.fileSize == 0 then
      return "is empty"
    end
  end

  return nil
end

--- The files from FILES that are not usable in the plugin folder.
--
-- @param pluginPath  defaults to the running plugin
-- @return a list of names, empty when the installation is complete
function PluginFiles.missing(pluginPath)
  pluginPath = pluginPath or _PLUGIN.path

  local absent = {}

  for _, name in ipairs(PluginFiles.FILES) do
    if unusable(LrPathUtils.child(pluginPath, name)) then
      absent[#absent + 1] = name
    end
  end

  return absent
end

--- The same question, answered with reasons: a list of "name (reason)".
--
-- Separate from missing() because the reason is for a human reading a
-- sentence or a log, and every existing caller wants the bare names.
function PluginFiles.problems(pluginPath)
  pluginPath = pluginPath or _PLUGIN.path

  local found = {}

  for _, name in ipairs(PluginFiles.FILES) do
    local why = unusable(LrPathUtils.child(pluginPath, name))
    if why then
      found[#found + 1] = name .. " (" .. why .. ")"
    end
  end

  return found
end

--- The sentence to show someone whose installation is incomplete, or nil.
--
-- nil when nothing is wrong, because the caller's other possible reason for
-- asking -- a real bug in a module that did load -- must not be dressed up as
-- a broken install. Being told to repair a plugin that is not damaged sends a
-- user round a download they did not need and leaves the actual fault
-- unreported.
function PluginFiles.brokenInstallText(pluginPath)
  local found = PluginFiles.problems(pluginPath)
  if #found == 0 then return nil end

  local count = #found
  local noun  = count == 1 and "file is" or "files are"

  return count .. " " .. noun .. " missing or unusable in this plugin's "
    .. "folder:\n\n" .. table.concat(found, ", ") .. "\n\n"
    .. "This usually means an update did not finish copying. Open "
    .. "File \226\150\184 Plug-in Manager, select Pinned for iNaturalist, and "
    .. "press Repair Installation to download this release again and put them "
    .. "back."
end

--- Report a failure that might be a broken install, or let it through.
--
-- Menu item scripts call this. Lightroom runs one top to bottom when it is
-- clicked and reports anything that escapes as "An internal error has
-- occurred", which for a module that will not load names a Lua file and no
-- action -- so the case worth intercepting is exactly the one this module can
-- explain.
--
-- Anything else is re-raised untouched, deliberately. Swallowing a genuine bug
-- into a dialog about reinstalling would be trading a reportable error for a
-- wrong answer, and the stack Lightroom prints is the only diagnostic a user
-- can send.
--
-- There used to be a second branch here, for a session that had applied an
-- update at startup: it told the user to restart. The mechanism it described
-- does not exist -- see PluginInit.lua -- so it has been removed rather than
-- left to offer a confident wrong answer to a failure nobody has explained.
function PluginFiles.report(err, pluginPath)
  local text = PluginFiles.brokenInstallText(pluginPath)
  if not text then error(err, 0) end

  LrDialogs.message("Pinned could not load part of itself", text, "critical")
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
