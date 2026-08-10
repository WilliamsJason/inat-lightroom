--[[
  UploadCore.lua
  --------------
  Creating observations on iNaturalist and attaching photos to them.

  This is the part of the old publish service worth keeping. The service itself
  is gone -- the floating panel is the plugin's interaction surface now -- but
  the sequence it worked out is unchanged, and most of it was learned the hard
  way:

    * an observation is resolved by UUID before anything is created, so a
      second upload of the same photos does not make a second observation
    * an observation that has since been deleted on the website is a normal
      thing to find, not an error; a fresh one is created under the same UUID
    * a 200 from the photo upload is not evidence the photo attached, so
      InatAPI:uploadPhotoVerified polls until it can confirm it

  What changed with the panel is the grouping. A publish service is handed
  photos one at a time, so "these frames are one observation" had to be
  recorded on the photos in advance and inat_observation_uuid existed to carry
  it. The panel has the whole selection in front of it, so selecting six frames
  and pressing Upload means one observation with six photos -- the UUID is
  still written, but now it is the *result* of grouping rather than the
  mechanism for it.
--]]

local LrApplication = import "LrApplication"
local LrDate        = import "LrDate"

local InatAPI  = require "InatAPI"
local InatAuth = require "InatAuth"
local logger   = require "Log"

local UploadCore = {}

local OBSERVATION_URL = "https://www.inaturalist.org/observations/"

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Return an authenticated InatAPI instance, or nil plus an error message.
-- Must be called from inside an async task.
function UploadCore.requireAPI()
  local token, err = InatAuth.getToken()
  if not token then
    return nil, err or "iNaturalist credentials are not set up."
  end
  return InatAPI.new(token), nil
end

--- Read a photo's plugin metadata field, treating "" as absent.
local function pluginField(photo, id)
  local value = photo:getPropertyForPlugin(_PLUGIN, id)
  if value == nil or value == "" then return nil end
  return value
end
UploadCore.pluginField = pluginField

--- The observation date for one photo, from its own capture time.
--
-- Lightroom counts seconds from 2001-01-01, not the Unix epoch, so os.date
-- would be 31 years out. LrDate knows the difference.
function UploadCore.observedOnFor(photo)
  local captured = photo:getRawMetadata("dateTimeOriginal")
  if not captured then return nil end
  return LrDate.timeToUserFormat(captured, "%Y-%m-%d")
end

--- Read a photo's coordinates, if it has any.
--
-- Shared because three callers wanted it and each had grown its own copy: the
-- observation body, the vision request, and now the panel's warning. Three
-- copies of "does this photo have a location" is three chances to disagree
-- about it, and the panel disagreeing with the uploader is exactly the bug
-- that would teach users to ignore the warning.
--
-- @return latitude, longitude -- both nil when the photo has no location
function UploadCore.locationOf(photo)
  local gps = photo:getRawMetadata("gps")
  if gps and gps.latitude and gps.longitude then
    return gps.latitude, gps.longitude
  end
  return nil, nil
end

--- Build the observation body for one photo.
--
-- Everything specific to the observation comes off the photo. Only the things
-- that really are preferences rather than observations -- geoprivacy, whether
-- to send location at all -- come from settings.
function UploadCore.observationParamsFor(settings, photo, options)
  settings = settings or {}
  options  = options or {}

  local params = {
    geoprivacy = settings.inat_geoprivacy or "open",
  }

  local observedOn = UploadCore.observedOnFor(photo)
  if observedOn then
    params.observed_on_string = observedOn
  end

  local guess = pluginField(photo, "inat_species_guess")
  if guess then
    params.species_guess = guess
  end

  local caption = photo:getFormattedMetadata("caption")
  if caption and caption ~= "" then
    params.description = caption
  end

  if settings.inat_upload_location then
    local latitude, longitude = UploadCore.locationOf(photo)
    if latitude then
      params.latitude  = latitude
      params.longitude = longitude

      -- Only ever alongside coordinates. positional_accuracy on its own
      -- describes the precision of a location that was not sent, which
      -- iNaturalist has no use for and a reader of the observation would have
      -- to guess at.
      local accuracy = pluginField(photo, "inat_positional_accuracy")
      if accuracy and tonumber(accuracy) then
        params.positional_accuracy = tonumber(accuracy)
      end
    end
  end

  return params
end

--- Find or create the observation a photo belongs to.
--
-- @param seen      uuid -> observation id for observations already resolved in
--                  this run, so a second photo in the same group does not go
--                  back to the server or create a duplicate.
-- @param warnings  Collects things worth telling the user that are not bad
--                  enough to fail the photo.
-- @return observation id, uuid, error message
function UploadCore.resolveObservation(api, settings, photo, seen, warnings)
  local uuid = pluginField(photo, "inat_observation_uuid")

  if uuid then
    if seen[uuid] then
      return seen[uuid], uuid, nil
    end

    -- The photo has been uploaded before, or was grouped with one that had.
    -- The observation may since have been deleted on the website, which is a
    -- normal thing to find rather than an error: fall through and make a new
    -- one under the same UUID.
    local existing, lookupErr = api:findObservationByUuid(uuid)
    if lookupErr then
      return nil, nil, lookupErr
    end
    if existing then
      seen[uuid] = existing.id

      -- Re-uploading means something about the photo changed, and the details
      -- are half the point of the upload. Creating the observation once and
      -- never updating it meant an edited species guess was written to the
      -- catalog, uploaded, and then thrown away.
      local _, updateErr = api:updateObservation(
        existing.id, UploadCore.observationParamsFor(settings, photo, { update = true }))
      if updateErr then
        logger:warn("Could not update observation " .. tostring(existing.id)
          .. ": " .. tostring(updateErr))
        if warnings then
          warnings[#warnings + 1] = "Observation " .. tostring(existing.id)
            .. ": the photo uploaded, but its details could not be updated ("
            .. tostring(updateErr) .. ")"
        end
      end

      return existing.id, uuid, nil
    end
  end

  local params = UploadCore.observationParamsFor(settings, photo)
  if uuid then
    params.uuid = uuid
  end

  local created, createErr = api:createObservation(params)
  if not created then
    return nil, nil, createErr
  end

  local resolvedUuid = created.uuid or uuid
  if resolvedUuid then
    seen[resolvedUuid] = created.id
  end

  return created.id, resolvedUuid, nil
end

--------------------------------------------------------------------------------
-- Recording the result
--------------------------------------------------------------------------------

--- Write the observation link onto a set of photos.
--
-- Every photo in the group gets the same observation, which is what makes the
-- panel show the right thing whichever of them is selected next, and what stops
-- a second upload creating a duplicate.
function UploadCore.recordObservation(catalog, photos, observationId, uuid)
  local url = OBSERVATION_URL .. tostring(observationId)

  catalog:withWriteAccessDo("iNat upload", function()
    for _, photo in ipairs(photos) do
      photo:setPropertyForPlugin(_PLUGIN, "inat_observation_id", tostring(observationId))
      photo:setPropertyForPlugin(_PLUGIN, "inat_observation_url", url)
      if uuid then
        photo:setPropertyForPlugin(_PLUGIN, "inat_observation_uuid", tostring(uuid))
      end
    end
  end)

  return url
end

--- Clear every trace of the link between a photo and its observation.
--
-- Keywords are deliberately left alone. By the time somebody unlinks a photo
-- the keywords are part of their catalog -- they have been used in smart
-- collections and exports -- and taking them away is a bigger, less reversible
-- act than the button appears to offer. Nothing on iNaturalist is touched
-- either; this only forgets.
UploadCore.LINK_FIELDS = {
  "inat_observation_id",
  "inat_observation_uuid",
  "inat_observation_url",
  "inat_quality_grade",
  "inat_last_synced",
  "inat_taxon_id",
  "inat_taxon_name",
  "inat_common_name",
}

function UploadCore.unlink(catalog, photos)
  if not photos or #photos == 0 then return 0 end

  catalog:withWriteAccessDo("iNat unlink", function()
    for _, photo in ipairs(photos) do
      for _, field in ipairs(UploadCore.LINK_FIELDS) do
        photo:setPropertyForPlugin(_PLUGIN, field, "")
      end
    end
  end)

  logger:info("Unlinked " .. #photos .. " photo(s) from iNaturalist")
  return #photos
end

return UploadCore
