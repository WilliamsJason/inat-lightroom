--[[
  Info.lua
  --------
  Plugin identity and manifest for pinned.lrplugin.

  Required by Lightroom; this file is read before any other Lua in the plugin.
  See: https://www.adobe.io/apis/creativecloud/lightroomsdk.html
--]]

return {
  LrSdkVersion        = 10.0,
  LrSdkMinimumVersion = 6.0,

  -- The identifier is not the plugin's name and must never be renamed with it.
  -- Every custom metadata field is addressed as "<identifier>.<field>", and the
  -- OAuth redirect is lightroom://<identifier>/<action>, so changing it orphans
  -- the observation IDs already written to people's photos.
  LrToolkitIdentifier = "com.github.inat-lightroom",

  -- The displayed name, which is deliberately not "iNaturalist".
  --
  -- rcloran's lr-inaturalist-publish -- the plugin most people with this
  -- workflow already have -- sets LrPluginName to exactly "iNaturalist", and
  -- so did this one. Two identically named rows in the Plug-in Manager, with
  -- nothing but install path to tell them apart, is a support burden paid by
  -- whoever is more confused.
  --
  -- "for iNaturalist" rather than "by" or a bare "iNaturalist": the mark is
  -- theirs, and naming the site as the thing this works with is ordinary
  -- descriptive use, while leading with it implies a product of theirs. The
  -- README disclaimer says so in words; the name should not have to be
  -- corrected by it.
  --
  -- Renaming this later means also renaming the registered iNaturalist OAuth
  -- application, which shows its own name on the authorization screen. The two
  -- drifting apart puts an unfamiliar name in front of someone at the moment
  -- they are granting account access. See docs/plugin-architecture.md.
  LrPluginName        = LOC "$$$/iNatLightroom/PluginName=Pinned for iNaturalist",
  LrPluginInfoUrl     = "https://github.com/WilliamsJason/inat-lightroom",

  -- No LrExportServiceProvider key, deliberately.
  --
  -- That one key is both the publish service and the "iNaturalist" entry in
  -- the ordinary Export dialog, so removing it removes both. It used to be
  -- here, and the publish service was genuinely the best surface available
  -- before the floating panel worked -- it had a Publish button in the left
  -- panel, and Lightroom tracked New / Modified / Published for us.
  --
  -- It goes because two ways in is worse than one. Publishing kept its own
  -- idea of what had been uploaded, in the published-collection records, next
  -- to this plugin's idea of the same thing in custom metadata; they could
  -- disagree, and when they did neither was obviously wrong. The panel has the
  -- selection in front of it and the metadata on the photos, and that is
  -- enough.
  --
  -- Removing it makes Lightroom drop the published collection. Nothing is
  -- actually lost: the observation ID, UUID and URL live in custom metadata on
  -- the photos and survive. See docs/plugin-architecture.md.

  -- Custom metadata panel shown in the Metadata panel set
  LrMetadataProvider = "CustomMetadata.lua",

  -- Metadata panel preset.
  --
  -- Lightroom has no SDK hook for adding a panel to the Library right panel
  -- stack. Confirmed by dumping the loader binaries: substrate.dll and the
  -- .lrmodule files between them recognise only the keys used in this file,
  -- and the docking machinery in ui.dll (AgViewWinPanelHost::DockOrUndockPanel)
  -- has no plugin-facing key at all. The Metadata panel's preset dropdown is as
  -- close as a plugin gets to owning a section of that column, so that is where
  -- this plugin's data lives. Only its data: LibraryToolkit.dll validates
  -- custom fields down to 'string', 'enum' or 'url', so nothing there can
  -- become a control. Actions live in the floating panel below.
  --
  -- One preset, not two. A preset replaces the panel contents rather than
  -- adding to them, and the answer to wanting the ordinary fields back is to
  -- select Default -- not for this plugin to ship its own copy of it.
  LrMetadataTagsetFactory = {
    "TagsetInat.lua",
  },

  -- Handles lightroom://com.github.inat-lightroom/<action> URLs. Undocumented
  -- but real: Adobe's own bundled Flickr.lrplugin uses the same key, for the
  -- same reason we will -- receiving an OAuth authorization code.
  URLHandler = "URLHandler.lua",

  -- The plugin's own section in the Plug-in Manager, which is where updating
  -- lives. That dialog is the one Lightroom surface about the plugin rather
  -- than about photos, and it is already where people go to install one.
  LrPluginInfoProvider = "PluginInfoProvider.lua",

  -- Load and unload hooks, both of them there for the updater.
  --
  -- Shutdown is where a staged update is applied: it is the only moment when
  -- every module that was going to load has loaded, so swapping the files
  -- cannot leave a session running half of one version and half of another.
  -- Init applies anything shutdown never got to -- after a crash or a kill --
  -- and runs the once-a-day check. See UpdateInstall.lua.
  LrInitPlugin     = "PluginInit.lua",
  LrShutdownPlugin = "PluginShutdown.lua",

  -- File > Plug-in Extras.
  --
  -- Two items, both of which open a window, because windows are now the only
  -- way into this plugin. The panel needs a way to be summoned back after it
  -- is closed, and settings has to be reachable before anything works at all.
  --
  -- The key name is a lie inherited from the SDK: `LrExportMenuItems` has
  -- nothing to do with exporting. `Library.lrmodule` hangs one shared
  -- "Plug-in Extras" submenu off three parents, and this key selects File --
  -- see docs/lightroom-sdk-notes.md for the disassembly. File is the right
  -- parent because the Library menu only exists in the Library module, while
  -- both of these items open floating windows that work from anywhere, and
  -- neither is an operation on the selected photos.
  --
  -- "Pinned", not "iNaturalist": Plug-in Extras is one flat shared submenu,
  -- so these items sit directly alongside those of every other installed
  -- plugin, and lr-inaturalist-publish puts its own unprefixed items in the
  -- same list. The item text is the only thing distinguishing them.
  LrExportMenuItems = {
    {
      title = LOC "$$$/iNatLightroom/Menu/Panel=Pinned Panel",
      file  = "ObservationPanelMenu.lua",
      id    = "inat_panel",
    },
    {
      title = LOC "$$$/iNatLightroom/Menu/Settings=Pinned Settings…",
      file  = "SettingsMenu.lua",
      id    = "inat_settings",
    },
  },

  -- The installed version, and half of what the updater compares.
  --
  -- The other half is the tag on GitHub. They must agree, so the release
  -- workflow refuses to build unless the tag is exactly "v" followed by the
  -- three numbers below; see .github/workflows/release.yml and
  -- explore/plugin_version.py. A mismatch is not cosmetic -- the updater would
  -- either hide a real update forever or offer the same one on every check.
  --
  -- `display` is what the Plug-in Manager shows. It carried "(pre-release)"
  -- until the first tagged release, and must not again: a release built from a
  -- plugin that calls itself pre-release ships that label to everyone.
  VERSION = {
    major  = 0,
    minor  = 1,
    revision = 4,
    display = "0.1.4",
  },
}
