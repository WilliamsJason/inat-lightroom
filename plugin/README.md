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

Go to **Library → Plug-in Extras → iNaturalist…** and choose *Set up
credentials*. There are two ways to authenticate, and the dialog offers both.

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
plugin. Use **Clear Stored Credentials** in the same dialog to remove it all.

---

## Usage

### Upload photos as an iNaturalist observation

1. Select one or more photos in Lightroom that are of the same species.
2. Go to **File → Export** (or right-click → **Export**).
3. Choose **iNaturalist** in the Export To drop-down on the left.
4. In the export panel:
   - **Species** – type to autocomplete; pick from the suggestions.
   - **iNat crop** – optionally set a crop used only for the uploaded image.
   - **Date / Location** – override if the EXIF values are wrong.
   - **Project** – optionally add to an iNaturalist project.
5. Click **Export**.  The observation ID is written back to each photo's custom metadata.

The export settings (JPEG, 2048 px long edge, sRGB, quality 90) are locked by
the plugin. iNaturalist rejects uploads over roughly 20 MB and displays at most
2048 px, so exporting a full-resolution raw conversion would fail for no gain.

Each photo upload is verified after the fact rather than trusted: iNaturalist
returns success before it has finished processing an image, so the plugin polls
until it can confirm the photo really attached, and retries if it cannot. If a
photo still fails, the plugin says so explicitly instead of leaving you with a
silently empty observation.

### Sync taxon data back to Lightroom

1. Select photos that already have an iNaturalist observation ID.
2. Click **Sync from iNaturalist** in the Metadata panel (see below), or use
   **Library → Plug-in Extras → iNaturalist…**.
3. The plugin fetches the latest community determination from iNaturalist and:
   - Creates/updates the taxonomic keyword hierarchy under an **iNaturalist** root keyword.
   - Updates the custom metadata fields (taxon name, common name, quality grade, etc.).

---

## The iNaturalist panel

Lightroom does not let a plugin add its own panel to the Library right side, so
the plugin lives in the **Metadata** panel instead. Open the drop-down at the
top left of that panel and choose **iNaturalist**. The panel then shows the
file name and every iNaturalist field, including the clickable actions below.

Switching back to **Default** gets your usual metadata fields back — the two
presets are one drop-down apart, so use whichever suits what you are doing.

### Actions

Two rows in that panel are clickable:

- **Sync from iNaturalist** — same as the menu item, for the selected photos.
- **Link to Observation…** — paste an observation ID or URL to attach the
  selected photos to an observation that already exists on iNaturalist, then
  sync it. This is the way to adopt observations you made in the app or on the
  web.

These rows only appear on photos the plugin has touched. To add them to photos
that have no iNaturalist data yet, use **Library → Plug-in Extras →
iNaturalist…** and choose *Add iNaturalist actions to selected photos*.

The **Observation ID** field is editable: typing an ID there and syncing does
the same job as *Link to Observation…*. Everything else is read-only, because it
mirrors iNaturalist and the next sync would overwrite an edit.

---

## Custom metadata fields

| Field | Description |
|---|---|
| **Observation ID** | iNaturalist observation ID (editable) |
| **Observation URL** | Direct link to the observation |
| **Taxon ID** | ID of the community-determined taxon |
| **Taxon Name** | Scientific name |
| **Common Name** | Vernacular/common name |
| **Quality Grade** | `casual`, `needs_id`, or `research` |
| **Last Synced** | Timestamp of the last sync |
| **iNat Crop** | Crop used only for the uploaded image |

---

## Development

The plugin is written in **Lua** using the [Lightroom Classic SDK](https://www.adobe.io/apis/creativecloud/lightroomsdk.html).

### File structure

```
inat.lrplugin/
├── Info.lua                   # Plugin identity, version, menu, tagsets, URL handler
├── InatMenu.lua               # The single Plug-in Extras entry
├── PluginInit.lua             # Legacy "Set Up Credentials" menu item
├── SyncObservation.lua        # Menu script: launches a sync
├── CredentialsDialog.lua      # The credentials dialog itself
├── SyncCore.lua               # Sync logic, callable from any entry point
├── InatAuth.lua               # Token acquisition and credential storage
├── InatAPI.lua                # HTTP client for the iNaturalist REST API
├── ExportServiceProvider.lua  # Upload / publish service
├── PanelActions.lua           # lightroom:// action links for the Metadata panel
├── URLHandler.lua             # Receives those links and dispatches
├── TagsetInat.lua             # Metadata panel preset: the plugin's fields
├── CustomMetadata.lua         # Custom metadata schema
├── Log.lua                    # Shared, enabled logger
└── json.lua                   # Bundled JSON encoder/decoder
```

Lightroom runs a menu-item script top to bottom when the item is clicked, which
means such a file cannot be required from anywhere else without performing its
action as a side effect. `InatMenu.lua`, `PluginInit.lua` and
`SyncObservation.lua` are therefore thin launchers; the logic they run lives in
`SyncCore.lua` and `CredentialsDialog.lua`.

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

The SDK behaviours that have actually broken this plugin — and how each is
guarded — are written up in
[docs/lightroom-sdk-notes.md](../docs/lightroom-sdk-notes.md). Worth reading
before adding SDK calls.

### Logging

The plugin logs to `LrLogger("iNatLightroom")`. Logs land in Lightroom's log
directory (`~/Documents/LrClassicLogs` on Windows,
`~/Library/Logs/Adobe/Lightroom/LrClassicLogs/` on macOS).
