# Lightroom Plugin

This directory contains the **inat.lrplugin** Adobe Lightroom Classic plugin.

---

## Installation

1. In Lightroom Classic, open **File → Plug-in Manager**.
2. Click **Add** and navigate to the `plugin/` directory in this repository.
3. Select the `inat.lrplugin` folder and click **Add Plug-in**.
4. The plugin appears in the list; ensure it is checked (enabled).

---

## First-time setup

Go to **File → Plug-in Extras → iNaturalist Settings…** and open the
**Account** tab. There are two ways to authenticate, and the tab offers both.

### Option 1 — paste an API token (works today)

1. Sign in at <https://www.inaturalist.org>.
2. Click **Open Token Page** in the dialog, or visit
   <https://www.inaturalist.org/users/api_token> directly.
3. Copy the token and paste it into the **Token** field. Either the bare token
   or the whole `{"api_token":"..."}` response works.
4. Click **Save**. The plugin verifies the token immediately and reports which
   account it belongs to.

These tokens expire after **24 hours**, so this needs repeating each day you
use the plugin. It requires no registration, which makes it the practical
option right now.

### Option 2 — OAuth application (no repeat prompts)

Fill in **App ID**, **App Secret**, **Username** and **Password**. The plugin
then mints fresh tokens on demand and never prompts again.

This needs an approved iNaturalist application. Since 2022 iNaturalist reviews
these manually: your account must be at least two months old and have made ten
or more improving identifications for other users in the past month. Apply at
<https://www.inaturalist.org/oauth/applications/new>.

Everything is stored in Lightroom's encrypted password store (`LrPasswords`),
which is backed by the OS credential vault. Nothing is written to disk by the
plugin. Use **Clear Stored Credentials** on the same tab to remove it all.

---

## Usage

Everything the plugin does happens in two floating windows, both under
**File → Plug-in Extras**. There is no Publish Service and no iNaturalist
entry in the Export dialog — see [Why there is no publish
service](#why-there-is-no-publish-service).

### The iNaturalist panel

**File → Plug-in Extras → iNaturalist Panel** opens a window that follows
whatever is selected in the filmstrip. It shows what the selection currently is
on iNaturalist — observation ID, taxon, common name, quality grade, last sync —
and carries every action.

The usual run of it:

1. Select the photo, or several photos of the same individual.
2. Click **Get Suggestions**. The plugin asks iNaturalist's vision model what
   the photo is and lists what comes back, best first, with how confident it is.
3. Click a suggestion. It fills in **Species guess** and, invisibly, the taxon
   ID behind it.
4. Click **Upload to iNaturalist** — or, if the selection is already linked to
   an observation, **Update species guess**.

The button is one button that changes its name, because upload-or-update is one
decision and the answer is already on screen. Uploading takes the whole
selection into a **single observation** with several photos, which is what
selecting several frames of one animal usually means. Date, location and
description come from the first photo.

Suggestions cost nothing extra once a photo is linked: iNaturalist can score an
observation it already holds, and scoring its own photos is a better question
than scoring a fresh JPEG. Only a photo that has never been uploaded needs
rendering first.

The other buttons:

- **Sync** — pull the current community determination for the selection.
- **Set on Map** — switch to Lightroom's Map module to give the photo a
  location. See below for why this is worth doing.
- **Link to Observation…** — adopt an observation that already exists on
  iNaturalist, made in the app or on the web. Paste its ID; the plugin fetches
  it and asks you to confirm before attaching.
- **View on iNaturalist** — open it in a browser.
- **Unlink** — forget the observation. It asks first, and it does not touch
  iNaturalist or remove the keywords already synced; it only detaches the
  Lightroom photo.

The window remembers where you put it, so drag it somewhere out of the way once
and it will reopen there. Close it and the menu item brings it back.

It stays above Lightroom and minimises with it, but it does not sit on top of
your browser or anything else. That takes a little work: Lightroom creates
plugin floating windows as system-wide always-on-top windows with no owner, and
gives plugins no way to change it, so on Windows the plugin runs a small
PowerShell helper (`fix_window_z_order.ps1`) that hands the window to Lightroom
and clears the always-on-top flag. It touches nothing but that one window, and
if it fails the panel simply stays always-on-top. On macOS it does not run at
all.

### Location, and why the panel nags about it

The panel shows the selected photo's coordinates, and **Set on Map** hands you
over to Lightroom's own Map module to place a photo that has none.

This matters more than it looks. Measured against the live API: of 8,691,735
observations with open geoprivacy and no coordinates, **99.975% are casual
grade** — which keeps them out of most research use and out of the GBIF export.
Only 1,793 of that whole set ever reached research grade. Coordinates also feed
iNaturalist's vision model, so a located photo gets better suggestions.

Most cameras still have no GPS, so this is the common case, not the unusual one.
Uploading a photo with no location therefore asks first. It is a warning and not
a veto — plenty of observations are worth having without one — and it stays
quiet entirely if you have turned **Send GPS coordinates** off in settings,
because a warning that fires when it should not is one people learn to click
past.

The plugin does not offer its own coordinate fields. The Map module already has
place search, a draggable pin, reverse geocoding, tracklog matching and saved
locations, and it writes the GPS to the file; two number boxes in a floating
window would be a worse version of something Lightroom ships. Set the location
there, come back, and upload.

### How precise the location is

iNaturalist carries an accuracy alongside every position — a radius, in metres,
inside which the subject really was. Lightroom has no equivalent field, so the
panel adds one: an **Accuracy** menu under the location.

| Choice | Sent | When it fits |
|---|---|---|
| Not specified | nothing | You would rather say nothing than guess |
| Precise — GPS fix | 10 m | Camera or phone GPS, or a pin dropped on the exact spot |
| Approximate | 100 m | You remember the area, not the metre |
| Rough | 3000 m | "Somewhere along that trail" |

There is deliberately **no "exact"**. No coordinate is exact, and offering a
choice that claims zero uncertainty would be offering to lie on your behalf.

It is only ever sent with coordinates. An accuracy on its own describes the
precision of a position nobody received, which a reader could only misread.

A sync brings the accuracy back down from iNaturalist, and the real number is
rarely one of the four above — so when it is not, the menu grows a fifth entry
showing it (`From iNaturalist (36 m)`) rather than rounding it to the nearest
preset. Picking a preset then replaces it, which is a change you asked for; a
menu that silently showed the nearest match would make one you did not.

### Coordinates come back down, too

A common shape of this workflow: upload from a camera with no GPS, then place
the observation on the map on the iNaturalist website, where it is easy. **Sync**
and **Link to Observation** notice that, and write the coordinates into
Lightroom.

**Only into an empty space.** If the photo already has coordinates then
iNaturalist's copy came from them in the first place and there is nothing to
gain; and in the rarer case where the two have genuinely diverged, quietly
moving a photo you placed yourself is not a sync, it is a correction nobody
asked for and nobody can see happen.

Obscured observations are the exception. If the observation's location is
obscured — because you set it that way, or because the taxon is threatened and
iNaturalist obscures it for you — the site returns a *randomised* position that
looks entirely ordinary, up to tens of kilometres out. The plugin refuses those
rather than writing fiction into your catalog. Your own true position does come
back if the API returns it to you as the owner.

### Picking a rank you can defend

Suggestions come back with a confidence score. When the best one is under 75%,
the plugin puts coarser options at the **top** of the list — genus, family,
order — each marked *"agreed by every suggestion"*.

Those come from iNaturalist's own `common_ancestor`: the most specific taxon its
model is confident about across *all* the candidates. If five results argue
about the species but all sit in one genus, that genus is the honest answer, and
it is the one the website itself falls back to. The ladder is never built by
walking up from the top result, because at 40% that result's family is exactly
what is in doubt — and it never offers a rank finer than the common ancestor.

They sit at the top rather than the bottom because a safer choice listed below
eight species is one nobody scrolls to.

For the same reason, identifying something as a **species** on a score below 75%
asks for confirmation first — on upload and on update, since an observation that
already exists is a published record, not a safer place to be wrong. Choosing
the genus instead is never questioned. A coarse record that is right is worth
more than a precise one that is wrong, and it is much easier for somebody else
to refine than to argue down.

### Using a suggestion without publishing anything

Two buttons sit next to the upload button and neither one uploads:

- **Sync guess to Metadata tags** writes the chosen taxon's full keyword
  hierarchy and taxon fields into the catalog and tells iNaturalist nothing. For
  the frames worth filing under the right name and not worth publishing — a
  duplicate, a soft focus, something already recorded. Before this the only way
  to get the hierarchy onto a photo was to create an observation and then think
  better of it.
- **View guess on iNaturalist** opens the taxon page, for when two suggestions
  look alike and the only way to decide is to go and look.

Neither warns about anything. A keyword in your own catalog is not public, not
permanent, and plainly visible; warning about it would only teach you to click
past the warnings that matter.

A later **Sync** overwrites the taxon fields with whatever iNaturalist says,
which is the intended order of authority.

### A species guess is not an identification

This is the one piece of iNaturalist behaviour worth understanding, because it
looks like it works when it does not.

`species_guess` is free text iNaturalist shows *only while an observation has no
taxon*. The moment anything identifies it — including you — it is ignored. So
the plugin does not send a guess when it knows better. If a suggestion was
chosen, it posts a real **identification**; the free text is used only when
nothing could be resolved to a taxon.

It also never sets the observation's taxon directly. That moves the taxon but
leaves your earlier identification standing, so the observation ends up
disagreeing with itself. Posting a new identification withdraws the old one.

### The settings window

**File → Plug-in Extras → iNaturalist Settings…**, in three tabs:

- **Account** — credentials, as above.
- **Observations** — what new observations say: geoprivacy, whether to send the
  photo's GPS coordinates, an optional project ID, and whether to sync taxa back
  after uploading. Also **Sync All Linked Photos**, which refreshes every photo
  in the catalog that has an observation ID.
- **Image** — what gets uploaded: which metadata to include, whether to strip
  location or person info, and an optional copyright watermark.

Uploads are always JPEG, sRGB, 2048 px on the long edge, quality 90, and that is
not adjustable. iNaturalist rejects uploads over roughly 20 MB and displays at
most 2048 px, so a full-resolution raw conversion would fail for no gain.

Each photo upload is verified after the fact rather than trusted: iNaturalist
returns success before it has finished processing an image, so the plugin polls
until it can confirm the photo really attached, and retries if it cannot. If a
photo still fails, the plugin says so explicitly instead of leaving you with a
silently empty observation.

### Syncing taxa back

Every path that changes something on iNaturalist ends in a sync, so the catalog
is not left describing an older version of the observation. You can also sync
on demand from the panel, or across the whole catalog from settings.

A sync fetches the current community determination and:

- creates or updates the taxonomic keyword hierarchy under an **iNaturalist**
  root keyword, so searching any rank finds the photo;
- updates the custom metadata fields.

A freshly created observation has no community taxon until somebody identifies
it, so **Not identified yet** is the normal result for anything just uploaded.
It is reported separately from errors, and the sync still records the
observation's UUID, URL and quality grade.

---

## Why there is no publish service

The plugin used to be a Publish Service, and briefly an ordinary Export target
as well. Both are gone.

A publish service is a good fit for a gallery: you choose the photos, and
publishing is the whole interaction. It is a bad fit here, because on
iNaturalist the interesting question is *what is this animal*, and a publish
service has nowhere to ask it. Suggestions would have had to live in a
connection dialog that is not open at the moment you need it, on a selection it
does not know about.

What that costs, honestly: Lightroom's New / Modified / Published bookkeeping,
`metadataThatTriggersRepublish`, and — the loss worth naming — the **Comments
panel**, which only a publish service can fill in, and which is where
iNaturalist's identifications and comments would have belonged.

**If you used the publish service:** the observation link lives in the photo's
metadata, not in the collection, so nothing is orphaned on iNaturalist and
nothing needs re-uploading. The old published collection is inert; delete it
when convenient. Removing a photo from it no longer detaches anything — use
**Unlink** on the panel.

---

## The iNaturalist metadata preset

The plugin's fields live in the **Metadata** panel. Open the drop-down at the
top left of that panel and choose **iNaturalist**. The panel then shows the file
name and every iNaturalist field, with a line at the top pointing at the panel.

Switching back to **Default** gets your usual metadata fields back — the two
presets are one drop-down apart, so use whichever suits what you are doing.

**Every field is read-only.** The Metadata panel is a display, not a control.
Two fields used to be editable and both were quietly broken:

- **Species Guess** wrote a string to the catalog and did nothing else. Given
  what `species_guess` actually means (above), a guess typed here could be
  saved, uploaded, and silently discarded, with every step looking successful.
- **Observation ID** was how you adopted an existing observation, before the
  panel had a button that fetches it and asks you to confirm. A text field
  applies to the whole selection with nothing to check it against.

---

## Custom metadata fields

| Field | Description |
|---|---|
| **Species Guess** | What the photo was last uploaded or identified as |
| **Observation ID** | iNaturalist observation ID |
| **Observation UUID** | The observation's stable identifier |
| **Observation URL** | Direct link to the observation |
| **Taxon ID** | ID of the community-determined taxon |
| **Taxon Name** | Scientific name |
| **Common Name** | Vernacular/common name |
| **Quality Grade** | `casual`, `needs_id`, or `research` |
| **Last Synced** | Timestamp of the last sync |

---

## Development

The plugin is written in **Lua** using the [Lightroom Classic SDK](https://www.adobe.io/apis/creativecloud/lightroomsdk.html).

### File structure

```
inat.lrplugin/
├── Info.lua                   # Plugin identity, version, menu, tagsets, URL handler
├── ObservationPanelMenu.lua   # Plug-in Extras entry: opens the panel
├── ObservationPanel.lua       # The panel's window: view and wiring
├── PanelCore.lua              # What the panel's buttons do, minus the UI
├── RenderPhoto.lua            # Renders a JPEG without an export service
├── UploadCore.lua             # Creating and updating observations
├── SyncCore.lua               # Sync logic, callable from any entry point
├── LinkObservation.lua        # Adopting an existing observation
├── SettingsMenu.lua           # Plug-in Extras entry: opens settings
├── SettingsDialog.lua         # The settings window
├── Settings.lua               # Reading, writing and validating settings
├── WindowFix.lua              # Fixes the panel's z-order (Windows only)
├── fix_window_z_order.ps1     # The Win32 helper WindowFix shells out to
├── InatAuth.lua               # Token acquisition and credential storage
├── InatAPI.lua                # HTTP client for the iNaturalist REST API
├── PluginUrls.lua             # Builds and parses lightroom:// plugin URLs
├── URLHandler.lua             # Receives those URLs and dispatches
├── TagsetInat.lua             # Metadata panel preset: the plugin's fields
├── CustomMetadata.lua         # Custom metadata schema (schemaVersion 4)
├── Log.lua                    # Shared, enabled logger
└── json.lua                   # Bundled JSON encoder/decoder
```

Each window is split in two: the `*Dialog` / `*Panel` file builds the view and
wires the buttons, and a plain-Lua module beside it holds what those buttons
actually do. Only the second half can be tested outside Lightroom, so the aim is
for the first half to be too boring to be wrong.

`RenderPhoto.lua` exists because rendering a JPEG normally belongs to an export
service, and this plugin no longer has one. It drives `LrExportSession` directly
into a temporary folder — `export_destinationType = "tempFolder"` is refused to
a plugin that declares no export service provider, and the error names a
different field, so this took a host round trip to establish.

Lightroom runs a menu-item script top to bottom when the item is clicked, which
means such a file cannot be required from anywhere else without performing its
action as a side effect. `SettingsMenu.lua` and `ObservationPanelMenu.lua`
are therefore one-line launchers; the real work lives in the modules they call.

`InatAPI.lua` is a deliberate mirror of `explore/inat_api.py`, which was used to
verify every one of these calls against the live API. If you change behaviour in
one, change it in the other. The API has several traps that are not visible from
its responses — most notably that updating an observation deletes all of its
photos unless a specific flag is sent, and returns success either way. These are
documented at their call sites and in [docs/inat-api-notes.md](../docs/inat-api-notes.md).

### Reloading after edits

In Plug-in Manager, click **Reload Plug-in** after any Lua file change, or press **Ctrl+Alt+Shift+,** (Mac: **⌘⌥⇧,**) in Lightroom Classic.

### Testing before reloading

Lightroom embeds **Lua 5.1**, and a single 5.3-only operator anywhere stops the
whole plugin loading. The plugin's Lua can be parsed and exercised outside
Lightroom:

```powershell
cd ..\explore
.\.venv\Scripts\python.exe check_lua.py    # parse every file under Lua 5.1
.\.venv\Scripts\python.exe -m pytest       # run the plugin's Lua against SDK stubs
```

`explore/lua_harness.py` loads these real files into a Lua 5.1 interpreter with
stubbed `Lr*` modules, so token handling, HTTP shapes, keyword building and
error paths are all testable without installing anything. It cannot tell you
whether the real SDK matches the stubs, so new SDK calls still need one pass
through Lightroom.

A passing test proves nothing until it has been seen to fail. Each `mutate_*.py`
script breaks the plugin on purpose — one plausible mistake at a time, described
in the words of the bug it would be — runs the suite, and reports any mutation
nothing noticed:

```powershell
.\.venv\Scripts\python.exe mutate_panel.py        # panel, metadata, tagset, location, sync, API
.\.venv\Scripts\python.exe mutate_upload_core.py
.\.venv\Scripts\python.exe mutate_settings.py
.\.venv\Scripts\python.exe mutate_render_photo.py
```

A survivor is the interesting result. Twice so far it has been a bad mutation
rather than a missing test, which is worth checking before writing anything.

The SDK behaviours that have actually broken this plugin — and how each is
guarded — are written up in
[docs/lightroom-sdk-notes.md](../docs/lightroom-sdk-notes.md). Worth reading
before adding SDK calls.

### Logging

The plugin logs to `LrLogger("iNatLightroom")`. Logs land in Lightroom's log
directory. On Windows that is
`%LOCALAPPDATA%\Adobe\Lightroom\Logs\LrClassicLogs\iNatLightroom.log` —
observed on Lightroom Classic 15, *not* `~/Documents/LrClassicLogs` as older
notes have it. macOS is
`~/Library/Logs/Adobe/Lightroom/LrClassicLogs/` (unverified).
