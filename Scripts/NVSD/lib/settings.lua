-- NVSD_ItemView - Settings Module
-- Theme definitions, load/save with ExtState

local settings = {}

-- When true, check_shortcut() returns false (key capture mode)
settings.listening = false

-- ExtState section name
local EXT_SECTION = "NVSD_ItemView"

-- Default shortcuts (using key names that map to ImGui_Key_*)
settings.DEFAULT_SHORTCUTS = {
  zoom_in = {ctrl = false, shift = false, alt = false, key = ""},  -- Not set by default
  zoom_out = {ctrl = false, shift = false, alt = false, key = ""},
  reset_zoom = {ctrl = false, shift = false, alt = false, key = "F"},
  toggle_warp = {ctrl = false, shift = false, alt = false, key = "W"},
  toggle_mute = {ctrl = false, shift = false, alt = false, key = "Num0"},
  reverse = {ctrl = false, shift = false, alt = false, key = "R"},
  clear = {ctrl = false, shift = true, alt = false, key = "C"},
  crop_to_selection = {ctrl = false, shift = false, alt = false, key = "C"},
  open_editor = {ctrl = true, shift = false, alt = true, key = "E"},
  toggle_snap = {ctrl = true, shift = false, alt = false, key = "4"},
  audio_preview = {ctrl = true, shift = false, alt = false, key = "Space"},
  envelope_lock = {ctrl = false, shift = false, alt = false, key = "L"},
  show_volume_env = {ctrl = false, shift = true, alt = false, key = "V"},
  show_pitch_env = {ctrl = false, shift = true, alt = false, key = "H"},
  show_pan_env = {ctrl = false, shift = true, alt = false, key = "P"},
  hide_envelopes = {ctrl = false, shift = false, alt = false, key = "H"},
  open_settings = {ctrl = false, shift = false, alt = true, key = "S"},
  set_start_marker = {ctrl = false, shift = false, alt = false, key = "Mouse4"},
  set_end_marker = {ctrl = false, shift = false, alt = false, key = "Mouse5"},
  set_fade_in = {ctrl = false, shift = true, alt = false, key = "Mouse4"},
  set_fade_out = {ctrl = false, shift = true, alt = false, key = "Mouse5"},
  zoom_to_markers = {ctrl = false, shift = false, alt = false, key = "Z"},
  unzoom_all = {ctrl = false, shift = false, alt = true, key = "Z"},
  toggle_cue_markers = {ctrl = false, shift = false, alt = false, key = "M"},
  toggle_ghost_markers = {ctrl = false, shift = false, alt = false, key = "G"},
  show_in_explorer = {ctrl = true, shift = false, alt = false, key = "F"},
  quantize_transients = {ctrl = true, shift = false, alt = false, key = "U"},
  insert_warp_marker = {ctrl = true, shift = false, alt = false, key = "I"},
  add_transient = {ctrl = true, shift = true, alt = false, key = "I"},
  preview_from_start = {ctrl = false, shift = false, alt = false, key = "Enter"},
}

-- Map key names to ImGui key getter function names (created once at module load)
local KEY_NAME_TO_FUNC = {
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
  Insert = "ImGui_Key_Insert",
  Home = "ImGui_Key_Home", End = "ImGui_Key_End",
  PageUp = "ImGui_Key_PageUp", PageDown = "ImGui_Key_PageDown",
  ["Num0"] = "ImGui_Key_Keypad0", ["Num1"] = "ImGui_Key_Keypad1",
  ["Num2"] = "ImGui_Key_Keypad2", ["Num3"] = "ImGui_Key_Keypad3",
  ["Num4"] = "ImGui_Key_Keypad4", ["Num5"] = "ImGui_Key_Keypad5",
  ["Num6"] = "ImGui_Key_Keypad6", ["Num7"] = "ImGui_Key_Keypad7",
  ["Num8"] = "ImGui_Key_Keypad8", ["Num9"] = "ImGui_Key_Keypad9",
  -- Symbol keys
  ["["] = "ImGui_Key_LeftBracket", ["]"] = "ImGui_Key_RightBracket",
  ["-"] = "ImGui_Key_Minus", ["="] = "ImGui_Key_Equal",
  [";"] = "ImGui_Key_Semicolon", ["'"] = "ImGui_Key_Apostrophe",
  [","] = "ImGui_Key_Comma", ["."] = "ImGui_Key_Period",
  ["/"] = "ImGui_Key_Slash", ["\\"] = "ImGui_Key_Backslash",
  ["`"] = "ImGui_Key_GraveAccent",
  -- Arrow keys
  Up = "ImGui_Key_UpArrow", Down = "ImGui_Key_DownArrow",
  Left = "ImGui_Key_LeftArrow", Right = "ImGui_Key_RightArrow",
  -- Numpad operators
  ["Num+"] = "ImGui_Key_KeypadAdd", ["Num-"] = "ImGui_Key_KeypadSubtract",
  ["Num*"] = "ImGui_Key_KeypadMultiply", ["Num/"] = "ImGui_Key_KeypadDivide",
  ["Num."] = "ImGui_Key_KeypadDecimal", ["NumEnter"] = "ImGui_Key_KeypadEnter",
  -- Mouse buttons (handled specially via IsMouseClicked, not IsKeyPressed)
  Mouse4 = "MOUSE_4", Mouse5 = "MOUSE_5",
}

-- Cache resolved ImGui key integer values (populated on first use, avoids repeated C calls)
local key_cache = {}

local function get_imgui_key(key_name)
  local cached = key_cache[key_name]
  if cached then return cached end
  local func_name = KEY_NAME_TO_FUNC[key_name]
  if func_name and reaper[func_name] then
    local val = reaper[func_name]()
    key_cache[key_name] = val
    return val
  end
  return nil
end

-- Cached modifier key constants (resolved once on first check_shortcut call)
local MOD_CTRL, MOD_SHIFT, MOD_ALT

-- All bindable key names (excludes Escape/Backspace/Delete which are capture controls)
local BINDABLE_KEYS = {
  "A","B","C","D","E","F","G","H","I","J","K","L","M",
  "N","O","P","Q","R","S","T","U","V","W","X","Y","Z",
  "0","1","2","3","4","5","6","7","8","9",
  "F1","F2","F3","F4","F5","F6","F7","F8","F9","F10","F11","F12",
  "Space","Enter","Tab","Insert","Home","End","PageUp","PageDown",
  "Num0","Num1","Num2","Num3","Num4","Num5","Num6","Num7","Num8","Num9",
  "[","]","-","=",";","'",",",".","/","\\","`",
  "Up","Down","Left","Right",
  "Num+","Num-","Num*","Num/","Num.","NumEnter",
  "Mouse4","Mouse5",
}

-- Check which bindable key was pressed this frame (for capture mode)
-- Returns key name string or nil
function settings.capture_pressed_key(ctx)
  -- Check mouse buttons first
  if reaper.ImGui_IsMouseClicked(ctx, 4) then return "Mouse4" end
  if reaper.ImGui_IsMouseClicked(ctx, 3) then return "Mouse5" end
  -- Check keyboard keys
  for _, key_name in ipairs(BINDABLE_KEYS) do
    if key_name ~= "Mouse4" and key_name ~= "Mouse5" then
      local imgui_key = get_imgui_key(key_name)
      if imgui_key and reaper.ImGui_IsKeyPressed(ctx, imgui_key) then
        return key_name
      end
    end
  end
  return nil
end

-- Check if a binding conflicts with any other shortcut
-- Returns conflicting shortcut name or nil
function settings.find_conflict(shortcuts, exclude_name, binding)
  if not binding or binding.key == "" then return nil end
  for name, shortcut in pairs(shortcuts) do
    if name ~= exclude_name and shortcut.key ~= "" then
      if shortcut.key == binding.key
        and shortcut.ctrl == binding.ctrl
        and shortcut.shift == binding.shift
        and shortcut.alt == binding.alt then
        return name
      end
    end
  end
  return nil
end

-- Color keys list for serialization (custom theme)
local COLOR_KEYS = { "waveform", "waveform_inactive", "waveform_bg", "centerline",
  "markers", "markers_hover", "border", "playhead", "grid_bar", "grid_beat",
  "ruler_bg", "ruler_text", "ruler_tick", "info_bar_bg", "info_bar_text",
  "info_bar_icon", "btn_on", "btn_off", "btn_hover", "btn_text" }
settings.COLOR_KEYS = COLOR_KEYS

-- Theme definitions
settings.THEMES = {
  {
    id = "default",
    name = "Default",
    description = "Professional steel-blue with gold accents",
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
      btn_text = 0xFFFFFFFF,
    }
  },
  {
    id = "classic",
    name = "Classic",
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
      grid_beat = 0x2E2E2EFF,
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
    id = "modern",
    name = "Modern",
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
      btn_text = 0xFFFFFFFF,
    }
  },
  {
    id = "pro_tools",
    name = "Pro Tools",
    description = "Authentic blue-teal with lighter dark bg",
    colors = {
      waveform = 0x5588A0FF,
      waveform_inactive = 0x3A6070FF,
      waveform_bg = 0x2A2A2AFF,
      centerline = 0x383838FF,
      markers = 0xC9A227FF,
      markers_hover = 0xDCB53AFF,
      border = 0x506070FF,
      playhead = 0x6699CCFF,
      grid_bar = 0x3C3C3CFF,
      grid_beat = 0x323232FF,
      ruler_bg = 0x3A3A3AFF,
      ruler_text = 0x999999FF,
      ruler_tick = 0x666666FF,
      info_bar_bg = 0x282828FF,
      info_bar_text = 0xB0B0B0FF,
      info_bar_icon = 0xC9A227FF,
      btn_on = 0xC9A227FF,
      btn_off = 0x484848FF,
      btn_hover = 0xD9B237FF,
      btn_text = 0xE0E0E0FF,
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
      btn_text = 0xFFFFFFFF,
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
      btn_text = 0xFFFFFFFF,
    }
  },
  {
    id = "sunset",
    name = "Sunset",
    description = "Warm earth tones",
    colors = {
      waveform = 0xC4785AFF,
      waveform_inactive = 0x7A4A38FF,
      waveform_bg = 0x1A1614FF,
      centerline = 0x2A2624FF,
      markers = 0xD4A850FF,
      markers_hover = 0xE8BC64FF,
      border = 0xA06848FF,
      playhead = 0xE8C040FF,
      grid_bar = 0x383230FF,
      grid_beat = 0x282422FF,
      ruler_bg = 0x252120FF,
      ruler_text = 0x988878FF,
      ruler_tick = 0x685850FF,
      info_bar_bg = 0x1E1A18FF,
      info_bar_text = 0xC8B8A8FF,
      info_bar_icon = 0xC4785AFF,
      btn_on = 0xD4A850FF,
      btn_off = 0x484240FF,
      btn_hover = 0xE4B860FF,
      btn_text = 0xFFFFFFFF,
    }
  },
  {
    id = "arctic",
    name = "Arctic",
    description = "Cool blues and whites",
    colors = {
      waveform = 0x5A8AAFFF,
      waveform_inactive = 0x3A5A70FF,
      waveform_bg = 0x161A1EFF,
      centerline = 0x262A2EFF,
      markers = 0x70C0D8FF,
      markers_hover = 0x88D4ECFF,
      border = 0x4A7A95FF,
      playhead = 0x90E0F0FF,
      grid_bar = 0x323638FF,
      grid_beat = 0x242628FF,
      ruler_bg = 0x202428FF,
      ruler_text = 0x808A92FF,
      ruler_tick = 0x586068FF,
      info_bar_bg = 0x1A1E22FF,
      info_bar_text = 0xB0BCC8FF,
      info_bar_icon = 0x5A8AAFFF,
      btn_on = 0x70C0D8FF,
      btn_off = 0x404448FF,
      btn_hover = 0x80D0E8FF,
      btn_text = 0xFFFFFFFF,
    }
  },
  {
    id = "forest",
    name = "Forest",
    description = "Natural greens",
    colors = {
      waveform = 0x5A8A60FF,
      waveform_inactive = 0x3A5A40FF,
      waveform_bg = 0x161A16FF,
      centerline = 0x262A26FF,
      markers = 0x8AB060FF,
      markers_hover = 0x9EC474FF,
      border = 0x4A7A50FF,
      playhead = 0xA0D060FF,
      grid_bar = 0x323832FF,
      grid_beat = 0x242824FF,
      ruler_bg = 0x202420FF,
      ruler_text = 0x808A80FF,
      ruler_tick = 0x586058FF,
      info_bar_bg = 0x1A1E1AFF,
      info_bar_text = 0xB0C0B0FF,
      info_bar_icon = 0x5A8A60FF,
      btn_on = 0x8AB060FF,
      btn_off = 0x404840FF,
      btn_hover = 0x9AC070FF,
      btn_text = 0xFFFFFFFF,
    }
  },
  {
    id = "neon",
    name = "Neon",
    description = "High energy, fun",
    colors = {
      waveform = 0xFF4488FF,
      waveform_inactive = 0x992A55FF,
      waveform_bg = 0x12101AFF,
      centerline = 0x22202AFF,
      markers = 0x44FF88FF,
      markers_hover = 0x66FF9AFF,
      border = 0xCC3070FF,
      playhead = 0x44CCFFFF,
      grid_bar = 0x302E38FF,
      grid_beat = 0x201E28FF,
      ruler_bg = 0x1E1C25FF,
      ruler_text = 0x887898FF,
      ruler_tick = 0x605068FF,
      info_bar_bg = 0x18161EFF,
      info_bar_text = 0xC0B0D0FF,
      info_bar_icon = 0xFF4488FF,
      btn_on = 0x44FF88FF,
      btn_off = 0x403848FF,
      btn_hover = 0x55FF99FF,
      btn_text = 0xFFFFFFFF,
    }
  },
  {
    id = "bitwig",
    name = "Bitwig",
    description = "Warm orange, modern energy",
    colors = {
      waveform = 0xA0A0A0FF,
      waveform_inactive = 0x686868FF,
      waveform_bg = 0x1E1C1AFF,
      centerline = 0x2E2C2AFF,
      markers = 0xFF8800FF,
      markers_hover = 0xFFA030FF,
      border = 0x808080FF,
      playhead = 0xFF8800FF,
      grid_bar = 0x3A3836FF,
      grid_beat = 0x2A2826FF,
      ruler_bg = 0x262422FF,
      ruler_text = 0x909090FF,
      ruler_tick = 0x686058FF,
      info_bar_bg = 0x201E1CFF,
      info_bar_text = 0xC0B8B0FF,
      info_bar_icon = 0xFF8800FF,
      btn_on = 0xFF8800FF,
      btn_off = 0x484440FF,
      btn_hover = 0xFFA030FF,
      btn_text = 0xFFFFFFFF,
    }
  },
  {
    id = "cubase",
    name = "Cubase",
    description = "Cool blue precision",
    colors = {
      waveform = 0x7090A8FF,
      waveform_inactive = 0x4A6070FF,
      waveform_bg = 0x181A1EFF,
      centerline = 0x282A2EFF,
      markers = 0x5A8ACAFF,
      markers_hover = 0x6A9ADAFF,
      border = 0x607890FF,
      playhead = 0x5A8ACAFF,
      grid_bar = 0x323438FF,
      grid_beat = 0x242628FF,
      ruler_bg = 0x222428FF,
      ruler_text = 0x8890A0FF,
      ruler_tick = 0x586070FF,
      info_bar_bg = 0x1C1E22FF,
      info_bar_text = 0xB0B8C8FF,
      info_bar_icon = 0x5A8ACAFF,
      btn_on = 0x5A8ACAFF,
      btn_off = 0x404448FF,
      btn_hover = 0x6A9ADAFF,
      btn_text = 0xFFFFFFFF,
    }
  },
  {
    id = "logic",
    name = "Logic Pro",
    description = "Minimal apple blue with sage green",
    colors = {
      waveform = 0x6A8A6AFF,
      waveform_inactive = 0x485A48FF,
      waveform_bg = 0x1A1A1AFF,
      centerline = 0x2A2A2AFF,
      markers = 0x4488CCFF,
      markers_hover = 0x5498DCFF,
      border = 0x5A7A5AFF,
      playhead = 0x4488CCFF,
      grid_bar = 0x343434FF,
      grid_beat = 0x262626FF,
      ruler_bg = 0x242424FF,
      ruler_text = 0x888888FF,
      ruler_tick = 0x606060FF,
      info_bar_bg = 0x1C1C1CFF,
      info_bar_text = 0xB0B0B0FF,
      info_bar_icon = 0x4488CCFF,
      btn_on = 0x4488CCFF,
      btn_off = 0x424242FF,
      btn_hover = 0x5498DCFF,
      btn_text = 0xFFFFFFFF,
    }
  },
  {
    id = "studio_one",
    name = "Studio One",
    description = "Deep purple with blue waveform",
    colors = {
      waveform = 0x5A80B0FF,
      waveform_inactive = 0x3A5578FF,
      waveform_bg = 0x181620FF,
      centerline = 0x282630FF,
      markers = 0x8866BBFF,
      markers_hover = 0x9876CBFF,
      border = 0x6A5A90FF,
      playhead = 0x8866BBFF,
      grid_bar = 0x302E38FF,
      grid_beat = 0x222028FF,
      ruler_bg = 0x201E28FF,
      ruler_text = 0x888090FF,
      ruler_tick = 0x605868FF,
      info_bar_bg = 0x1A181EFF,
      info_bar_text = 0xB0A8C0FF,
      info_bar_icon = 0x8866BBFF,
      btn_on = 0x8866BBFF,
      btn_off = 0x403848FF,
      btn_hover = 0x9876CBFF,
      btn_text = 0xFFFFFFFF,
    }
  },
  {
    id = "custom",
    name = "Custom",
    description = "Your own color palette",
    colors = {
      -- Initialized as copy of Default; overridden from ExtState on load
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
      btn_text = 0xFFFFFFFF,
    }
  },
}

-- Number of built-in themes (everything before user-saved themes)
settings.BUILTIN_THEME_COUNT = #settings.THEMES

-- Default toggle defaults (initial visibility when selecting items)
settings.DEFAULT_DEFAULTS = {
  show_cue_markers = true,
  show_ghost_markers = true,
  auto_show_envelopes = true,
  envelope_lock = false,
  env_snap_enabled = true,
}

-- Default layout visibility (which UI panels are shown)
settings.DEFAULT_LAYOUT = {
  show_controls = true,   -- gain/pan/pitch panel
  show_fx = true,         -- FX toolbar + list
  show_warp = true,       -- WARP button + dropdowns + Clear
  show_buttons = true,    -- x2, /2, reverse, edit, loop
  shaped_waveform = false, -- waveform follows fades, volume/pan envelopes
}

-- Dirty flag: when true, config.refresh_colors() will run next frame
settings.colors_dirty = true  -- Start dirty so initial load applies colors

-- Current settings (loaded from ExtState or defaults)
settings.current = {
  theme_id = "default",
  shortcuts = {},
  toolbar_buttons = {},  -- {label, cmd} entries for custom info bar buttons
  defaults = {},         -- toggle defaults (loaded from DEFAULT_DEFAULTS)
  layout = {},           -- layout visibility (loaded from DEFAULT_LAYOUT)
}

-- Save custom theme colors to ExtState
function settings.save_custom_colors(colors)
  for _, key in ipairs(COLOR_KEYS) do
    if colors[key] then
      reaper.SetExtState(EXT_SECTION, "custom_color_" .. key, tostring(colors[key]), true)
    end
  end
end

-- Load custom theme colors from ExtState
function settings.load_custom_colors()
  local colors = {}
  for _, key in ipairs(COLOR_KEYS) do
    local val = reaper.GetExtState(EXT_SECTION, "custom_color_" .. key)
    if val ~= "" then colors[key] = tonumber(val) end
  end
  return colors
end

-- Save a user theme to ExtState and insert into THEMES (before Custom)
function settings.save_user_theme(name, colors)
  local id = "user_" .. tostring(os.time()) .. "_" .. math.random(1000, 9999)
  local theme = {
    id = id,
    name = name,
    description = "Custom",
    colors = {},
    user_theme = true,  -- flag to distinguish from built-in themes
  }
  for _, key in ipairs(COLOR_KEYS) do
    theme.colors[key] = colors[key]
  end
  -- Insert before Custom (last built-in theme)
  local insert_pos = 1  -- top of list, after we find the right spot
  -- Find first built-in theme position (insert user themes at the top)
  table.insert(settings.THEMES, insert_pos, theme)
  -- Persist: save list of user theme IDs + their data
  settings._save_all_user_themes()
  return id
end

-- Delete a user theme by ID
function settings.delete_user_theme(id)
  for i, theme in ipairs(settings.THEMES) do
    if theme.id == id and theme.user_theme then
      table.remove(settings.THEMES, i)
      break
    end
  end
  settings._save_all_user_themes()
end

-- Persist all user themes to ExtState
function settings._save_all_user_themes()
  local user_themes = {}
  for _, theme in ipairs(settings.THEMES) do
    if theme.user_theme then
      user_themes[#user_themes + 1] = theme
    end
  end
  reaper.SetExtState(EXT_SECTION, "user_theme_count", tostring(#user_themes), true)
  for i, theme in ipairs(user_themes) do
    local prefix = "user_theme_" .. i .. "_"
    reaper.SetExtState(EXT_SECTION, prefix .. "id", theme.id, true)
    reaper.SetExtState(EXT_SECTION, prefix .. "name", theme.name, true)
    for _, key in ipairs(COLOR_KEYS) do
      reaper.SetExtState(EXT_SECTION, prefix .. key, tostring(theme.colors[key] or 0), true)
    end
  end
  -- Clean up stale entries beyond current count
  local i = #user_themes + 1
  while true do
    local prefix = "user_theme_" .. i .. "_"
    local old_id = reaper.GetExtState(EXT_SECTION, prefix .. "id")
    if old_id == "" then break end
    reaper.DeleteExtState(EXT_SECTION, prefix .. "id", true)
    reaper.DeleteExtState(EXT_SECTION, prefix .. "name", true)
    for _, key in ipairs(COLOR_KEYS) do
      reaper.DeleteExtState(EXT_SECTION, prefix .. key, true)
    end
    i = i + 1
  end
end

-- Load user themes from ExtState (called during settings.load)
function settings._load_user_themes()
  local count_str = reaper.GetExtState(EXT_SECTION, "user_theme_count")
  local count = tonumber(count_str) or 0
  for i = 1, count do
    local prefix = "user_theme_" .. i .. "_"
    local id = reaper.GetExtState(EXT_SECTION, prefix .. "id")
    local name = reaper.GetExtState(EXT_SECTION, prefix .. "name")
    if id ~= "" and name ~= "" then
      local colors = {}
      for _, key in ipairs(COLOR_KEYS) do
        local val = reaper.GetExtState(EXT_SECTION, prefix .. key)
        if val ~= "" then colors[key] = tonumber(val) end
      end
      local theme = {
        id = id,
        name = name,
        description = "Custom",
        colors = colors,
        user_theme = true,
      }
      -- Insert at position i (user themes go at the top)
      table.insert(settings.THEMES, i, theme)
    end
  end
end

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
  if shortcut.key == "" then return "" end
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
  -- Load user-saved themes (inserts at top of THEMES list)
  settings._load_user_themes()

  -- Load theme
  local theme_id = reaper.GetExtState(EXT_SECTION, "theme")
  if theme_id and theme_id ~= "" then
    settings.current.theme_id = theme_id
  else
    settings.current.theme_id = "default"
  end

  -- Load custom theme colors from ExtState if saved
  local custom_colors = settings.load_custom_colors()
  local custom_theme = settings.get_theme("custom")
  if custom_theme then
    for key, val in pairs(custom_colors) do
      custom_theme.colors[key] = val
    end
  end

  -- One-time migration: clear stale saved shortcuts whose defaults changed
  local MIGRATIONS = {
    {key = "shortcut_toggle_mute", old = "M"},           -- was M, now Num0
    {key = "shortcut_toggle_cue_markers", old = "T"},     -- was T, now M
    {key = "shortcut_open_editor", old = "E"},             -- was E, now Ctrl+Alt+E
  }
  for _, m in ipairs(MIGRATIONS) do
    local saved = reaper.GetExtState(EXT_SECTION, m.key)
    if saved == m.old then
      reaper.DeleteExtState(EXT_SECTION, m.key, true)
    end
  end

  -- Load toolbar buttons
  settings.load_toolbar()

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

  -- Load toggle defaults
  settings.current.defaults = {}
  for name, default_val in pairs(settings.DEFAULT_DEFAULTS) do
    local saved = reaper.GetExtState(EXT_SECTION, "default_" .. name)
    if saved ~= "" then
      settings.current.defaults[name] = (saved == "true")
    else
      settings.current.defaults[name] = default_val
    end
  end

  -- Load layout visibility
  settings.current.layout = {}
  for name, default_val in pairs(settings.DEFAULT_LAYOUT) do
    local saved = reaper.GetExtState(EXT_SECTION, "layout_" .. name)
    if saved ~= "" then
      settings.current.layout[name] = (saved == "true")
    else
      settings.current.layout[name] = default_val
    end
  end
end

-- Save a single default toggle to ExtState (avoids full save overhead)
function settings.save_default(name)
  reaper.SetExtState(EXT_SECTION, "default_" .. name, tostring(settings.current.defaults[name]), true)
end

-- Save a single layout toggle to ExtState (avoids full save overhead)
function settings.save_layout(name)
  reaper.SetExtState(EXT_SECTION, "layout_" .. name, tostring(settings.current.layout[name]), true)
end

-- Save settings to ExtState
function settings.save()
  -- Save theme
  reaper.SetExtState(EXT_SECTION, "theme", settings.current.theme_id, true)

  -- Save shortcuts
  for name, shortcut in pairs(settings.current.shortcuts) do
    reaper.SetExtState(EXT_SECTION, "shortcut_" .. name, shortcut_to_string(shortcut), true)
  end

  -- Save toolbar buttons
  settings.save_toolbar()

  -- Save toggle defaults
  for name, val in pairs(settings.current.defaults) do
    reaper.SetExtState(EXT_SECTION, "default_" .. name, tostring(val), true)
  end

  -- Save layout visibility
  for name, val in pairs(settings.current.layout) do
    reaper.SetExtState(EXT_SECTION, "layout_" .. name, tostring(val), true)
  end
end

-- Apply settings (update current and save)
function settings.apply(new_settings)
  settings.current.theme_id = new_settings.theme_id
  settings.current.shortcuts = new_settings.shortcuts
  if new_settings.defaults then
    settings.current.defaults = new_settings.defaults
  end
  if new_settings.layout then
    settings.current.layout = new_settings.layout
  end
  settings.colors_dirty = true
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
  -- Reset toggle defaults
  settings.current.defaults = {}
  for name, default_val in pairs(settings.DEFAULT_DEFAULTS) do
    settings.current.defaults[name] = default_val
  end
  -- Reset layout visibility
  settings.current.layout = {}
  for name, default_val in pairs(settings.DEFAULT_LAYOUT) do
    settings.current.layout[name] = default_val
  end
  settings.colors_dirty = true
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
  if shortcut.key == "" then return "" end
  local parts = {}
  if shortcut.ctrl then table.insert(parts, "Ctrl") end
  if shortcut.shift then table.insert(parts, "Shift") end
  if shortcut.alt then table.insert(parts, "Alt") end
  table.insert(parts, shortcut.key)
  return table.concat(parts, "+")
end

-- Format shortcut by name (looks up from current settings)
function settings.format_shortcut_by_name(name)
  local sc = settings.current.shortcuts[name]
  if sc and sc.key ~= "" then return settings.format_shortcut(sc) end
  return ""
end

-- Mouse button index map (ImGui button indices: 3=X2/Mouse5, 4=X1/Mouse4 on this hardware)
local MOUSE_BUTTON_MAP = { Mouse4 = 4, Mouse5 = 3 }

-- Check if a shortcut matches current key state
function settings.check_shortcut(ctx, name)
  if settings.listening then return false end
  local shortcut = settings.current.shortcuts[name]
  if not shortcut or shortcut.key == "" then return false end

  -- Resolve modifier constants once (they never change)
  if not MOD_CTRL then
    MOD_CTRL = reaper.ImGui_Mod_Ctrl()
    MOD_SHIFT = reaper.ImGui_Mod_Shift()
    MOD_ALT = reaper.ImGui_Mod_Alt()
  end

  -- Early-exit on modifier mismatch before checking key (cheapest checks first)
  if reaper.ImGui_IsKeyDown(ctx, MOD_CTRL) ~= shortcut.ctrl then return false end
  if reaper.ImGui_IsKeyDown(ctx, MOD_SHIFT) ~= shortcut.shift then return false end
  if reaper.ImGui_IsKeyDown(ctx, MOD_ALT) ~= shortcut.alt then return false end

  -- Mouse buttons use IsMouseClicked instead of IsKeyPressed
  local mouse_btn = MOUSE_BUTTON_MAP[shortcut.key]
  if mouse_btn then
    return reaper.ImGui_IsMouseClicked(ctx, mouse_btn)
  end

  local imgui_key = get_imgui_key(shortcut.key)
  if not imgui_key then return false end

  return reaper.ImGui_IsKeyPressed(ctx, imgui_key)
end

-- Scan REAPER's toolbar_icons directory for available icon PNGs
function settings.scan_toolbar_icons()
  local dir = reaper.GetResourcePath() .. "/Data/toolbar_icons/"
  local icons = {}
  local i = 0
  while true do
    local file = reaper.EnumerateFiles(dir, i)
    if not file then break end
    if file:lower():match("%.png$") then
      icons[#icons + 1] = file
    end
    i = i + 1
  end
  table.sort(icons)
  return icons
end

-- Load toolbar buttons from ExtState
function settings.load_toolbar()
  settings.current.toolbar_buttons = {}
  -- New format: single serialized key
  local data = reaper.GetExtState(EXT_SECTION, "toolbar_data")
  if data ~= "" then
    for line in data:gmatch("[^\n]+") do
      if line == "S" then
        settings.current.toolbar_buttons[#settings.current.toolbar_buttons + 1] = {type = "separator"}
      elseif line:sub(1, 2) == "B\t" then
        local fields = {}
        for f in (line:sub(3) .. "\t"):gmatch("(.-)\t") do fields[#fields + 1] = f end
        local label = fields[1] or ""
        local cmd = fields[2] or ""
        local icon = fields[3]
        if label ~= "" and cmd ~= "" then
          settings.current.toolbar_buttons[#settings.current.toolbar_buttons + 1] = {
            label = label, cmd = cmd, icon = (icon and icon ~= "") and icon or nil
          }
        end
      end
    end
    return
  end
  -- Legacy format: per-item keys (migrate on first save)
  local count = tonumber(reaper.GetExtState(EXT_SECTION, "toolbar_count")) or 0
  if count > 0 then
    for i = 1, count do
      local item_type = reaper.GetExtState(EXT_SECTION, "toolbar_" .. i .. "_type")
      if item_type == "separator" then
        settings.current.toolbar_buttons[#settings.current.toolbar_buttons + 1] = {type = "separator"}
      else
        local label = reaper.GetExtState(EXT_SECTION, "toolbar_" .. i .. "_label")
        local cmd = reaper.GetExtState(EXT_SECTION, "toolbar_" .. i .. "_cmd")
        local icon = reaper.GetExtState(EXT_SECTION, "toolbar_" .. i .. "_icon")
        if label ~= "" and cmd ~= "" then
          settings.current.toolbar_buttons[#settings.current.toolbar_buttons + 1] = {
            label = label, cmd = cmd, icon = (icon and icon ~= "") and icon or nil
          }
        end
      end
    end
    -- Migrate: save in new format and clean up old keys
    settings.save_toolbar()
    reaper.DeleteExtState(EXT_SECTION, "toolbar_count", true)
    for i = 1, count + 5 do
      reaper.DeleteExtState(EXT_SECTION, "toolbar_" .. i .. "_label", true)
      reaper.DeleteExtState(EXT_SECTION, "toolbar_" .. i .. "_cmd", true)
      reaper.DeleteExtState(EXT_SECTION, "toolbar_" .. i .. "_icon", true)
      reaper.DeleteExtState(EXT_SECTION, "toolbar_" .. i .. "_type", true)
    end
    return
  end
  -- No saved data at all: add a default button so users discover the toolbar
  settings.current.toolbar_buttons = {
    {label = "Item properties", cmd = "40009"},
  }
end

-- Save toolbar to a single ExtState key (tab-delimited, one item per line)
function settings.save_toolbar()
  local btns = settings.current.toolbar_buttons or {}
  local lines = {}
  for i, btn in ipairs(btns) do
    if btn.type == "separator" then
      lines[i] = "S"
    else
      lines[i] = "B\t" .. (btn.label or "") .. "\t" .. (btn.cmd or "") .. "\t" .. (btn.icon or "")
    end
  end
  reaper.SetExtState(EXT_SECTION, "toolbar_data", table.concat(lines, "\n"), true)
end

-- Toolbar undo/redo stack
local tb_undo_stack = {}
local tb_redo_stack = {}
local TB_UNDO_MAX = 30

local function tb_deep_copy(btns)
  local copy = {}
  for i, btn in ipairs(btns) do
    copy[i] = {type = btn.type, label = btn.label, cmd = btn.cmd, icon = btn.icon}
  end
  return copy
end

local function tb_push_undo()
  tb_undo_stack[#tb_undo_stack + 1] = tb_deep_copy(settings.current.toolbar_buttons)
  if #tb_undo_stack > TB_UNDO_MAX then table.remove(tb_undo_stack, 1) end
  tb_redo_stack = {}
end

function settings.toolbar_undo()
  if #tb_undo_stack == 0 then return false end
  tb_redo_stack[#tb_redo_stack + 1] = tb_deep_copy(settings.current.toolbar_buttons)
  settings.current.toolbar_buttons = table.remove(tb_undo_stack)
  settings.save_toolbar()
  return true
end

function settings.toolbar_redo()
  if #tb_redo_stack == 0 then return false end
  tb_undo_stack[#tb_undo_stack + 1] = tb_deep_copy(settings.current.toolbar_buttons)
  settings.current.toolbar_buttons = table.remove(tb_redo_stack)
  settings.save_toolbar()
  return true
end

function settings.toolbar_can_undo() return #tb_undo_stack > 0 end
function settings.toolbar_can_redo() return #tb_redo_stack > 0 end

-- Add a toolbar button (after_idx: insert after this index, nil = append)
function settings.add_toolbar_button(label, cmd, icon, after_idx)
  tb_push_undo()
  local btns = settings.current.toolbar_buttons
  local entry = {label = label, cmd = cmd, icon = icon or nil}
  if after_idx and after_idx >= 1 and after_idx <= #btns then
    table.insert(btns, after_idx + 1, entry)
  else
    btns[#btns + 1] = entry
  end
  settings.save_toolbar()
end

-- Add a toolbar separator (after_idx: insert after this index, nil = append)
function settings.add_toolbar_separator(after_idx)
  tb_push_undo()
  local btns = settings.current.toolbar_buttons
  local entry = {type = "separator"}
  if after_idx and after_idx >= 1 and after_idx <= #btns then
    table.insert(btns, after_idx + 1, entry)
  else
    btns[#btns + 1] = entry
  end
  settings.save_toolbar()
end

-- Remove a toolbar button by index
function settings.remove_toolbar_button(index)
  tb_push_undo()
  table.remove(settings.current.toolbar_buttons, index)
  settings.save_toolbar()
end

-- Move a toolbar button from one index to another
function settings.move_toolbar_button(from, to)
  tb_push_undo()
  local btns = settings.current.toolbar_buttons
  if from < 1 or from > #btns or to < 1 or to > #btns then return end
  local btn = table.remove(btns, from)
  table.insert(btns, to, btn)
  settings.save_toolbar()
end

return settings
