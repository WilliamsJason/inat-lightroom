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

  Second, check for a newer release. Throttled to once a day, silent when the
  network is not there, and skippable with a preference.
--]]

local UpdateInstall = require "UpdateInstall"
local UpdateCore    = require "UpdateCore"
local logger        = require "Log"

local applied = UpdateInstall.apply()
if applied then
  logger:info("PluginInit: applied a staged update (" .. tostring(applied) ..
    ") that shutdown did not; Info.lua changes take effect next launch")
end

UpdateCore.checkOnStartup()
