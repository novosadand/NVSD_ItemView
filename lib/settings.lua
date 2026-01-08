-- NVSD_ItemView - Settings Module
-- Theme definitions, load/save with ExtState

local settings = {}

-- ExtState section name
local EXT_SECTION = "NVSD_ItemView"

-- Default shortcuts (using key names that map to ImGui_Key_*)
settings.DEFAULT_SHORTCUTS = {
  undo = {ctrl = true, shift = false, alt = false, key = "Z"},
  redo = {ctrl = true, shift = false, alt = false, key = "Y"},
}

-- Map key names to ImGui key getter functions
local function get_imgui_key(key_name)
  local key_map = {
    A = "ImGui_Key_A", B = "ImGui_Key_B", C = "ImGui_Key_C", D = "ImGui_Key_D",
    E = "ImGui_Key_E", F = "ImGui_Key_F", G = "ImGui_Key_G", H = "ImGui_Key_H",
    I = "ImGui_Key_I", J = "ImGui_Key_J", K = "ImGui_Key_K", L = "ImGui_Key_L",
    M = "ImGui_Key_M", N = "ImGui_Key_N", O = "ImGui_Key_O", P = "ImGui_Key_P",
    Q = "ImGui_Key_Q", R = "ImGui_Key_R", S = "ImGui_Key_S", T = "ImGui_Key_T",
    U = "ImGui_Key_U", V = "ImGui_Key_V", W = "ImGui_Key_W", X = "ImGui_Key_X",
    Y = "ImGui_Key_Y", Z = "ImGui_Key_Z",
    ["0"] = "ImGui_Key_0", ["1"] = "ImGui_Key_1", ["2"] = "ImGui_Key_2",
    ["3"] = "ImGui_Key_3", ["4"] = "ImGui_Key_4", ["5"] = "ImGui_Key_5",
    ["6"] = "ImGui_Key_6", ["7"] = "ImGui_Key_7", ["8"] = "ImGui_Key_8",
    ["9"] = "ImGui_Key_9",
    F1 = "ImGui_Key_F1", F2 = "ImGui_Key_F2", F3 = "ImGui_Key_F3",
    F4 = "ImGui_Key_F4", F5 = "ImGui_Key_F5", F6 = "ImGui_Key_F6",
    F7 = "ImGui_Key_F7", F8 = "ImGui_Key_F8", F9 = "ImGui_Key_F9",
    F10 = "ImGui_Key_F10", F11 = "ImGui_Key_F11", F12 = "ImGui_Key_F12",
    Space = "ImGui_Key_Space", Enter = "ImGui_Key_Enter",
    Escape = "ImGui_Key_Escape", Tab = "ImGui_Key_Tab",
    Backspace = "ImGui_Key_Backspace", Delete = "ImGui_Key_Delete",
  }
  local func_name = key_map[key_name]
  if func_name and reaper[func_name] then
    return reaper[func_name]()
  end
  return nil
end

-- Theme definitions
settings.THEMES = {
  {
    id = "default",
    name = "Default",
    description = "Classic green waveform",
    colors = {
      waveform = 0x5A9F5AFF,
      waveform_inactive = 0x3A6A3AFF,
      waveform_bg = 0x1A1A1AFF,
      centerline = 0x2A2A2AFF,
      markers = 0x4A90D9FF,
      markers_hover = 0x6AB0F9FF,
      border = 0x4A7A4AFF,
      playhead = 0x00CC00FF,
      grid_bar = 0x383838FF,
      grid_beat = 0x282828FF,
      ruler_bg = 0x252525FF,
      ruler_text = 0x888888FF,
      ruler_tick = 0x666666FF,
      info_bar_bg = 0x1E1E1EFF,
      info_bar_text = 0xBBBBBBFF,
      info_bar_icon = 0x5A9F5AFF,
      btn_on = 0x4A90D9FF,
      btn_off = 0x404040FF,
      btn_hover = 0x5AA0E9FF,
      btn_text = 0xFFFFFFFF,
    }
  },
  {
    id = "nvk_modern",
    name = "NVK Modern",
    description = "Clean, muted teal tones",
    colors = {
      waveform = 0x6B8E9BFF,
      waveform_inactive = 0x4A6570FF,
      waveform_bg = 0x1A1D1FFF,
      centerline = 0x2A2D30FF,
      markers = 0x5BC0BEFF,
      markers_hover = 0x7DD3D1FF,
      border = 0x5B7B85FF,
      playhead = 0x5BC0BEFF,
      grid_bar = 0x353840FF,
      grid_beat = 0x282B30FF,
      ruler_bg = 0x222528FF,
      ruler_text = 0x8A9098FF,
      ruler_tick = 0x606670FF,
      info_bar_bg = 0x1C1F22FF,
      info_bar_text = 0xB8C0C8FF,
      info_bar_icon = 0x5BC0BEFF,
      btn_on = 0x5BC0BEFF,
      btn_off = 0x404548FF,
      btn_hover = 0x6DD0CEFF,
      btn_text = 0xFFFFFFFF,
    }
  },
  {
    id = "ableton_dark",
    name = "Ableton Dark",
    description = "Classic DAW orange accents",
    colors = {
      waveform = 0x7B9BA6FF,
      waveform_inactive = 0x556A72FF,
      waveform_bg = 0x1E1E1EFF,
      centerline = 0x2E2E2EFF,
      markers = 0xE8A449FF,
      markers_hover = 0xFFB85CFF,
      border = 0x6A8A92FF,
      playhead = 0xE8A449FF,
      grid_bar = 0x3A3A3AFF,
      grid_beat = 0x2A2A2AFF,
      ruler_bg = 0x262626FF,
      ruler_text = 0x909090FF,
      ruler_tick = 0x686868FF,
      info_bar_bg = 0x202020FF,
      info_bar_text = 0xC0C0C0FF,
      info_bar_icon = 0xE8A449FF,
      btn_on = 0xE8A449FF,
      btn_off = 0x454545FF,
      btn_hover = 0xF8B459FF,
      btn_text = 0x1A1A1AFF,
    }
  },
  {
    id = "pro_tools",
    name = "Pro Tools",
    description = "Muted professional look",
    colors = {
      waveform = 0x5B7B8AFF,
      waveform_inactive = 0x3D5560FF,
      waveform_bg = 0x1C1C1CFF,
      centerline = 0x2C2C2CFF,
      markers = 0xC9A227FF,
      markers_hover = 0xDCB53AFF,
      border = 0x4B6B7AFF,
      playhead = 0xC9A227FF,
      grid_bar = 0x363636FF,
      grid_beat = 0x262626FF,
      ruler_bg = 0x242424FF,
      ruler_text = 0x888888FF,
      ruler_tick = 0x606060FF,
      info_bar_bg = 0x1E1E1EFF,
      info_bar_text = 0xB0B0B0FF,
      info_bar_icon = 0xC9A227FF,
      btn_on = 0xC9A227FF,
      btn_off = 0x424242FF,
      btn_hover = 0xD9B237FF,
      btn_text = 0x1A1A1AFF,
    }
  },
  {
    id = "high_contrast",
    name = "High Contrast",
    description = "Accessibility-focused bright colors",
    colors = {
      waveform = 0x7FFF00FF,
      waveform_inactive = 0x4A9900FF,
      waveform_bg = 0x0A0A0AFF,
      centerline = 0x1A1A1AFF,
      markers = 0x00BFFFFF,
      markers_hover = 0x40DFFFFF,
      border = 0x60CC00FF,
      playhead = 0xFF4444FF,
      grid_bar = 0x333333FF,
      grid_beat = 0x1A1A1AFF,
      ruler_bg = 0x151515FF,
      ruler_text = 0xCCCCCCFF,
      ruler_tick = 0x888888FF,
      info_bar_bg = 0x101010FF,
      info_bar_text = 0xEEEEEEFF,
      info_bar_icon = 0x7FFF00FF,
      btn_on = 0x00BFFFFF,
      btn_off = 0x505050FF,
      btn_hover = 0x40DFFFFF,
      btn_text = 0x000000FF,
    }
  },
  {
    id = "warm",
    name = "Warm",
    description = "Orange and amber tones",
    colors = {
      waveform = 0xD4915AFF,
      waveform_inactive = 0x8A5A3AFF,
      waveform_bg = 0x1A1816FF,
      centerline = 0x2A2826FF,
      markers = 0xE07A5FFF,
      markers_hover = 0xF08A6FFF,
      border = 0xB07A4AFF,
      playhead = 0xE07A5FFF,
      grid_bar = 0x383432FF,
      grid_beat = 0x282624FF,
      ruler_bg = 0x252220FF,
      ruler_text = 0x9A8A80FF,
      ruler_tick = 0x6A6058FF,
      info_bar_bg = 0x1E1C1AFF,
      info_bar_text = 0xC8B8A8FF,
      info_bar_icon = 0xD4915AFF,
      btn_on = 0xE07A5FFF,
      btn_off = 0x484440FF,
      btn_hover = 0xF08A6FFF,
      btn_text = 0xFFFFFFFF,
    }
  },
  {
    id = "cool",
    name = "Cool",
    description = "Blue and purple tones",
    colors = {
      waveform = 0x5A8A9FFF,
      waveform_inactive = 0x3A5A6AFF,
      waveform_bg = 0x16181AFF,
      centerline = 0x26282AFF,
      markers = 0x8A7FBFFF,
      markers_hover = 0x9A8FCFFF,
      border = 0x4A7A8FFF,
      playhead = 0x8A7FBFFF,
      grid_bar = 0x323438FF,
      grid_beat = 0x242628FF,
      ruler_bg = 0x202225FF,
      ruler_text = 0x808890FF,
      ruler_tick = 0x585E68FF,
      info_bar_bg = 0x1A1C1EFF,
      info_bar_text = 0xB0B8C0FF,
      info_bar_icon = 0x5A8A9FFF,
      btn_on = 0x8A7FBFFF,
      btn_off = 0x404448FF,
      btn_hover = 0x9A8FCFFF,
      btn_text = 0xFFFFFFFF,
    }
  },
  {
    id = "monochrome",
    name = "Monochrome",
    description = "Minimal grayscale",
    colors = {
      waveform = 0x8A8A8AFF,
      waveform_inactive = 0x5A5A5AFF,
      waveform_bg = 0x181818FF,
      centerline = 0x282828FF,
      markers = 0xCCCCCCFF,
      markers_hover = 0xEEEEEEFF,
      border = 0x707070FF,
      playhead = 0xFFFFFFFF,
      grid_bar = 0x353535FF,
      grid_beat = 0x252525FF,
      ruler_bg = 0x222222FF,
      ruler_text = 0x888888FF,
      ruler_tick = 0x606060FF,
      info_bar_bg = 0x1C1C1CFF,
      info_bar_text = 0xB0B0B0FF,
      info_bar_icon = 0x8A8A8AFF,
      btn_on = 0xA0A0A0FF,
      btn_off = 0x404040FF,
      btn_hover = 0xB0B0B0FF,
      btn_text = 0x1A1A1AFF,
    }
  },
}

-- Current settings (loaded from ExtState or defaults)
settings.current = {
  theme_id = "default",
  shortcuts = {},
}

-- Get theme by ID
function settings.get_theme(id)
  for _, theme in ipairs(settings.THEMES) do
    if theme.id == id then
      return theme
    end
  end
  return settings.THEMES[1] -- fallback to default
end

-- Get current theme colors
function settings.get_colors()
  local theme = settings.get_theme(settings.current.theme_id)
  return theme.colors
end

-- Get current shortcuts
function settings.get_shortcuts()
  return settings.current.shortcuts
end

-- Serialize shortcut to string
local function shortcut_to_string(shortcut)
  local parts = {}
  if shortcut.ctrl then table.insert(parts, "ctrl") end
  if shortcut.shift then table.insert(parts, "shift") end
  if shortcut.alt then table.insert(parts, "alt") end
  table.insert(parts, shortcut.key)
  return table.concat(parts, "+")
end

-- Parse shortcut from string
local function string_to_shortcut(str)
  local shortcut = {ctrl = false, shift = false, alt = false, key = ""}
  for part in string.gmatch(str, "[^+]+") do
    local lower_part = part:lower()
    if lower_part == "ctrl" then
      shortcut.ctrl = true
    elseif lower_part == "shift" then
      shortcut.shift = true
    elseif lower_part == "alt" then
      shortcut.alt = true
    else
      shortcut.key = part  -- Keep original case for key name
    end
  end
  return shortcut
end

-- Load settings from ExtState
function settings.load()
  -- Load theme
  local theme_id = reaper.GetExtState(EXT_SECTION, "theme")
  if theme_id and theme_id ~= "" then
    settings.current.theme_id = theme_id
  else
    settings.current.theme_id = "default"
  end

  -- Load shortcuts
  settings.current.shortcuts = {}
  for name, default in pairs(settings.DEFAULT_SHORTCUTS) do
    local saved = reaper.GetExtState(EXT_SECTION, "shortcut_" .. name)
    if saved and saved ~= "" then
      settings.current.shortcuts[name] = string_to_shortcut(saved)
    else
      -- Deep copy default
      settings.current.shortcuts[name] = {
        ctrl = default.ctrl,
        shift = default.shift,
        alt = default.alt,
        key = default.key
      }
    end
  end
end

-- Save settings to ExtState
function settings.save()
  -- Save theme
  reaper.SetExtState(EXT_SECTION, "theme", settings.current.theme_id, true)

  -- Save shortcuts
  for name, shortcut in pairs(settings.current.shortcuts) do
    reaper.SetExtState(EXT_SECTION, "shortcut_" .. name, shortcut_to_string(shortcut), true)
  end
end

-- Apply settings (update current and save)
function settings.apply(new_settings)
  settings.current.theme_id = new_settings.theme_id
  settings.current.shortcuts = new_settings.shortcuts
  settings.save()
end

-- Reset to defaults
function settings.reset_all()
  settings.current.theme_id = "default"
  settings.current.shortcuts = {}
  for name, default in pairs(settings.DEFAULT_SHORTCUTS) do
    settings.current.shortcuts[name] = {
      ctrl = default.ctrl,
      shift = default.shift,
      alt = default.alt,
      key = default.key
    }
  end
  settings.save()
end

-- Reset single shortcut to default
function settings.reset_shortcut(name)
  local default = settings.DEFAULT_SHORTCUTS[name]
  if default then
    settings.current.shortcuts[name] = {
      ctrl = default.ctrl,
      shift = default.shift,
      alt = default.alt,
      key = default.key
    }
  end
end

-- Format shortcut for display
function settings.format_shortcut(shortcut)
  local parts = {}
  if shortcut.ctrl then table.insert(parts, "Ctrl") end
  if shortcut.shift then table.insert(parts, "Shift") end
  if shortcut.alt then table.insert(parts, "Alt") end
  table.insert(parts, shortcut.key)
  return table.concat(parts, "+")
end

-- Check if a shortcut matches current key state
function settings.check_shortcut(ctx, name)
  local shortcut = settings.current.shortcuts[name]
  if not shortcut then return false end

  local ctrl = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
  local shift = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
  local alt = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Alt())

  if ctrl ~= shortcut.ctrl then return false end
  if shift ~= shortcut.shift then return false end
  if alt ~= shortcut.alt then return false end

  local imgui_key = get_imgui_key(shortcut.key)
  if not imgui_key then return false end

  return reaper.ImGui_IsKeyPressed(ctx, imgui_key)
end

return settings
