--[[
  URLHandler.lua
  --------------
  Receives "lightroom://com.github.inat-lightroom/<action>" URLs.

  Wired up by the URLHandler entry in Info.lua. That key is real but barely
  documented; Adobe's own bundled Flickr.lrplugin uses it for its OAuth
  callback, and the constant table of its compiled URLHandler chunk confirms
  the contract this file follows: return a table with a single URLHandler
  function taking the whole URL as a string.

  This was built to give the Metadata panel something like a button: a custom
  field of dataType "url" renders as a clickable row, and clicking one really
  does route back into the plugin -- confirmed in a running Lightroom Classic.
  Those rows are gone now, because the panel gives a plugin no say over the
  row's label, its value, or what the arrow does, and the actions moved to the
  publish service.

  The handler stays for two reasons. It is how a shortcut or a browser can
  drive the plugin, and OAuth needs exactly this: iNaturalist will send the
  authorization code back to a lightroom:// redirect, which is what lets a
  public client work without shipping a secret.
--]]

local LrDialogs         = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"

local PluginUrls = require "PluginUrls"
local logger     = require "Log"

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

--- Sync the selected photos.
local function doSync()
  local SyncCore = require "SyncCore"
  LrFunctionContext.postAsyncTaskWithContext("inat_url_sync", function(context)
    SyncCore.syncTargetPhotos(context)
  end)
end

--- Ask for an observation ID and attach it to the selection, then sync.
local function doLink()
  require("LinkObservation").start()
end

--- Open the floating panel.
local function doPanel()
  require("ObservationPanel").show()
end

local handlers = {
  sync  = doSync,
  link  = doLink,
  panel = doPanel,
}

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

return {
  URLHandler = function(url)
    local action = PluginUrls.parse(url)

    if not action then
      logger:warn("Ignoring URL that is not ours: " .. tostring(url))
      return
    end

    local handler = handlers[action]
    if not handler then
      logger:warn("Unknown action: " .. tostring(action))
      LrDialogs.message("iNaturalist",
        "Unknown action: " .. tostring(action), "warning")
      return
    end

    logger:info("Plugin URL action: " .. action)
    handler()
  end,
}
