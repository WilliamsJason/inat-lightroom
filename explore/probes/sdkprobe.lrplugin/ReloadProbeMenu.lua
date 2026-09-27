--[[
  ReloadProbeMenu.lua
  -------------------
  Can a plugin make Lightroom reload a plugin?

  WHY THIS EXISTS
  ---------------
  An update applied during LrInitPlugin cannot add a file to a running session:
  Lightroom fixes the set of toolkit scripts a plugin has when it loads the
  plugin, and that is before LrInitPlugin runs. The file lands on disk
  correctly and `require` still says "Could not load toolkit script: X". Two
  releases shipped into that (0.3.0 adding ExportPresets.lua, 0.3.2 adding
  PluginFiles.lua) before a user's log explained it.

  0.3.3 answers it with words -- it tells the user to restart. The question
  this probe asks is whether it could instead be answered with an action.

  A reload runs LrShutdownPlugin and then LrInitPlugin, so it rebinds the
  script list. If a plugin can ask for one, the restart goes away and releases
  that add files stop being expensive.

  WHAT THE BINARIES SAY
  ---------------------
  The SDK documents nothing here, but Lightroom's own binaries carry the
  machinery. In substrate.dll, one method table holds:

      allPlugins | enabledPlugins | pluginForId | pluginForIdFromAllPlugins
      sdkVersionForCaller | enablePlugin | disablePlugin | installPluginAtPath
      uninstallPlugin | reloadPlugin | reloadPluginIfNeededForEachUse
      reloadAllPluginsIfNeededForEachUse | startHttpHandlerForPlugin
      removeHttpHandlerForPlugin

  named near AgSdkPluginManager and AgSdkPluginLoader. Strings next to
  reloadPlugin's body mention closeFloatingDialogsForPlugin,
  suppressNotifications, reloadOnEachUse and enabled, which reads like the
  implementation behind the Plug-in Manager's Reload Plug-in button.
  LibraryToolkit.dll also has reloadPluginFlag and reloadPluginSem, so there is
  a flag and a semaphore to fall foul of.

  That a symbol exists says nothing about whether a plugin may reach it. This
  plugin has already found two undocumented-but-importable namespaces that way
  (LrDigest, LrUUID) and there is no reason the Ag* internals should follow the
  same rule. Hence a probe rather than a patch.

  HOW IT IS STAGED
  ----------------
  Three phases, increasingly rude, each gated behind the last:

    1  discovery   can `import` reach the namespace at all, and what is on it
    2  cross       reload a *different* plugin (the real one) from this one
    3  self        reload the plugin whose own code is making the call

  Phase 3 is the one that answers the actual question and the one most likely
  to deadlock: it asks Lightroom to unload the module that is mid-call. Phase 2
  is worth doing first because if it fails there is no point reaching phase 3,
  and because it is the survivable half of the same API.

  Every phase writes its line to the log file *before* making the call. A
  reload may take this plugin's Lua state with it, and the last line written is
  then the only evidence of what happened -- the same reason Report flushes per
  line. If the file ends at "about to call", the call did not come back.
--]]

local LrDialogs = import "LrDialogs"
local LrTasks   = import "LrTasks"

local Report = require "Report"

--- The real plugin, which phase 2 asks Lightroom to reload.
local TARGET_PLUGIN_ID = "com.github.inat-lightroom"

--- Namespaces to try. The first is the one the binaries point at; the rest are
-- calibration. AgSdkPluginManager succeeding while all of them succeed would
-- mean `import` returns something for any name, which is a different finding
-- and one worth not mistaking for success.
local CANDIDATES = {
  "AgSdkPluginManager",
  "AgPluginManager",
  "AgSdkPluginLoader",
  "LrPluginManager",
  "LrPlugin",
  "AgNotARealNamespaceAtAll",
}

--- Method names read out of substrate.dll, in the order they appear there.
local METHODS = {
  "allPlugins",
  "enabledPlugins",
  "pluginForId",
  "pluginForIdFromAllPlugins",
  "sdkVersionForCaller",
  "enablePlugin",
  "disablePlugin",
  "installPluginAtPath",
  "uninstallPlugin",
  "reloadPlugin",
  "reloadPluginIfNeededForEachUse",
  "reloadAllPluginsIfNeededForEachUse",
  "startHttpHandlerForPlugin",
  "removeHttpHandlerForPlugin",
}

--- Fields worth reading off whatever pluginForId hands back.
local PLUGIN_FIELDS = {
  "id", "path", "enabled", "reloadOnEachUse", "name", "version", "status",
}

--- type(), but naming the shape rather than just "userdata".
local function describe(value)
  local kind = type(value)
  if kind ~= "userdata" and kind ~= "table" then
    return kind .. " " .. tostring(value)
  end

  local meta = nil
  pcall(function() meta = getmetatable(value) end)
  return kind .. (meta and " (has metatable)" or " (no metatable)")
end

--- Every key on a namespace, when it will admit to having any.
--
-- Guarded twice over: an SDK namespace is often userdata with __index, where
-- pairs raises rather than returning nothing, and where the keys exist but
-- cannot be listed. A failure here is not a failure of the probe -- METHODS
-- below asks by name instead, which works on exactly those objects.
local function keysOf(namespace)
  local found = {}

  local ok = pcall(function()
    for key in pairs(namespace) do
      found[#found + 1] = tostring(key)
    end
  end)

  if not ok then return nil end
  table.sort(found)
  return found
end

local function probeNamespaces(report)
  report:step("import")

  local reached = nil

  for _, name in ipairs(CANDIDATES) do
    local ok, namespace = pcall(import, name)

    if ok and namespace ~= nil then
      report:addf("  %-34s %s", name, describe(namespace))

      local keys = keysOf(namespace)
      if keys then
        report:addf("      %d key(s): %s", #keys, table.concat(keys, ", "))
      else
        report:add("      keys are not enumerable (userdata with __index)")
      end

      if name == "AgSdkPluginManager" then reached = namespace end
    else
      report:addf("  %-34s unavailable: %s", name,
        tostring(namespace):gsub("%s+", " "))
    end
  end

  return reached
end

local function probeMethods(report, manager)
  report:step("methods on AgSdkPluginManager")

  local present = {}

  for _, name in ipairs(METHODS) do
    local ok, value = pcall(function() return manager[name] end)
    local kind = ok and type(value) or "unreadable"

    report:addf("  %-38s %s", name, kind)
    if kind == "function" then present[name] = value end
  end

  return present
end

local function probePluginObject(report, methods)
  report:step("our own plugin object")

  if not methods.pluginForId then
    report:add("  pluginForId is not callable; nothing to inspect")
    return nil
  end

  local took, plugin, err = Report.timed(methods.pluginForId, _PLUGIN.id)
  report:addf("  pluginForId(%q) -> %s  [%s]", _PLUGIN.id,
    err and ("error: " .. err) or describe(plugin), took)

  if not plugin then return nil end

  for _, field in ipairs(PLUGIN_FIELDS) do
    local ok, value = pcall(function() return plugin[field] end)
    if ok and value ~= nil then
      report:addf("      %-18s %s", field, tostring(value))
    end
  end

  -- reloadOnEachUse is the cheaper lever if it is writable: Library.lrmodule
  -- calls reloadPluginIfNeededForEachUse on the menu-item path, so a plugin
  -- carrying that flag is reloaded before a menu item runs -- which is a
  -- reload we would not have to ask for.
  local ok, err2 = pcall(function() plugin.reloadOnEachUse = true end)
  report:addf("  setting reloadOnEachUse: %s",
    ok and "accepted (read back: " ..
      tostring(select(2, pcall(function() return plugin.reloadOnEachUse end)))
      .. ")" or ("refused: " .. tostring(err2)))
  pcall(function() plugin.reloadOnEachUse = false end)

  return plugin
end

--- Ask for a reload and report what came back, having already said so in the
-- log in case nothing comes back at all.
local function attemptReload(report, methods, subject, label)
  if not methods.reloadPlugin then
    report:add("  reloadPlugin is not callable; nothing to try")
    return
  end

  report:addf("  about to call reloadPlugin on %s -- if the log ends here, it "
    .. "did not return", label)

  local took, result, err = Report.timed(methods.reloadPlugin, subject)

  report:addf("  returned after %s: %s", took,
    err and ("error: " .. err) or tostring(result))
  report:add("  and this process is still running, which is itself the result")
end

local function probeCrossPluginReload(report, methods)
  report:step("reloading another plugin")

  if not methods.pluginForId then
    report:add("  pluginForId is not callable; cannot name a target")
    return
  end

  local _took, target, err = Report.timed(methods.pluginForId, TARGET_PLUGIN_ID)
  if err or not target then
    report:addf("  %s is not installed here (%s), so there is nothing safe to "
      .. "reload; install it or skip to the self test",
      TARGET_PLUGIN_ID, tostring(err))
    return
  end

  attemptReload(report, methods, target, TARGET_PLUGIN_ID)
end

local function probeSelfReload(report, methods)
  report:step("reloading ourselves")

  local _took, me, err = Report.timed(methods.pluginForId, _PLUGIN.id)
  if err or not me then
    report:addf("  could not name ourselves: %s", tostring(err))
    return
  end

  attemptReload(report, methods, me, _PLUGIN.id .. " (this plugin)")
end

LrTasks.startAsyncTask(function()
  local report = Report.new("iNat Probe: Plugin Reload")

  report:add("Asking whether a plugin can make Lightroom reload a plugin.")
  report:add("Background: an update applied at LrInitPlugin cannot add a file")
  report:add("to the running session. A reload would rebind the script list.")
  report:blank()

  local manager = probeNamespaces(report)
  report:blank()

  if not manager then
    report:add("AgSdkPluginManager is not reachable through import, so there")
    report:add("is no reload to ask for and the remaining phases are moot.")
    report:add("That is a complete answer: the restart notice stays the fix,")
    report:add("and a release that adds files stays expensive.")
    report:show()
    return
  end

  local methods = probeMethods(report, manager)
  report:blank()

  probePluginObject(report, methods)
  report:blank()

  -- Gated, and gated separately, because from here on the probe changes the
  -- state of the application rather than reading it.
  local go = LrDialogs.confirm(
    "Try reloading a plugin?",
    "Everything so far only read. The next step asks Lightroom to reload "
      .. "another plugin, and the step after that asks it to reload this one "
      .. "while this code is running.\n\nThat may hang Lightroom. The results "
      .. "so far are already on disk.",
    "Reload another plugin", "Stop here")

  if go ~= "ok" then
    report:add("Stopped before changing anything.")
    report:show()
    return
  end

  probeCrossPluginReload(report, methods)
  report:blank()

  local goSelf = LrDialogs.confirm(
    "Reload this plugin, from this plugin?",
    "This is the question that matters and the one most likely to deadlock: "
      .. "Lightroom is being asked to unload the code making the request.\n\n"
      .. "If Lightroom stops responding, that is the answer, and the log file "
      .. "will end at the line naming the call.",
    "Reload this plugin", "Stop here")

  if goSelf ~= "ok" then
    report:add("Stopped before the self test.")
    report:show()
    return
  end

  probeSelfReload(report, methods)
  report:show()
end)
