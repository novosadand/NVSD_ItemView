# NVSD_ItemView - Development Documentation

## Project Overview

NVSD_ItemView is a REAPER script that provides an Ableton-style clip view for audio items. It displays a waveform visualization of the source audio with draggable markers to control which portion of the audio the item plays.

**For user documentation, see [README.md](README.md)**
**For Gumroad listing, see [GUMROAD_DESCRIPTION.md](GUMROAD_DESCRIPTION.md)**

---

## Task Management

**IMPORTANT: The todo list is ALWAYS in this file (CLAUDE.md). When user says "add to todo", add it here.**

### Current Todo List
(empty)

### Completed Features
All planned features implemented. See README.md for full feature list.

---

## Development Workflow

**IMPORTANT: Always run tests then sync after making changes.**

- **Dev folder (WSL)**: `~/dev/NVSD_ItemView/`
- **Windows folder**: `D:\production\# BOUGHT & FREE soft\Reaper\NVSD_ItemView\`

```bash
# ALWAYS run after making changes (tests + sync):
cd ~/dev/NVSD_ItemView && lua5.4 tests/run_tests.lua && ./sync.sh
```

---

## Architecture Overview

### File Structure
```
NVSD_ItemView/
├── NVSD_ItemView.lua          # Main script (≈2560 lines)
├── README.md                   # User documentation
├── GUMROAD_DESCRIPTION.md      # Sales copy for Gumroad
├── CLAUDE.md                   # Development documentation (this file)
├── sync.sh                     # Sync script (WSL → Windows)
├── docs/
│   ├── REAPER_WAVEFORM_RENDERING.md   # PCM_Source_GetPeaks reference
│   └── REAPER_TIMELINE_GRID.md        # Timeline/tempo API reference
└── tests/
    ├── luaunit.lua             # LuaUnit testing framework
    ├── run_tests.lua           # Test runner
    └── nvsd_itemview_test.lua  # 68 unit tests
```

### Code Organization (NVSD_ItemView.lua)

| Section | Lines | Description |
|---------|-------|-------------|
| Header & Config | 1-60 | Constants, colors, dimensions |
| State Variables | 61-185 | Drag states, zoom, pan, caching |
| Utility Functions | 186-470 | Math helpers, conversions, formatting |
| Drawing Functions | 471-1000 | Ruler, waveform, markers, overlays |
| Control Panels | 1001-1600 | Buttons, gain slider, pitch knob |
| Main Loop | 1601-2560 | Input handling, item detection, rendering |

### Key Abstractions

**Unified Drag Control System** (lines 117-181)
```lua
drag_controls = {
  gain = { active, start_y, start_value, shift_held },
  pitch = { ... },
  semitones = { ... },
  cents = { ... },
}
start_drag(name, mouse_y, value, track_shift)
end_drag(name)
is_dragging(name)
get_drag_delta(ctx, name, mouse_y, current_value, fine_sensitivity)
```

**Peak Caching System**
- `cached_peaks` - Waveform data for current source
- `cached_source` - Source pointer for cache invalidation
- `cached_num_samples` - Resolution for zoom-dependent refresh

**View Coordinate System**
- `view_start` - Left edge of view in source time
- `view_length` - Duration visible in view
- `zoom_level` - 1.0 = fit all, >1 = zoomed in
- `pan_offset` - Horizontal scroll in source time units

---

## Testing

### Running Tests
```bash
cd ~/dev/NVSD_ItemView && lua5.4 tests/run_tests.lua
```

### Test Coverage (68 tests)
- Gain/dB conversions
- Pitch/semitones/cents conversions
- Slider position calculations
- Time format functions
- Peak buffer parsing
- View calculations
- UI element bounds
- Edge cases

### Adding Tests
1. Add test functions to `tests/nvsd_itemview_test.lua`
2. Prefix with `test_` for auto-discovery
3. Use LuaUnit assertions: `lu.assertEquals()`, `lu.assertAlmostEquals()`

---

## Key REAPER APIs Used

### Item & Take
```lua
reaper.GetSelectedMediaItem(0, index)
reaper.GetActiveTake(item)
reaper.GetMediaItemTake_Source(take)
reaper.GetMediaItemInfo_Value(item, "D_LENGTH" | "D_POSITION" | "D_VOL" | "B_MUTE")
reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS" | "D_PLAYRATE" | "D_PITCH")
reaper.SetMediaItemInfo_Value(item, param, value)
reaper.SetMediaItemTakeInfo_Value(take, param, value)
```

### Waveform
```lua
reaper.PCM_Source_GetPeaks(source, peakrate, starttime, numchannels, numsamples, want_extra, buf)
reaper.GetMediaSourceLength(source)
reaper.GetMediaSourceSampleRate(source)
reaper.GetMediaSourceNumChannels(source)
```

### Timeline
```lua
reaper.TimeMap2_timeToBeats(proj, time) → beats, measures, ...
reaper.TimeMap2_beatsToTime(proj, beats, measures)
reaper.GetProjectTimeSignature2(proj, time) → bpm, bpi
```

### ReaImGui
```lua
reaper.ImGui_CreateContext(name)
reaper.ImGui_Begin(ctx, title, open, flags)
reaper.ImGui_GetWindowDrawList(ctx)
reaper.ImGui_DrawList_AddRectFilled(...)
reaper.ImGui_DrawList_AddLine(...)
reaper.ImGui_IsMouseClicked(ctx, button)
reaper.ImGui_GetMousePos(ctx)
```

### SWS/JS Extensions (Optional)
```lua
reaper.BR_GetMediaSourceProperties(take) → retval, section, start, length, fade, reverse
reaper.JS_Mouse_GetState(flags) → bitmask
reaper.JS_Mouse_SetPosition(x, y)
```

---

## Common Patterns

### Undo Points
```lua
-- For instant actions:
reaper.Undo_BeginBlock()
-- ... make changes ...
reaper.Undo_EndBlock("Description", -1)

-- For drag operations (deferred scripts):
undo_block_open = "operation_name"
-- ... on mouse release ...
reaper.Undo_OnStateChangeEx(message, -1, -1)
undo_block_open = nil
```

### Coordinate Conversion
```lua
-- Source time ↔ Project time
local function source_to_project_time(source_t, item_position, start_offset, playrate)
  return item_position + (source_t - start_offset) / playrate
end

-- Source time ↔ Pixel position
local function time_to_px(t)
  return wave_x + ((t - view_start) / view_length) * waveform_width
end
```

### Mouse State Detection
```lua
-- Use bitwise AND for bitmask (includes modifier keys)
local mouse_state = reaper.JS_Mouse_GetState(1)
if (mouse_state & 1) ~= 0 then  -- Left button pressed
  ...
end
```

---

## Performance Considerations

1. **Peak Caching** - Only refetch when source/zoom changes
2. **Lazy Validation** - Check sticky_item validity by iterating project items
3. **Draw Culling** - Skip markers/elements outside visible view
4. **Buffer Reuse** - Single reaper.array for peak fetching

---

## Debugging Tips

1. **Auto-reload** - Save script to trigger reload without restarting REAPER
2. **Console output** - Use `reaper.ShowConsoleMsg()` for debugging
3. **Test isolation** - Tests run outside REAPER with mocked API

---

## Technology Stack

| Component | Technology |
|-----------|------------|
| Language | Lua 5.4 |
| GUI | ReaImGui |
| Target | REAPER 6.0+ |
| Testing | LuaUnit |
| Optional | SWS Extension, js_ReaScriptAPI |

---

## Contributing Guidelines

1. Write tests before implementing features
2. Run full test suite before committing
3. Keep functions small and focused
4. Document complex algorithms in comments
5. Update README.md for user-facing changes
