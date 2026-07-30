--[[
  InatAPI.lua
  -----------
  Lua client for the iNaturalist REST API, built on LrHttp.

  Behaviours below were verified against the live API by the Python
  exploration scripts in explore/. Several are counter-intuitive and are
  called out at their call sites; see docs/inat-api-notes.md for the evidence.

  The three that will bite hardest if changed carelessly:

    1. Writes require a JWT, not a bare OAuth token. A bare OAuth token is
       treated as anonymous rather than rejected. Handled in InatAuth.

    2. PUT /observations/{id} DESTROYS every photo on the observation unless
       a top-level ignore_photos flag is sent. It returns 200 either way.
       See updateObservation.

    3. GET /v1/observations/{id} is served from a search index that lags
       reality by minutes. Never use it to confirm a write. See
       countAttachedPhotos.

  All functions here must be called from inside an async task, because
  LrHttp yields.

  Usage:
      local InatAPI = require "InatAPI"
      local api     = InatAPI.new(jwt)
      local obs     = api:getObservation(12345678)
--]]

local LrHttp   = import "LrHttp"

local json   = require "json"
local logger = require "Log"

local API_V1   = "https://api.inaturalist.org/v1"
local WWW_BASE = "https://www.inaturalist.org"

local USER_AGENT = "inat-lightroom/0.1 (+https://github.com/WilliamsJason/inat-lightroom)"

--------------------------------------------------------------------------------
-- Low-level helpers
--------------------------------------------------------------------------------

--- Percent-encode a string for use in a URL query or form body.
local function urlEncode(value)
  return (tostring(value):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

--- Build a query string from a table, encoding both keys and values.
local function buildQuery(params)
  if not params then return "" end

  local parts = {}
  for key, value in pairs(params) do
    if value ~= nil then
      parts[#parts + 1] = urlEncode(key) .. "=" .. urlEncode(value)
    end
  end

  if #parts == 0 then return "" end
  return "?" .. table.concat(parts, "&")
end

local function jsonHeaders(token)
  local headers = {
    { field = "Content-Type", value = "application/json" },
    { field = "Accept",       value = "application/json" },
    { field = "User-Agent",   value = USER_AGENT },
  }
  if token then
    headers[#headers + 1] = { field = "Authorization", value = "Bearer " .. token }
  end
  return headers
end

--- Interpret an LrHttp response: check status, decode JSON.
-- @return decoded table, or nil plus an error message
local function handleResponse(method, url, body, respHeaders)
  if not body then
    return nil, method .. " " .. url .. " failed: no response from the server"
  end

  local status = respHeaders and tonumber(respHeaders.status)
  if status and status >= 400 then
    -- Surface a snippet of the body; iNaturalist puts useful validation
    -- errors there and discarding them makes failures undebuggable.
    local snippet = tostring(body):sub(1, 300)
    return nil, string.format("%s %s failed with HTTP %d: %s",
      method, url, status, snippet)
  end

  -- DELETE and some updates legitimately return an empty body.
  if body == "" then
    return {}, nil
  end

  local ok, decoded = pcall(json.decode, body)
  if not ok then
    return nil, method .. " " .. url .. ": could not parse the response ("
      .. tostring(decoded) .. ")"
  end

  return decoded, nil
end

--- Unwrap the several response shapes the v1 API uses.
-- Some endpoints return {results = {...}}, some return a bare object, and
-- some return an array. Callers almost always want the single object.
local function firstResult(payload)
  if type(payload) ~= "table" then return nil end

  if payload.results ~= nil then
    if type(payload.results) == "table" then
      return payload.results[1]
    end
    return nil
  end

  -- An array-style response: take the first element.
  if payload[1] ~= nil then
    return payload[1]
  end

  return payload
end

--------------------------------------------------------------------------------
-- Request verbs
--------------------------------------------------------------------------------

local function apiGet(url, params, token)
  local fullUrl = url .. buildQuery(params)
  logger:debug("GET " .. fullUrl)
  local body, respHeaders = LrHttp.get(fullUrl, jsonHeaders(token))
  return handleResponse("GET", fullUrl, body, respHeaders)
end

local function apiSend(method, url, payload, token)
  local body = json.encode(payload)
  logger:debug(method .. " " .. url)
  local respBody, respHeaders = LrHttp.post(
    url, body, jsonHeaders(token), method, "application/json")
  return handleResponse(method, url, respBody, respHeaders)
end

--------------------------------------------------------------------------------
-- Multipart
--------------------------------------------------------------------------------

--- Build a multipart/form-data body.
-- @param fields  Array of { name = ..., value = ... } text fields
-- @param file    Optional { name = ..., fileName = ..., data = ..., contentType = ... }
-- @return body string, contentType string
local function buildMultipart(fields, file)
  local boundary = "----iNatLightroom" .. tostring(os.time()) .. tostring(math.random(100000, 999999))
  local CRLF = "\r\n"
  local parts = {}

  for _, field in ipairs(fields or {}) do
    parts[#parts + 1] = "--" .. boundary
    parts[#parts + 1] = 'Content-Disposition: form-data; name="' .. field.name .. '"'
    parts[#parts + 1] = ""
    parts[#parts + 1] = tostring(field.value)
  end

  if file then
    parts[#parts + 1] = "--" .. boundary
    parts[#parts + 1] = 'Content-Disposition: form-data; name="' .. file.name
      .. '"; filename="' .. file.fileName .. '"'
    parts[#parts + 1] = "Content-Type: " .. (file.contentType or "image/jpeg")
    parts[#parts + 1] = ""
    parts[#parts + 1] = file.data
  end

  parts[#parts + 1] = "--" .. boundary .. "--"
  parts[#parts + 1] = ""

  return table.concat(parts, CRLF), "multipart/form-data; boundary=" .. boundary
end

local function readFile(filePath)
  local handle = io.open(filePath, "rb")
  if not handle then
    return nil, "Cannot open file: " .. tostring(filePath)
  end
  local data = handle:read("*a")
  handle:close()
  return data, nil
end

local function baseName(filePath)
  return filePath:match("([^/\\]+)$") or "photo.jpg"
end

local function postMultipart(url, fields, file, token)
  local body, contentType = buildMultipart(fields, file)

  local headers = {
    { field = "Content-Type", value = contentType },
    { field = "Accept",       value = "application/json" },
    { field = "User-Agent",   value = USER_AGENT },
  }
  if token then
    headers[#headers + 1] = { field = "Authorization", value = "Bearer " .. token }
  end

  logger:debug("POST (multipart) " .. url)
  local respBody, respHeaders = LrHttp.post(url, body, headers, "POST", contentType)
  return handleResponse("POST", url, respBody, respHeaders)
end

--------------------------------------------------------------------------------
-- InatAPI class
--------------------------------------------------------------------------------

local InatAPI = {}
InatAPI.__index = InatAPI

--- Create a new API client.
-- @param token  A JWT from InatAuth.getToken(). NOT a bare OAuth token.
function InatAPI.new(token)
  return setmetatable({ token = token }, InatAPI)
end

--------------------------------------------------------------------------------
-- Taxa
--------------------------------------------------------------------------------

--- GET /taxa/autocomplete -- returns an array of taxon tables.
function InatAPI:autocompleteTaxon(query, rank)
  local params = { q = query, per_page = 10, locale = "en" }
  if rank then params.rank = rank end

  local payload, err = apiGet(API_V1 .. "/taxa/autocomplete", params, self.token)
  if not payload then return nil, err end

  return payload.results or {}, nil
end

--- GET /taxa/{id} -- full taxon including the ancestors array.
function InatAPI:getTaxon(taxonId)
  local payload, err = apiGet(API_V1 .. "/taxa/" .. tostring(taxonId), nil, self.token)
  if not payload then return nil, err end

  local taxon = firstResult(payload)
  if not taxon then
    return nil, "Taxon " .. tostring(taxonId) .. " not found"
  end
  return taxon, nil
end

--- Build the Lightroom keyword path for a taxon: kingdom down to the taxon,
-- nested under a single root keyword.
function InatAPI.buildKeywordPath(taxon, root)
  local path = { root or "iNaturalist" }
  for _, ancestor in ipairs(taxon.ancestors or {}) do
    path[#path + 1] = ancestor.name
  end
  path[#path + 1] = taxon.name
  return path
end

--------------------------------------------------------------------------------
-- Observations
--------------------------------------------------------------------------------

--- GET /observations/{id} -- returns the observation table itself.
--
-- Note this reads the search index, which lags writes by minutes. It is fine
-- for reading determinations, but must not be used to confirm an upload.
function InatAPI:getObservation(observationId)
  local payload, err = apiGet(
    API_V1 .. "/observations/" .. tostring(observationId), nil, self.token)
  if not payload then return nil, err end

  local observation = firstResult(payload)
  if not observation then
    return nil, "Observation " .. tostring(observationId) .. " not found"
  end
  return observation, nil
end

--- POST /observations -- returns the created observation (with .id).
function InatAPI:createObservation(params)
  local payload, err = apiSend("POST", API_V1 .. "/observations",
    { observation = params }, self.token)
  if not payload then return nil, err end

  local observation = firstResult(payload)
  if not observation or not observation.id then
    return nil, "The API did not return an observation ID"
  end
  return observation, nil
end

--- PUT /observations/{id} -- partial update.
--
-- WARNING: the API treats a PUT as a full replacement of the observation's
-- nested associations. Without the top-level ignore_photos flag, EVERY PHOTO
-- IS DETACHED from the observation and the request still returns 200. The
-- image files survive in iNaturalist's storage, but the observation is left
-- with no evidence and silently drops to casual grade.
--
-- Verified directly: an identical PUT took an observation from 1 photo to 0
-- without the flag, and left it at 1 with the flag.
--
-- ignorePhotos defaults to true. Only pass false if you genuinely intend to
-- remove the observation's photos.
function InatAPI:updateObservation(observationId, params, ignorePhotos)
  local body = { observation = params }

  if ignorePhotos ~= false then
    body.ignore_photos = true
  end

  local payload, err = apiSend("PUT",
    API_V1 .. "/observations/" .. tostring(observationId), body, self.token)
  if not payload then return nil, err end

  return firstResult(payload) or {}, nil
end

--- DELETE /observations/{id}
function InatAPI:deleteObservation(observationId)
  local url = API_V1 .. "/observations/" .. tostring(observationId)
  logger:debug("DELETE " .. url)
  local respBody, respHeaders = LrHttp.post(
    url, "", jsonHeaders(self.token), "DELETE", "application/json")
  return handleResponse("DELETE", url, respBody, respHeaders)
end

--------------------------------------------------------------------------------
-- Photos
--------------------------------------------------------------------------------

--- POST /observation_photos -- attach a rendered JPEG to an observation.
--
-- A 200 here does NOT mean the photo is attached: iNaturalist responds before
-- the image has finished processing, and the URLs in the response point at
-- placeholder graphics until it has. Prefer uploadPhotoVerified.
function InatAPI:uploadPhoto(observationId, filePath)
  local data, readErr = readFile(filePath)
  if not data then return nil, readErr end

  local fields = {
    { name = "observation_photo[observation_id]", value = observationId },
  }
  local file = {
    name = "file",
    fileName = baseName(filePath),
    data = data,
    contentType = "image/jpeg",
  }

  local payload, err = postMultipart(
    API_V1 .. "/observation_photos", fields, file, self.token)
  if not payload then return nil, err end

  return firstResult(payload) or {}, nil
end

--- Count the photos actually attached to an observation.
--
-- This deliberately queries the Rails endpoint rather than /v1/observations,
-- because the v1 API is served from a search index that lags photo processing
-- by minutes. It will report zero photos long after an upload has in fact
-- succeeded, which makes it useless for verification.
function InatAPI:countAttachedPhotos(observationId)
  local url = WWW_BASE .. "/observations/" .. tostring(observationId) .. ".json"
  local payload, err = apiGet(url, nil, self.token)
  if not payload then return nil, err end

  local photos = payload.observation_photos
  if type(photos) ~= "table" then return 0, nil end

  return #photos, nil
end

--- Upload a photo and confirm it actually attached, retrying if it did not.
--
-- @param observationId  Numeric observation ID
-- @param filePath       Absolute path to the rendered JPEG
-- @param options        Optional table:
--                         attempts   how many uploads to try (default 3)
--                         pollTries  polls per attempt (default 6)
--                         sleep      function(seconds) used to wait; pass
--                                    LrTasks.sleep from the calling task
--                         onEvent    function(message) progress callback
-- @return the upload response, or nil plus an error message
function InatAPI:uploadPhotoVerified(observationId, filePath, options)
  options = options or {}

  local attempts  = options.attempts or 3
  local pollTries = options.pollTries or 6
  local pollWait  = options.pollSeconds or 5
  local sleep     = options.sleep
  local onEvent   = options.onEvent or function() end

  local baseline, countErr = self:countAttachedPhotos(observationId)
  if not baseline then
    -- Do not fail the upload just because the baseline check failed.
    logger:warn("Could not read the photo baseline: " .. tostring(countErr))
    baseline = 0
  end

  local lastError

  for attempt = 1, attempts do
    local response, err = self:uploadPhoto(observationId, filePath)

    if not response then
      lastError = err
      onEvent(string.format("Attempt %d of %d failed: %s", attempt, attempts, tostring(err)))
    else
      onEvent(string.format("Attempt %d of %d accepted, verifying...", attempt, attempts))

      for _ = 1, pollTries do
        if sleep then sleep(pollWait) end

        local current = self:countAttachedPhotos(observationId)
        if current and current > baseline then
          onEvent("Photo verified as attached.")
          return response, nil
        end
      end

      lastError = "iNaturalist accepted the upload but the photo never attached"
      onEvent(string.format("Attempt %d of %d did not persist.", attempt, attempts))
    end
  end

  return nil, lastError or "Photo upload failed"
end

--------------------------------------------------------------------------------
-- Identifications
--------------------------------------------------------------------------------

--- GET /identifications?observation_id=... -- authoritative list.
--
-- Prefer this over the observation's identifications_count, which is
-- search-index backed and lags.
function InatAPI:getIdentifications(observationId)
  local payload, err = apiGet(API_V1 .. "/identifications",
    { observation_id = observationId, per_page = 100 }, self.token)
  if not payload then return nil, err end

  return payload.results or {}, nil
end

--- POST /identifications -- the correct way to change an observation's ID.
--
-- Do not set taxon_id via updateObservation for this: that moves the
-- observation's taxon but leaves the previous identification standing, so the
-- two disagree. Posting an identification makes iNaturalist withdraw the
-- author's earlier one automatically.
function InatAPI:addIdentification(observationId, taxonId, body)
  local identification = {
    observation_id = observationId,
    taxon_id       = taxonId,
  }
  if body and body ~= "" then
    identification.body = body
  end

  local payload, err = apiSend("POST", API_V1 .. "/identifications",
    { identification = identification }, self.token)
  if not payload then return nil, err end

  return firstResult(payload) or {}, nil
end

--- Summarise the current determination for an observation.
-- Prefers the community taxon, which is what the plugin should key off.
function InatAPI.determination(observation)
  local taxon     = observation.taxon or {}
  local community = observation.community_taxon
  local chosen    = community or taxon

  return {
    taxon_id     = chosen.id,
    name         = chosen.name,
    rank         = chosen.rank,
    common_name  = chosen.preferred_common_name,
    is_community = community ~= nil,
    quality_grade = observation.quality_grade,
  }
end

--------------------------------------------------------------------------------
-- Computer vision
--------------------------------------------------------------------------------

--- POST /computervision/score_image -- suggest taxa for a local file.
--
-- Lets the plugin offer suggestions before creating anything on iNaturalist.
--
-- IMPORTANT: lat, lng and observed_on must be sent as multipart form fields.
-- Passing them in the query string returns 200 and silently ignores them; the
-- only symptom is that every frequency_score comes back zero. Sending them
-- correctly is worth a great deal -- on a test image it collapsed four
-- candidates (including species from the wrong hemisphere) down to one.
--
-- @param filePath    Absolute path to a rendered JPEG (1024 px is plenty)
-- @param latitude    Optional
-- @param longitude   Optional
-- @param observedOn  Optional, YYYY-MM-DD
-- @return table with .results and .common_ancestor, or nil plus an error
function InatAPI:scoreImage(filePath, latitude, longitude, observedOn)
  local data, readErr = readFile(filePath)
  if not data then return nil, readErr end

  local fields = {}
  if latitude and longitude then
    fields[#fields + 1] = { name = "lat", value = latitude }
    fields[#fields + 1] = { name = "lng", value = longitude }
  end
  if observedOn and observedOn ~= "" then
    fields[#fields + 1] = { name = "observed_on", value = observedOn }
  end

  local file = {
    name = "image",
    fileName = baseName(filePath),
    data = data,
    contentType = "image/jpeg",
  }

  return postMultipart(API_V1 .. "/computervision/score_image",
    fields, file, self.token)
end

--- GET /computervision/score_observation/{id}
function InatAPI:scoreObservation(observationId)
  return apiGet(API_V1 .. "/computervision/score_observation/"
    .. tostring(observationId), nil, self.token)
end

--- Flatten a vision response into rows suitable for a picker UI.
function InatAPI.summariseSuggestions(payload)
  local rows = {}
  for _, result in ipairs((payload and payload.results) or {}) do
    local taxon = result.taxon or {}
    rows[#rows + 1] = {
      taxon_id       = taxon.id,
      name           = taxon.name,
      rank           = taxon.rank,
      common_name    = taxon.preferred_common_name,
      combined_score = result.combined_score,
      vision_score   = result.vision_score,
      frequency_score = result.frequency_score,
    }
  end
  return rows
end

--------------------------------------------------------------------------------
-- Projects
--------------------------------------------------------------------------------

--- POST /project_observations
function InatAPI:addToProject(observationId, projectId)
  local payload, err = apiSend("POST", API_V1 .. "/project_observations", {
    project_observation = {
      observation_id = observationId,
      project_id     = projectId,
    },
  }, self.token)
  if not payload then return nil, err end

  return firstResult(payload) or {}, nil
end

--- GET /projects?q=...
function InatAPI:searchProjects(query)
  local payload, err = apiGet(API_V1 .. "/projects",
    { q = query, per_page = 20 }, self.token)
  if not payload then return nil, err end

  return payload.results or {}, nil
end

return InatAPI
