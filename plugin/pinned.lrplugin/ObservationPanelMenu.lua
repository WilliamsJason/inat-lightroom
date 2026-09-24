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

  WHY PluginFiles IS ITSELF REQUIRED THROUGH A pcall
  --------------------------------------------------
  Because it was the crash, once. 0.3.2 added PluginFiles.lua and this file
  opened with a plain `require "PluginFiles"`, so for a user whose update was
  applied at startup -- where Lightroom will not load a file that was not in
  the folder when it launched -- clicking the menu item produced "Could not
  load toolkit script: PluginFiles". The safety net was a new file, and a new
  file was exactly what could not be loaded.

  So nothing here may assume the guard loaded. The fallback imports only from
  the SDK, which cannot go missing, and is deliberately dull: it says what
  failed and the two things worth trying, which still beats an internal error
  naming a Lua module.
--]]

local function fallback(err)
  import("LrDialogs").message(
    "Pinned for iNaturalist could not start",
    tostring(err) .. "\n\nIf Lightroom updated this plugin while it was "
      .. "running, quit Lightroom and start it again. If that does not help, "
      .. "open File \226\150\184 Plug-in Manager, select Pinned for "
      .. "iNaturalist, and press Repair Installation.",
    "critical")
end

local function show()
  require("ObservationPanel").show()
end

local loaded, PluginFiles = pcall(require, "PluginFiles")

if loaded then
  PluginFiles.protect(show)
else
  local ok, err = pcall(show)
  if not ok then fallback(err) end
end
