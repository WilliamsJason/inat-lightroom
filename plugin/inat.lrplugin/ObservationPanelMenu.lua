--[[
  ObservationPanelMenu.lua
  ------------------------
  File > Plug-in Extras > Pinning Panel.

  Lightroom runs a menu item's file top to bottom when it is clicked, so this
  file must never be required by anything: loading it is running it. The real
  work is in ObservationPanel.lua.
--]]

require("ObservationPanel").show()
