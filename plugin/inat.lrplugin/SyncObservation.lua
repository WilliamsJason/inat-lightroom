--[[
  SyncObservation.lua
  -------------------
  Library menu item: "iNaturalist: Sync Selected Photos"

  For each selected photo that has an inat_observation_id stored in custom
  metadata, this script:

    1. Fetches the latest observation from iNaturalist (GET /observations/{id})
    2. Reads the community-determined taxon and its ancestor list
    3. Creates / reuses a hierarchical keyword tree under an "iNaturalist" root
    4. Applies the leaf keyword to the photo
    5. Updates the custom metadata fields (taxon name, common name, quality
       grade, last-synced timestamp)
--]]

local LrApplication    = import "LrApplication"
local LrDate           = import "LrDate"
local LrDialogs        = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrProgressScope  = import "LrProgressScope"

-- Deliberately does not require PluginInit: that file is a menu-item script
-- and opens the credentials dialog as soon as it is loaded.
local InatAPI  = require "InatAPI"
local InatAuth = require "InatAuth"
local logger   = require "Log"

--------------------------------------------------------------------------------
-- Build keyword hierarchy and return the leaf keyword object
--------------------------------------------------------------------------------

--- Create or reuse a nested keyword hierarchy.
-- @param catalog  LrCatalog
-- @param path     Ordered list of names, e.g. {"iNaturalist","Plantae",…,"Quercus robur"}
-- @return         Leaf LrKeyword object
local function ensureKeywordPath(catalog, path)
  local parentKw = nil
  local leafKw   = nil

  for i, name in ipairs(path) do
    local isLeaf = (i == #path)
    -- synonyms, includeOnExport, parent, skipIfExists
    local kw = catalog:createKeyword(name, {}, true, parentKw, true)
    parentKw = kw
    if isLeaf then leafKw = kw end
  end

  return leafKw
end

--- Build the keyword path from a taxon table.
-- Delegates to InatAPI so the plugin and the Python harness agree on shape.
local function buildKeywordPath(taxon)
  return InatAPI.buildKeywordPath(taxon, "iNaturalist")
end

--------------------------------------------------------------------------------
-- Sync a single photo
--------------------------------------------------------------------------------

local function syncPhoto(catalog, photo, api)
  local obsId = photo:getPropertyForPlugin(_PLUGIN, "inat_observation_id")
  if not obsId or obsId == "" then
    return false, "No iNaturalist observation ID stored for this photo."
  end

  -- Fetch observation from iNaturalist
  local obs, err = api:getObservation(tonumber(obsId))
  if not obs then
    return false, "Failed to fetch observation " .. obsId .. ": " .. (err or "unknown")
  end

  -- Prefer community_taxon; fall back to taxon
  local taxon = obs.community_taxon or obs.taxon
  if not taxon then
    return false, "Observation " .. obsId .. " has no taxon data yet."
  end

  -- Fetch full taxon with ancestors if not already present
  if not taxon.ancestors then
    local fullTaxon, taxErr = api:getTaxon(taxon.id)
    if fullTaxon then
      taxon = fullTaxon
    else
      logger:warn("Could not fetch full taxon: " .. (taxErr or ""))
    end
  end

  -- Build and apply keyword hierarchy. createKeyword needs write access just
  -- as the metadata setters do, so it shares the one transaction.
  local path = buildKeywordPath(taxon)

  catalog:withWriteAccessDo("iNat sync", function()
    local leafKw = ensureKeywordPath(catalog, path)
    if leafKw then
      photo:addKeyword(leafKw)
    end

    photo:setPropertyForPlugin(_PLUGIN, "inat_taxon_id",
      tostring(taxon.id or ""))
    photo:setPropertyForPlugin(_PLUGIN, "inat_taxon_name",
      taxon.name or "")
    photo:setPropertyForPlugin(_PLUGIN, "inat_common_name",
      taxon.preferred_common_name or "")
    photo:setPropertyForPlugin(_PLUGIN, "inat_quality_grade",
      obs.quality_grade or "")
    photo:setPropertyForPlugin(_PLUGIN, "inat_observation_url",
      "https://www.inaturalist.org/observations/" .. tostring(obsId))
    photo:setPropertyForPlugin(_PLUGIN, "inat_last_synced",
      LrDate.timeToW3CDate(LrDate.currentTime()))
  end)

  logger:info("Synced photo → obs=" .. obsId .. " taxon=" .. (taxon.name or "?"))
  return true, nil
end

--------------------------------------------------------------------------------
-- Entry point – runs when the menu item is selected
--------------------------------------------------------------------------------

-- The whole job is asynchronous: LrHttp yields, so the token fetch and every
-- request have to run in a task. postAsyncTaskWithContext is what pairs the two
-- correctly -- callWithContext would return the moment the task was queued,
-- leaving the progress scope holding a context that had already ended.
LrFunctionContext.postAsyncTaskWithContext("inat_sync", function(context)
  local catalog = LrApplication.activeCatalog()
  local photos  = catalog:getTargetPhotos()

  if not photos or #photos == 0 then
    LrDialogs.message("iNaturalist Sync", "No photos selected.", "warning")
    return
  end

  local token, authErr = InatAuth.getToken()
  if not token then
    LrDialogs.message("iNaturalist Sync", authErr or "Authentication failed.", "critical")
    return
  end

  local api = InatAPI.new(token)

  local progress = LrProgressScope {
    title           = "iNaturalist Sync",
    caption         = "Syncing…",
    functionContext = context,
  }
  progress:setCancelable(true)

  local synced  = 0
  local skipped = 0
  local errors  = {}

  for i, photo in ipairs(photos) do
    if progress:isCanceled() then break end

    progress:setCaption("Photo " .. i .. " of " .. #photos .. "…")
    progress:setPortionComplete(i - 1, #photos)

    local ok, err = syncPhoto(catalog, photo, api)
    if ok then
      synced = synced + 1
    elseif err and err:find("No iNaturalist observation ID") then
      skipped = skipped + 1
    else
      errors[#errors + 1] = err
      logger:warn("Sync error for photo " .. i .. ": " .. (err or "?"))
    end
  end

  progress:done()

  local msg = string.format(
    "Sync complete.\n\nSynced: %d\nSkipped (no ID): %d\nErrors: %d",
    synced, skipped, #errors
  )
  if #errors > 0 then
    msg = msg .. "\n\nFirst error:\n" .. errors[1]
  end
  LrDialogs.message("iNaturalist Sync", msg, #errors > 0 and "warning" or "info")
end)
