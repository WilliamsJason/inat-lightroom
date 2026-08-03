--[[
  URLHandler.lua
  --------------
  Receives "lightroom://com.github.inat-lightroom/<action>" URLs.

  Wired up by the URLHandler entry in Info.lua. That key is real but barely
  documented; Adobe's own bundled Flickr.lrplugin uses it for its OAuth
  callback, and the constant table of its compiled URLHandler chunk confirms
  the contract this file follows: return a table with a single URLHandler
  function taking the whole URL as a string.

  The reason this exists is the Metadata panel. Lightroom offers no way to put
  a button there, but it renders a custom metadata field of dataType "url" as
  a clickable link -- so a field holding one of our own lightroom:// URLs is
  the closest thing to a panel button available. See PanelActions.lua.

  Whether Lightroom routes a click on a *metadata* URL back into the plugin is
  the open question this is meant to answer in the host; the stubs cannot. If
  it does not, nothing here runs and the fields are inert text.

  The handler also fires for URLs opened any other way (a browser, a shortcut),
  which is a bonus rather than a problem: every action operates on the current
  selection, so it behaves the same either way.
--]]

local LrApplication     = import "LrApplication"
local LrDialogs         = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"

local PanelActions = require "PanelActions"
local logger       = require "Log"

--------------------------------------------------------------------------------
-- Actions
--------------------------------------------------------------------------------

--- Sync the selected photos. Deliberately not requiring SyncObservation:
-- that is a menu-item script and loading it runs a sync.
local function doSync()
  local SyncCore = require "SyncCore"
  LrFunctionContext.postAsyncTaskWithContext("inat_panel_sync", function(context)
    SyncCore.syncTargetPhotos(context)
  end)
end

--- Ask for an observation ID and attach it to the selection, then sync.
-- This is the workflow the Metadata panel could not otherwise offer: adopting
-- an observation that already exists on iNaturalist.
local function doLink()
  LrFunctionContext.postAsyncTaskWithContext("inat_panel_link", function(context)
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

    local obsId = PanelActions.parseObservationId(props.obs_id)

    if not obsId then
      LrDialogs.message("iNaturalist",
        "That does not look like an observation ID or URL.", "warning")
      return
    end

    catalog:withWriteAccessDo("iNat link", function()
      for _, photo in ipairs(photos) do
        photo:setPropertyForPlugin(_PLUGIN, "inat_observation_id", obsId)
        PanelActions.armPhoto(photo)
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
    local action = PanelActions.parse(url)

    if not action then
      logger:warn("Ignoring URL that is not ours: " .. tostring(url))
      return
    end

    local handler = handlers[action]
    if not handler then
      logger:warn("Unknown panel action: " .. tostring(action))
      LrDialogs.message("iNaturalist",
        "Unknown action: " .. tostring(action), "warning")
      return
    end

    logger:info("Panel action: " .. action)
    handler()
  end,
}
