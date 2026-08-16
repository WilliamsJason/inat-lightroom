--[[
  PluginShutdown.lua
  ------------------
  LrShutdownPlugin: run when Lightroom unloads the plugin, which happens when
  Lightroom quits and when the plugin is disabled or reloaded.

  Lightroom runs this file top to bottom, so it must never be required.

  This is where a staged update is actually applied. It is the only moment when
  every module that was going to load has loaded, so replacing the files on disk
  cannot produce a session running half of one version and half of another. The
  next launch reads a folder that is entirely one release.

  Nothing here is allowed to fail loudly. There is no user to show a dialog to
  during shutdown -- Lightroom is closing and a modal would either be missed or
  hold the process open -- so a failure goes to the log, the staged folder is
  left where it is, and PluginInit tries again at the next launch.

  The entry line is logged unconditionally, before anything can go wrong. It is
  the only way to tell "Lightroom never ran this hook" apart from "the hook ran
  and the swap failed", and those two have completely different fixes. Without
  it the two are indistinguishable, because a plugin that is being unloaded
  cannot report anything except in passing.
--]]

local logger = require "Log"

logger:trace("PluginShutdown: running")

local ok, err = pcall(function()
  local UpdateInstall = require "UpdateInstall"
  return UpdateInstall.apply()
end)

if not ok then
  logger:error("PluginShutdown: applying a staged update failed: " ..
    tostring(err))
end
