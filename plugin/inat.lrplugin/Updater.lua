--[[
  Updater.lua
  -----------
  Finding out whether a newer plugin has been released. Nothing here changes
  anything on disk; installing is UpdateInstall's job, and keeping the two apart
  is what lets the check run unattended at startup.

  Lightroom has no updater. There is no manifest key for a version feed and no
  hook that offers one, which was checked the same way the rest of this plugin's
  SDK claims were: by looking. Every plugin that updates itself does what this
  one does -- read a release feed, compare versions, download an archive.

  The feed is GitHub's own:

      https://api.github.com/repos/<owner>/<repo>/releases/latest

  which is public, unauthenticated, and rate limited per IP at 60 requests an
  hour. That is far beyond a once-a-day check, but it is a shared limit on a
  shared address, so a failure to reach it is treated as "do not know" and never
  as "no update".

  Two things about that endpoint matter:

    1. It excludes pre-releases and drafts. That is why Info.lua's display
       string may not say "pre-release": a release either exists here for
       everyone or it does not exist at all.

    2. It returns the newest release by date, not by version number. Retagging
       an old commit would therefore offer a downgrade, so the comparison below
       is numeric and one-directional rather than "different from mine".
--]]

local LrHttp = import "LrHttp"

local json   = require "json"
local logger = require "Log"

local Updater = {}

Updater.OWNER = "WilliamsJason"
Updater.REPO  = "inat-lightroom"

Updater.LATEST_RELEASE_URL =
  "https://api.github.com/repos/" .. Updater.OWNER .. "/" .. Updater.REPO ..
  "/releases/latest"

Updater.RELEASES_PAGE_URL =
  "https://github.com/" .. Updater.OWNER .. "/" .. Updater.REPO .. "/releases"

--- Every asset URL must begin with this, or it is not ours.
--
-- The release JSON is fetched over TLS from GitHub, so a hostile
-- browser_download_url means GitHub is already compromised. This is not
-- defence against that; it is defence against pointing the downloader at some
-- other host because a field was renamed, a redirect was followed, or a future
-- change here read the wrong key.
Updater.ASSET_URL_PREFIX =
  "https://github.com/" .. Updater.OWNER .. "/" .. Updater.REPO ..
  "/releases/download/"

Updater.CHECKSUM_ASSET = "SHA256SUMS"

local USER_AGENT = "inat-lightroom/" ..
  "updater (+https://github.com/WilliamsJason/inat-lightroom)"

--------------------------------------------------------------------------------
-- Versions
--------------------------------------------------------------------------------

--- Turn "v0.2.0", "0.2.0" or "0.2" into { major, minor, revision }.
-- @return a table, or nil when the string is not a version at all
function Updater.parseVersion(text)
  if type(text) ~= "string" then return nil end

  local trimmed = text:match("^%s*(.-)%s*$"):gsub("^[vV]", "")

  local major, minor, revision = trimmed:match("^(%d+)%.(%d+)%.(%d+)")
  if not major then
    major, minor = trimmed:match("^(%d+)%.(%d+)")
    revision = "0"
  end
  if not major then return nil end

  return {
    major    = tonumber(major),
    minor    = tonumber(minor),
    revision = tonumber(revision),
  }
end

--- Render a version table as "0.2.0".
function Updater.versionString(version)
  if not version then return "unknown" end
  return string.format("%d.%d.%d",
    version.major or 0, version.minor or 0, version.revision or 0)
end

--- True when `candidate` is a strictly higher version than `installed`.
--
-- Numeric, field by field. Comparing the strings instead would make 0.10.0
-- older than 0.9.0, which is the classic way to strand everyone on the release
-- where the minor number reached double figures.
function Updater.isNewer(candidate, installed)
  if not candidate then return false end
  if not installed then return true end

  local fields = { "major", "minor", "revision" }
  for _, field in ipairs(fields) do
    local left  = candidate[field] or 0
    local right = installed[field] or 0
    if left > right then return true end
    if left < right then return false end
  end

  return false
end

--- The version of the plugin that is running.
--
-- Read from Info.lua rather than repeated here. Lightroom reads that file
-- itself before any plugin code runs, and requiring it again simply evaluates
-- a table constructor; there is no other way to reach VERSION, because the
-- SDK's _PLUGIN object carries id, path and enabled but no version.
function Updater.currentVersion()
  local ok, info = pcall(require, "Info")
  if not ok or type(info) ~= "table" or type(info.VERSION) ~= "table" then
    logger:warn("Updater: could not read VERSION out of Info.lua")
    return nil
  end
  return {
    major    = info.VERSION.major or 0,
    minor    = info.VERSION.minor or 0,
    revision = info.VERSION.revision or 0,
    display  = info.VERSION.display,
  }
end

--------------------------------------------------------------------------------
-- Reading a release
--------------------------------------------------------------------------------

--- The plugin archive and the checksum file from a release's asset list.
-- @return assetUrl, sumsUrl, assetName -- any of which may be nil
function Updater.pickAssets(release)
  if type(release) ~= "table" or type(release.assets) ~= "table" then
    return nil, nil, nil
  end

  local assetUrl, sumsUrl, assetName

  for _, asset in ipairs(release.assets) do
    local name = asset.name
    local url  = asset.browser_download_url

    if type(name) == "string" and type(url) == "string"
       and url:sub(1, #Updater.ASSET_URL_PREFIX) == Updater.ASSET_URL_PREFIX then
      if name == Updater.CHECKSUM_ASSET then
        sumsUrl = url
      elseif name:match("^inat%-lightroom%-.+%.zip$") then
        assetUrl  = url
        assetName = name
      end
    end
  end

  return assetUrl, sumsUrl, assetName
end

--- The SHA-256 recorded for one file in a SHA256SUMS body.
--
-- The format is what sha256sum writes: a hex digest, whitespace, an optional
-- binary marker, then the name. Matching the name exactly matters -- a release
-- carrying several archives must not have one verified against another's hash.
function Updater.hashFor(sumsText, assetName)
  if type(sumsText) ~= "string" or type(assetName) ~= "string" then
    return nil
  end

  for line in (sumsText .. "\n"):gmatch("([^\n]*)\n") do
    local digest, name = line:match("^(%x+)%s+%*?(.+)$")
    if digest and name == assetName and #digest == 64 then
      return digest:lower()
    end
  end

  return nil
end

--------------------------------------------------------------------------------
-- Asking GitHub
--------------------------------------------------------------------------------

local function get(url)
  local body, headers = LrHttp.get(url, {
    { field = "Accept",     value = "application/vnd.github+json" },
    { field = "User-Agent", value = USER_AGENT },
  })

  if not body then
    local detail = "no response"
    if type(headers) == "table" and type(headers.error) == "table" then
      detail = tostring(headers.error.name or "unknown error")
    end
    return nil, detail
  end

  -- Read the way InatAPI reads it: `respHeaders.status` without asserting the
  -- table's type. LrHttp hands back a Lua table, but a status that arrives as
  -- a string still has to compare as a number, and a guard that is too clever
  -- here silently stops noticing failures at all.
  local status = headers and tonumber(headers.status)
  if status and status ~= 200 then
    -- 404 is the ordinary answer for a repository that has never published a
    -- release, so it is reported as plainly as the rest.
    return nil, "GitHub replied " .. tostring(status)
  end

  return body
end

--- Look up the newest release.
--
-- Must be called from inside an async task; LrHttp yields.
--
-- @return a table describing the release, or nil plus a message. The table is
--   returned whether or not it is newer than what is installed -- deciding
--   that is the caller's business, and the UI wants the version either way.
function Updater.latestRelease()
  local body, err = get(Updater.LATEST_RELEASE_URL)
  if not body then return nil, err end

  local ok, release = pcall(json.decode, body)
  if not ok or type(release) ~= "table" then
    return nil, "GitHub's answer was not JSON"
  end

  local version = Updater.parseVersion(release.tag_name)
  if not version then
    return nil, "release " .. tostring(release.tag_name) ..
      " is not named like a version"
  end

  local assetUrl, sumsUrl, assetName = Updater.pickAssets(release)

  return {
    version   = version,
    tag       = release.tag_name,
    notes     = release.body or "",
    pageUrl   = release.html_url or Updater.RELEASES_PAGE_URL,
    assetUrl  = assetUrl,
    assetName = assetName,
    sumsUrl   = sumsUrl,
  }
end

--- Fetch and parse the checksum file for a release.
-- @return the hex digest for the release's archive, or nil plus a message
function Updater.expectedHash(release)
  if not release or not release.sumsUrl or not release.assetName then
    return nil, "the release has no checksum file"
  end

  local body, err = get(release.sumsUrl)
  if not body then return nil, err end

  local digest = Updater.hashFor(body, release.assetName)
  if not digest then
    return nil, "no checksum listed for " .. release.assetName
  end

  return digest
end

--- The whole check: what is installed, what is published, and whether to care.
--
-- @return a table { current, latest, isNewer, canInstall }, or nil plus a
--   message. canInstall is false for a release that has no archive attached --
--   which happens if a release is published by hand rather than by the
--   workflow -- so the UI can offer the release page instead of a dead button.
function Updater.check()
  local current = Updater.currentVersion()

  local release, err = Updater.latestRelease()
  if not release then return nil, err end

  local newer = Updater.isNewer(release.version, current)

  logger:info(string.format(
    "Updater: installed %s, published %s%s",
    Updater.versionString(current),
    Updater.versionString(release.version),
    newer and " (update available)" or ""))

  return {
    current    = current,
    latest     = release,
    isNewer    = newer,
    canInstall = newer and release.assetUrl ~= nil and release.sumsUrl ~= nil,
  }
end

return Updater
