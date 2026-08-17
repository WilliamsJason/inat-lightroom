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

## The catalog queries a plugin gets, and the date vocabulary they accept

`LibraryToolkit.dll` exposes a `SdkLrCatalogQueries` set — the plugin-facing one
— which includes the three calls any whole-catalog operation needs:

| Call | Why it matters |
|---|---|
| `catalog:findPhotos{ searchDesc = ..., sort = ..., ascending = ... }` | narrows the catalog before anything is read |
| `catalog:batchGetRawMetadata(photos, keys)` | one call instead of a `getRawMetadata` loop |
| `catalog:batchGetPropertyForPlugin(photos, ...)` | the same for this plugin's own fields |

`findPhotos` asserts its arguments, and the assertion strings say exactly what it
wants: *"must be called with named arguments syntax"*, *"searchDesc must be a
table or nil"*, *"sort must be a string or nil"*, *"ascending must be a boolean
or nil"*, and — easy to miss — *"must be called from within an LrTask"*.

The date operations are a fixed list, sitting next to `import AgDate`:

```
== != > < inLast notInLast in today yesterday thisWeek thisMonth
thisYear pastYear lastYear anytime thisWeekUntilToday range ...
```

So a capture-time range is `operation = "in"` with `value` and `value2`, and
`criteria = "captureTime"` is real — `Library.lrmodule` ships the "Past Month"
smart collection as plain Lua using `criteria = "captureTime", operation =
"inLast", value = 1, value_units = "months"`, which is where the criteria name
and the `value_units` key can be read off directly.

**What the binaries cannot say is how long any of it takes.** That needs a real
catalog, which is what `explore/probes/sdkprobe.lrplugin` is for.



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

## An SDK call that never returns usually means a bad argument

Not slow work. Two independent cases, both found by a probe that appeared to
hang:

```lua
-- operation the date vocabulary does not list: never returns
catalog:findPhotos { searchDesc = {
  { criteria = "captureTime", operation = ">=", value = "2000-01-01" },
  combine = "intersect" } }

-- _PLUGIN where a plugin id string belongs: never returns
catalog:batchGetPropertyForPlugin(photos, keys, _PLUGIN)
```

Neither raises, neither times out, and Lightroom stays responsive enough that
the plugin looks busy rather than stuck. The rule that follows: build search
descriptors and argument lists from fixed tables of known-good values, never by
assembling strings, because a typo costs a hang rather than an error.

Contrast the *good* failures, which are precise enough to reverse-engineer a
signature from. `batchGetPropertyForPlugin` complained about a different
argument each time it was moved:

```
(photos, {keys})      -> bad argument #1 to 'ipairs' (table expected, got nil)
(photos, {keys}, id)  -> bad argument #1 to 'ipairs' (table expected, got string)
```

What it iterates is the *third* argument, so the keys go last:

```lua
-- 500 photos, one key, 36 ms; result keyed by photo object
catalog:batchGetPropertyForPlugin(photos, "com.example.plugin", { "my_key" })
```

## `captureTime` searches honour seconds, but only in one date format

`LrDate.timeToW3CDate` produces `2017-04-29T17:22:25.000+00:00`, and
`findPhotos` matches **nothing** against it. No error — an empty result, which
is indistinguishable from a window that genuinely holds no photo. Measured on
one photo's own capture time:

| value format | matches |
| --- | --- |
| `timeToW3CDate` | 0 |
| `%Y-%m-%dT%H:%M:%S` | 1 |
| `%Y-%m-%d` | 1 |

So build the value with `LrDate.timeToUserFormat(when, "%Y-%m-%dT%H:%M:%S")`.

The time part is really compared, rather than rounded away to the day. A
±2 second window against the whole day containing it, on a day holding several
photos:

```
±2 s = 2 vs whole day = 5
```

Which makes a narrow window query the cheap way to ask "what did I shoot at
this instant":

```lua
catalog:findPhotos { searchDesc = {
  { criteria = "captureTime", operation = "in", value = from, value2 = to },
  combine = "intersect" } }
```

Measured at **1.7 ms** average over 25 windows on a 6,591 photo catalog, and
the cost is Lightroom's own index rather than anything proportional to the
result. That is what makes matching scale by the number of things being looked
up rather than by the size of the catalog.

## `batchGetRawMetadata` is worth it, and one bad key fails all of them

Over a 500 photo sample:

| call | keys | time |
| --- | --- | --- |
| `batchGetRawMetadata` | 8 | 107 ms |
| `getRawMetadata` loop | 2 | 377 ms |

Roughly ten times cheaper per key, and the result is keyed by the photo object,
not by index:

```lua
local rows = catalog:batchGetRawMetadata(photos, { "dateTimeOriginal", "gps" })
local when = rows[photo].dateTimeOriginal
```

But the call is all-or-nothing. Asking for one key it does not know throws away
every other column:

```
Unknown key: "fileName"
```

`fileName` is *formatted* metadata, not raw. Keys confirmed to work:
`dateTimeOriginal`, `dateTimeOriginalISO8601`, `captureTime`, `gps`,
`gpsAltitude`, `path`, `uuid`, `isVirtualCopy`. Validate a key list once
against a single photo before running it over a catalog, so an unknown key
costs one call rather than the whole read.

## A plain `pcall` around an SDK call silently breaks it

`pcall` stops the code inside it from yielding, and most of the interesting SDK
is asynchronous underneath. What comes back is not "you used pcall wrong", it is
one of these:

```
Yielding is not allowed within a C or metamethod call
LrCatalog:findPhotos: must be called from within an LrTask
```

The second is the cruel one. It is reported while running inside a perfectly
good `postAsyncTaskWithContext`, because what the SDK actually tests is whether
yielding is possible *right now* — and inside a `pcall` it is not. Chasing the
message leads to auditing task creation, which is not where the problem is.

`getAllPhotos` was quieter still: wrapped in a `pcall` it returned an **empty
list** rather than raising, which reads as an empty catalog.

`LrTasks` exports a replacement. The full export list, from `LightroomSDK.dll`:

```
startAsyncTask startAsyncTaskWithoutErrorHandler pcall canYield
canYieldToScheduler sleep yield yieldToScheduler execute executeWithRunAsVerb
```

So use `LrTasks.pcall(f, ...)`, which has `pcall`'s signature and lets what it
calls yield. Plain `pcall` remains correct for things that genuinely cannot
yield — `string.format`, `io`, reading a field off a table. Note that indexing
is beyond rescue either way: Lua cannot yield across a metamethod at all.

### The second symptom, which reads as a different bug

The message above is what you get when the SDK notices in advance. The other
one arrives from Lua itself, after the call has already started:

```
Yielding is not allowed within a C or metamethod call
```

It names neither `pcall` nor the call that yielded, and it is what
`catalog:createKeyword` produces when it runs inside a plain `pcall`.

This cost a whole Reverse Sync run. Each row was wrapped in a plain `pcall` so
that one bad observation could not abandon the other ninety-nine — and every
row then failed, because linking creates the taxon's keyword path. The failures
were caught and counted exactly as designed, so the result was "Linked 0
photo(s), 1 could not be linked": a report that reads as a matching problem
rather than a Lua one. A defensive `pcall` is precisely where this hides,
because its whole purpose is to turn an error into a count.

The harness models the rule now: it replaces `pcall` with one that records that
a plain `pcall` is on the stack, leaves `LrTasks.pcall` alone, and makes the
stubs for `createKeyword`, `withWriteAccessDo` and `LrHttp` refuse to run while
one is. Reverting the fix makes the test fail with the same error Lightroom
gave, which is the only way to know the guard guards anything.

## A menu item does not run in a task, and a dialog built from one can raise

`LrFunctionContext.callWithContext` does not create a task. Neither does the
script Lightroom runs when a **Plug-in Extras** item is clicked. So a dialog
whose *construction* touches the catalog raises before it can appear:

```
An internal error has occurred: We can only wait from within a task
```

Unlike the `pcall` messages above, this one is shown to the user, and it names
neither the call nor the module. The window simply never opens.

`catalog:getKeywords()` is one such call. The settings dialog began walking it
to build the keyword-root picker, which turned "Pinned Settings…" into that
dialog for every user — while all 37 tests for the module still passed, because
a stub that hands back a table cannot refuse. `SettingsDialog.show` posts a task
now, and the harness's `getKeywords` refuses outside one, so opening the dialog
the way the menu does is a test rather than a thing you find in the host.

### The second failure is worse than the first, because it is silent

Posting the task did not fix the dialog. It moved the failure: the walk also
asks each keyword its name, and `LrKeyword:getName` and `getChildren` need
**read access**, because a keyword is a handle into the catalog rather than a
value copied out of it. So the next error was raised *inside* the task — and an
error raised there is not reported anywhere. No dialog, no log line. The menu
item did nothing at all when clicked, which is a worse bug report than the
error dialog was.

The walk belongs in one `catalog:withReadAccessDo` for the whole tree, not one
per keyword: it is a lock, and a tree that is not changing does not need it
taken thousands of times. Note that a **write** block is read access too, which
is why `SyncCore` has never needed one of its own — and why the harness's guard
trips only the code that reads without either.

Two habits come out of this, both about the silence rather than the API:

- **Log the entry point of any task a user action starts.** "Did it even try"
  is otherwise unanswerable, and it is the first question.
- **Guard the optional part.** The picker is a convenience; the dialog holds
  every setting in the plugin, including the credentials. A failed catalog read
  should cost the popup, not the window.

The general shape: **the pieces of a dialog can be unit tested individually and
still fail together**, because what breaks is the context they are assembled in.
Something has to open it the way the user does.

### The third failure: `table.sort` is a C call too

The guard above worked. It was also the only thing standing between the user and
a picker that offered nothing, because the walk still failed — three releases
running, in the same twenty lines:

```
Settings: could not list keywords for the picker:
Yielding is not allowed within a C or metamethod call
```

The message is the `pcall` one, and there was no `pcall`. The culprit was the
comparator:

```lua
table.sort(sorted, function(a, b) return a:getName() < b:getName() end)
```

`table.sort` is a C function that calls back into Lua, so the comparator runs
across the same C boundary a `pcall` puts up — and `getName` yields. Nothing in
the shape of the line says "SDK call inside a C call", which is exactly the
thing to look for. The fix is to read every name *before* sorting, and sort on
the values:

```lua
for _, kw in ipairs(keywords or {}) do
  sorted[#sorted + 1] = { keyword = kw, name = kw:getName() }
end
table.sort(sorted, function(a, b) return a.name < b.name end)
```

Generalised: **read the catalog into plain values before handing anything to a
C function that calls your code back** — `table.sort` is the common one, and
any `__index`/`__lt` metamethod is the same trap.

Two things about how this survived so long:

- The harness counted only `pcall`, so its stubs happily yielded inside a
  comparator. It now wraps `table.sort` on the same counter, and `getName`,
  `getChildren` and `getKeywords` announce that they yield. Reverting the
  comparator fails two tests with Lightroom's own message.
- **A guard that logs is a place bugs go to live.** Every direct test of
  `keywordRootItems` passed, because the harness let the sort work; in the host,
  the failure was swallowed by the very `LrTasks.pcall` that keeps the dialog
  open, and surfaced only as a popup with one row in it. Where a fallback
  exists, assert that it was *not* taken — the dialog's test now fails if the
  warning is logged at all.

## A `popup_menu` does not cope with a long list -- so do not build one

`f:popup_menu` puts every item on screen at once. Given a few hundred it draws
a menu the height and width of the display, with the longest title setting the
width and a scroll arrow at each end. There is no `max_visible`, no filtering,
and no truncation.

The keyword-root picker hit this the moment it worked: it listed the catalog's
whole keyword tree, and on a synced catalog that tree is mostly the plugin's
own taxonomy -- five hundred rows of `iNaturalist > Animalia > Arthropoda > …`
covering the screen. The item cap that was supposed to protect against this was
doing its job perfectly; five hundred items is still unusable.

A cap on **quantity** is not the same as a cap on **relevance**. The list is
two levels deep now, which is where roots actually live, and the cap stayed as
a backstop for a catalog that is wide rather than deep. When a control cannot
show a big list, the answer is a smaller question, not a bigger control -- and
in a dialog with a free-text field beside it, "type the rest" is a real answer.

## `f:static_text` drops a word rather than clipping it

Given a fixed `width`, a `static_text` whose contents do not fit does not
truncate mid-word or add an ellipsis. The word that does not fit is simply not
drawn.

In the Reverse Sync review list each row was one control holding
`species — folder/file.jpg`. Rows with short species names looked perfect.
Rows with long ones drew the species, the separator, and then nothing at all:

```
Narrow-collared Snail-eating Beetle (Scaphinotus angusticollis)  —
```

The filename is a single unbreakable 31-character token, so once the species
name had eaten the width there was nowhere to put it and it disappeared whole.
Nothing about the row said it had been shortened, so it read as a match with no
file behind it -- a data problem rather than a layout one, which is where the
first hour went. Adding scientific names lengthened every title at once and
turned one bad row into many, which is what finally identified it.

Two lessons. Give each piece of information its own control, so the thing that
overflows is the thing that is too long. And when text goes missing, suspect the
layout before the string -- the bytes were checked first here, and they were
fine.

## A bound `visible` does not hide a row

`visible` is documented as a view property and is accepted on an `f:row`
without complaint:

```lua
f:row {
  bind_to_object = props,
  visible = LrView.bind("visible" .. row),
  ...
}
```

It binds, the property changes, and the row keeps drawing. Setting it false
left nine rows on the last page of the Reverse Sync review list showing an
empty checkbox beside a placeholder tile -- which reads as nine matches the
feature failed to describe, rather than as nine rows that should not be there.

Combined with the view tree being fixed once a dialog is presented -- rows
cannot be added or removed -- the only thing a paged list can control is which
data its rows point at. So the last page is padded backwards: it ends on the
last item and begins a full page before it, overlapping the previous page,
rather than being left short. That is only safe because selection is keyed by
item index rather than held in the widgets, so an item shown on two pages is
one answer seen twice.

Not established: whether `visible` works on other view types, or only fails to
collapse layout while still hiding content. Neither was worth another probe
once the padding removed the need for it.

## A `scrolled_view` cannot be scrolled from code

There is no scroll position to read or write. `f:scrolled_view` takes
`width`, `height` and its scroller flags, and the view it returns carries
nothing that moves it; the SDK exposes no `scrollTo`, no bindable offset, and
no way to bring a child into view. Adobe's own forums have the question
outstanding with no answer.

This shows up the moment a scrolled list is paged. The Reverse Sync review
list draws twenty-five rows about 100pt tall inside a 460pt viewport, so
roughly four and a half are visible at a time. Turning to the next page
repoints those rows at new data but leaves the scroller exactly where it was,
so a user who read to the bottom of one page arrives at the bottom of the next
and has to scroll back up to see the twenty rows above it.

The only real fix is to stop scrolling: size the page to what the window shows
so every page turn lands on a whole page, because there is no position to be
away from. That trades rows per page for pages -- at the current thumbnail
size roughly eight rows against twenty-five -- and was offered and declined, on
the grounds that scrolling a big page beats clicking through three times as
many small ones. Recorded so the next person reaches for the page size rather
than for an API that is not there.

## `f:edit_text` is Mac-only
In `ui.dll`'s factory constant list it sits directly behind a `MAC_ENV` guard:

```
... color_well edit_field MAC_ENV edit_text combo_box password_field ...
```

On Windows `f:edit_text` is simply `nil`, and the failure is
`attempt to call method 'edit_text' (a nil value)` at the moment the view is
built. Use `f:edit_field` with `height_in_lines` for multi-line text.

Worth checking any control against that list before relying on it — `MAC_ENV`
appears 161 times in `ui.dll`, so this is unlikely to be the only one.



Calling it directly hands back the loop *index* first, so `renditions()()` is a
number, not a rendition:

```lua
for _, rendition in exportSession:renditions() do ... end
```

To look at the photos without disturbing the rendition queue, use
`exportSession:photosToExport()`, which returns `LrPhoto` objects directly.

Measured for `LrExportSession` too, not only for the `exportContext` an export
provider is handed: a probe in Lightroom Classic 14 reported `first=number 1`,
`second=table`, so both take the same shape.

## `f:simple_list` scales; hand-built scrolled rows do not

A review list of a few thousand rows can be built either way. Only one of them
survives it. Timings are open-plus-dismiss, so roughly 2.2 s of every figure is
human reaction time, present in all of them:

| rows | `scrolled_view` of built rows | `simple_list` |
| --- | --- | --- |
| 250 | 4.2 s | — |
| 500 | 5.2 s | 4.3 s |
| 1000 | **14.9 s** | — |
| 5000 | — | **7.1 s** |

Hand-built rows degrade faster than linearly and are unusable by a thousand.
`simple_list` takes ten times the items for less than half the cost, because it
wraps a native `table_view` rather than instantiating a view per row.

Building the list is never the slow part — 5000 items assemble in about 5 ms.
The cost is in realising the views.

With `allows_multiple_selection`, its `value` is a table of selected indexes,
so "everything selected, deselect what you do not want" is the natural default:

```lua
f:simple_list {
  items = labels,
  allows_multiple_selection = true,
  value = LrView.bind("selection"),   -- a table, not a number
}
```

## `export_destinationType = "tempFolder"` needs an export service provider

A plugin with no `LrExportServiceProvider` cannot render into Lightroom's temp
folder, even though the destination type is real — it has its own preset label
(`$$$/AgExport/DestinationFolder/TempFolder`) and its own progress scope
(`$$$/AgExport/ToPluginTempDir/ScopeOperation…`). Asking for it produces:

```
export settings are missing the LR_export_destinationPathPrefix
```

which names the wrong field and sends you looking in the wrong place. The
reason is in `Export.lrmodule`: the destination is resolved as

```lua
if kind == "specificFolder" or kind == "chooseLater" then
  dir = settings.export_destinationPathPrefix
else
  dir = LrPathUtils.getStandardFilePath(kind)   -- "tempFolder" -> nil
end
assert(type(dir) == "string",
  "export settings are missing the LR_export_destinationPathPrefix")
```

`tempFolder` *is* handled, but in `addRenditionsForPhotos`, and only when the
export service provider declares **`exportToTemporaryLocation`** — a name that
sits in the binary's list of provider callbacks beside `processRenderedPhotos`
and `sectionsForTopOfDialog`. It is something a plugin's own provider declares
about itself.

Beware `canExportToTemporaryLocation`, which is a *different* name appearing
nearby. Reading the two as one fact is what produced the failed attempt above.

Without a provider, do what Lightroom does: build a directory under
`LrPathUtils.getStandardFilePath("temp")`, pass it as
`LR_export_destinationPathPrefix` with `LR_export_destinationType =
"specificFolder"`, and delete it afterwards.

## Omitted export settings come from the user's last export

`LrExportSession` does not apply documented defaults to keys you leave out —
`fillInDefaultSettings` fills them from the user's own preferences. So an
omitted key does not mean "the sensible default", it means "whatever that
person happened to do last time", which is invisible on the machine it was
written on and a bug report from everyone else.

Supply a complete preset. Four omissions that each look harmless:

| Key | Lightroom's value | What it does to an upload |
| --- | --- | --- |
| `collisionHandling` | `"ask"` | Halts the render with a dialog. Two selected photos *do* collide: `DSC0001.ARW` and `DSC0001.JPG` both render to `DSC0001.jpg`. Use `"rename"` — `"overwrite"` silently drops one. |
| `reimportExportedPhoto` | user's last | Adds a duplicate of every uploaded photo back into the catalog |
| `export_postProcessing` | `"revealInFinder"` in shipped presets | Opens a file browser on a temp folder mid-upload. Use `"doNothing"`. |
| `includeVideoFiles` | user's last | Passes a video through as an image; it fails later at upload, where the message makes no sense |

The full set of valid keys and values is easiest to read from the export
presets embedded in `Export.lrmodule` as plain Lua source — search for
`collisionHandling = "ask"`.

## A plugin cannot add a panel to the Library right side

There is no Info.lua key for it, and looking for one costs an afternoon because
plugins like Assisted Culling visibly have panels between Histogram and Quick
Develop. They are not using the SDK. Dumping the shipped binaries settles it:

| Binary | Info.lua keys it recognises |
|---|---|
| `substrate.dll` (plugin loader) | `LrSdkVersion`, `LrSdkMinimumVersion`, `LrToolkitIdentifier`, `LrPluginName`, `LrInitPlugin`, `LrShutdownPlugin`, `LrEnablePlugin`, `LrDisablePlugin`, `LrExportServiceProvider`, `LrMetadataProvider`, `URLHandler` |
| `Library.lrmodule` | `LrLibraryMenuItems`, `LrExportMenuItems`, `LrHelpMenuItems`, `LrFilterPresetFactory`, `LrForceInitPlugin` |
| `LibraryToolkit.dll` | `LrMetadataTagsetFactory`, `LrPublishService` |
| `Export.lrmodule` | `LrExportServiceProvider`, `LrExportFilterProvider`, `URLHandler` |
| `LightroomSDK.dll` | `LrPluginInfoProvider`, `LrPluginInfoUrl` |

That is the whole list. Searched for and **not found in any binary**: `LrPanel`,
`LrLibraryPanel`, `LrDevelopPanel`, `LrViewProvider`, `LrInspector`,
`LrModulePanel`, `LrCustomPanel`, `LrSidePanel`.

```powershell
$txt = [System.Text.Encoding]::ASCII.GetString(
  [System.IO.File]::ReadAllBytes("C:\Program Files\Adobe\Adobe Lightroom Classic\substrate.dll"))
[regex]::Matches($txt, 'Lr[A-Za-z]{3,45}') | ForEach-Object { $_.Value } | Sort-Object -Unique
```

Nothing resembling `LrLibraryPanelSections` exists anywhere in the product. The
docking machinery itself is there — `AgViewWinPanelHost::DockOrUndockPanel` and
friends in `ui.dll` — but it is internal C++ that no manifest key reaches. A
third-party panel is a companion application's own window, positioned over the
panel column — not available to a pure Lua plugin.

The closest legitimate surface is `LrMetadataTagsetFactory`: a preset in the
Metadata panel's dropdown that shows a chosen set of fields. It is a preset,
not a new panel, so selecting it replaces whatever the user had there.

## Which menu a plugin's items land in, and why there are only three

`Info.lua` offers a choice of exactly three parents, and the key names are
misleading — `LrExportMenuItems` has nothing to do with exporting, it just
means the File menu:

| `Info.lua` key | Menu it appears under |
|---|---|
| `LrExportMenuItems` | **File** › Plug-in Extras |
| `LrLibraryMenuItems` | **Library** › Plug-in Extras |
| `LrHelpMenuItems` | **Help** › Plug-in Extras |

`Library.lrmodule` defines one `LrSdkMenus` module exposing exactly three
functions — `addExportMenuItems`, `addLibraryMenuItems`, `addHelpMenuItems` —
and the submenu title `$$$/AgSdkMenus/Menu/PluginExtras=Pl&ug-in Extras`
occurs **once in the whole application**. One submenu, three parents. The
mapping was read off the call sites: `addExportMenuItems` is invoked directly
after the `$$$/Application/Menu/File/PluginManager` block, `addLibraryMenuItems`
amid the `Menu/Library/*` items.

This plugin uses File. The Library menu only exists in the Library module,
whereas File is present everywhere; both of our items open floating windows
that work from any module, and neither is an operation on selected photos.

## A plugin cannot add anything to a photo's right-click menu

Right-clicking a photo is the natural place to want "send this to
iNaturalist", and there is no way to get there. Three independent checks:

- Scanning every `.lrmodule`, `.exe` and `.dll` in the install for
  `Lr[A-Za-z]*MenuItems` returns **exactly three keys**, all listed above.
  Nothing matching `Context`, `Photo`, `Image`, `Grid` or `Filmstrip` exists.
- Each of the three `add*MenuItems` functions has **exactly one call site**.
  (Each name appears twice in `Library.lrmodule`: once in the consecutive run
  of constants that is the `LrSdkMenus` module definition, once where it is
  called.) So the Plug-in Extras submenu is attached to three menus, full stop.
- The image context menu is built from `$$$/AgLibrary/Menu/ImageContext/*` and
  never reaches the plugin submenu builder.

`PluginContextMenu` does turn up in `libcef.dll`, but that is Chromium's
embedded browser, not Lightroom's UI.

The only two ways a plugin has ever appeared on that menu are the
`ImageContext/ExportSubmenu` (an export preset built on an
`LrExportServiceProvider`) and the publish-specific entries like
`GoToPublishedPhoto` and `MarkPhotoDirty` (an `LrPublishService`). This plugin
deliberately declares neither — see plugin-architecture.md — so the floating
panel plus the File menu are the whole surface, by choice.

The temptation is to also ship a combined preset — plugin fields plus the
everyday Lightroom ones — so users are not giving anything up by leaving it
selected. This plugin tried that and dropped it. Default is one dropdown away,
a copy of Default is a second thing to keep in step with Lightroom, and two
near-identical entries in that menu is worse than switching.

## The Metadata panel is the least capable surface in the SDK

Worth knowing before designing around it, because it looks like the most
promising one. A plugin's field becomes a panel row through
`makeFormatterFromFieldDeclaration`, and the *only* keys that function derives
from a field declaration are:

```
id ("%s.%s"), isSdkItem, title, data_type, rating/mixed_value,
enum_values (from `values`), format_image, readOnly, set_image,
and for dataType "url": a hardcoded
action_title = "$$$/AgPhotoPropertySpec/GoURL=Go to URL" plus a fixed action
```

Consequences, all of them load-bearing:

- The `→` button on a `url` row is Lightroom's own "Go to URL". A plugin cannot
  relabel it, replace its action, or add one to a non-`url` field.
- The row displays the field's **value**. For a `url` field that means the raw
  URL is on screen. There is no display-text-vs-target split and no
  `format_value` for SDK fields, so an action row always shows its URL.
- The `→` renders even when the value is empty, and clicking it hands the OS an
  empty target — on Windows that opens Explorer. An unwritten `url` field is an
  actively broken button, not an inert one.
- No `validate` and no change callback reach a plugin's metadata field, so the
  panel cannot react to the user typing into one.

Lightroom's internal formatter spec is far richer than what plugins are given —
it has `action`, `action_title`, `action_type`, `action_icon`, `always_visible`,
`format_value`, `hidden` — which is why built-in rows have real buttons. None of
it is reachable through `LrMetadataProvider`.

```powershell
$txt = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes(
  "C:\Program Files\Adobe\Adobe Lightroom Classic\LibraryToolkit.dll"))
$i = $txt.IndexOf("makeFormatterFromFieldDeclaration")   # and "CustomMetadataFormatters"
```

Treat the Metadata panel as **read/write text fields and nothing more**.

## Every UI surface a plugin can have

This is the complete list, from dumping the loader binaries. It is short, and
the shape of it is the single most important constraint on the plugin's design.

| Surface | Docked? | Widgets | How |
| --- | --- | --- | --- |
| Metadata panel fields | **yes** | text only | `LrMetadataProvider` |
| Publish service entry | **yes** | fixed row | `supportsIncrementalPublish` |
| Comments panel | **yes** | fixed | publish-service comment hooks |
| Floating window | no | anything | `LrDialogs.presentFloatingDialog` |
| Export / publish dialog | modal | anything | `sectionsForTopOfDialog` |
| Plug-in Manager section | modal | anything | `LrPluginInfoProvider` |
| Modal dialog | modal | anything | `LrDialogs.presentModalDialog` |
| Web view dialog | modal | HTML | `LrDialogs.presentWebViewDialog` |
| Bezel | transient | text/image | `LrDialogs.showBezel` |
| Menu items | — | none | `Lr*MenuItems` |

**Nothing is both docked and arbitrary.** The three docked surfaces are all
fixed-shape things Lightroom draws for you and lets a plugin fill with data;
everything that accepts a `push_button` is a window that floats or blocks.

The docking machinery does exist in `ui.dll` — `AgViewWinPanelHost::DockOrUndockPanel`,
`AgViewWinPanel::SetFloating`, `IsUndocked` — but it is internal C++ with no
plugin-facing manifest key. Searching every `.lrmodule` and `.dll` for `LrPanel`,
`LrLibraryPanel`, `LrDevelopPanel`, `LrViewProvider`, `LrInspector`,
`LrModulePanel`, `LrCustomPanel` and `LrSidePanel` turns up nothing. This is
absence-of-exposure rather than a prohibition, but it is consistent across every
binary that could plausibly host one.

The one near-miss is the **Web module**, whose right-hand panels really are
plugin-populated with arbitrary `LrView` content —
`Resources\webengines\default_html.lrwebengine\galleryInfo.lrweb` builds them
with `views = f:panel_content{...}`. But that is a **different plugin type**
(`.lrwebengine`, keyed by `galleryType`, loaded by `Web.lrmodule`), it only
exists inside the Web module, and it is gallery-export configuration rather than
a general-purpose panel. Not a route to a Library-module panel.

### Controls

Complete `LrView.osFactory()` control list, from `ui.dll`:

```
row column spacer checkbox radio_button color_well edit_field edit_text
combo_box password_field group_box catalog_photo picture popup_menu
simple_list scrolled_view push_button square_button separator slider
static_text tab_view tab_view_item view path_control
```

Complete `LrDialogs` export list, same binary:

```
message confirm runOpenPanel runSavePanel messageWithDoNotShow
promptForActionWithDoNotShow resetDoNotShowFlag presentModalDialog
presentFloatingDialog closeFloatingDialogsForPlugin presentWebViewDialog
showBezel stopModalWithResult showModalProgressDialog showError
attachErrorDialogToFunctionContext showStringsDialog
```

**No canvas, no drawing primitives, and no mouse coordinates anywhere.**
`mouse_down` exists on some controls but carries no position, so draggable
handles and hit-testing are impossible in pure Lua. Nobody in the ecosystem has
done it.

#### `f:simple_list` is real, but undocumented

It sits in the constructor list above, beside `popup_menu`. The string
`simple_list` appears **exactly once** in the whole binary — the factory entry —
so it has no property surface to scan for. Its implementation chunk (index
~265542 in `ui.dll`) gives it away instead: it builds a `table_view` inside a
`scroll_view`, reading

```
bind_to_object auto_resize width autoresize_columns no_column_headers
allows_multiple_selection fill columns title resizable truncation
value items selected_indexes height enabled visible
```

which is enough to conclude it takes `items` and a `value`, and that the SDK's
usual `{ title = ..., value = ... }` item shape is the one to try.

**"The binary accepts these keys" is not "this displays."** This plugin uses it
for the panel's suggestions list, isolated in `ObservationPanel.suggestionsView`
so that falling back to `f:popup_menu` is a one-line change. **Confirmed in the
host:** it renders, and rows highlight on click.

##### Its `value` is a list, even for a single selection

`value` is not the selected item. `simple_list` binds it to the inner
`table_view`'s `selected_indexes` through a `transform`, and the reverse path
(`propagationFromDocumentView`) runs `ipairs` over that — so what reaches the
property is a **table**, with one entry for a single click and zero entries when
nothing is selected.

Taking it for a row number is silent: `rows[{...}]` is `nil`, so the list
highlights the row and nothing else happens. There is no error and nothing in
the log. This cost a host round trip to notice, because a list that visibly
responds to clicks looks like a list that is wired up.

`PanelCore.selectedIndex` normalises it and accepts every plausible shape rather
than only the observed one, on the grounds that the failure mode is invisible.

Same caution for a bound `title` on `f:push_button`: the panel's Upload/Update
button relies on it, and the failure mode would be a blank button rather than an
error. **Confirmed in the host:** it works.

### The floating window, in detail

`LrDialogs.presentFloatingDialog(_PLUGIN, { ... })` is the only non-modal,
persistent window a plugin can create, and the only surface that can hold both
this plugin's data and its buttons. **This plugin uses it** — see
`ObservationPanel.lua`.

The argument names are not guesswork. The `LrDialogs` wrapper's own constant
table lists `contents`, `onShow`, `id`, `save_frame`, `blockTask`, and it
validates two things by name:

```
$$$/LrDialogs/Error/NoPlugin=presentFloatingDialog called with invalid plugin parameter
$$$/LrDialogs/Error/NoFloatingContents=presentFloatingDialog called with no contents parameter
```

The window it builds is a separate chunk, identifiable by
`is_non_modal_sdk_window`. That chunk's constants give the rest of the accepted
keys — `title`, `save_frame`, `position`, `margin`, `closable`, `maximizable`,
`minimizable`, `borderless`, `background_color`, `canBecomeKeyWindow`,
`windowWillClose` — and, the useful part, it reads two observer keys straight
out of the argument table and hands them to the catalog:

```
selectionChangeObserver  ->  addSelectionContentObserver
sourceChangeObserver     ->  addSourcesChangedObserver
```

So a floating window can follow the filmstrip selection and the chosen
folder/collection. That is what makes it behave like a panel rather than a
dialog. Focus Points v4 ships the same mechanism.

The observers are registered on the Library module's filmstrip, not on the
catalog: in `Library.lrmodule` `addSelectionContentObserver` sits in the same
class as `setSelectedImageIds`, `getSelectedImageIds`, `getSelectedImageCount`
and `addSelectionWillChangeObserver`. They fire promptly and reliably — verified
by logging inside them in the host.

**They are not called from within a task, and that matters more than it
sounds.** Almost anything worth doing in one of these observers — reading plugin
metadata, formatted metadata, most catalog access — yields, and yielding outside
a task raises. Two different messages depending on how the observer was reached:

```
We can only wait from within a task
Yielding is not allowed within a C or metamethod call
```

**Lightroom swallows both.** No dialog, no console output, nothing in the plugin
log unless you catch it yourself. The visible symptom is simply a window that
does not react, which sends you looking at the observer wiring — the one part
that is working. Wrap the observer body in `LrTasks.startAsyncTask`.

Expect several firings per user action, with transient states in between. The
host log for a single folder change showed the selection observer fire three
times, reporting 1, then 104, then 104, then 1 target photos. Anything doing
async work per firing needs to decide which result is still wanted rather than
assuming the last one to finish is the newest.

Three things matter for it to be usable:

- **`blockTask = true`.** The window is bound to a property table owned by the
  calling task's function context. Without `blockTask` that task ends as soon
  as the window is shown, the context dies, and every binding points at a dead
  object.
- **`save_frame` plus `id`.** Position and size persist across sessions. A
  floating window that reopens centred every time is one people close once.
- **Observers on a task**, as above.

It takes focus every time it is opened — which is why the panel updates its
bindings in place on selection change rather than rebuilding the window.

#### It is system-wide always-on-top, and that is not configurable

Measured on Windows with `GetWindowLongPtrW` / `GetWindow` against a live
Lightroom process, rather than assumed:

| Window | Class | Ex-style | Owner |
|---|---|---|---|
| Our floating panel | `AgWinFrame` | `0x108` — `WS_EX_TOPMOST` set | `0` (none) |
| Lightroom main window | `AgWinMainFrame` | `0x100` | `0` |

Two consequences, both unwanted: `WS_EX_TOPMOST` puts the panel above *every*
application, not just Lightroom; and having no owner window means it does not
minimise, restore or z-order with Lightroom.

There is no Lua control over either. `_topmost` *is* a real property of the
underlying window object — in `ui.dll` it sits in the same property list as
`borderless`, `closable`, `minimizable` and `canBecomeKeyWindow`, all of which
the SDK builder does pass — but the builder's own constant table contains no
`_topmost` and no `level`, so it never reads the key. Passing
`_topmost = false` through `presentFloatingDialog` was tried in the host and
changed nothing: the window still came up `0x108`.

The behaviour you would want (above Lightroom, not above everything) is an
owned, non-topmost window. That is reachable only from outside Lua:

```
SetWindowLongPtrW(panel, GWLP_HWNDPARENT /* -8 */, mainHwnd)
SetWindowPos(panel, HWND_NOTOPMOST /* -2 */, 0,0,0,0, SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE)
```

Both calls were confirmed against the live panel. Order matters: giving the
window an owner first puts it in the owner's z-order band, and clearing topmost
afterwards is what stops it floating over other applications.

That is what the plugin now does. `WindowFix.lua` shells out through
`LrTasks.execute` to `fix_window_z_order.ps1`, which polls for a window matching
Lightroom's PID + class `AgWinFrame` + the exact caption, then applies both
calls. It is started on its own task just before `presentFloatingDialog`, which
blocks; the helper polls rather than expecting the window to exist yet.

Measured after the plugin's own fix-up, opening the panel from the menu:

```
title='iNaturalist'             class='AgWinFrame'      owner=0x3064A exstyle=0x100 TOPMOST=False
title='Lightroom Catalog - ...' class='AgWinMainFrame'  owner=0x0     exstyle=0x100 TOPMOST=False
```

Owner is Lightroom's main frame, topmost is gone. No console window flashes,
because the helper is launched `-WindowStyle Hidden`.

To re-measure: `EnumWindows` filtered by Lightroom's PID, then
`GetWindowLongPtrW(h, -20)` for the ex-style and `GetWindow(h, GW_OWNER /* 4 */)`
for the owner. Add `CharSet = CharSet.Unicode` to the `GetClassNameW` /
`GetWindowTextW` P/Invokes — `StringBuilder` marshals as ANSI by default and you
get one character back per string.

Note `windowWillClose` here, **not** `window_closing`. The assert
"windowWillClose is overriden, use window_closing instead" is in the popup /
overlay widget code (`auto_close`, `fade_out`), not the SDK window builder.

### Other odds and ends

`f:catalog_photo { photo, width, height }` renders a live catalog photo with
develop settings and Lightroom's own crop applied; it cannot show a custom crop
region and is not interactive. Overlays are done with
`f:view { place = "overlapping" }` plus `f:picture` positioned by `margin_left`
/ `margin_top`. On Windows transparent PNGs over `catalog_photo` have alpha
bugs, which is why Focus Points falls back to exporting a temp JPEG and drawing
overlays into it with a bundled ImageMagick. **Unverified:** whether its `photo`
property can be re-bound to follow a selection, or whether the window has to be
rebuilt to change the picture.

`presentWebViewDialog` is unexplored and possibly significant: the backing
`AgWebView` has `runScript`, an HTML `source`, and strings for a `lua URL`
callback and `pushNextLuaChunk()`, which imply JavaScript can call back into
Lua. That would give real mouse events — the one route to a draggable crop
rectangle. On Windows it is the legacy `Internet Explorer_Server` (MSHTML)
control, and no known plugin uses it.

`LrSocket` (in `net_client.dll`) is real and is the escape hatch for a companion
process.

## A publish service is an export provider with one extra key

There is **no `LrPublishService` manifest key.** The string exists inside
`LibraryToolkit.dll` but it is internal; Adobe's own `Flickr.lrplugin` registers
under `LrExportServiceProvider` and becomes a publish service by setting
`supportsIncrementalPublish = "only"` on the provider table. **Confirmed in the
host**: this plugin shipped that way for a while and appeared in the Publish
Services panel. It no longer does — the panel replaced it, for reasons in
[plugin-architecture.md](plugin-architecture.md) — but the finding stands.

Over a plain export target it adds:

- A persistent entry in the Library **left** panel, visible while working
- A **Publish** button, and per-photo *New / Modified / Published* state that
  Lightroom tracks for free
- `metadataThatTriggersRepublish` to mark photos dirty when chosen fields change
- `rendition:recordPublishedPhotoId` / `recordPublishedPhotoUrl`
- `viewForCollectionSettings` in addition to `sectionsForTopOfDialog`
- The **Comments panel**, through `getCommentsFromPublishedCollection`,
  `canAddCommentsToService` and `addCommentToPublishedPhoto` — plus
  `getRatingsFromPublishedCollection` and `titleForPhotoRating`

That last one is the answer to "can a plugin put something next to Comments in
the Library panel". It cannot; a publish service **fills Comments in**.

The full ordered key list, recovered from Flickr's compiled provider table:

```
small_icon, publish_fallbackNameBinding, titleForPublishedCollection,
titleForPublishedCollection_standalone, titleForPublishedSmartCollection,
titleForPublishedSmartCollection_standalone, getCollectionBehaviorInfo,
titleForGoToPublishedCollection, titleForGoToPublishedPhoto,
deletePhotosFromPublishedCollection, deleteFirstOnPublish,
metadataThatTriggersRepublish, shouldReverseSequenceForPublishedCollection,
supportsCustomSortOrder, imposeSortOrderOnPublishedCollection,
renamePublishedCollection, deletePublishedCollection,
getCommentsFromPublishedCollection, titleForPhotoRating,
getRatingsFromPublishedCollection, canAddCommentsToService,
addCommentToPublishedPhoto
```

Two traps worth knowing before writing one:

- **`metadataThatTriggersRepublish` must set `default = false`.** Without it
  every catalog field triggers a republish and the whole collection sits
  permanently in Modified.
- **Use `withPrivateWriteAccessDo`, not `withWriteAccessDo`,** for catalog
  writes inside `processRenderedPhotos`. The ordinary write can block waiting
  on a transaction the export itself is holding. It takes just a function, no
  title.

The panel entry's layout is fixed — arbitrary widgets go in the settings dialog,
not the panel row. `rcloran/lr-inaturalist-publish` is the reference
implementation and is worth reading.

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

**Confirmed in the host.** The plugin registers `URLHandler.lua` and Lightroom
calls it.

This was originally the plugin's route to a *button* in the Metadata panel: a
custom field of `dataType = "url"` renders as a clickable row, and a field
holding `lightroom://com.github.inat-lightroom/sync` therefore behaves like
one. Clicking such a row does reach the handler — that part works.

**It was still the wrong idea, and the plugin no longer does it.** A url row is
not a button:

- Lightroom fixes the label from the field declaration and hardcodes
  `"Go to URL"` for `dataType = "url"` (see `makeFormatterFromFieldDeclaration`
  above). A plugin cannot rename the arrow or supply an action.
- The arrow **fires on empty values** — on Windows that opens Explorer.
- A custom metadata field has no default, so the row only exists on photos
  something has already written to. The photo that most needed *Link to
  Observation…* was the one photo that could not offer it.

What the mechanism is genuinely for here is the OAuth callback:
`lightroom://com.github.inat-lightroom/authorization-redirect?code=…`, which
needs no `LrSocket` listener and no local port.

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

Anything the built-in tagsets use is safe. `explore/test_plugin_surface_lua.py`
holds that list and asserts this plugin's tagsets stay inside it.

Plugin fields are addressed as `<LrToolkitIdentifier>.<field id>`; a bare field
ID silently resolves to nothing.

### A tagset item can be a table, not just a field ID

Two formatters take that form. The formatter table in `LibraryToolkit.dll`
(index ~28441) maps `com.adobe.separator → separator` and
`com.adobe.label → label`, and Adobe's own shipped IPTC and IPTC Extension
tagsets use `com.adobe.label` to draw their "Contact" and "Description"
headings:

```lua
{ formatter = "com.adobe.label", label = LOC "$$$/…=Some heading" },
```

This plugin uses one to say where its controls are, since a panel of read-only
fields with no explanation reads as broken.

The consequence bites tests rather than the plugin: a tagset's `items` list is
no longer all strings, so anything iterating it to check field IDs has to skip
the tables first.

## Removing a custom metadata field leaves it in the catalog

Dropping a field from `LrMetadataProvider` and bumping `schemaVersion` does not
remove it from catalogs that already have it. Both the field spec and every
value written to it stay behind indefinitely.

Verified against a catalog carried from v2 to v5: it still held specs *and*
values for `inat_action_sync` and `inat_action_link` (removed at v3) and
`inat_crop` (removed at v4) — three specs the plugin no longer declares at all.
Reading `AgPhotoPropertySpec` shows 13 rows for `sourcePlugin =
'com.github.inat-lightroom'` against the 10 fields the plugin declares.

This matters because leftovers are not invisible. Lightroom's own **All
Plug-in Metadata** preset lists every field a plugin ever registered, so stale
values appear there, unlabelled by anything current and impossible to edit away.

There is no SDK call that deletes a field spec, and the values cannot be cleared
either. `setPropertyForPlugin` validates its key against the schema the plugin
*currently* declares, so writing `nil` to a removed field is refused:

```
Attempt to access property "inat_action_sync" that's not declared in Info.lua
```

**Removing a field is a one-way door.** Everything it has ever held stays in the
catalog and keeps appearing in All Plug-in Metadata. Be sure before adding one.

Establishing that cost three schema versions, because a migration that returns
is recorded as done and never runs again — `Adobe_variablesTable` holds the
number under `AgSdkUpgradeFunctionSucceededForSchemaVersion_<toolkit id>`. Each
failed attempt burns one.

Two of those three failed *silently*, both worth knowing:

- Wrapping the pass in a plain `pcall` made `getAllPhotos` return an empty list
  (see the `pcall` note above), so it read a 6,591-photo catalog as empty and
  reported success. `LrTasks.pcall` fixed that and revealed the real error.
- The migration then logged `0 of 3 field(s) clearable` — which is the only
  reason the rejection above was ever seen. Instrument the migration before
  attempting a third guess; the catalog cannot tell you *why* nothing happened.

Verifying any of this from outside Lightroom means copying `-wal` and `-shm`
alongside the `.lrcat`. The catalog runs in WAL mode, so a copy of the main file
alone is a stale snapshot that makes a migration which did run look like it
did not.

## `LrLogger` writes nothing until it is enabled

`LrLogger("name")` returns a logger that silently discards everything until
`enable("logfile")` is called **on that instance**. Sharing a logger *name*
across modules does not share its enablement, so a module that creates its own
logger logs nothing.

This plugin has one `Log.lua` that enables a single logger; every module
requires it. On Windows the output lands in
`%LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\`, observed on Lightroom
Classic 15 — the widely repeated `~/Documents/LrClassicLogs` was wrong here, and
`~/Documents` is redirected to OneDrive on this machine, so if you go looking be
sure which one you are looking at. macOS is
`~/Library/Logs/Adobe/Lightroom/LrClassicLogs/` (unverified).

Note that a menu-item script only loads when the menu item is *clicked*, so
putting logger setup there means nothing logs during an export.

## `LrPasswords` is already plugin-scoped

```lua
LrPasswords.store(key, value)
LrPasswords.retrieve(key)
```

No plugin ID argument — it is implicit. Storage is the OS credential vault.

## `LrApplicationView.switchToModule` is real, and `"map"` is the Map module

`LrApplicationView` is not in the SDK documentation this project was working
from, but it is a real module: `LrApplicationView.lua` sits in `Lightroom.exe`'s
Lua module registry (~index 1975723) alongside `LrApplication`, `LrSelection`
and `LrUndo`. Its export table includes `switchToModule`, `getCurrentModuleName`,
`showView`, `gridView` and `zoomIn`.

The module names it accepts are a table at indices 2905266–2905279, mapping the
public name to the internal one:

| Name to pass | Internal identifier |
|---|---|
| `library` | |
| `develop` | |
| `map` | `com.adobe.ag.location` |
| `book` | |
| `slideshow` | |
| `print` | |
| `web` | `com.adobe.ag.wpg` |

So it is `"map"`, not `"location"` — the internal name is what the binary calls
it, not what the API takes.

Two things this does **not** establish, and neither is relied on:

- whether `switchToModule` must run inside a task. The plugin calls it directly
  from a button action, wrapped in `pcall`, and falls back to telling the user
  where the module picker is.
- whether the Map module is available to every user. `Lightroom.exe` also
  contains `isModuleBlockedForChineseUser`, so at least one build restricts it.
  The `pcall` covers that too.

### The `{4,}` string-scan regex silently drops three-letter names

Every binary dump in this document was made by extracting printable runs with
`[ -~]{4,}`. That minimum **hides `map` and `web`**, which is exactly why the
module table first looked like it had two entries with missing names. Re-scan at
`{3,}` whenever a table looks malformed — the data was fine, the sieve was not.

## `LrApplication.activeCatalog()`, not `LrCatalog`

`LrCatalog` is the type of the object you get back, not a module with an
`activeCatalog` function.

## Raw `dateTimeOriginal` counts from 2001-01-01

Lightroom's raw metadata uses the Cocoa epoch, not the Unix one, so `os.date`
lands 31 years early. Use `LrDate.timeToUserFormat` / `LrDate.timeToW3CDate`,
and `LrDate.currentTime()` for "now".

## Menu-item scripts run on load

Anything in `LrExportMenuItems` (or the Library/Help equivalents) executes its
file top to bottom when clicked.
Never `require` such a file from another module. This is not theoretical: the
sync used to live in `SyncObservation.lua`, which made it unreachable from
anywhere except its own menu item, and adding a second caller meant extracting
the logic into `SyncCore.lua` first. `PluginInit.lua` had the same problem —
requiring it opened the credentials dialog as a side effect.

The pattern that works is a module holding the logic and a two-line script
holding the entry point. `explore/test_plugin_surface_lua.py` asserts no module
requires a menu script.

## `LrBinding.negativeOfKey` returns a boolean

It is for enabling and disabling controls. It is not a way to derive one
displayed string from another, which makes it the wrong tool for an export
`synopsis`.

---

## A Plug-in Manager section binds to preferences unless told otherwise

`sectionsForTopOfDialog(f, propertyTable)` hands you a property table, so it
looks as though `LrView.bind("status")` inside that section resolves against
it. It does not. Without an enclosing `bind_to_object`, a binding falls through
to the plugin's *preferences*.

The Updates section shipped without one. It rendered like this:

```
Installed version:                 <- blank
                                   <- blank, where the status line should be
[Check for Updates] [Download and Install] [Release Notes]
[x] Check for updates automatically <- correctly ticked
```

Every literal `title` drew fine. `installedVersion` and `status` were blank,
because no preference has those names. The checkbox looked *perfect*, because
`update_check_automatically` is a real preference — so that binding silently
read and wrote the preferences table directly, behind the property table's
back. `endDialog` would then have written its stale copy back over whatever was
clicked.

That is the shape of the bug worth remembering: the fields bound to names the
preferences do not have go blank, and the fields bound to names they do have
keep working while pointing at the wrong table. A half-correct dialog is much
harder to read than a dead one.

The fix is one line, stated once, on a container wrapping the whole section:

```lua
f:column {
  bind_to_object = props,
  ...
}
```

`SettingsDialog.lua` had always done this, because a modal dialog built with
`LrBinding.makePropertyTable` has to. The Plug-in Manager path is the one that
looks like it does not.

The harness could not catch this: its view factory records arguments rather
than resolving bindings, so a binding with no source looks the same as a good
one. `explore/test_plugin_info_provider_lua.py` catches it structurally
instead, by walking the returned section and asserting that every binding has
an enclosing `bind_to_object` which is the same table the code writes to.

---

## `LrShutdownPlugin` runs on Reload Plug-in, from the file on disk

Verified in the host. The updater's whole design rests on this hook firing, so
it was worth proving rather than assuming: the plugin stages an update while it
is loaded and swaps the files as it unloads, which costs the user one restart
instead of two.

Two things the log showed that are not in the SDK documentation:

**The hook fires on Reload Plug-in, not only on quit.** A user who leaves
Lightroom running for weeks can still take an update the moment they ask for
one.

**Lightroom reads `PluginShutdown.lua` at unload, not at load.** The line that
proved the hook ran was written to the file *after* Lightroom had already
loaded the plugin, and it still appeared. So the unload path is not a chunk
compiled at startup. This matters when testing: editing the shutdown script of
a running plugin takes effect on the next unload, with no reload needed first.

The evidence to look for, since two different code paths can apply an update:

```
TRACE  PluginShutdown: running
INFO   Updater: applied v0.9.8 (29 files)
```

and *no* `PluginInit: applied a staged update ...` line after it. `PluginInit`
is the fallback for a crash or a kill; if its line appears too, the hook did
not do the work. Both lines exist to tell those cases apart.

That distinction only became readable after fixing a bug of my own. The
`pcall` around the swap discarded its error while the comment above it claimed
failures reached the log, so "the hook never ran" and "the hook ran and the
swap failed" produced identical evidence — an update landing one restart late
— despite sharing no fix. `PluginShutdown` now logs on entry unconditionally,
before anything can fail, and logs the `pcall` error when there is one.

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

## `setRawMetadata` can write GPS — from its own dispatch code

Not adjacency, not a guess: `Library.lrmodule` contains the constant run for
`LrPhoto:setRawMetadata`, and immediately around the

```
LrPhoto:setRawMetadata: unknown metadata key %q
```

error message sits the handler table itself:

```
'extendedMetadata' 'GPSLatitude' 'GPSLongitude'
'latitude' 'longitude' 'xmpLatLonCoordFromFloat' 'lat' 'lon' 'touch'
```

Reading it: the `"gps"` key takes a **table**, off which it reads `latitude` and
`longitude` — the same shape `getRawMetadata("gps")` hands back — converts them
with `xmpLatLonCoordFromFloat`, and writes `GPSLatitude` / `GPSLongitude` into
the photo's extended metadata. `gpsAltitude` (→ `GPSAltitude`, via
`numberToFraction`) and `gpsImgDirection` have handlers of their own, so they
are separate keys rather than fields of the same table.

```lua
catalog:withWriteAccessDo("...", function()
  photo:setRawMetadata("gps", { latitude = 51.5, longitude = -0.12 })
end)
```

**The key list is a whitelist, and an unknown key raises.** That error message
is not decoration — it is the else branch. So a typo in a metadata key is a
runtime error rather than a silent no-op, which is the good outcome, but only if
the call is reached during testing. `explore/lua_harness.py`'s stub enforces the
same whitelist with the same message for exactly that reason.

Not established by this: whether a write is rejected for a photo whose file is
offline, and whether it round-trips to the file immediately or waits for a
metadata save.

## A nil keyword is not "no parent"

`catalog:createKeyword(name, synonyms, includeOnExport, parent, returnExisting)`
returns nil under conditions the SDK does not spell out. The obvious loop --

```lua
for _, name in ipairs(path) do
  parentKw = catalog:createKeyword(name, {}, true, parentKw, true)
end
```

-- treats that nil as the parent for the next level, and a nil parent means
*the top of the catalog*. So a lineage that broke partway through carried on
creating the rest of itself as brand new **top-level** keywords, beside the
user's own vocabulary and outside the plugin's root keyword entirely.

Three things make that much worse than it sounds:

- Deleting the root keyword does not clean it up. Lightroom's delete does
  cascade to children -- but these were never children of anything.
- **There is no SDK call to delete a keyword.** The plugin cannot offer to
  repair what it created; the user has to do it by hand in the Keyword List.
- It is silent. The keyword count looks right and the leaf gets applied.

`ensureKeywordPath` now abandons the whole path on the first refusal and logs
the level that failed. Nothing written is a re-run; something wrong written is
a cleanup somebody else has to do.

### It compounds

Confirmed against a real catalog. The fragments were rooted at the level
*after* the break -- `Aculeata` where the path broke at `Apocrita`, `Adephaga`
where it broke at `Coleoptera` -- and those parents were themselves stranded
roots from earlier runs.

That is the nasty part: the stranded `Aculeata` is a *second* keyword of that
name, which makes the next run's `createKeyword` refuse one level deeper, which
strands `Apoidea`, and so on down the lineage. One refusal became dozens of
top-level fragments across a handful of lineages.

So refusing the path outright is not enough either -- that would decline the
lineage for good. On nil, `ensureKeywordPath` now looks for the keyword among
the parent's `getChildren()` (or `catalog:getKeywords()` at the top level) and
carries on with it. Only when it is neither creatable nor findable is the path
abandoned.
