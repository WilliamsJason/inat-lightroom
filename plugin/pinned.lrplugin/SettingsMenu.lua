--[[
  SettingsMenu.lua
  ----------------
  File > Plug-in Extras > "Settings…".

  Was "Set Up Credentials". It covers more than credentials now -- the publish
  service's settings had nowhere else to go once it was removed -- but the
  reason it is a menu item rather than part of the panel has not changed: you
  need it before anything works, and the observation panel is a poor place to
  type a token into.

  Like every menu-item script, Lightroom runs this file top to bottom when the
  item is clicked. Nothing may require it -- the dialog itself is in
  SettingsDialog.lua for exactly that reason.

  Guarded like the panel's item, and this one matters more: Settings is where
  someone would go to turn off the feature whose missing module broke the
  plugin, so it is the last door that should be stuck shut. See PluginFiles --
  including why the guard itself is loaded through a pcall.
--]]

local function fallback(err)
  import("LrDialogs").message(
    "Pinned for iNaturalist could not open Settings",
    tostring(err) .. "\n\nIf Lightroom updated this plugin while it was "
      .. "running, quit Lightroom and start it again. If that does not help, "
      .. "open File \226\150\184 Plug-in Manager, select Pinned for "
      .. "iNaturalist, and press Repair Installation.",
    "critical")
end

local function show()
  require("SettingsDialog").show()
end

local loaded, PluginFiles = pcall(require, "PluginFiles")

if loaded then
  PluginFiles.protect(show)
else
  local ok, err = pcall(show)
  if not ok then fallback(err) end
end
