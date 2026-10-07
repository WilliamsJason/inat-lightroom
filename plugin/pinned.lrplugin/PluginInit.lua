--[[
  PluginInit.lua
  --------------
  LrInitPlugin: run when Lightroom loads the plugin.

  Lightroom runs this file top to bottom, so it must never be required by
  anything -- loading it is running it, the same as the menu item files.

  Two jobs, in this order and for a reason.

  First, finish any update that was staged but never applied. Normally the
  shutdown hook applies it as Lightroom closes; this is the path for the launch
  after Lightroom was killed, crashed, or was force-quit with a staged update
  waiting. It happens here because LrInitPlugin runs before any other module of
  this plugin is required, so the swap lands before anything can read a mixture
  of two versions.

  What it cannot fix is Info.lua, which Lightroom read before running a line of
  this. This session therefore runs new code behind the old manifest -- new menu
  items or metadata fields appear only at the next launch. That is a real cost
  and it is the cheaper of the two: the alternative is leaving the update
  unapplied indefinitely.

  A sharper claim used to be made here, and then it was removed, and the
  removal was also wrong. It said Lightroom fixes the set of toolkit scripts
  when it loads the plugin, so a file an update *added* could not be required
  for the rest of the session. A probe appeared to disprove it: a .lua file
  written during LrInitPlugin is requireable in the same session, and Reload
  Plug-in picks up new files, new menu items and renames.

  The field disagrees with the probe, three times now, always with the same
  shape -- a release that adds a file, applied at startup, then "Could not
  load toolkit script: <the added file>":

    0.3.0 added ExportPresets.lua -> could not load ExportPresets
    0.3.2 added PluginFiles.lua   -> could not load PluginFiles
    0.3.4 added NameStyle.lua     -> could not load NameStyle

  The third report is the one that forces the issue. That user quit and
  restarted and everything worked: nothing was downloaded again, no repair was
  run, so the file was on disk the whole time and the session would not load
  it. A missing file cannot explain that, and neither can the probe.

  So: the mechanism is unknown and nothing here should assert one. What is
  known is the symptom, that it follows applying an update at startup, and
  that a restart is the only thing that has ever cleared it. The flag below
  records the applied tag so PluginFiles can offer a restart instead of an
  internal error, and UpdateCore says it up front rather than waiting for the
  user to find it by clicking a menu item.

  Worth revisiting whenever a release adds a file, which is the case that has
  now gone wrong three times. A probe that reproduces it is still owed.

  Second, check for a newer release. Throttled to once a day, silent when the
  network is not there, and skippable with a preference.
--]]

local UpdateInstall = require "UpdateInstall"
local UpdateCore    = require "UpdateCore"
local logger        = require "Log"

-- Cleared before anything else, so the flag always means "during this launch".
-- Read back by PluginFiles, and written here as a bare preference key rather
-- than through PluginFiles because this is precisely the session in which a
-- module might not load. test_plugin_files_lua.py pins the two names together.
pcall(function()
  import("LrPrefs").prefsForPlugin(nil).update_applied_at_startup = nil
end)

--- Write the Lightroom build and platform into the log, once per launch.
--
-- This exists because a user's 40,000-line log recorded neither, and working
-- out even which operating system they were on came down to noticing a
-- /var/folders path in a temp filename. A version-specific theory could not
-- be checked at all.
--
-- Wrapped in pcall per field and never fatal: this is diagnostics, and a
-- plugin that fails to start because it could not describe itself would be a
-- poor trade. Anything unavailable is logged as unknown rather than skipped,
-- because "we asked and could not tell" is itself worth seeing.
local function logEnvironment()
  local function ask(f)
    local ok, value = pcall(f)
    if not ok or value == nil then return "unknown" end
    return tostring(value)
  end

  local version = ask(function()
    local v = import("LrApplication").versionTable()
    return string.format("%s.%s.%s build %s",
      tostring(v.major), tostring(v.minor), tostring(v.revision),
      tostring(v.build))
  end)

  local system = import "LrSystemInfo"

  logger:info(string.format(
    "Environment: Lightroom %s, %s, %s, %s RAM, plugin id %s",
    version,
    ask(system.summaryString),
    ask(system.architecture),
    ask(function() return system.memSize() end),
    ask(function() return tostring(_PLUGIN and _PLUGIN.id or nil) end)))
end

pcall(logEnvironment)

local applied = UpdateInstall.apply()
if applied then
  logger:info("PluginInit: applied a staged update (" .. tostring(applied) ..
    ") that shutdown did not; Info.lua changes take effect next launch")

  pcall(function()
    import("LrPrefs").prefsForPlugin(nil).update_applied_at_startup = applied
  end)

  UpdateCore.announceRestartNeeded(applied)
end

UpdateCore.checkOnStartup()
