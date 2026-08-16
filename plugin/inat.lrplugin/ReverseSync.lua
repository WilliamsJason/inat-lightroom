--[[
  ReverseSync.lua
  ---------------
  Finding the photos behind observations that already exist.

  The ordinary direction is photo first: a Lightroom photo becomes an
  observation. This is the other one, for observations made in the field on a
  phone, or uploaded years ago from somewhere else, whose photos have been
  sitting in the catalog unlinked ever since.

  Why it does not index the catalog
  ---------------------------------
  The obvious shape is to read every photo's capture time once, then look each
  observation up in that index. It works, and it stops working at a size real
  catalogs reach: reading metadata costs about 0.7 ms per photo, so a million
  photos is twelve minutes of waiting before the first match appears, and the
  index has to be held in memory while the user reads a dialog.

  The two sides are wildly asymmetric. Catalogs run to millions; nobody has
  more than about five digits of observations. So this asks the catalog one
  narrow capture-time question per observation and lets Lightroom's own index
  answer it -- measured at 1.7 ms, and flat with respect to catalog size, since
  the work is an index seek rather than a scan. Ten thousand observations is
  about seventeen seconds of querying whether the catalog holds six thousand
  photos or six million.

  The SDK probe that established those numbers is in explore/probes, and the
  findings are written up in docs/lightroom-sdk-notes.md.
--]]

local LrApplication = import "LrApplication"
local LrDate        = import "LrDate"
local LrTasks       = import "LrTasks"

local Logger    = require "Log"
local MatchCore = require "MatchCore"
local Settings  = require "Settings"

local logger = Logger

local ReverseSync = {}

--- Raw metadata read for each candidate photo.
--
-- Validated against a single photo before being used in anger, because
-- batchGetRawMetadata is all or nothing: one key it does not know throws away
-- every other column with `Unknown key: "..."`. `fileName` is the trap -- it
-- is formatted metadata, not raw -- and `path` is what stands in for it.
local CANDIDATE_KEYS = { "dateTimeOriginal", "gps", "path", "isVirtualCopy" }

--------------------------------------------------------------------------------
-- Photos already spoken for
--------------------------------------------------------------------------------

--- The set of photos already carrying an observation id.
--
-- An unlinked photo keeps the field and empties it rather than losing it, so
-- findPhotosWithProperty returns photos whose value is "" as well. Code that
-- trusts the call without filtering treats every photo ever unlinked as still
-- linked, and silently refuses to match it again.
function ReverseSync.linkedPhotos(catalog)
  local linked = {}
  local found = catalog:findPhotosWithProperty(_PLUGIN.id, "inat_observation_id")

  for _, photo in ipairs(found or {}) do
    local value = photo:getPropertyForPlugin(_PLUGIN, "inat_observation_id")
    if value and value ~= "" then linked[photo] = value end
  end

  return linked
end

--------------------------------------------------------------------------------
-- Candidates
--------------------------------------------------------------------------------

--- The wall-clock seconds a photo was taken, or nil when it has no capture time.
--
-- Lightroom counts from 2001-01-01 and MatchCore counts from 1970, and rather
-- than have two modules agree about an epoch offset, the conversion goes
-- through the one formatter whose output is already pinned by the search
-- format. Slower than arithmetic and impossible to get subtly wrong.
local function secondsOf(captured)
  if type(captured) ~= "number" then return nil end
  local parts = MatchCore.parseTimestamp(
    LrDate.timeToUserFormat(captured, "%Y-%m-%dT%H:%M:%S"))
  if not parts then return nil end
  return MatchCore.toSeconds(parts)
end

--- Photos whose capture time falls inside one observation's window.
--
-- One metadata read for the whole window rather than one per photo: a window
-- usually holds one or two photos, but a burst can hold a dozen, and
-- batchGetRawMetadata is about ten times cheaper per key.
function ReverseSync.candidatesFor(catalog, observation, tolerance, linked)
  local from, to = MatchCore.windowFor(observation, tolerance)
  if not from then return nil end

  local found = catalog:findPhotos {
    searchDesc = {
      { criteria = "captureTime", operation = "in", value = from, value2 = to },
      combine = "intersect",
    },
  }
  if not found or #found == 0 then return {} end

  local fresh = {}
  for _, photo in ipairs(found) do
    -- A photo already linked to something is not a candidate for anything.
    -- Reverse Sync exists to fill gaps, and quietly relinking a photo the user
    -- has already placed is the one outcome worse than finding nothing.
    if not linked[photo] then fresh[#fresh + 1] = photo end
  end
  if #fresh == 0 then return {} end

  local rows = catalog:batchGetRawMetadata(fresh, CANDIDATE_KEYS)

  local candidates = {}
  for _, photo in ipairs(fresh) do
    local row = rows[photo] or {}
    local seconds = secondsOf(row.dateTimeOriginal)
    if seconds then
      local gps = row.gps
      candidates[#candidates + 1] = {
        photo     = photo,
        seconds   = seconds,
        path      = row.path,
        latitude  = gps and gps.latitude or nil,
        longitude = gps and gps.longitude or nil,
      }
    end
  end

  return candidates
end

--------------------------------------------------------------------------------
-- The scan
--------------------------------------------------------------------------------

--- Match every observation against the catalog.
--
-- @param options.tolerance   seconds either side of the observation time
-- @param options.onProgress  called with (done, total, matchesSoFar)
-- @param options.shouldStop  called per observation; true abandons the scan
-- @return array of matches, plus a summary table
function ReverseSync.scan(catalog, observations, options)
  options = options or {}

  local tolerance = options.tolerance
    or tonumber(Settings.get("reverse_sync_tolerance_seconds")) or 2
  local linked = options.linked or ReverseSync.linkedPhotos(catalog)

  local matches = {}
  local summary = {
    observations = #observations,
    undatable    = 0,
    unmatched    = 0,
    ambiguous    = 0,
    conflicts    = 0,
    stopped      = false,
  }

  for index, observation in ipairs(observations) do
    local candidates = ReverseSync.candidatesFor(catalog, observation,
      tolerance, linked)

    if candidates == nil then
      -- No time to search by. An observation carrying only a date would match
      -- the whole day, which is a coincidence rather than a match.
      summary.undatable = summary.undatable + 1
    elseif #candidates == 0 then
      summary.unmatched = summary.unmatched + 1
    else
      local best = MatchCore.chooseMatch(observation, candidates)
      if best then
        best.observation = observation
        best.selected    = true

        -- Claimed straight away, so two observations seconds apart cannot both
        -- take the same frame. Whichever is considered first wins, which is
        -- arbitrary but at least visible: the loser reports as unmatched
        -- rather than quietly overwriting the winner at link time.
        linked[best.photo] = "pending"

        matches[#matches + 1] = best
        if best.ambiguous then summary.ambiguous = summary.ambiguous + 1 end
        if best.tier == MatchCore.CONFLICT then
          summary.conflicts = summary.conflicts + 1
        end
      else
        summary.unmatched = summary.unmatched + 1
      end
    end

    if options.onProgress then
      options.onProgress(index, #observations, #matches)
    end

    if options.shouldStop and options.shouldStop() then
      summary.stopped = true
      break
    end
  end

  summary.matched = #matches
  logger:info(string.format(
    "reverse sync scanned %d observations: %d matched, %d unmatched, %d undatable",
    summary.observations, summary.matched, summary.unmatched, summary.undatable))

  return matches, summary
end

--------------------------------------------------------------------------------
-- Applying
--------------------------------------------------------------------------------

--- Link the selected matches, in one transaction per batch.
--
-- Batched rather than one transaction for the whole run: a single write block
-- around ten thousand photos holds the catalog against the user for the
-- duration and loses everything if it fails at the end, while one block per
-- photo pays the transaction cost ten thousand times.
--
-- Each batch is resolved before it is written. Everything the observation says
-- is already in hand -- it came down with the list -- but a taxon usually
-- arrives without its ancestors, and the ancestors are the entire keyword
-- hierarchy. Fetching them is an HTTP call, and an HTTP call inside a write
-- transaction blocks the catalog on the network, which is indistinguishable
-- from a hang.
--
-- @param options.api  When given, each linked photo is also brought up to date
--                     with its observation: keywords, quality grade, location.
-- @return linkedCount, failures
function ReverseSync.apply(catalog, matches, options)
  options = options or {}
  local batchSize = options.batchSize or 100
  local UploadCore = require "UploadCore"
  local SyncCore   = options.api and require "SyncCore" or nil

  local selected = {}
  for _, match in ipairs(matches) do
    if match.selected then selected[#selected + 1] = match end
  end

  -- Keyed by taxon id and shared across the whole run. A few thousand
  -- observations are usually a few hundred species, and without this the same
  -- taxon is fetched once per observation of it.
  local taxa = {}

  local function taxonFor(observation)
    local raw = observation.community_taxon or observation.taxon
    if not raw then return nil end
    if raw.ancestors then return raw end

    local id = raw.id
    if id == nil then return raw end
    if taxa[id] == nil then
      taxa[id] = SyncCore.withAncestors(options.api, raw) or false
    end
    return taxa[id] or raw
  end

  local done, failures = 0, {}

  local index = 1
  while index <= #selected do
    local last = math.min(index + batchSize - 1, #selected)

    -- Resolved first, outside the transaction, and remembered per row so the
    -- write block below does nothing but write.
    local resolved = {}
    if SyncCore then
      for position = index, last do
        -- Also LrTasks.pcall: withAncestors makes an HTTP call, which yields.
        local ok, taxon = LrTasks.pcall(taxonFor, selected[position].observation)
        resolved[position] = ok and taxon or nil
      end
    end

    catalog:withWriteAccessDo("iNat reverse sync", function()
      for position = index, last do
        local match = selected[position]
        local observation = match.observation

        -- LrTasks.pcall, not Lua's. Lua 5.1 cannot yield across a C call, and
        -- pcall is one, so anything inside a plain pcall that yields fails with
        -- "Yielding is not allowed within a C or metamethod call" -- which is
        -- what this did, on every single photo. createKeyword yields, and every
        -- link creates the taxon's keyword path.
        --
        -- The failure is doubly unhelpful: it names neither pcall nor the call
        -- that yielded, and because it was caught and counted the whole run
        -- reported "0 linked, 1 could not be linked" and looked like a matching
        -- problem rather than a Lua one.
        local ok, err = LrTasks.pcall(function()
          UploadCore.writeObservationFields({ match.photo },
            observation.id, observation.uuid)

          if SyncCore then
            SyncCore.writeObservation(catalog, match.photo, observation,
              resolved[position])
          end
        end)

        if ok then
          done = done + 1
        else
          -- Recorded and stepped over rather than raised. One observation with
          -- something odd in it should not abandon the other ninety-nine in
          -- this batch, let alone the rest of the run.
          --
          -- The id is read defensively for the same reason: if the row is
          -- malformed enough to have failed, it is malformed enough to fail
          -- again here, and an error raised while recording an error would
          -- take out the batch the pcall above just saved.
          local id = observation and observation.id or "unknown"
          failures[#failures + 1] = {
            observation = id,
            message     = tostring(err),
          }
          -- Logged as well as counted. Told only that "1 could not be linked",
          -- with nothing in the log and no way to ask again, there is nothing
          -- the user or anyone helping them can do next.
          logger:warn("Reverse sync could not link observation "
            .. tostring(id) .. ": " .. tostring(err))
        end
      end
    end)

    if options.onProgress then
      options.onProgress(done, #selected)
    end

    index = last + 1
  end

  return done, failures
end

--------------------------------------------------------------------------------
-- Entry point
--------------------------------------------------------------------------------

--- Fetch observations and match them, without applying anything.
-- @return matches, summary -- or nil plus an error message
function ReverseSync.prepare(api, options)
  options = options or {}
  local catalog = LrApplication.activeCatalog()

  local observations, err = api:listObservations {
    perPage    = 200,
    onPage     = options.onFetch,
    shouldStop = options.shouldStop,
  }
  if not observations then return nil, err end

  local matches, summary = ReverseSync.scan(catalog, observations, options)
  return matches, summary
end

return ReverseSync
