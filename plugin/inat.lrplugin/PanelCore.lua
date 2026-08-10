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
  end

  return name
end

--- Turn suggestion rows into items for a list control.
--
-- The value is the row's position rather than its taxon_id because a taxon_id
-- is not guaranteed to be there (an unranked or malformed result comes back
-- with a taxon that has no id), and a list whose values collide or go nil
-- selects the wrong row rather than failing.
function PanelCore.suggestionItems(rows)
  local items = {}
  for i, row in ipairs(rows or {}) do
    if i > PanelCore.SUGGESTION_LIMIT then break end
    items[#items + 1] = {
      title = PanelCore.describeSuggestion(row),
      value = i,
    }
  end
  return items
end

--- Work out which suggestion row a list control is reporting as selected.
--
-- f:simple_list does not hand back the row number. Its `value` is bound to the
-- underlying table_view's `selected_indexes` through a transform, and the
-- reverse path runs ipairs over that -- so what arrives is a *list* of selected
-- values, even when only one row can be picked. Observed in the host: choosing
-- a row set the property to a table, chooseSuggestion was handed that table as
-- an index, rows[{...}] was nil, and the click did nothing at all.
--
-- Every plausible shape is accepted rather than the one that turned out to be
-- real, because the failure is silent -- a control that quietly does nothing
-- looks like a control nobody wired up. The shapes: a bare row number, a list
-- of them, or a list of the item tables themselves.
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

  local obsId = UploadCore.pluginField(photo, "inat_observation_id")
  if obsId then
    local payload, err = api:scoreObservation(tonumber(obsId))
    if not payload then return nil, err end
    return InatAPI.summariseSuggestions(payload), nil
  end

  local path, renderErr, folder = RenderPhoto.renderForSuggestions(photo)
  if not path then
    return nil, renderErr
  end

  -- Location and date are not decoration here. Sent as multipart fields they
  -- collapse the candidate list dramatically, because a species from the wrong
  -- hemisphere stops being plausible. Sent as query parameters iNaturalist
  -- returns 200 and ignores them -- see InatAPI:scoreImage.
  local latitude, longitude = UploadCore.locationOf(photo)

  local payload, err = api:scoreImage(path, latitude, longitude,
    UploadCore.observedOnFor(photo))

  RenderPhoto.cleanUp(folder)

  if not payload then return nil, err end
  return InatAPI.summariseSuggestions(payload), nil
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

--------------------------------------------------------------------------------
-- Keeping the catalog in step
--------------------------------------------------------------------------------

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
