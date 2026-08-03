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

local LrApplication     = import "LrApplication"
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
-- Adopting an observation that already exists on iNaturalist: publishing can
-- only ever create new ones, so without this there is no way to connect a
-- Lightroom photo to an observation made in the field on a phone.
local function doLink()
  LrFunctionContext.postAsyncTaskWithContext("inat_url_link", function(context)
    local LrBinding = import "LrBinding"
    local LrView    = import "LrView"

    local catalog = LrApplication.activeCatalog()
    local photos  = catalog:getTargetPhotos()

    if not photos or #photos == 0 then
      LrDialogs.message("iNaturalist", "No photos selected.", "warning")
      return
    end

    local f     = LrView.osFactory()
    local props = LrBinding.makePropertyTable(context)
    props.obs_id = ""

    local contents = f:column {
      bind_to_object = props,
      spacing = f:label_spacing(),
      f:static_text {
        title = "Paste the observation ID or URL from iNaturalist.\n"
          .. "It will be applied to all " .. #photos .. " selected photo(s).",
        width = 400,
        height_in_lines = 2,
      },
      f:row {
        f:static_text { title = "Observation:", width = 90, alignment = "right" },
        f:edit_field { value = LrView.bind("obs_id"), width = 300, immediate = true },
      },
    }

    local result = LrDialogs.presentModalDialog {
      title      = "iNaturalist - Link to Observation",
      contents   = contents,
      actionVerb = "Link and Sync",
    }

    if result ~= "ok" then
      return
    end

    local obsId = PluginUrls.parseObservationId(props.obs_id)

    if not obsId then
      LrDialogs.message("iNaturalist",
        "That does not look like an observation ID or URL.", "warning")
      return
    end

    catalog:withWriteAccessDo("iNat link", function()
      for _, photo in ipairs(photos) do
        photo:setPropertyForPlugin(_PLUGIN, "inat_observation_id", obsId)
      end
    end)

    logger:info("Linked " .. #photos .. " photo(s) to observation " .. obsId)

    local SyncCore = require "SyncCore"
    SyncCore.syncTargetPhotos(context)
  end)
end

local handlers = {
  sync = doSync,
  link = doLink,
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
