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
local Jobs         = require "Jobs"
local UploadCore   = require "UploadCore"
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

--- The existing keyword of this name among a parent's children.
--
-- The fallback for createKeyword handing back nil. `returnExisting` is meant
-- to make that impossible, and mostly does; when it does not, the keyword we
-- were about to create is usually already sitting there, and finding it is the
-- difference between the hierarchy continuing and the lineage being refused
-- for good.
--
-- @param parentKw  nil to search the top level of the catalog
local function findChild(catalog, parentKw, name)
  local siblings
  if parentKw then
    siblings = parentKw:getChildren()
  else
    siblings = catalog:getKeywords()
  end

  for _, kw in ipairs(siblings or {}) do
    if kw:getName() == name then return kw end
  end
  return nil
end

--- Create or reuse a nested keyword hierarchy.
--
-- Gives up on the whole path the moment a level cannot be resolved, rather
-- than carrying on with a nil parent. That distinction is not academic: a nil
-- parent means "top of the catalog", so a path that broke at, say, Apocrita
-- carried on creating Aculeata, Apoidea, Apidae and the species as brand new
-- **top-level** keywords, beside the user's own vocabulary and outside the
-- iNaturalist tree entirely.
--
-- Worse, it compounded. The stranded Aculeata is a second keyword of that
-- name, which made the next run's createKeyword refuse one level deeper, which
-- stranded Apoidea, and so on down. A single refusal turned into dozens of
-- fragments. Deleting the iNaturalist keyword does not clean any of it up --
-- they were never inside it -- and the SDK cannot delete a keyword at all, so
-- it falls to the user by hand.
--
-- @param catalog  LrCatalog
-- @param path     Ordered list of names, e.g. {"iNaturalist","Plantae",…,"Quercus robur"}
-- @return         Leaf LrKeyword object, or nil when any level could not be resolved
local function ensureKeywordPath(catalog, path)
  local parentKw = nil
  local leafKw   = nil

  for i, name in ipairs(path) do
    local isLeaf = (i == #path)

    if type(name) ~= "string" or name == "" then
      logger:warn(string.format(
        "Keyword level %d of %d is not a usable name (%s); wrote no keyword",
        i, #path, tostring(name)))
      return nil
    end

    -- synonyms, includeOnExport, parent, skipIfExists
    local kw = catalog:createKeyword(name, {}, true, parentKw, true)
    if not kw then
      kw = findChild(catalog, parentKw, name)
      if kw then
        logger:info(string.format(
          "Lightroom refused to create keyword %q; used the one already there",
          name))
      end
    end

    if not kw then
      logger:warn(string.format(
        "Could not create or find keyword %q under %s (level %d of %d); "
        .. "wrote no keyword rather than stranding the rest at the top level",
        name, i > 1 and string.format("%q", tostring(path[i - 1]))
          or "the catalog root", i, #path))
      return nil
    end

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

--- Fill in a taxon's ancestors if it arrived without them.
--
-- MUST be called from inside a task: it may make an HTTP call.
--
-- A taxon from an observation or a vision result carries a name and a rank but
-- usually no lineage, and the lineage is the whole keyword hierarchy.
--
-- Returns the original taxon when the fetch fails, and callers must check
-- `hasLineage` before building a keyword from it. It used to say here that a
-- leaf keyword under the wrong parent beats no keyword at all, and that was
-- wrong: one run that hit the rate limit filed 346 species directly under
-- "iNaturalist" instead of under their lineage. A keyword written into
-- someone's catalog is much harder to take back than one not written yet --
-- nothing written is a re-run, something wrong written is a cleanup.
function SyncCore.withAncestors(api, taxon)
  if not taxon or taxon.ancestors then return taxon end
  -- Nothing to look it up by. Asking anyway spends a request on /taxa/nil.
  if taxon.id == nil then return taxon end

  local full, err = api:getTaxon(taxon.id)
  if full then return full end

  logger:warn("Could not fetch full taxon: " .. (err or "unknown"))
  return taxon
end

--- True when this taxon knows its own lineage.
--
-- A kingdom legitimately has an empty ancestors list, so the test is presence
-- rather than length: nil means "never loaded", {} means "top of the tree".
function SyncCore.hasLineage(taxon)
  return taxon ~= nil and taxon.ancestors ~= nil
end

--- Write a taxon onto a photo: the keyword hierarchy and the taxon fields.
--
-- MUST be called from inside a write transaction. createKeyword needs write
-- access exactly as the metadata setters do, and callers have other writes to
-- batch with it.
--
-- Shared by the sync, which learns the taxon from an observation, and by the
-- panel's local apply, which learns it from a suggestion the user picked. They
-- disagree about where a taxon comes from and agree about everything that
-- happens next, so only the first half is worth writing twice.
--
-- @return true when a taxon was written, false when there was none.
function SyncCore.applyTaxon(catalog, photo, taxon)
  if not taxon then return false end

  -- The keyword is skipped, not guessed, when the lineage never loaded.
  -- buildKeywordPath on a taxon with no ancestors yields
  -- {"iNaturalist", "Bombus"}, which files a genus beside the kingdoms as
  -- though that were where it belongs. The taxon fields below are still
  -- written -- they are correct either way, and they are what a later run
  -- reads to put the keyword right.
  if SyncCore.hasLineage(taxon) then
    local leafKw = ensureKeywordPath(catalog, buildKeywordPath(taxon))
    if leafKw then
      photo:addKeyword(leafKw)
    end
  else
    logger:warn("No lineage for taxon " .. tostring(taxon.name or taxon.id)
      .. "; wrote the fields and left the keyword for a later run")
  end

  photo:setPropertyForPlugin(_PLUGIN, "inat_taxon_id", tostring(taxon.id or ""))
  photo:setPropertyForPlugin(_PLUGIN, "inat_taxon_name", taxon.name or "")
  photo:setPropertyForPlugin(_PLUGIN, "inat_common_name",
    taxon.preferred_common_name or "")

  return true
end

--------------------------------------------------------------------------------
-- Sync a single photo
--------------------------------------------------------------------------------

--- The coordinates an observation is willing to tell us, if any.
--
-- @return latitude, longitude, accuracyInMetres -- all nil when there is
--         nothing safe to use.
--
-- The trap this exists for: **an obscured observation reports coordinates that
-- are deliberately wrong.** iNaturalist randomises the public position of
-- anything obscured -- by geoprivacy or because the taxon is threatened --
-- within a box that measured ~30 km across on a live example, and still returns
-- a `location` string and a `geojson` point. Nothing in the shape of the
-- response says the numbers are fiction; only the `obscured` flag does.
-- Trusting it would write a plausible coordinate up to 30 km from where the
-- photo was taken, into the user's own catalog, silently.
--
-- The owner is told the truth through `private_location`, which the API only
-- includes for authenticated requests on your own observations. So: use the
-- private position when it is there, use the public one when nothing is
-- obscured, and otherwise decline. Declining costs a user the convenience on
-- their own obscured records; the alternative costs somebody a wrong location
-- they will never think to check.
function SyncCore.coordinatesFrom(obs)
  if not obs then return nil, nil, nil end

  local point = obs.private_location
  if not point or point == "" then
    if obs.obscured then return nil, nil, nil end
    point = obs.location
  end

  if not point or point == "" then return nil, nil, nil end

  local latitude, longitude = string.match(point, "^%s*(-?[%d%.]+)%s*,%s*(-?[%d%.]+)%s*$")
  latitude, longitude = tonumber(latitude), tonumber(longitude)
  if not latitude or not longitude then return nil, nil, nil end

  -- positional_accuracy describes the true position, public_positional_accuracy
  -- the obscured one. Since we only ever return a true position, only the
  -- former belongs with it.
  local accuracy = tonumber(obs.positional_accuracy)
  if accuracy and accuracy <= 0 then accuracy = nil end

  return latitude, longitude, accuracy
end

--- Write everything an observation says onto a photo.
--
-- MUST be called from inside a write transaction. Split from the fetch so that
-- a caller holding a batch of photos can write them all in one transaction --
-- Reverse Sync links a hundred at a time -- rather than opening a block per
-- photo or, worse, nesting one inside another, which Lightroom refuses.
--
-- @param taxon  Already resolved, with ancestors. Resolving it makes an HTTP
--               call, which cannot happen in here: a write transaction blocks
--               the catalog, and blocking it on the network is how a sync ends
--               up looking like a hang.
function SyncCore.writeObservation(catalog, photo, obs, taxon)
  local obsId = obs.id

  SyncCore.applyTaxon(catalog, photo, taxon)

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

  -- Bring the location home, but only into an empty space.
  --
  -- The common case this serves: uploaded from a camera with no GPS, placed
  -- on the map afterwards on the iNaturalist website. Without this the
  -- catalog never learns where the photo was taken and the Map module stays
  -- empty forever.
  --
  -- Never an overwrite. If the photo already has coordinates then
  -- iNaturalist's copy came from them in the first place, so there is nothing
  -- to gain; and in the case where they have genuinely diverged, quietly
  -- moving a photo the user has already placed is not a sync, it is a
  -- correction nobody asked for and cannot see happen.
  local latitude, longitude, accuracy = SyncCore.coordinatesFrom(obs)
  if latitude and not UploadCore.locationOf(photo) then
    photo:setRawMetadata("gps", { latitude = latitude, longitude = longitude })
    logger:info("Applied location from observation " .. tostring(obsId))
  end

  -- The accuracy is recorded whether or not the coordinates were, because it
  -- describes what iNaturalist holds and the panel shows it back. Withheld
  -- when the position was, since an accuracy for a position we declined to
  -- read describes nothing we know.
  if latitude and accuracy then
    photo:setPropertyForPlugin(_PLUGIN, "inat_positional_accuracy",
      string.format("%d", math.floor(accuracy + 0.5)))
  end
end

--- The taxon an observation should be filed under, with its ancestors.
--
-- MUST be called from inside a task, and outside a write transaction: it may
-- make an HTTP call.
--
-- The community taxon wins where there is one. It is what iNaturalist itself
-- displays, and it is the answer several people agreed on rather than the one
-- the observer first guessed.
function SyncCore.taxonFor(api, obs)
  return SyncCore.withAncestors(api, obs.community_taxon or obs.taxon)
end

--- Warm the taxon cache for a set of observations.
--
-- MUST be called from inside a task.
--
-- The taxon each observation will be filed under is known as soon as the
-- observation is in hand, so they can all be fetched together instead of one
-- at a time from inside the photo loop. Uses the same choice of taxon that
-- taxonFor will make, so nothing is fetched that will not be used.
--
-- @param observations  A table of observations; keys are ignored.
function SyncCore.prefetchTaxa(observations, api)
  if not api.prefetchTaxa then return end

  local ids = {}
  for _, obs in pairs(observations or {}) do
    local taxon = obs.community_taxon or obs.taxon
    -- One that already carries its lineage needs no request at all.
    if taxon and taxon.id ~= nil and taxon.ancestors == nil then
      ids[#ids + 1] = taxon.id
    end
  end

  api:prefetchTaxa(ids)
end

--- Bring one photo up to date with an observation already in hand.
--
-- The observation is passed in rather than fetched so that Reverse Sync, which
-- has just downloaded every observation the user has, does not immediately ask
-- for each one again -- a second round trip per photo, against a rate limit of
-- 100 requests a minute.
--
-- @param write  Optional. Called as write(fn) to run the catalog writes; the
--               default opens a transaction of its own. Reverse Sync passes
--               one that does not, because it already holds one open.
-- @return status, err
function SyncCore.applyObservation(catalog, photo, obs, api, write)
  if not obs then return SyncCore.FAILED, "No observation to apply." end

  local taxon = SyncCore.taxonFor(api, obs)

  -- Everything that is not the taxon is written either way. An observation
  -- nobody has identified yet is the normal state of one just published, and
  -- its UUID and URL are worth recording now: the UUID is what stops the next
  -- publish creating a duplicate.
  local body = function()
    SyncCore.writeObservation(catalog, photo, obs, taxon)
  end

  if write then
    write(body)
  else
    catalog:withWriteAccessDo("iNat sync", body)
  end

  if not taxon then
    logger:info("Observation " .. tostring(obs.id)
      .. " has no taxon yet; recorded the rest")
    return SyncCore.UNIDENTIFIED, nil
  end

  logger:info("Synced photo → obs=" .. tostring(obs.id)
    .. " taxon=" .. (taxon.name or "?"))
  return SyncCore.SYNCED, nil
end

--- Bring one photo up to date with its observation.
--
-- @param obs  Optional. The already-fetched observation, which is how the
--             batched run avoids a request per photo. `false` means the batch
--             asked for it and it did not come back -- a deleted or hidden
--             observation -- so there is nothing to gain by asking again.
--             `nil` means nobody has looked, and this call does the fetching.
-- @return status  One of the SyncCore.* codes.
-- @return err     A message, when status is FAILED.
function SyncCore.syncPhoto(catalog, photo, api, obs)
  local obsId = photo:getPropertyForPlugin(_PLUGIN, "inat_observation_id")
  if not obsId or obsId == "" then
    return SyncCore.NO_ID, nil
  end

  local err
  if obs == nil then
    obs, err = api:getObservation(tonumber(obsId))
  elseif obs == false then
    obs, err = nil, "it no longer exists or is not visible to you"
  end
  if not obs then
    return SyncCore.FAILED,
      "Failed to fetch observation " .. obsId .. ": " .. (err or "unknown")
  end

  -- The fetched observation is trusted for everything except its own id, which
  -- is what the photo is filed under. A response missing it would otherwise
  -- write a url ending in "nil" over a good one.
  obs.id = obs.id or tonumber(obsId) or obsId

  return SyncCore.applyObservation(catalog, photo, obs, api)
end

--- Every observation the given photos are linked to, fetched in batches.
--
-- MUST be called from inside a task.
--
-- Returns a table keyed by the id as the photo stores it -- a string -- so the
-- loop can look up without converting. Photos with no id are skipped here and
-- reported by syncPhoto, which is the one place that decides what NO_ID means.
--
-- @return { [idString] = observation }, or nil plus an error message
function SyncCore.observationsFor(photos, api)
  local wanted, seen = {}, {}

  for _, photo in ipairs(photos) do
    local obsId = photo:getPropertyForPlugin(_PLUGIN, "inat_observation_id")
    if obsId and obsId ~= "" and not seen[tostring(obsId)] then
      seen[tostring(obsId)] = true
      wanted[#wanted + 1] = obsId
    end
  end

  return api:getObservations(wanted)
end

--------------------------------------------------------------------------------
-- Sync a list of photos
--------------------------------------------------------------------------------

--- Sync the given photos, reporting progress and a summary.
--
-- Holds the plugin's one job slot for the duration: see Jobs. Nothing else
-- that walks the catalog can start while this is running, and this will not
-- start while one of them is.
--
-- @param context  A live LrFunctionContext; the progress scope is tied to it,
--                 so it must belong to the task actually running this.
-- @param photos   The photos to sync.
-- @param options  quiet = true reports only when something actually went
--                 wrong. Used after a publish, where the run was not asked
--                 for directly and a modal saying "nothing to report" is just
--                 something else to dismiss.
function SyncCore.syncPhotos(context, photos, options)
  options = options or {}

  return Jobs.runOrReport(options.label or "Syncing photos with iNaturalist",
    function()
      SyncCore.syncPhotosNow(context, photos, options)
    end)
end

--- The sync itself, without the lock.
--
-- Separate so that the guard has exactly one place to be, and so a caller that
-- already holds the slot does not deadlock against itself.
function SyncCore.syncPhotosNow(context, photos, options)
  options = options or {}
  local catalog = LrApplication.activeCatalog()

  if not photos or #photos == 0 then
    if not options.quiet then
      LrDialogs.message("Pinned Sync", "No photos selected.", "warning")
    end
    return
  end

  local token, authErr = InatAuth.getToken()
  if not token then
    InatAuth.reportMissingCredentials(authErr)
    return
  end

  local api = InatAPI.new(token)

  local progress = LrProgressScope {
    title           = "Pinned Sync",
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

  -- Every observation up front, 200 to a request, rather than one request per
  -- photo. With requests paced a second apart for the rate limit, per-photo
  -- fetching put a 650-photo sync at eleven minutes of waiting.
  progress:setCaption("Fetching observations…")
  local observations, fetchErr = SyncCore.observationsFor(photos, api)
  if not observations then
    progress:done()
    LrDialogs.message("Pinned Sync",
      "Could not fetch your observations.\n\n" .. tostring(fetchErr), "critical")
    return
  end

  progress:setCaption("Fetching species…")
  SyncCore.prefetchTaxa(observations, api)

  for i, photo in ipairs(photos) do
    if progress:isCanceled() then break end

    progress:setCaption("Photo " .. i .. " of " .. #photos .. "…")
    progress:setPortionComplete(i - 1, #photos)

    local obsId = photo:getPropertyForPlugin(_PLUGIN, "inat_observation_id")
    -- `false`, not nil: the batch already asked for this id and it did not come
    -- back, so syncPhoto must not spend another paced request finding that out.
    local obs = nil
    if obsId and obsId ~= "" then
      obs = observations[tostring(obsId)] or false
    end

    local status, err = SyncCore.syncPhoto(catalog, photo, api, obs)
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
  LrDialogs.message("Pinned Sync", msg, #errors > 0 and "warning" or "info")
end

--------------------------------------------------------------------------------
-- Sync whatever is selected
--------------------------------------------------------------------------------

--- Sync the current target photos.
function SyncCore.syncTargetPhotos(context)
  SyncCore.syncPhotos(context, LrApplication.activeCatalog():getTargetPhotos())
end

return SyncCore
