-- NVSD_ItemView_Settings.lua
-- Standalone settings window for NVSD_ItemView
-- Run this to open settings without the main viewer

-- Get script directory for loading modules
local script_path = debug.getinfo(1, "S").source:match("@(.+)")
local script_dir = script_path:match("(.+)[/\\]")

-- Load modules
local settings = dofile(script_dir .. "/lib/settings.lua")
local settings_ui = dofile(script_dir .. "/lib/settings_ui.lua")

-- Check for ReaImGui
if not reaper.ImGui_CreateContext then
  reaper.MB("This script requires the ReaImGui extension.\nInstall it via ReaPack: Extensions > ReaPack > Browse packages > ReaImGui", "Missing Dependency", 0)
  return
end

-- Create ImGui context
local ctx = reaper.ImGui_CreateContext("NVSD_ItemView_Settings")

-- Initialize settings
settings.load()

-- Open settings UI
settings_ui.open(settings)

-- Main loop
local function loop()
  local visible, open = reaper.ImGui_Begin(ctx, "NVSD ItemView Settings Host", true, reaper.ImGui_WindowFlags_NoDecoration() + reaper.ImGui_WindowFlags_NoBackground())

  if visible then
    -- Draw settings UI
    settings_ui.draw(ctx, settings)
    reaper.ImGui_End(ctx)
  end

  -- Keep running while settings window is open
  if open and settings_ui.is_open() then
    reaper.defer(loop)
  end
end

reaper.defer(loop)
