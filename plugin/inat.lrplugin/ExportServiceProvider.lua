--[[
  ExportServiceProvider.lua
  -------------------------
  Lightroom Classic publish service that uploads photos to iNaturalist as
  observations, and keeps track of which photos are already up there.

  This file is referenced from Info.lua as LrExportServiceProvider. A publish
  service is not a separate manifest key: it is an export service provider that
  sets supportsIncrementalPublish, which is how Adobe's own bundled
  Flickr.lrplugin does it. "only" means this service publishes and cannot be
  used as a plain export target.

  What that buys, and why it replaced the export target and the clickable rows
  in the Metadata panel:

    * a permanent "iNaturalist" entry in the Library's left panel, with a
      Publish button, which is the place to act on photos that the Metadata
      panel could never be
    * Lightroom itself tracking New / Modified / Published, instead of this
      plugin inferring it from a last-synced timestamp
    * metadataThatTriggersRepublish, so editing a caption or a species guess
      marks the photo for re-upload without anyone remembering to
    * recordPublishedPhotoId / recordPublishedPhotoUrl, giving every uploaded
      photo a handle we can later replace or detach

  The one thing publishing takes away is the export batch. An export uploaded
  everything selected as a single observation; a publish service hands photos
  over one at a time and re-publishes them individually, so "these frames are
  one observation" has to be recorded on the photos themselves. That is what
  inat_observation_uuid is for: photos sharing a UUID publish into the same
  observation, and a photo without one gets a new observation whose UUID
  iNaturalist supplies and we then store.

  Key lifecycle hooks used here:
    sectionsForTopOfDialog  – the service settings UI
    updateExportSettings    – force iNaturalist's size and format limits
    processRenderedPhotos   – create observations and upload the renders
    deletePhotosFromPublishedCollection – remove them again
--]]

local LrApplication    = import "LrApplication"
local LrBinding        = import "LrBinding"
local LrDate           = import "LrDate"
local LrDialogs        = import "LrDialogs"
local LrErrors         = import "LrErrors"
local LrFunctionContext = import "LrFunctionContext"
local LrHttp           = import "LrHttp"
local LrTasks          = import "LrTasks"
local LrView           = import "LrView"

local InatAPI  = require "InatAPI"
local InatAuth = require "InatAuth"
local SyncCore = require "SyncCore"
local logger   = require "Log"

--------------------------------------------------------------------------------
-- Export size defaults
-- iNaturalist displays at most 2048 px on the long edge.
--------------------------------------------------------------------------------
local INAT_MAX_PX   = 2048
local INAT_QUALITY  = 90

local OBSERVATION_URL = "https://www.inaturalist.org/observations/"

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Return an authenticated InatAPI instance, or nil plus an error message.
-- Must be called from inside an async task.
local function requireAPI()
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

--- The observation date for one photo, from its own capture time.
--
-- Lightroom counts seconds from 2001-01-01, not the Unix epoch, so os.date
-- would be 31 years out. LrDate knows the difference.
local function observedOnFor(photo)
  local captured = photo:getRawMetadata("dateTimeOriginal")
  if not captured then return nil end
  return LrDate.timeToUserFormat(captured, "%Y-%m-%d")
end

--- Build the observation body for one photo.
--
-- Everything specific to the observation comes off the photo, because in a
-- publish service there is no batch to hang it on: the same settings are used
-- for every photo in the collection and for every future re-publish. Only the
-- things that really are per-connection preferences -- geoprivacy, the project
-- to file into, a fallback taxon -- come from the service settings.
local function observationParamsFor(settings, photo, options)
  options = options or {}

  local params = {
    geoprivacy = settings.inat_geoprivacy or "open",
  }

  local observedOn = observedOnFor(photo)
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
    local gps = photo:getRawMetadata("gps")
    if gps and gps.latitude and gps.longitude then
      params.latitude  = gps.latitude
      params.longitude = gps.longitude
    end
  end

  -- The connection's default taxon is a fallback for photos that say nothing
  -- about themselves. It is not sent when the photo has its own species guess:
  -- iNaturalist prefers taxon_id, so sending both would quietly discard what
  -- the user actually typed.
  --
  -- It is never sent on an update at all. By then the observation may carry
  -- identifications, and re-asserting a default from a Lightroom connection
  -- would argue with them on every republish.
  if not options.update and not params.species_guess then
    local taxonId = tonumber(settings.inat_default_taxon_id or "")
    if taxonId and taxonId > 0 then
      params.taxon_id = taxonId
    end
  end

  return params
end

--- Find or create the observation a photo belongs to.
--
-- @param seen      uuid -> observation id for observations already resolved in
--                  this publish run, so a second photo in the same group does
--                  not go back to the server or create a duplicate.
-- @param warnings  Collects things worth telling the user that are not bad
--                  enough to fail the photo.
-- @return observation id, uuid, error message
local function resolveObservation(api, settings, photo, seen, warnings)
  local uuid = pluginField(photo, "inat_observation_uuid")

  if uuid then
    if seen[uuid] then
      return seen[uuid], uuid, nil
    end

    -- The photo has been published before, or was grouped with one that had.
    -- The observation may since have been deleted on the website, which is a
    -- normal thing to find rather than an error: fall through and make a new
    -- one under the same UUID.
    local existing, lookupErr = api:findObservationByUuid(uuid)
    if lookupErr then
      return nil, nil, lookupErr
    end
    if existing then
      seen[uuid] = existing.id

      -- A republish means the photo's data has changed -- that is the only
      -- thing that puts it back into Modified. Creating the observation once
      -- and never updating it meant an edited species guess was written to
      -- the catalog, marked for republish, uploaded, and then thrown away.
      local _, updateErr = api:updateObservation(
        existing.id, observationParamsFor(settings, photo, { update = true }))
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

  local params = observationParamsFor(settings, photo)
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

--- Ask iNaturalist for taxa matching a name and let the user pick one.
--
-- Writes the chosen taxon into the service's default taxon. This is a fallback
-- for photos with no species guess of their own, not a per-photo choice: the
-- settings dialog belongs to the connection and is not open when photos are
-- published.
local function showSpeciesPicker(propertyTable)
  LrTasks.startAsyncTask(function()
    local query = propertyTable.inat_species_search

    if not query or query == "" then
      LrDialogs.message("iNaturalist",
        "Type part of a species name first, then click Search.", "info")
      return
    end

    local api, apiErr = requireAPI()
    if not api then
      LrDialogs.message("iNaturalist", apiErr, "critical")
      return
    end

    local taxa, err = api:autocompleteTaxon(query)
    if not taxa then
      LrDialogs.message("iNaturalist", "Search failed:\n\n" .. tostring(err), "critical")
      return
    end

    if #taxa == 0 then
      LrDialogs.message("iNaturalist", "Nothing matched \"" .. query .. "\".", "info")
      return
    end

    LrFunctionContext.callWithContext("inat_species_picker", function(context)
      local f     = LrView.osFactory()
      local props = LrBinding.makePropertyTable(context)

      local items = {}
      for _, taxon in ipairs(taxa) do
        local label = taxon.name or "?"
        if taxon.preferred_common_name then
          label = taxon.preferred_common_name .. " (" .. label .. ")"
        end
        if taxon.rank then
          label = label .. "  [" .. taxon.rank .. "]"
        end
        items[#items + 1] = { title = label, value = taxon.id }
      end

      props.chosen = items[1].value

      local result = LrDialogs.presentModalDialog {
        title    = "Choose a Taxon",
        contents = f:column {
          bind_to_object = props,
          spacing = f:label_spacing(),
          f:static_text { title = #taxa .. " match(es) for \"" .. query .. "\":" },
          f:popup_menu {
            value = LrView.bind("chosen"),
            items = items,
            width = 420,
          },
        },
      }

      if result ~= "ok" then return end

      for _, taxon in ipairs(taxa) do
        if taxon.id == props.chosen then
          propertyTable.inat_default_taxon_id   = tostring(taxon.id)
          propertyTable.inat_default_taxon_name = taxon.name or ""
          propertyTable.inat_species_search     = taxon.name or query
          logger:info("Default taxon set to " .. tostring(taxon.id)
            .. " (" .. tostring(taxon.name) .. ")")
          return
        end
      end
    end)
  end)
end

--------------------------------------------------------------------------------
-- Publish service provider table
--------------------------------------------------------------------------------

local provider = {}

-- Publish only. There is no useful "export to iNaturalist" that is not a
-- publish: the whole point is the link between the catalog photo and the
-- observation, and an export that forgot it would create duplicates on every
-- run.
provider.supportsIncrementalPublish = "only"

-- Connection settings. These belong to the publish service as a whole; per
-- observation data lives on the photos.
provider.exportPresetFields = {
  { key = "inat_default_taxon_id",   default = "" },
  { key = "inat_default_taxon_name", default = "" },
  { key = "inat_species_search",     default = "" },
  { key = "inat_project_id",         default = "" },
  { key = "inat_geoprivacy",         default = "open" },
  { key = "inat_upload_location",    default = true },
  { key = "inat_sync_on_publish",    default = true },
}

-- A publish service has nowhere to put files and no say in their names.
provider.hideSections        = { "exportLocation", "fileNaming", "video" }
provider.allowFileFormats    = { "JPEG" }
provider.allowColorSpaces    = { "sRGB" }
provider.hidePrintResolution = true
provider.canExportVideo      = false

provider.titleForPublishedCollection     = "Observations"
provider.titleForGoToPublishedCollection = "Show my observations on iNaturalist"

-- One collection, called Observations, and no way to add more. iNaturalist has
-- no album or set concept for a plugin to mirror, so extra collections would
-- be folders that exist only in Lightroom while claiming to be published
-- somewhere.
function provider.getCollectionBehaviorInfo(_publishSettings)
  return {
    defaultCollectionName         = "Observations",
    defaultCollectionCanBeDeleted = false,
    canAddCollection              = false,
    maxCollectionSetDepth         = 0,
  }
end

-- What counts as changing the photo enough to warrant re-uploading it.
--
-- default = false matters: without it every field in the catalog triggers a
-- republish and the whole collection sits permanently in Modified.
function provider.metadataThatTriggersRepublish(_publishSettings)
  return {
    default     = false,
    caption     = true,
    dateCreated = true,
    gps         = true,
    ["com.github.inat-lightroom.inat_species_guess"] = true,
    ["com.github.inat-lightroom.inat_crop"]          = true,
  }
end

function provider.goToPublishedCollection(_publishSettings)
  LrTasks.startAsyncTask(function()
    local url = "https://www.inaturalist.org/observations"

    -- Land on the user's own observations when we know who they are; the bare
    -- URL is everybody's observations, which is not what the menu item says.
    local token = InatAuth.getToken()
    if token then
      local user = InatAuth.whoami(token)
      if user and user.login then
        url = url .. "?user_id=" .. tostring(user.login)
      end
    end

    LrHttp.openUrlInBrowser(url)
  end)
end

-- Called by Lightroom to ask the provider for a top-of-dialog section.
function provider.sectionsForTopOfDialog(f, propertyTable)
  return {
    {
      title = "iNaturalist",
      synopsis = LrView.bind {
        key = "inat_default_taxon_name",
        transform = function(value)
          if not value or value == "" then return "No default taxon" end
          return "Default: " .. value
        end,
      },

      f:static_text {
        title = "Species, date, location and description come from each photo.\n"
          .. "Use the Species Guess field in the Metadata panel's iNaturalist\n"
          .. "preset to say what a photo is.",
        height_in_lines = 3,
      },

      f:separator { fill_horizontal = 1 },

      -- Fallback taxon search
      f:row {
        f:static_text { title = "Default taxon:", width = 100, alignment = "right" },
        f:edit_field {
          value     = LrView.bind("inat_species_search"),
          width     = 240,
          immediate = true,
          placeholder_string = "Optional",
        },
        f:push_button {
          title  = "Search",
          action = function()
            showSpeciesPicker(propertyTable)
          end,
        },
      },

      -- Confirmation of what was actually resolved. The search field is free
      -- text, so without this there is no way to tell whether a taxon was ever
      -- chosen from the results.
      f:row {
        f:static_text { title = "Selected:", width = 100, alignment = "right" },
        f:static_text {
          title = LrView.bind {
            key = "inat_default_taxon_name",
            transform = function(value)
              if not value or value == "" then
                return "none - photos will be uploaded as Unknown"
              end
              return value
            end,
          },
          width = 320,
        },
      },

      f:row {
        f:static_text { title = "Geoprivacy:", width = 100, alignment = "right" },
        f:popup_menu {
          value = LrView.bind("inat_geoprivacy"),
          items = {
            { title = "Open",     value = "open" },
            { title = "Obscured", value = "obscured" },
            { title = "Private",  value = "private" },
          },
        },
      },

      f:row {
        f:static_text { title = "Project ID:", width = 100, alignment = "right" },
        f:edit_field {
          value     = LrView.bind("inat_project_id"),
          width     = 120,
          immediate = true,
          placeholder_string = "Optional",
        },
      },

      f:row {
        f:checkbox {
          title = "Upload the photo's GPS location",
          value = LrView.bind("inat_upload_location"),
        },
      },

      f:row {
        f:checkbox {
          title = "Sync taxa back from iNaturalist after publishing",
          value = LrView.bind("inat_sync_on_publish"),
        },
      },

      f:separator { fill_horizontal = 1 },

      -- Sync used to be a clickable row in the Metadata panel, faked out of a
      -- url field. This is what it should always have been: a button, in a
      -- dialog that can run code, with a label we chose.
      f:row {
        f:push_button {
          title  = "Sync selected photos now",
          action = function()
            LrFunctionContext.postAsyncTaskWithContext("inat_settings_sync",
              function(context)
                SyncCore.syncTargetPhotos(context)
              end)
          end,
        },
        f:static_text {
          title = "Fetches the current taxon and keywords for whatever\n"
            .. "is selected in the Library.",
          height_in_lines = 2,
        },
      },
    },
  }
end

function provider.startDialog(_propertyTable)
  -- Nothing to validate at dialog open; credentials are checked when a publish
  -- actually starts, so someone who has not set them up yet can still get as
  -- far as choosing their preferences.
end

function provider.updateExportSettings(exportSettings)
  -- Enforce resolution / quality for iNaturalist uploads.
  exportSettings.LR_format              = "JPEG"
  exportSettings.LR_jpeg_quality        = INAT_QUALITY / 100
  exportSettings.LR_size_doConstrain    = true
  exportSettings.LR_size_maxHeight      = INAT_MAX_PX
  exportSettings.LR_size_maxWidth       = INAT_MAX_PX
  exportSettings.LR_size_resizeType     = "longEdge"
  exportSettings.LR_size_units          = "pixels"
  exportSettings.LR_size_doNotEnlarge   = true
  exportSettings.LR_outputSharpeningOn  = false
  exportSettings.LR_exportColorSpace    = "sRGB"
end

--------------------------------------------------------------------------------
-- Publishing
--------------------------------------------------------------------------------

--- Upload one rendered file and record the result against the rendition.
-- @return true on success, or false plus a message
local function publishRendition(api, settings, catalog, rendition, filePath, seen, index, warnings)
  local photo = rendition.photo

  local observationId, uuid, obsErr = resolveObservation(api, settings, photo, seen, warnings)
  if not observationId then
    return false, "could not create the observation: " .. tostring(obsErr)
  end

  -- iNaturalist returns 200 before the image has been processed, so a
  -- successful response is not evidence the photo attached. This polls until
  -- it can confirm the attachment, and retries if it cannot.
  local response, photoErr = api:uploadPhotoVerified(observationId, filePath, {
    sleep = LrTasks.sleep,
    onEvent = function(message)
      logger:info("Photo " .. index .. ": " .. message)
    end,
  })

  if photoErr then
    return false, tostring(photoErr)
  end

  local publishedId = InatAPI.observationPhotoId(response)
  if not publishedId then
    -- Lightroom needs a remote ID per photo or it will not consider it
    -- published. A synthetic one keeps that state honest; it only costs the
    -- ability to detach this particular photo later, which is better than an
    -- uploaded photo showing as New forever and being uploaded again.
    publishedId = "observation:" .. tostring(observationId) .. "/" .. tostring(index)
    logger:warn("No observation_photo ID in the upload response; recorded "
      .. publishedId)
  end

  -- Replacing rather than adding: a re-publish has just uploaded a fresh copy,
  -- so the previous one is now a duplicate on the same observation. Deleted
  -- after the new upload verified, never before, so a failure here can never
  -- leave the observation with no photos at all.
  local previousPhotoId = rendition.publishedPhotoId
  if previousPhotoId and tostring(previousPhotoId) ~= publishedId then
    local _, deleteErr = api:deleteObservationPhoto(previousPhotoId)
    if deleteErr then
      logger:warn("Could not remove the previous copy of photo " .. index
        .. " (" .. tostring(previousPhotoId) .. "): " .. tostring(deleteErr))
    end
  end

  local url = OBSERVATION_URL .. tostring(observationId)

  rendition:recordPublishedPhotoId(publishedId)
  rendition:recordPublishedPhotoUrl(url)

  -- withPrivateWriteAccessDo, not withWriteAccessDo: this runs inside an
  -- export task, where the ordinary catalog write can block waiting on a
  -- transaction the export itself is holding.
  catalog:withPrivateWriteAccessDo(function()
    photo:setPropertyForPlugin(_PLUGIN, "inat_observation_id", tostring(observationId))
    photo:setPropertyForPlugin(_PLUGIN, "inat_observation_url", url)
    if uuid then
      photo:setPropertyForPlugin(_PLUGIN, "inat_observation_uuid", tostring(uuid))
    end
  end)

  return true, nil
end

function provider.processRenderedPhotos(_functionContext, exportContext)
  local exportSession = exportContext.exportSession
  local settings      = exportContext.propertyTable
  local catalog       = LrApplication.activeCatalog()
  local nPhotos       = exportSession:countRenditions()

  local api, apiErr = requireAPI()
  if not api then
    LrErrors.throwUserError(apiErr)
  end

  local progress = exportContext:configureProgress {
    title = nPhotos == 1
      and "Publishing one photo to iNaturalist"
      or string.format("Publishing %d photos to iNaturalist", nPhotos),
  }

  -- uuid -> observation id, so photos grouped into one observation resolve it
  -- once rather than once each.
  local seen      = {}
  local published = {}
  local failures  = {}
  local warnings  = {}
  local index     = 0

  for _, rendition in exportContext:renditions { stopIfCanceled = true } do
    index = index + 1
    progress:setPortionComplete(index - 1, nPhotos)

    if not rendition.wasSkipped then
      local rendered, pathOrMessage = rendition:waitForRender()

      if not rendered then
        logger:warn("Render failed: " .. tostring(pathOrMessage))
        failures[#failures + 1] = "Photo " .. index .. ": render failed"
        rendition:uploadFailed("Lightroom could not render this photo")
      else
        local ok, message = publishRendition(
          api, settings, catalog, rendition, pathOrMessage, seen, index, warnings)

        if ok then
          published[#published + 1] = rendition.photo
        else
          logger:warn("Publish failed for photo " .. index .. ": " .. tostring(message))
          failures[#failures + 1] = "Photo " .. index .. ": " .. tostring(message)
          -- Tell Lightroom, or the photo is marked Published despite never
          -- having reached iNaturalist and no later publish will retry it.
          rendition:uploadFailed(tostring(message))
        end
      end
    end
  end

  -- Optionally add every observation touched to a project.
  local projectId = tonumber(settings.inat_project_id or "")
  if projectId and projectId > 0 then
    progress:setCaption("Adding to project…")
    for _, observationId in pairs(seen) do
      local _, projectErr = api:addToProject(observationId, projectId)
      if projectErr then
        logger:warn("Could not add observation " .. tostring(observationId)
          .. " to project: " .. tostring(projectErr))
        failures[#failures + 1] = "Project: " .. tostring(projectErr)
      end
    end
  end

  progress:done()

  -- Report failures loudly. An observation with no photos is worse than no
  -- observation at all: it stays at casual grade and nobody can identify it.
  -- Report failures loudly. An observation with no photos is worse than no
  -- observation at all: it stays at casual grade and nobody can identify it.
  --
  -- Warnings are reported too. They mean the image is safely on iNaturalist
  -- but something the user typed did not follow it, which nothing else on
  -- screen would reveal.
  if #failures > 0 or #warnings > 0 then
    local parts = {}
    if #failures > 0 then
      parts[#parts + 1] = string.format("%d of %d photo(s) published.\n\n%s",
        #published, nPhotos, table.concat(failures, "\n"))
    end
    if #warnings > 0 then
      parts[#parts + 1] = table.concat(warnings, "\n")
    end

    LrDialogs.message(
      #failures > 0 and "iNaturalist Publish Incomplete" or "iNaturalist Publish",
      table.concat(parts, "\n\n"),
      "warning")
  end

  -- Sync the photos that were just published, not whatever happens to be
  -- selected in the Library -- after a publish those are rarely the same set,
  -- and the Publish button is nowhere near the filmstrip.
  if settings.inat_sync_on_publish and #published > 0 then
    local justPublished = published
    LrFunctionContext.postAsyncTaskWithContext("inat_sync_after_publish",
      function(context)
        SyncCore.syncPhotos(context, justPublished, { quiet = true })
      end)
  end
end

--------------------------------------------------------------------------------
-- Removing photos again
--------------------------------------------------------------------------------

--- Map the published photo IDs Lightroom is deleting to their observations.
--
-- Lightroom hands over remote photo IDs and nothing else, but whether an
-- observation should also go depends on how many of *its* photos are being
-- removed -- so the catalog has to be asked which Lightroom photo each ID
-- belongs to. Returns observation id -> list of remote photo ids.
local function observationsForPublishedPhotoIds(catalog, localCollectionId, photoIds)
  local wanted = {}
  for _, photoId in ipairs(photoIds) do
    wanted[tostring(photoId)] = true
  end

  local byObservation = {}

  local collection = catalog:getPublishedCollectionByLocalIdentifier(localCollectionId)
  if not collection then return byObservation end

  for _, publishedPhoto in ipairs(collection:getPublishedPhotos()) do
    local remoteId = publishedPhoto:getRemoteId()
    if remoteId and wanted[tostring(remoteId)] then
      local observationId = publishedPhoto:getPhoto()
        :getPropertyForPlugin(_PLUGIN, "inat_observation_id")

      if observationId and observationId ~= "" then
        local list = byObservation[observationId] or {}
        list[#list + 1] = tostring(remoteId)
        byObservation[observationId] = list
      end
    end
  end

  return byObservation
end

--- Remove photos from iNaturalist when they are deleted from the collection.
--
-- Detaching the photo is the easy half. The other half is that an observation
-- whose last photo has gone is not neutral: iNaturalist keeps it, it drops to
-- casual grade, and nobody can ever identify it. So when every remaining photo
-- of an observation is being removed, the observation goes too.
function provider.deletePhotosFromPublishedCollection(
    _publishSettings, photoIds, deletedCallback, localCollectionId)

  local api, apiErr = requireAPI()
  if not api then
    LrErrors.throwUserError(apiErr)
  end

  local catalog = LrApplication.activeCatalog()

  local byObservation = {}
  local mapped, result = LrTasks.pcall(observationsForPublishedPhotoIds,
    catalog, localCollectionId, photoIds)
  if mapped then
    byObservation = result
  else
    -- Worth continuing without: the photos still get detached, we just cannot
    -- tell whether any observation was left empty.
    logger:warn("Could not map published photos to observations: " .. tostring(result))
  end

  local emptied = {}
  for observationId, removing in pairs(byObservation) do
    local attached = api:countAttachedPhotos(observationId)
    if attached and attached > 0 and attached <= #removing then
      emptied[observationId] = removing
    end
  end

  local handled = {}

  -- Delete whole observations first. iNaturalist removes their photos with
  -- them, so detaching those individually afterwards would only produce 404s.
  for observationId, removing in pairs(emptied) do
    local _, deleteErr = api:deleteObservation(observationId)
    if deleteErr then
      logger:warn("Could not delete observation " .. tostring(observationId)
        .. ": " .. tostring(deleteErr))
    else
      logger:info("Deleted observation " .. tostring(observationId)
        .. " along with its last " .. #removing .. " photo(s)")
      for _, remoteId in ipairs(removing) do
        handled[remoteId] = true
        deletedCallback(remoteId)
      end
    end
  end

  for _, photoId in ipairs(photoIds) do
    local remoteId = tostring(photoId)
    if not handled[remoteId] then
      local _, deleteErr = api:deleteObservationPhoto(remoteId)
      if deleteErr then
        LrErrors.throwUserError("Could not remove photo " .. remoteId
          .. " from iNaturalist: " .. tostring(deleteErr))
      end
      deletedCallback(photoId)
    end
  end
end

-- Exposed for tests only. These are the pure logic that would otherwise need a
-- running publish to reach, and one of them was the source of a crash that
-- only appeared at upload time.
provider._internal = {
  observedOnFor        = observedOnFor,
  observationParamsFor = observationParamsFor,
  resolveObservation   = resolveObservation,
  publishRendition     = publishRendition,
  observationsForPublishedPhotoIds = observationsForPublishedPhotoIds,
}

return provider
