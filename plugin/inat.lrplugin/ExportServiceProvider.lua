--[[
  ExportServiceProvider.lua
  -------------------------
  Lightroom Classic "Export Service Provider" that uploads selected photos to
  iNaturalist as a new observation.

  This file is referenced from Info.lua as LrExportServiceProvider.
  Lightroom calls the functions defined in the returned table at specific
  points in the export workflow.

  Key export lifecycle hooks used here:
    startDialog      – build the export panel UI
    sectionsForTopOfDialog – return UI sections
    processRenderedPhotos – called after Lightroom has rendered all photos;
                            we upload them here
--]]

local LrApplication    = import "LrApplication"
local LrBinding        = import "LrBinding"
local LrDate           = import "LrDate"
local LrDialogs        = import "LrDialogs"
local LrErrors         = import "LrErrors"
local LrFunctionContext = import "LrFunctionContext"
local LrProgressScope  = import "LrProgressScope"
local LrTasks          = import "LrTasks"
local LrView           = import "LrView"

-- Deliberately does not require PluginInit: that file is a menu-item script
-- and opens the credentials dialog as soon as it is loaded.
local InatAPI  = require "InatAPI"
local InatAuth = require "InatAuth"
local logger   = require "Log"

--------------------------------------------------------------------------------
-- Export size defaults
-- iNaturalist displays at most 2048 px on the long edge.
--------------------------------------------------------------------------------
local INAT_MAX_PX   = 2048
local INAT_QUALITY  = 90

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

--- Ask iNaturalist for taxa matching a name and let the user pick one.
--
-- Writes the chosen taxon into inat_taxon_id / inat_taxon_name on the export
-- property table. Without this nothing ever sets inat_taxon_id and every
-- export stops at the "select a species" check.
local function showSpeciesPicker(propertyTable)
  LrTasks.startAsyncTask(function()
    local query = propertyTable.inat_species_guess

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
          propertyTable.inat_taxon_id   = tostring(taxon.id)
          propertyTable.inat_taxon_name = taxon.name or ""
          propertyTable.inat_species_guess = taxon.name or query
          logger:info("Selected taxon " .. tostring(taxon.id)
            .. " (" .. tostring(taxon.name) .. ")")
          return
        end
      end
    end)
  end)
end

--- Return the first photo in the export, or nil.
--
-- renditions() is a Lua iterator, so calling it directly yields the loop
-- index rather than a rendition. Driving it with a for loop and returning
-- immediately is the correct way to peek at the first entry.
local function firstExportPhoto(exportSession)
  -- photosToExport hands back LrPhoto objects and does not disturb the
  -- rendition queue, which is what we want when only reading metadata.
  local ok, photo = pcall(function()
    for _, candidate in exportSession:photosToExport() do
      return candidate
    end
    return nil
  end)
  if ok and photo then return photo end

  local fallbackOk, fallback = pcall(function()
    for _, rendition in exportSession:renditions() do
      return rendition.photo
    end
    return nil
  end)
  if fallbackOk then return fallback end

  return nil
end

--- Work out the observation date: the panel override, else the first photo.
local function observedOnFor(exportSession, override)
  if override and override ~= "" then
    return override
  end

  local photo = firstExportPhoto(exportSession)
  if not photo then return nil end

  local captured = photo:getRawMetadata("dateTimeOriginal")
  if not captured then return nil end

  -- Lightroom counts seconds from 2001-01-01, not the Unix epoch, so os.date
  -- would be 31 years out. LrDate knows the difference.
  return LrDate.timeToUserFormat(captured, "%Y-%m-%d")
end

--------------------------------------------------------------------------------
-- Export service provider table
--------------------------------------------------------------------------------

local provider = {}

-- Tell Lightroom what file format / size settings to enforce.
provider.exportPresetFields = {
  { key = "inat_taxon_id",     default = "" },
  { key = "inat_taxon_name",   default = "" },
  { key = "inat_species_guess",default = "" },
  { key = "inat_date",         default = "" },
  { key = "inat_latitude",     default = "" },
  { key = "inat_longitude",    default = "" },
  { key = "inat_description",  default = "" },
  { key = "inat_project_id",   default = "" },
  { key = "inat_geoprivacy",   default = "open" },
  { key = "inat_use_inat_crop",default = false },
}

-- Lock the file format and size to iNaturalist's preferred settings.
provider.canExportVideo = false
provider.hideSections   = { "fileNaming", "video" }

-- Called by Lightroom to ask the provider for a top-of-dialog section.
function provider.sectionsForTopOfDialog(f, propertyTable)
  return {
    {
      title = "iNaturalist Observation",
      -- Shown collapsed in the export panel, so make it the chosen taxon.
      synopsis = LrView.bind("inat_taxon_name"),

      -- Species search
      f:row {
        f:static_text { title = "Species:", width = 90, alignment = "right" },
        f:edit_field {
          value     = LrView.bind("inat_species_guess"),
          width     = 260,
          immediate = true,
        },
        f:push_button {
          title  = "Search",
          action = function()
            showSpeciesPicker(propertyTable)
          end,
        },
      },

      -- Confirmation of what will actually be uploaded. The search field is
      -- free text, so without this there is no way to tell whether a taxon was
      -- ever resolved.
      f:row {
        f:static_text { title = "Selected:", width = 90, alignment = "right" },
        f:static_text {
          title = LrView.bind {
            key = "inat_taxon_name",
            transform = function(value)
              if not value or value == "" then
                return "none yet - click Search"
              end
              return value
            end,
          },
          width = 320,
        },
      },

      -- Date override
      f:row {
        f:static_text { title = "Date:", width = 90, alignment = "right" },
        f:edit_field {
          value     = LrView.bind("inat_date"),
          width     = 120,
          immediate = true,
          placeholder_string = "YYYY-MM-DD (leave blank to use EXIF)",
        },
      },

      -- Location override
      f:row {
        f:static_text { title = "Latitude:", width = 90, alignment = "right" },
        f:edit_field { value = LrView.bind("inat_latitude"),  width = 100, immediate = true },
        f:static_text { title = "Longitude:", width = 70, alignment = "right" },
        f:edit_field { value = LrView.bind("inat_longitude"), width = 100, immediate = true },
      },

      -- Geoprivacy
      f:row {
        f:static_text { title = "Geoprivacy:", width = 90, alignment = "right" },
        f:popup_menu {
          value = LrView.bind("inat_geoprivacy"),
          items = {
            { title = "Open",    value = "open" },
            { title = "Obscured", value = "obscured" },
            { title = "Private", value = "private" },
          },
        },
      },

      -- Project
      f:row {
        f:static_text { title = "Project ID:", width = 90, alignment = "right" },
        f:edit_field {
          value     = LrView.bind("inat_project_id"),
          width     = 120,
          immediate = true,
          placeholder_string = "Optional",
        },
      },

      -- Description
      f:row {
        f:static_text { title = "Description:", width = 90, alignment = "right" },
        f:edit_field {
          value     = LrView.bind("inat_description"),
          width     = 300,
          height_in_lines = 3,
          immediate = true,
        },
      },

      -- iNat-specific crop toggle
      f:row {
        f:checkbox {
          title = "Use iNat-specific crop (stored in custom metadata)",
          value = LrView.bind("inat_use_inat_crop"),
        },
      },
    },
  }
end

-- Validate settings before export begins.
function provider.startDialog(propertyTable)
  -- Nothing to validate at dialog open; validation happens in updateExportSettings.
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
  exportSettings.LR_outputSharpeningOn  = false
  exportSettings.LR_exportColorSpace    = "sRGB"
end

-- Main upload routine – called after Lightroom renders all photos.
function provider.processRenderedPhotos(functionContext, exportContext)
  local exportSession  = exportContext.exportSession
  local exportSettings = exportContext.propertyTable
  local catalog        = LrApplication.activeCatalog()
  local nPhotos        = exportSession:countRenditions()

  local api, apiErr = requireAPI()
  if not api then
    LrErrors.throwUserError(apiErr)
  end

  -- Determine taxon
  local taxonId = tonumber(exportSettings.inat_taxon_id)
  if not taxonId or taxonId == 0 then
    LrErrors.throwUserError("Please search for and select a species before uploading.")
  end

  -- Determine observation date from settings or first photo EXIF
  local observedOn = observedOnFor(exportSession, exportSettings.inat_date)

  -- Create observation (all selected photos share one observation)
  local obsParams = {
    taxon_id           = taxonId,
    observed_on_string = observedOn or "",
    description        = exportSettings.inat_description or "",
    geoprivacy         = exportSettings.inat_geoprivacy or "open",
  }

  local latitude  = tonumber(exportSettings.inat_latitude or "")
  local longitude = tonumber(exportSettings.inat_longitude or "")
  if latitude and longitude then
    obsParams.latitude  = latitude
    obsParams.longitude = longitude
  end

  local progress = LrProgressScope {
    title    = "Uploading to iNaturalist…",
    caption  = "Creating observation…",
    functionContext = functionContext,
  }
  progress:setCancelable(false)

  local obsResponse, obsErr = api:createObservation(obsParams)
  if not obsResponse then
    LrErrors.throwUserError("Failed to create observation: " .. (obsErr or "unknown error"))
  end

  local observationId = obsResponse.id
  logger:info("Created observation id=" .. tostring(observationId))

  -- Upload each rendered photo
  local photoIndex = 0
  local uploaded   = 0
  local failures   = {}

  for _, rendition in exportContext:renditions() do
    photoIndex = photoIndex + 1
    progress:setCaption("Uploading photo " .. photoIndex .. " of " .. nPhotos .. "…")
    progress:setPortionComplete(photoIndex - 1, nPhotos)

    local success, pathOrMessage = rendition:waitForRender()
    if not success then
      logger:warn("Render failed: " .. tostring(pathOrMessage))
      failures[#failures + 1] = "Photo " .. photoIndex .. ": render failed"
    else
      local filePath = pathOrMessage

      -- If iNat crop is requested, apply the stored crop before uploading
      -- TODO: crop the rendered file using the stored inat_crop metadata value

      -- Verified upload: iNaturalist returns 200 before the image has been
      -- processed, so a successful response is not evidence the photo
      -- attached. This polls until it can confirm the attachment, and retries
      -- if it cannot.
      local _, photoErr = api:uploadPhotoVerified(observationId, filePath, {
        sleep = LrTasks.sleep,
        onEvent = function(message)
          logger:info("Photo " .. photoIndex .. ": " .. message)
        end,
      })

      if photoErr then
        logger:warn("Photo upload error: " .. tostring(photoErr))
        failures[#failures + 1] = "Photo " .. photoIndex .. ": " .. tostring(photoErr)
      else
        uploaded = uploaded + 1
      end

      -- Write observation ID back to the Lightroom photo
      local photo = rendition.photo
      catalog:withWriteAccessDo("iNat observation ID", function()
        photo:setPropertyForPlugin(_PLUGIN, "inat_observation_id", tostring(observationId))
        photo:setPropertyForPlugin(
          _PLUGIN, "inat_observation_url",
          "https://www.inaturalist.org/observations/" .. tostring(observationId)
        )
        photo:setPropertyForPlugin(_PLUGIN, "inat_taxon_id",   tostring(taxonId))
        photo:setPropertyForPlugin(_PLUGIN, "inat_taxon_name", exportSettings.inat_taxon_name or "")
        photo:setPropertyForPlugin(_PLUGIN, "inat_last_synced", os.date("!%Y-%m-%dT%H:%M:%SZ"))
      end)
    end
  end

  -- Optionally add to project
  local projectId = tonumber(exportSettings.inat_project_id)
  if projectId and projectId > 0 then
    progress:setCaption("Adding to project…")
    local _, projectErr = api:addToProject(observationId, projectId)
    if projectErr then
      logger:warn("Could not add to project: " .. tostring(projectErr))
      failures[#failures + 1] = "Project: " .. tostring(projectErr)
    end
  end

  progress:done()

  local url = "https://www.inaturalist.org/observations/" .. tostring(observationId)

  -- Report photo failures loudly. An observation with no photos is worse than
  -- no observation at all: it stays at casual grade and nobody can identify it.
  if #failures > 0 then
    LrDialogs.message(
      "iNaturalist Upload Incomplete",
      string.format(
        "Observation %s was created, but %d of %d photo(s) uploaded.\n\n%s\n\n%s",
        tostring(observationId), uploaded, nPhotos,
        table.concat(failures, "\n"), url),
      "warning"
    )
    return
  end

  LrDialogs.message(
    "iNaturalist Upload Complete",
    "Observation " .. tostring(observationId) .. " created with "
      .. uploaded .. " photo(s).\n\n" .. url,
    "info"
  )
end

-- Exposed for tests only. These are pure logic that would otherwise need a
-- running export to reach, and one of them was the source of a crash that only
-- appeared at upload time.
provider._internal = {
  firstExportPhoto = firstExportPhoto,
  observedOnFor    = observedOnFor,
}

return provider
