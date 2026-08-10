--[[
  Info.lua
  --------
  Plugin identity and manifest for inat.lrplugin.

  Required by Lightroom; this file is read before any other Lua in the plugin.
  See: https://www.adobe.io/apis/creativecloud/lightroomsdk.html
--]]

return {
  LrSdkVersion        = 10.0,
  LrSdkMinimumVersion = 6.0,

  LrToolkitIdentifier = "com.github.inat-lightroom",
  LrPluginName        = LOC "$$$/iNatLightroom/PluginName=iNaturalist",
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

  -- Library menu extras.
  --
  -- Two items, both of which open a window, because windows are now the only
  -- way into this plugin. The panel needs a way to be summoned back after it
  -- is closed, and settings has to be reachable before anything works at all.
  LrLibraryMenuItems = {
    {
      title = LOC "$$$/iNatLightroom/Menu/Panel=iNaturalist Panel",
      file  = "ObservationPanelMenu.lua",
      id    = "inat_panel",
    },
    {
      title = LOC "$$$/iNatLightroom/Menu/Settings=iNaturalist Settings…",
      file  = "SettingsMenu.lua",
      id    = "inat_settings",
    },
    -- TEMPORARY. Proves LrExportSession works in the host before the panel is
    -- built on it. Goes, with RenderProbe.lua, once it has passed.
    {
      title = LOC "$$$/iNatLightroom/Menu/RenderProbe=Render Probe (temporary)",
      file  = "RenderProbe.lua",
      id    = "inat_render_probe",
    },
  },

  VERSION = {
    major  = 0,
    minor  = 1,
    revision = 0,
    display = "0.1.0 (pre-release)",
  },
}
