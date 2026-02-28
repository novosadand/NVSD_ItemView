# Sausage File Region Navigation — Design

## Goal

Navigate between sound regions in sausage files (audio files with multiple variations separated by digital silence). Left/Right arrow keys skip between regions, optional click-to-seek snaps out of silence gaps.

## Background

Sausage files are common in commercial SFX libraries. A single file contains multiple sound variations (e.g., 10 footstep takes) concatenated with genuine digital silence between them. Users need to quickly audition individual variations.

## Algorithm Layer

Three pure functions in `lib/utils.lua` operating on existing peak data (`peaks.mins`, `peaks.maxs`, flat indexing with `peaks.channels`):

### is_column_silent(peaks, col)

Returns true when both min and max are exactly 0.0 across all channels. Works because sausage files have genuine digital zeros between variations, not just quiet audio.

```
for ch = 1 to peaks.channels:
    flat_idx = (col - 1) * peaks.channels + ch
    if mins[flat_idx] ~= 0.0 or maxs[flat_idx] ~= 0.0: return false
return true
```

### find_next_region(peaks, col)

From current column:
1. If in silence — scan forward for first non-silent column. Return it.
2. If in sound — skip past remaining sound, then skip past silence gap, return first non-silent column.
3. If no region found — return nil.

### find_prev_region(peaks, col)

From current column:
1. If in silence — walk backward past current silence gap into previous sound, then find that sound region's start.
2. If in sound — walk backward to find start of current sound region (where preceding silence ends).
3. If at column 0 or no previous gap — return nil.

All O(n) in peak columns (typically 800-2000), effectively instant.

## Navigation Shortcuts

Two new editable shortcuts in EDITABLE_SHORTCUTS:
- `next_region` — default: Right arrow — skip to next sound region
- `prev_region` — default: Left arrow — skip to previous sound region

### On trigger

1. Get current playhead/preview cursor position
2. Convert to peak column: `col = math.floor((pos - item_start) / item_length * peaks.count)`
3. Call `find_next_region` or `find_prev_region`
4. Convert result back: `time = col / peaks.count * item_length + item_start`
5. Seek via `reaper.SetEditCurPos()` or set `state.preview_cursor_pos`
6. If nil returned (no region found), fall back to +/- 3 seconds

### Grace period for rapid backward skipping

When pressing Left repeatedly within 1.5 seconds: if the playhead hasn't moved past the midpoint of the variation you landed on, skip past that variation to the previous one. Prevents getting "stuck" on the current variation.

State tracked in:
- `state.prev_region_last_time` — timestamp of last Left press
- `state.prev_region_last_col` — column we last landed on

Logic:
```
if Left pressed within 1.5s of last Left
   AND playhead < midpoint of landed variation:
    search from (last_col - 1) instead of current position
```

## Click-to-Seek Silence Snap

New preference: `snap_click_to_sound` (default: off).

When enabled and user clicks in a silent region of the waveform:
1. Convert click position to peak column
2. If column is non-silent — no adjustment
3. If silent — find nearest sound column (biased forward toward next onset)
4. Snap to 1 column before onset to preserve attack transient

Implemented as a filter on the existing click-to-seek path in `NVSD_ItemView.lua` (around line 4446 where `state.preview_cursor_pos` is set).

## Files Touched

- `lib/utils.lua` — add `is_column_silent`, `find_next_region`, `find_prev_region`, `find_nearest_sound_column`
- `lib/settings.lua` — add `next_region`/`prev_region` shortcut defaults, `snap_click_to_sound` preference default
- `lib/settings_ui.lua` — add shortcuts to EDITABLE_SHORTCUTS, add preference toggle to Preferences tab
- `NVSD_ItemView.lua` — shortcut handlers, grace period state, click snap filter
- `tests/nvsd_itemview_test.lua` — unit tests for silence detection and region finding
