--[[
  LinkObservation.lua
  -------------------
  Attaching a Lightroom photo to an observation that already exists.

  Publishing can only ever create new observations, so without this there is no
  way to connect a photo to one made in the field on a phone -- which is most of
  them, for most people.

  This lives in its own module because two entry points need it: the floating
  panel's button and the lightroom:// URL handler. It used to be a local
  function inside URLHandler.lua, which meant the panel could only reach it by
  pretending to be a URL.
--]]

local LrApplication     = import "LrApplication"
local LrBinding         = import "LrBinding"
local LrDialogs         = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrView            = import "LrView"

local PluginUrls = require "PluginUrls"
local logger     = require "Log"

local LinkObservation = {}

--- Ask for an observation ID, store it on the selection, then sync.
-- @param context  A live LrFunctionContext; the dialog's property table and the
--                 sync's progress scope are both tied to it.
-- @return         The number of photos linked, or 0 if nothing happened.
function LinkObservation.run(context)
  local catalog = LrApplication.activeCatalog()
  local photos  = catalog:getTargetPhotos()

  if not photos or #photos == 0 then
    LrDialogs.message("iNaturalist", "No photos selected.", "warning")
    return 0
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
    return 0
  end

  local obsId = PluginUrls.parseObservationId(props.obs_id)

  if not obsId then
    LrDialogs.message("iNaturalist",
      "That does not look like an observation ID or URL.", "warning")
    return 0
  end

  catalog:withWriteAccessDo("iNat link", function()
    for _, photo in ipairs(photos) do
      photo:setPropertyForPlugin(_PLUGIN, "inat_observation_id", obsId)
    end
  end)

  logger:info("Linked " .. #photos .. " photo(s) to observation " .. obsId)

  -- Sync immediately: the point of linking is to pull the observation's taxon
  -- down, and making that a second, separate step people have to know about
  -- would leave the photo looking no different for having been linked.
  local SyncCore = require "SyncCore"
  SyncCore.syncPhotos(context, photos)

  return #photos
end

--- Run it in its own task, for callers that are not already inside one.
function LinkObservation.start()
  LrFunctionContext.postAsyncTaskWithContext("inat_link", function(context)
    LinkObservation.run(context)
  end)
end

return LinkObservation
