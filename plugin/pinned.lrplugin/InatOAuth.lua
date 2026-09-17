--[[
  InatOAuth.lua
  -------------
  The authorization code flow with PKCE: the browser sign-in that replaces
  pasting a 24-hour token every morning.

  ## The shape of it

      1. generateChallenge()  makes a verifier, keeps it, derives a challenge
      2. startSignIn()        opens iNaturalist in the browser
      3. user signs in there; the plugin never sees the password
      4. iNaturalist redirects to lightroom://<plugin id>/authorization-redirect?code=...
      5. Lightroom hands that to URLHandler.lua, which calls handleRedirect()
      6. exchangeCode()       trades code + verifier for an OAuth access token
      7. InatAuth             stores it and mints 24-hour JWTs from it forever

  Step 6 sends no client secret, which is the entire point of PKCE and the
  reason a plugin whose Lua anyone can read is allowed to do this at all. The
  verifier proves the client that redeems the code is the client that started
  the flow; a secret would prove only that the secret had leaked.

  ## Why the verifier is stored rather than held in memory

  rcloran's lr-inaturalist-publish keeps its verifier in the publish dialog's
  property table and tells the user not to close the window. That is simpler,
  and it loses the sign-in if the window closes, if Lightroom is restarted
  while the browser is open, or if the user goes to make a cup of tea and
  iNaturalist asks them to confirm their email first.

  So it goes in LrPasswords with a timestamp in prefs. It is a single-use
  secret with a short life: cleared the moment it is redeemed, and refused
  after PENDING_TTL_SECONDS whether or not it was used. The cost is a secret
  briefly at rest in the OS credential vault, which is where the token it
  becomes is going to live anyway.

  ## Entropy

  The verifier has to be unguessable by anything that can see the challenge --
  in practice, another application on the same machine that registered the
  same URL scheme and is racing for the redirect.

  `LrUUID.generateUUID` is in substrate.dll, the plugin loader itself, so it is
  always there; the same plugin's Windows helper never has to be shelled out
  to. rcloran runs `cscript uuid.vbs` and reads the result back through a temp
  file, then XORs it with a Lua PRNG precisely because that file is
  interceptable. Nothing here leaves the process.

  Adobe does not say how `generateUUID` is seeded, so it is not trusted alone:
  several UUIDs are mixed with the clock, a monotonic timer, a table address
  from the Lua allocator and the PRNG, and the whole lot is run through
  SHA-256. The result is no weaker than the best single input, which is the
  only guarantee available without a documented CSPRNG.

  The digest is used as the verifier directly. 64 lowercase hex characters sits
  inside RFC 7636's 43-128, and hex is entirely within its unreserved
  character set, so nothing needs encoding and no base64 step can get it wrong.
--]]

local LrDialogs = import "LrDialogs"
local LrHttp    = import "LrHttp"
local LrPasswords = import "LrPasswords"
local LrPrefs   = import "LrPrefs"
local LrTasks   = import "LrTasks"

local json = require "json"

local PluginUrls = require "PluginUrls"
local Sha256     = require "Sha256"
local logger     = require "Log"

local prefs = LrPrefs.prefsForPlugin()

local WWW_BASE      = "https://www.inaturalist.org"
local AUTHORIZE_URL = WWW_BASE .. "/oauth/authorize"
local TOKEN_URL     = WWW_BASE .. "/oauth/token"

--- The registered iNaturalist application.
--
-- Public by design. A PKCE client is not confidential: iNaturalist's
-- application form has a "Confidential" checkbox and this application has it
-- unchecked, so there is no secret, and the token exchange would reject one if
-- there were. Anyone can read this out of the plugin and that is fine -- it
-- names the application, it does not authorise anything. Every user still
-- signs in as themselves and gets their own token.
local CLIENT_ID = "y3sOmdF1q07gmGEDDH9vttdZsaWrWf9cGGvjw1Oa3KA"

--- Where iNaturalist sends the browser back to.
--
-- Must match what is registered on the application character for character;
-- Doorkeeper compares the whole string. It is built from the toolkit
-- identifier rather than written out, so the two cannot drift apart -- see
-- the warning on LrToolkitIdentifier in Info.lua.
local REDIRECT_ACTION = "authorization-redirect"

-- LrPasswords is already plugin-scoped, so a bare key is enough.
local KEY_PKCE_VERIFIER = "pkce_verifier"

--- How long a started sign-in stays redeemable.
--
-- Generous on purpose. The window covers signing in, possibly creating an
-- account, confirming an email and reading the authorization screen, and the
-- failure it guards against -- a verifier sitting around forever -- is mild.
-- Doorkeeper expires the authorization code itself well inside this.
local PENDING_TTL_SECONDS = 30 * 60

local InatOAuth = {}

InatOAuth.CLIENT_ID = CLIENT_ID

--- The exact redirect URI, for registering and for the token exchange.
function InatOAuth.redirectUri()
  return PluginUrls.urlFor(REDIRECT_ACTION)
end

InatOAuth.REDIRECT_ACTION = REDIRECT_ACTION

--------------------------------------------------------------------------------
-- Encoding
--------------------------------------------------------------------------------

--- Percent-encode one value for a query string or a form body.
--
-- The unreserved set of RFC 3986, so "~" and "." survive. Spaces become %20
-- rather than "+": correct in a query string, and accepted in a form body.
local function urlEncode(value)
  return (tostring(value):gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

InatOAuth.urlEncode = urlEncode

--- Build "a=1&b=2" from a table, in a fixed order.
--
-- Sorted by key because an unordered pairs() walk makes the request
-- unpredictable, which is miserable to assert on in a test and no help at all
-- when reading a log.
local function formEncode(params)
  local keys = {}
  for key in pairs(params) do keys[#keys + 1] = key end
  table.sort(keys)

  local parts = {}
  for _, key in ipairs(keys) do
    parts[#parts + 1] = urlEncode(key) .. "=" .. urlEncode(params[key])
  end
  return table.concat(parts, "&")
end

InatOAuth.formEncode = formEncode

--------------------------------------------------------------------------------
-- The verifier
--------------------------------------------------------------------------------

local seeded = false

--- Gather whatever entropy this process can reach, as one string.
local function entropy()
  local parts = {}

  local ok, LrUUID = pcall(import, "LrUUID")
  if ok and LrUUID and type(LrUUID.generateUUID) == "function" then
    for _ = 1, 4 do
      local got, uuid = pcall(LrUUID.generateUUID)
      if got and uuid then parts[#parts + 1] = tostring(uuid) end
    end
  end

  if not seeded then
    -- os.clock has sub-second resolution where os.time does not, so the two
    -- together separate two sign-ins started in the same second.
    math.randomseed(os.time() + math.floor((os.clock() * 1000000) % 1000000))
    seeded = true
  end

  parts[#parts + 1] = tostring(os.time())
  parts[#parts + 1] = tostring(os.clock())
  -- The address the Lua allocator happened to hand out, which varies with
  -- heap layout. Weak on its own, free, and independent of the clock.
  parts[#parts + 1] = tostring({})
  for _ = 1, 4 do
    parts[#parts + 1] = tostring(math.random(0, 2147483647))
  end

  return table.concat(parts, "|")
end

--- Make a fresh code verifier.
-- @return 64 hex characters, or nil plus a reason
function InatOAuth.generateVerifier()
  local verifier, err = Sha256.hex(entropy())
  if not verifier then return nil, err end
  return verifier, nil
end

--- Derive the S256 code challenge for a verifier.
-- @return unpadded base64url of the SHA-256 digest, or nil plus a reason
function InatOAuth.challengeFor(verifier)
  local digest, err = Sha256.hex(verifier)
  if not digest then return nil, err end

  local challenge = Sha256.base64urlFromHex(digest)
  if not challenge then
    return nil, "Could not encode the PKCE challenge."
  end
  return challenge, nil
end

--------------------------------------------------------------------------------
-- Pending sign-in state
--------------------------------------------------------------------------------

local function rememberVerifier(verifier)
  LrPasswords.store(KEY_PKCE_VERIFIER, verifier)
  prefs.pkceStartedAt = os.time()
end

--- The verifier for the sign-in in progress, if one is still redeemable.
function InatOAuth.pendingVerifier()
  local verifier = LrPasswords.retrieve(KEY_PKCE_VERIFIER)
  if not verifier or verifier == "" then return nil end

  local startedAt = prefs.pkceStartedAt
  if not startedAt or (os.time() - startedAt) > PENDING_TTL_SECONDS then
    return nil
  end

  return verifier
end

--- Forget any sign-in in progress.
function InatOAuth.clearPending()
  LrPasswords.store(KEY_PKCE_VERIFIER, "")
  prefs.pkceStartedAt = nil
end

--------------------------------------------------------------------------------
-- Starting the flow
--------------------------------------------------------------------------------

--- The URL that begins authorization.
-- @return url string, or nil plus a reason
function InatOAuth.authorizeUrl(challenge)
  local params = {
    client_id             = CLIENT_ID,
    redirect_uri          = InatOAuth.redirectUri(),
    response_type         = "code",
    code_challenge        = challenge,
    code_challenge_method = "S256",
  }
  return AUTHORIZE_URL .. "?" .. formEncode(params)
end

--- Begin a sign-in: make a verifier, keep it, open the browser.
--
-- Safe to call when a sign-in is already pending; the new verifier replaces
-- the old one, because the only way to have two in flight is that the first
-- was abandoned.
--
-- @return true, or false plus a reason fit to show a user
function InatOAuth.startSignIn()
  local usable, why = Sha256.available()
  if not usable then
    return false, why
  end

  local verifier, verifierErr = InatOAuth.generateVerifier()
  if not verifier then return false, verifierErr end

  local challenge, challengeErr = InatOAuth.challengeFor(verifier)
  if not challenge then return false, challengeErr end

  rememberVerifier(verifier)

  local url = InatOAuth.authorizeUrl(challenge)
  logger:info("Starting OAuth sign-in")
  LrHttp.openUrlInBrowser(url)
  return true, nil
end

--------------------------------------------------------------------------------
-- Finishing the flow
--------------------------------------------------------------------------------

--- Trade an authorization code for an OAuth access token.
--
-- Must be called from inside a task: LrHttp.post yields.
--
-- No client_secret, deliberately. The code_verifier is what proves this is
-- the same client that started the flow.
--
-- @return access token string, or nil plus a reason
function InatOAuth.exchangeCode(code, verifier)
  local body = formEncode {
    client_id     = CLIENT_ID,
    code          = code,
    code_verifier = verifier,
    grant_type    = "authorization_code",
    redirect_uri  = InatOAuth.redirectUri(),
  }

  local headers = {
    { field = "Content-Type", value = "application/x-www-form-urlencoded" },
    { field = "Accept",       value = "application/json" },
  }

  local respBody, respHeaders = LrHttp.post(TOKEN_URL, body, headers)

  if not respBody then
    local message = respHeaders and respHeaders.error
      and respHeaders.error.name
    return nil, "Could not reach iNaturalist to finish signing in."
      .. (message and ("\n\n" .. tostring(message)) or "")
  end

  local status = respHeaders and tonumber(respHeaders.status)
  local ok, data = pcall(json.decode, respBody)

  if status and status >= 400 then
    -- Doorkeeper answers with a JSON body naming the fault, and those names
    -- are worth surfacing: "invalid_grant" is almost always a code that was
    -- already used or has expired, which has an obvious fix.
    local detail = ok and type(data) == "table"
      and (data.error_description or data.error)
    return nil, "iNaturalist refused the sign-in (HTTP " .. tostring(status)
      .. ")." .. (detail and ("\n\n" .. tostring(detail)) or "")
  end

  if not ok or type(data) ~= "table" or not data.access_token then
    return nil, "iNaturalist's reply did not contain an access token."
  end

  return data.access_token, nil
end

--------------------------------------------------------------------------------
-- The redirect
--------------------------------------------------------------------------------

--- Called by URLHandler when the browser comes back.
--
-- Takes the already-parsed query parameters rather than the URL, so that URL
-- parsing lives in one place and this can be tested with a table.
--
-- Runs the exchange in a task because it is network work, and reports the
-- outcome itself: there may well be no plugin window open by now.
--
-- @param params  decoded query parameters from the redirect
-- @param onComplete  optional function(ok, loginOrError) called after the
--                    exchange. URLHandler has no dialog to refresh, so it
--                    passes nothing and the module-level InatOAuth.onComplete
--                    is used instead -- that is how a settings window still on
--                    screen updates itself without the URL handler having to
--                    know it exists.
function InatOAuth.handleRedirect(params, onComplete)
  params = params or {}
  onComplete = onComplete or InatOAuth.onComplete

  local function finish(ok, detail)
    if onComplete then
      local called, err = pcall(onComplete, ok, detail)
      if not called then
        logger:warn("Sign-in completion handler failed: " .. tostring(err))
      end
    end
  end

  if params.error then
    -- The user pressed Reject, or iNaturalist declined. Not a fault, so it is
    -- reported as information rather than an error.
    InatOAuth.clearPending()
    local detail = params.error_description or params.error
    logger:info("OAuth sign-in declined: " .. tostring(detail))
    LrDialogs.message("Pinned",
      "Sign-in was not completed.\n\n" .. tostring(detail), "info")
    finish(false, tostring(detail))
    return
  end

  local code = params.code
  if not code or code == "" then
    logger:warn("Authorization redirect carried no code")
    LrDialogs.message("Pinned",
      "iNaturalist sent this plugin back without an authorization code.\n\n"
        .. "Try signing in again from Pinned Settings.", "warning")
    finish(false, "No authorization code.")
    return
  end

  local verifier = InatOAuth.pendingVerifier()
  if not verifier then
    -- Either nothing started this, or it started too long ago. Both are worth
    -- refusing: redeeming a code against a verifier we cannot vouch for is
    -- exactly what PKCE exists to prevent.
    logger:warn("Authorization redirect with no sign-in in progress")
    LrDialogs.message("Pinned",
      "No sign-in is in progress, or it was started too long ago.\n\n"
        .. "Open File > Plug-in Extras > Pinned Settings… and press "
        .. "Sign In with iNaturalist again.", "warning")
    finish(false, "No sign-in in progress.")
    return
  end

  LrTasks.startAsyncTask(function()
    local InatAuth = require "InatAuth"

    local token, err = InatOAuth.exchangeCode(code, verifier)

    -- Single use, whatever happened. A verifier that has been sent once is
    -- spent, and keeping it would only let a replay find it.
    InatOAuth.clearPending()

    if not token then
      logger:error("OAuth exchange failed: " .. tostring(err))
      LrDialogs.message("Pinned",
        "Could not finish signing in.\n\n" .. tostring(err), "critical")
      finish(false, tostring(err))
      return
    end

    local stored, storeErr = InatAuth.storeOAuthToken(token)
    if not stored then
      LrDialogs.message("Pinned",
        "Signed in, but the credentials could not be saved.\n\n"
          .. tostring(storeErr), "critical")
      finish(false, tostring(storeErr))
      return
    end

    -- Prove it end to end before saying so. An access token that cannot be
    -- turned into a JWT is not a working sign-in, and finding that out now is
    -- much kinder than finding out during an upload.
    local jwt, jwtErr = InatAuth.getToken()
    if not jwt then
      LrDialogs.message("Pinned",
        "Signed in, but could not get an API token.\n\n" .. tostring(jwtErr),
        "critical")
      finish(false, tostring(jwtErr))
      return
    end

    local user, userErr = InatAuth.whoami(jwt)
    if not user then
      LrDialogs.message("Pinned",
        "Signed in, but iNaturalist did not recognise the token.\n\n"
          .. tostring(userErr), "critical")
      finish(false, tostring(userErr))
      return
    end

    logger:info("OAuth sign-in complete for " .. tostring(user.login))
    LrDialogs.message("Pinned",
      "Signed in as " .. tostring(user.login) .. ".\n\n"
        .. "Pinned will keep itself signed in from now on.", "info")
    finish(true, tostring(user.login))
  end)
end

return InatOAuth
