# Sausage File Region Navigation — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Navigate between sound regions in sausage files using Left/Right arrow shortcuts, with optional click-to-seek silence snapping.

**Architecture:** Pure silence detection functions in `utils.lua` operate on existing peak data (`peaks.mins`/`peaks.maxs`). Shortcut handlers in the main loop convert between time and peak columns. A preference toggle enables click-in-silence snapping.

**Tech Stack:** Lua 5.4, ReaImGui, REAPER native API

---

### Task 1: Add silence detection and region-finding functions to utils.lua

**Files:**
- Modify: `lib/utils.lua:1307` (before `return utils` on line 1309)
- Test: `tests/nvsd_itemview_test.lua`

**Step 1: Write tests for is_column_silent**

In `tests/nvsd_itemview_test.lua`, after line 1241, add:

```lua
-- Sausage navigation: silence detection
function TestNVSDItemView:test_is_column_silent_all_zero()
  local peaks = {mins = {0, 0}, maxs = {0, 0}, count = 2, channels = 1}
  lu.assertTrue(utils.is_column_silent(peaks, 1))
end

function TestNVSDItemView:test_is_column_silent_has_sound()
  local peaks = {mins = {-0.5, 0}, maxs = {0.5, 0}, count = 2, channels = 1}
  lu.assertFalse(utils.is_column_silent(peaks, 1))
  lu.assertTrue(utils.is_column_silent(peaks, 2))
end

function TestNVSDItemView:test_is_column_silent_stereo()
  -- Flat indexing: col 1 = indices 1,2; col 2 = indices 3,4
  local peaks = {
    mins = {0, 0,  -0.3, 0},
    maxs = {0, 0,   0.3, 0},
    count = 2, channels = 2
  }
  lu.assertTrue(utils.is_column_silent(peaks, 1))
  lu.assertFalse(utils.is_column_silent(peaks, 2))
end

function TestNVSDItemView:test_is_column_silent_stereo_one_channel_nonzero()
  -- col 1: ch1 silent, ch2 has sound → not silent
  local peaks = {
    mins = {0, -0.1},
    maxs = {0,  0.1},
    count = 1, channels = 2
  }
  lu.assertFalse(utils.is_column_silent(peaks, 1))
end
```

**Step 2: Run tests to verify they fail**

Run: `wsl -e bash -c 'cd "/mnt/d/production/# BOUGHT & FREE soft/Reaper/NVSD_ItemView" && lua5.4 tests/run_tests.lua'`
Expected: FAIL — `is_column_silent` not defined

**Step 3: Implement is_column_silent**

In `lib/utils.lua`, before `return utils` (line 1309), add:

```lua
--- Check if a peak column is silent (all channels min and max are 0.0)
--- @param peaks table Peak data with mins, maxs, count, channels
--- @param col integer 1-based column index
--- @return boolean
function utils.is_column_silent(peaks, col)
  for ch = 1, peaks.channels do
    local idx = (col - 1) * peaks.channels + ch
    if (peaks.mins[idx] or 0) ~= 0 or (peaks.maxs[idx] or 0) ~= 0 then
      return false
    end
  end
  return true
end
```

**Step 4: Run tests**

Run: `wsl -e bash -c 'cd "/mnt/d/production/# BOUGHT & FREE soft/Reaper/NVSD_ItemView" && lua5.4 tests/run_tests.lua'`
Expected: new tests PASS

**Step 5: Commit**

```
feat: add is_column_silent for sausage file detection
```

---

### Task 2: Add find_next_region and find_prev_region

**Files:**
- Modify: `lib/utils.lua` (after `is_column_silent`)
- Test: `tests/nvsd_itemview_test.lua`

**Step 1: Write tests for find_next_region**

```lua
-- Test data: sound(1-3), silence(4-6), sound(7-9), silence(10)
local function make_sausage_peaks()
  -- 10 columns mono: sound, sound, sound, silent, silent, silent, sound, sound, sound, silent
  local mins = {-0.5, -0.4, -0.3,  0, 0, 0,  -0.6, -0.5, -0.4,  0}
  local maxs = { 0.5,  0.4,  0.3,  0, 0, 0,   0.6,  0.5,  0.4,  0}
  return {mins = mins, maxs = maxs, count = 10, channels = 1}
end

function TestNVSDItemView:test_find_next_region_from_sound()
  local peaks = make_sausage_peaks()
  -- From col 2 (in first sound): skip rest of sound, skip silence, land on col 7
  lu.assertEquals(utils.find_next_region(peaks, 2), 7)
end

function TestNVSDItemView:test_find_next_region_from_silence()
  local peaks = make_sausage_peaks()
  -- From col 5 (in silence): find next sound at col 7
  lu.assertEquals(utils.find_next_region(peaks, 5), 7)
end

function TestNVSDItemView:test_find_next_region_at_end()
  local peaks = make_sausage_peaks()
  -- From col 8 (second sound region): no more regions ahead
  lu.assertNil(utils.find_next_region(peaks, 8))
end

function TestNVSDItemView:test_find_next_region_from_last_silence()
  local peaks = make_sausage_peaks()
  -- From col 10 (trailing silence): no sound ahead
  lu.assertNil(utils.find_next_region(peaks, 10))
end
```

**Step 2: Write tests for find_prev_region**

```lua
function TestNVSDItemView:test_find_prev_region_from_sound_middle()
  local peaks = make_sausage_peaks()
  -- From col 8 (in second sound): find start of this region = col 7
  lu.assertEquals(utils.find_prev_region(peaks, 8), 7)
end

function TestNVSDItemView:test_find_prev_region_from_silence()
  local peaks = make_sausage_peaks()
  -- From col 5 (in silence): walk back to first sound, find its start = col 1
  lu.assertEquals(utils.find_prev_region(peaks, 5), 1)
end

function TestNVSDItemView:test_find_prev_region_from_first_region()
  local peaks = make_sausage_peaks()
  -- From col 2 (first sound, at its start): no previous region
  lu.assertNil(utils.find_prev_region(peaks, 1))
end

function TestNVSDItemView:test_find_prev_region_from_region_start()
  local peaks = make_sausage_peaks()
  -- From col 7 (start of second sound): previous region starts at col 1
  lu.assertEquals(utils.find_prev_region(peaks, 7), 1)
end
```

**Step 3: Run tests to verify they fail**

Run: `wsl -e bash -c 'cd "/mnt/d/production/# BOUGHT & FREE soft/Reaper/NVSD_ItemView" && lua5.4 tests/run_tests.lua'`
Expected: FAIL

**Step 4: Implement both functions**

In `lib/utils.lua`, after `is_column_silent`:

```lua
--- Find the start column of the next sound region after a silence gap.
--- @param peaks table Peak data
--- @param col integer 1-based current column
--- @return integer|nil Next region start column, or nil if none found
function utils.find_next_region(peaks, col)
  local n = peaks.count
  if col >= n then return nil end

  local i = col
  if utils.is_column_silent(peaks, i) then
    -- Already in silence — find end of this gap
    while i <= n and utils.is_column_silent(peaks, i) do i = i + 1 end
    return i <= n and i or nil
  end

  -- In sound — skip past current sound, then past silence gap
  while i <= n and not utils.is_column_silent(peaks, i) do i = i + 1 end
  while i <= n and utils.is_column_silent(peaks, i) do i = i + 1 end
  return i <= n and i or nil
end

--- Find the start column of the current or previous sound region.
--- @param peaks table Peak data
--- @param col integer 1-based current column
--- @return integer|nil Region start column, or nil if at/before first region
function utils.find_prev_region(peaks, col)
  if col <= 1 then return nil end

  local i = col
  -- If in silence, walk backward into previous sound region
  if utils.is_column_silent(peaks, i) then
    while i > 1 and utils.is_column_silent(peaks, i - 1) do i = i - 1 end
    if i <= 1 then return nil end
    i = i - 1  -- step into previous sound region
  end

  -- Now in sound. Walk backward to find start of this sound region.
  while i > 1 and not utils.is_column_silent(peaks, i - 1) do i = i - 1 end

  -- If start is col 1 and we started in this region, no previous region
  if i == col or (not utils.is_column_silent(peaks, col) and i == 1 and col <= i) then
    return nil
  end
  -- If we're at col 1 and that's the start of the first region
  if i <= 1 and col <= 1 then return nil end
  return i
end
```

**Step 5: Run tests**

Run: `wsl -e bash -c 'cd "/mnt/d/production/# BOUGHT & FREE soft/Reaper/NVSD_ItemView" && lua5.4 tests/run_tests.lua'`
Expected: all new tests PASS

**Step 6: Commit**

```
feat: add find_next_region / find_prev_region for sausage navigation
```

---

### Task 3: Add find_nearest_sound_column for click snap

**Files:**
- Modify: `lib/utils.lua` (after find_prev_region)
- Test: `tests/nvsd_itemview_test.lua`

**Step 1: Write tests**

```lua
function TestNVSDItemView:test_find_nearest_sound_in_sound()
  local peaks = make_sausage_peaks()
  -- Already in sound → returns same column
  lu.assertEquals(utils.find_nearest_sound_column(peaks, 2), 2)
end

function TestNVSDItemView:test_find_nearest_sound_in_silence_biased_forward()
  local peaks = make_sausage_peaks()
  -- Col 5 is in silence gap (4-6). Next sound at 7, prev sound at 3. Forward bias → 7
  lu.assertEquals(utils.find_nearest_sound_column(peaks, 5), 7)
end

function TestNVSDItemView:test_find_nearest_sound_trailing_silence()
  local peaks = make_sausage_peaks()
  -- Col 10 is trailing silence. No forward sound. Backward to col 9.
  lu.assertEquals(utils.find_nearest_sound_column(peaks, 10), 9)
end
```

**Step 2: Run tests to verify they fail**

**Step 3: Implement**

```lua
--- Find nearest non-silent column, biased forward (toward next onset).
--- @param peaks table Peak data
--- @param col integer 1-based column
--- @return integer Nearest sound column (same col if already in sound)
function utils.find_nearest_sound_column(peaks, col)
  if not utils.is_column_silent(peaks, col) then return col end

  -- Search forward first (bias toward next attack)
  for i = col + 1, peaks.count do
    if not utils.is_column_silent(peaks, i) then return i end
  end
  -- Search backward
  for i = col - 1, 1, -1 do
    if not utils.is_column_silent(peaks, i) then return i end
  end
  return col  -- all silent, return original
end
```

**Step 4: Run tests, verify PASS**

**Step 5: Commit**

```
feat: add find_nearest_sound_column for click-to-seek snap
```

---

### Task 4: Add shortcut defaults and preference to settings

**Files:**
- Modify: `lib/settings.lua:20-59` (DEFAULT_SHORTCUTS) and `lib/settings.lua:680-688` (DEFAULT_DEFAULTS)
- Modify: `lib/settings_ui.lua:17-72` (EDITABLE_SHORTCUTS) and `lib/settings_ui.lua:2188-2191` (DEFAULTS_ITEMS)

**Step 1: Add shortcut defaults**

In `lib/settings.lua`, in the `DEFAULT_SHORTCUTS` table (around line 43, near `unzoom_all`), add:

```lua
  next_region = {ctrl = false, shift = false, alt = false, key = "Right"},
  prev_region = {ctrl = false, shift = false, alt = false, key = "Left"},
```

**Step 2: Add preference default**

In `lib/settings.lua`, in the `DEFAULT_DEFAULTS` table (line 687, after `show_tooltips`), add:

```lua
  snap_click_to_sound = false,
```

**Step 3: Add to EDITABLE_SHORTCUTS**

In `lib/settings_ui.lua`, after the "View & Zoom" section entries (line 62, after `zoom_to_markers`), add a new section:

```lua
  -- Navigation
  {section = "Navigation"},
  {name = "next_region",       label = "Skip to next region"},
  {name = "prev_region",       label = "Skip to previous region"},
```

**Step 4: Add preference toggle to DEFAULTS_ITEMS**

In `lib/settings_ui.lua`, in the `DEFAULTS_ITEMS` table (around line 2191, after `show_tooltips`), add:

```lua
  {key = "snap_click_to_sound", label = "Snap click to sound", tip = "When clicking in a silent gap, snap cursor to nearest sound onset"},
```

**Step 5: Run tests**

Run: `wsl -e bash -c 'cd "/mnt/d/production/# BOUGHT & FREE soft/Reaper/NVSD_ItemView" && lua5.4 tests/run_tests.lua'`
Expected: same pass count (test_default_shortcuts_complete will change expected count — update if needed)

**Step 6: Commit**

```
feat: add next/prev region shortcuts and snap_click_to_sound preference
```

---

### Task 5: Wire up shortcut handlers and click snap in NVSD_ItemView.lua

**Files:**
- Modify: `NVSD_ItemView.lua:522-526` (after unzoom_all handler), `NVSD_ItemView.lua:4449-4455` (click-to-seek)
- Modify: `lib/state.lua` (add grace period state fields)

**Step 1: Add state fields for grace period**

In `lib/state.lua`, before `return state` (line 614), add:

```lua
-- Sausage navigation grace period
state.prev_region_last_time = 0
state.prev_region_last_col = 0
state.prev_region_land_col = 0
state.prev_region_end_col = 0
```

**Step 2: Add shortcut handlers**

In `NVSD_ItemView.lua`, after the `unzoom_all` handler block (after line 526), add:

```lua
    -- Region navigation (sausage files)
    if reaper_is_active and not text_input_active and state.view_peaks
        and state.view_peaks.count > 0 then
      if settings.check_shortcut(ctx, "next_region") then
        local peaks = state.view_peaks
        local cur_time = state.preview_cursor_pos or reaper.GetCursorPosition()
        local item_pos = item and reaper.GetMediaItemInfo_Value(item, "D_POSITION") or 0
        local item_len = item and reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 1
        local col = math.floor((cur_time - item_pos) / item_len * peaks.count) + 1
        col = math.max(1, math.min(peaks.count, col))
        local next_col = utils.find_next_region(peaks, col)
        if next_col then
          local t = item_pos + (next_col - 1) / peaks.count * item_len
          state.preview_cursor_pos = t
          reaper.SetEditCurPos(t, false, true)
        else
          -- Fallback: +3 seconds
          local t = math.min(item_pos + item_len, (cur_time or 0) + 3)
          state.preview_cursor_pos = t
          reaper.SetEditCurPos(t, false, true)
        end
      elseif settings.check_shortcut(ctx, "prev_region") then
        local peaks = state.view_peaks
        local cur_time = state.preview_cursor_pos or reaper.GetCursorPosition()
        local item_pos = item and reaper.GetMediaItemInfo_Value(item, "D_POSITION") or 0
        local item_len = item and reaper.GetMediaItemInfo_Value(item, "D_LENGTH") or 1
        local col = math.floor((cur_time - item_pos) / item_len * peaks.count) + 1
        col = math.max(1, math.min(peaks.count, col))

        -- Grace period: if repeated within 1.5s and haven't moved past midpoint
        local now = reaper.time_precise()
        local search_col = col
        if now - state.prev_region_last_time < 1.5 and state.prev_region_land_col > 0 then
          local mid = math.floor((state.prev_region_land_col + state.prev_region_end_col) / 2)
          if col <= mid then
            search_col = state.prev_region_land_col - 1
            if search_col < 1 then search_col = 1 end
          end
        end

        local prev_col = utils.find_prev_region(peaks, search_col)
        if prev_col then
          local t = item_pos + (prev_col - 1) / peaks.count * item_len
          state.preview_cursor_pos = t
          reaper.SetEditCurPos(t, false, true)
          -- Track for grace period: find end of this region
          local end_col = prev_col
          while end_col < peaks.count and not utils.is_column_silent(peaks, end_col + 1) do
            end_col = end_col + 1
          end
          state.prev_region_land_col = prev_col
          state.prev_region_end_col = end_col
        else
          -- Fallback: -3 seconds
          local t = math.max(item_pos, (cur_time or 0) - 3)
          state.preview_cursor_pos = t
          reaper.SetEditCurPos(t, false, true)
          state.prev_region_land_col = 0
          state.prev_region_end_col = 0
        end
        state.prev_region_last_time = now
        state.prev_region_last_col = col
      end
    end
```

**Step 3: Add click-to-seek silence snap**

In `NVSD_ItemView.lua`, around line 4452 where `state.preview_cursor_pos = click_t` is set, wrap with the snap logic:

Find:
```lua
                state.preview_cursor_pos = click_t
```

Replace with:
```lua
                -- Snap click out of silence if preference enabled
                if settings.current.defaults.snap_click_to_sound
                    and state.view_peaks and state.view_peaks.count > 0 and item then
                  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
                  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                  local peaks = state.view_peaks
                  local col = math.floor((click_t - item_pos) / item_len * peaks.count) + 1
                  col = math.max(1, math.min(peaks.count, col))
                  if utils.is_column_silent(peaks, col) then
                    local snap_col = utils.find_nearest_sound_column(peaks, col)
                    click_t = item_pos + (snap_col - 1) / peaks.count * item_len
                  end
                end
                state.preview_cursor_pos = click_t
```

**Step 4: Run tests**

Run: `wsl -e bash -c 'cd "/mnt/d/production/# BOUGHT & FREE soft/Reaper/NVSD_ItemView" && lua5.4 tests/run_tests.lua'`
Expected: all tests pass

**Step 5: Commit**

```
feat: wire up region navigation shortcuts and click-to-seek snap
```

---

### Task 6: Add help text

**Files:**
- Modify: `lib/settings_ui.lua:2117` (Tips section in HELP_SECTIONS)

**Step 1: Add tip**

After the existing grab button tip (around line 2118), add:

```lua
      "- Left/Right arrows skip between sound regions in sausage files",
```

**Step 2: Commit**

```
docs: add sausage navigation tip to Help tab
```

---

## Verification Checklist

1. All tests pass: `wsl -e bash -c 'cd "/mnt/d/production/# BOUGHT & FREE soft/Reaper/NVSD_ItemView" && lua5.4 tests/run_tests.lua'`
2. In REAPER with a sausage file selected:
   - Right arrow skips to next sound region
   - Left arrow skips to previous sound region
   - Rapid Left presses skip past current region (grace period)
   - When no more regions: falls back to +/- 3 seconds
3. Settings > Shortcuts tab: "Navigation" section with next_region / prev_region
4. Settings > Preferences tab: "Snap click to sound" toggle
5. With snap enabled: clicking in silence snaps to nearest sound
6. With snap disabled: clicking in silence seeks to exact position (unchanged)
7. Works with stereo files (silence = both channels zero)
