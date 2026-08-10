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

Measured for `LrExportSession` too, not only for the `exportContext` an export
provider is handed: a probe in Lightroom Classic 14 reported `first=number 1`,
`second=table`, so both take the same shape.

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
host**: the plugin ships this way and appears in the Publish Services panel.

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
holding the entry point. `explore/test_plugin_surface_lua.py` asserts no module
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
