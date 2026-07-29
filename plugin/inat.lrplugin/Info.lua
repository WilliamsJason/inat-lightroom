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

  -- Library menu extras
  LrLibraryMenuItems = {
    {
      title   = LOC "$$$/iNatLightroom/Menu/Sync=iNaturalist: Sync Selected Photos",
      file    = "SyncObservation.lua",
      enabledWhen = "photosSelected",
    },
    {
      title   = LOC "$$$/iNatLightroom/Menu/Setup=iNaturalist: Set Up Credentials",
      file    = "PluginInit.lua",
      id      = "setup_credentials",
    },
  },

  VERSION = {
    major  = 0,
    minor  = 1,
    revision = 0,
    display = "0.1.0 (pre-release)",
  },
}
