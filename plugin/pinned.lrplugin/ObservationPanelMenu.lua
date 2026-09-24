--[[
  ObservationPanelMenu.lua
  ------------------------
  File > Plug-in Extras > Observation Panel.

  Lightroom runs a menu item's file top to bottom when it is clicked, so this
  file must never be required by anything: loading it is running it. The real
  work is in ObservationPanel.lua.

  The require is wrapped because the panel pulls in most of the plugin --
  PanelCore, RenderPhoto, ExportPresets and the rest -- and any one of those
  missing from the folder surfaces here as "An internal error has occurred.
  Could not load toolkit script: <a name the user has never seen>". PluginFiles
  turns that into the repair, and re-raises anything that is not a missing
  file, so a real bug in the panel still reports itself as one.
--]]

local PluginFiles = require "PluginFiles"

PluginFiles.protect(function()
  require("ObservationPanel").show()
end)
