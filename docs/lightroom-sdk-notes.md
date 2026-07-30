# Lightroom SDK notes

Things the SDK does that cost real debugging time on this plugin. Each was
found by a failure inside Lightroom, and each is now covered by a test in
`explore/` so it cannot come back quietly.

Companion to [inat-api-notes.md](inat-api-notes.md), which covers the
iNaturalist API's own traps.

---

## Lightroom runs Lua 5.1

Not 5.3, not 5.4. So none of these exist:

| Construct | Introduced in |
|---|---|
| `\|` `&` `~` `<<` `>>` (bitwise) | 5.3 |
| `//` (integer division) | 5.3 |
| `goto` / `::label::` | 5.2 |

They are **syntax errors at load time**, so the entire plugin fails to load
with a message pointing at one line of one file. The bundled `json.lua` used
bitwise operators in its UTF-8 encoder and took the whole plugin down.

Checking with a parser that accepts 5.3 is worse than not checking, because it
tells you the code is fine. `explore/check_lua.py` parses every plugin file
under a real 5.1 interpreter; `explore/test_lua_syntax.py` also feeds it known
5.3-only code and asserts it is **rejected**.

```powershell
.\.venv\Scripts\python.exe check_lua.py
```

Run it before asking Lightroom to reload.

## `LrHttp.post`'s fifth argument is a timeout, not a content type

```lua
LrHttp.post(url, body, headers, method, timeout)
```

Passing `"application/json"` there means **the request is never made**. There is
no error: the body comes back `nil` and the only symptom is whatever your code
says when it gets no response. Content type belongs in `headers`.

`LrHttp.get` has a different signature and is unaffected, so authentication and
search kept working while every upload failed — a useful signal when only
writes are broken.

## `LrHttp` reports transport failures in the headers table

When a request fails outright there is no body. The reason is in the *headers*
return value:

```lua
local body, respHeaders = LrHttp.get(url)
if not body then
  local reason = respHeaders and respHeaders.error
  -- reason.name, reason.errorCode
end
```

Discard that and every network problem looks identical.

## `LrCatalog:createKeyword` needs write access

It must be called inside `catalog:withWriteAccessDo`, like the metadata
setters. Build the keyword hierarchy inside the same transaction that applies
it.

```lua
catalog:withWriteAccessDo("iNat sync", function()
  local keyword = catalog:createKeyword(name, {}, true, parent, true)
  photo:addKeyword(keyword)
end)
```

The fifth argument (`returnExistingIfAny`) is what makes the call idempotent —
without it, creating a keyword that already exists is an error, so every sync
after the first would fail.

## A function context ends when its owning function returns

This looks reasonable and is wrong:

```lua
LrFunctionContext.callWithContext("job", function(context)
  LrTasks.startAsyncTask(function()
    local progress = LrProgressScope { functionContext = context }  -- dead
  end)
end)
```

`callWithContext` returns as soon as the task is *queued*, so the context is
already finished by the time the task runs. Use the call that pairs them:

```lua
LrFunctionContext.postAsyncTaskWithContext("job", function(context)
  -- one task, one context, same lifetime
end)
```

The exception is a modal dialog, which blocks and so keeps its context alive
for anything started underneath it.

## `exportSession:renditions()` is an iterator

Calling it directly hands back the loop *index* first, so `renditions()()` is a
number, not a rendition:

```lua
for _, rendition in exportSession:renditions() do ... end
```

To look at the photos without disturbing the rendition queue, use
`exportSession:photosToExport()`, which returns `LrPhoto` objects directly.

## `LrLogger` writes nothing until it is enabled

`LrLogger("name")` returns a logger that silently discards everything until
`enable("logfile")` is called **on that instance**. Sharing a logger *name*
across modules does not share its enablement, so a module that creates its own
logger logs nothing.

This plugin has one `Log.lua` that enables a single logger; every module
requires it. Output lands in `~/Documents/LrClassicLogs` (Windows) or
`~/Library/Logs/Adobe/Lightroom/LrClassicLogs/` (macOS).

Note that a menu-item script only loads when the menu item is *clicked*, so
putting logger setup there means nothing logs during an export.

## `LrPasswords` is already plugin-scoped

```lua
LrPasswords.store(key, value)
LrPasswords.retrieve(key)
```

No plugin ID argument — it is implicit. Storage is the OS credential vault.

## `LrApplication.activeCatalog()`, not `LrCatalog`

`LrCatalog` is the type of the object you get back, not a module with an
`activeCatalog` function.

## Raw `dateTimeOriginal` counts from 2001-01-01

Lightroom's raw metadata uses the Cocoa epoch, not the Unix one, so `os.date`
lands 31 years early. Use `LrDate.timeToUserFormat` / `LrDate.timeToW3CDate`,
and `LrDate.currentTime()` for "now".

## Menu-item scripts run on load

Anything in `LrLibraryMenuItems` executes its file top to bottom when clicked.
Never `require` such a file from another module — this plugin's `PluginInit.lua`
opens the credentials dialog as a side effect of loading.

## `LrBinding.negativeOfKey` returns a boolean

It is for enabling and disabling controls. It is not a way to derive one
displayed string from another, which makes it the wrong tool for an export
`synopsis`.

---

## Testing without Lightroom

Every bug above only appeared by running Lightroom, clicking through, and
reading a screenshot. `explore/lua_harness.py` exists to shorten that loop: it
runs the plugin's real Lua under Lua 5.1 with stubbed SDK modules.

```python
from lua_harness import LuaPlugin

plugin = LuaPlugin()
api = plugin.require("InatAPI")
```

**The stubs are the interesting part.** They deliberately enforce the rules
above — the catalog refuses writes outside a transaction, progress scopes
reject a finished context, async tasks queue instead of running inline, and
`LrHttp.post` records arguments past the fourth. A permissive stub is worse
than no stub, because it produces a green suite and a broken plugin.

What this cannot tell you is whether the real SDK behaves like the stubs, or
whether a function exists at all. It proves logic, not conformance. Anything
new still needs one pass through Lightroom.

When fixing a bug, check the new test actually fails against the old code —
ideally with the same message the user saw. Two tests in this repo were caught
being worthless that way.
