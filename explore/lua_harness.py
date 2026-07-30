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
stubs.LrHttp = {
  get = function(url, headers)
    httpCalls[#httpCalls + 1] = { method = "GET", url = url, headers = headers }
    if HTTP_HANDLER then return HTTP_HANDLER("GET", url, nil, headers) end
    error("unexpected HTTP GET in test: " .. tostring(url))
  end,
  post = function(url, body, headers, method, contentType)
    httpCalls[#httpCalls + 1] =
      { method = method or "POST", url = url, body = body, headers = headers }
    if HTTP_HANDLER then
      return HTTP_HANDLER(method or "POST", url, body, headers)
    end
    error("unexpected HTTP POST in test: " .. tostring(url))
  end,
  openUrlInBrowser = function() end,
}

stubs.LrTasks = {
  startAsyncTask = function(fn) fn() end,
  sleep = function() end,
}

stubs.LrDate = {
  timeToUserFormat = function(_time, _format) return "2026-07-29" end,
}

-- UI modules. Enough shape to let the export provider load and to record what
-- would have been shown to the user.
local dialogMessages = {}
stubs.LrDialogs = {
  message = function(title, message, style)
    dialogMessages[#dialogMessages + 1] =
      { title = title, message = message, style = style }
  end,
  presentModalDialog = function() return "cancel" end,
}

stubs.LrErrors = {
  throwUserError = function(message)
    error({ userError = tostring(message) }, 0)
  end,
}

local function passthroughFactory()
  -- Every view constructor just records its arguments; nothing renders here.
  return setmetatable({}, {
    __index = function(_table, _key)
      return function(_self, args) return args or {} end
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

stubs.LrProgressScope = function(args)
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
  callWithContext = function(_name, fn) return fn({}) end,
}

local catalogWrites = {}
stubs.LrApplication = {
  activeCatalog = function()
    return {
      withWriteAccessDo = function(_self, name, fn)
        catalogWrites[#catalogWrites + 1] = name
        fn()
      end,
      createKeyword = function(_self, name) return { name = name } end,
      getTargetPhotos = function() return {} end,
    }
  end,
}

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
  dialogMessages = dialogMessages,
  catalogWrites = catalogWrites,
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
        return [
            {
                "method": calls[i]["method"],
                "url": calls[i]["url"],
                "body": calls[i]["body"],
            }
            for i in range(1, len(calls) + 1)
        ]

    def eval(self, source: str):
        return self.runtime.eval(source)

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
