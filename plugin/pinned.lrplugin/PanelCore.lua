--[[
  PanelCore.lua
  -------------
  What the floating panel's buttons actually do.

  Kept apart from ObservationPanel.lua for one reason: none of this can be
  tested through a view. ObservationPanel builds controls and wires clicks to
  functions; everything those functions do -- asking for suggestions, uploading,
  changing a determination, unlinking -- is here, taking its catalog and its API
  client as arguments so the Python harness can hand it fakes.

  Three things in here were learned rather than designed, and each has a comment
  where it happens:

    * a species guess is not a determination. iNaturalist ignores species_guess
      once an observation has a taxon, so choosing a suggestion has to post an
      identification.
    * suggestions for an already-uploaded photo need no render at all.
    * every path that changes an observation ends by syncing it back, or the
      taxonomy keywords silently stop matching what is on the website.
--]]

local InatAPI    = require "InatAPI"
local RenderPhoto = require "RenderPhoto"
local SyncCore   = require "SyncCore"
local UploadCore = require "UploadCore"
local logger     = require "Log"

local PanelCore = {}

--- How many suggestions to show. iNaturalist returns ten or so and the tail of
-- the list is noise; a short list that fits without scrolling is more useful
-- than a complete one.
PanelCore.SUGGESTION_LIMIT = 8

--- The score at or above which a species-level answer stands on its own.
--
-- Below it the picker offers coarser ranks and the upload asks for confirmation.
-- iNaturalist's own site makes the same move -- it stops naming a species and
-- says "we're pretty sure this is in the genus ..." -- and the number is a
-- judgement call rather than anything the API publishes.
--
-- The asymmetry that sets it: a genus-level record that is right is useful
-- forever, and a species-level record that is wrong is worse than useless,
-- because somebody downstream trusts it. So the threshold sits high enough to
-- catch a confident-looking guess.
PanelCore.CONFIDENT_SCORE = 75

--- Ranks worth offering as a fallback, coarsest first.
--
-- Deliberately not every rank iNaturalist has. Suborder, superfamily and tribe
-- are real, and a list containing all of them is a taxonomy lesson rather than
-- a choice -- these three are the ones a person actually files things under.
PanelCore.FALLBACK_RANKS = { "order", "family", "genus" }

--- Ranks that name a single species, and so carry the risk worth warning about.
PanelCore.SPECIES_RANKS = { species = true, subspecies = true, variety = true }

--- Shown in place of coordinates. Exposed so the panel and its tests agree on
-- the wording without either one hardcoding it.
local NO_LOCATION = "None - iNaturalist will mark this casual"
PanelCore.NO_LOCATION = NO_LOCATION

--------------------------------------------------------------------------------
-- Describing suggestions
--------------------------------------------------------------------------------

--- One suggestion as a single line of text.
--
-- The common name leads because that is what most people are deciding between,
-- but the scientific name is always shown: it is what actually gets uploaded,
-- and common names are ambiguous enough that hiding it would make the list
-- impossible to check.
function PanelCore.describeSuggestion(row)
  if not row then return "" end

  local name = row.common_name
  if name and name ~= "" and row.name and row.name ~= "" then
    name = name .. " (" .. row.name .. ")"
  else
    name = row.common_name or row.name or "Unnamed taxon"
  end

  local score = tonumber(row.combined_score)
  if score then
    name = name .. " - " .. string.format("%.0f%%", score)
  elseif row.note and row.note ~= "" then
    name = name .. " - " .. row.note
  end

  return name
end

--- The coarser taxa worth offering when no species-level answer is convincing.
--
-- @param commonAncestor  The vision response's common ancestor, fetched with
--                        its `ancestors` so there is a ladder to walk.
-- @param topScore        The best combined_score in the list.
-- @return A list of rows in the same shape as a suggestion, finest first.
--
-- Built from the common ancestor's own lineage and nothing else, which is what
-- keeps it honest: the common ancestor is the most specific taxon the model is
-- confident about across every candidate, so it and everything above it are
-- agreed on by the whole list. Walking *down* from it -- say, offering the top
-- result's genus -- would assume the top result's lineage is the right one,
-- which at 40% is precisely what is in doubt.
--
-- Empty when something already scores well: a confident answer needs no
-- fallback, and offering one anyway would make every identification look
-- uncertain.
function PanelCore.fallbackRows(commonAncestor, topScore)
  if not commonAncestor then return {} end
  if tonumber(topScore) and tonumber(topScore) >= PanelCore.CONFIDENT_SCORE then
    return {}
  end

  local wanted = {}
  for _, rank in ipairs(PanelCore.FALLBACK_RANKS) do wanted[rank] = true end

  local chain = {}
  for _, taxon in ipairs(commonAncestor.ancestors or {}) do
    chain[#chain + 1] = taxon
  end
  chain[#chain + 1] = commonAncestor

  local rows = {}
  for i = #chain, 1, -1 do
    local taxon = chain[i]
    if taxon and taxon.id and wanted[taxon.rank] then
      rows[#rows + 1] = {
        taxon_id    = taxon.id,
        name        = taxon.name,
        rank        = taxon.rank,
        common_name = taxon.preferred_common_name,
        -- No score. These are not candidates the model ranked, and a percentage
        -- next to one would be a number nobody computed.
        note        = taxon.rank .. ", agreed by every suggestion",
      }
    end
  end

  return rows
end

--- The case against claiming this taxon, if there is one.
--
-- @return A message to show, or nil when there is nothing worth saying.
--
-- Only for a rank that names one species. Committing a genus you are 40% sure
-- of is a normal, useful record -- it is what an expert does when the photo will
-- not support more -- but committing a *species* you are 40% sure of quietly
-- puts a wrong name into a public dataset that other people build on.
--
-- Silent when there is no score at all. That means a fallback rank or a
-- hand-typed name, and there is no evidence to call weak.
function PanelCore.confidenceWarning(row)
  if not row then return nil end
  if not PanelCore.SPECIES_RANKS[row.rank] then return nil end

  local score = tonumber(row.combined_score)
  if not score or score >= PanelCore.CONFIDENT_SCORE then return nil end

  local name = row.name or row.common_name or "that species"

  return string.format(
    "iNaturalist's model is only %.0f%% confident that this is %s.\n\n" ..
    "A wrong species-level identification is harder to undo than a vague one, " ..
    "because other people build on it. If you are not sure, Get Suggestions " ..
    "again and pick the genus or family instead -- a coarser record that is " ..
    "right is worth more than a precise one that is wrong.",
    score, name)
end

--- What a chosen and an unchosen suggestion row are prefixed with.
--
-- A hand-built row has no selection highlight of its own -- that came free with
-- the list control this replaced -- so the mark is the only thing saying which
-- suggestion the buttons below are about. Both are the same width so the names
-- stay in one column.
PanelCore.CHOSEN_MARK   = "\226\151\143 "  -- a filled circle
PanelCore.UNCHOSEN_MARK = "  "

--- The caption of the per-row link out to iNaturalist.
PanelCore.TAXON_LINK = "View \226\134\151"

--- Turn suggestion rows into the fixed set of display slots the panel has.
--
-- The panel's rows are built once and cannot be added to, removed or hidden --
-- a bound `visible` is accepted and ignored (see docs/lightroom-sdk-notes.md)
-- -- so there is always SUGGESTION_LIMIT of them and the surplus are blank.
--
-- A slot carries what its row draws and nothing else: the title with its
-- chosen/unchosen mark, and the link caption, which is empty when the row has
-- no taxon to link to. Blank slots have neither, so an empty row is inert
-- rather than a link to nowhere.
--
-- @param rows      The suggestion rows, in order.
-- @param selected  The index currently chosen, or nil.
function PanelCore.suggestionSlots(rows, selected)
  local slots = {}

  for i = 1, PanelCore.SUGGESTION_LIMIT do
    local row = (rows or {})[i]

    if row then
      local mark = (i == selected) and PanelCore.CHOSEN_MARK
                                    or PanelCore.UNCHOSEN_MARK
      slots[i] = {
        title = mark .. PanelCore.describeSuggestion(row),
        link  = PanelCore.taxonUrl(row.taxon_id) and PanelCore.TAXON_LINK or "",
      }
    else
      slots[i] = { title = "", link = "" }
    end
  end

  return slots
end

--- Normalise whatever a caller offers as a suggestion row index.
--
-- The rows are hand-built now and hand a plain number straight back, so this is
-- a guard rather than a translation. It stays because of what it was written
-- for: f:simple_list, which the rows replaced, reported its selection as a
-- *table* of selected indexes even when only one row could be picked, and
-- taking that for a row number failed silently -- the row highlighted, rows[{}]
-- was nil, and the click did nothing, with no error and nothing in the log.
-- See docs/lightroom-sdk-notes.md.
--
-- Every plausible shape is accepted rather than only the one that turned out to
-- be real, because that failure mode is invisible.
function PanelCore.selectedIndex(value)
  if type(value) == "number" then return value end
  if type(value) == "string" then return tonumber(value) end

  if type(value) ~= "table" then return nil end

  -- Recorded so the real shape stops being an inference. Remove once the log
  -- has said the same thing a few times.
  logger:tracef("suggestion selection arrived as a table: [1] is %s",
                type(value[1]))

  local first = value[1]
  if type(first) == "number" then return first end
  if type(first) == "string" then return tonumber(first) end
  if type(first) == "table"  then return tonumber(first.value) end

  -- A single item table rather than a list of them.
  return tonumber(value.value)
end

--- Describe a photo's location for display.
function PanelCore.describeLocation(photo)
  if not photo then return "" end

  local latitude, longitude = UploadCore.locationOf(photo)
  if not latitude then return NO_LOCATION end

  return string.format("%.5f, %.5f", latitude, longitude)
end

--- Decide whether an upload should be questioned for having no location.
--
-- Returns a message when it should, nil when it should not.
--
-- Missing coordinates are not a cosmetic problem. Measured against the live
-- API: of 8,691,735 open-geoprivacy observations with no coordinates, 99.975%
-- are casual grade, which keeps them out of most research use and out of the
-- GBIF export. Only 1,793 of them ever reached research grade. An upload
-- without a location is a record that will mostly not count, and the moment to
-- say so is before it happens rather than after.
--
-- Silent when the user has turned off "send GPS coordinates". Warning about a
-- thing they have deliberately switched off is nagging, and a warning that
-- fires when it should not is a warning people learn to click past -- which
-- would cost us the times it is right.
function PanelCore.locationWarning(settings, photos)
  settings = settings or {}

  if not settings.inat_upload_location then return nil end
  if not photos or #photos == 0 then return nil end

  -- The observation's details come from the first photo, so it is the first
  -- photo's location that decides, however many are selected.
  local latitude = UploadCore.locationOf(photos[1])
  if latitude then return nil end

  return "This photo has no location.\n\n"
      .. "iNaturalist marks observations without coordinates as casual grade, "
      .. "which keeps them out of most research use. Almost nothing without a "
      .. "location ever reaches research grade.\n\n"
      .. "You can set one in Lightroom's Map module and upload afterwards."
end

--------------------------------------------------------------------------------
-- How precise the location claims to be
--------------------------------------------------------------------------------

--- The presets offered in the panel, coarsest concept first.
--
-- Metres, because that is what iNaturalist stores. The numbers are deliberately
-- round: this is a claim about how well the photographer knows where they were,
-- not a measurement, and offering "37 m" would invite a precision nobody has.
--
-- There is no preset for "exact". A coordinate is never exact -- consumer GPS
-- lands within a handful of metres on a good day -- and a plugin that offers to
-- claim zero uncertainty would be offering to lie on the user's behalf. 10 m is
-- what a camera or phone fix is actually worth.
PanelCore.ACCURACY_PRESETS = {
  { value = "",     label = "Not specified" },
  { value = "10",   label = "Precise - GPS fix (~10 m)" },
  { value = "100",  label = "Approximate - within ~100 m" },
  { value = "3000", label = "Rough - within a few km" },
}

--- Normalise a stored accuracy to a plain string of metres, or "" for unset.
--
-- Stored as a string because that is what a plugin metadata field holds, but a
-- sync writes whatever number iNaturalist has, so it arrives as anything.
function PanelCore.accuracyValue(raw)
  if raw == nil or raw == "" then return "" end

  local metres = tonumber(raw)
  if not metres or metres <= 0 then return "" end

  -- Whole metres. iNaturalist rejects a fractional positional_accuracy, and
  -- floats reaching a popup_menu would never match a preset's string anyway.
  return string.format("%d", math.floor(metres + 0.5))
end

--- The items for the accuracy popup, including the stored value if it is not a
--- preset.
--
-- A popup_menu whose value matches no item renders blank, which would read as
-- "not specified" for an observation that has an accuracy -- and picking any
-- preset would then silently overwrite it. Since a sync brings back the real
-- number and it is almost never one of our four, the odd value gets an item of
-- its own rather than being rounded to the nearest preset.
function PanelCore.accuracyItems(stored)
  local value = PanelCore.accuracyValue(stored)
  local items = {}

  for _, preset in ipairs(PanelCore.ACCURACY_PRESETS) do
    items[#items + 1] = { value = preset.value, title = preset.label }
    if preset.value == value then value = nil end
  end

  if value then
    items[#items + 1] = {
      value = value,
      title = "From iNaturalist (" .. value .. " m)",
    }
  end

  return items
end

--------------------------------------------------------------------------------
-- Asking for suggestions
--------------------------------------------------------------------------------

--- Suggest taxa for a photo.
--
-- MUST be called from inside a task: it renders and makes HTTP calls.
--
-- An already-uploaded photo takes the cheap path. score_observation is a plain
-- GET against something iNaturalist already holds, so there is no render, no
-- temporary file and no upload -- and it scores the observation's own photos,
-- which is a better question than scoring a fresh JPEG of one of them.
--
-- @return rows, error message
function PanelCore.getSuggestions(api, photo)
  if not photo then
    return nil, "Select a photo first."
  end

  local payload, err

  local obsId = UploadCore.pluginField(photo, "inat_observation_id")
  if obsId then
    payload, err = api:scoreObservation(tonumber(obsId))
  else
    local path, renderErr, folder = RenderPhoto.renderForSuggestions(photo)
    if not path then
      return nil, renderErr
    end

    -- Location and date are not decoration here. Sent as multipart fields they
    -- collapse the candidate list dramatically, because a species from the wrong
    -- hemisphere stops being plausible. Sent as query parameters iNaturalist
    -- returns 200 and ignores them -- see InatAPI:scoreImage.
    local latitude, longitude = UploadCore.locationOf(photo)

    payload, err = api:scoreImage(path, latitude, longitude,
      UploadCore.observedOnFor(photo))

    RenderPhoto.cleanUp(folder)
  end

  if not payload then return nil, err end

  local rows, commonAncestor = InatAPI.summariseSuggestions(payload)
  return PanelCore.withFallbacks(api, rows, commonAncestor), nil
end

--- Put the coarser options at the top of the list, when there should be any.
--
-- MUST be called from inside a task: it may fetch the ancestor's lineage.
--
-- At the top rather than the bottom because that is where the answer the user
-- should probably pick belongs. A safer choice below eight species is one
-- nobody scrolls to.
function PanelCore.withFallbacks(api, rows, commonAncestor)
  rows = rows or {}

  local topScore = rows[1] and tonumber(rows[1].combined_score)
  if not commonAncestor then return rows end
  if topScore and topScore >= PanelCore.CONFIDENT_SCORE then return rows end

  -- Only now is the extra request worth making. A confident list never pays for
  -- a lineage it will not show.
  local fallbacks = PanelCore.fallbackRows(
    SyncCore.withAncestors(api, commonAncestor), topScore)

  local combined = {}
  for _, row in ipairs(fallbacks) do combined[#combined + 1] = row end
  for _, row in ipairs(rows) do combined[#combined + 1] = row end

  return combined
end

--------------------------------------------------------------------------------
-- Uploading
--------------------------------------------------------------------------------

--- Upload the selected photos as a single observation.
--
-- MUST be called from inside a task.
--
-- One observation for the whole selection is the deliberate behaviour, and it
-- is the thing the publish service could not do: a service is handed photos one
-- at a time, so grouping had to be recorded on the photos beforehand. The panel
-- has the selection in front of it, so six frames of the same animal become one
-- observation with six photos, which is what iNaturalist wants.
--
-- The observation's details come from the first photo. Its date, location and
-- caption describe the sighting, and the sighting is one thing however many
-- frames were taken of it.
--
-- @param options  onEvent(message) progress callback, sleep for the upload
--                 verifier
-- @return observationId, url, list of error strings
function PanelCore.upload(catalog, api, settings, photos, options)
  options  = options or {}
  settings = settings or {}
  local onEvent = options.onEvent or function() end

  if not photos or #photos == 0 then
    return nil, nil, { "Select at least one photo first." }
  end

  local errors = {}

  onEvent("Rendering " .. #photos .. " photo(s)…")
  local rendered, renderFailures, folder = RenderPhoto.render(photos, {
    settings = settings,
  })

  for _, failure in ipairs(renderFailures) do
    errors[#errors + 1] = failure
  end

  if #rendered == 0 then
    RenderPhoto.cleanUp(folder)
    if #errors == 0 then
      errors[#errors + 1] = RenderPhoto.FAILED_MESSAGE
    end
    return nil, nil, errors
  end

  onEvent("Creating the observation…")
  local seen = {}
  local observationId, uuid, resolveErr =
    UploadCore.resolveObservation(api, settings, photos[1], seen, errors)

  if not observationId then
    RenderPhoto.cleanUp(folder)
    errors[#errors + 1] = resolveErr or "Could not create the observation."
    return nil, nil, errors
  end

  local attached = 0
  for i, item in ipairs(rendered) do
    onEvent("Uploading photo " .. i .. " of " .. #rendered .. "…")

    local _, uploadErr = api:uploadPhotoVerified(observationId, item.path, {
      sleep   = options.sleep,
      onEvent = onEvent,
    })

    if uploadErr then
      errors[#errors + 1] = uploadErr
    else
      attached = attached + 1
    end
  end

  RenderPhoto.cleanUp(folder)

  if attached == 0 then
    -- Every photo failed, so the observation exists with nothing in it. Saying
    -- so is better than recording a link to an empty observation and letting
    -- the panel report success.
    errors[#errors + 1] = "Observation " .. tostring(observationId)
      .. " was created but no photo could be attached to it."
    return nil, nil, errors
  end

  local url = UploadCore.recordObservation(catalog, photos, observationId, uuid)

  if settings.inat_project_id and settings.inat_project_id ~= "" then
    local _, projectErr = api:addToProject(observationId, settings.inat_project_id)
    if projectErr then
      errors[#errors + 1] = "Could not add it to the project: " .. tostring(projectErr)
    end
  end

  -- Bring the taxonomy keywords back down. Without this an upload leaves the
  -- catalog knowing an observation ID and nothing else, and the keywords only
  -- appear whenever somebody happens to press Sync.
  if settings.inat_sync_after_upload ~= false then
    onEvent("Syncing…")
    PanelCore.syncBack(catalog, api, photos, errors)
  end

  logger:info("Uploaded " .. attached .. " photo(s) as observation " .. tostring(observationId))
  return observationId, url, errors
end

--------------------------------------------------------------------------------
-- Changing the determination
--------------------------------------------------------------------------------

--- Tell iNaturalist what this is.
--
-- MUST be called from inside a task.
--
-- The distinction that matters: species_guess is free text that iNaturalist
-- shows only while an observation has no taxon. Once anything has been
-- identified -- including by the uploader -- it is ignored, which is exactly
-- why an edited guess appeared to vanish. So when a taxon is known this posts a
-- real identification, and the free-text field is only used when the user typed
-- something we could not resolve to a taxon.
--
-- Note it posts an identification rather than setting taxon_id through
-- updateObservation. Setting taxon_id moves the observation but leaves the
-- author's earlier identification standing, so the observation and its own
-- identification disagree. Posting withdraws the earlier one automatically.
--
-- @return true, or false plus an error message
function PanelCore.updateSpeciesGuess(catalog, api, photos, guess, taxonId)
  if not photos or #photos == 0 then
    return false, "Select a photo first."
  end

  local observationId = UploadCore.pluginField(photos[1], "inat_observation_id")
  if not observationId then
    return false, "That photo has not been uploaded to iNaturalist yet."
  end

  PanelCore.recordGuess(catalog, photos, guess)

  local err
  if taxonId then
    local _, identifyErr = api:addIdentification(tonumber(observationId), taxonId)
    err = identifyErr
  else
    -- No taxon to point at, so all we can offer is the free text -- which
    -- iNaturalist will only display while nobody has identified it.
    local _, updateErr = api:updateObservation(tonumber(observationId), {
      species_guess = guess or "",
    }, true)
    err = updateErr
  end

  if err then
    return false, err
  end

  local errors = {}
  PanelCore.syncBack(catalog, api, photos, errors)

  return true, errors[1]
end

--- Write the species guess onto every photo.
--
-- Applies to the whole selection rather than just the first photo. The panel
-- displays the first photo's values but the buttons act on the selection, and
-- typing one name for the six frames of one animal is the common case.
--
-- The taxon id a suggestion carried is deliberately not stored. inat_taxon_id
-- means "what iNaturalist currently says this is", written by the sync; putting
-- a guess in it would make the Metadata panel claim a determination that
-- nobody, including us, has actually made yet.
function PanelCore.recordGuess(catalog, photos, guess)
  catalog:withWriteAccessDo("iNat species guess", function()
    for _, photo in ipairs(photos) do
      photo:setPropertyForPlugin(_PLUGIN, "inat_species_guess", guess or "")
    end
  end)
end

--- Write the location accuracy onto every photo.
--
-- Same reasoning as recordGuess: the panel shows the first photo but the
-- buttons act on the selection, and the frames of one animal share a location.
function PanelCore.recordAccuracy(catalog, photos, accuracy)
  local value = PanelCore.accuracyValue(accuracy)

  catalog:withWriteAccessDo("iNat location accuracy", function()
    for _, photo in ipairs(photos) do
      photo:setPropertyForPlugin(_PLUGIN, "inat_positional_accuracy", value)
    end
  end)
end

--- Push a changed accuracy to an observation that already exists.
--
-- MUST be called from inside a task.
--
-- Upload reads the accuracy off the photo, so a new observation carries it
-- without any help. An existing one does not: the update path posts an
-- identification, which says nothing about location, so without this a user
-- could change the accuracy on an uploaded photo and watch the panel accept it
-- while iNaturalist kept the old value forever.
--
-- @return true, or false plus an error message
function PanelCore.updateAccuracy(catalog, api, photos, accuracy)
  if not photos or #photos == 0 then return true, nil end

  local observationId = UploadCore.pluginField(photos[1], "inat_observation_id")
  if not observationId then return true, nil end

  local value = PanelCore.accuracyValue(accuracy)
  if value == "" then return true, nil end

  -- ignore_photos, as everywhere else. A PUT without it detaches every photo on
  -- the observation and still returns 200.
  local _, err = api:updateObservation(tonumber(observationId), {
    positional_accuracy = tonumber(value),
  }, true)
  if err then return false, err end

  PanelCore.recordAccuracy(catalog, photos, value)
  return true, nil
end

--------------------------------------------------------------------------------
-- Applying a taxon without telling iNaturalist
--------------------------------------------------------------------------------

--- The public page for a taxon.
--
-- Deciding between two similar-looking suggestions usually means going and
-- looking at both, and the plugin cannot show a photo grid in a floating window.
function PanelCore.taxonUrl(taxonId)
  if not taxonId or taxonId == "" then return nil end
  local id = tonumber(taxonId)
  if not id then return nil end

  return "https://www.inaturalist.org/taxa/" .. string.format("%d", id)
end

--- Write a chosen suggestion's taxonomy into the catalog and stop there.
--
-- MUST be called from inside a task: it fetches the taxon's ancestors.
--
-- The point of this is the photo you are not going to upload. Plenty of frames
-- are worth filing under the right name and not worth publishing -- a duplicate,
-- a bad exposure of something already recorded, somebody's cat -- and before
-- this the only way to get iNaturalist's keyword hierarchy onto one was to
-- create an observation and then think better of it.
--
-- Nothing here touches iNaturalist, so no observation link is made or implied.
--
-- @return true, or false plus a message
function PanelCore.applyGuessLocally(catalog, api, photos, taxonId)
  if not photos or #photos == 0 then
    return false, "Select a photo first."
  end
  if not taxonId then
    return false, "Pick a suggestion first, then apply it."
  end

  local taxon, err = api:getTaxon(tonumber(taxonId))
  if not taxon then
    return false, err or "Could not fetch that taxon."
  end

  catalog:withWriteAccessDo("iNat apply taxon", function()
    for _, photo in ipairs(photos) do
      SyncCore.applyTaxon(catalog, photo, taxon)

      -- The guess is what this actually is: a name the user chose, not one
      -- anybody confirmed. Recording it keeps the panel honest about where the
      -- keywords came from, and gives a later upload the right species_guess.
      photo:setPropertyForPlugin(_PLUGIN, "inat_species_guess", taxon.name or "")
    end
  end)

  logger:info("Applied taxon " .. tostring(taxon.name) .. " to " ..
              tostring(#photos) .. " photo(s) locally")
  return true, nil
end



--- Re-read the observation and write its taxonomy back onto the photos.
--
-- Every button that changes something on iNaturalist finishes here, which is
-- the whole point: the keywords are the reason this plugin exists, and having
-- three code paths that each remembered to write them separately is how they
-- came to disagree.
--
-- Failures are collected rather than raised. The upload or the identification
-- has already succeeded by the time this runs, and a sync that could not read
-- the observation back does not undo it.
function PanelCore.syncBack(catalog, api, photos, errors)
  local synced = 0

  for _, photo in ipairs(photos or {}) do
    local status, err = SyncCore.syncPhoto(catalog, photo, api)
    if status == SyncCore.FAILED then
      if errors then errors[#errors + 1] = err end
      logger:warn("Sync-back failed: " .. tostring(err))
    else
      synced = synced + 1
    end
  end

  return synced
end

--------------------------------------------------------------------------------
-- Unlinking
--------------------------------------------------------------------------------

--- Forget the link between the selected photos and their observation.
--
-- Nothing on iNaturalist is touched and the keywords are left alone -- see
-- UploadCore.unlink, which explains why.
function PanelCore.unlink(catalog, photos)
  return UploadCore.unlink(catalog, photos)
end

return PanelCore
