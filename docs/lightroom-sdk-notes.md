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

## A plugin cannot add a panel to the Library right side

There is no Info.lua key for it, and looking for one costs an afternoon because
plugins like Assisted Culling visibly have panels between Histogram and Quick
Develop. They are not using the SDK. Dumping the shipped binaries settles it:

| Binary | Info.lua keys it recognises |
|---|---|
| `substrate.dll` (plugin loader) | `LrSdkVersion`, `LrSdkMinimumVersion`, `LrToolkitIdentifier`, `LrPluginName`, `LrInitPlugin`, `LrShutdownPlugin`, `LrEnablePlugin`, `LrDisablePlugin`, `LrExportServiceProvider`, `LrMetadataProvider`, `URLHandler` |
| `Library.lrmodule` | `LrLibraryMenuItems`, `LrExportMenuItems`, `LrHelpMenuItems`, `LrFilterPresetFactory`, `LrForceInitPlugin` |
| `LibraryToolkit.dll` | `LrMetadataTagsetFactory`, `LrPublishService` |

```powershell
$txt = [System.Text.Encoding]::ASCII.GetString(
  [System.IO.File]::ReadAllBytes("C:\Program Files\Adobe\Adobe Lightroom Classic\substrate.dll"))
[regex]::Matches($txt, 'Lr[A-Za-z]{3,45}') | ForEach-Object { $_.Value } | Sort-Object -Unique
```

Nothing resembling `LrLibraryPanelSections` exists anywhere in the product. A
third-party panel is a companion application's own window, positioned over the
panel column — not available to a pure Lua plugin.

The closest legitimate surface is `LrMetadataTagsetFactory`: a preset in the
Metadata panel's dropdown that shows a chosen set of fields. It is a preset,
not a new panel, so selecting it replaces whatever the user had there.

The temptation is to also ship a combined preset — plugin fields plus the
everyday Lightroom ones — so users are not giving anything up by leaving it
selected. This plugin tried that and dropped it. Default is one dropdown away,
a copy of Default is a second thing to keep in step with Lightroom, and two
near-identical entries in that menu is worse than switching.

## `URLHandler` is a real Info.lua key

Undocumented in most places you would look, but Adobe's own bundled
`Flickr.lrplugin` uses it, and `lightroom://` is registered as a system
protocol handler pointing at `Lightroom.exe`. The contract is confirmed by the
constant table of Flickr's compiled `URLHandler.lua` chunk (`import`,
`LrErrors`, `LrLogger`, `FlickrAPI`, `URLHandler`):

```lua
-- Info.lua
URLHandler = "URLHandler.lua",

-- URLHandler.lua
return { URLHandler = function(url) ... end }
```

A bare function, or a differently named key, is never called.

This matters because the Metadata panel renders a custom field of
`dataType = "url"` as a clickable row, and a row is the nearest thing to a
button that panel offers. A field holding
`lightroom://com.github.inat-lightroom/sync` is therefore a panel button.

**Confirmed in the host.** Clicking such a row in the Metadata panel does reach
the plugin's `URLHandler`, in a running Lightroom Classic with the plugin
installed. This is the mechanism the plugin's panel actions rely on.

A custom metadata field has no default value, so a field nothing has written to
renders nothing at all. Action links have to be written onto each photo before
they appear.

## Valid tagset field IDs come from Lightroom's own tagsets

A tagset naming a field ID Lightroom does not accept misbehaves without raising,
and the list of valid `com.adobe.*` IDs is not published anywhere convenient.

It is tempting to grep the binaries for `com.adobe.*` strings and use whatever
comes back. That is wrong, and quietly so: a string being present does not make
it a valid *tagset item*. `com.adobe.label` looks like the colour label and is
actually a section-heading formatter, only meaningful in table form with a
`label =` attribute; the colour label is `com.adobe.colorLabels`. Likewise
`com.adobe.keywords` exists as a string and is not a tagset item.

The authority is `AgMetadataTagsets.lua`, compiled into `LibraryToolkit.dll`,
which defines the built-in presets. Its string constants are readable in order,
so the Default preset's item list can be read straight out:

```powershell
$txt = [System.Text.Encoding]::ASCII.GetString(
  [System.IO.File]::ReadAllBytes("C:\Program Files\Adobe\Adobe Lightroom Classic\LibraryToolkit.dll"))
$i = $txt.IndexOf("com.adobe.tagsets.default")
($txt.Substring($i, 3000) -replace '[^\x20-\x7E]','.') -replace '\.{3,}',' | '
```

Anything the built-in tagsets use is safe. `explore/test_panel_actions_lua.py`
holds that list and asserts this plugin's tagsets stay inside it.

Plugin fields are addressed as `<LrToolkitIdentifier>.<field id>`; a bare field
ID silently resolves to nothing.

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
Never `require` such a file from another module. This is not theoretical: the
sync used to live in `SyncObservation.lua`, which made it unreachable from
anywhere except its own menu item, and adding a second caller meant extracting
the logic into `SyncCore.lua` first. `PluginInit.lua` had the same problem —
requiring it opened the credentials dialog as a side effect.

The pattern that works is a module holding the logic and a two-line script
holding the entry point. `explore/test_panel_actions_lua.py` asserts no module
requires a menu script.

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
