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

local LrBinding        = import "LrBinding"
local LrCatalog        = import "LrCatalog"
local LrDialogs        = import "LrDialogs"
local LrErrors         = import "LrErrors"
local LrExportContext  = import "LrExportContext"
local LrFunctionContext = import "LrFunctionContext"
local LrLogger         = import "LrLogger"
local LrPathUtils      = import "LrPathUtils"
local LrProgressScope  = import "LrProgressScope"
local LrStringUtils    = import "LrStringUtils"
local LrTasks          = import "LrTasks"
local LrView           = import "LrView"

local InatAPI    = require "InatAPI"
local PluginInit = require "PluginInit"

local logger = LrLogger("iNatLightroom")

--------------------------------------------------------------------------------
-- Export size defaults
-- iNaturalist displays at most 2048 px on the long edge.
--------------------------------------------------------------------------------
local INAT_MAX_PX   = 2048
local INAT_QUALITY  = 90

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Return an authenticated InatAPI instance, or show an error and return nil.
local function requireAPI()
  local creds = PluginInit.getStoredCredentials()
  if not creds then
    LrDialogs.message(
      "iNaturalist",
      "Credentials are not set up. Go to Library → Plug-in Extras → iNaturalist: Set Up Credentials.",
      "critical"
    )
    return nil
  end

  -- Obtain OAuth token via resource-owner password grant.
  -- In production this should be replaced with the authorization-code flow.
  local InatAuth = require "InatAuth"
  local token, err = InatAuth.getToken(creds)
  if not token then
    LrDialogs.message("iNaturalist", "Authentication failed: " .. (err or "unknown error"), "critical")
    return nil
  end

  return InatAPI.new(token)
end

--- Build a nested Lightroom keyword hierarchy and apply it to *photo*.
-- @param catalog  LrCatalog
-- @param photo    LrPhoto
-- @param path     ordered list of keyword names, e.g. {"iNaturalist","Plantae",…}
local function applyKeywordHierarchy(catalog, photo, path)
  local parentKw = nil
  for _, name in ipairs(path) do
    local kw = catalog:createKeyword(name, {}, true, parentKw, true)
    parentKw = kw
  end
  -- parentKw is now the leaf (species) keyword
  if parentKw then
    catalog:withWriteAccessDo("iNat keyword", function()
      photo:addKeyword(parentKw)
    end)
  end
end

--- Build the keyword path from a taxon dict (mirrors sync_observation.py).
local function buildKeywordPath(taxon)
  local ancestors = taxon.ancestors or {}
  local path = { "iNaturalist" }
  for _, a in ipairs(ancestors) do
    path[#path + 1] = a.name
  end
  path[#path + 1] = taxon.name
  return path
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
      synopsis = LrBinding.negativeOfKey("inat_taxon_name"),

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
            -- TODO: open species autocomplete picker dialog
            LrDialogs.message("Species search", "Autocomplete picker – coming soon.", "info")
          end,
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
  local catalog        = LrCatalog.activeCatalog()
  local nPhotos        = exportSession:countRenditions()

  local api = requireAPI()
  if not api then
    LrErrors.throwUserError("Cannot upload: credentials not configured.")
  end

  -- Determine taxon
  local taxonId = tonumber(exportSettings.inat_taxon_id)
  if not taxonId or taxonId == 0 then
    LrErrors.throwUserError("Please search for and select a species before uploading.")
  end

  -- Determine observation date from settings or first photo EXIF
  local observedOn = exportSettings.inat_date
  if not observedOn or observedOn == "" then
    local firstRendition = exportSession:renditions()()
    if firstRendition then
      local dt = firstRendition.photo:getRawMetadata("dateTimeOriginal")
      if dt then
        observedOn = os.date("%Y-%m-%d", dt)
      end
    end
  end

  -- Create observation (all selected photos share one observation)
  local obsParams = {
    taxon_id           = taxonId,
    observed_on_string = observedOn or "",
    description        = exportSettings.inat_description or "",
    geoprivacy         = exportSettings.inat_geoprivacy or "open",
  }
  if exportSettings.inat_latitude  ~= "" then obsParams.latitude  = tonumber(exportSettings.inat_latitude) end
  if exportSettings.inat_longitude ~= "" then obsParams.longitude = tonumber(exportSettings.inat_longitude) end

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
  for _, rendition in exportSession:renditions() do
    photoIndex = photoIndex + 1
    progress:setCaption("Uploading photo " .. photoIndex .. " of " .. nPhotos .. "…")
    progress:setPortionComplete(photoIndex - 1, nPhotos)

    local success, pathOrMessage = rendition:waitForRender()
    if not success then
      logger:warn("Render failed: " .. tostring(pathOrMessage))
    else
      local filePath = pathOrMessage

      -- If iNat crop is requested, apply the stored crop before uploading
      -- TODO: crop the rendered file using the stored inat_crop metadata value

      local _, photoErr = api:uploadPhoto(observationId, filePath)
      if photoErr then
        logger:warn("Photo upload error: " .. photoErr)
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
    api:addToProject(observationId, projectId)
  end

  progress:done()

  LrDialogs.message(
    "iNaturalist Upload Complete",
    "Observation " .. tostring(observationId) .. " created with " .. nPhotos .. " photo(s).\n\n"
    .. "https://www.inaturalist.org/observations/" .. tostring(observationId),
    "info"
  )
end

return provider
