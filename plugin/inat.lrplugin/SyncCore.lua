--[[
  SyncCore.lua
  ------------
  The sync itself, as a module rather than a script.

  This used to live in SyncObservation.lua, which Lightroom runs top to bottom
  the moment its menu item is clicked. That makes it impossible to require:
  loading it *is* running it. The sync is now started from a button in the
  publish service's settings dialog and from a lightroom:// URL, so the logic
  has to be callable from more than one entry point and lives here.

  For each photo that has an inat_observation_id stored in custom metadata:

    1. Fetches the latest observation from iNaturalist (GET /observations/{id})
    2. Reads the community-determined taxon and its ancestor list
    3. Creates / reuses a hierarchical keyword tree under an "iNaturalist" root
    4. Applies the leaf keyword to the photo
    5. Updates the custom metadata fields (taxon name, common name, quality
       grade, observation UUID, last-synced timestamp)
--]]

local LrApplication   = import "LrApplication"
local LrDate          = import "LrDate"
local LrDialogs       = import "LrDialogs"
local LrProgressScope = import "LrProgressScope"

local InatAPI      = require "InatAPI"
local InatAuth     = require "InatAuth"
local logger       = require "Log"

local SyncCore = {}

--- What happened to one photo. Anything that is not FAILED is a normal
-- outcome, including UNIDENTIFIED: a freshly created observation has no
-- community taxon until somebody identifies it, which is most of them.
SyncCore.SYNCED       = "synced"
SyncCore.UNIDENTIFIED = "unidentified"
SyncCore.NO_ID        = "no-id"
SyncCore.FAILED       = "failed"

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

--- Bring one photo up to date with its observation.
-- @return status  One of the SyncCore.* codes.
-- @return err     A message, when status is FAILED.
function SyncCore.syncPhoto(catalog, photo, api)
  local obsId = photo:getPropertyForPlugin(_PLUGIN, "inat_observation_id")
  if not obsId or obsId == "" then
    return SyncCore.NO_ID, nil
  end

  -- Fetch observation from iNaturalist
  local obs, err = api:getObservation(tonumber(obsId))
  if not obs then
    return SyncCore.FAILED,
      "Failed to fetch observation " .. obsId .. ": " .. (err or "unknown")
  end

  -- Prefer community_taxon; fall back to taxon
  local taxon = obs.community_taxon or obs.taxon

  -- Fetch full taxon with ancestors if not already present
  if taxon and not taxon.ancestors then
    local fullTaxon, taxErr = api:getTaxon(taxon.id)
    if fullTaxon then
      taxon = fullTaxon
    else
      logger:warn("Could not fetch full taxon: " .. (taxErr or ""))
    end
  end

  -- Build and apply keyword hierarchy. createKeyword needs write access just
  -- as the metadata setters do, so it shares the one transaction.
  --
  -- Everything that is not the taxon is written either way. An observation
  -- nobody has identified yet is the normal state of one just published, and
  -- its UUID and URL are worth recording now: the UUID is what stops the next
  -- publish creating a duplicate.
  catalog:withWriteAccessDo("iNat sync", function()
    if taxon then
      local leafKw = ensureKeywordPath(catalog, buildKeywordPath(taxon))
      if leafKw then
        photo:addKeyword(leafKw)
      end

      photo:setPropertyForPlugin(_PLUGIN, "inat_taxon_id",
        tostring(taxon.id or ""))
      photo:setPropertyForPlugin(_PLUGIN, "inat_taxon_name",
        taxon.name or "")
      photo:setPropertyForPlugin(_PLUGIN, "inat_common_name",
        taxon.preferred_common_name or "")
    end

    photo:setPropertyForPlugin(_PLUGIN, "inat_quality_grade",
      obs.quality_grade or "")
    photo:setPropertyForPlugin(_PLUGIN, "inat_observation_url",
      "https://www.inaturalist.org/observations/" .. tostring(obsId))
    photo:setPropertyForPlugin(_PLUGIN, "inat_last_synced",
      LrDate.timeToW3CDate(LrDate.currentTime()))

    -- The UUID is how a photo finds its observation again at publish time, and
    -- a photo linked by pasting an observation ID has never had one. Storing
    -- it here is what makes an adopted observation behave like a published one
    -- rather than getting a duplicate on its next publish.
    if obs.uuid and obs.uuid ~= "" then
      photo:setPropertyForPlugin(_PLUGIN, "inat_observation_uuid", obs.uuid)
    end
  end)

  if not taxon then
    logger:info("Observation " .. obsId .. " has no taxon yet; recorded the rest")
    return SyncCore.UNIDENTIFIED, nil
  end

  logger:info("Synced photo → obs=" .. obsId .. " taxon=" .. (taxon.name or "?"))
  return SyncCore.SYNCED, nil
end

--------------------------------------------------------------------------------
-- Sync a list of photos
--------------------------------------------------------------------------------

--- Sync the given photos, reporting progress and a summary.
-- @param context  A live LrFunctionContext; the progress scope is tied to it,
--                 so it must belong to the task actually running this.
-- @param photos   The photos to sync.
-- @param options  quiet = true reports only when something actually went
--                 wrong. Used after a publish, where the run was not asked
--                 for directly and a modal saying "nothing to report" is just
--                 something else to dismiss.
function SyncCore.syncPhotos(context, photos, options)
  options = options or {}
  local catalog = LrApplication.activeCatalog()

  if not photos or #photos == 0 then
    if not options.quiet then
      LrDialogs.message("iNaturalist Sync", "No photos selected.", "warning")
    end
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

  local counts = {
    [SyncCore.SYNCED]       = 0,
    [SyncCore.UNIDENTIFIED] = 0,
    [SyncCore.NO_ID]        = 0,
  }
  local errors = {}

  for i, photo in ipairs(photos) do
    if progress:isCanceled() then break end

    progress:setCaption("Photo " .. i .. " of " .. #photos .. "…")
    progress:setPortionComplete(i - 1, #photos)

    local status, err = SyncCore.syncPhoto(catalog, photo, api)
    if status == SyncCore.FAILED then
      errors[#errors + 1] = err
      logger:warn("Sync error for photo " .. i .. ": " .. (err or "?"))
    else
      counts[status] = counts[status] + 1
    end
  end

  progress:done()

  if options.quiet and #errors == 0 then
    return
  end

  local msg = string.format(
    "Sync complete.\n\nSynced: %d\nNot identified yet: %d\nSkipped (no ID): %d\nErrors: %d",
    counts[SyncCore.SYNCED], counts[SyncCore.UNIDENTIFIED],
    counts[SyncCore.NO_ID], #errors
  )
  if #errors > 0 then
    msg = msg .. "\n\nFirst error:\n" .. errors[1]
  end
  LrDialogs.message("iNaturalist Sync", msg, #errors > 0 and "warning" or "info")
end

--------------------------------------------------------------------------------
-- Sync whatever is selected
--------------------------------------------------------------------------------

--- Sync the current target photos.
function SyncCore.syncTargetPhotos(context)
  SyncCore.syncPhotos(context, LrApplication.activeCatalog():getTargetPhotos())
end

return SyncCore
