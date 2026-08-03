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

  -- Export / publish service (upload to iNaturalist)
  LrExportServiceProvider = {
    title          = LOC "$$$/iNatLightroom/ExportTitle=iNaturalist",
    file           = "ExportServiceProvider.lua",
    builtInPresent = false,
  },

  -- Custom metadata panel shown in the Metadata panel set
  LrMetadataProvider = "CustomMetadata.lua",

  -- Metadata panel presets.
  --
  -- Lightroom has no SDK hook for adding a panel to the Library right panel
  -- stack -- the plugin loader (substrate.dll) and Library.lrmodule between
  -- them recognise only the keys used in this file, and none of them are panel
  -- sections. The Metadata panel's preset dropdown is as close as a plugin
  -- gets to owning a section of that column, so that is where this plugin's UI
  -- lives.
  LrMetadataTagsetFactory = {
    "TagsetInat.lua",
    "TagsetInatCombined.lua",
  },

  -- Handles lightroom://com.github.inat-lightroom/<action> URLs, which is how
  -- the clickable rows in the Metadata panel invoke plugin code. Undocumented
  -- but real: Adobe's own bundled Flickr.lrplugin uses the same key.
  URLHandler = "URLHandler.lua",

  -- Library menu extras.
  --
  -- One item on purpose. A menu is a bad home for this and everything it can
  -- do is reachable from the Metadata panel; what has to stay is a way to arm
  -- photos that have no iNaturalist data yet, which the panel cannot do for
  -- itself.
  LrLibraryMenuItems = {
    {
      title = LOC "$$$/iNatLightroom/Menu/Main=iNaturalist…",
      file  = "InatMenu.lua",
      id    = "inat_menu",
    },
  },

  VERSION = {
    major  = 0,
    minor  = 1,
    revision = 0,
    display = "0.1.0 (pre-release)",
  },
}
