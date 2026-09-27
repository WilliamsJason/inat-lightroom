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

  A sharper claim used to be made here, and it was wrong. It said Lightroom
  fixes the set of toolkit scripts when it loads the plugin, so a file an
  update *added* could not be required for the rest of the session. A probe
  disproved it: a .lua file written during LrInitPlugin is requireable in the
  same session, and Reload Plug-in picks up new files, new menu items and
  renames. The machinery that announced a needed restart has been removed
  along with the claim. See docs/lightroom-sdk-notes.md for the runs.

  What broke for the user who prompted all this is still not known. The error
  they saw -- "Could not load toolkit script: PluginFiles" -- could not be
  reproduced by any of seven deliberate attempts, and a missing, empty,
  unreadable or directory-shaped file each produces different wording. They
  were unblocked by installing 0.3.3 and restarting, which is not evidence for
  any particular mechanism: that step also delivered a fresh copy of every
  file, so "the restart fixed it" and "a correct copy finally landed" cannot
  be told apart.

  Worth revisiting the next time a release adds a file, which is the case that
  went wrong twice. Until then, do not encode a theory here.

  Second, check for a newer release. Throttled to once a day, silent when the
  network is not there, and skippable with a preference.
--]]

local UpdateInstall = require "UpdateInstall"
local UpdateCore    = require "UpdateCore"
local logger        = require "Log"

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
end

UpdateCore.checkOnStartup()
