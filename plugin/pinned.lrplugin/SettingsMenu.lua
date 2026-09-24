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
  plugin, so it is the last door that should be stuck shut. See PluginFiles.
--]]

local PluginFiles = require "PluginFiles"

PluginFiles.protect(function()
  require("SettingsDialog").show()
end)
