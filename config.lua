-- NVSD_ItemView - Configuration Module
-- Constants, colors, and dimensions

local config = {}

-- Layout dimensions
config.MARKER_WIDTH = 12
config.WINDOW_PADDING = 2
config.WAVEFORM_MARGIN_H = 12
config.WAVEFORM_MARGIN_V = 2
config.INFO_BAR_HEIGHT = 18
config.RULER_HEIGHT = 20
config.TIME_RULER_HEIGHT = 18
config.SNAP_THRESHOLD_PX = 25
config.LEFT_PANEL_WIDTH = 70
config.LEFT_COLUMN_WIDTH = 145
config.GAIN_SLIDER_WIDTH = 16

-- Pitch constants
config.PITCH_KNOB_RADIUS = 16
config.PITCH_MIN = -48
config.PITCH_MAX = 48

-- Colors (0xRRGGBBAA format)
config.COLOR_WAVEFORM = 0x5A9F5AFF
config.COLOR_WAVEFORM_INACTIVE = 0x3A6A3AFF
config.COLOR_WAVEFORM_BG = 0x1A1A1AFF
config.COLOR_CENTERLINE = 0x2A2A2AFF
config.COLOR_MARKER = 0x4A90D9FF
config.COLOR_MARKER_HOVER = 0x6AB0F9FF
config.COLOR_BORDER = 0x4A7A4AFF
config.COLOR_RULER_BG = 0x252525FF
config.COLOR_RULER_TEXT = 0x888888FF
config.COLOR_RULER_TICK = 0x666666FF
config.COLOR_GRID_BAR = 0x383838FF
config.COLOR_GRID_BEAT = 0x282828FF
config.COLOR_PLAYHEAD = 0x00CC00FF
config.COLOR_INFO_BAR_BG = 0x1E1E1EFF
config.COLOR_INFO_BAR_TEXT = 0xBBBBBBFF
config.COLOR_INFO_BAR_ICON = 0x5A9F5AFF

-- Pitch shift mode values (I_PITCHMODE)
config.PITCH_MODES = {
  {name = "Project Default", value = -1},
  {name = "SoundTouch", value = 0},
  {name = "Simple Windowed", value = 131072},
  {name = "Elastique 3 Pro", value = 589824},
  {name = "Elastique 3 Efficient", value = 655360},
  {name = "Elastique 3 Soloist", value = 720896},
  {name = "Elastique 2 Pro", value = 393216},
  {name = "Elastique 2 Efficient", value = 458752},
  {name = "Elastique 2 Soloist", value = 524288},
  {name = "Rubber Band", value = 851968},
}

return config
