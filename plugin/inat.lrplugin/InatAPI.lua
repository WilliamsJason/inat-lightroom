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

local LrDate   = import "LrDate"
local LrHttp   = import "LrHttp"
local LrTasks  = import "LrTasks"

local json   = require "json"
local logger = require "Log"

local API_V1   = "https://api.inaturalist.org/v1"

-- Declared here rather than beside its constructor because the request verbs
-- above read the rate-limit settings off it.
local InatAPI = {}
InatAPI.__index = InatAPI

-- v2 is used for exactly one call: listing observations. It is the only
-- endpoint here that returns thousands of rows, and the only one where v2's
-- `fields` parameter is worth the difference in response shape. See
-- LIST_FIELDS.
local API_V2   = "https://api.inaturalist.org/v2"
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
    -- On a transport failure LrHttp returns no body and puts the reason in
    -- the headers table. Reporting only "no response" throws that away and
    -- leaves nothing to act on.
    local detail
    if type(respHeaders) == "table" and type(respHeaders.error) == "table" then
      local err = respHeaders.error
      detail = tostring(err.name or "unknown error")
      if err.errorCode then
        detail = detail .. " (code " .. tostring(err.errorCode) .. ")"
      end
    end

    return nil, method .. " " .. url .. " failed: "
      .. (detail or "no response from the server")
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
-- Staying inside the rate limit
--------------------------------------------------------------------------------

--- Seconds to leave between requests.
--
-- iNaturalist asks for no more than 60 requests a minute and refuses above
-- roughly 100. A sync loop makes one or two requests per photo and nothing
-- paces it, so a few hundred photos hit the ceiling within seconds: a real run
-- took 346 of 654 taxon lookups to HTTP 429.
--
-- That mattered far more than a failed request usually does, because the code
-- that asks for a taxon wants its ancestors, and a taxon without ancestors
-- still looks like a taxon. Every 429 wrote a species keyword directly under
-- "iNaturalist" instead of under its lineage, so throttling quietly flattened
-- a third of the user's keyword tree.
InatAPI.MIN_INTERVAL = 1.0

--- How many times to retry a request the server refused for rate.
InatAPI.MAX_RETRIES = 4

local lastRequestAt = nil

--- Wait until the next request is allowed.
--
-- MUST be called from inside a task. LrTasks.sleep yields, and the whole API
-- is task-only already.
local function pace()
  if lastRequestAt then
    local since = LrDate.currentTime() - lastRequestAt
    local wait  = InatAPI.MIN_INTERVAL - since
    -- Guarded against a negative wait and against a clock that has gone
    -- backwards, which would otherwise sleep for most of a day.
    if wait > 0 and wait <= InatAPI.MIN_INTERVAL then
      LrTasks.sleep(wait)
    end
  end
  lastRequestAt = LrDate.currentTime()
end

--- True when the server refused this request for rate rather than for content.
local function throttled(err)
  return type(err) == "string" and err:find("HTTP 429", 1, true) ~= nil
end

--- Run one request, pacing it and retrying while the server says 429.
--
-- Backoff doubles from a second. A 429 means the window is already full, so
-- retrying at the same rate spends the whole allowance on refusals.
local function paced(send)
  local delay = 1.0

  for attempt = 1, InatAPI.MAX_RETRIES + 1 do
    pace()
    local payload, err = send()
    if payload or not throttled(err) then return payload, err end

    if attempt <= InatAPI.MAX_RETRIES then
      logger:warn(string.format(
        "Rate limited by iNaturalist; waiting %.0fs (attempt %d of %d)",
        delay, attempt, InatAPI.MAX_RETRIES))
      LrTasks.sleep(delay)
      delay = delay * 2
    end
  end

  return nil, "iNaturalist is rate limiting this plugin; try again shortly."
end

InatAPI._paced = paced

--------------------------------------------------------------------------------
-- Request verbs
--------------------------------------------------------------------------------

local function apiGet(url, params, token)
  local fullUrl = url .. buildQuery(params)
  logger:debug("GET " .. fullUrl)
  return paced(function()
    local body, respHeaders = LrHttp.get(fullUrl, jsonHeaders(token))
    return handleResponse("GET", fullUrl, body, respHeaders)
  end)
end

local function apiSend(method, url, payload, token)
  local body = json.encode(payload)
  logger:debug(method .. " " .. url)
  -- Content type goes in the headers. LrHttp.post's fifth parameter is a
  -- timeout, and passing a string there stops the request being made at all.
  local respBody, respHeaders = LrHttp.post(url, body, jsonHeaders(token), method)
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
  local respBody, respHeaders = LrHttp.post(url, body, headers, "POST")
  return handleResponse("POST", url, respBody, respHeaders)
end

--------------------------------------------------------------------------------
-- InatAPI class
--------------------------------------------------------------------------------

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
--
-- Memoised on the client, because the callers ask the same question over and
-- over: a sync of 654 photos was 654 lookups covering a few hundred species,
-- and one taxon id appeared dozens of times. A taxon's lineage cannot change
-- while Lightroom is open, so the second answer is always the first one.
--
-- Only successes are kept. Caching a failure would turn one refused request
-- into a permanently wrong keyword for every photo of that species in the run.
function InatAPI:getTaxon(taxonId)
  local key = tostring(taxonId)
  self._taxa = self._taxa or {}
  if self._taxa[key] then return self._taxa[key], nil end

  local payload, err = apiGet(API_V1 .. "/taxa/" .. key, nil, self.token)
  if not payload then return nil, err end

  local taxon = firstResult(payload)
  if not taxon then
    return nil, "Taxon " .. key .. " not found"
  end

  self._taxa[key] = taxon
  return taxon, nil
end

--- GET /taxa?id=1,2,3 -- fill the taxon cache in bulk.
--
-- Nothing is returned. This exists purely so that the getTaxon calls that
-- follow are answered from memory: after batching the observation fetches, the
-- taxon lookups were the entire remaining cost of a sync -- 158 requests at a
-- paced second each, against one request for all 169 observations.
--
-- Best effort by design. An id that does not come back, or a whole batch that
-- fails, simply leaves the cache without it, and getTaxon asks for it the slow
-- way. Reporting an error here would make a partial answer look like a failed
-- sync when the sync is about to succeed.
--
-- MUST be called from inside a task.
function InatAPI:prefetchTaxa(ids)
  if type(ids) ~= "table" or #ids == 0 then return end

  self._taxa = self._taxa or {}

  local BATCH = 200
  local wanted = {}
  local seen = {}
  for _, id in ipairs(ids) do
    local key = tostring(id)
    if not self._taxa[key] and not seen[key] then
      seen[key] = true
      wanted[#wanted + 1] = key
    end
  end

  local index = 1
  while index <= #wanted do
    local last = math.min(index + BATCH - 1, #wanted)
    local batch = {}
    for position = index, last do
      batch[#batch + 1] = wanted[position]
    end

    local payload, err = apiGet(API_V1 .. "/taxa", {
      id       = table.concat(batch, ","),
      per_page = BATCH,
    }, self.token)

    if payload then
      for _, taxon in ipairs(payload.results or {}) do
        -- Only a taxon that knows its own lineage is worth caching. One
        -- without ancestors would be a cached answer that stops getTaxon ever
        -- asking properly, and the lineage is the whole keyword hierarchy.
        if taxon.id ~= nil and taxon.ancestors ~= nil then
          self._taxa[tostring(taxon.id)] = taxon
        end
      end
    else
      logger:warn("Could not prefetch taxa: " .. (err or "unknown")
        .. "; falling back to one request each")
    end

    index = last + 1
  end
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
-- Who we are
--------------------------------------------------------------------------------

--- GET /users/me -- the account the stored token belongs to.
--
-- Needed because the search endpoints have no notion of "me". `user_id=me`
-- looks like it ought to work, and every other API this plugin talks to would
-- accept it; iNaturalist answers HTTP 422 `Unknown user_id me`, because
-- user_id there is an index filter and the index holds numbers, not pronouns.
--
-- Cached on the client. The answer cannot change while a token is in use, and
-- the alternative is an extra round trip in front of every search.
function InatAPI:currentUser()
  if self._currentUser then return self._currentUser, nil end

  local payload, err = apiGet(API_V1 .. "/users/me", nil, self.token)
  if not payload then return nil, err end

  local user = firstResult(payload)
  if not user or not user.id then
    return nil, "iNaturalist did not say which account this token belongs to."
  end

  self._currentUser = user
  return user, nil
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

--- GET /observations?id=a,b,c -- many observations in one request.
--
-- The endpoint takes up to 200 ids at a time, which is the difference between
-- a sync of 654 photos costing 654 requests and costing four. That mattered
-- little until requests were paced a second apart to stay inside the rate
-- limit; now it is the difference between eleven minutes and a few seconds.
--
-- Returned as a table keyed by id, because the API is under no obligation to
-- answer in the order asked and an observation that has been deleted on the
-- website simply does not come back. Callers look each one up rather than
-- zipping two lists together, which would silently shift every photo after a
-- missing one onto the wrong observation.
--
-- @param ids array of observation ids
-- @return { [id] = observation }, or nil plus an error message
function InatAPI:getObservations(ids)
  local found = {}
  if type(ids) ~= "table" or #ids == 0 then return found, nil end

  local BATCH = 200
  local index = 1

  while index <= #ids do
    local last  = math.min(index + BATCH - 1, #ids)
    local batch = {}
    for position = index, last do
      batch[#batch + 1] = tostring(ids[position])
    end

    local payload, err = apiGet(API_V1 .. "/observations", {
      id       = table.concat(batch, ","),
      per_page = BATCH,
    }, self.token)
    if not payload then return nil, err end

    for _, observation in ipairs(payload.results or {}) do
      if observation.id ~= nil then
        found[tostring(observation.id)] = observation
      end
    end

    index = last + 1
  end

  return found, nil
end

--- GET /observations?uuid=... -- find an observation by its UUID.
--
-- The UUID is how this plugin knows that several Lightroom photos belong to
-- one observation, and it is the only handle that survives a photo being
-- published, re-rendered and published again.
--
-- Returns the observation, or nil with no error when there simply is not one:
-- a photo whose observation was deleted on the website is a normal state to be
-- in, not a failure, and the caller's job is to make a new one rather than to
-- report a problem.
function InatAPI:findObservationByUuid(uuid)
  if not uuid or uuid == "" then
    return nil, nil
  end

  local payload, err = apiGet(API_V1 .. "/observations",
    { uuid = uuid, per_page = 1 }, self.token)
  if not payload then return nil, err end

  local results = payload.results
  if type(results) ~= "table" or #results == 0 then
    return nil, nil
  end

  return results[1], nil
end

--- What a listed observation needs to carry.
--
-- v1 has no way to ask for less than everything, and everything is enormous:
-- one page of 200 observations is about 15 MB, nearly all of it identifications,
-- comments, photo URLs in six sizes, and the observer's profile repeated 200
-- times. Asking v2 for these fields instead brings the same page back in about
-- 95 KB -- a hundred and sixty times smaller, on every page, for an account
-- that may have tens of them.
--
-- Anything the matching or linking code reads has to be listed here, because v2
-- returns precisely what was asked for and nothing else. A field left out does
-- not error; it simply arrives nil, which is how a missing time_observed_at
-- would quietly become "this observation cannot be matched".
local LIST_FIELDS = table.concat({
  "id", "uuid",
  "observed_on", "observed_on_string", "time_observed_at", "observed_time_zone",
  "location", "private_location", "obscured", "geoprivacy",
  "positional_accuracy", "public_positional_accuracy",
  "quality_grade",
  "taxon.id", "taxon.name", "taxon.rank", "taxon.preferred_common_name",
  "community_taxon.id", "community_taxon.name", "community_taxon.rank",
  "community_taxon.preferred_common_name",
  -- The review list draws the iNaturalist photo beside the catalog one, so the
  -- user can confirm a match by looking rather than by trusting a timestamp.
  -- `photos.url` is the 75px square; ThumbCache rewrites it for a bigger size.
  "photos.id", "photos.url",
}, ",")

InatAPI.LIST_FIELDS = LIST_FIELDS

--- GET /observations?user_id=... -- every observation of yours, in id order.
--
-- The id is looked up rather than assumed: see currentUser, which exists
-- because "me" is not a user id.
--
-- Cursor pagination, not page numbers. `page` × `per_page` is capped at 10,000
-- by the API, so a user with more observations than that simply cannot reach
-- the end by asking for page 51: the request fails rather than paging on.
-- `id_above` has no such ceiling, because it asks the index to resume rather
-- than to count.
--
-- That makes ordering load-bearing: `order_by = "id"` ascending is what lets
-- the last id of one page become the cursor for the next. Any other ordering
-- silently repeats or skips observations.
--
-- @param options.perPage    results per request (default 200, the API maximum)
-- @param options.fields     comma-separated field list, to keep pages small
-- @param options.onPage     called with (fetchedSoFar, totalResults) per page
-- @param options.shouldStop called between pages; return true to stop early
-- @return array of observations, or nil plus an error message
function InatAPI:listObservations(options)
  options = options or {}

  local user, userErr = self:currentUser()
  if not user then return nil, userErr end

  local perPage    = options.perPage or 200
  local observations = {}
  local idAbove   = 0
  local total     = nil

  while true do
    local params = {
      user_id  = user.id,
      order_by = "id",
      order    = "asc",
      per_page = perPage,
      id_above = idAbove,
      fields   = options.fields or LIST_FIELDS,
    }

    local payload, err = apiGet(API_V2 .. "/observations", params, self.token)
    if not payload then return nil, err end

    local results = payload.results
    if type(results) ~= "table" or #results == 0 then
      break
    end

    total = total or payload.total_results

    for _, observation in ipairs(results) do
      observations[#observations + 1] = observation
      -- The cursor has to advance even if a later page is abandoned, so it is
      -- taken from every row rather than from the last one after the loop.
      if type(observation.id) == "number" and observation.id > idAbove then
        idAbove = observation.id
      end
    end

    if options.onPage then
      options.onPage(#observations, total or #observations)
    end

    -- A short page means the end of the results, and asking again would cost a
    -- request against a rate limit of 100/minute to be told the same thing.
    if #results < perPage then break end

    if options.shouldStop and options.shouldStop() then break end
  end

  return observations, nil
end

--- POST /observations -- returns the created observation (with .id).
--
-- Pass params.uuid to create an observation the caller has already named. That
-- is how a second Lightroom photo joins an observation whose first photo was
-- published from another machine: the UUID travels in the catalog, the
-- observation is found or created under it either way.
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
    url, "", jsonHeaders(self.token), "DELETE")
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

--- Pull the observation_photo ID out of an upload response.
--
-- Lightroom wants an ID for every published photo, and it is the handle used
-- later to detach or replace that photo. POST /observation_photos is
-- documented to return the record itself, but the v1 API has been inconsistent
-- enough elsewhere that guessing one shape and crashing on the other is not
-- worth it -- so this looks in the places the ID has actually been seen and
-- says so plainly when it finds none.
function InatAPI.observationPhotoId(response)
  if type(response) ~= "table" then return nil end

  local candidates = {
    response.id,
    response.observation_photo_id,
    type(response.observation_photo) == "table" and response.observation_photo.id or nil,
  }

  for _, candidate in ipairs(candidates) do
    if candidate ~= nil and candidate ~= "" then
      return tostring(candidate)
    end
  end

  return nil
end

--- DELETE /observation_photos/{id} -- detach a photo from its observation.
--
-- A 404 counts as success: the only reason to call this is to reach a state
-- where the photo is gone, and it already being gone is that state. Treating
-- it as an error would make a retry after a half-finished delete fail forever.
function InatAPI:deleteObservationPhoto(observationPhotoId)
  local url = API_V1 .. "/observation_photos/" .. tostring(observationPhotoId)
  logger:debug("DELETE " .. url)
  local respBody, respHeaders = LrHttp.post(
    url, "", jsonHeaders(self.token), "DELETE")

  local payload, err = handleResponse("DELETE", url, respBody, respHeaders)
  if payload then return payload, nil end

  if respHeaders and tonumber(respHeaders.status) == 404 then
    return {}, nil
  end

  return nil, err
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
--- Reduce a vision payload to the rows the picker shows, plus the fallback.
--
-- @return rows, commonAncestor
--
-- `common_ancestor` is the most specific taxon the model is confident about
-- *across all candidates*, which is a different and better-founded claim than
-- the lineage of the top result: when the candidates disagree at species level
-- but agree at genus, this is that genus. It is what lets the picker offer a
-- coarser rank honestly, so it is returned rather than dropped.
--
-- Absent from a response whose candidates share nothing, and possibly from
-- score_observation, so every caller must cope with nil.
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

  local ancestor = payload and payload.common_ancestor
  return rows, ancestor and ancestor.taxon or nil
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
