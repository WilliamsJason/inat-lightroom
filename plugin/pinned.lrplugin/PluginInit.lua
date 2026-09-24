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

  There is a second, sharper cost that took two releases and a user's log to
  understand. Lightroom fixes the set of toolkit scripts a plugin has when it
  loads the plugin, which is before this file runs. A file the release *adds*
  therefore cannot be required for the rest of this session, however correctly
  it was copied. Overwritten files are fine, which is what makes it so easy to
  miss: the update looks applied until something reaches for the one module
  that is new, and then Lightroom says "Could not load toolkit script: X".

  0.3.0 added ExportPresets.lua and 0.3.2 added PluginFiles.lua, and a user
  whose shutdown hook never runs -- so every update lands here -- got exactly
  that error, twice, for exactly those two files.

  Nothing can be done about it from inside the session, so the job is to say
  so: the flag below turns that internal error into an explanation, and the
  notice tells the user before they go looking for it.

  Second, check for a newer release. Throttled to once a day, silent when the
  network is not there, and skippable with a preference.
--]]

local UpdateInstall = require "UpdateInstall"
local UpdateCore    = require "UpdateCore"
local logger        = require "Log"

-- Cleared before anything else, so the flag always means "during this launch".
-- Read back by PluginFiles, and written here rather than through PluginFiles
-- because this is precisely the session in which a module might not load.
pcall(function()
  import("LrPrefs").prefsForPlugin(nil).update_applied_at_startup = nil
end)

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
