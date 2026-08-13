--[[
  UpdateInstall.lua
  -----------------
  Turning a published release into the plugin that loads next time.

  The problem this file exists to solve is that a plugin cannot safely replace
  itself while it is running. Lightroom loads a module the first time something
  requires it, so a folder half-swapped mid-session serves old modules to code
  that has already loaded and new ones to code that has not, and the failure
  from that arrives later, somewhere else, looking like a bug in whatever
  happened to require last.

  So the work is split in two, and they never happen in the same moment:

    stage    download, verify, unpack into <plugin>/.update-staging, and mark
             it ready. Runs whenever the user asks. Touches nothing that is
             loaded.

    apply    copy the staged files over the installed ones. Runs from
             LrShutdownPlugin, as Lightroom is closing, when no further require
             can happen. The next launch reads a folder that is entirely one
             version.

  A shutdown hook is not a promise -- Lightroom can be killed, or crash, and
  then nothing applied it. That is why PluginInit tries again at startup: a
  staged update that survived to the next launch is applied before any other
  module of this plugin is loaded, which is the same guarantee by a longer
  route. The only thing it cannot fix up is Info.lua, which Lightroom has
  already read by then, so that session runs new code behind an old manifest
  and the next one is straight again.

  Staging lives inside the plugin folder rather than beside it or in temp:

    beside   needs write permission on the parent directory, which is a
             different permission from the one the swap itself needs, and the
             swap is the part that must not fail half way
    temp     is cleared between sessions on both platforms, which is exactly
             the moment the staged update is waiting for

  Lightroom only loads the files Info.lua names, so an extra folder inside the
  plugin is inert.
--]]

local LrFileUtils = import "LrFileUtils"
local LrHttp      = import "LrHttp"
local LrPathUtils = import "LrPathUtils"
local LrTasks     = import "LrTasks"

local logger = require "Log"

local UpdateInstall = {}

UpdateInstall.STAGING_DIR   = ".update-staging"
UpdateInstall.PLUGIN_DIR    = "inat.lrplugin"
UpdateInstall.READY_MARKER  = "READY"
UpdateInstall.WIN_SCRIPT    = "install_update.ps1"
UpdateInstall.MAC_SCRIPT    = "install_update.sh"
UpdateInstall.ARCHIVE_NAME  = "inat-lightroom-update.zip"

--- How big a plugin archive is allowed to be, in bytes.
--
-- The whole download is held in memory as a Lua string before it reaches disk,
-- and the plugin is a few dozen kilobytes of text. Ten megabytes is far more
-- than a release can plausibly need and far less than enough to hurt.
UpdateInstall.MAX_ARCHIVE_BYTES = 10 * 1024 * 1024

--------------------------------------------------------------------------------
-- Paths
--------------------------------------------------------------------------------

function UpdateInstall.stagingPath(pluginPath)
  return LrPathUtils.child(pluginPath, UpdateInstall.STAGING_DIR)
end

--- Where the archive unpacks to: <plugin>/.update-staging/inat.lrplugin
function UpdateInstall.stagedPluginPath(pluginPath)
  return LrPathUtils.child(
    UpdateInstall.stagingPath(pluginPath), UpdateInstall.PLUGIN_DIR)
end

--- The file whose existence means "this staging folder is complete".
--
-- Unpacking is not atomic, and a staging folder that was interrupted looks
-- exactly like a finished one from the outside. The marker is written last and
-- read first, so a partial unpack is never applied; it is discarded and the
-- installed plugin is untouched.
function UpdateInstall.readyMarkerPath(pluginPath)
  return LrPathUtils.child(
    UpdateInstall.stagingPath(pluginPath), UpdateInstall.READY_MARKER)
end

function UpdateInstall.archivePath()
  return LrPathUtils.child(
    LrPathUtils.getStandardFilePath("temp"), UpdateInstall.ARCHIVE_NAME)
end

function UpdateInstall.scriptName()
  if WIN_ENV then return UpdateInstall.WIN_SCRIPT end
  return UpdateInstall.MAC_SCRIPT
end

function UpdateInstall.scriptPath(pluginPath)
  return LrPathUtils.child(pluginPath, UpdateInstall.scriptName())
end

--------------------------------------------------------------------------------
-- The helper command
--------------------------------------------------------------------------------

--- The command line that verifies and unpacks the archive.
--
-- Kept pure so a test can assert on it without a shell, which is the same
-- reason WindowFix.command exists -- and the same reasoning about quoting
-- applies: the executable is left unquoted so that cmd.exe, which strips the
-- outermost pair of quotes only when the command begins with one, cannot eat
-- the quotes around the paths.
function UpdateInstall.command(scriptPath, archivePath, expectedHash, destination)
  if WIN_ENV then
    return table.concat({
      "powershell",
      "-NoProfile",
      "-NonInteractive",
      -- Plugins are installed by pointing the Plug-in Manager at a folder, so
      -- this script is unsigned and, after an update, marked as downloaded.
      "-ExecutionPolicy Bypass",
      "-WindowStyle Hidden",
      '-File "' .. scriptPath .. '"',
      '-Archive "' .. archivePath .. '"',
      '-ExpectedHash "' .. expectedHash .. '"',
      '-Destination "' .. destination .. '"',
    }, " ")
  end

  return table.concat({
    "sh",
    '"' .. scriptPath .. '"',
    '"' .. archivePath .. '"',
    '"' .. expectedHash .. '"',
    '"' .. destination .. '"',
  }, " ")
end

--- What each exit code from the helper means, in words a user can act on.
UpdateInstall.EXIT_MESSAGES = {
  [1] = "the downloaded file could not be read",
  [2] = "the download did not match its checksum, so it was not installed",
  [3] = "the download could not be unpacked",
  [4] = "the download did not contain a Lightroom plugin",
}

--------------------------------------------------------------------------------
-- The filesystem, in one place
--------------------------------------------------------------------------------

--- Every filesystem operation this module performs, behind one table.
--
-- Injectable because the alternative is testing the swap against a real
-- directory tree, and the swap is the one operation here that can leave a user
-- without a working plugin. A fake table lets a test watch it copy and delete
-- without either party owning a disk.
local realFs = {}

function realFs.exists(path)
  return LrFileUtils.exists(path) ~= false
end

function realFs.isDirectory(path)
  return LrFileUtils.exists(path) == "directory"
end

function realFs.makeDirectories(path)
  LrFileUtils.createAllDirectories(path)
end

function realFs.copy(from, to)
  LrFileUtils.createAllDirectories(LrPathUtils.parent(to))
  -- LrFileUtils.copy will not overwrite, and every file in an update already
  -- exists at the destination.
  if LrFileUtils.exists(to) then
    LrFileUtils.delete(to)
  end
  return LrFileUtils.copy(from, to)
end

function realFs.delete(path)
  return LrFileUtils.delete(path)
end

function realFs.readFile(path)
  if LrFileUtils.exists(path) ~= "file" then return nil end
  return LrFileUtils.readFile(path)
end

function realFs.writeFile(path, contents)
  local handle, err = io.open(path, "wb")
  if not handle then return nil, tostring(err) end
  handle:write(contents)
  handle:close()
  return true
end

--- Every file under `root`, as paths relative to it, with '/' separators.
--
-- Separators are normalised because the comparison between what is installed
-- and what is staged is a string comparison, and on Windows the two walks can
-- disagree about slashes while describing the same file.
function realFs.files(root)
  local found = {}
  local prefix = #root + 2

  for path in LrFileUtils.recursiveFiles(root) do
    local relative = path:sub(prefix):gsub("\\", "/")
    if relative ~= "" then
      found[#found + 1] = relative
    end
  end

  return found
end

UpdateInstall.fs = realFs

--------------------------------------------------------------------------------
-- Staging
--------------------------------------------------------------------------------

--- Download the release archive into the temp folder.
--
-- Must be called from a task. Returns the path it wrote, or nil plus a message.
function UpdateInstall.download(url, fs)
  fs = fs or UpdateInstall.fs

  local body, headers = LrHttp.get(url, {
    { field = "Accept",     value = "application/octet-stream" },
    { field = "User-Agent", value = "inat-lightroom/updater" },
  })

  if not body then
    local detail = "no response"
    if type(headers) == "table" and type(headers.error) == "table" then
      detail = tostring(headers.error.name or "unknown error")
    end
    return nil, "could not download the update: " .. detail
  end

  local status = headers and tonumber(headers.status)
  if status and status ~= 200 then
    return nil, "could not download the update: GitHub replied " .. tostring(status)
  end

  if #body == 0 then
    return nil, "the downloaded update was empty"
  end
  if #body > UpdateInstall.MAX_ARCHIVE_BYTES then
    return nil, "the downloaded update was implausibly large"
  end

  local path = UpdateInstall.archivePath()
  local ok, err = fs.writeFile(path, body)
  if not ok then
    return nil, "could not save the update: " .. tostring(err)
  end

  logger:info("Updater: downloaded " .. #body .. " bytes to " .. path)
  return path
end

--- Download, verify and unpack a release into the staging folder.
--
-- Must be called from a task: it downloads and it shells out, and both block.
--
-- @param release   a table from Updater.latestRelease
-- @param hash      the expected SHA-256, from Updater.expectedHash
-- @return true, or nil plus a message fit to show a user
function UpdateInstall.stage(release, hash, pluginPath, fs)
  fs = fs or UpdateInstall.fs
  pluginPath = pluginPath or _PLUGIN.path

  if type(hash) ~= "string" or not hash:match("^%x%x+$") then
    return nil, "the release did not publish a usable checksum"
  end

  -- Refuse before downloading anything if the swap could not happen anyway.
  -- Discovering an unwritable plugin folder after a download is a worse
  -- experience and leaves a stray file in temp.
  local writable, whyNot = UpdateInstall.canWrite(pluginPath, fs)
  if not writable then
    return nil, whyNot
  end

  local archive, err = UpdateInstall.download(release.assetUrl, fs)
  if not archive then return nil, err end

  local command = UpdateInstall.command(
    UpdateInstall.scriptPath(pluginPath),
    archive,
    hash,
    UpdateInstall.stagingPath(pluginPath))

  local ok, result = LrTasks.pcall(function()
    return LrTasks.execute(command)
  end)

  -- The archive has done its job either way, and leaving several megabytes in
  -- temp after a failure is untidy at best and confusing at worst.
  pcall(function() fs.delete(archive) end)

  if not ok then
    return nil, "could not run the installer: " .. tostring(result)
  end
  if result ~= 0 then
    local why = UpdateInstall.EXIT_MESSAGES[result]
      or ("the installer exited " .. tostring(result))
    UpdateInstall.discard(pluginPath, fs)
    return nil, why
  end

  -- Written last: this is what makes the staging folder count as complete.
  local marked, markErr = fs.writeFile(
    UpdateInstall.readyMarkerPath(pluginPath), release.tag or "")
  if not marked then
    UpdateInstall.discard(pluginPath, fs)
    return nil, "could not finish staging the update: " .. tostring(markErr)
  end

  logger:info("Updater: staged " .. tostring(release.tag))
  return true
end

--- Whether the installed plugin can be written to at all.
--
-- Checked by writing, because permission is not something to infer: plugins
-- installed under Program Files or in a synced folder can be readable and
-- unwritable, and the honest answer for those users is to install by hand.
function UpdateInstall.canWrite(pluginPath, fs)
  fs = fs or UpdateInstall.fs

  local probe = LrPathUtils.child(pluginPath, ".update-write-test")
  local ok = fs.writeFile(probe, "")
  if not ok then
    return false, "this plugin's folder is read-only, so it cannot update "
      .. "itself. Download the release and replace the folder by hand."
  end

  pcall(function() fs.delete(probe) end)
  return true
end

--------------------------------------------------------------------------------
-- Applying
--------------------------------------------------------------------------------

--- The tag of a staged update waiting to be applied, or nil.
function UpdateInstall.pending(pluginPath, fs)
  fs = fs or UpdateInstall.fs
  pluginPath = pluginPath or _PLUGIN.path

  local marker = UpdateInstall.readyMarkerPath(pluginPath)
  if not fs.exists(marker) then return nil end
  if not fs.exists(UpdateInstall.stagedPluginPath(pluginPath)) then return nil end

  local contents = fs.readFile(marker)
  return contents and contents:match("^%s*(.-)%s*$") or ""
end

--- Throw away a staged update.
function UpdateInstall.discard(pluginPath, fs)
  fs = fs or UpdateInstall.fs
  pluginPath = pluginPath or _PLUGIN.path

  local staging = UpdateInstall.stagingPath(pluginPath)
  if not fs.exists(staging) then return true end

  local ok, err = pcall(function() return fs.delete(staging) end)
  if not ok then
    logger:warn("Updater: could not remove the staging folder: " .. tostring(err))
    return false
  end
  return true
end

--- What applying an update does to the installed folder.
--
-- Pure: two lists of relative paths in, a plan out. The swap is the one thing
-- here that can leave someone without a working plugin, and this is the part of
-- it worth testing exhaustively.
--
-- Files are copied rather than the folder replaced wholesale because the
-- installed folder is the one Lightroom has registered by path; moving it aside
-- would unregister the plugin, and the user would find it disabled with no
-- explanation.
--
-- Deletions matter as much as copies: a module dropped in a release stays
-- behind otherwise, and a stale Lua file that nothing requires is harmless
-- right up until something requires it again under the same name.
function UpdateInstall.swapPlan(installed, staged)
  local wanted = {}
  for _, path in ipairs(staged) do wanted[path] = true end

  local plan = { copy = {}, delete = {} }

  for _, path in ipairs(staged) do
    plan.copy[#plan.copy + 1] = path
  end

  for _, path in ipairs(installed) do
    -- The staging folder lives inside the plugin folder, so it turns up in the
    -- installed walk. Deleting its contents mid-swap would be deleting the
    -- source of the copy that is still happening.
    local isStaging = path == UpdateInstall.STAGING_DIR
      or path:sub(1, #UpdateInstall.STAGING_DIR + 1)
         == (UpdateInstall.STAGING_DIR .. "/")

    if not wanted[path] and not isStaging then
      plan.delete[#plan.delete + 1] = path
    end
  end

  return plan
end

--- Apply a staged update over the installed plugin.
--
-- Called from LrShutdownPlugin, and again from LrInitPlugin for the case where
-- shutdown never ran. Returns the tag applied, or nil.
--
-- Failure here is reported to the log and nowhere else. There is no user to
-- show a dialog to during shutdown, and at startup a modal would appear before
-- Lightroom has drawn a window.
function UpdateInstall.apply(pluginPath, fs)
  fs = fs or UpdateInstall.fs
  pluginPath = pluginPath or _PLUGIN.path

  local tag = UpdateInstall.pending(pluginPath, fs)
  if not tag then return nil end

  local staged = UpdateInstall.stagedPluginPath(pluginPath)

  local ok, result = pcall(function()
    local plan = UpdateInstall.swapPlan(fs.files(pluginPath), fs.files(staged))

    -- Copies first, deletions after. The other order spends time with the
    -- plugin missing files it has not yet been given.
    for _, relative in ipairs(plan.copy) do
      local from = staged .. "/" .. relative
      local to   = pluginPath .. "/" .. relative
      local copied, copyErr = fs.copy(from, to)
      if copied == false then
        error("could not copy " .. relative .. ": " .. tostring(copyErr), 0)
      end
    end

    for _, relative in ipairs(plan.delete) do
      pcall(function() fs.delete(pluginPath .. "/" .. relative) end)
    end

    return #plan.copy
  end)

  if not ok then
    -- Deliberately leaves the staging folder in place. A half-applied update is
    -- the one state worth retrying automatically, and the next launch will.
    logger:error("Updater: could not apply " .. tostring(tag) .. ": " ..
      tostring(result))
    return nil
  end

  UpdateInstall.discard(pluginPath, fs)
  logger:info("Updater: applied " .. tostring(tag) .. " (" ..
    tostring(result) .. " files)")
  return tag
end

return UpdateInstall
