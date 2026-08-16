--[[
  ThumbCache.lua
  --------------
  Getting the iNaturalist side of a review row onto the screen.

  f:picture draws a file, so every iNaturalist thumbnail has to be downloaded
  before it can be shown. That is about 100ms each, measured, which is nothing
  for one and a page-turn's worth of waiting for twenty-five.

  So the cache exists to make the second look at a page free. A user reviewing
  a few hundred matches pages back and forth -- to re-check one they were not
  sure about, or because they overshot -- and paying for those downloads again
  every time would make the dialog feel broken well before it made it slow.

  Everything lands in one folder that is deleted when the review ends. These
  are 200px JPEGs of the user's own photos, already on their disk in full
  resolution; keeping them after the dialog closes would be litter, not a
  cache.
--]]

local LrFileUtils   = import "LrFileUtils"
local LrHttp        = import "LrHttp"
local LrPathUtils   = import "LrPathUtils"
local LrTasks       = import "LrTasks"

local Logger = require "Log"
local logger = Logger

local ThumbCache = {}
ThumbCache.__index = ThumbCache

--- Which of iNaturalist's fixed sizes to ask for.
--
-- The API hands back the 75px `square` URL. That is too small to tell two
-- similar frames apart, which is the entire job here. The sizes are the same
-- file with a different name -- square, small, medium, large, original -- so
-- the bigger one is a substitution, not another request to find it.
--
-- `medium` is 500px on the long edge and around 40KB. `small` (240px) would
-- halve the transfer but is soft when shown at 200px on a high-DPI display,
-- and this image is being used as evidence.
ThumbCache.SIZE = "medium"

--- Rewrite a photo URL to the size we want.
--
-- Returns nil for anything that does not look like an iNaturalist photo URL,
-- rather than guessing: a URL we do not recognise is more likely a change in
-- the API than a size we can substitute into.
function ThumbCache.sizedUrl(url, size)
  if type(url) ~= "string" or url == "" then return nil end

  local base, extension =
    url:match("^(.*/)[%w_]+%.(%a+)$")
  if not base then return nil end

  return base .. (size or ThumbCache.SIZE) .. "." .. extension
end

--- The first photo of an observation, at review size.
function ThumbCache.observationUrl(observation)
  local photos = observation and observation.photos
  if type(photos) ~= "table" then return nil end

  local first = photos[1]
  if type(first) ~= "table" then return nil end

  return ThumbCache.sizedUrl(first.url)
end

--- Write bytes to a path.
--
-- A seam, because the SDK has no "write these bytes to this file" and io is
-- the only way -- which makes the one interesting failure here, a folder that
-- cannot be written to, impossible to provoke in a test otherwise.
function ThumbCache.writeFile(path, bytes)
  local handle, err = io.open(path, "wb")
  if not handle then return false, err end

  handle:write(bytes)
  handle:close()
  return true
end

--- A new cache, backed by its own folder under the system temp directory.
function ThumbCache.new(options)
  options = options or {}

  local folder = options.folder
  if not folder then
    folder = LrPathUtils.child(LrPathUtils.getStandardFilePath("temp"),
      "inat-review-thumbs")
  end

  return setmetatable({
    folder      = folder,
    files       = {},   -- url -> path on disk, or false for "tried and failed"
    placeholder = options.placeholder,
    http        = options.http or LrHttp,
    fs          = options.fs or LrFileUtils,
    write       = options.write or ThumbCache.writeFile,
  }, ThumbCache)
end

--- Where a URL's bytes would live.
--
-- Named after the photo id in the URL rather than a hash of it, so that a
-- folder left behind by a crash can be read by a human.
function ThumbCache:pathFor(url)
  local id = url:match("/photos/(%d+)/") or tostring(#url)
  local extension = url:match("%.(%a+)$") or "jpg"
  local size = url:match("/(%a+)%.%a+$") or "image"

  return LrPathUtils.child(self.folder,
    string.format("%s-%s.%s", id, size, extension))
end

--- Fetch one thumbnail, unless it is already here.
--
-- @return a path to show. Never nil: a failure yields the placeholder, because
--         the widget needs a file either way and an empty row would say less
--         than a tile that says "no photo".
function ThumbCache:fetch(url)
  if not url then return self.placeholder end

  local known = self.files[url]
  if known ~= nil then
    return known or self.placeholder
  end

  local body, headers = self.http.get(url)
  local status = headers and headers.status

  if not body or body == "" or (status and status ~= 200) then
    logger:warnf("thumbnail %s failed (status %s, %d bytes)",
      tostring(url), tostring(status), body and #body or 0)
    self.files[url] = false
    return self.placeholder
  end

  local path = self:pathFor(url)

  local wrote, err = self.write(path, body)
  if not wrote then
    logger:warnf("could not write thumbnail to %s: %s", path, tostring(err))
    self.files[url] = false
    return self.placeholder
  end

  self.files[url] = path
  return path
end

--- Make sure the folder exists before anything tries to write into it.
function ThumbCache:prepare()
  if not self.fs.exists(self.folder) then
    self.fs.createAllDirectories(self.folder)
  end
end

--- Fetch a run of URLs, reporting each one as it lands.
--
-- MUST be called from inside a task: this yields, once per download.
--
-- `onReady(index, path)` is called per URL rather than once at the end so the
-- page fills in as it arrives. Twenty-five images appearing together after
-- 2.6 seconds of nothing looks like a stall; the same images appearing one at
-- a time looks like loading.
--
-- `shouldStop()` is checked between downloads so that turning the page again
-- abandons the previous page's remaining downloads instead of making the user
-- wait out a page they have already left.
function ThumbCache:fetchAll(urls, onReady, shouldStop)
  self:prepare()

  for index, url in pairs(urls or {}) do
    if shouldStop and shouldStop() then return false end

    local ok, path = LrTasks.pcall(function() return self:fetch(url) end)
    if not ok then
      logger:warnf("thumbnail %s errored: %s", tostring(url), tostring(path))
      path = self.placeholder
    end

    if onReady then onReady(index, path) end
  end

  return true
end

--- Throw the folder away.
--
-- Never raises: this runs when the dialog closes, and a temp file that outlives
-- its cache is not worth an error dialog.
function ThumbCache:discard()
  local ok, err = LrTasks.pcall(function()
    if self.fs.exists(self.folder) then self.fs.delete(self.folder) end
  end)

  if not ok then
    logger:warnf("could not remove %s: %s", tostring(self.folder), tostring(err))
  end

  self.files = {}
  return ok
end

return ThumbCache
