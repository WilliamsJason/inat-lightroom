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

  -- Publish service (upload photos to iNaturalist as observations).
  --
  -- There is no separate LrPublishService manifest key: a publish service is
  -- an export service provider whose table sets supportsIncrementalPublish.
  -- Adobe's own bundled Flickr.lrplugin declares itself exactly this way.
  LrExportServiceProvider = {
    title          = LOC "$$$/iNatLightroom/ExportTitle=iNaturalist",
    file           = "ExportServiceProvider.lua",
    builtInPresent = false,
  },

  -- Custom metadata panel shown in the Metadata panel set
  LrMetadataProvider = "CustomMetadata.lua",

  -- Metadata panel preset.
  --
  -- Lightroom has no SDK hook for adding a panel to the Library right panel
  -- stack -- the plugin loader (substrate.dll) and Library.lrmodule between
  -- them recognise only the keys used in this file, and none of them are panel
  -- sections. The Metadata panel's preset dropdown is as close as a plugin
  -- gets to owning a section of that column, so that is where this plugin's
  -- data lives. Only its data: the panel renders text fields and nothing a
  -- plugin can turn into a control, so actions belong to the publish service.
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
  -- One item, and only because credentials have to be entered before anything
  -- else works and there is nowhere better to start from. Everything else is
  -- on the publish service, which is in the Library's left panel while you
  -- work; a menu is not.
  LrLibraryMenuItems = {
    {
      title = LOC "$$$/iNatLightroom/Menu/Credentials=Set Up Credentials…",
      file  = "CredentialsMenu.lua",
      id    = "inat_credentials",
    },
  },

  VERSION = {
    major  = 0,
    minor  = 1,
    revision = 0,
    display = "0.1.0 (pre-release)",
  },
}
