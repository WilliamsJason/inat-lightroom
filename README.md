# inat-lightroom

**Pinned for iNaturalist** — an Adobe Lightroom Classic plugin that uploads
photos to [iNaturalist](https://www.inaturalist.org/) and syncs the community's
identifications back into your catalog as searchable taxonomy.

---

## Disclaimer

This is **not** an official iNaturalist product. It is an independent,
community-built plugin, not affiliated with, endorsed by, or supported by
iNaturalist or its staff. Please don't ask them about it. "iNaturalist" appears
in the name only to say what this works with; the name and logo belong to
iNaturalist.

It is also not related to the other Lightroom plugins for the same site — most
of which install as plain "iNaturalist". If you have one of those too, this is
the entry called **Pinned for iNaturalist**.

It is provided **as-is**, with no warranty — see [LICENSE](LICENSE). It writes to
a real iNaturalist account through the public API, so use it with the same care
you would use posting by hand.

It is also **completely untested on macOS**. Development and testing happen on
Windows with Lightroom Classic. The Mac-specific paths and scripts are written
to the documentation but have not been run; the panel's window handling is a
deliberate no-op there.

That said — I would love for this to be genuinely useful to other people. If
something is broken, confusing, or risky, or if a feature would make a real
difference to how you use iNaturalist and Lightroom together,
[open an issue](https://github.com/WilliamsJason/inat-lightroom/issues) and tell
me. Bug reports from macOS users are especially welcome, since I can't produce
them myself.

---

## Goals

### 1. Upload photos to iNaturalist

- **Multi-photo observations** – select multiple photos of the same species and associate them with a single iNaturalist observation record.
- **Native resolution** – export at iNaturalist's recommended maximum (2048 px on the long edge) so Lightroom never has to upscale or over-downscale.
- **Two-way link** – write the iNaturalist observation ID back to the Lightroom photo as custom metadata so the two records stay connected.
- **Rich metadata at upload time** – choose from AI species recommendations, add the observation to a project, and optionally override the location or timestamp before submitting.

### 2. Sync iNaturalist data back to Lightroom

Using the stored observation ID, pull the latest community determination from iNaturalist and write the full taxonomic tree (kingdom → species) into the photo's keywords/metadata so that searching for any taxonomic rank returns the correct photos.

### 3. Future ideas

Any other useful functionality identified as the project matures.

---

## Status

The plugin does the full round trip today: identify a photo, upload it as an
iNaturalist observation with the image attached, and sync the community
determination back as a taxonomic keyword tree. Verified end to end against the
live API — there is no iNaturalist sandbox, so every test writes to a real
account.

Everything happens in a floating **Pinned panel** (Library → Plug-in
Extras). It follows the filmstrip selection, asks iNaturalist's vision model
what the photo is, and turns the answer into an upload or an identification on
an observation you already have. A second window holds settings: credentials,
export options, and a sync of everything in the catalog that is linked.

Lightroom gives a plugin no docked surface that can hold a button — that was
checked against the shipped binaries, not assumed — so a floating window is as
close to a panel as a plugin gets. On Windows it is nudged into behaving like
one: a small helper hands the window to Lightroom so it stays above Lightroom,
and only Lightroom, instead of the whole desktop.

The **Metadata panel** carries a **Pinned for iNaturalist** preset, but it is
display only. It shows what the observation says; it does not change it.

There was a Publish Service and an ordinary Export target. Both are gone. A
publish service gives you Lightroom's new/modified/published bookkeeping, but
it makes publishing the moment you identify a photo, and by then it is too late
to ask what the photo is. See [`docs/plugin-architecture.md`](docs/plugin-architecture.md)
for what that costs and why it was still worth it — and for what to do if you
have an existing published collection.

Authentication is a pasted API token, which expires daily. The frictionless
path is browser sign-in via the OAuth authorization code flow, which is not
built yet; the `lightroom://` plumbing it needs already exists. An earlier
form that took your iNaturalist password directly has been removed — see
[`plugin/README.md`](plugin/README.md).

Rough edges worth knowing: an upload takes the whole selection into one
observation, but there is no way yet to group photos across separate uploads;
and nothing has been tested on macOS, where the panel's window handling is a
deliberate no-op.

---

## Installing

Download `inat-lightroom-<version>.zip` from the
[latest release](https://github.com/WilliamsJason/inat-lightroom/releases/latest),
unzip it, and point **File → Plug-in Manager → Add** at the `pinned.lrplugin`
folder. Keep it somewhere permanent that you can write to — the plugin updates
itself in place, and Lightroom remembers it by path.

Better still, unzip it into Lightroom Classic's standard plugin location, where
Lightroom loads it at start-up on its own and you can skip the **Add** step
entirely:

- **Windows** — `C:\Users\<username>\AppData\Roaming\Adobe\Lightroom\Modules`
- **macOS** — `~/Library/Application Support/Adobe/Lightroom/Modules`
  (`Library` is hidden in Finder; reach it with **Go → Go to Folder…** and type
  `~/Library`)

Create the `Modules` folder if it isn't there yet.

After that, **File → Plug-in Manager → Pinned for iNaturalist → Updates** has a button that
fetches the latest release, checks it against its published checksum, and
installs it when you next quit Lightroom. It also checks once a day by itself,
and offers each new version once in a dialog whose **Update** button does the
same thing. Nothing installs without a click, and the daily check can be
switched off. See [`SECURITY.md`](SECURITY.md) for what you are trusting when
you use it.

Setup and usage are in [`plugin/README.md`](plugin/README.md).

---

## Repository layout

```
inat-lightroom/
├── docs/                        # Notes, API reference, architecture decisions
│   ├── inat-api-notes.md        # iNaturalist REST API traps, verified live
│   ├── lightroom-sdk-notes.md   # Lightroom SDK traps, found the hard way
│   └── plugin-architecture.md   # Lightroom plugin design
│
├── explore/                     # Python exploration + the Lua test harness
│   ├── README.md
│   ├── inat_api.py              # Direct API client; the Lua mirrors this
│   ├── feasibility_test.py      # Full round trip against the live API
│   ├── suggest_species.py       # Computer-vision species suggestions
│   ├── lua_harness.py           # Runs the plugin's Lua outside Lightroom
│   ├── check_lua.py             # Parses the plugin under Lua 5.1
│   ├── plugin_version.py        # Reads Info.lua's version; the release gate
│   ├── install_plugin.ps1       # Copies a working tree into Lightroom's copy
│   ├── test_*_lua.py            # Tests over the plugin's actual Lua
│   └── mutate_*.py              # Breaks the plugin on purpose to check the
│                                #   tests would notice
│
├── .github/workflows/           # Verify on every push; build a release on a tag
│
└── plugin/                      # Adobe Lightroom Classic plugin (Lua)
    ├── README.md
    └── pinned.lrplugin/
        ├── Info.lua             # Plugin identity, version, menu, tagsets, URL handler
        ├── ObservationPanelMenu.lua  # Plug-in Extras entry: opens the panel
        ├── ObservationPanel.lua # The panel's window: view and wiring
        ├── PanelCore.lua        # What its buttons do, minus the UI
        ├── RenderPhoto.lua      # Renders a JPEG without an export service
        ├── UploadCore.lua       # Creating and updating observations
        ├── SyncCore.lua         # Sync taxon data → Lightroom keywords
        ├── LinkObservation.lua  # Adopting an existing observation
        ├── SettingsMenu.lua     # Plug-in Extras entry: settings
        ├── SettingsDialog.lua   # The settings window
        ├── Settings.lua         # Reading, writing and validating settings
        ├── WindowFix.lua        # Keeps the panel above Lightroom, not the desktop
        ├── fix_window_z_order.ps1 # The Win32 helper it shells out to
        ├── PluginInfoProvider.lua # The Updates section in the Plug-in Manager
        ├── PluginInit.lua       # Load hook: finishes an interrupted update, checks for new
        ├── PluginShutdown.lua   # Unload hook: applies a staged update
        ├── Updater.lua          # Reads the GitHub release feed, compares versions
        ├── UpdateCore.lua       # When to check, what to say, what to install
        ├── UpdateInstall.lua    # Download, verify, stage, swap
        ├── install_update.ps1   # Verifies and unpacks an update (Windows)
        ├── install_update.sh    # Verifies and unpacks an update (macOS)
        ├── InatAuth.lua         # Token acquisition and credential storage
        ├── InatAPI.lua          # HTTP client for the iNaturalist REST API
        ├── PluginUrls.lua       # Builds and parses lightroom:// plugin URLs
        ├── URLHandler.lua       # Receives those URLs and dispatches
        ├── TagsetInat.lua       # Metadata panel preset (display only)
        ├── CustomMetadata.lua   # Custom metadata schema
        ├── Log.lua              # Shared logger
        └── json.lua             # Bundled JSON encoder/decoder
```

---

## Quick start (Python exploration)

```powershell
cd explore
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```

Put an API token from <https://www.inaturalist.org/users/api_token> in `.env`
as `INAT_API_TOKEN`, then:

```powershell
# Species suggestions for a photo
.\.venv\Scripts\python.exe suggest_species.py --photo C:\path\to\photo.jpg

# Full upload/update/sync round trip -- creates a real observation
.\.venv\Scripts\python.exe feasibility_test.py --photo C:\path\to\photo.jpg
```

See [`explore/README.md`](explore/README.md) for full details.

---

## Quick start (Lightroom plugin)

See [`plugin/README.md`](plugin/README.md) for installation and development instructions.

---

## Releasing

Releases are built by GitHub Actions from a tag, and the tag is the source of
truth for the version:

1. Bump `VERSION` in `plugin/pinned.lrplugin/Info.lua`, and commit it.
2. Tag the commit `vX.Y.Z` — matching those numbers exactly — and push the tag.

The workflow then parses the Lua under 5.1, runs the tests, refuses to continue
unless the tag and `Info.lua` agree, and publishes
`inat-lightroom-X.Y.Z.zip` plus `SHA256SUMS`. Those two assets are what the
plugin's own updater looks for, so a release published by hand without them is
one the updater will report but cannot install.

---

## Contributing

This is currently a personal exploratory project. If you have ideas or want to collaborate, open an issue to start the conversation.

---

## License

MIT – see [LICENSE](LICENSE).
