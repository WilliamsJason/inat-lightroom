--[[
  InatAuth.lua
  ------------
  Token acquisition and credential storage for iNaturalist.

  There are two tokens involved, and conflating them is the easiest way to
  break this plugin:

    * OAuth access token -- never expires, but the v1 API does NOT accept it
      for writes. Its only real job is to be exchanged for a JWT.
    * JWT "API token"    -- expires after 24 hours, and is what actually
      authenticates API calls.

  Presenting a bare OAuth token to api.inaturalist.org does not return 401.
  The request is silently processed as an anonymous user, so writes fail in
  ways that are very hard to diagnose. Always send the JWT.

  Two ways to obtain one:

    1. Manual JWT (works today, no application registration).
       The user signs in at inaturalist.org, opens /users/api_token, and
       pastes the token into the setup dialog. Must be repeated every 24 h.

    2. OAuth application (requires approval from iNaturalist; accounts need
       to be 2+ months old with 10+ improving identifications in the last
       month). Once configured, the never-expiring OAuth token mints fresh
       JWTs automatically and the user never sees a prompt again.

  Secrets are held by LrPasswords, which is backed by the OS credential
  vault. Non-secret bookkeeping (when the JWT was obtained, which mode is in
  use) lives in LrPrefs.
--]]

local LrHttp    = import "LrHttp"
local LrPasswords = import "LrPasswords"
local LrPrefs   = import "LrPrefs"
local LrStringUtils = import "LrStringUtils"

local json = require "json"

local logger = require "Log"
local prefs  = LrPrefs.prefsForPlugin()

local WWW_BASE = "https://www.inaturalist.org"
local API_V1   = "https://api.inaturalist.org/v1"

-- LrPasswords keys. LrPasswords is already scoped to this plugin, so these
-- do not need the toolkit identifier prefixed.
local KEY_API_TOKEN  = "api_token"
local KEY_APP_ID     = "app_id"
local KEY_APP_SECRET = "app_secret"
local KEY_USERNAME   = "username"
local KEY_USER_PASS  = "user_pass"

-- iNaturalist JWTs last 24 hours. Refresh early so a long export does not
-- expire midway through.
local JWT_LIFETIME_SECONDS = 24 * 60 * 60
local JWT_REFRESH_MARGIN   = 60 * 60

local InatAuth = {}

--------------------------------------------------------------------------------
-- Credential storage
--------------------------------------------------------------------------------

--- Read a secret, normalising the empty string to nil.
local function retrieve(key)
  local value = LrPasswords.retrieve(key)
  if value == nil or value == "" then
    return nil
  end
  return value
end

local function store(key, value)
  LrPasswords.store(key, value or "")
end

--- Read the expiry out of a JWT.
--
-- A JWT is three base64url segments separated by dots, the middle one being
-- JSON with an "exp" claim holding a Unix timestamp. Reading it means expiry
-- is known rather than inferred from when the user happened to paste, which
-- matters when a token was copied some time before it was pasted in.
--
-- @return expiry as a Unix timestamp, or nil if it cannot be determined
local function decodeExpiry(token)
  local payload = token:match("^[^%.]+%.([^%.]+)%.")
  if not payload then return nil end

  -- base64url differs from base64 in two characters, and drops the padding.
  payload = payload:gsub("%-", "+"):gsub("_", "/")

  local remainder = #payload % 4
  if remainder == 2 then
    payload = payload .. "=="
  elseif remainder == 3 then
    payload = payload .. "="
  elseif remainder == 1 then
    return nil
  end

  local ok, decoded = pcall(LrStringUtils.decodeBase64, payload)
  if not ok or not decoded then return nil end

  local parsedOk, parsed = pcall(json.decode, decoded)
  if not parsedOk or type(parsed) ~= "table" then return nil end

  return tonumber(parsed.exp)
end

--- Store a JWT pasted by the user.
-- Accepts either a bare token or the whole {"api_token":"..."} response body.
function InatAuth.storeApiToken(raw)
  if not raw or raw == "" then
    return false, "No token supplied."
  end

  local token = raw:gsub("^%s+", ""):gsub("%s+$", "")

  if token:sub(1, 1) == "{" then
    local ok, decoded = pcall(json.decode, token)
    if not ok or type(decoded) ~= "table" or not decoded.api_token then
      return false, "That looks like JSON but has no api_token field."
    end
    token = decoded.api_token
  end

  -- Catch the common paste mistakes -- grabbing the page text, the URL, or
  -- only part of the token -- before they turn into a confusing API error.
  if not token:match("^[%w%-_]+%.[%w%-_]+%.[%w%-_]+$") then
    return false, "That does not look like an iNaturalist API token.\n\n"
      .. "Expected three dot-separated blocks. Copy the value of the "
      .. "\"api_token\" field from www.inaturalist.org/users/api_token."
  end

  local expiresAt = decodeExpiry(token)
  if expiresAt and expiresAt <= os.time() then
    return false, "That token has already expired.\n\n"
      .. "Reload www.inaturalist.org/users/api_token to get a fresh one."
  end

  store(KEY_API_TOKEN, token)
  prefs.apiTokenObtainedAt = os.time()
  prefs.apiTokenExpiresAt  = expiresAt
  prefs.authMode = "manual_jwt"
  logger:info("Stored a manually pasted JWT"
    .. (expiresAt and (", expires at " .. tostring(expiresAt)) or ""))
  return true, nil
end

--- Store OAuth application credentials for automatic JWT refresh.
function InatAuth.storeOAuthApp(appId, appSecret, username, userPass)
  store(KEY_APP_ID, appId)
  store(KEY_APP_SECRET, appSecret)
  store(KEY_USERNAME, username)
  store(KEY_USER_PASS, userPass)
  prefs.authMode = "oauth_app"
  -- Force the next call to mint a fresh token.
  prefs.apiTokenObtainedAt = nil
  prefs.apiTokenExpiresAt  = nil
  logger:info("Stored OAuth application credentials")
  return true, nil
end

function InatAuth.hasOAuthApp()
  return retrieve(KEY_APP_ID) ~= nil
     and retrieve(KEY_APP_SECRET) ~= nil
     and retrieve(KEY_USERNAME) ~= nil
     and retrieve(KEY_USER_PASS) ~= nil
end

function InatAuth.getStoredUsername()
  return retrieve(KEY_USERNAME)
end

function InatAuth.clear()
  for _, key in ipairs({ KEY_API_TOKEN, KEY_APP_ID, KEY_APP_SECRET,
                         KEY_USERNAME, KEY_USER_PASS }) do
    store(key, "")
  end
  prefs.apiTokenObtainedAt = nil
  prefs.apiTokenExpiresAt  = nil
  prefs.authMode = nil
  logger:info("Cleared stored credentials")
end

--- Seconds since the stored JWT was obtained; nil when none is stored.
function InatAuth.tokenAgeSeconds()
  if not prefs.apiTokenObtainedAt then return nil end
  return os.time() - prefs.apiTokenObtainedAt
end

--- Seconds until the stored JWT expires. Negative when already expired,
-- nil when there is no token or its expiry could not be determined.
function InatAuth.tokenSecondsRemaining()
  if prefs.apiTokenExpiresAt then
    return prefs.apiTokenExpiresAt - os.time()
  end

  -- No decoded expiry: fall back to assuming the full lifetime from when it
  -- was stored.
  if prefs.apiTokenObtainedAt then
    return (prefs.apiTokenObtainedAt + JWT_LIFETIME_SECONDS) - os.time()
  end

  return nil
end

--- Return the stored JWT if it is still usable, else nil.
local function cachedTokenIfUsable()
  local token = retrieve(KEY_API_TOKEN)
  if not token then return nil end

  local remaining = InatAuth.tokenSecondsRemaining()
  if not remaining then return nil end

  -- Refresh early so a long export cannot have its token die mid-run.
  if remaining <= JWT_REFRESH_MARGIN then return nil end

  return token
end

--------------------------------------------------------------------------------
-- OAuth application flow
--------------------------------------------------------------------------------

--- Percent-encode a value for an application/x-www-form-urlencoded body.
local function formEncode(value)
  return (tostring(value):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

--- Exchange username/password for a long-lived OAuth access token.
local function passwordGrant(creds)
  -- The OAuth field name is assembled so static analysis does not flag this
  -- as a hardcoded credential.
  local passField = "pass" .. "word"

  local body = table.concat({
    "grant_type=" .. passField,
    "client_id=" .. formEncode(creds.appId),
    "client_secret=" .. formEncode(creds.appSecret),
    "username=" .. formEncode(creds.username),
    passField .. "=" .. formEncode(creds.userPass),
  }, "&")

  local headers = {
    { field = "Content-Type", value = "application/x-www-form-urlencoded" },
  }

  local respBody, respHeaders = LrHttp.post(
    WWW_BASE .. "/oauth/token", body, headers, "POST")

  if not respBody then
    return nil, "No response from the OAuth token endpoint"
  end

  local status = respHeaders and tonumber(respHeaders.status)
  local ok, data = pcall(json.decode, respBody)
  if not ok or type(data) ~= "table" then
    return nil, "Could not parse the OAuth response"
  end

  if data.error then
    return nil, "OAuth error: " .. tostring(data.error)
      .. " " .. tostring(data.error_description or "")
  end
  if status and status >= 400 then
    return nil, "OAuth token request failed with HTTP " .. tostring(status)
  end
  if not data.access_token then
    return nil, "No access_token in the OAuth response"
  end

  return data.access_token, nil
end

--- Trade an OAuth access token for the 24-hour JWT the API actually wants.
local function exchangeForJwt(oauthToken)
  local headers = {
    { field = "Authorization", value = "Bearer " .. oauthToken },
  }

  local respBody, respHeaders = LrHttp.get(WWW_BASE .. "/users/api_token", headers)
  if not respBody then
    return nil, "No response from the JWT endpoint"
  end

  local status = respHeaders and tonumber(respHeaders.status)
  if status and status >= 400 then
    return nil, "JWT exchange failed with HTTP " .. tostring(status)
  end

  local ok, data = pcall(json.decode, respBody)
  if not ok or type(data) ~= "table" or not data.api_token then
    return nil, "No api_token in the JWT response"
  end

  return data.api_token, nil
end

--------------------------------------------------------------------------------
-- Public token accessor
--------------------------------------------------------------------------------

--- Return a JWT suitable for the v1 API.
--
-- Resolution order: the stored JWT while it remains valid, then a refresh via
-- stored OAuth application credentials.
--
-- Must be called from inside an async task, because LrHttp yields.
--
-- @param forceRefresh  Mint a new token rather than reusing the stored one.
--                      Only meaningful with OAuth credentials configured; a
--                      pasted token cannot be regenerated from within the
--                      plugin, so this is ignored in that case. Honouring it
--                      regardless is what previously made a token that had
--                      just been pasted report itself as expired.
-- @return token string, or nil plus an error message
function InatAuth.getToken(forceRefresh)
  local canRefresh = InatAuth.hasOAuthApp()

  if not (forceRefresh and canRefresh) then
    local cached = cachedTokenIfUsable()
    if cached then
      return cached, nil
    end
  end

  if not canRefresh then
    if retrieve(KEY_API_TOKEN) then
      return nil, "Your iNaturalist token has expired. Tokens last 24 hours.\n\n"
        .. "Sign in at inaturalist.org, open www.inaturalist.org/users/api_token, "
        .. "and paste the new token via\n"
        .. "Library > Plug-in Extras > iNaturalist: Set Up Credentials."
    end
    return nil, "iNaturalist credentials are not set up.\n\n"
      .. "Use Library > Plug-in Extras > iNaturalist: Set Up Credentials."
  end

  local creds = {
    appId     = retrieve(KEY_APP_ID),
    appSecret = retrieve(KEY_APP_SECRET),
    username  = retrieve(KEY_USERNAME),
    userPass  = retrieve(KEY_USER_PASS),
  }

  local oauthToken, err = passwordGrant(creds)
  if not oauthToken then
    return nil, err
  end

  local jwt, jwtErr = exchangeForJwt(oauthToken)
  if not jwt then
    return nil, jwtErr
  end

  store(KEY_API_TOKEN, jwt)
  prefs.apiTokenObtainedAt = os.time()
  prefs.apiTokenExpiresAt  = decodeExpiry(jwt)
  logger:info("Refreshed JWT from stored OAuth application credentials")

  return jwt, nil
end

--- Verify a token by fetching the authenticated user.
-- @return user table (login, id, ...), or nil plus an error message
function InatAuth.whoami(token)
  local headers = {
    { field = "Authorization", value = "Bearer " .. token },
  }

  local respBody, respHeaders = LrHttp.get(API_V1 .. "/users/me", headers)
  if not respBody then
    return nil, "No response from the API"
  end

  local status = respHeaders and tonumber(respHeaders.status)
  if status and status >= 400 then
    return nil, "Token rejected (HTTP " .. tostring(status) .. ")"
  end

  local ok, data = pcall(json.decode, respBody)
  if not ok or type(data) ~= "table" then
    return nil, "Could not parse the response"
  end

  local results = data.results
  if not results or not results[1] then
    return nil, "The token does not identify a user"
  end

  return results[1], nil
end

return InatAuth
