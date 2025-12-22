# REAPER Timeline and Grid API Reference

Documentation of REAPER API functions for timeline grid, tempo, and bar/beat calculations.

---

## Item Position in Project

### Getting Item Timeline Position

```lua
-- Get item's start position in project timeline (seconds)
local item_position = reaper.GetMediaItemInfo_Value(item, "D_POSITION")

-- Get item's length on timeline (seconds)
local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

-- Item ends at:
local item_end = item_position + item_length
```

---

## Time to Bars/Beats Conversion

### TimeMap2_timeToBeats

Converts project time (seconds) to musical position (bars/beats).

```lua
local retval, measures, cml, fullbeats, cdenom = reaper.TimeMap2_timeToBeats(proj, tpos)
```

**Parameters:**
- `proj` - Project (0 for current project)
- `tpos` - Time position in seconds

**Returns:**
- `retval` - Beats since start of measure
- `measures` - Measure number (0-based, add 1 for display)
- `cml` - Current measure length in beats
- `fullbeats` - Total beats from project start
- `cdenom` - Current denominator (e.g., 4 for 4/4 time)

**Example:**
```lua
local beats, measures, measure_length, total_beats, denom = reaper.TimeMap2_timeToBeats(0, 5.0)
local bar_number = measures + 1  -- Convert 0-based to 1-based for display
```

### TimeMap2_beatsToTime

Converts musical position (bars/beats) to project time (seconds).

```lua
local time = reaper.TimeMap2_beatsToTime(proj, tpos, measuresInOptional)
```

**Parameters:**
- `proj` - Project (0 for current project)
- `tpos` - Beat position (if measuresIn not provided) or beats within measure
- `measuresInOptional` - If provided, tpos is beats within this measure number

**Example - Get time at start of bar 5:**
```lua
-- Method 1: Using measure number (0-based)
local bar5_time = reaper.TimeMap2_beatsToTime(0, 0, 4)  -- Bar 5 = measure index 4

-- Method 2: Calculate beats from start
-- (need to know time signature changes)
```

---

## Tempo and Time Signature

### GetProjectTimeSignature2

Gets the project's tempo and time signature at a specific time.

```lua
local bpm, bpi = reaper.GetProjectTimeSignature2(proj, time)
```

**Parameters:**
- `proj` - Project (0 for current project)
- `time` - Time position in seconds

**Returns:**
- `bpm` - Beats per minute at that time
- `bpi` - Beats per interval (numerator of time signature)

### Master Tempo

```lua
-- Get master tempo
local tempo = reaper.Master_GetTempo()

-- Get tempo at specific time (accounts for tempo changes)
local bpm, bpi = reaper.GetProjectTimeSignature2(0, time_pos)
```

---

## Grid Settings

### GetToggleCommandState

Check if grid is visible:
```lua
local grid_visible = reaper.GetToggleCommandState(40145) == 1  -- View: Toggle grid lines
```

### GetSetProjectGrid

Get/set grid division:
```lua
-- Get grid division
local retval, division, swingmode, swingamt = reaper.GetSetProjectGrid(proj, false)
-- division: 1 = whole note, 0.5 = half, 0.25 = quarter, 0.125 = eighth, etc.
```

---

## Converting Between Source Time and Project Time

When displaying a waveform, we work in "source time" (position within the audio file).
The grid needs to show "project time" (position in the timeline).

### Source Time → Project Time

```lua
-- Given:
-- item_position = where item starts in project
-- start_offset = where in source the item starts playing
-- playrate = speed multiplier (1.0 = normal)

-- For a source time position 'source_t':
local function source_to_project_time(source_t, item_position, start_offset, playrate)
    return item_position + (source_t - start_offset) / playrate
end
```

### Project Time → Source Time

```lua
-- For a project time position 'project_t':
local function project_to_source_time(project_t, item_position, start_offset, playrate)
    return start_offset + (project_t - item_position) * playrate
end
```

### Example: Finding Bar Positions in Source Time

```lua
-- Get the project time range covered by the item
local project_start = item_position
local project_end = item_position + item_length

-- Find first bar within range
local _, start_measure = reaper.TimeMap2_timeToBeats(0, project_start)
local first_bar = math.ceil(start_measure)  -- Round up to next bar

-- Iterate through bars
local bar = first_bar
while true do
    local bar_project_time = reaper.TimeMap2_beatsToTime(0, 0, bar)  -- Time at start of bar
    if bar_project_time > project_end then break end

    -- Convert to source time for drawing
    local bar_source_time = start_offset + (bar_project_time - item_position) * playrate

    -- Draw line at bar_source_time...

    bar = bar + 1
end
```

---

## Beat Subdivision

For drawing beat lines (not just bar lines):

```lua
local bpm, bpi = reaper.GetProjectTimeSignature2(0, project_time)
local beats_per_bar = bpi  -- Usually 4 for 4/4 time

-- Time duration of one beat
local beat_duration = 60 / bpm

-- For each bar, draw beat subdivisions
for beat = 0, beats_per_bar - 1 do
    local beat_time = bar_time + beat * beat_duration
    -- Draw lighter line for beats (vs bars)
end
```

---

## Visual Hierarchy for Grid

Typical grid line styling:
- **Bar lines**: Bright/thick (e.g., 0x888888FF, 2px)
- **Beat lines**: Medium (e.g., 0x444444FF, 1px)
- **Sub-beat lines**: Dim (e.g., 0x222222FF, 1px)

---

## Ruler Bar Display

For displaying bar numbers above the waveform:

```lua
-- Draw ruler background
reaper.ImGui_DrawList_AddRectFilled(draw_list, x, y, x + width, y + ruler_height, COLOR_RULER_BG)

-- Draw bar numbers
for each visible bar do
    local bar_x = time_to_px(bar_source_time)
    local bar_num = bar + 1  -- 1-based display
    reaper.ImGui_DrawList_AddText(draw_list, bar_x + 2, y + 2, COLOR_TEXT, tostring(bar_num))
end
```

---

## Performance Considerations

1. **Cache bar positions** - Only recalculate when item position or tempo changes
2. **Limit visible bars** - Only calculate bars within the visible view range
3. **Skip dense grids** - If grid lines would be < 10px apart, skip subdivisions

---

## References

- [REAPER API - TimeMap2_timeToBeats](https://www.reaper.fm/sdk/reascript/reascripthelp.html#TimeMap2_timeToBeats)
- [REAPER API - TimeMap2_beatsToTime](https://www.reaper.fm/sdk/reascript/reascripthelp.html#TimeMap2_beatsToTime)
- [REAPER API - GetProjectTimeSignature2](https://www.reaper.fm/sdk/reascript/reascripthelp.html#GetProjectTimeSignature2)
