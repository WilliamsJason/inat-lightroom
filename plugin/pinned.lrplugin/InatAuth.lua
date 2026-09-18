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

  One way to obtain one today: the user signs in at inaturalist.org, opens
  /users/api_token, and pastes the JWT into the setup dialog. It must be
  repeated every 24 hours. It stays because it needs no registered
  application, which makes it the fallback when anything about OAuth is
  unavailable.

  The better way, and now the default: the authorization code flow with PKCE,
  in InatOAuth.lua. The user signs in once in their browser, the plugin keeps
  a never-expiring OAuth access token, and this module quietly mints a new JWT
  from it whenever the old one ages out. Nobody pastes anything again.

  This module used to offer a third way -- an OAuth application using the
  password grant, which exchanged the user's iNaturalist username and password
  for a never-expiring access token and minted JWTs from it. It worked, and it
  is gone anyway. iNaturalist recommends against the password grant and
  specifically against it in publicly distributed applications, because it
  requires typing an account password into third-party software. The advice is
  the authorization code flow with PKCE, which sends the user to iNaturalist to
  sign in and never lets the plugin near the password.

  It was also impractical: the app id and secret are per-application, and
  iNaturalist reviews applications by hand, so every user would have needed
  their own approved application before the fields did anything. PKCE does not
  have that problem -- one approved application, no secret, and every user
  authenticating against it as themselves.

  URLHandler.lua and PluginUrls.lua receive the redirect that carries the
  authorization code back; that is what Info.lua's URLHandler entry is for.

  Secrets are held by LrPasswords, which is backed by the OS credential
  vault. Non-secret bookkeeping (when the JWT was obtained, which mode is in
  use) lives in LrPrefs.
--]]

local LrDialogs = import "LrDialogs"
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
local KEY_API_TOKEN    = "api_token"
local KEY_OAUTH_TOKEN  = "oauth_access_token"


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

function InatAuth.clear()
  store(KEY_API_TOKEN, "")
  store(KEY_OAUTH_TOKEN, "")
  prefs.apiTokenObtainedAt = nil
  prefs.apiTokenExpiresAt  = nil
  prefs.authMode = nil

  -- Any half-finished browser sign-in goes too. Clearing credentials is what
  -- someone does when they want the plugin to have forgotten them, and a
  -- verifier sitting in the vault waiting for a redirect is not that.
  local ok, InatOAuth = pcall(require, "InatOAuth")
  if ok and InatOAuth then
    pcall(InatOAuth.clearPending)
  end

  logger:info("Cleared stored credentials")
end

--------------------------------------------------------------------------------
-- OAuth
--------------------------------------------------------------------------------

--- Store the never-expiring OAuth access token from a browser sign-in.
--
-- This is not the token the API accepts. Its whole job is to sit in the vault
-- and mint 24-hour JWTs on demand, which is what makes browser sign-in a
-- one-time act rather than a daily one.
--
-- @return true, or false plus a reason
function InatAuth.storeOAuthToken(token)
  if type(token) ~= "string" or token == "" then
    return false, "iNaturalist returned an empty access token."
  end

  store(KEY_OAUTH_TOKEN, token)
  -- Any previously pasted JWT is now stale bookkeeping: the next getToken
  -- should mint a fresh one rather than trust what the old mode left behind.
  store(KEY_API_TOKEN, "")
  prefs.apiTokenObtainedAt = nil
  prefs.apiTokenExpiresAt  = nil
  prefs.authMode = "oauth"

  logger:info("Stored an OAuth access token")
  return true, nil
end

--- Whether the plugin is signed in through the browser.
function InatAuth.isSignedIn()
  return retrieve(KEY_OAUTH_TOKEN) ~= nil
end

--- Exchange the stored OAuth token for a fresh 24-hour JWT.
--
-- Must be called from inside a task: LrHttp.get yields.
--
-- The endpoint is on www.inaturalist.org rather than the API host, and it is
-- the one place a bare OAuth bearer token is the right thing to send.
--
-- @return jwt string, or nil plus a reason
local function refreshJwtFromOAuth()
  local oauthToken = retrieve(KEY_OAUTH_TOKEN)
  if not oauthToken then
    return nil, "Not signed in to iNaturalist."
  end

  local headers = {
    { field = "Authorization", value = "Bearer " .. oauthToken },
    { field = "Accept",        value = "application/json" },
  }

  local respBody, respHeaders = LrHttp.get(WWW_BASE .. "/users/api_token", headers)
  if not respBody then
    return nil, "Could not reach iNaturalist to refresh the API token."
  end

  local status = respHeaders and tonumber(respHeaders.status)
  if status and status >= 400 then
    -- 401 here means the access token has been revoked -- from iNaturalist's
    -- account settings, or by the application being deleted. There is no way
    -- back from the plugin's side, so say what actually fixes it.
    if status == 401 then
      return nil, "iNaturalist has rejected this plugin's access.\n\n"
        .. "That usually means access was revoked on the website. Open\n"
        .. "File > Plug-in Extras > Pinned Settings… and sign in again."
    end
    return nil, "iNaturalist refused to issue an API token (HTTP "
      .. tostring(status) .. ")."
  end

  local ok, data = pcall(json.decode, respBody)
  if not ok or type(data) ~= "table" or not data.api_token then
    return nil, "iNaturalist's reply contained no API token."
  end

  local token = data.api_token
  store(KEY_API_TOKEN, token)
  prefs.apiTokenObtainedAt = os.time()
  prefs.apiTokenExpiresAt  = decodeExpiry(token)
  prefs.authMode = "oauth"

  logger:info("Refreshed the API token from the stored OAuth token")
  return token, nil
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
-- Public token accessor
--------------------------------------------------------------------------------

--- Return a JWT suitable for the v1 API.
--
-- Two ways to have one, and they behave differently:
--
--   * Signed in through the browser. The stored OAuth token never expires, so
--     an expired JWT is refreshed silently and the user is never asked for
--     anything. This is the branch the module was always written around.
--   * A pasted token. There is nothing to refresh from, so an expired one can
--     only be reported.
--
-- Must be called from inside an async task, because LrHttp yields.
--
-- @param forceRefresh  Mint a new JWT even if the cached one looks usable.
--                      Honoured only when signed in through the browser: with
--                      a pasted token there is nothing to refresh from, and
--                      honouring it there is what previously made a token that
--                      had just been pasted report itself as expired. Callers
--                      pass it after saving credentials, so it has to be
--                      harmless rather than an error.
-- @return token string, or nil plus an error message
function InatAuth.getToken(forceRefresh)
  local signedIn = InatAuth.isSignedIn()

  if not (forceRefresh and signedIn) then
    local cached = cachedTokenIfUsable()
    if cached then
      return cached, nil
    end
  end

  if signedIn then
    return refreshJwtFromOAuth()
  end

  if retrieve(KEY_API_TOKEN) then
    return nil, "Your iNaturalist token has expired. Tokens last 24 hours.\n\n"
      .. "Sign in at inaturalist.org, open www.inaturalist.org/users/api_token, "
      .. "and paste the new token via\n"
      .. "File > Plug-in Extras > Pinned Settings…\n\n"
      .. "Or use Sign In with iNaturalist there once, and this stops happening."
  end

  return nil, "iNaturalist credentials are not set up.\n\n"
    .. "Use File > Plug-in Extras > Pinned Settings…."
end

--- A one-line summary of why a token could not be had.
--
-- Read from the stored state rather than from the caller's message, because
-- the messages are written for a dialog that is no longer shown and end with
-- directions to the very window that is about to open.
local function setupNotice()
  if retrieve(KEY_API_TOKEN) then
    return "Pinned's iNaturalist token has expired."
  end
  return "Pinned needs your iNaturalist credentials before it can do that."
end

--- Whether the settings window is the answer to this failure.
--
-- It is when there is nothing stored that the plugin can renew on its own: no
-- credentials at all, or a pasted token that has run out. It is not when the
-- user is signed in through the browser, because then the plugin renews its
-- own token and a failure is the network, a revocation, or iNaturalist being
-- down -- none of which are fixed by the window, and the first of which comes
-- and goes. Yanking the settings open over a dropped connection teaches the
-- user to close it without reading.
local function setupWouldHelp()
  return not InatAuth.isSignedIn()
end

--- Send the user to the place that fixes missing or expired credentials.
--
-- One route for every feature that needs a token, because it is one problem
-- with one fix, and it is not about the feature that happened to hit it. Four
-- call sites had drifted into three different titles and two severities, so
-- the same sentence looked like a different fault depending on which button
-- had been pressed.
--
-- It used to be a warning dialog whose whole content was directions to
-- File > Plug-in Extras > Pinned Settings…. Reading out a menu path is a
-- worse version of opening the window, so when the window is the answer it
-- opens the window -- on the Account tab, with the reason above the fields
-- that answer it. The caller's message is kept for the log, which is where
-- the detail is still wanted, and is still shown when the window is not the
-- answer or cannot be opened.
--
-- Required lazily: SettingsDialog requires this module at load time, so a
-- require at the top of the file would be circular.
function InatAuth.reportMissingCredentials(message)
  local fallback = message or "iNaturalist credentials are not set up.\n\n"
    .. "Use File > Plug-in Extras > Pinned Settings…."

  logger:info("No usable token: " .. tostring(fallback))

  local ok, opened = pcall(function()
    if not setupWouldHelp() then return false end

    local SettingsDialog = require "SettingsDialog"

    -- Already there. Opening a second copy of the window on top of the one
    -- the user is looking at would hide the fields that fix this.
    if SettingsDialog.isShowing() then return false end

    SettingsDialog.show({ tab = "account", notice = setupNotice() })
    return true
  end)

  if not ok then
    logger:error("Could not open settings: " .. tostring(opened))
  end

  -- Either the window was the wrong answer, or opening it failed -- and a
  -- feature that stops with nothing shown at all reads as one that quietly
  -- did nothing.
  if not ok or not opened then
    LrDialogs.message("Pinned", fallback, "warning")
  end
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
