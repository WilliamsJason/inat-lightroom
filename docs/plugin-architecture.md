# Lightroom Plugin – Architecture

## Overview

The plugin is an **Adobe Lightroom Classic** plugin written in Lua using the [Lightroom SDK](https://www.adobe.io/apis/creativecloud/lightroomsdk.html). It does two things:

1. **Identify and upload** – ask iNaturalist's vision model what a photo is, and turn the answer into an observation or an identification on one.
2. **Sync** – pull the latest community identification from iNaturalist and write the full taxonomic tree into Lightroom keywords.

Both live in a floating panel. There is no Publish Service and no export
target; see [Why there is no publish service](#why-there-is-no-publish-service).

---

## Plugin files

```
pinned.lrplugin/
├── Info.lua                   # Plugin identity, SDK version, menu, tagsets, URL handler
├── ObservationPanelMenu.lua   # Menu script: opens the floating panel
├── ObservationPanel.lua       # The panel's window: view and wiring
├── PanelCore.lua              # What the panel's buttons do, minus the UI
├── RenderPhoto.lua            # Renders a JPEG with no export service to do it
├── UploadCore.lua             # Creating and updating observations
├── SyncCore.lua               # Sync logic, callable from any entry point
├── LinkObservation.lua        # Adopting an observation that already exists
├── SettingsMenu.lua           # Menu script: opens the settings window
├── SettingsDialog.lua         # The settings window
├── Settings.lua               # Reading, writing and validating settings
├── WindowFix.lua              # Fixes the panel's z-order (Windows only)
├── fix_window_z_order.ps1     # The Win32 helper WindowFix shells out to
├── PluginInfoProvider.lua     # The plugin's section in the Plug-in Manager
├── PluginInit.lua             # Load hook: finishes an interrupted update, checks for new ones
├── PluginShutdown.lua         # Unload hook: applies a staged update
├── Updater.lua                # Reads the release feed and compares versions
├── UpdateCore.lua             # When to check, what to say, what to install
├── UpdateInstall.lua          # Download, verify, stage, and swap the files
├── install_update.ps1         # Verifies and unpacks an update (Windows)
├── install_update.sh          # Verifies and unpacks an update (macOS)
├── InatAuth.lua               # Token acquisition and credential storage
├── InatAPI.lua                # HTTP helpers wrapping iNaturalist REST API (LrHttp)
├── PluginUrls.lua             # Builds and parses lightroom:// plugin URLs
├── URLHandler.lua             # Receives those URLs and dispatches
├── TagsetInat.lua             # Metadata panel preset: the plugin's fields
└── CustomMetadata.lua         # Custom metadata schema definition
```

Menu scripts are deliberately thin. Lightroom executes a menu-item file top to
bottom when the item is clicked, so a file registered as a menu item cannot be
required from anywhere else without performing its action as a side effect. Each
one is a single line that calls into a real module.

Each window is split the same way: `ObservationPanel` / `SettingsDialog` build
views and wire buttons, and `PanelCore` / `Settings` hold what those buttons do.
Only the second half can be tested outside Lightroom, so the split is drawn to
leave as little as possible on the untestable side.

`File > Plug-in Extras` holds two items, and both of them only *open*
something: **Pinned Panel** and **Pinned Settings…**. That is the test
for whether something belongs in the menu — features live where the user is
already looking, and a menu is somewhere you have to go.

File rather than Library: the SDK offers a choice of three parent menus (see
lightroom-sdk-notes.md), and the Library menu only exists in the Library
module. Both items open floating windows that work from anywhere, and neither
acts on the selected photos. A photo right-click entry would be the natural
home for "send this to iNaturalist", but no SDK key reaches that menu — the
only routes are an export preset or a publish service, both of which this
plugin deliberately does not declare.

---

## Where the plugin lives in the UI

Lightroom Classic gives a plugin **no docked surface that can hold a control**.
This was checked against the shipped binaries rather than assumed — the full
survey is in [lightroom-sdk-notes.md](lightroom-sdk-notes.md), and the short
version is:

| Surface | Docked? | Can hold buttons? |
| --- | --- | --- |
| Metadata panel fields | yes | no — `string`/`enum`/`url` text only |
| Publish service entry | yes | no — fixed row |
| Comments panel | yes | no — fixed |
| Floating window | **no** | **yes** |
| Modal / export dialogs | no | yes |

Nothing is both. Third-party products that appear to have a real panel are
companion applications drawing their own window over the panel column.

So the plugin uses two: floating windows for everything it does, and the
Metadata panel as a read-only display of what it has done.

### Why there is no publish service

The plugin was a publish service first (`supportsIncrementalPublish = "only"`
on `LrExportServiceProvider` — there is no `LrPublishService` manifest key;
Adobe's own `Flickr.lrplugin` registers the same way). It worked. It was
removed anyway.

A publish service models *choose photos, then send them*. That is right for a
gallery and wrong here, because on iNaturalist the interesting question is
**what is this animal**, and answering it needs the photo, a round trip to the
vision API, a list of candidates, and a choice — before anything is sent. A
publish service has nowhere to put that. Its only interactive surface is the
connection dialog, which is not open at the moment of publishing and does not
know the selection. The suggestions would have had to live somewhere other than
the place you decide.

There is a real cost, and it is worth naming rather than pretending the
replacement is strictly better:

| Lost | Consequence |
| --- | --- |
| New / Modified / Published bookkeeping | The catalog no longer tells you at a glance what has been uploaded; the metadata fields do, one photo at a time. |
| `metadataThatTriggersRepublish` | Editing a photo no longer flags it. Nothing re-uploads by itself. |
| Removing a photo from a collection detaching it | Replaced by an explicit **Unlink**, which is narrower — it detaches in Lightroom only. |
| The **Comments panel** | The largest loss. Only a publish service can fill it (`getCommentsFromPublishedCollection`, `addCommentToPublishedPhoto`), and it is exactly where iNaturalist's identifications and comments belong. |

The ordinary Export target went with it, for a smaller reason: with no settings
worth choosing per-export and the real workflow elsewhere, an iNaturalist entry
in the Export dialog was a second, worse way in.

**Migration.** The link between a photo and its observation lives in the
photo's metadata, not in the published collection, so removing the service
orphans nothing on either side. An existing published collection becomes an
ordinary inert collection; delete it whenever. Photos in it keep working.

One consequence worth knowing: `export_destinationType = "tempFolder"` is
refused to a plugin that declares no export service provider — and the error
names a different field entirely (`LR_export_destinationPathPrefix`). That is
why `RenderPhoto.lua` manages its own temporary directory.

### The Metadata panel — data only

A preset named `Pinned for iNaturalist` in the Metadata panel dropdown shows
this plugin's fields and the file name, and nothing else. The full name rather
than just `Pinned`: it sits among Default, EXIF and IPTC, which all describe
what they contain, so a bare product name there says nothing about what
selecting it would do.

A preset *replaces* the panel's contents rather than adding to it, so selecting
it costs the user their ordinary metadata view. An earlier version
shipped a second `iNaturalist + Default` preset to avoid that. It was dropped:
Default is one dropdown away, and a copy of Default is a second thing to keep
in step with Lightroom for no real gain.

The panel holds **no actions**, and cannot: `LibraryToolkit.dll` validates a
custom field's `dataType` down to `string`, `enum` or `url` and rejects anything
else. It briefly held fake ones — a `url` field renders as a clickable row, and
two such fields held `lightroom://com.github.inat-lightroom/...` links that
reached `URLHandler.lua`. That worked, but the row is not really a button.
Lightroom derives its label from the field declaration and hardcodes "Go to
URL"; the plugin cannot rename it, cannot supply an action, and the arrow fires
even when the field is empty (on Windows that opens Explorer). Custom fields
also have no default, so the rows only existed on photos the plugin had already
touched — the one photo that most needed *Link to Observation…* was the one
photo that could not offer it.

`PluginUrls.lua` and `URLHandler.lua` stay, because OAuth needs the same
mechanism to receive its `lightroom://com.github.inat-lightroom/authorization-redirect`
callback.

**Every field is read-only.** Two were editable and both were traps.
`inat_species_guess` accepted text, wrote it to the catalog, and did nothing
else — and given what `species_guess` means on iNaturalist (see [A species guess
is not an identification](#a-species-guess-is-not-an-identification)) the text
could then be uploaded and discarded with every step looking successful.
`inat_observation_id` was how a photo adopted an existing observation, before
the panel had a button that fetches it and asks; a text field applies to the
whole selection with nothing to check it against.

A panel of greyed-out fields reads as broken rather than deliberate, so the
preset opens with a heading row saying where the controls are. That uses
`{ formatter = "com.adobe.label", label = ... }`, which is a real tagset item —
`LibraryToolkit.dll`'s formatter table maps `com.adobe.label` to `label`, and
Adobe's shipped IPTC presets use exactly this shape for their own headings. It
does mean a tagset's `items` list is no longer all strings.

### The floating panel — data and actions together

`ObservationPanel.lua` is the answer to wanting one place that has the photo's
iNaturalist state *and* the buttons that act on it. It is the only surface that
can hold both, at the cost of floating rather than docking.

`LrDialogs.presentFloatingDialog(_PLUGIN, {...})` opens a non-modal window that
stays up while the user works. Two arguments make it behave like a panel instead
of a dialog:

- `selectionChangeObserver` fires when the filmstrip selection changes, and
  `sourceChangeObserver` when the folder or collection does. The panel refreshes
  its bound property table in place, so it always describes what is selected.
  Rebuilding the window instead would also work, but reopening a floating window
  steals focus on Windows, and doing that on every arrow-key press would make
  the plugin unusable.
- `save_frame` (with `id`) persists position and size across sessions.

`blockTask = true` is load-bearing rather than cosmetic: the window's bindings
belong to a property table owned by the calling task's function context, and
without it that task ends immediately, the context dies, and every binding is
pointing at a dead object.

**The observers do not run in a task, and the refresh has to.** Reading plugin
metadata yields, so doing it straight from the observer raises *"We can only
wait from within a task"* — or, when the observer is reached through a
metamethod, *"Yielding is not allowed within a C or metamethod call"*. Lightroom
swallows both. The symptom is not an error but a panel that quietly ignores the
filmstrip while the observers fire perfectly, which is exactly how this
presented. `refresh` therefore hands its catalog reads to
`LrTasks.startAsyncTask`.

That makes refreshes concurrent, so each one carries a generation number and
only the newest may write. Two things need it: arrow-keying down the filmstrip
fires the observer faster than the reads finish, and a folder change reports the
whole folder selected before settling on one photo — the host log showed
`1 → 104 → 104 → 1` target photos for a single click. Without the guard a
refresh that started earlier and finished later can leave the panel on the wrong
photo, and there is nothing to correct it until the next click.

The panel shows the selection, what the observation currently is, its quality
grade and last sync, a **Species guess** with a **Get Suggestions** button and a
list of what came back, one button that is **Upload to iNaturalist** or **Update
species guess** depending on whether the selection is already linked, and
**Sync**, **Set on Map**, **Link to Observation…**, **View on iNaturalist** and
**Unlink**.

Everything below the heading describes the *first* selected photo and the
heading says so. Uploading is the exception: it takes the whole selection into a
single observation, because several frames of one animal is the usual reason to
select several. Details come from the first photo.

The upload button is one button that renames itself rather than two buttons, one
of which is always wrong. Upload-or-update is a single decision, its answer is
already on screen, and a disabled second button would only invite the question
of why.

**Suggestions cost differently depending on the photo, so they take different
routes.** A linked photo can be scored by `GET /computervision/score_observation`
— iNaturalist already holds the image, no render, and scoring the observation's
own photos is a better question than scoring a fresh JPEG of one of them. Only
an unlinked photo needs `RenderPhoto.renderForSuggestions` and
`score_image`, and that render is cleaned up afterwards.

`suggestionItems` maps list entries to *row positions*, not taxon ids, because a
malformed result may have no id and a list that silently drops rows is worse
than one that shows a row it cannot act on.

### Location: warn, and hand off to the Map module

An observation without coordinates is, in practice, an observation that does not
count. Measured against the live API: of 8,691,735 open-geoprivacy observations
with no coordinates, **99.975% are casual grade**; only 1,793 ever reached
research grade. Coordinates also improve the vision model's suggestions through
its geographic prior. Most cameras still have no GPS, so this is the ordinary
case rather than an edge one.

The panel therefore shows the location on its own row — it is the only field
here the user can still act on — and `PanelCore.locationWarning` gates the
upload behind a confirmation when the first photo has none.

Three deliberate limits on that warning:

- **It fires only on upload, never on update.** An update posts an
  identification; it cannot add coordinates, so warning there would be a dialog
  with nothing behind it.
- **It is silent when `inat_upload_location` is off.** The user switched
  location off on purpose. A warning that fires when it should not is one people
  learn to click through, and that costs us the times it is right.
- **It is a warning, not a veto.** Plenty of observations are worth having
  without a location.

It judges `photos[1]`, because the observation's details come from the first
photo. Judging any other would warn about a location that is not the one being
uploaded.

**The plugin does not offer coordinate entry of its own.** `LrView` has no
canvas and no mouse coordinates, so the best a plugin can build is two number
fields — against a module that already has place search, a draggable pin,
reverse geocoding, tracklog matching and saved locations, and that writes the
GPS itself. `ObservationPanel.openMap` calls
`LrApplicationView.switchToModule("map")` and gets out of the way.

That call is wrapped in `pcall`: it is the first use of `LrApplicationView` in
this plugin, at least one build restricts the Map module
(`isModuleBlockedForChineseUser` appears in `Lightroom.exe`), and a button whose
whole job is to fix the problem the panel just raised must not fail silently.
`"map"` is verified against Lightroom's own module table rather than guessed —
see `docs/lightroom-sdk-notes.md`.

Reading a photo's coordinates lives in one place, `UploadCore.locationOf`. Three
callers wanted it — the observation body, the vision request, and now the
warning — and the panel disagreeing with the uploader about whether a photo has
a location is precisely the bug that would teach users to ignore the warning.

### Positional accuracy: a field Lightroom does not have

iNaturalist takes a `positional_accuracy` in metres — the radius the subject was
somewhere inside. Lightroom stores no such thing, so it lives in plugin metadata
(`inat_positional_accuracy`, schema v5) and is edited through a `popup_menu` on
the panel.

**Stored in metres, not as a preset name.** Metres are what the API takes, and a
sync writes back whatever number the site holds — which is almost never one of
the four presets. A preset name would leave nowhere to put a synced value.

**No "exact" preset.** A coordinate is never exact; a choice claiming zero
uncertainty would be a lie the plugin invited.

`PanelCore.accuracyItems` adds a synthetic item for a stored value that matches
no preset. This is not cosmetic: a `popup_menu` whose `value` matches no item
renders **blank**, which reads as "not specified" for an observation that has an
accuracy — and touching the control would then overwrite it.

The upload path and the update path need separate handling. `UploadCore`
composes a new observation from what the *photo* says, so `recordAccuracy` runs
first and the value rides along; it is withheld unless coordinates are also
being sent, since an accuracy without a position describes nothing. The update
path posts an *identification*, which says nothing about location, so
`PanelCore.updateAccuracy` PUTs it separately — with `ignore_photos`, like every
other update here.

### Bringing coordinates back down

`SyncCore.coordinatesFrom` is the guard, and its ordering is the whole point:

1. `private_location` if present — the owner's true position.
2. otherwise the public `location`, **but only if `obscured` is false**.
3. otherwise nothing.

iNaturalist randomises the public position of an obscured observation and still
returns an ordinary-looking `location` string. A live example carried a real
`positional_accuracy` of 61 m against a `public_positional_accuracy` of 30278 m.
Writing that into a catalog would be worse than writing nothing, because after
the fact it is indistinguishable from a real fix. `positional_accuracy` is read
rather than `public_positional_accuracy` for the same reason: only the former
describes a position we would actually store.

The write itself is conditional on `UploadCore.locationOf(photo)` being nil —
fill an empty space, never overwrite. `setRawMetadata("gps", {latitude=,
longitude=})` is verified against its own dispatch code in `Library.lrmodule`,
not inferred; see `docs/lightroom-sdk-notes.md`.

### A species guess is not an identification

`species_guess` is free text iNaturalist shows **only while an observation has
no taxon**. As soon as anything identifies it — including the uploader — it is
ignored. So a guess could be typed, saved, uploaded, and silently discarded,
with every step reporting success. This is the single behaviour that shaped the
whole panel.

So when a taxon id is known the plugin posts an **identification**
(`POST /identifications`), and uses free text only when nothing resolved.

It never sets `taxon_id` through `updateObservation`. That moves the
observation's taxon but leaves the author's earlier identification standing, so
the observation disagrees with itself. Posting a new identification withdraws
the previous one automatically.

Every mutating path — upload, update, unlink's counterpart, link — ends in a
sync, so the catalog is never left describing an older version of the
observation than the one that now exists.

### The settings window

`SettingsDialog.lua` is a modal `f:tab_view` with three tabs: **Account**
(credentials), **Observations** (keyword root, **Sync All Linked Photos**,
**Find Unlinked Observations…**) and **Upload** (geoprivacy, GPS, project,
sync-after-upload, metadata inclusion, location and person stripping,
watermark).

The split is by when a question is answered, not by which API field it lands
in: what an observation *says* is decided at upload time alongside what the
file carries, while the Observations tab is the catalog-wide side.

Every preference is written by an observer the moment it changes
(`SettingsDialog.watchPreferences`), so the window's only button is **Done** --
the cancel button is left off with `cancelVerb = "< exclude >"`. A Save/Cancel
pair would advertise a pending edit that does not exist, and a Cancel that
cannot undo anything is worse than no Cancel. Credentials are the exception,
being a store plus a network check, so **Save Token** and **Clear Stored
Credentials** are push buttons on the Account tab instead.

These were the publish connection's settings. They had to go somewhere when the
connection did, and they are genuine preferences rather than per-batch choices,
so a settings window is where they belong. `Settings.lua` holds reading, writing
and validation so the tabs stay declarative.

Tab identifiers are exposed for testing: `ui.dll` raises *"Multiple
tab_view_item views with the same identifier"* and *"tab_view_item needs to have
a string or number identifier"*, and neither is discoverable without opening a
modal dialog.

One rough edge Lightroom leaves us: the window is created `WS_EX_TOPMOST` with
no owner, so out of the box it floats above every application and does not
minimise with Lightroom. Nothing in the SDK controls that — passing
`_topmost = false` was tested in the host and ignored — so `WindowFix.lua`
shells out to `fix_window_z_order.ps1`, which gives the window Lightroom's main
window as its owner and clears topmost. The result is an ordinary owned window:
above Lightroom, above nothing else, minimising with it. That shell-out is the
only place the plugin leaves Lua, it is Windows-only, and on macOS it is a
no-op because the behaviour there has never been measured. See
`docs/lightroom-sdk-notes.md` for the before-and-after window flags.

`LinkObservation.lua` exists because two entry points need it — the panel's
button and the `lightroom://` URL. It used to be a local function inside
`URLHandler.lua`, which meant the panel could only reach it by pretending to be
a URL.

### Offering a rank the evidence supports

`PanelCore.fallbackRows` prepends coarser taxa to the suggestion list when the
top `combined_score` is below `CONFIDENT_SCORE` (75).

The source is the vision response's `common_ancestor` — the most specific taxon
the model is confident about *across all candidates* — and its `ancestors`,
filtered to `FALLBACK_RANKS` (`order`, `family`, `genus`). Two properties follow
from that choice and neither is incidental:

- **It never descends below the common ancestor.** Offering the top result's
  genus would assume the top result's lineage is right, which is precisely what
  a 40% score doubts. Everything at or above the common ancestor is agreed on by
  every candidate.
- **It carries no score.** These are not rows the model ranked. A percentage
  beside one would be a number nobody computed, so the row carries a `note` and
  `describeSuggestion` renders that in place of a percentage.

Ordered finest-first and inserted at the head of the list, because the most
specific defensible answer is the one most people want and a safer option below
eight species is one nobody scrolls to. The `/taxa/{id}` fetch for the lineage
happens only when the list is unconfident, so a confident answer pays nothing.

`InatAPI.summariseSuggestions` now returns `rows, commonAncestor`. It previously
discarded the ancestor entirely, which left the picker with nothing to fall back
to but the guess already under suspicion.

### Arguing before a weak species claim

`PanelCore.confidenceWarning` returns a message when a **species-rank** taxon is
about to be committed on a score below 75, and nil otherwise.

Restricted to species-level ranks (`species`, `subspecies`, `variety`) on
purpose. Coming in at genus when the photo will not support more is what a
careful observer does — warning about it would punish the behaviour the fallback
list exists to encourage. A row with no score at all is either a fallback rank
or a hand-typed name, where there is no evidence to call weak.

Asked **before** the upload/update branch in `ObservationPanel.uploadOrUpdate`,
unlike the location warning, which is upload-only because an update cannot add
coordinates. A wrong species is equally wrong on an observation that already
exists — arguably worse, because it is already public.

The message names the alternative rather than only asking "are you sure?". A
warning with no suggested action is one people learn to dismiss.

### Applying a taxon without publishing

`PanelCore.applyGuessLocally` fetches the chosen taxon, writes its keyword
hierarchy and taxon fields to every selected photo, and stops. Nothing reaches
iNaturalist and no observation link is made or implied.

`SyncCore.applyTaxon` is the shared half. The sync learns a taxon from an
observation and the panel learns one from a suggestion; they disagree about
where it comes from and agree about everything that happens afterwards, so only
the first half was worth writing twice. `SyncCore.withAncestors` is the other
extraction — a taxon from either source usually arrives without the lineage that
*is* the keyword hierarchy.

Deliberately no warnings on this path. The location and confidence warnings both
exist because a bad iNaturalist record is a public artefact other people build
on; a keyword in a private catalog is none of those things, and warning about it
would dilute the two that matter.

Chosen policy for the taxon fields: fill them in, and let the next Sync
overwrite them without asking. That is already how `syncPhoto` behaves, so it
needed no change — the fields mean "best known taxon", with iNaturalist
authoritative whenever it has an opinion.

`PanelCore.taxonUrl` formats the id with `%d` rather than `tostring`, which
gives `1.03486e+08` past a certain size and a URL that 404s.

---

## Custom metadata schema (`CustomMetadata.lua`)

`schemaVersion = 5`. Every field is **read-only**; the panel writes them, the
user does not.

| Field ID | Type | Description |
|---|---|---|
| `inat_observation_id` | `string` | iNaturalist observation ID |
| `inat_observation_uuid` | `string` | The observation's stable identifier |
| `inat_observation_url` | `url` | Direct URL to the observation |
| `inat_taxon_id` | `string` | Taxon ID of the community determination |
| `inat_taxon_name` | `string` | Scientific name of the taxon |
| `inat_common_name` | `string` | Vernacular/common name |
| `inat_quality_grade` | `string` | `casual`, `needs_id`, or `research` |
| `inat_last_synced` | `string` | ISO 8601 timestamp of last sync |
| `inat_species_guess` | `string` | What the photo was last uploaded or identified as |
| `inat_positional_accuracy` | `string` | Location accuracy in metres |

Everything mirroring iNaturalist state would be silently overwritten by the next
sync, which is worse than not being editable. The two that were once editable
are covered above.

`inat_species_guess` is deliberately separate from `inat_taxon_name`. One
records what this photo was said to be, the other what the community decided;
merging them would let a sync quietly rewrite the first.

`inat_observation_url` is the only `url` field the preset shows, because it is
the only one that is either filled in or hidden.

`inat_crop` was removed in schema 4. It held `x,y,w,h` for an iNat-specific crop
that was written by an export dialog that no longer exists and read by nothing
that ever did — an editable box inviting input that went nowhere. The idea is
not dead, but it belongs to the panel, and the field can come back when
something reads it. The obvious design for it — drag a rectangle over a preview
— is **not possible in pure Lua**: `LrView` has no canvas, no drawing primitives
and no mouse coordinates, checked against the shipped binaries rather than
assumed. Sliders bound to four numbers would work; so would creating a virtual
copy with a different crop and uploading that, which puts the cropping in
Lightroom's hands where it belongs.

These fields appear in Lightroom's **Metadata** panel under the iNaturalist
preset.

---

## Upload workflow

The whole selection becomes **one observation**. Details come from the first
photo.

```
Select photos, choose a suggestion (or type a guess), click Upload
        │
        ▼
RenderPhoto renders each photo: JPEG, 2048 px long edge, sRGB, q90,
into a temp folder the plugin owns and cleans up
        │
        ▼
POST /observations   ← species_guess only if no taxon was resolved
        │
        ▼
For each rendition: POST /observation_photos, then verify
        │
        ▼
zero photos attached? → do NOT record the link, and say so
        │
        ▼
taxon resolved? → POST /identifications
        │
        ▼
(optional) POST /project_observations
        │
        ▼
sync taxa back for the photos just uploaded
```

Uploads are verified rather than trusted: iNaturalist returns success before it
has finished processing an image, so the plugin polls until it can confirm the
photo attached, and retries if it cannot.

Refusing to record the link when nothing attached is deliberate. An observation
with zero photos drops to casual grade permanently, and a recorded link would
make the catalog claim a success that is not there — the next thing the user
does would be an *update*, not a retry.

---

## Sync workflow

Started from the panel (the selection), from the settings window's **Sync All
Linked Photos** (everything in the catalog with an observation ID), from a
`lightroom://` URL, or automatically after an upload — in which case it syncs
the photos that were just uploaded, not the selection, which by then is usually
something else.

```
SyncCore.lua reads inat_observation_id from each photo
        │
        ▼
GET /observations/{id}  →  observation + community_taxon + ancestors
        │
        ├── taxon present ──▶ build keyword hierarchy:
        │                       Animalia > Arthropoda > … > Quercus robur
        │                     LrCatalog:withWriteAccessDo → addKeyword
        │                     write inat_taxon_id / _taxon_name / _common_name
        │
        └── no taxon yet ───▶ nothing to file under; no keywords
        │
        ▼
Either way, write:
  inat_quality_grade, inat_observation_url,
  inat_observation_uuid, inat_last_synced
```

**"No taxon yet" is not an error.** Nobody has identified an observation the
moment it is created, so with sync-after-upload enabled it is the outcome of
almost every first upload. It is counted separately (`Not identified yet`) and
reported as information.

The write happens either way for a reason: a photo linked to something
unidentified is exactly the case that needs its UUID, URL and grade recorded,
and an early return would drop them precisely then.

---

## Authentication

The plugin stores the iNaturalist token in **Lightroom's encrypted password
store** (`LrPasswords`), which is backed by the OS credential vault. Today that
token is pasted by hand from
<https://www.inaturalist.org/users/api_token> and expires after 24 hours.

The replacement is OAuth with PKCE, which was checked against iNaturalist's
live endpoints: they run Doorkeeper 5.6.6 with S256 PKCE enabled, and an
application registered with **Confidential unchecked** is a public client — so
there is **no client secret to ship**, which is the thing that usually makes
OAuth impossible for a distributed plugin.

The redirect comes back through the same `lightroom://` mechanism the plugin
already uses:
`lightroom://com.github.inat-lightroom/authorization-redirect?code=…`, handled
by `URLHandler.lua`. No `LrSocket` listener and no local port.

That needs an approved iNaturalist application, and since 2022 those are
reviewed by hand: the account must be two months old with ten or more improving
identifications for other people in the past month. Registration is in
progress; revisit around October 2026.

### What to register, and why the two fields are not free choices

Two values on the application form are fixed by decisions already made in this
repository, and both are awkward to change afterwards.

**Redirect URI** — `lightroom://com.github.inat-lightroom/authorization-redirect`

The host part is `LrToolkitIdentifier` from `Info.lua`, because that is what
Lightroom routes `lightroom://` URLs by. Registering it pins the identifier:
from that point on, renaming `LrToolkitIdentifier` breaks the redirect until
the application is re-registered, on top of orphaning every custom metadata
field already written to photos. The identifier was left as
`com.github.inat-lightroom` through the rename to "Pinned for iNaturalist"
partly for this reason — see `Info.lua`.

**Application name** — `Pinned for iNaturalist`

This one is user-facing, which is easy to miss on a form that otherwise looks
administrative. Doorkeeper shows the application name on the authorization
screen — *"Pinned for iNaturalist would like access to your account"* — which
someone reads at the moment they are deciding whether to trust this with their
iNaturalist account. It has to match `LrPluginName` exactly. A mismatch there
is the same confusion the rename set out to remove, reappearing at the worst
possible moment: a name nobody recognises, asking for account access, is
indistinguishable from something hostile.

Leave **Confidential unchecked**, per above — that is what makes this a public
client with no secret to ship.

Until then there is no second option in the dialog, and that is deliberate.
There used to be: an OAuth application form taking an app id, secret,
iNaturalist username and password, using the password grant to mint a
never-expiring access token. It was implemented and it worked. It was removed
before the repository went public for two reasons. iNaturalist recommends
against the password grant, and particularly against it in distributed
applications, because it requires the user to type their account password into
third-party software — the exact problem PKCE exists to solve. And the app id
and secret are per-application, so with manual review every user would have
needed their own approved application before the fields did anything.

`InatAuth.clear()` erases the token. It briefly also erased the keys that form
wrote, on the theory that removing the feature should not strand a password in
the credential vault; that was dropped once it was certain nobody had ever
stored one. A test in `explore/test_settings_dialog_lua.py` walks the Account
tab and fails if any field binds to those names again.

---

## LrHttp notes

The Lightroom SDK provides `LrHttp` for HTTP requests. Key points:

- `LrHttp.get(url, headers)` – simple GET, returns body string
- `LrHttp.post(url, body, headers, method, contentType)` – POST/PUT
- Multipart form data (for photo upload) requires manually building the MIME boundary string.
- SSL is supported but certificate errors will surface as empty responses; ensure the iNaturalist API certificate chain is valid on the user's machine.

`score_image` is the trap here: its `lat`, `lng` and `observed_on` hints must be
sent as **multipart form fields**. Sent as query parameters the request returns
200 and every `frequency_score` is silently zero, so the suggestions come back
plausible-looking and worse.

A thin `InatAPI.lua` module wraps these calls and handles JSON encode/decode (via a bundled `json.lua`).

---

## Keyword hierarchy approach

Lightroom keywords are hierarchical. The sync step creates/reuses:

```
iNaturalist                     ← configurable root (Settings.sync_keyword_root)
└── <kingdom>
    └── <phylum>
        └── <class>
            └── <order>
                └── <family>
                    └── <genus>
                        └── <species binomial>
                            └── <common name>   (synonyms/alias keyword)
```

Using `LrCatalog:createKeyword(name, synonyms, includeOnExport, parent, skipIfAlreadyExists)`.

The root is a `>`-separated keyword *path* rather than a single name, so the
tree can be nested inside a vocabulary the user already has (`Nature >
iNaturalist`); an empty setting means the top level of the catalog.
`InatAPI.keywordRootPath` turns the stored string into levels, and
`SyncCore.buildKeywordPath` is the one place that reads the setting, so every
caller that writes a taxon — sync, reverse sync, the panel's local apply —
files it in the same place.

It is configurable because rcloran's `lr-inaturalist-publish` syncs taxonomy
keywords under a root of *its* user's choosing and prunes anything under that
root it considers non-equivalent. Two plugins sharing one root means whichever
syncs last removes the other's keywords from the photo, with nothing to say
why. Renaming the default would dodge that only by coincidence.

---

## Export size

iNaturalist displays at most **2048 px** on the long edge and rejects uploads
over roughly 20 MB. `RenderPhoto.lua` therefore fixes JPEG / 2048 px long edge /
sRGB / quality 90 rather than offering it as a default: a full-resolution raw
conversion would fail the upload for an image nobody would ever see at that
size.

Omitted export settings are the hazard. `fillInDefaultSettings` fills gaps from
the *user's own last export*, not from documented defaults, so an omitted key is
invisible on the machine that wrote it and a bug everywhere else. Four are set
explicitly for that reason: `collisionHandling` (`"ask"` would open a dialog
mid-render), `reimportExportedPhoto`, `export_postProcessing` (several shipped
presets carry `"revealInFinder"`), and `includeVideoFiles`.

---

## Updating the plugin

Lightroom has no updater. There is no manifest key for a version feed, no hook
that offers one, and nothing in the Plug-in Manager that fetches anything. Every
plugin that updates itself does the same four things by hand: read a release
feed, compare versions, download an archive, replace its own files.

The feed is GitHub's own `releases/latest` endpoint for this repository. It is
public and unauthenticated, rate limited per IP at 60 requests an hour, and it
excludes drafts and pre-releases — which is why `Info.lua`'s display string may
not say "pre-release", and why the release workflow refuses to build one that
does. It returns the newest release *by date*, not by version number, so the
comparison in `Updater.isNewer` is numeric and one-directional; retagging an old
commit must not offer everyone a downgrade.

### The tag and Info.lua are one fact in two places

The updater compares the tag published on GitHub against the version compiled
into the installed plugin. If those disagree the failure is silent and
permanent, in one of two directions: a plugin that never sees an update, or one
that offers the same update every day forever. So `.github/workflows/release.yml`
runs `explore/plugin_version.py --expect <tag>` and refuses to build unless they
match. Nothing is generated from anything; the check just stops a release that
would be wrong.

### Why a plugin cannot replace itself while it is running

Lightroom loads a module the first time something requires it. A folder swapped
half-way through a session therefore serves old modules to code that has already
loaded and new ones to code that has not, and the resulting failure arrives
later, somewhere else, looking like a bug in whatever happened to require last.

So the work is split, and the two halves never happen in the same moment:

| | when | touches |
|---|---|---|
| **stage** | whenever the user clicks | nothing that is loaded |
| **apply** | `LrShutdownPlugin` | everything, but nothing can require afterwards |

Staging downloads the archive, verifies it, and unpacks it into
`<plugin>/.update-staging`. Applying copies those files over the installed ones
as Lightroom closes. The next launch reads a folder that is entirely one
release, and the user restarts once.

This is verified in the host rather than assumed: `LrShutdownPlugin` does fire,
and it fires on Reload Plug-in as well as on quit, so an update can land without
Lightroom ever closing. See `docs/lightroom-sdk-notes.md` for the log evidence
and for how to tell the two apply paths apart.

A shutdown hook is not a promise — Lightroom can crash or be killed — so
`PluginInit` applies a leftover staged update at the next launch instead. That
runs before any other module of this plugin is required, which is the same
guarantee by a longer route, with one gap it cannot close: Lightroom has already
read `Info.lua` by then. That session runs new code behind the old manifest, so
new menu items or metadata fields appear only at the launch after. It is the
cheaper of the two costs; the alternative is leaving the update unapplied.

### Why staging lives inside the plugin folder

Two alternatives were rejected. Beside the plugin needs write permission on the
*parent* directory, which is a different permission from the one the swap needs,
and the swap is the part that must not fail half way. Temp is cleared between
sessions on both platforms — which is exactly the moment a staged update is
waiting for. Lightroom only loads the files `Info.lua` names, so an extra folder
inside the plugin is inert.

The swap copies files rather than replacing the folder wholesale, because
Lightroom has registered the plugin *by path*: moving the folder aside would
unregister it, and the user would find it disabled with no explanation. Copies
happen before deletions, so no moment exists where the plugin is missing files
it has not yet been given. Files the release no longer ships are deleted — a
stale Lua module is harmless right up until something requires it again under
the same name — and that does mean anything a user added to the folder by hand
is removed too.

### What the checksum is and is not for

Hashing a file and reading a ZIP are both beyond Lua and beyond the SDK, so
`install_update.ps1` and `install_update.sh` do the verify and the unpack
together in one process — checking in one process and extracting in another
leaves a window where the file that was checked is not the file that was opened.

The hash is **not** a defence against a hostile GitHub. `SHA256SUMS` ships from
the same release as the archive, so anyone able to replace one can replace the
other. TLS and GitHub's identity are the trust boundary, and this plugin
downloads and runs code from there, including a PowerShell script. What the
checksum catches is the ordinary failure: a truncated or corrupted download
being unpacked over a working plugin. A release whose checksum cannot be read is
refused rather than installed.

Exit codes are the entire interface between those scripts and
`UpdateInstall.lua`, which turns each into a sentence for the user. On Windows
that meant not using `Write-Error` to report them: under
`$ErrorActionPreference = 'Stop'` it raises a terminating error and PowerShell
exits 1 on the spot, which collapses every distinct failure into "exit 1" —
including the checksum mismatch, the one failure most worth describing
accurately.

### Checking is automatic; installing is not

The check runs once a day from `LrInitPlugin`, after a delay, in its own task,
and can be switched off in the Plug-in Manager. Installing stays a button.
Replacing the code that touches someone's catalog while they are not looking is
not a default anyone chose.

A failed check resolves to "could not check", never to a silence that reads as
"nothing new", and the timestamp is written whether or not the check succeeded —
recording only successes turns an offline week into a request on every launch,
which is the behaviour rate limits exist to punish. When there is something new,
the user is told once per version rather than once per launch.

The UI lives in the **Plug-in Manager** (`LrPluginInfoProvider`), which is the
one Lightroom surface that is about the plugin rather than about photos, and
where people already go to install and enable one. The settings window is about
what an observation says, and the floating panel is about the photo in front of
you; neither is about the plugin.

## What comes next

**Now.** The panel is the whole interface. What is missing from it:

- **Group into observation** across separate uploads. Uploading a selection
  already produces one observation, so this only matters for adding to one
  later. It needs a client-side UUID generator, since it has to invent an ID
  before any observation exists.
- A **crop**. `f:catalog_photo` shows a live catalog photo but applies
  Lightroom's own crop and cannot show a custom region; overlays go on with
  `f:view { place = "overlapping" }` and `f:picture`. Draggable handles are
  impossible — `LrView` has no canvas and no mouse coordinates.

**OAuth**, once the iNaturalist application is approved (revisit October 2026).
Register it as `Pinned for iNaturalist` with the redirect URI
`lightroom://com.github.inat-lightroom/authorization-redirect`; both are
constrained, see [Authentication](#authentication).

**The Comments panel** is now out of reach, and it was the panel this whole
design started out trying to sit next to. Only a publish service can fill it
(`getCommentsFromPublishedCollection`, `canAddCommentsToService`,
`addCommentToPublishedPhoto`, and `getRatingsFromPublishedCollection` +
`titleForPhotoRating` for the faves count). Recovering it would mean a publish
service existing *alongside* the panel purely as a comments feed, which may yet
be worth it — the objection to a publish service was that it is a bad place to
identify a photo, not that it is a bad place to read comments.

Smaller ideas:

- **Capture time in `observed_on_string`** — the plugin has it and sends only
  the date. Better data for iNaturalist.
- **Smart collections** driven by the taxonomic keyword hierarchy.
- **Identification alerts** when somebody adds an ID to an observation.
- **`presentWebViewDialog`** is the only unexplored surface left, and the only
  one that could give real mouse events — and therefore a draggable crop
  rectangle. Its `AgWebView` has `runScript` and strings implying JavaScript can
  call back into Lua. On Windows it is the legacy MSHTML control and no known
  plugin uses it, so this is a research spike, not a plan.
