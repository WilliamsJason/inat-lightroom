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

PLUGIN_DIR = Path(__file__).resolve().parent.parent / "plugin" / "inat.lrplugin"

# Lua source for the fake SDK. Kept as Lua rather than built through the bridge
# so that table semantics (methods called with ':') behave normally.
_STUB_SOURCE = """
local stubs = {}

-- Captures every logged line so tests can assert on them if useful.
local logLines = {}

stubs.LrLogger = function(_name)
  local logger = {}
  local function record(level)
    return function(_self, message)
      logLines[#logLines + 1] = level .. ": " .. tostring(message)
    end
  end
  logger.enable = function() end
  logger.trace = record("trace")
  logger.debug = record("debug")
  logger.info  = record("info")
  logger.warn  = record("warn")
  logger.error = record("error")
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
    httpCalls[#httpCalls + 1] = { method = "GET", url = url, headers = headers }
    if HTTP_HANDLER then return HTTP_HANDLER("GET", url, nil, headers) end
    error("unexpected HTTP GET in test: " .. tostring(url))
  end,
  -- The real LrHttp.post takes (url, body, headers, method, timeout). Anything
  -- beyond the fourth argument is recorded so tests can assert we are not
  -- passing a content type positionally, which silently stops the request.
  post = function(url, body, headers, method, ...)
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

local function runPendingTasks()
  while #pendingTasks > 0 do
    local fn = table.remove(pendingTasks, 1)
    fn()
  end
end

stubs.LrTasks = {
  startAsyncTask = function(fn) pendingTasks[#pendingTasks + 1] = fn end,
  sleep = function() end,
  -- Lightroom's own pcall, which unlike Lua's can be used around code that
  -- yields. Same contract, so the plain one is a faithful stand-in.
  pcall = function(fn, ...) return pcall(fn, ...) end,
}

stubs.LrDate = {
  timeToUserFormat = function(_time, _format) return "2026-07-29" end,
  timeToW3CDate = function(_time) return "2026-07-29T19:36:41Z" end,
  currentTime = function() return 807126000 end,
}

-- UI modules. Enough shape to let the export provider load and to record what
-- would have been shown to the user.
local dialogMessages = {}
local floatingDialogs = {}
stubs.LrDialogs = {
  message = function(title, message, style)
    dialogMessages[#dialogMessages + 1] =
      { title = title, message = message, style = style }
  end,
  presentModalDialog = function() return "cancel" end,

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

stubs.LrBinding = {
  makePropertyTable = function() return {} end,
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

local catalogWrites = {}
local createdKeywords = {}
local targetPhotos = {}
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

  withWriteAccessDo = function(self, name, fn)
    catalogWrites[#catalogWrites + 1] = name
    self._writing = true
    local ok, err = pcall(fn)
    self._writing = false
    if not ok then error(err, 0) end
  end,

  -- The variant an export task must use: the ordinary write can block on a
  -- transaction the export itself is holding. It takes no name, which is the
  -- easiest way for a test to tell the two apart.
  withPrivateWriteAccessDo = function(self, fn)
    catalogWrites[#catalogWrites + 1] = "<private>"
    self._writing = true
    local ok, err = pcall(fn)
    self._writing = false
    if not ok then error(err, 0) end
  end,

  -- createKeyword(name, synonyms, includeOnExport, parent, returnExistingIfAny)
  createKeyword = function(_self, name, _synonyms, _include, parent, returnExisting)
    requireWriteAccess("LrCatalog:createKeyword")
    local parentName = parent and parent.name or nil
    for _, keyword in ipairs(createdKeywords) do
      if keyword.name == name and keyword.parent == parentName then
        if returnExisting then return keyword end
        error("LrCatalog:createKeyword: keyword exists: " .. name, 0)
      end
    end
    local keyword = { name = name, parent = parentName }
    createdKeywords[#createdKeywords + 1] = keyword
    return keyword
  end,

  getTargetPhotos = function() return targetPhotos end,

  getPublishedCollectionByLocalIdentifier = function(_self, localId)
    return publishedCollections[localId]
  end,
}

stubs.LrApplication = {
  activeCatalog = function() return catalog end,
}

-- Lightroom exposes the plugin object as a global.
_PLUGIN = { id = "com.github.inat-lightroom" }

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
  dialogMessages = dialogMessages,
  floatingDialogs = floatingDialogs,
  catalogWrites = catalogWrites,
  createdKeywords = createdKeywords,
  newPhoto = newPhoto,
  setTargetPhotos = function(photos) targetPhotos = photos end,

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

    @property
    def catalog(self):
        """The stub LrCatalog, for code that takes one as an argument."""
        return self.env["stubs"]["LrApplication"]["activeCatalog"]()

    def new_photo(self, raw=None, formatted=None, **properties):
        """Build a stub LrPhoto.

        ``properties`` become plugin custom metadata; ``raw`` and ``formatted``
        become getRawMetadata / getFormattedMetadata, which is what the publish
        path reads a photo's capture time, GPS and caption from.
        """
        return self.env["newPhoto"](
            self.runtime.table_from(properties),
            self.runtime.table_from(raw or {}),
            self.runtime.table_from(formatted or {}),
        )

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

    def run_pending_tasks(self) -> None:
        """Run queued async tasks, as Lightroom would once the caller returns."""
        self.env["runPendingTasks"]()

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
