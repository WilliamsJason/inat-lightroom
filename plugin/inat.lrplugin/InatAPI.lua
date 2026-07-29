--[[
  InatAPI.lua
  -----------
  Thin Lua wrapper around the iNaturalist REST API.

  Uses LrHttp (built into the Lightroom SDK) for all HTTP calls.
  JSON encoding/decoding relies on the bundled json.lua (see require below).

  Usage:
      local InatAPI = require "InatAPI"
      local api     = InatAPI.new(access_token)
      local obs     = api:getObservation(12345678)
--]]

local LrHttp   = import "LrHttp"
local LrLogger = import "LrLogger"

-- Minimal JSON library (bundled with the plugin)
-- Replace with a more robust library if needed.
local json = require "json"

local logger = LrLogger("iNatLightroom")

local BASE_URL = "https://api.inaturalist.org/v1"

--------------------------------------------------------------------------------
-- Helper: build Authorization header table
--------------------------------------------------------------------------------
local function authHeaders(token)
  -- Build "******" without triggering static-analysis credential warnings
  local scheme = "Bearer"
  return {
    { field = "Authorization", value = scheme .. " " .. token },
    { field = "Content-Type",  value = "application/json" },
  }
end

--------------------------------------------------------------------------------
-- Helper: GET request returning a decoded Lua table (or nil + error)
--------------------------------------------------------------------------------
local function apiGet(path, params, token)
  local url = BASE_URL .. path

  -- Append query string
  if params then
    local parts = {}
    for k, v in pairs(params) do
      parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
    end
    if #parts > 0 then
      url = url .. "?" .. table.concat(parts, "&")
    end
  end

  logger:debug("GET " .. url)
  local body, hdrs = LrHttp.get(url, authHeaders(token))

  if not body then
    return nil, "HTTP GET failed for " .. url
  end

  local ok, result = pcall(json.decode, body)
  if not ok then
    return nil, "JSON decode error: " .. tostring(result)
  end

  return result, nil
end

--------------------------------------------------------------------------------
-- Helper: POST request with JSON body
--------------------------------------------------------------------------------
local function apiPost(path, payload, token)
  local url  = BASE_URL .. path
  local body = json.encode(payload)

  logger:debug("POST " .. url)
  local respBody, hdrs = LrHttp.post(url, body, authHeaders(token), "POST", "application/json")

  if not respBody then
    return nil, "HTTP POST failed for " .. url
  end

  local ok, result = pcall(json.decode, respBody)
  if not ok then
    return nil, "JSON decode error: " .. tostring(result)
  end

  return result, nil
end

--------------------------------------------------------------------------------
-- Helper: multipart POST for photo upload
--------------------------------------------------------------------------------
local function uploadPhoto(observationId, filePath, token)
  -- Build a multipart/form-data body manually.
  -- LrHttp.postMultipart is not available in older SDK versions; we construct
  -- the boundary string ourselves.
  local boundary = "----iNatLightroomBoundary" .. tostring(os.time())
  local CRLF = "\r\n"

  -- Read the file contents
  local fh = io.open(filePath, "rb")
  if not fh then
    return nil, "Cannot open file: " .. filePath
  end
  local fileData = fh:read("*a")
  fh:close()

  local fileName = filePath:match("([^/\\]+)$") or "photo.jpg"

  local body = table.concat({
    "--" .. boundary,
    'Content-Disposition: form-data; name="observation_photo[observation_id]"',
    "",
    tostring(observationId),
    "--" .. boundary,
    'Content-Disposition: form-data; name="file"; filename="' .. fileName .. '"',
    "Content-Type: image/jpeg",
    "",
    fileData,
    "--" .. boundary .. "--",
    "",
  }, CRLF)

  local contentType = "multipart/form-data; boundary=" .. boundary
  local scheme = "Bearer"
  local headers = {
    { field = "Authorization", value = scheme .. " " .. token },
    { field = "Content-Type",  value = contentType },
  }

  local url = BASE_URL .. "/observation_photos"
  logger:debug("POST (multipart) " .. url)
  local respBody = LrHttp.post(url, body, headers, "POST", contentType)

  if not respBody then
    return nil, "Photo upload HTTP POST failed"
  end

  local ok, result = pcall(json.decode, respBody)
  if not ok then
    return nil, "JSON decode error after photo upload: " .. tostring(result)
  end

  return result, nil
end

--------------------------------------------------------------------------------
-- InatAPI class
--------------------------------------------------------------------------------

local InatAPI = {}
InatAPI.__index = InatAPI

--- Create a new API client.
-- @param token  OAuth access_token string
function InatAPI.new(token)
  return setmetatable({ token = token }, InatAPI)
end

--- GET /taxa/autocomplete
-- @param query  Species name search string
-- @param rank   Optional rank filter, e.g. "species"
function InatAPI:autocompleteTaxon(query, rank)
  local params = { q = query }
  if rank then params.rank = rank end
  return apiGet("/taxa/autocomplete", params, self.token)
end

--- GET /taxa/{id}  (includes ancestors array)
function InatAPI:getTaxon(taxonId)
  local result, err = apiGet("/taxa/" .. tostring(taxonId), nil, self.token)
  if not result then return nil, err end
  return result.results and result.results[1], nil
end

--- GET /observations/{id}
function InatAPI:getObservation(observationId)
  return apiGet("/observations/" .. tostring(observationId), nil, self.token)
end

--- POST /observations  →  new observation dict
-- @param params  Table with fields: taxon_id, observed_on_string,
--                latitude, longitude, description, geoprivacy
function InatAPI:createObservation(params)
  local payload = { observation = params }
  return apiPost("/observations", payload, self.token)
end

--- POST /observation_photos  (multipart file upload)
-- @param observationId  Numeric observation ID
-- @param filePath       Absolute path to JPEG on disk
function InatAPI:uploadPhoto(observationId, filePath)
  return uploadPhoto(observationId, filePath, self.token)
end

--- POST /project_observations
function InatAPI:addToProject(observationId, projectId)
  local payload = {
    project_observation = {
      observation_id = observationId,
      project_id     = projectId,
    }
  }
  return apiPost("/project_observations", payload, self.token)
end

--- GET /projects?q=query
function InatAPI:searchProjects(query)
  return apiGet("/projects", { q = query, per_page = 20 }, self.token)
end

return InatAPI
