-- NVSD_ItemView - Configuration Module
-- Constants, colors, and dimensions

local config = {}

-- Settings reference (set by main script)
config.settings = nil

-- Layout dimensions
config.MARKER_WIDTH = 12
config.WINDOW_PADDING = 2
config.WAVEFORM_MARGIN_H = 12
config.WAVEFORM_MARGIN_V = 2
config.COLOR_STRIP_HEIGHT = 4
config.INFO_BAR_HEIGHT = 18
config.INFO_BAR_HEIGHT_BASE = 18      -- no toolbar buttons
config.INFO_BAR_HEIGHT_TOOLBAR = 36   -- with toolbar buttons (fits 30px REAPER icons)
config.TOOLBAR_BTN_GAP = 4
config.RULER_HEIGHT = 20
config.TIME_RULER_HEIGHT = 18
config.SNAP_THRESHOLD_PX = 25
config.FADE_HANDLE_SIZE = 7
config.FADE_HANDLE_THRESHOLD = 14  -- hit detection radius in px
config.LEFT_PANEL_WIDTH = 70
config.LEFT_COLUMN_WIDTH = 145
config.FX_COLUMN_WIDTH = 140
config.GAIN_SLIDER_WIDTH = 16

-- Warp bar (stretch markers / transient detection)
config.WARP_BAR_HEIGHT = 18
config.WARP_MARKER_HIT_RADIUS = 8
config.WARP_DRAG_THRESHOLD = 4

config.COLOR_WARP_MARKER = 0xE8A020FF
config.COLOR_WARP_MARKER_HOVER = 0xFFBB44FF
config.COLOR_WARP_MARKER_LINE = 0xE8A02055
config.COLOR_WARP_MARKER_LINE_HOVER = 0xE8A02088
config.COLOR_TRANSIENT = 0x88888899
config.COLOR_TRANSIENT_HOVER = 0xBBBBBBCC
config.COLOR_WARP_MARKER_GHOST = 0x88888888
config.COLOR_WARP_MARKER_LINE_GHOST = 0x88888833
config.COLOR_WARP_MARKER_SELECTED = 0x66CCCCFF
config.COLOR_WARP_BAR_BG = 0x1E1E1EFF
config.COLOR_WARP_BAR_BORDER = 0x333333FF

-- Loop boundary marker color (vertical line at source_length intervals)
config.COLOR_LOOP_REGION = 0xFFAA3360

-- Envelope editor
config.ENVELOPE_BAR_HEIGHT = 18
config.COLOR_ENV_LINE = 0x66CCCCFF
config.COLOR_ENV_LINE_DASHED = 0x66CCCC99
config.COLOR_ENV_FILL = 0x66CCCC20
config.COLOR_ENV_NODE = 0xFFFFFFFF
config.COLOR_ENV_NODE_HOVER = 0x66CCFFFF
config.COLOR_ENV_NODE_BORDER = 0x66CCCCFF
config.COLOR_ENV_TOOLTIP_BG = 0x333333EE
config.COLOR_ENV_TOOLTIP_TEXT = 0xFFFFFFFF
config.COLOR_ENV_PREVIEW_NODE = 0xFFFFFF88
config.COLOR_ENV_GRID = 0xFFFFFF12          -- subtle semitone grid lines
config.COLOR_ENV_GRID_OCTAVE = 0xFFFFFF22    -- brighter for octave lines (+/-12, +/-24)
config.COLOR_ENV_GRID_CENTER = 0xFFFFFF44    -- brightest for center (0 st)
config.COLOR_ENV_GRID_LABEL = 0xFFFFFF66     -- semitone label text
config.COLOR_ENV_LINE_HOVER = 0xAAEEEEFF    -- brighter teal for hovered segment
config.PITCH_LABEL_WIDTH = 30               -- left gutter width for pitch semitone labels
-- Per-type envelope colors
config.ENV_COLORS = {
  Volume = {
    line       = 0x66CCCCFF,
    line_dash  = 0x66CCCC99,
    fill       = 0x66CCCC20,
    node_hover = 0x66CCFFFF,
    node_border= 0x66CCCCFF,
    line_hover = 0xAAEEEEFF,
    preview    = 0xFFFFFF88,
  },
  Pitch = {
    line       = 0x5B8BE0FF,
    line_dash  = 0x5B8BE099,
    fill       = 0x5B8BE020,
    node_hover = 0x7BABF0FF,
    node_border= 0x5B8BE0FF,
    line_hover = 0x9BCBFFFF,
    preview    = 0xFFFFFF88,
  },
  Pan = {
    line       = 0xCC8844FF,
    line_dash  = 0xCC884499,
    fill       = 0xCC884420,
    node_hover = 0xEEAA66FF,
    node_border= 0xCC8844FF,
    line_hover = 0xFFCC88FF,
    preview    = 0xFFFFFF88,
  },
}

config.COLOR_ENV_NODE_SELECTED = 0xFFDD44FF       -- bright yellow fill for selected nodes
config.COLOR_ENV_SEL_RECT_FILL = 0x4488FF20        -- semi-transparent blue rect fill
config.COLOR_ENV_SEL_RECT_BORDER = 0x6699FFAA      -- selection rect border

config.ENV_NODE_RADIUS = 4
config.ENV_NODE_HIT_RADIUS = 8
config.ENV_LINE_THICKNESS = 2.0
config.ENV_DASH_LENGTH = 6
config.ENV_DASH_GAP = 4

-- Pitch constants
config.PITCH_KNOB_RADIUS = 16
config.PITCH_MIN = -48
config.PITCH_MAX = 48
config.PITCH_FULL_RANGE = 48       -- visible window size (always 48 semitones)
config.PITCH_MAX_SEMITONES = 48    -- absolute max semitone value
config.PITCH_SCROLL_SPEED = 4     -- semitones per mousewheel tick
config.PITCH_AUTO_SCROLL_EDGE = 30    -- pixels from edge where auto-scroll kicks in
config.PITCH_AUTO_SCROLL_RATE = 0.5   -- semitones per frame at edge (scales linearly to edge)

-- Region selection overlay
config.COLOR_SELECTION = 0x66AAFF30        -- semi-transparent blue overlay
config.COLOR_SELECTION_EDGE = 0x66AAFFAA   -- selection edge lines

-- WAV cue markers
config.COLOR_CUE_MARKER = 0x88AABBAA      -- semi-transparent dashed lines
config.COLOR_CUE_MARKER_TEXT = 0xBBCCDDFF  -- label text
config.COLOR_CUE_MARKER_BG = 0x222222DD    -- dark background behind labels

-- Default colors (0xRRGGBBAA format)
local DEFAULT_COLORS = {
  waveform = 0x5A9F5AFF,
  waveform_inactive = 0x3A6A3AFF,
  waveform_bg = 0x1A1A1AFF,
  centerline = 0x2A2A2AFF,
  markers = 0x4A90D9FF,
  markers_hover = 0x6AB0F9FF,
  border = 0x4A7A4AFF,
  ruler_bg = 0x252525FF,
  ruler_text = 0x888888FF,
  ruler_tick = 0x666666FF,
  grid_bar = 0x383838FF,
  grid_beat = 0x2E2E2EFF,
  playhead = 0x00CC00FF,
  info_bar_bg = 0x1E1E1EFF,
  info_bar_text = 0xBBBBBBFF,
  info_bar_icon = 0x5A9F5AFF,
  btn_on = 0x4A90D9FF,
  btn_off = 0x404040FF,
  btn_hover = 0x5AA0E9FF,
  btn_text = 0xFFFFFFFF,
}

-- Color properties (updated by refresh_colors)
config.COLOR_WAVEFORM = DEFAULT_COLORS.waveform
config.COLOR_WAVEFORM_INACTIVE = DEFAULT_COLORS.waveform_inactive
config.COLOR_WAVEFORM_BG = DEFAULT_COLORS.waveform_bg
config.COLOR_CENTERLINE = DEFAULT_COLORS.centerline
config.COLOR_MARKER = DEFAULT_COLORS.markers
config.COLOR_MARKER_HOVER = DEFAULT_COLORS.markers_hover
config.COLOR_BORDER = DEFAULT_COLORS.border
config.COLOR_RULER_BG = DEFAULT_COLORS.ruler_bg
config.COLOR_RULER_TEXT = DEFAULT_COLORS.ruler_text
config.COLOR_RULER_TICK = DEFAULT_COLORS.ruler_tick
config.COLOR_GRID_BAR = DEFAULT_COLORS.grid_bar
config.COLOR_GRID_BEAT = DEFAULT_COLORS.grid_beat
config.COLOR_PLAYHEAD = DEFAULT_COLORS.playhead
config.COLOR_INFO_BAR_BG = DEFAULT_COLORS.info_bar_bg
config.COLOR_INFO_BAR_TEXT = DEFAULT_COLORS.info_bar_text
config.COLOR_INFO_BAR_ICON = DEFAULT_COLORS.info_bar_icon
config.COLOR_BTN_ON = DEFAULT_COLORS.btn_on
config.COLOR_BTN_OFF = DEFAULT_COLORS.btn_off
config.COLOR_BTN_HOVER = DEFAULT_COLORS.btn_hover
config.COLOR_BTN_TEXT = DEFAULT_COLORS.btn_text

-- Refresh colors from settings (call this when settings change)
function config.refresh_colors()
  local colors = DEFAULT_COLORS
  if config.settings then
    colors = config.settings.get_colors()
  end

  config.COLOR_WAVEFORM = colors.waveform or DEFAULT_COLORS.waveform
  config.COLOR_WAVEFORM_INACTIVE = colors.waveform_inactive or DEFAULT_COLORS.waveform_inactive
  config.COLOR_WAVEFORM_BG = colors.waveform_bg or DEFAULT_COLORS.waveform_bg
  config.COLOR_CENTERLINE = colors.centerline or DEFAULT_COLORS.centerline
  config.COLOR_MARKER = colors.markers or DEFAULT_COLORS.markers
  config.COLOR_MARKER_HOVER = colors.markers_hover or DEFAULT_COLORS.markers_hover
  config.COLOR_BORDER = colors.border or DEFAULT_COLORS.border
  config.COLOR_RULER_BG = colors.ruler_bg or DEFAULT_COLORS.ruler_bg
  config.COLOR_RULER_TEXT = colors.ruler_text or DEFAULT_COLORS.ruler_text
  config.COLOR_RULER_TICK = colors.ruler_tick or DEFAULT_COLORS.ruler_tick
  config.COLOR_GRID_BAR = colors.grid_bar or DEFAULT_COLORS.grid_bar
  config.COLOR_GRID_BEAT = colors.grid_beat or DEFAULT_COLORS.grid_beat
  config.COLOR_PLAYHEAD = colors.playhead or DEFAULT_COLORS.playhead
  config.COLOR_INFO_BAR_BG = colors.info_bar_bg or DEFAULT_COLORS.info_bar_bg
  config.COLOR_INFO_BAR_TEXT = colors.info_bar_text or DEFAULT_COLORS.info_bar_text
  config.COLOR_INFO_BAR_ICON = colors.info_bar_icon or DEFAULT_COLORS.info_bar_icon
  config.COLOR_BTN_ON = colors.btn_on or DEFAULT_COLORS.btn_on
  config.COLOR_BTN_OFF = colors.btn_off or DEFAULT_COLORS.btn_off
  config.COLOR_BTN_HOVER = colors.btn_hover or DEFAULT_COLORS.btn_hover
  config.COLOR_BTN_TEXT = colors.btn_text or DEFAULT_COLORS.btn_text
end

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
