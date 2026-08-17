"""Run the plugin's Lua outside Lightroom, against stubbed SDK modules.

Two auth bugs in a row reached Lightroom because the Lua could not be executed
anywhere else: token handling is pure logic, but it is wrapped in ``import``
calls for LrPasswords, LrPrefs and friends that only resolve inside the host.

lupa gives us a real Lua 5.1 -- the same version Lightroom embeds. Supplying
fake SDK modules is enough to exercise everything that is not an actual network
call, which is where the interesting logic lives.

What this can and cannot catch:

  can     control flow, token parsing and expiry, error messages, anything
          that is ordinary Lua
  cannot  whether the real SDK behaves like these stubs, or whether SDK
          functions exist at all

The stubs are deliberately thin. Where behaviour matters -- LrPasswords storing
by key, LrStringUtils.decodeBase64 doing real base64 -- they are faithful.
"""

from __future__ import annotations

import base64
from pathlib import Path
from typing import Any

from lupa import lua51

PLUGIN_DIR = Path(__file__).resolve().parent.parent / "plugin" / "pinned.lrplugin"

# Lua source for the fake SDK. Kept as Lua rather than built through the bridge
# so that table semantics (methods called with ':') behave normally.
_STUB_SOURCE = """
local stubs = {}

-- Lua 5.1 cannot yield across a C call, and pcall is a C function. So an SDK
-- call that yields -- which is most of the catalog, and all of the network --
-- fails when it happens inside a plain pcall, with a message that names neither
-- the pcall nor the call that yielded:
--
--     Yielding is not allowed within a C or metamethod call
--
-- Nothing about the shape of the code says so, and it is invisible until it
-- runs inside Lightroom. It cost a whole reverse sync run: every photo failed,
-- the failures were caught and counted, and the result read as a matching
-- problem rather than a Lua one.
--
-- So the harness models the rule. pcall is replaced with one that remembers it
-- is a plain pcall, LrTasks.pcall is not, and the stubs that stand for yielding
-- calls refuse to run while a plain one is on the stack.
local realPcall = pcall
local plainPcallDepth = 0

function pcall(fn, ...)
  plainPcallDepth = plainPcallDepth + 1
  local results = { realPcall(fn, ...) }
  plainPcallDepth = plainPcallDepth - 1
  return unpack(results)
end

--- Called by every stub that stands in for a call that yields in Lightroom.
local function yieldsHere(what)
  if plainPcallDepth > 0 then
    error("Yielding is not allowed within a C or metamethod call -- "
      .. tostring(what) .. " yields, and it is inside a plain pcall. "
      .. "Use LrTasks.pcall.", 0)
  end
end

-- Some of the SDK does not merely yield when it feels like it: it refuses
-- outright unless a task is running, with the message Lightroom puts in front
-- of the user --
--
--     An internal error has occurred: We can only wait from within a task
--
-- -- and no clue as to which call it was. A menu item's script does not run in
-- a task, and neither does LrFunctionContext.callWithContext, so a dialog that
-- reads the catalog while it is being built raises before it can appear.
--
-- That is exactly how the settings dialog broke: the keyword-root picker walks
-- catalog:getKeywords() to fill its list. Every test passed, because a stub
-- that just returns a table cannot refuse.
local taskDepth = 0

local function requiresTask(what)
  if taskDepth == 0 then
    error("We can only wait from within a task -- " .. tostring(what)
      .. " must be called from inside one. Use LrTasks.startAsyncTask or "
      .. "LrFunctionContext.postAsyncTaskWithContext.", 0)
  end
end

-- Captures every logged line so tests can assert on them if useful.
local logLines = {}

stubs.LrLogger = function(_name)
  local logger = {}
  local function record(level)
    return function(_self, message)
      logLines[#logLines + 1] = level .. ": " .. tostring(message)
    end
  end
  -- The real LrLogger has a printf-style variant of every level. Leaving them
  -- out did not make tests fail loudly -- it made any line that used one raise
  -- "attempt to call method 'tracef' (a nil value)", so those paths were simply
  -- never reached.
  local function recordf(level)
    return function(_self, format, ...)
      local ok, message = realPcall(string.format, tostring(format), ...)
      logLines[#logLines + 1] = level .. ": " .. (ok and message or tostring(format))
    end
  end
  logger.enable = function() end
  logger.trace  = record("trace")
  logger.debug  = record("debug")
  logger.info   = record("info")
  logger.warn   = record("warn")
  logger.error  = record("error")
  logger.tracef = recordf("trace")
  logger.debugf = recordf("debug")
  logger.infof  = recordf("info")
  logger.warnf  = recordf("warn")
  logger.errorf = recordf("error")
  return logger
end

-- LrPasswords is plugin-scoped in the real SDK, so a flat keyed store matches.
local passwordStore = {}
stubs.LrPasswords = {
  store = function(key, value)
    passwordStore[key] = value
  end,
  retrieve = function(key)
    return passwordStore[key]
  end,
}

local prefs = {}
stubs.LrPrefs = {
  prefsForPlugin = function()
    return prefs
  end,
}

stubs.LrStringUtils = {
  decodeBase64 = function(value)
    return PY_B64DECODE(value)
  end,
  trimWhitespace = function(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
  end,
}

-- Network calls are not exercised; failing loudly beats returning plausible
-- nonsense that makes a test pass for the wrong reason.
local httpCalls = {}
local openedUrls = {}
stubs.LrHttp = {
  get = function(url, headers)
    yieldsHere("LrHttp.get")
    httpCalls[#httpCalls + 1] = { method = "GET", url = url, headers = headers }
    if HTTP_HANDLER then return HTTP_HANDLER("GET", url, nil, headers) end
    error("unexpected HTTP GET in test: " .. tostring(url))
  end,
  -- The real LrHttp.post takes (url, body, headers, method, timeout). Anything
  -- beyond the fourth argument is recorded so tests can assert we are not
  -- passing a content type positionally, which silently stops the request.
  post = function(url, body, headers, method, ...)
    yieldsHere("LrHttp.post")
    httpCalls[#httpCalls + 1] = {
      method = method or "POST",
      url = url,
      body = body,
      headers = headers,
      extraArgs = select("#", ...),
    }
    if HTTP_HANDLER then
      return HTTP_HANDLER(method or "POST", url, body, headers)
    end
    error("unexpected HTTP POST in test: " .. tostring(url))
  end,
  openUrlInBrowser = function(url)
    openedUrls[#openedUrls + 1] = url
  end,
}

-- Async tasks do not run inline in Lightroom: they are queued and run once the
-- caller has returned. Modelling that is what makes a progress scope outliving
-- its function context visible here instead of only in the host.
local pendingTasks = {}

-- Every LrTasks.sleep the plugin asked for, in order. Rate limiting is a
-- behaviour made entirely of waiting, so the waits have to be observable.
local sleeps = {}
stubs._sleeps = sleeps

-- Shell-outs. LrTasks.execute is how the plugin reaches Win32 to fix the
-- floating panel's z-order, so tests need to see the command and to be able to
-- make it fail.
local executedCommands = {}
local executeExitCode  = 0

-- Order matters in places where a recording alone cannot show it -- whether the
-- z-order fix-up was started alongside the window or ran before it, for
-- instance -- so the stubs that block in Lightroom also append here.
local timeline = {}

local function runPendingTasks(reverse)
  while #pendingTasks > 0 do
    -- Lightroom makes no promise about the order tasks finish in, and a
    -- refresh that started earlier can finish later. Draining back to front
    -- models that without needing real concurrency.
    local index = reverse and #pendingTasks or 1
    local fn = table.remove(pendingTasks, index)
    taskDepth = taskDepth + 1
    local ok, err = realPcall(fn)
    taskDepth = taskDepth - 1
    if not ok then error(err, 0) end
  end
end

--- Run something as though a task were already running.
--
-- For testing a function the plugin only ever calls from inside a task, without
-- routing the call through the queue just to get its return value back.
local function runInTask(fn, ...)
  taskDepth = taskDepth + 1
  local results = { realPcall(fn, ...) }
  taskDepth = taskDepth - 1
  if not results[1] then error(results[2], 0) end
  return unpack(results, 2)
end

stubs.LrTasks = {
  startAsyncTask = function(fn) pendingTasks[#pendingTasks + 1] = fn end,
  -- Records rather than waits. Pacing and backoff are worth asserting on --
  -- the whole point is how long the plugin waits -- and a test suite that
  -- actually slept would take minutes.
  sleep = function(seconds) sleeps[#sleeps + 1] = seconds end,
  -- Lightroom's own pcall, which unlike Lua's can be used around code that
  -- yields. realPcall, and deliberately without touching plainPcallDepth: this
  -- is the one that is safe to yield inside.
  pcall = function(fn, ...) return realPcall(fn, ...) end,

  -- Records the command instead of running a shell, and hands back whatever
  -- exit code the test asked for. Real one blocks until the child exits.
  execute = function(command)
    executedCommands[#executedCommands + 1] = command
    timeline[#timeline + 1] = "execute"
    return executeExitCode
  end,
}

local createdDirectories = {}
local deletedPaths = {}
local deleteFails = false

stubs.LrPathUtils = {
  child = function(directory, name)
    return tostring(directory) .. "/" .. tostring(name)
  end,

  -- The real one returns nil for a name it does not know, which is exactly how
  -- the tempFolder destination type failed: getStandardFilePath("tempFolder")
  -- is nil, and the assert that follows blames a missing path prefix.
  getStandardFilePath = function(name)
    if name == "temp" then return "/tmp" end
    if name == "home" then return "/home/tester" end
    return nil
  end,
}

-- The filesystem, only as far as the plugin touches it. Nothing is written:
-- what matters to a test is which directories were asked for and which paths
-- were deleted, so those are recorded instead.
stubs.LrFileUtils = {
  createAllDirectories = function(path)
    createdDirectories[#createdDirectories + 1] = path
    return true
  end,

  delete = function(path)
    -- The real one has a path to work with or it does not. Recording nil would
    -- be a silent no-op here (Lua tables do not store nil), which would let a
    -- missing guard in the caller pass unnoticed.
    if path == nil then
      error("LrFileUtils.delete: path must not be nil", 0)
    end
    if deleteFails then
      error("could not delete " .. tostring(path), 0)
    end
    deletedPaths[#deletedPaths + 1] = path
    return true
  end,

  exists = function(path)
    for _, made in ipairs(createdDirectories) do
      if made == path then return "directory" end
    end
    return false
  end,
}

-- Lightroom counts seconds from 2001-01-01, not the Unix epoch, and the whole
-- point of routing dates through LrDate is that os.date would be 31 years out.
-- A stub returning a fixed string cannot tell a caller who got that right from
-- one who got it wrong, so these convert for real. UTC throughout, so a test
-- gives the same answer on any machine.
local LR_EPOCH_IN_UNIX = 978307200

stubs.LrDate = {
  timeToUserFormat = function(time, format)
    return os.date("!" .. format, (time or 0) + LR_EPOCH_IN_UNIX)
  end,
  -- The real one includes milliseconds and an explicit offset. That exact
  -- shape matters: findPhotos matches nothing against it, silently, so a test
  -- that feeds it to a capture-time search should see what Lightroom sees.
  timeToW3CDate = function(time)
    return os.date("!%Y-%m-%dT%H:%M:%S.000+00:00", (time or 0) + LR_EPOCH_IN_UNIX)
  end,
  currentTime = function() return 807126000 end,
}

-- UI modules. Enough shape to let the export provider load and to record what
-- would have been shown to the user.
local dialogMessages = {}
local floatingDialogs = {}
local confirmAnswer = "cancel"
stubs.LrDialogs = {
  message = function(title, message, style)
    dialogMessages[#dialogMessages + 1] =
      { title = title, message = message, style = style }
  end,
  presentModalDialog = function() return "cancel" end,

  -- Answers whatever the test told it to, defaulting to Cancel. Defaulting to
  -- "ok" would make a missing confirmation look like a working one, and the
  -- whole point of a confirmation is that it can say no.
  confirm = function(title, message, actionVerb, cancelVerb)
    dialogMessages[#dialogMessages + 1] = {
      title = title, message = message, style = "confirm",
      actionVerb = actionVerb, cancelVerb = cancelVerb,
    }
    return confirmAnswer
  end,

  -- Records the args rather than showing anything, so a test can find the
  -- observers and call them the way Lightroom would. The real one blocks the
  -- calling task until the window closes when blockTask is set; blocking here
  -- would deadlock the test, so it returns instead.
  presentFloatingDialog = function(plugin, args)
    if not plugin then
      error("presentFloatingDialog called with invalid plugin parameter", 0)
    end
    if not args or not args.contents then
      error("presentFloatingDialog called with no contents parameter", 0)
    end
    floatingDialogs[#floatingDialogs + 1] = args
    timeline[#timeline + 1] = "floatingDialog"
    return args
  end,
  closeFloatingDialogsForPlugin = function() end,
}

stubs.LrErrors = {
  throwUserError = function(message)
    error({ userError = tostring(message) }, 0)
  end,
}

local function passthroughFactory()
  -- Every view constructor just records its arguments; nothing renders here.
  -- The constructor's own name is recorded too, so a test can tell a
  -- push_button from a static_text when walking a dialog's sections.
  return setmetatable({}, {
    __index = function(_table, key)
      return function(_self, args)
        args = args or {}
        if type(args) == "table" then args._viewType = key end
        return args
      end
    end,
  })
end

stubs.LrView = {
  osFactory = passthroughFactory,
  bind = function(spec) return { __bind = spec } end,
}

-- LrColor is a module that is itself a function: LrColor(r, g, b). The stub
-- keeps the components so a test can assert a warning is drawn in a warning
-- colour, rather than only that some colour was asked for.
stubs.LrColor = function(red, green, blue, alpha)
  return { red = red, green = green, blue = blue, alpha = alpha,
           __color = true }
end

-- A property table that notices writes.
--
-- The real one is not a plain table: assigning to it fires anything registered
-- with addObserver, which is the only way a list or a slider tells a plugin
-- that the user changed it. A plain stub table made every observer look like it
-- worked while never firing, so the code under test could not be wrong.
--
-- Values live in a table behind a proxy rather than in the proxy itself,
-- because __newindex only fires for keys the table does not already have, and
-- every interesting write here is an update to an existing key.
stubs.LrBinding = {
  makePropertyTable = function()
    local values    = {}
    local observers = {}
    local proxy     = {}

    setmetatable(proxy, {
      __index = function(_table, key)
        if key == "addObserver" then
          return function(_self, watched, fn)
            observers[watched] = observers[watched] or {}
            table.insert(observers[watched], fn)
          end
        end
        return values[key]
      end,

      __newindex = function(_table, key, value)
        local previous = values[key]
        values[key] = value

        -- Lightroom does not re-notify for a write that changed nothing, and
        -- an observer that fires on every assignment can loop forever when it
        -- writes back to the table it is watching.
        if previous == value then return end

        for _, fn in ipairs(observers[key] or {}) do
          fn(proxy, key, value)
        end
      end,
    })

    return proxy
  end,
  negativeOfKey = function(key) return { __negative = key } end,
}

-- A function context dies when the function owning it returns. Anything still
-- holding one after that is holding a dead object, which is easy to do by
-- pairing callWithContext with an async task.
local function newContext()
  return { alive = true }
end

stubs.LrProgressScope = function(args)
  local context = args and args.functionContext
  if context and context.alive == false then
    error("LrProgressScope: its function context has already ended", 0)
  end
  return {
    setCaption = function() end,
    setPortionComplete = function() end,
    setCancelable = function() end,
    isCanceled = function() return false end,
    done = function() end,
    _args = args,
  }
end

stubs.LrFunctionContext = {
  callWithContext = function(_name, fn)
    local context = newContext()
    local result = fn(context)
    context.alive = false
    runPendingTasks()
    return result
  end,
  -- The right tool when the work is asynchronous: the context lives exactly as
  -- long as the task does.
  postAsyncTaskWithContext = function(_name, fn)
    pendingTasks[#pendingTasks + 1] = function()
      local context = newContext()
      fn(context)
      context.alive = false
    end
  end,
}

-- The only capture-time value format findPhotos actually understands, plus the
-- date-only form. Anything else -- a zone, a fraction of a second, the output
-- of LrDate.timeToW3CDate -- returns nil here and matches nothing there.
--
-- `endOfDay` extends a bare date to cover the whole of it, which is what the
-- real search does with a date-only bound.
local function parseSearchValue(value, endOfDay)
  if type(value) ~= "string" then return nil end

  local year, month, day, hour, minute, second = string.match(value,
    "^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)$")

  if not year then
    year, month, day = string.match(value, "^(%d%d%d%d)-(%d%d)-(%d%d)$")
    if not year then return nil end
    hour, minute, second = endOfDay and 23 or 0, endOfDay and 59 or 0,
      endOfDay and 59 or 0
  end

  -- os.time reads the machine's zone; these are UTC by construction, so the
  -- arithmetic is done here instead.
  local y, m, d = tonumber(year), tonumber(month), tonumber(day)
  local era = math.floor((m <= 2 and y - 1 or y) / 400)
  local yoe = (m <= 2 and y - 1 or y) - era * 400
  local mp  = (m + 9) % 12
  local doy = math.floor((153 * mp + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  local days = era * 146097 + doe - 719468

  return days * 86400 + tonumber(hour) * 3600 + tonumber(minute) * 60
    + tonumber(second)
end

local catalogWrites = {}
local createdKeywords = {}
local refusedKeywords = {}
local targetPhotos = {}
local allPhotos = {}
local publishedCollections = {}
local catalog

-- The real catalog refuses writes outside a transaction. Letting them through
-- here would mean the tests pass and Lightroom throws.
local function requireWriteAccess(what)
  if not catalog._writing then
    error(what .. ": must be called inside a withWriteAccessDo block", 0)
  end
end

local function newPhoto(props, raw, formatted)
  local photo = {
    _props = props or {},
    _raw = raw or {},
    _formatted = formatted or {},
    keywords = {},
  }
  photo.getPropertyForPlugin = function(self, _plugin, key)
    return self._props[key]
  end
  photo.setPropertyForPlugin = function(self, _plugin, key, value)
    requireWriteAccess("LrPhoto:setPropertyForPlugin")
    self._props[key] = value
  end
  photo.getRawMetadata = function(self, key)
    return self._raw[key]
  end
  -- Refuses keys Lightroom's own setRawMetadata refuses. Its whitelist raises
  -- "unknown metadata key %q", so a stub that accepted anything would let a
  -- typo pass here and fail only in the host, which is the failure this harness
  -- exists to prevent. The list is the plugin-relevant part of the real one.
  photo.setRawMetadata = function(self, key, value)
    requireWriteAccess("LrPhoto:setRawMetadata")
    local settable = {
      gps = true, gpsAltitude = true, gpsImgDirection = true,
      caption = true, title = true, rating = true, label = true,
      pickStatus = true, copyrightState = true,
    }
    if not settable[key] then
      error("LrPhoto:setRawMetadata: unknown metadata key '" .. tostring(key) .. "'", 0)
    end
    self._raw[key] = value
  end
  photo.getFormattedMetadata = function(self, key)
    return self._formatted[key]
  end
  photo.addKeyword = function(self, keyword)
    requireWriteAccess("LrPhoto:addKeyword")
    self.keywords[#self.keywords + 1] = keyword
  end
  return photo
end

catalog = {
  _writing = false,

  -- Nesting is rejected rather than quietly flattened. Lightroom will not open
  -- a write block inside a write block, and a stub that allowed it would let a
  -- caller wrap a helper that already opens its own -- which passes here and
  -- deadlocks there. The exit flag is restored rather than cleared for the
  -- same reason: clearing it would leave the outer block looking closed.
  withWriteAccessDo = function(self, name, fn)
    yieldsHere("catalog:withWriteAccessDo")
    if self._writing then
      error("withWriteAccessDo: cannot be called inside another write block " ..
        "(already in " .. tostring(self._writingName) .. ")", 0)
    end

    catalogWrites[#catalogWrites + 1] = name
    local wasWriting, wasName = self._writing, self._writingName
    self._writing, self._writingName = true, name
    local ok, err = realPcall(fn)
    self._writing, self._writingName = wasWriting, wasName
    if not ok then error(err, 0) end
  end,

  -- The variant an export task must use: the ordinary write can block on a
  -- transaction the export itself is holding. It takes no name, which is the
  -- easiest way for a test to tell the two apart.
  withPrivateWriteAccessDo = function(self, fn)
    yieldsHere("catalog:withPrivateWriteAccessDo")
    catalogWrites[#catalogWrites + 1] = "<private>"
    self._writing = true
    local ok, err = realPcall(fn)
    self._writing = false
    if not ok then error(err, 0) end
  end,

  -- createKeyword(name, synonyms, includeOnExport, parent, returnExistingIfAny)
  createKeyword = function(_self, name, _synonyms, _include, parent, returnExisting)
    yieldsHere("catalog:createKeyword")
    requireWriteAccess("LrCatalog:createKeyword")
    -- Lightroom sometimes hands back nil instead of a keyword. Tests need to
    -- reproduce that, because the interesting question is what the caller does
    -- next: carrying on with a nil parent silently creates the rest of the
    -- hierarchy at the top level of the catalog.
    if refusedKeywords[name] then return nil end
    local parentName = parent and parent.name or nil
    for _, keyword in ipairs(createdKeywords) do
      if keyword.name == name and keyword.parent == parentName then
        if returnExisting then return keyword end
        error("LrCatalog:createKeyword: keyword exists: " .. name, 0)
      end
    end
    local keyword = { name = name, parent = parentName }
    -- Real keywords answer questions about themselves. The plugin asks, when
    -- createKeyword refuses, whether the keyword it wanted is already there.
    keyword.getName     = function(_kw) return name end
    keyword.getChildren = function(_kw)
      local children = {}
      for _, other in ipairs(createdKeywords) do
        if other.parent == name then children[#children + 1] = other end
      end
      return children
    end
    createdKeywords[#createdKeywords + 1] = keyword
    return keyword
  end,

  --- The top level of the keyword list. Children hang off getChildren.
  --
  -- Refuses outside a task, as the real one does. This is the call that broke
  -- the settings dialog: reachable from a menu item, which is not a task.
  getKeywords = function(_self)
    requiresTask("LrCatalog:getKeywords")
    local top = {}
    for _, keyword in ipairs(createdKeywords) do
      if keyword.parent == nil then top[#top + 1] = keyword end
    end
    return top
  end,

  getTargetPhotos = function() return targetPhotos end,

  -- The catalog's own index of photos carrying a value for one plugin field.
  -- Deliberately returns photos whose value is the empty string too, because
  -- the real one does: an unlinked photo keeps the field and empties it rather
  -- than losing it, and code that trusts this call without filtering will sync
  -- photos that are not linked to anything.
  findPhotosWithProperty = function(_self, pluginId, fieldName)
    local found = {}
    for _, photo in ipairs(allPhotos) do
      if pluginId == _PLUGIN.id and photo._props[fieldName] ~= nil then
        found[#found + 1] = photo
      end
    end
    return found
  end,

  getPublishedCollectionByLocalIdentifier = function(_self, localId)
    return publishedCollections[localId]
  end,

  -- The capture-time search, with the behaviour the SDK probe measured rather
  -- than the behaviour the documentation implies. Three details are load
  -- bearing and all three were found the hard way:
  --
  --   * a value it cannot read matches *nothing*, silently. That is how
  --     LrDate.timeToW3CDate output behaves against the real call -- an empty
  --     result, indistinguishable from a window holding no photo -- so a stub
  --     that accepted any date string would hide the bug it exists to catch.
  --   * an operation outside the date vocabulary never returns at all in
  --     Lightroom. A stub cannot hang without hanging the suite, so this
  --     raises instead, which fails the same tests for the same reason.
  --   * seconds are compared, not rounded away to whole days.
  findPhotos = function(_self, args)
    if type(args) ~= "table" or args.searchDesc == nil then
      error("LrCatalog:findPhotos: must be called with named arguments syntax", 0)
    end

    local desc = args.searchDesc
    local criteria = desc.criteria and { desc } or desc

    local matched = {}
    for _, photo in ipairs(allPhotos) do
      local keep = true

      for _, rule in ipairs(criteria) do
        if rule.criteria ~= "captureTime" then
          error("harness findPhotos: unsupported criteria " ..
            tostring(rule.criteria), 0)
        end
        if rule.operation ~= "in" then
          error("harness findPhotos: operation " .. tostring(rule.operation) ..
            " never returns in Lightroom -- use one from the date vocabulary", 0)
        end

        local from = parseSearchValue(rule.value, false)
        local to   = parseSearchValue(rule.value2, true)
        local when = photo._raw.dateTimeOriginal

        -- An unreadable bound matches nothing, exactly as the real call does.
        if not from or not to or not when then
          keep = false
        else
          local unix = when + LR_EPOCH_IN_UNIX
          if unix < from or unix > to then keep = false end
        end
      end

      if keep then matched[#matched + 1] = photo end
    end

    return matched
  end,

  -- Keyed by photo object, not by index, and all or nothing: one key it does
  -- not know discards every other column. The real message is
  -- `Unknown key: "fileName"` -- fileName being formatted metadata rather than
  -- raw, which is the mistake this reproduces.
  batchGetRawMetadata = function(_self, photos, keys)
    local known = {
      dateTimeOriginal = true, dateTimeOriginalISO8601 = true,
      captureTime = true, gps = true, gpsAltitude = true,
      path = true, uuid = true, isVirtualCopy = true,
    }
    for _, key in ipairs(keys) do
      if not known[key] then
        error('Unknown key: "' .. tostring(key) .. '"', 0)
      end
    end

    local rows = {}
    for _, photo in ipairs(photos) do
      local row = {}
      for _, key in ipairs(keys) do row[key] = photo._raw[key] end
      rows[photo] = row
    end
    return rows
  end,

  -- (photos, pluginId, {keys}) -- the keys go last. The other orderings raise
  -- `bad argument #1 to 'ipairs'` in Lightroom, or hang when handed _PLUGIN.
  batchGetPropertyForPlugin = function(_self, photos, pluginId, keys)
    if type(keys) ~= "table" then
      error("bad argument #1 to 'ipairs' (table expected, got " ..
        type(keys) .. ")", 0)
    end

    local rows = {}
    for _, photo in ipairs(photos) do
      local row = {}
      for _, key in ipairs(keys) do
        if pluginId == _PLUGIN.id then row[key] = photo._props[key] end
      end
      rows[photo] = row
    end
    return rows
  end,
}

stubs.LrApplication = {
  activeCatalog = function() return catalog end,
}

-- Records module switches so a test can check the panel sent people to the
-- right one. Rejects anything outside the real module list rather than
-- accepting any string: "map" was read out of Lightroom.exe's module table, and
-- a stub that shrugs at "Map" or "location" would hide the one mistake worth
-- catching here.
local moduleSwitches = {}
local VALID_MODULES = {
  library = true, develop = true, map = true, book = true,
  slideshow = true, print = true, web = true,
}

stubs.LrApplicationView = {
  switchToModule = function(name)
    if not VALID_MODULES[name] then
      error("no such module: " .. tostring(name), 0)
    end
    moduleSwitches[#moduleSwitches + 1] = name
  end,
  getCurrentModuleName = function()
    return moduleSwitches[#moduleSwitches] or "library"
  end,
}


-- LrExportSession, the mechanism the panel uses to turn catalog photos into
-- JPEGs now that there is no export service provider to do it.
--
-- The stub reproduces two behaviours that the real one has and that code gets
-- wrong: asking for the renditions is what starts the export (there is no
-- separate "go" call), and waitForRender returns success-plus-value, so a
-- failure arrives as a message in the same slot as the path.
exportSessions = {}
renderFailing = false
renderFailureMessage = nil

stubs.LrExportSession = function(params)
  assert(type(params) == "table",
    "LrExportSession:init: must use named arguments syntax")
  assert(params.exportSettings,
    "LrExportSession:init: params table must have exportSettings")

  local photos = params.photosToExport or {}
  local session = {
    settings = params.exportSettings,
    photos = photos,
    started = false,
  }

  function session:countRenditions() return #photos end

  function session:renditions()
    self.started = true

    local index = 0
    return function()
      index = index + 1
      local photo = photos[index]
      if not photo then return nil end

      local rendition = {
        photo = photo,
        waitForRender = function()
          if renderFailing then return false, renderFailureMessage end
          return true, "/tmp/lr-export/" .. tostring(index) .. ".jpg"
        end,
      }
      -- Yields index alongside the rendition, the way an export provider's
      -- exportContext:renditions does.
      return index, rendition
    end
  end

  function session:doExportOnCurrentTask() self.started = true end
  function session:doExportOnNewTask() self.started = true end

  exportSessions[#exportSessions + 1] = session
  return session
end

-- Lightroom exposes the plugin object as a global. `path` is the plugin
-- directory; it is in AgLrPlugin's property list in substrate.dll alongside
-- id, enabled and type.
_PLUGIN = { id = "com.github.inat-lightroom", path = "/plugins/pinned.lrplugin" }

-- Lightroom sets exactly one of these in every plugin's sandbox; they are in
-- the globals list in substrate.dll next to _PLUGIN and LOC. Tests that care
-- about the other platform flip them.
WIN_ENV = true
MAC_ENV = false

-- LOC is a global in Lightroom, not a module, and every Info.lua / tagset /
-- metadata definition calls it at load time. Without it those files cannot be
-- required here at all. The real one looks up a translation and falls back to
-- the default text after the '='; with no translations loaded that fallback is
-- exactly what Lightroom itself returns.
function LOC(key, ...)
  local text = tostring(key):match("^%$%$%$/[^=]*=(.*)$") or tostring(key)
  local args = { ... }
  return (text:gsub("%^(%d)", function(index)
    return tostring(args[tonumber(index)] or "")
  end))
end

-- Lightroom exposes 'import' as a global.
function import(name)
  local stub = stubs[name]
  if stub == nil then
    error("test stub missing for module: " .. tostring(name))
  end
  return stub
end

return {
  stubs = stubs,
  passwordStore = passwordStore,
  prefs = prefs,
  logLines = logLines,
  httpCalls = httpCalls,
  openedUrls = openedUrls,
  executedCommands = executedCommands,
  timeline = timeline,
  setExecuteExitCode = function(code) executeExitCode = code end,
  setConfirmAnswer = function(answer) confirmAnswer = answer end,
  dialogMessages = dialogMessages,
  moduleSwitches = moduleSwitches,
  floatingDialogs = floatingDialogs,
  catalogWrites = catalogWrites,
  createdKeywords = createdKeywords,
  refusedKeywords = refusedKeywords,
  newPhoto = newPhoto,
  exportSessions = exportSessions,
  createdDirectories = createdDirectories,
  deletedPaths = deletedPaths,
  setDeleteFails = function(fails) deleteFails = fails end,
  setRenderFailure = function(message)
    -- Lightroom does not promise waitForRender supplies a message, so failing
    -- and having something to say about it are separate.
    renderFailing = true
    renderFailureMessage = message
  end,
  setTargetPhotos = function(photos) targetPhotos = photos end,
  setAllPhotos = function(photos) allPhotos = photos end,

  -- Build the object tree deletePhotosFromPublishedCollection walks: a
  -- collection of published photos, each pairing a remote ID with a catalog
  -- photo. Keyed by the local collection ID Lightroom passes back.
  setPublishedCollection = function(localId, entries)
    local published = {}
    for i, entry in ipairs(entries) do
      published[i] = {
        getRemoteId = function() return entry.remoteId end,
        getPhoto    = function() return entry.photo end,
      }
    end
    publishedCollections[localId] = {
      getPublishedPhotos = function() return published end,
    }
  end,
  runPendingTasks = runPendingTasks,
  runInTask = runInTask,
  pendingTaskCount = function() return #pendingTasks end,
  resetHttp = function() httpCalls = {} end,
}
"""


class LuaPlugin:
    """A Lua 5.1 runtime preloaded with fake Lightroom SDK modules."""

    def __init__(self, http_handler: Any = None) -> None:
        # unpack_returned_tuples lets a Python HTTP stub return (body, headers)
        # and have Lua see two values, matching LrHttp.
        #
        # latin-1 rather than utf-8 because multipart bodies carry raw JPEG
        # bytes. It maps every byte to exactly one character and never fails,
        # so binary survives the round trip while ASCII (all our JSON) is
        # unaffected. utf-8 raises on the first 0xFF of a JPEG header.
        self.runtime = lua51.LuaRuntime(
            unpack_returned_tuples=True, encoding="latin-1"
        )
        globals_ = self.runtime.globals()

        globals_["PY_B64DECODE"] = lambda value: base64.b64decode(value)
        globals_["HTTP_HANDLER"] = http_handler

        # Let require() find the plugin's own modules (json, Log, ...).
        globals_["package"].path = str(PLUGIN_DIR / "?.lua")

        self.env = self.runtime.execute(_STUB_SOURCE)

    def require(self, module: str):
        """Load a plugin module by name, as the plugin itself would."""
        return self.runtime.globals()["require"](module)

    def call(self, fn, *args) -> tuple[Any, Any]:
        """Call a Lua function and always get back a (value, error) pair.

        Lua's multiple returns arrive through the bridge inconsistently: a
        trailing nil is dropped, so ``return true, nil`` and ``return true``
        are indistinguishable. Every function in this plugin follows the
        value-or-error convention, so normalising through a table keeps tests
        from having to care.
        """
        wrapper = self.runtime.eval(
            "function(fn, ...)"
            "  local value, err = fn(...)"
            "  return { value = value, err = err }"
            "end"
        )
        result = wrapper(fn, *args)
        return result["value"], result["err"]

    @property
    def prefs(self):
        return self.env["prefs"]

    @property
    def passwords(self):
        return self.env["passwordStore"]

    @property
    def log_lines(self) -> list[str]:
        lines = self.env["logLines"]
        return [lines[i] for i in range(1, len(lines) + 1)]

    @property
    def sleeps(self) -> list[float]:
        """Every LrTasks.sleep the plugin asked for, in seconds, in order."""
        waits = self.env["stubs"]["_sleeps"]
        return [waits[i] for i in range(1, len(waits) + 1)]

    @property
    def http_calls(self) -> list[dict]:
        """Every request the plugin made, in order, as plain dicts."""
        calls = self.env["httpCalls"]

        def headers_of(call) -> dict:
            raw = call["headers"]
            if raw is None:
                return {}
            return {
                raw[i]["field"]: raw[i]["value"] for i in range(1, len(raw) + 1)
            }

        return [
            {
                "method": calls[i]["method"],
                "url": calls[i]["url"],
                "body": calls[i]["body"],
                "headers": headers_of(calls[i]),
                "extra_args": calls[i]["extraArgs"],
            }
            for i in range(1, len(calls) + 1)
        ]

    def eval(self, source: str):
        return self.runtime.eval(source)

    @property
    def dialogs(self) -> list[dict]:
        """Messages that would have been shown to the user."""
        shown = self.env["dialogMessages"]
        return [
            {
                "title": shown[i]["title"],
                "message": shown[i]["message"],
                "style": shown[i]["style"],
            }
            for i in range(1, len(shown) + 1)
        ]

    @property
    def module_switches(self) -> list[str]:
        """Module names handed to LrApplicationView.switchToModule, in order."""
        switches = self.env["moduleSwitches"]
        return [switches[i] for i in range(1, len(switches) + 1)]

    @property
    def floating_dialogs(self) -> list:
        """Args of each presentFloatingDialog call, in order."""
        shown = self.env["floatingDialogs"]
        return [shown[i] for i in range(1, len(shown) + 1)]

    @property
    def opened_urls(self) -> list[str]:
        """URLs handed to LrHttp.openUrlInBrowser, in order."""
        urls = self.env["openedUrls"]
        return [urls[i] for i in range(1, len(urls) + 1)]

    @property
    def executed_commands(self) -> list[str]:
        """Command lines handed to LrTasks.execute, in order."""
        commands = self.env["executedCommands"]
        return [commands[i] for i in range(1, len(commands) + 1)]

    @property
    def timeline(self) -> list[str]:
        """Blocking calls in the order they happened.

        Entries are "floatingDialog" and "execute". Both block the calling task
        in Lightroom, so their relative order says whether work was handed to a
        separate task or run inline -- which a recording on its own cannot show.
        """
        events = self.env["timeline"]
        return [events[i] for i in range(1, len(events) + 1)]

    def set_execute_exit_code(self, code: int) -> None:
        """Make the next LrTasks.execute calls report this exit code."""
        self.env["setExecuteExitCode"](code)

    def set_confirm_answer(self, answer: str) -> None:
        """Make LrDialogs.confirm return this. Defaults to "cancel"."""
        self.env["setConfirmAnswer"](answer)

    def set_platform(self, windows: bool) -> None:
        """Flip the WIN_ENV / MAC_ENV pair Lightroom sets in the sandbox."""
        globals_ = self.runtime.globals()
        globals_["WIN_ENV"] = windows
        globals_["MAC_ENV"] = not windows

    @property
    def catalog_writes(self) -> list[str]:
        """Names of the write transactions opened, in order."""
        writes = self.env["catalogWrites"]
        return [writes[i] for i in range(1, len(writes) + 1)]

    @property
    def keywords(self) -> list[dict]:
        """Keywords created, as {"name", "parent"} with parent names."""
        created = self.env["createdKeywords"]
        return [
            {"name": created[i]["name"], "parent": created[i]["parent"]}
            for i in range(1, len(created) + 1)
        ]

    def add_keyword(self, name: str, parent: str | None = None) -> None:
        """Put a keyword in the catalog before anything runs.

        The user's own vocabulary, as opposed to the ones a sync creates. It
        writes through the same createKeyword the plugin uses, with the write
        flag flipped rather than a transaction opened, so seeding does not show
        up in catalog_writes as work the code under test did.

        Nesting is by parent *name*, which is all the stub catalog tracks.
        """
        seed = self.runtime.eval(
            "function(env, name, parentName)\n"
            "  local catalog = env.stubs.LrApplication.activeCatalog()\n"
            "  local parent = nil\n"
            "  if parentName then\n"
            "    for _, kw in ipairs(env.createdKeywords) do\n"
            "      if kw.name == parentName then parent = kw end\n"
            "    end\n"
            "  end\n"
            "  local wasWriting = catalog._writing\n"
            "  catalog._writing = true\n"
            "  catalog:createKeyword(name, {}, true, parent, true)\n"
            "  catalog._writing = wasWriting\n"
            "end\n"
        )
        seed(self.env, name, parent)

    def refuse_keyword(self, name: str) -> None:
        """Make catalog:createKeyword hand back nil for this name.

        Lightroom does this in circumstances the SDK does not document. What
        matters is that the plugin notices, rather than treating nil as "no
        parent" and creating the remainder of the lineage at the catalog root.
        """
        self.env["refusedKeywords"][name] = True

    @property
    def catalog(self):
        """The stub LrCatalog, for code that takes one as an argument."""
        return self.env["stubs"]["LrApplication"]["activeCatalog"]()

    def new_photo(self, raw=None, formatted=None, **properties):
        """Build a stub LrPhoto.

        ``properties`` become plugin custom metadata; ``raw`` and ``formatted``
        become getRawMetadata / getFormattedMetadata, which is what the upload
        path reads a photo's capture time, GPS and caption from.

        ``raw`` and ``formatted`` are converted all the way down. lupa's
        table_from only converts the outermost level, so a nested dict would
        arrive as a Python object -- and reading a key it does not have raises
        KeyError instead of returning nil, which is the opposite of what Lua
        does and would make the plugin look wrong when it is the stub that is.
        """
        return self.env["newPhoto"](
            self.runtime.table_from(properties),
            self._deep_table(raw or {}),
            self._deep_table(formatted or {}),
        )

    def _deep_table(self, value):
        if isinstance(value, dict):
            return self.runtime.table_from(
                {k: self._deep_table(v) for k, v in value.items()})
        if isinstance(value, list):
            return self.runtime.table_from(
                {i + 1: self._deep_table(v) for i, v in enumerate(value)})
        return value

    def set_published_collection(self, local_id, entries) -> None:
        """Populate catalog:getPublishedCollectionByLocalIdentifier(local_id).

        ``entries`` is a list of {"remoteId": ..., "photo": ...}.
        """
        self.env["setPublishedCollection"](
            local_id,
            self.runtime.table_from(
                [self.runtime.table_from(entry) for entry in entries]
            ),
        )

    def set_target_photos(self, photos) -> None:
        """Set what catalog:getTargetPhotos() returns."""
        self.env["setTargetPhotos"](self.runtime.table_from(list(photos)))

    def set_all_photos(self, photos) -> None:
        """Set the catalog that findPhotosWithProperty searches."""
        self.env["setAllPhotos"](self.runtime.table_from(list(photos)))

    def set_render_failure(self, message=None) -> None:
        """Make every rendition fail, optionally with a message."""
        self.env["setRenderFailure"](message)

    @property
    def export_sessions(self):
        """Every LrExportSession built, in order."""
        return list(self.env["exportSessions"].values())

    @property
    def created_directories(self):
        """Every path passed to LrFileUtils.createAllDirectories."""
        return list(self.env["createdDirectories"].values())

    @property
    def deleted_paths(self):
        """Every path passed to LrFileUtils.delete."""
        return list(self.env["deletedPaths"].values())

    def set_delete_fails(self, fails: bool = True) -> None:
        """Make LrFileUtils.delete raise, as a locked file would."""
        self.env["setDeleteFails"](fails)

    def view_factory(self):
        """A view factory that records arguments instead of rendering.

        Lets a test inspect the shape of a dialog -- what controls it has, what
        identifiers they carry -- without opening one.
        """
        return self.env["stubs"]["LrView"]["osFactory"]()

    def run_pending_tasks(self, reverse: bool = False) -> None:
        """Run queued async tasks, as Lightroom would once the caller returns.

        With ``reverse``, drains them back to front. Lightroom makes no promise
        about the order tasks finish in, so this is how a test shows that a
        refresh which started earlier but finished later cannot win.
        """
        self.env["runPendingTasks"](reverse)

    def pending_task_count(self) -> int:
        """How many async tasks are queued but not yet run."""
        return int(self.env["pendingTaskCount"]())

    def in_task(self, fn, *args):
        """Call a Lua function as though a task were already running.

        Parts of the catalog API refuse outside one, and the harness models
        that. Use this for a function the plugin only ever reaches from inside
        a task but whose return value a test wants directly.
        """
        return self.env["runInTask"](fn, *args)

    @property
    def pending_tasks(self) -> int:
        """How many async tasks are queued but not yet run.

        Useful for asserting that something dispatched work, when running that
        work would need more of Lightroom than the stubs provide.
        """
        return self.env["pendingTaskCount"]()

    def set_http_handler(self, handler) -> None:
        """Swap the HTTP stub mid-test."""
        self.runtime.globals()["HTTP_HANDLER"] = handler


def make_jwt(expires_at: int | None, *, payload: dict | None = None) -> str:
    """Build a structurally valid JWT. The signature is not checked locally."""
    import json as _json

    def segment(data: dict) -> str:
        raw = _json.dumps(data, separators=(",", ":")).encode()
        return base64.urlsafe_b64encode(raw).decode().rstrip("=")

    body = dict(payload or {})
    if expires_at is not None:
        body["exp"] = expires_at

    return f"{segment({'alg': 'HS512'})}.{segment(body)}.c2lnbmF0dXJl"
