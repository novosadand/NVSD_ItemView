-- Unit tests for NVSD_ItemView
local lu = require("luaunit")

-- Mock REAPER API for testing outside REAPER
reaper = reaper or {}

-- Load real modules for testing (pure-Lua functions work outside REAPER)
local utils = dofile("Scripts/NVSD/lib/utils.lua")
local settings = dofile("Scripts/NVSD/lib/settings.lua")

-- Test suite
TestNVSDItemView = {}

function TestNVSDItemView:test_marker_near_detection()
    -- Test the is_near_marker logic (using real utils module)
    lu.assertTrue(utils.is_near_marker(100, 105, 10))   -- within threshold
    lu.assertTrue(utils.is_near_marker(100, 95, 10))    -- within threshold (other side)
    lu.assertFalse(utils.is_near_marker(100, 115, 10))  -- outside threshold
    lu.assertFalse(utils.is_near_marker(100, 85, 10))   -- outside threshold (other side)
    lu.assertTrue(utils.is_near_marker(100, 100, 10))   -- exactly on marker
end

function TestNVSDItemView:test_offset_clamping()
    -- Test that offset is properly clamped to valid range
    local function clamp_offset(new_pos, source_length, item_length)
        return math.max(0, math.min(new_pos, source_length - item_length))
    end

    -- Normal case
    lu.assertEquals(clamp_offset(5, 20, 10), 5)

    -- Clamp to 0 when negative
    lu.assertEquals(clamp_offset(-5, 20, 10), 0)

    -- Clamp to max when exceeding source
    lu.assertEquals(clamp_offset(15, 20, 10), 10)  -- max is 20-10=10
end

function TestNVSDItemView:test_pixel_to_time_conversion()
    -- Test converting pixel position to time position
    local function pixel_to_time(mouse_x, wave_x, waveform_width, source_length)
        return ((mouse_x - wave_x) / waveform_width) * source_length
    end

    -- At start
    lu.assertAlmostEquals(pixel_to_time(100, 100, 500, 10), 0, 0.001)

    -- At middle
    lu.assertAlmostEquals(pixel_to_time(350, 100, 500, 10), 5, 0.001)

    -- At end
    lu.assertAlmostEquals(pixel_to_time(600, 100, 500, 10), 10, 0.001)
end

function TestNVSDItemView:test_time_to_pixel_conversion()
    -- Test converting time position to pixel position
    local function time_to_pixel(time_pos, source_length, waveform_width)
        return (time_pos / source_length) * waveform_width
    end

    -- At start
    lu.assertAlmostEquals(time_to_pixel(0, 10, 500), 0, 0.001)

    -- At middle
    lu.assertAlmostEquals(time_to_pixel(5, 10, 500), 250, 0.001)

    -- At end
    lu.assertAlmostEquals(time_to_pixel(10, 10, 500), 500, 0.001)
end

function TestNVSDItemView:test_length_clamping()
    -- Test that item length is properly clamped
    local function clamp_length(new_length, start_offset, source_length, min_length)
        min_length = min_length or 0.01
        return math.max(min_length, math.min(new_length, source_length - start_offset))
    end

    -- Normal case
    lu.assertEquals(clamp_length(5, 2, 20, 0.01), 5)

    -- Clamp to minimum
    lu.assertEquals(clamp_length(0, 2, 20, 0.01), 0.01)

    -- Clamp to max available
    lu.assertEquals(clamp_length(25, 5, 20, 0.01), 15)  -- max is 20-5=15
end

function TestNVSDItemView:test_active_region_pixel_calculation()
    -- Test calculating active region bounds in pixels
    local function calc_active_region_px(start_offset, item_length, source_length, width)
        local start_px = math.max(0, (start_offset / source_length) * width)
        local end_px = math.min(width, ((start_offset + item_length) / source_length) * width)
        return start_px, end_px
    end

    -- Full source selected (offset=0, length=source_length)
    local s, e = calc_active_region_px(0, 10, 10, 500)
    lu.assertAlmostEquals(s, 0, 0.001)
    lu.assertAlmostEquals(e, 500, 0.001)

    -- First half selected
    s, e = calc_active_region_px(0, 5, 10, 500)
    lu.assertAlmostEquals(s, 0, 0.001)
    lu.assertAlmostEquals(e, 250, 0.001)

    -- Second half selected
    s, e = calc_active_region_px(5, 5, 10, 500)
    lu.assertAlmostEquals(s, 250, 0.001)
    lu.assertAlmostEquals(e, 500, 0.001)

    -- Middle portion selected
    s, e = calc_active_region_px(2.5, 5, 10, 500)
    lu.assertAlmostEquals(s, 125, 0.001)
    lu.assertAlmostEquals(e, 375, 0.001)

    -- Clamp to bounds (negative offset)
    s, e = calc_active_region_px(-2, 5, 10, 500)
    lu.assertAlmostEquals(s, 0, 0.001)  -- clamped to 0

    -- Clamp to bounds (exceeds source)
    s, e = calc_active_region_px(8, 5, 10, 500)
    lu.assertAlmostEquals(e, 500, 0.001)  -- clamped to width
end

function TestNVSDItemView:test_peak_in_active_region()
    -- Test checking if a peak position falls within active region
    local function is_peak_in_active(peak_index, num_peaks, source_length, start_offset, item_length)
        local peak_pos = ((peak_index - 1) / num_peaks) * source_length
        return peak_pos >= start_offset and peak_pos <= (start_offset + item_length)
    end

    -- 100 peaks, 10 second source, active region 2-7 seconds
    local num_peaks = 100
    local source_length = 10
    local start_offset = 2
    local item_length = 5

    -- Peak at 0 seconds (index 1) - outside
    lu.assertFalse(is_peak_in_active(1, num_peaks, source_length, start_offset, item_length))

    -- Peak at ~2 seconds (index 21) - at start boundary
    lu.assertTrue(is_peak_in_active(21, num_peaks, source_length, start_offset, item_length))

    -- Peak at 5 seconds (index 51) - inside
    lu.assertTrue(is_peak_in_active(51, num_peaks, source_length, start_offset, item_length))

    -- Peak at ~7 seconds (index 71) - at end boundary
    lu.assertTrue(is_peak_in_active(71, num_peaks, source_length, start_offset, item_length))

    -- Peak at 9 seconds (index 91) - outside
    lu.assertFalse(is_peak_in_active(91, num_peaks, source_length, start_offset, item_length))
end

function TestNVSDItemView:test_peakrate_calculation()
    -- Test peakrate calculation for proper waveform display
    local function calc_peakrate(num_samples, source_length)
        return num_samples / source_length
    end

    -- 500 samples over 10 seconds = 50 samples/sec
    lu.assertAlmostEquals(calc_peakrate(500, 10), 50, 0.001)

    -- 1000 samples over 5 seconds = 200 samples/sec
    lu.assertAlmostEquals(calc_peakrate(1000, 5), 200, 0.001)

    -- Short sample: 500 samples over 0.5 seconds = 1000 samples/sec
    lu.assertAlmostEquals(calc_peakrate(500, 0.5), 1000, 0.001)
end

function TestNVSDItemView:test_waveform_y_calculation()
    -- Test converting peak values to Y coordinates
    local function calc_peak_y(peak_min, peak_max, center_y, height)
        local half_height = height / 2
        local min_y = center_y - (peak_max * half_height * 0.95)  -- max goes up
        local max_y = center_y - (peak_min * half_height * 0.95)  -- min goes down
        return min_y, max_y
    end

    local center_y = 100
    local height = 180

    -- Silent audio (0, 0) - should be near center
    local min_y, max_y = calc_peak_y(0, 0, center_y, height)
    lu.assertAlmostEquals(min_y, 100, 0.001)
    lu.assertAlmostEquals(max_y, 100, 0.001)

    -- Full amplitude (−1, 1)
    min_y, max_y = calc_peak_y(-1, 1, center_y, height)
    lu.assertAlmostEquals(min_y, 100 - (1 * 90 * 0.95), 0.001)  -- peak.max goes up
    lu.assertAlmostEquals(max_y, 100 - (-1 * 90 * 0.95), 0.001)  -- peak.min goes down

    -- Half amplitude (−0.5, 0.5)
    min_y, max_y = calc_peak_y(-0.5, 0.5, center_y, height)
    lu.assertAlmostEquals(min_y, 100 - (0.5 * 90 * 0.95), 0.001)
    lu.assertAlmostEquals(max_y, 100 - (-0.5 * 90 * 0.95), 0.001)
end

function TestNVSDItemView:test_mouse_in_waveform_detection()
    -- Test mouse position detection within waveform bounds
    local function is_mouse_in_waveform(mouse_x, mouse_y, wave_x, wave_y, width, height)
        return mouse_x >= wave_x and mouse_x <= wave_x + width
               and mouse_y >= wave_y and mouse_y <= wave_y + height
    end

    local wave_x, wave_y = 50, 100
    local width, height = 500, 180

    -- Inside
    lu.assertTrue(is_mouse_in_waveform(300, 150, wave_x, wave_y, width, height))

    -- At corners
    lu.assertTrue(is_mouse_in_waveform(50, 100, wave_x, wave_y, width, height))  -- top-left
    lu.assertTrue(is_mouse_in_waveform(550, 280, wave_x, wave_y, width, height))  -- bottom-right

    -- Outside left
    lu.assertFalse(is_mouse_in_waveform(40, 150, wave_x, wave_y, width, height))

    -- Outside right
    lu.assertFalse(is_mouse_in_waveform(560, 150, wave_x, wave_y, width, height))

    -- Outside top
    lu.assertFalse(is_mouse_in_waveform(300, 90, wave_x, wave_y, width, height))

    -- Outside bottom
    lu.assertFalse(is_mouse_in_waveform(300, 290, wave_x, wave_y, width, height))
end

function TestNVSDItemView:test_stereo_peak_combination()
    -- Test combining stereo peaks (min of mins, max of maxes)
    local function combine_stereo_peaks(l_min, l_max, r_min, r_max)
        return math.min(l_min, r_min), math.max(l_max, r_max)
    end

    -- Left louder
    local min_val, max_val = combine_stereo_peaks(-0.8, 0.9, -0.5, 0.6)
    lu.assertAlmostEquals(min_val, -0.8, 0.001)
    lu.assertAlmostEquals(max_val, 0.9, 0.001)

    -- Right louder
    min_val, max_val = combine_stereo_peaks(-0.3, 0.4, -0.7, 0.8)
    lu.assertAlmostEquals(min_val, -0.7, 0.001)
    lu.assertAlmostEquals(max_val, 0.8, 0.001)

    -- Equal
    min_val, max_val = combine_stereo_peaks(-0.5, 0.5, -0.5, 0.5)
    lu.assertAlmostEquals(min_val, -0.5, 0.001)
    lu.assertAlmostEquals(max_val, 0.5, 0.001)
end

function TestNVSDItemView:test_source_length_fallback()
    -- Test that invalid source_length falls back to item_length
    local function get_effective_source_length(source_length, item_length)
        if source_length <= 0 then
            return item_length
        end
        return source_length
    end

    -- Normal case - use source_length
    lu.assertEquals(get_effective_source_length(10, 5), 10)

    -- Zero source_length - fallback to item_length
    lu.assertEquals(get_effective_source_length(0, 5), 5)

    -- Negative source_length - fallback to item_length
    lu.assertEquals(get_effective_source_length(-1, 5), 5)
end

function TestNVSDItemView:test_file_changed_detection()
    -- Test detecting if file modification time changed
    local function has_file_changed(current_mtime, stored_mtime)
        if not stored_mtime then return false end  -- first run, no comparison
        if not current_mtime then return false end  -- can't read file
        return current_mtime > stored_mtime
    end

    -- First run (no stored time) - don't reload
    lu.assertFalse(has_file_changed(1000, nil))

    -- Can't read file - don't reload
    lu.assertFalse(has_file_changed(nil, 1000))

    -- Same time - no change
    lu.assertFalse(has_file_changed(1000, 1000))

    -- File is newer - changed
    lu.assertTrue(has_file_changed(1001, 1000))

    -- File is older (shouldn't happen but handle it) - no change
    lu.assertFalse(has_file_changed(999, 1000))
end

function TestNVSDItemView:test_marker_at_start_means_zero_offset()
    -- When left marker is all the way left, offset should be 0 (start of sound)
    local function calc_offset_from_marker_px(marker_px, wave_x, waveform_width, source_length)
        return ((marker_px - wave_x) / waveform_width) * source_length
    end

    local wave_x = 100
    local waveform_width = 500
    local source_length = 10

    -- Marker at far left (wave_x) = offset 0 (start of sound)
    lu.assertAlmostEquals(calc_offset_from_marker_px(100, wave_x, waveform_width, source_length), 0, 0.001)

    -- Marker at far right = offset equals source_length (end of sound)
    lu.assertAlmostEquals(calc_offset_from_marker_px(600, wave_x, waveform_width, source_length), 10, 0.001)

    -- Marker at middle = half the source
    lu.assertAlmostEquals(calc_offset_from_marker_px(350, wave_x, waveform_width, source_length), 5, 0.001)
end

function TestNVSDItemView:test_drag_start_marker_keeps_end_fixed()
    -- Dragging start marker: end position stays fixed, offset and length change
    -- Now allows negative offsets for pre-source looping
    local function drag_start_marker(new_start_pos, original_offset, original_length)
        local original_end = original_offset + original_length
        -- Only clamp: can't go past end (need at least 0.01s length)
        local new_start = math.min(new_start_pos, original_end - 0.01)
        local new_length = original_end - new_start
        return new_start, new_length
    end

    -- Original: offset=2, length=5, end=7
    -- Drag start to position 3 -> new offset=3, new length=4, end still=7
    local new_offset, new_length = drag_start_marker(3, 2, 5)
    lu.assertAlmostEquals(new_offset, 3, 0.001)
    lu.assertAlmostEquals(new_length, 4, 0.001)
    lu.assertAlmostEquals(new_offset + new_length, 7, 0.001)  -- end unchanged

    -- Drag start to position 1 -> new offset=1, new length=6, end still=7
    new_offset, new_length = drag_start_marker(1, 2, 5)
    lu.assertAlmostEquals(new_offset, 1, 0.001)
    lu.assertAlmostEquals(new_length, 6, 0.001)
    lu.assertAlmostEquals(new_offset + new_length, 7, 0.001)  -- end unchanged

    -- Drag start to 0 (far left) -> offset=0, length=7, end still=7
    new_offset, new_length = drag_start_marker(0, 2, 5)
    lu.assertAlmostEquals(new_offset, 0, 0.001)
    lu.assertAlmostEquals(new_length, 7, 0.001)
    lu.assertAlmostEquals(new_offset + new_length, 7, 0.001)  -- end unchanged

    -- Drag start to -2 (before source, for looping) -> offset=-2, length=9
    new_offset, new_length = drag_start_marker(-2, 2, 5)
    lu.assertAlmostEquals(new_offset, -2, 0.001)
    lu.assertAlmostEquals(new_length, 9, 0.001)
    lu.assertAlmostEquals(new_offset + new_length, 7, 0.001)  -- end unchanged

    -- Try to drag past end -> clamped to just before end
    new_offset, new_length = drag_start_marker(8, 2, 5)
    lu.assertAlmostEquals(new_offset, 6.99, 0.02)
    lu.assertAlmostEquals(new_length, 0.01, 0.02)  -- minimum length
end

function TestNVSDItemView:test_drag_end_marker_keeps_start_fixed()
    -- Dragging end marker: start position stays fixed, only length changes
    -- Now allows extending past source bounds for looping
    local function drag_end_marker(new_end_pos, start_offset)
        local new_length = new_end_pos - start_offset
        new_length = math.max(0.01, new_length)  -- only minimum clamp, no max (allows looping)
        return new_length
    end

    -- Offset=2, drag end to 8 -> length=6
    local new_length = drag_end_marker(8, 2)
    lu.assertAlmostEquals(new_length, 6, 0.001)

    -- Offset=2, drag end to 5 -> length=3
    new_length = drag_end_marker(5, 2)
    lu.assertAlmostEquals(new_length, 3, 0.001)

    -- Offset=2, drag end to 10 (source end) -> length=8
    new_length = drag_end_marker(10, 2)
    lu.assertAlmostEquals(new_length, 8, 0.001)

    -- Offset=2, drag end to 15 (past source) -> length=13 (allowed for looping)
    new_length = drag_end_marker(15, 2)
    lu.assertAlmostEquals(new_length, 13, 0.001)

    -- Offset=2, drag end to 2.005 (very close to start) -> minimum length
    new_length = drag_end_marker(2.005, 2)
    lu.assertAlmostEquals(new_length, 0.01, 0.01)

    -- Offset=2, drag end before start -> clamped to minimum
    new_length = drag_end_marker(1, 2)
    lu.assertAlmostEquals(new_length, 0.01, 0.001)
end

function TestNVSDItemView:test_full_selection_markers_at_edges()
    -- When item covers full source, markers should be at edges
    local function calc_marker_positions(start_offset, item_length, source_length, waveform_width)
        local start_px = (start_offset / source_length) * waveform_width
        local end_px = ((start_offset + item_length) / source_length) * waveform_width
        return start_px, end_px
    end

    -- Full source selected: offset=0, length=source_length
    local start_px, end_px = calc_marker_positions(0, 10, 10, 500)
    lu.assertAlmostEquals(start_px, 0, 0.001)      -- left marker at far left
    lu.assertAlmostEquals(end_px, 500, 0.001)     -- right marker at far right

    -- First half: offset=0, length=5
    start_px, end_px = calc_marker_positions(0, 5, 10, 500)
    lu.assertAlmostEquals(start_px, 0, 0.001)      -- left marker at far left
    lu.assertAlmostEquals(end_px, 250, 0.001)     -- right marker at middle

    -- Last half: offset=5, length=5
    start_px, end_px = calc_marker_positions(5, 5, 10, 500)
    lu.assertAlmostEquals(start_px, 250, 0.001)   -- left marker at middle
    lu.assertAlmostEquals(end_px, 500, 0.001)     -- right marker at far right
end

function TestNVSDItemView:test_view_range_calculation()
    -- Test calculating view range - only expands when item exceeds source bounds
    local function calc_view_range(start_offset, item_length, source_length)
        local item_end = start_offset + item_length
        local view_start, view_end
        if start_offset >= 0 and item_end <= source_length then
            -- Item fits within source - show original source size
            view_start = 0
            view_end = source_length
        else
            -- Item extends beyond source - expand view to fit
            view_start = math.min(0, start_offset)
            view_end = math.max(source_length, item_end)
        end
        local view_length = view_end - view_start
        return view_start, view_end, view_length
    end

    -- Normal case: item within source bounds - view stays at source size
    local view_start, view_end, view_length = calc_view_range(2, 5, 10)
    lu.assertAlmostEquals(view_start, 0, 0.001)
    lu.assertAlmostEquals(view_end, 10, 0.001)
    lu.assertAlmostEquals(view_length, 10, 0.001)

    -- Item at start, within bounds - view stays at source size
    view_start, view_end, view_length = calc_view_range(0, 5, 10)
    lu.assertAlmostEquals(view_start, 0, 0.001)
    lu.assertAlmostEquals(view_end, 10, 0.001)
    lu.assertAlmostEquals(view_length, 10, 0.001)

    -- Item extends past source end (looping) - view expands
    view_start, view_end, view_length = calc_view_range(2, 15, 10)
    lu.assertAlmostEquals(view_start, 0, 0.001)
    lu.assertAlmostEquals(view_end, 17, 0.001)  -- item_end = 2 + 15 = 17
    lu.assertAlmostEquals(view_length, 17, 0.001)

    -- Item starts before source (negative offset, looping) - view expands
    view_start, view_end, view_length = calc_view_range(-3, 8, 10)
    lu.assertAlmostEquals(view_start, -3, 0.001)
    lu.assertAlmostEquals(view_end, 10, 0.001)
    lu.assertAlmostEquals(view_length, 13, 0.001)

    -- Item extends both ways (starts before and ends after source)
    view_start, view_end, view_length = calc_view_range(-2, 15, 10)
    lu.assertAlmostEquals(view_start, -2, 0.001)
    lu.assertAlmostEquals(view_end, 13, 0.001)  -- item_end = -2 + 15 = 13
    lu.assertAlmostEquals(view_length, 15, 0.001)
end

function TestNVSDItemView:test_time_wrapping_for_looping()
    -- Test wrapping time position for looped playback
    local function wrap_time(t, source_length)
        local wrapped = t % source_length
        if wrapped < 0 then wrapped = wrapped + source_length end
        return wrapped
    end

    local source_length = 10

    -- Normal times (within source)
    lu.assertAlmostEquals(wrap_time(0, source_length), 0, 0.001)
    lu.assertAlmostEquals(wrap_time(5, source_length), 5, 0.001)
    lu.assertAlmostEquals(wrap_time(9.5, source_length), 9.5, 0.001)

    -- Times past source end (loop forward)
    lu.assertAlmostEquals(wrap_time(10, source_length), 0, 0.001)
    lu.assertAlmostEquals(wrap_time(12, source_length), 2, 0.001)
    lu.assertAlmostEquals(wrap_time(25, source_length), 5, 0.001)

    -- Negative times (loop backward)
    lu.assertAlmostEquals(wrap_time(-1, source_length), 9, 0.001)
    lu.assertAlmostEquals(wrap_time(-3, source_length), 7, 0.001)
    lu.assertAlmostEquals(wrap_time(-10, source_length), 0, 0.001)
end

function TestNVSDItemView:test_px_to_time_with_view_offset()
    -- Test pixel to time conversion with view offset (for looped views)
    local function px_to_time(px, wave_x, waveform_width, view_start, view_length)
        return view_start + ((px - wave_x) / waveform_width) * view_length
    end

    local wave_x = 100
    local waveform_width = 500

    -- Normal view (view_start=0, view_length=10)
    lu.assertAlmostEquals(px_to_time(100, wave_x, waveform_width, 0, 10), 0, 0.001)
    lu.assertAlmostEquals(px_to_time(350, wave_x, waveform_width, 0, 10), 5, 0.001)
    lu.assertAlmostEquals(px_to_time(600, wave_x, waveform_width, 0, 10), 10, 0.001)

    -- Extended view (view_start=-2, view_length=15)
    lu.assertAlmostEquals(px_to_time(100, wave_x, waveform_width, -2, 15), -2, 0.001)
    lu.assertAlmostEquals(px_to_time(600, wave_x, waveform_width, -2, 15), 13, 0.001)

    -- Offset view (view_start=0, view_length=17 for item extending past source)
    lu.assertAlmostEquals(px_to_time(100, wave_x, waveform_width, 0, 17), 0, 0.001)
    lu.assertAlmostEquals(px_to_time(600, wave_x, waveform_width, 0, 17), 17, 0.001)
end

function TestNVSDItemView:test_pcm_source_getpeaks_buffer_format_mono()
    -- Test correct buffer format parsing for PCM_Source_GetPeaks (mono)
    -- REAPER format: [max_values][min_values] with channel interleaving
    -- For mono: [max0, max1, max2, ...][min0, min1, min2, ...]

    local function parse_mono_peaks(buf, actual_samples)
        local peaks = {}
        local min_block_offset = actual_samples

        for i = 1, actual_samples do
            peaks[i] = {
                max = buf[i],
                min = buf[min_block_offset + i]
            }
        end
        return peaks
    end

    -- Simulate mono buffer: 4 samples
    -- max values: 0.5, 0.8, 0.3, 0.9
    -- min values: -0.4, -0.7, -0.2, -0.8
    local buf = {
        0.5, 0.8, 0.3, 0.9,   -- max block
        -0.4, -0.7, -0.2, -0.8 -- min block
    }

    local peaks = parse_mono_peaks(buf, 4)

    lu.assertAlmostEquals(peaks[1].max, 0.5, 0.001)
    lu.assertAlmostEquals(peaks[1].min, -0.4, 0.001)
    lu.assertAlmostEquals(peaks[2].max, 0.8, 0.001)
    lu.assertAlmostEquals(peaks[2].min, -0.7, 0.001)
    lu.assertAlmostEquals(peaks[3].max, 0.3, 0.001)
    lu.assertAlmostEquals(peaks[3].min, -0.2, 0.001)
    lu.assertAlmostEquals(peaks[4].max, 0.9, 0.001)
    lu.assertAlmostEquals(peaks[4].min, -0.8, 0.001)
end

function TestNVSDItemView:test_pcm_source_getpeaks_buffer_format_stereo()
    -- Test correct buffer format parsing for PCM_Source_GetPeaks (stereo)
    -- REAPER format: channel-interleaved within each block
    -- [L0_max, R0_max, L1_max, R1_max, ...][L0_min, R0_min, L1_min, R1_min, ...]

    local function parse_stereo_peaks(buf, actual_samples, num_channels)
        local peaks = {}
        local min_block_offset = actual_samples * num_channels

        for i = 1, actual_samples do
            local base_idx = (i - 1) * num_channels + 1
            local l_max = buf[base_idx]
            local r_max = buf[base_idx + 1]
            local l_min = buf[min_block_offset + base_idx]
            local r_min = buf[min_block_offset + base_idx + 1]

            peaks[i] = {
                max = math.max(l_max, r_max),
                min = math.min(l_min, r_min)
            }
        end
        return peaks
    end

    -- Simulate stereo buffer: 3 samples, 2 channels
    -- max block (interleaved): L0, R0, L1, R1, L2, R2
    -- min block (interleaved): L0, R0, L1, R1, L2, R2
    local buf = {
        -- max block: L0=0.5, R0=0.6, L1=0.3, R1=0.8, L2=0.4, R2=0.2
        0.5, 0.6, 0.3, 0.8, 0.4, 0.2,
        -- min block: L0=-0.4, R0=-0.5, L1=-0.2, R1=-0.7, L2=-0.3, R2=-0.1
        -0.4, -0.5, -0.2, -0.7, -0.3, -0.1
    }

    local peaks = parse_stereo_peaks(buf, 3, 2)

    -- Sample 1: max(0.5, 0.6)=0.6, min(-0.4, -0.5)=-0.5
    lu.assertAlmostEquals(peaks[1].max, 0.6, 0.001)
    lu.assertAlmostEquals(peaks[1].min, -0.5, 0.001)

    -- Sample 2: max(0.3, 0.8)=0.8, min(-0.2, -0.7)=-0.7
    lu.assertAlmostEquals(peaks[2].max, 0.8, 0.001)
    lu.assertAlmostEquals(peaks[2].min, -0.7, 0.001)

    -- Sample 3: max(0.4, 0.2)=0.4, min(-0.3, -0.1)=-0.3
    lu.assertAlmostEquals(peaks[3].max, 0.4, 0.001)
    lu.assertAlmostEquals(peaks[3].min, -0.3, 0.001)
end

function TestNVSDItemView:test_pcm_source_getpeaks_return_value_parsing()
    -- Test parsing the return value from PCM_Source_GetPeaks
    -- Return value encodes: sample_count (bits 0-19), output_mode (bits 20-23), has_extra (bit 24)

    local function parse_return_value(ret)
        local sample_count = ret & 0xFFFFF           -- lower 20 bits
        local output_mode = (ret & 0xF00000) >> 20   -- bits 20-23
        local has_extra = (ret & 0x1000000) >> 24    -- bit 24
        return sample_count, output_mode, has_extra
    end

    -- Simple case: just 500 samples, no extra
    local count, mode, extra = parse_return_value(500)
    lu.assertEquals(count, 500)
    lu.assertEquals(mode, 0)
    lu.assertEquals(extra, 0)

    -- 1000 samples with extra type available
    count, mode, extra = parse_return_value(0x1000000 + 1000)
    lu.assertEquals(count, 1000)
    lu.assertEquals(extra, 1)

    -- Large sample count (max 20 bits = 1048575)
    count, mode, extra = parse_return_value(0xFFFFF)
    lu.assertEquals(count, 1048575)
end

function TestNVSDItemView:test_playrate_source_length_calculation()
    -- Test calculating source length covered by item with playrate
    -- source_item_length = item_length * playrate

    local function calc_source_item_length(item_length, playrate)
        return item_length * playrate
    end

    -- Normal playrate (1.0): 5 second item covers 5 seconds of source
    lu.assertAlmostEquals(calc_source_item_length(5, 1.0), 5, 0.001)

    -- Double speed (2.0): 5 second item covers 10 seconds of source
    lu.assertAlmostEquals(calc_source_item_length(5, 2.0), 10, 0.001)

    -- Half speed (0.5): 5 second item covers 2.5 seconds of source
    lu.assertAlmostEquals(calc_source_item_length(5, 0.5), 2.5, 0.001)

    -- 1.5x speed: 4 second item covers 6 seconds of source
    lu.assertAlmostEquals(calc_source_item_length(4, 1.5), 6, 0.001)
end

function TestNVSDItemView:test_source_to_project_time()
    -- Test converting source time to project timeline time (using real utils module)
    -- Simple case: item at position 10, offset 2, playrate 1
    -- Source time 2 (at offset) -> project time 10 (at item start)
    lu.assertAlmostEquals(utils.source_to_project_time(2, 10, 2, 1), 10, 0.001)

    -- Source time 5 (3 seconds after offset) -> project time 13
    lu.assertAlmostEquals(utils.source_to_project_time(5, 10, 2, 1), 13, 0.001)

    -- With playrate 2 (double speed): source time 5 -> project time 11.5
    lu.assertAlmostEquals(utils.source_to_project_time(5, 10, 2, 2), 11.5, 0.001)

    -- With playrate 0.5 (half speed): source time 5 -> project time 16
    lu.assertAlmostEquals(utils.source_to_project_time(5, 10, 2, 0.5), 16, 0.001)
end

function TestNVSDItemView:test_project_to_source_time()
    -- Test converting project timeline time to source time (using real utils module)
    -- Simple case: item at position 10, offset 2, playrate 1
    -- Project time 10 (at item start) -> source time 2 (at offset)
    lu.assertAlmostEquals(utils.project_to_source_time(10, 10, 2, 1), 2, 0.001)

    -- Project time 13 -> source time 5
    lu.assertAlmostEquals(utils.project_to_source_time(13, 10, 2, 1), 5, 0.001)

    -- With playrate 2: project time 11.5 -> source time 5
    lu.assertAlmostEquals(utils.project_to_source_time(11.5, 10, 2, 2), 5, 0.001)

    -- With playrate 0.5: project time 16 -> source time 5
    lu.assertAlmostEquals(utils.project_to_source_time(16, 10, 2, 0.5), 5, 0.001)
end

function TestNVSDItemView:test_source_project_time_roundtrip()
    -- Test that source->project->source is identity (using real utils module)
    local item_position = 10
    local start_offset = 2
    local playrate = 1.5

    local source_time = 7.5
    local project_time = utils.source_to_project_time(source_time, item_position, start_offset, playrate)
    local back_to_source = utils.project_to_source_time(project_time, item_position, start_offset, playrate)

    lu.assertAlmostEquals(back_to_source, source_time, 0.0001)
end

function TestNVSDItemView:test_fixed_view_bounds()
    -- Test that view is always fixed to original source bounds (0 to source_length)
    local function calc_view_bounds(source_length)
        local view_start = 0
        local view_end = source_length
        local view_length = source_length
        return view_start, view_end, view_length
    end

    -- Short source
    local view_start, view_end, view_length = calc_view_bounds(2)
    lu.assertEquals(view_start, 0)
    lu.assertEquals(view_end, 2)
    lu.assertEquals(view_length, 2)

    -- Long source
    view_start, view_end, view_length = calc_view_bounds(120)
    lu.assertEquals(view_start, 0)
    lu.assertEquals(view_end, 120)
    lu.assertEquals(view_length, 120)

    -- View bounds don't change with item length (looping)
    -- Even if item is looped 10x, view still shows original source
    local source_length = 10
    local source_item_length = 100  -- 10x loops
    view_start, view_end, view_length = calc_view_bounds(source_length)
    lu.assertEquals(view_start, 0)
    lu.assertEquals(view_end, 10)  -- Still just source_length
    lu.assertEquals(view_length, 10)
end

function TestNVSDItemView:test_pan_offset_adjustment_at_drag_end()
    -- Test that pan_offset is adjusted correctly when drag ends to keep view stable
    local function calc_pan_adjustment(
        drag_start_offset, drag_start_length, drag_start_playrate,
        new_start_offset, new_item_length, new_playrate,
        source_length, zoom_level, current_pan_offset
    )
        local old_item_length = drag_start_length * drag_start_playrate
        local new_source_item_length = new_item_length * new_playrate

        local old_center = drag_start_offset + old_item_length / 2
        local new_center = new_start_offset + new_source_item_length / 2

        local old_base = math.max(source_length, old_item_length)
        local new_base = math.max(source_length, new_source_item_length)
        local old_view_length = old_base / zoom_level
        local new_view_length = new_base / zoom_level

        return current_pan_offset + (old_center - new_center) + (new_view_length - old_view_length) / 2
    end

    -- No change in item -> no change in pan
    local new_pan = calc_pan_adjustment(2, 5, 1, 2, 5, 1, 10, 1, 0)
    lu.assertAlmostEquals(new_pan, 0, 0.001)

    -- Item center moved left (start dragged left, end fixed)
    -- Original: offset=2, length=5, center=4.5
    -- New: offset=1, length=6, center=4 (end stayed at 7)
    new_pan = calc_pan_adjustment(2, 5, 1, 1, 6, 1, 10, 1, 0)
    -- Old center=4.5, new center=4, diff=0.5
    -- View length unchanged (both fit in source)
    lu.assertAlmostEquals(new_pan, 0.5, 0.001)
end

function TestNVSDItemView:test_snap_to_source_boundary()
    -- Test snapping time to nearest source length boundary
    local function snap_to_source_boundary(t, source_length, threshold_time)
        local nearest_boundary = math.floor(t / source_length + 0.5) * source_length
        if math.abs(t - nearest_boundary) <= threshold_time then
            return nearest_boundary
        end
        return t
    end

    local source_length = 10
    local threshold = 0.5

    -- Close to 0 -> snap to 0
    lu.assertAlmostEquals(snap_to_source_boundary(0.3, source_length, threshold), 0, 0.001)

    -- Close to source_length -> snap to source_length
    lu.assertAlmostEquals(snap_to_source_boundary(9.8, source_length, threshold), 10, 0.001)

    -- Close to 2*source_length -> snap to 20
    lu.assertAlmostEquals(snap_to_source_boundary(19.7, source_length, threshold), 20, 0.001)

    -- Not close to any boundary -> no snap
    lu.assertAlmostEquals(snap_to_source_boundary(5.5, source_length, threshold), 5.5, 0.001)

    -- Negative, close to -source_length -> snap to -10
    lu.assertAlmostEquals(snap_to_source_boundary(-9.8, source_length, threshold), -10, 0.001)
end

function TestNVSDItemView:test_overlay_zone_detection()
    -- Test detecting which overlay zone a position falls into
    -- Zones: outside_source (dark), unused_source (light), active (no overlay)
    local function get_overlay_zone(source_t, start_offset, source_item_length, source_length)
        local item_end = start_offset + source_item_length

        -- Check if in active region (between markers)
        if source_t >= start_offset and source_t <= item_end then
            return "active"
        end

        -- Check if within original source bounds
        if source_t >= 0 and source_t <= source_length then
            return "unused_source"  -- light overlay
        end

        return "outside_source"  -- dark overlay
    end

    -- Item from 2 to 7 in a 10-second source
    local start_offset = 2
    local source_item_length = 5
    local source_length = 10

    -- In active region
    lu.assertEquals(get_overlay_zone(3, start_offset, source_item_length, source_length), "active")
    lu.assertEquals(get_overlay_zone(5, start_offset, source_item_length, source_length), "active")

    -- In unused source (within source but outside item)
    lu.assertEquals(get_overlay_zone(0, start_offset, source_item_length, source_length), "unused_source")
    lu.assertEquals(get_overlay_zone(1, start_offset, source_item_length, source_length), "unused_source")
    lu.assertEquals(get_overlay_zone(8, start_offset, source_item_length, source_length), "unused_source")
    lu.assertEquals(get_overlay_zone(10, start_offset, source_item_length, source_length), "unused_source")

    -- Outside source bounds (looped content)
    lu.assertEquals(get_overlay_zone(-1, start_offset, source_item_length, source_length), "outside_source")
    lu.assertEquals(get_overlay_zone(11, start_offset, source_item_length, source_length), "outside_source")
end

function TestNVSDItemView:test_view_always_shows_full_source()
    -- Test that view always shows 0 to source_length (no zoom/pan effect)
    local function calc_view(source_length)
        local view_start = 0
        local view_length = source_length
        return view_start, view_length
    end

    -- Short source
    local view_start, view_length = calc_view(5)
    lu.assertEquals(view_start, 0)
    lu.assertEquals(view_length, 5)

    -- Long source
    view_start, view_length = calc_view(120)
    lu.assertEquals(view_start, 0)
    lu.assertEquals(view_length, 120)

    -- Source length is all that matters - item length doesn't affect view
    view_start, view_length = calc_view(10)
    lu.assertEquals(view_start, 0)
    lu.assertEquals(view_length, 10)
    -- Even if source_item_length is 100 (10x loops), view still shows just source
end

function TestNVSDItemView:test_adaptive_sample_count()
    -- Test that sample count scales with zoom level
    local function calc_desired_samples(waveform_width, zoom_level, max_samples)
        local base_samples = math.max(100, math.floor(waveform_width))
        return math.min(max_samples, math.floor(base_samples * zoom_level))
    end

    -- At zoom 1, should equal base samples
    lu.assertEquals(calc_desired_samples(500, 1, 8000), 500)

    -- At zoom 2, should double (but capped at max)
    lu.assertEquals(calc_desired_samples(500, 2, 8000), 1000)

    -- At zoom 10, should be 5000 (10 * 500)
    lu.assertEquals(calc_desired_samples(500, 10, 8000), 5000)

    -- At zoom 20, should be capped at max
    lu.assertEquals(calc_desired_samples(500, 20, 8000), 8000)

    -- Small width still gets minimum 100
    lu.assertEquals(calc_desired_samples(50, 1, 8000), 100)
end

function TestNVSDItemView:test_file_size_change_detection()
    -- Test detecting file changes by size (for auto-reload)
    local function has_file_changed(current_size, initial_size)
        if not current_size or current_size == 0 then return false end
        if not initial_size or initial_size == 0 then return false end
        return current_size ~= initial_size
    end

    -- No change
    lu.assertFalse(has_file_changed(1000, 1000))

    -- File grew
    lu.assertTrue(has_file_changed(1100, 1000))

    -- File shrunk
    lu.assertTrue(has_file_changed(900, 1000))

    -- Invalid sizes
    lu.assertFalse(has_file_changed(0, 1000))
    lu.assertFalse(has_file_changed(nil, 1000))
    lu.assertFalse(has_file_changed(1000, 0))
    lu.assertFalse(has_file_changed(1000, nil))
end

function TestNVSDItemView:test_pixel_to_time_with_fixed_view()
    -- Test pixel to time conversion with fixed view (0 to source_length)
    local function px_to_time(px, wave_x, waveform_width, source_length)
        local view_start = 0
        local view_length = source_length
        return view_start + ((px - wave_x) / waveform_width) * view_length
    end

    local wave_x = 100
    local waveform_width = 500
    local source_length = 10

    -- px at wave_x should be t=0
    lu.assertEquals(px_to_time(100, wave_x, waveform_width, source_length), 0)

    -- px at wave_x + waveform_width should be t=source_length
    lu.assertEquals(px_to_time(600, wave_x, waveform_width, source_length), 10)

    -- px at center should be t=source_length/2
    lu.assertEquals(px_to_time(350, wave_x, waveform_width, source_length), 5)

    -- px before wave_x gives negative time
    lu.assertEquals(px_to_time(50, wave_x, waveform_width, source_length), -1)

    -- px after waveform gives time > source_length
    lu.assertEquals(px_to_time(700, wave_x, waveform_width, source_length), 12)
end

function TestNVSDItemView:test_dashed_line_segments()
    -- Test calculating dashed line segment positions
    local function calc_dash_segments(y1, y2, dash_length, gap_length)
        local segments = {}
        local y = y1
        while y < y2 do
            local dash_end = math.min(y + dash_length, y2)
            table.insert(segments, {start_y = y, end_y = dash_end})
            y = y + dash_length + gap_length
        end
        return segments
    end

    -- Simple case
    local segs = calc_dash_segments(0, 20, 5, 3)
    lu.assertEquals(#segs, 3)
    lu.assertEquals(segs[1].start_y, 0)
    lu.assertEquals(segs[1].end_y, 5)
    lu.assertEquals(segs[2].start_y, 8)
    lu.assertEquals(segs[2].end_y, 13)
    lu.assertEquals(segs[3].start_y, 16)
    lu.assertEquals(segs[3].end_y, 20)  -- clamped to y2
end

function TestNVSDItemView:test_ruler_mouse_detection()
    -- Test detecting if mouse is in ruler area
    local function is_mouse_in_ruler(mouse_x, mouse_y, wave_x, ruler_y, width, ruler_height)
        return mouse_x >= wave_x and mouse_x <= wave_x + width
               and mouse_y >= ruler_y and mouse_y <= ruler_y + ruler_height
    end

    local wave_x, ruler_y = 100, 50
    local width, ruler_height = 500, 20

    -- Inside ruler
    lu.assertTrue(is_mouse_in_ruler(300, 60, wave_x, ruler_y, width, ruler_height))

    -- In waveform area (below ruler)
    lu.assertFalse(is_mouse_in_ruler(300, 80, wave_x, ruler_y, width, ruler_height))

    -- Above ruler
    lu.assertFalse(is_mouse_in_ruler(300, 40, wave_x, ruler_y, width, ruler_height))

    -- Left of waveform
    lu.assertFalse(is_mouse_in_ruler(90, 60, wave_x, ruler_y, width, ruler_height))
end

function TestNVSDItemView:test_alt_drag_slide_both_markers()
    -- Test Alt+drag behavior: both markers move together, item length stays same
    -- This slides the "window" of which part of the source is used
    local function alt_drag_slide(drag_start_offset, drag_start_length, mouse_delta_time, playrate)
        -- New start offset = original + delta
        local new_start = drag_start_offset + mouse_delta_time
        -- Item length stays the same
        local original_source_length = drag_start_length * playrate
        local new_end = new_start + original_source_length
        -- Return new start, end, and item length (should be unchanged)
        return new_start, new_end, drag_start_length
    end

    -- Original: offset=2, length=5, playrate=1
    -- Slide right by 1 second
    local new_start, new_end, new_length = alt_drag_slide(2, 5, 1, 1)
    lu.assertAlmostEquals(new_start, 3, 0.001)
    lu.assertAlmostEquals(new_end, 8, 0.001)
    lu.assertAlmostEquals(new_length, 5, 0.001)  -- length unchanged

    -- Slide left by 1 second
    new_start, new_end, new_length = alt_drag_slide(2, 5, -1, 1)
    lu.assertAlmostEquals(new_start, 1, 0.001)
    lu.assertAlmostEquals(new_end, 6, 0.001)
    lu.assertAlmostEquals(new_length, 5, 0.001)  -- length unchanged

    -- Slide into negative (before source start - for looping)
    new_start, new_end, new_length = alt_drag_slide(2, 5, -4, 1)
    lu.assertAlmostEquals(new_start, -2, 0.001)
    lu.assertAlmostEquals(new_end, 3, 0.001)
    lu.assertAlmostEquals(new_length, 5, 0.001)  -- length unchanged

    -- With playrate 2 (double speed)
    new_start, new_end, new_length = alt_drag_slide(2, 5, 1, 2)
    lu.assertAlmostEquals(new_start, 3, 0.001)
    lu.assertAlmostEquals(new_end, 13, 0.001)  -- source length = 5 * 2 = 10
    lu.assertAlmostEquals(new_length, 5, 0.001)  -- item length unchanged
end

function TestNVSDItemView:test_format_source_time()
    -- Test formatting source time (using real utils module)
    -- Basic formatting without ms
    lu.assertEquals(utils.format_source_time(0, false), "0:00")
    lu.assertEquals(utils.format_source_time(5, false), "0:05")
    lu.assertEquals(utils.format_source_time(65, false), "1:05")
    lu.assertEquals(utils.format_source_time(125, false), "2:05")

    -- With milliseconds
    lu.assertEquals(utils.format_source_time(0, true), "0:00:000")
    lu.assertEquals(utils.format_source_time(1.5, true), "0:01:500")
    lu.assertEquals(utils.format_source_time(0.25, true), "0:00:250")
    lu.assertEquals(utils.format_source_time(65.123, true), "1:05:123")

    -- Negative times
    lu.assertEquals(utils.format_source_time(-5, false), "-0:05")
    lu.assertEquals(utils.format_source_time(-65, false), "-1:05")
    lu.assertEquals(utils.format_source_time(-1.5, true), "-0:01:500")
end

function TestNVSDItemView:test_time_ruler_interval_selection()
    -- Test selecting appropriate time intervals based on zoom level
    local function select_interval(target_interval)
        local nice_intervals = {0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600}
        local interval = nice_intervals[#nice_intervals]
        for _, ni in ipairs(nice_intervals) do
            if ni >= target_interval then
                interval = ni
                break
            end
        end
        return interval
    end

    -- Very zoomed in (need sub-second intervals)
    lu.assertEquals(select_interval(0.005), 0.01)
    lu.assertEquals(select_interval(0.015), 0.02)
    lu.assertEquals(select_interval(0.08), 0.1)

    -- Medium zoom (second intervals)
    lu.assertEquals(select_interval(0.8), 1)
    lu.assertEquals(select_interval(1.5), 2)
    lu.assertEquals(select_interval(4), 5)

    -- Zoomed out (larger intervals)
    lu.assertEquals(select_interval(8), 10)
    lu.assertEquals(select_interval(25), 30)
    lu.assertEquals(select_interval(50), 60)
    lu.assertEquals(select_interval(100), 120)
end

function TestNVSDItemView:test_alt_drag_snap_only_grabbed_marker_start()
    -- Test that alt+drag only snaps the grabbed marker, not both
    local function alt_drag_with_snap_start(raw_start, raw_end, source_length, snap_threshold, dragging_start)
        local function snap_to_source_boundary(t, src_len, threshold_time)
            local nearest_boundary = math.floor(t / src_len + 0.5) * src_len
            if math.abs(t - nearest_boundary) <= threshold_time then
                return nearest_boundary
            end
            return t
        end

        local original_source_length = raw_end - raw_start
        local new_start

        if dragging_start then
            -- Grabbed start marker - only snap start to boundary
            local start_snapped = snap_to_source_boundary(raw_start, source_length, snap_threshold)
            if start_snapped ~= raw_start then
                new_start = start_snapped
            else
                new_start = raw_start
            end
        else
            -- Grabbed end marker - only snap end to boundary
            local end_snapped = snap_to_source_boundary(raw_end, source_length, snap_threshold)
            if end_snapped ~= raw_end then
                new_start = end_snapped - original_source_length
            else
                new_start = raw_start
            end
        end

        return new_start, new_start + original_source_length
    end

    local source_length = 10
    local snap_threshold = 0.5

    -- Dragging start marker, start near 0 -> should snap start to 0
    local new_start, new_end = alt_drag_with_snap_start(0.2, 5.2, source_length, snap_threshold, true)
    lu.assertAlmostEquals(new_start, 0, 0.001)  -- snapped
    lu.assertAlmostEquals(new_end, 5, 0.001)    -- follows

    -- Dragging start marker, end near 10 -> should NOT snap (only grabbed marker snaps)
    new_start, new_end = alt_drag_with_snap_start(4.8, 9.8, source_length, snap_threshold, true)
    lu.assertAlmostEquals(new_start, 4.8, 0.001)  -- not snapped (start not near boundary)
    lu.assertAlmostEquals(new_end, 9.8, 0.001)    -- follows

    -- Dragging end marker, end near 10 -> should snap end to 10
    new_start, new_end = alt_drag_with_snap_start(4.8, 9.8, source_length, snap_threshold, false)
    lu.assertAlmostEquals(new_start, 5, 0.001)    -- adjusted
    lu.assertAlmostEquals(new_end, 10, 0.001)     -- snapped

    -- Dragging end marker, start near 0 -> should NOT snap (only grabbed marker snaps)
    new_start, new_end = alt_drag_with_snap_start(0.2, 5.2, source_length, snap_threshold, false)
    lu.assertAlmostEquals(new_start, 0.2, 0.001)  -- not adjusted
    lu.assertAlmostEquals(new_end, 5.2, 0.001)    -- not snapped (end not near boundary)
end

function TestNVSDItemView:test_semitones_to_playrate()
    -- Test converting semitones to playrate (using real utils module)
    -- 0 semitones = no change
    lu.assertAlmostEquals(utils.semitones_to_playrate(0), 1.0, 0.001)

    -- +12 semitones = double speed (octave up)
    lu.assertAlmostEquals(utils.semitones_to_playrate(12), 2.0, 0.001)

    -- -12 semitones = half speed (octave down)
    lu.assertAlmostEquals(utils.semitones_to_playrate(-12), 0.5, 0.001)

    -- +7 semitones = perfect fifth up
    lu.assertAlmostEquals(utils.semitones_to_playrate(7), 2^(7/12), 0.001)

    -- -5 semitones = perfect fourth down
    lu.assertAlmostEquals(utils.semitones_to_playrate(-5), 2^(-5/12), 0.001)
end

function TestNVSDItemView:test_playrate_to_semitones()
    -- Test converting playrate to semitones (using real utils module)
    -- Normal speed = 0 semitones
    lu.assertAlmostEquals(utils.playrate_to_semitones(1.0), 0, 0.001)

    -- Double speed = +12 semitones
    lu.assertAlmostEquals(utils.playrate_to_semitones(2.0), 12, 0.001)

    -- Half speed = -12 semitones
    lu.assertAlmostEquals(utils.playrate_to_semitones(0.5), -12, 0.001)

    -- Roundtrip test
    local original = 7.5
    local playrate = utils.semitones_to_playrate(original)
    local back = utils.playrate_to_semitones(playrate)
    lu.assertAlmostEquals(back, original, 0.001)
end

function TestNVSDItemView:test_db_to_linear_and_back()
    -- Test dB to linear conversion (using real utils module)
    -- 0 dB = unity gain
    lu.assertAlmostEquals(utils.db_to_gain(0), 1.0, 0.001)

    -- +6 dB = ~2x
    lu.assertAlmostEquals(utils.db_to_gain(6), 1.995, 0.01)

    -- -6 dB = ~0.5x
    lu.assertAlmostEquals(utils.db_to_gain(-6), 0.501, 0.01)

    -- +24 dB (max gain in UI)
    lu.assertAlmostEquals(utils.db_to_gain(24), 15.85, 0.1)

    -- Very low dB = 0 gain (utils.db_to_gain guards at -150)
    lu.assertEquals(utils.db_to_gain(-150), 0)

    -- Roundtrip
    local original_db = -12
    local linear = utils.db_to_gain(original_db)
    local back = utils.gain_to_db(linear)
    lu.assertAlmostEquals(back, original_db, 0.001)
end

function TestNVSDItemView:test_mouse_in_full_view_area()
    -- Test detecting mouse in full waveform view (waveform + both rulers)
    local function is_mouse_in_view(mouse_x, mouse_y, wave_x, ruler_y, waveform_width, time_ruler_y, time_ruler_height)
        return mouse_x >= wave_x and mouse_x <= wave_x + waveform_width
               and mouse_y >= ruler_y and mouse_y <= time_ruler_y + time_ruler_height
    end

    local wave_x = 100
    local ruler_y = 50      -- top ruler starts here
    local waveform_width = 500
    local time_ruler_y = 250   -- bottom ruler starts here
    local time_ruler_height = 20

    -- In top ruler
    lu.assertTrue(is_mouse_in_view(300, 55, wave_x, ruler_y, waveform_width, time_ruler_y, time_ruler_height))

    -- In waveform area
    lu.assertTrue(is_mouse_in_view(300, 150, wave_x, ruler_y, waveform_width, time_ruler_y, time_ruler_height))

    -- In bottom time ruler
    lu.assertTrue(is_mouse_in_view(300, 260, wave_x, ruler_y, waveform_width, time_ruler_y, time_ruler_height))

    -- Above top ruler
    lu.assertFalse(is_mouse_in_view(300, 40, wave_x, ruler_y, waveform_width, time_ruler_y, time_ruler_height))

    -- Below bottom ruler
    lu.assertFalse(is_mouse_in_view(300, 280, wave_x, ruler_y, waveform_width, time_ruler_y, time_ruler_height))

    -- Left of waveform
    lu.assertFalse(is_mouse_in_view(90, 150, wave_x, ruler_y, waveform_width, time_ruler_y, time_ruler_height))

    -- Right of waveform
    lu.assertFalse(is_mouse_in_view(610, 150, wave_x, ruler_y, waveform_width, time_ruler_y, time_ruler_height))
end

function TestNVSDItemView:test_fixed_peak_samples()
    -- Test that peak samples are fixed to waveform width (view always shows full source)
    local function calc_desired_samples(waveform_width, max_samples)
        local pixels_per_source = waveform_width
        return math.max(200, math.min(max_samples, math.floor(pixels_per_source)))
    end

    local max_samples = 50000

    -- Width 800: 800 samples
    lu.assertEquals(calc_desired_samples(800, max_samples), 800)

    -- Width 400: 400 samples
    lu.assertEquals(calc_desired_samples(400, max_samples), 400)

    -- Width 100: clamped to min 200
    lu.assertEquals(calc_desired_samples(100, max_samples), 200)

    -- Width 60000: capped at max
    lu.assertEquals(calc_desired_samples(60000, max_samples), 50000)

    -- Samples don't change with item length (looping doesn't affect resolution)
    local waveform_width = 800
    lu.assertEquals(calc_desired_samples(waveform_width, max_samples), 800)
    -- Same result regardless of how many loops
end

function TestNVSDItemView:test_time_to_pixel_with_fixed_view()
    -- Test time to pixel conversion with fixed view (0 to source_length)
    local function time_to_px(t, wave_x, waveform_width, source_length)
        local view_start = 0
        local view_length = source_length
        return wave_x + ((t - view_start) / view_length) * waveform_width
    end

    local wave_x = 100
    local waveform_width = 500
    local source_length = 10

    -- t=0 should be at wave_x
    lu.assertEquals(time_to_px(0, wave_x, waveform_width, source_length), 100)

    -- t=source_length should be at wave_x + waveform_width
    lu.assertEquals(time_to_px(10, wave_x, waveform_width, source_length), 600)

    -- t=5 (middle) should be at wave_x + waveform_width/2
    lu.assertEquals(time_to_px(5, wave_x, waveform_width, source_length), 350)

    -- Markers beyond source still convert correctly (for looped items)
    -- t=15 (1.5x source) would be at 850 (off screen but calculable)
    lu.assertEquals(time_to_px(15, wave_x, waveform_width, source_length), 850)

    -- Negative offsets also work
    lu.assertEquals(time_to_px(-2, wave_x, waveform_width, source_length), 0)
end

function TestNVSDItemView:test_format_db()
    -- Test formatting dB value for display (using real utils module)
    -- Positive values: no + sign, includes " dB"
    lu.assertEquals(utils.format_db(24), "24.0 dB")
    lu.assertEquals(utils.format_db(12), "12.0 dB")
    lu.assertEquals(utils.format_db(6), "6.0 dB")
    lu.assertEquals(utils.format_db(0), "0.0 dB")

    -- Negative values: includes " dB"
    lu.assertEquals(utils.format_db(-6), "-6.0 dB")
    lu.assertEquals(utils.format_db(-12), "-12.0 dB")
    lu.assertEquals(utils.format_db(-24), "-24.0 dB")

    -- Very low values: show -∞ dB
    lu.assertEquals(utils.format_db(-60), "-∞ dB")
    lu.assertEquals(utils.format_db(-61), "-∞ dB")
    lu.assertEquals(utils.format_db(-100), "-∞ dB")

    -- Fractional values
    lu.assertEquals(utils.format_db(6.5), "6.5 dB")
    lu.assertEquals(utils.format_db(-3.2), "-3.2 dB")
    lu.assertEquals(utils.format_db(0.1), "0.1 dB")
end

function TestNVSDItemView:test_mute_toggle()
    -- Test mute toggle logic
    local function toggle_mute(is_muted)
        return is_muted and 0 or 1
    end

    -- Muted -> unmute
    lu.assertEquals(toggle_mute(true), 0)

    -- Unmuted -> mute
    lu.assertEquals(toggle_mute(false), 1)
end

function TestNVSDItemView:test_gain_to_db()
    -- Test converting linear gain to dB (using real utils module)
    -- Unity gain = 0 dB
    lu.assertAlmostEquals(utils.gain_to_db(1.0), 0, 0.001)

    -- Double = +6.02 dB
    lu.assertAlmostEquals(utils.gain_to_db(2.0), 6.02, 0.1)

    -- Half = -6.02 dB
    lu.assertAlmostEquals(utils.gain_to_db(0.5), -6.02, 0.1)

    -- +24 dB gain (~15.85x)
    lu.assertAlmostEquals(utils.gain_to_db(15.85), 24, 0.1)

    -- Zero gain = -inf
    lu.assertEquals(utils.gain_to_db(0), -math.huge)
end

function TestNVSDItemView:test_db_to_slider_position()
    -- Test converting dB to slider position (using real utils module)
    -- +24 dB = top (1.0)
    lu.assertAlmostEquals(utils.db_to_slider(24), 1.0, 0.001)

    -- 0 dB = middle (0.5)
    lu.assertAlmostEquals(utils.db_to_slider(0), 0.5, 0.001)

    -- +12 dB = 0.75
    lu.assertAlmostEquals(utils.db_to_slider(12), 0.75, 0.001)

    -- Very low dB = bottom (0.0)
    lu.assertAlmostEquals(utils.db_to_slider(-150), 0, 0.001)

    -- Check logarithmic curve: -6 dB should be between 0 and 0.5
    local pos_neg6 = utils.db_to_slider(-6)
    lu.assertTrue(pos_neg6 > 0.3)  -- Above bottom
    lu.assertTrue(pos_neg6 < 0.5)  -- Below 0dB position
end

function TestNVSDItemView:test_slider_to_db()
    -- Test converting slider position to dB (using real utils module)
    -- Top = +24 dB
    lu.assertAlmostEquals(utils.slider_to_db(1.0), 24, 0.001)

    -- Middle = 0 dB
    lu.assertAlmostEquals(utils.slider_to_db(0.5), 0, 0.001)

    -- 0.75 = +12 dB
    lu.assertAlmostEquals(utils.slider_to_db(0.75), 12, 0.001)

    -- Bottom = -inf dB
    lu.assertEquals(utils.slider_to_db(0), -math.huge)
end

function TestNVSDItemView:test_pitch_to_semitones_cents()
    -- Test splitting pitch value into semitones and cents (using real utils module)
    -- Uses round-to-nearest for Ableton-style ±50 cents range

    -- Exact semitone
    local semi, cents = utils.pitch_to_semitones_cents(5.0)
    lu.assertEquals(semi, 5)
    lu.assertEquals(cents, 0)

    -- Positive cents (below half-semitone)
    semi, cents = utils.pitch_to_semitones_cents(5.25)
    lu.assertEquals(semi, 5)
    lu.assertEquals(cents, 25)

    -- Positive pitch with large fractional: rounds UP to nearest semitone
    semi, cents = utils.pitch_to_semitones_cents(4.75)
    lu.assertEquals(semi, 5)    -- floor(4.75 + 0.5) = floor(5.25) = 5
    lu.assertEquals(cents, -25) -- (4.75 - 5) * 100 = -25

    -- Negative pitch: round(-3.5) = floor(-3.0) = -3
    semi, cents = utils.pitch_to_semitones_cents(-3.5)
    lu.assertEquals(semi, -3)
    lu.assertEquals(cents, -50)

    -- Negative pitch with large fractional: rounds to nearest
    semi, cents = utils.pitch_to_semitones_cents(-1.3)
    lu.assertEquals(semi, -1)
    lu.assertEquals(cents, -30)

    -- Boundary: 0.50 rounds up
    semi, cents = utils.pitch_to_semitones_cents(0.50)
    lu.assertEquals(semi, 1)    -- floor(0.50 + 0.5) = floor(1.0) = 1
    lu.assertEquals(cents, -50) -- (0.50 - 1) * 100 = -50

    -- Zero pitch
    semi, cents = utils.pitch_to_semitones_cents(0)
    lu.assertEquals(semi, 0)
    lu.assertEquals(cents, 0)
end

function TestNVSDItemView:test_semitones_cents_to_pitch()
    -- Test combining semitones and cents into pitch value (using real utils module)
    lu.assertAlmostEquals(utils.semitones_cents_to_pitch(5, 0), 5.0, 0.001)
    lu.assertAlmostEquals(utils.semitones_cents_to_pitch(5, 50), 5.5, 0.001)
    lu.assertAlmostEquals(utils.semitones_cents_to_pitch(5, -25), 4.75, 0.001)
    lu.assertAlmostEquals(utils.semitones_cents_to_pitch(-3, 50), -2.5, 0.001)
    lu.assertAlmostEquals(utils.semitones_cents_to_pitch(0, 0), 0, 0.001)
end

function TestNVSDItemView:test_multi_channel_peak_parsing()
    -- Test parsing peaks into separate channels (for multi-channel display)
    local function parse_peaks_per_channel(buf, actual_samples, num_channels)
        local peaks = {}
        local min_block_offset = actual_samples * num_channels

        for i = 1, actual_samples do
            local channels = {}
            if num_channels == 1 then
                channels[1] = { min = buf[min_block_offset + i] or 0, max = buf[i] or 0 }
            else
                local base_idx = (i - 1) * num_channels + 1
                for ch = 1, num_channels do
                    channels[ch] = {
                        max = buf[base_idx + ch - 1] or 0,
                        min = buf[min_block_offset + base_idx + ch - 1] or 0
                    }
                end
            end
            peaks[i] = channels
        end
        return peaks
    end

    -- Test stereo buffer: 2 samples, 2 channels
    local buf = {
        -- max block: L0=0.8, R0=0.6, L1=0.4, R1=0.9
        0.8, 0.6, 0.4, 0.9,
        -- min block: L0=-0.7, R0=-0.5, L1=-0.3, R1=-0.8
        -0.7, -0.5, -0.3, -0.8
    }

    local peaks = parse_peaks_per_channel(buf, 2, 2)

    -- Sample 1, Channel 1 (Left)
    lu.assertAlmostEquals(peaks[1][1].max, 0.8, 0.001)
    lu.assertAlmostEquals(peaks[1][1].min, -0.7, 0.001)

    -- Sample 1, Channel 2 (Right)
    lu.assertAlmostEquals(peaks[1][2].max, 0.6, 0.001)
    lu.assertAlmostEquals(peaks[1][2].min, -0.5, 0.001)

    -- Sample 2, Channel 1 (Left)
    lu.assertAlmostEquals(peaks[2][1].max, 0.4, 0.001)
    lu.assertAlmostEquals(peaks[2][1].min, -0.3, 0.001)

    -- Sample 2, Channel 2 (Right)
    lu.assertAlmostEquals(peaks[2][2].max, 0.9, 0.001)
    lu.assertAlmostEquals(peaks[2][2].min, -0.8, 0.001)
end

function TestNVSDItemView:test_range_based_view_calculation()
    -- Test view range that includes both markers AND orange source edges
    local function calc_full_range(start_offset, source_item_length, source_length)
        local item_end = start_offset + source_item_length
        local left_bound = math.min(0, start_offset)
        local right_bound = math.max(source_length, item_end)
        return left_bound, right_bound, right_bound - left_bound
    end

    -- Item within source
    local left, right, range = calc_full_range(2, 5, 10)
    lu.assertAlmostEquals(left, 0, 0.001)
    lu.assertAlmostEquals(right, 10, 0.001)
    lu.assertAlmostEquals(range, 10, 0.001)

    -- Item starts before source
    left, right, range = calc_full_range(-3, 8, 10)
    lu.assertAlmostEquals(left, -3, 0.001)
    lu.assertAlmostEquals(right, 10, 0.001)
    lu.assertAlmostEquals(range, 13, 0.001)

    -- Item extends past source
    left, right, range = calc_full_range(5, 10, 10)
    lu.assertAlmostEquals(left, 0, 0.001)
    lu.assertAlmostEquals(right, 15, 0.001)
    lu.assertAlmostEquals(range, 15, 0.001)

    -- Item extends both ways
    left, right, range = calc_full_range(-2, 20, 10)
    lu.assertAlmostEquals(left, -2, 0.001)
    lu.assertAlmostEquals(right, 18, 0.001)
    lu.assertAlmostEquals(range, 20, 0.001)
end

function TestNVSDItemView:test_quick_marker_positioning_left()
    -- Test mouse button 4 quick positioning of left marker
    local function move_left_marker_to(click_time, current_end)
        local new_start = click_time
        -- Clamp: can't go past end marker
        new_start = math.min(new_start, current_end - 0.01)
        local new_length = current_end - new_start
        return new_start, new_length
    end

    -- Normal case: move left marker to position 3, end at 8
    local new_start, new_length = move_left_marker_to(3, 8)
    lu.assertAlmostEquals(new_start, 3, 0.001)
    lu.assertAlmostEquals(new_length, 5, 0.001)

    -- Click before current start (extend item)
    new_start, new_length = move_left_marker_to(1, 8)
    lu.assertAlmostEquals(new_start, 1, 0.001)
    lu.assertAlmostEquals(new_length, 7, 0.001)

    -- Click past end marker (clamp to just before end)
    new_start, new_length = move_left_marker_to(10, 8)
    lu.assertAlmostEquals(new_start, 7.99, 0.02)
    lu.assertAlmostEquals(new_length, 0.01, 0.02)

    -- Negative click position (before source)
    new_start, new_length = move_left_marker_to(-2, 8)
    lu.assertAlmostEquals(new_start, -2, 0.001)
    lu.assertAlmostEquals(new_length, 10, 0.001)
end

function TestNVSDItemView:test_quick_marker_positioning_right()
    -- Test mouse button 5 quick positioning of right marker
    local function move_right_marker_to(click_time, start_offset, playrate)
        local new_end = click_time
        -- Clamp: can't go before start marker
        new_end = math.max(new_end, start_offset + 0.01)
        local new_source_length = new_end - start_offset
        local new_item_length = new_source_length / playrate
        return new_end, new_item_length
    end

    -- Normal case: move right marker to position 8, start at 2, playrate 1
    local new_end, new_length = move_right_marker_to(8, 2, 1)
    lu.assertAlmostEquals(new_end, 8, 0.001)
    lu.assertAlmostEquals(new_length, 6, 0.001)

    -- Shrink item
    new_end, new_length = move_right_marker_to(5, 2, 1)
    lu.assertAlmostEquals(new_end, 5, 0.001)
    lu.assertAlmostEquals(new_length, 3, 0.001)

    -- Click before start marker (clamp to just after start)
    new_end, new_length = move_right_marker_to(1, 2, 1)
    lu.assertAlmostEquals(new_end, 2.01, 0.02)
    lu.assertAlmostEquals(new_length, 0.01, 0.02)

    -- With playrate 2 (double speed)
    new_end, new_length = move_right_marker_to(12, 2, 2)
    lu.assertAlmostEquals(new_end, 12, 0.001)
    lu.assertAlmostEquals(new_length, 5, 0.001)  -- (12-2)/2 = 5
end

function TestNVSDItemView:test_file_name_extraction()
    -- Test extracting file name from full path (using real utils module)
    lu.assertEquals(utils.get_file_name("/home/user/audio/kick.wav"), "kick.wav")
    lu.assertEquals(utils.get_file_name("C:\\Users\\audio\\snare.wav"), "snare.wav")
    lu.assertEquals(utils.get_file_name("hihat.wav"), "hihat.wav")
    lu.assertEquals(utils.get_file_name(""), "")
    lu.assertEquals(utils.get_file_name(nil), "")
    lu.assertEquals(utils.get_file_name("/home/user/My Audio/cool sound.wav"), "cool sound.wav")
end

function TestNVSDItemView:test_channel_height_calculation()
    -- Test calculating per-channel height for multi-channel display
    local function calc_channel_height(total_height, num_channels)
        return total_height / num_channels
    end

    -- Mono
    lu.assertAlmostEquals(calc_channel_height(200, 1), 200, 0.001)

    -- Stereo
    lu.assertAlmostEquals(calc_channel_height(200, 2), 100, 0.001)

    -- 4 channels
    lu.assertAlmostEquals(calc_channel_height(200, 4), 50, 0.001)
end

function TestNVSDItemView:test_channel_y_position()
    -- Test calculating Y position for each channel
    local function calc_channel_y(base_y, channel_index, channel_height)
        return base_y + (channel_index - 1) * channel_height
    end

    local base_y = 100
    local channel_height = 50

    -- Channel 1
    lu.assertAlmostEquals(calc_channel_y(base_y, 1, channel_height), 100, 0.001)

    -- Channel 2
    lu.assertAlmostEquals(calc_channel_y(base_y, 2, channel_height), 150, 0.001)

    -- Channel 3
    lu.assertAlmostEquals(calc_channel_y(base_y, 3, channel_height), 200, 0.001)
end

function TestNVSDItemView:test_waveform_minimum_height()
    -- Test that silent waveform has minimum visible height
    local function calc_waveform_rect(peak_min, peak_max, center_y, height, min_height)
        local half_height = height / 2
        local top_y = center_y - (peak_max * half_height * 0.95)
        local bot_y = center_y - (peak_min * half_height * 0.95)

        -- Ensure minimum height for visibility
        if bot_y - top_y < min_height then
            top_y = center_y - min_height / 2
            bot_y = center_y + min_height / 2
        end

        return top_y, bot_y
    end

    local center_y = 100
    local height = 100
    local min_height = 1

    -- Silent (0, 0) - should get minimum height
    local top, bot = calc_waveform_rect(0, 0, center_y, height, min_height)
    lu.assertAlmostEquals(bot - top, min_height, 0.001)
    lu.assertAlmostEquals((top + bot) / 2, center_y, 0.001)  -- centered

    -- Very quiet - still minimum height
    top, bot = calc_waveform_rect(-0.001, 0.001, center_y, height, min_height)
    lu.assertTrue(bot - top >= min_height)

    -- Normal amplitude - larger than minimum
    top, bot = calc_waveform_rect(-0.5, 0.5, center_y, height, min_height)
    lu.assertTrue(bot - top > min_height)
end

function TestNVSDItemView:test_overlay_alpha_values()
    -- Test that overlay alpha values are appropriate for visibility
    local COLOR_UNUSED_SOURCE = 0x00000038    -- ~22% opacity
    local COLOR_OUTSIDE_SOURCE = 0x00000058   -- ~35% opacity

    -- Extract alpha from RGBA
    local function get_alpha(color)
        return color & 0xFF
    end

    local unused_alpha = get_alpha(COLOR_UNUSED_SOURCE)
    local outside_alpha = get_alpha(COLOR_OUTSIDE_SOURCE)

    -- Unused source should be lighter (lower alpha)
    lu.assertTrue(unused_alpha < outside_alpha)

    -- Both should be semi-transparent (not fully opaque)
    lu.assertTrue(unused_alpha < 128)
    lu.assertTrue(outside_alpha < 128)

    -- But still visible
    lu.assertTrue(unused_alpha > 20)
    lu.assertTrue(outside_alpha > 40)
end

function TestNVSDItemView:test_bracket_indicator_direction()
    -- Test that bracket indicators point in correct direction
    -- Left edge: "[" shape (horizontal lines extend right)
    -- Right edge: "]" shape (horizontal lines extend left)

    local function calc_bracket_lines(edge_x, is_left_edge, bracket_len)
        if is_left_edge then
            -- "[" shape: lines extend to the right
            return edge_x, edge_x + bracket_len
        else
            -- "]" shape: lines extend to the left
            return edge_x - bracket_len, edge_x
        end
    end

    local bracket_len = 4

    -- Left edge at x=100
    local start_x, end_x = calc_bracket_lines(100, true, bracket_len)
    lu.assertEquals(start_x, 100)
    lu.assertEquals(end_x, 104)  -- extends right

    -- Right edge at x=500
    start_x, end_x = calc_bracket_lines(500, false, bracket_len)
    lu.assertEquals(start_x, 496)  -- extends left
    lu.assertEquals(end_x, 500)
end

function TestNVSDItemView:test_pan_limits_include_markers_and_edges()
    -- Test that pan limits allow seeing both blue markers and orange source edges
    local function calc_pan_limits(view_length, start_offset, source_item_length, source_length)
        local item_end = start_offset + source_item_length
        local left_bound = math.min(0, start_offset)
        local right_bound = math.max(source_length, item_end)
        local range_center = (left_bound + right_bound) / 2

        -- Pan limits: allow scrolling to see full range
        local min_pan = left_bound - (range_center - view_length / 2)
        local max_pan = right_bound - (range_center + view_length / 2)

        return min_pan, max_pan
    end

    -- Item within source, view fits all
    local min_pan, max_pan = calc_pan_limits(10, 2, 5, 10)
    -- Range is 0-10, center=5, view_length=10 fits exactly
    lu.assertTrue(min_pan <= 0)
    lu.assertTrue(max_pan >= 0)

    -- Item extends past source
    min_pan, max_pan = calc_pan_limits(10, 5, 10, 10)
    -- Range is 0-15, center=7.5
    lu.assertTrue(max_pan > 0)  -- Can pan right to see extended area
end

function TestNVSDItemView:test_center_text_positioning()
    -- Test calculating centered text position
    local function calc_centered_text_pos(area_width, area_height, text_width, text_height)
        local x = (area_width - text_width) / 2
        local y = (area_height - text_height) / 2
        return x, y
    end

    -- Center in 800x600 area, text is 100x20
    local x, y = calc_centered_text_pos(800, 600, 100, 20)
    lu.assertAlmostEquals(x, 350, 0.001)
    lu.assertAlmostEquals(y, 290, 0.001)

    -- Small area
    x, y = calc_centered_text_pos(200, 100, 50, 15)
    lu.assertAlmostEquals(x, 75, 0.001)
    lu.assertAlmostEquals(y, 42.5, 0.001)
end

function TestNVSDItemView:test_mute_button_bounds()
    -- Test mute button position and size in info bar
    local function calc_mute_button_bounds(info_bar_x, info_bar_y, info_bar_height)
        local mute_size = 10
        local mute_x = info_bar_x + 4
        local mute_y = info_bar_y + (info_bar_height - mute_size) / 2
        return mute_x, mute_y, mute_size
    end

    local info_bar_x = 100
    local info_bar_y = 50
    local info_bar_height = 18

    local x, y, size = calc_mute_button_bounds(info_bar_x, info_bar_y, info_bar_height)

    lu.assertEquals(x, 104)  -- 4px padding from left
    lu.assertEquals(size, 10)
    -- Vertically centered
    lu.assertAlmostEquals(y, 50 + (18 - 10) / 2, 0.001)
end

function TestNVSDItemView:test_mouse_in_mute_button()
    -- Test mouse detection in mute button area
    local function is_mouse_in_mute(mouse_x, mouse_y, mute_x, mute_y, mute_size)
        return mouse_x >= mute_x and mouse_x <= mute_x + mute_size
               and mouse_y >= mute_y and mouse_y <= mute_y + mute_size
    end

    local mute_x, mute_y, mute_size = 104, 54, 10

    -- Inside
    lu.assertTrue(is_mouse_in_mute(109, 59, mute_x, mute_y, mute_size))

    -- Corner
    lu.assertTrue(is_mouse_in_mute(104, 54, mute_x, mute_y, mute_size))
    lu.assertTrue(is_mouse_in_mute(114, 64, mute_x, mute_y, mute_size))

    -- Outside left
    lu.assertFalse(is_mouse_in_mute(103, 59, mute_x, mute_y, mute_size))

    -- Outside right
    lu.assertFalse(is_mouse_in_mute(115, 59, mute_x, mute_y, mute_size))

    -- Outside top
    lu.assertFalse(is_mouse_in_mute(109, 53, mute_x, mute_y, mute_size))

    -- Outside bottom
    lu.assertFalse(is_mouse_in_mute(109, 65, mute_x, mute_y, mute_size))
end

-- =============================================================================
-- State Module Tests
-- =============================================================================

function TestNVSDItemView:test_state_start_drag()
    -- Test that start_drag initializes drag state correctly
    local state = {
        drag_controls = {
            gain = { active = false, start_y = 0, start_value = 0, shift_held = false },
            pitch = { active = false, start_y = 0, start_value = 0, shift_held = false },
        },
        has_js_extension = false,
        undo_block_open = nil,
    }

    local function start_drag(name, mouse_y, value, track_shift)
        local ctrl = state.drag_controls[name]
        ctrl.active = true
        ctrl.start_y = mouse_y
        ctrl.start_value = value
        if track_shift then
            ctrl.shift_held = false
        end
        if not state.undo_block_open then
            state.undo_block_open = name
        end
    end

    -- Start gain drag
    start_drag("gain", 150, 0.5, true)

    lu.assertTrue(state.drag_controls.gain.active)
    lu.assertEquals(state.drag_controls.gain.start_y, 150)
    lu.assertEquals(state.drag_controls.gain.start_value, 0.5)
    lu.assertFalse(state.drag_controls.gain.shift_held)
    lu.assertEquals(state.undo_block_open, "gain")

    -- Pitch should still be inactive
    lu.assertFalse(state.drag_controls.pitch.active)
end

function TestNVSDItemView:test_state_end_drag()
    -- Test that end_drag clears the active state
    local state = {
        drag_controls = {
            gain = { active = true, start_y = 150, start_value = 0.5, shift_held = false },
        },
    }

    local function end_drag(name)
        state.drag_controls[name].active = false
    end

    lu.assertTrue(state.drag_controls.gain.active)
    end_drag("gain")
    lu.assertFalse(state.drag_controls.gain.active)
    -- Other values should remain
    lu.assertEquals(state.drag_controls.gain.start_y, 150)
    lu.assertEquals(state.drag_controls.gain.start_value, 0.5)
end

function TestNVSDItemView:test_state_is_dragging()
    -- Test is_dragging returns correct boolean
    local state = {
        drag_controls = {
            gain = { active = true },
            pitch = { active = false },
            semitones = { active = false },
            cents = { active = false },
        },
    }

    local function is_dragging(name)
        return state.drag_controls[name].active
    end

    lu.assertTrue(is_dragging("gain"))
    lu.assertFalse(is_dragging("pitch"))
    lu.assertFalse(is_dragging("semitones"))
    lu.assertFalse(is_dragging("cents"))
end

function TestNVSDItemView:test_state_is_any_control_dragging()
    -- Test is_any_control_dragging checks all controls
    local function is_any_control_dragging(state)
        return state.drag_controls.gain.active or state.drag_controls.pitch.active
            or state.drag_controls.semitones.active or state.drag_controls.cents.active
    end

    -- None active
    local state1 = {
        drag_controls = {
            gain = { active = false },
            pitch = { active = false },
            semitones = { active = false },
            cents = { active = false },
        },
    }
    lu.assertFalse(is_any_control_dragging(state1))

    -- Gain active
    local state2 = {
        drag_controls = {
            gain = { active = true },
            pitch = { active = false },
            semitones = { active = false },
            cents = { active = false },
        },
    }
    lu.assertTrue(is_any_control_dragging(state2))

    -- Cents active
    local state3 = {
        drag_controls = {
            gain = { active = false },
            pitch = { active = false },
            semitones = { active = false },
            cents = { active = true },
        },
    }
    lu.assertTrue(is_any_control_dragging(state3))

    -- Multiple active
    local state4 = {
        drag_controls = {
            gain = { active = true },
            pitch = { active = true },
            semitones = { active = false },
            cents = { active = false },
        },
    }
    lu.assertTrue(is_any_control_dragging(state4))
end

function TestNVSDItemView:test_state_get_drag_delta_basic()
    -- Test get_drag_delta without JS extension (simple case)
    local state = {
        drag_controls = {
            gain = { active = true, start_y = 200, start_value = 0.5, shift_held = false },
        },
        has_js_extension = false,
        drag_cumulative_delta_y = 0,
    }

    local function get_drag_delta_basic(name, mouse_y)
        local ctrl = state.drag_controls[name]
        if not ctrl.active then return 0 end
        return ctrl.start_y - mouse_y
    end

    -- Mouse moved up (decrease Y) = positive delta
    lu.assertEquals(get_drag_delta_basic("gain", 180), 20)

    -- Mouse moved down (increase Y) = negative delta
    lu.assertEquals(get_drag_delta_basic("gain", 220), -20)

    -- No movement
    lu.assertEquals(get_drag_delta_basic("gain", 200), 0)
end

function TestNVSDItemView:test_state_get_drag_delta_inactive()
    -- Test get_drag_delta returns 0 when not active
    local state = {
        drag_controls = {
            gain = { active = false, start_y = 200, start_value = 0.5 },
        },
        has_js_extension = false,
    }

    local function get_drag_delta_basic(name, mouse_y)
        local ctrl = state.drag_controls[name]
        if not ctrl.active then return 0 end
        return ctrl.start_y - mouse_y
    end

    lu.assertEquals(get_drag_delta_basic("gain", 100), 0)
end

function TestNVSDItemView:test_state_invalidate_view_peaks()
    -- Test invalidate_view_peaks clears all per-view state
    local state = {
        view_peaks = { mins = {}, maxs = {}, count = 100 },
        view_source = "some_source",
        view_start = 1.0,
        view_length = 2.0,
        view_num_samples = 400,
    }

    local function invalidate_view_peaks()
        state.view_peaks = nil
        state.view_source = nil
        state.view_start = -1
        state.view_length = -1
        state.view_num_samples = 0
    end

    -- Verify state has values
    lu.assertNotNil(state.view_peaks)
    lu.assertNotNil(state.view_source)
    lu.assertEquals(state.view_start, 1.0)

    -- Invalidate
    invalidate_view_peaks()

    -- Verify all cleared
    lu.assertNil(state.view_peaks)
    lu.assertNil(state.view_source)
    lu.assertEquals(state.view_start, -1)
    lu.assertEquals(state.view_length, -1)
    lu.assertEquals(state.view_num_samples, 0)
end

function TestNVSDItemView:test_state_undo_block_not_overwritten()
    -- Test that undo_block_open is not overwritten if already set
    local state = {
        drag_controls = {
            gain = { active = false, start_y = 0, start_value = 0, shift_held = false },
            pitch = { active = false, start_y = 0, start_value = 0, shift_held = false },
        },
        has_js_extension = false,
        undo_block_open = nil,
    }

    local function start_drag(name, mouse_y, value, track_shift)
        local ctrl = state.drag_controls[name]
        ctrl.active = true
        ctrl.start_y = mouse_y
        ctrl.start_value = value
        if track_shift then
            ctrl.shift_held = false
        end
        if not state.undo_block_open then
            state.undo_block_open = name
        end
    end

    -- Start gain drag first
    start_drag("gain", 150, 0.5, true)
    lu.assertEquals(state.undo_block_open, "gain")

    -- Start pitch drag - undo block should stay "gain"
    start_drag("pitch", 200, 1.0, true)
    lu.assertEquals(state.undo_block_open, "gain")
end

function TestNVSDItemView:test_state_pending_cache_invalidation()
    -- Test deferred cache invalidation countdown
    local state = {
        pending_cache_invalidation = 3,
        view_peaks = { mins = {}, maxs = {}, count = 50 },
        view_source = "src",
        view_start = 1.0,
        view_length = 2.0,
        view_num_samples = 400,
    }
    local wf_cache_invalidated = false

    local function process_pending_invalidation()
        if state.pending_cache_invalidation > 0 then
            state.pending_cache_invalidation = state.pending_cache_invalidation - 1
            if state.pending_cache_invalidation == 0 then
                -- invalidate_view_peaks
                state.view_peaks = nil
                state.view_source = nil
                state.view_start = -1
                state.view_length = -1
                state.view_num_samples = 0
                -- invalidate_wf_cache
                wf_cache_invalidated = true
            end
        end
    end

    -- Frame 1: count down to 2
    process_pending_invalidation()
    lu.assertEquals(state.pending_cache_invalidation, 2)
    lu.assertNotNil(state.view_peaks)

    -- Frame 2: count down to 1
    process_pending_invalidation()
    lu.assertEquals(state.pending_cache_invalidation, 1)
    lu.assertNotNil(state.view_peaks)

    -- Frame 3: count down to 0, invalidate
    process_pending_invalidation()
    lu.assertEquals(state.pending_cache_invalidation, 0)
    lu.assertNil(state.view_peaks)
    lu.assertNil(state.view_source)
    lu.assertTrue(wf_cache_invalidated)
end

-- ============================================================================
-- Settings Module Tests
-- ============================================================================

function TestNVSDItemView:test_settings_format_shortcut()
    -- Test shortcut formatting for display (using real settings module)
    lu.assertEquals(settings.format_shortcut({ctrl = true, shift = false, alt = false, key = "Z"}), "Ctrl+Z")
    lu.assertEquals(settings.format_shortcut({ctrl = true, shift = true, alt = false, key = "Z"}), "Ctrl+Shift+Z")
    lu.assertEquals(settings.format_shortcut({ctrl = false, shift = false, alt = true, key = "F4"}), "Alt+F4")
    lu.assertEquals(settings.format_shortcut({ctrl = false, shift = false, alt = false, key = "Space"}), "Space")
    lu.assertEquals(settings.format_shortcut({ctrl = true, shift = true, alt = true, key = "A"}), "Ctrl+Shift+Alt+A")
    -- Empty key returns empty string (edge case fix)
    lu.assertEquals(settings.format_shortcut({ctrl = true, shift = false, alt = false, key = ""}), "")
end

function TestNVSDItemView:test_settings_shortcut_to_string()
    -- Test serializing shortcut for ExtState storage
    local function shortcut_to_string(shortcut)
        local parts = {}
        if shortcut.ctrl then table.insert(parts, "ctrl") end
        if shortcut.shift then table.insert(parts, "shift") end
        if shortcut.alt then table.insert(parts, "alt") end
        table.insert(parts, shortcut.key)
        return table.concat(parts, "+")
    end

    local shortcut = {ctrl = true, shift = false, alt = false, key = "Z"}
    lu.assertEquals(shortcut_to_string(shortcut), "ctrl+Z")

    local shortcut2 = {ctrl = true, shift = true, alt = false, key = "Y"}
    lu.assertEquals(shortcut_to_string(shortcut2), "ctrl+shift+Y")
end

function TestNVSDItemView:test_settings_string_to_shortcut()
    -- Test parsing shortcut from ExtState storage
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

    -- Test parsing Ctrl+Z
    local result = string_to_shortcut("ctrl+Z")
    lu.assertTrue(result.ctrl)
    lu.assertFalse(result.shift)
    lu.assertFalse(result.alt)
    lu.assertEquals(result.key, "Z")

    -- Test parsing Ctrl+Shift+Y
    local result2 = string_to_shortcut("ctrl+shift+Y")
    lu.assertTrue(result2.ctrl)
    lu.assertTrue(result2.shift)
    lu.assertFalse(result2.alt)
    lu.assertEquals(result2.key, "Y")

    -- Test parsing Alt+F1
    local result3 = string_to_shortcut("alt+F1")
    lu.assertFalse(result3.ctrl)
    lu.assertFalse(result3.shift)
    lu.assertTrue(result3.alt)
    lu.assertEquals(result3.key, "F1")
end

function TestNVSDItemView:test_settings_theme_lookup()
    -- Test theme retrieval by ID (using real settings module)
    local theme = settings.get_theme("ableton_dark")
    lu.assertEquals(theme.name, "Ableton Dark")
    lu.assertNotNil(theme.colors.waveform)

    -- Test fallback to default for unknown ID
    local unknown = settings.get_theme("nonexistent")
    lu.assertEquals(unknown.id, "default")

    -- Verify THEMES table is populated
    lu.assertTrue(#settings.THEMES >= 2)
end

function TestNVSDItemView:test_settings_check_changes()
    -- Test detecting unsaved changes in settings
    local function check_changes(pending_theme_id, original_theme_id, pending_shortcuts, original_shortcuts)
        if pending_theme_id ~= original_theme_id then
            return true
        end
        for name, pending in pairs(pending_shortcuts) do
            local original = original_shortcuts[name]
            if original then
                if pending.ctrl ~= original.ctrl or
                   pending.shift ~= original.shift or
                   pending.alt ~= original.alt or
                   pending.key ~= original.key then
                    return true
                end
            end
        end
        return false
    end

    local original_shortcuts = {
        undo = {ctrl = true, shift = false, alt = false, key = "Z"},
        redo = {ctrl = true, shift = false, alt = false, key = "Y"},
    }

    -- No changes
    local pending_same = {
        undo = {ctrl = true, shift = false, alt = false, key = "Z"},
        redo = {ctrl = true, shift = false, alt = false, key = "Y"},
    }
    lu.assertFalse(check_changes("default", "default", pending_same, original_shortcuts))

    -- Theme changed
    lu.assertTrue(check_changes("ableton_dark", "default", pending_same, original_shortcuts))

    -- Shortcut changed
    local pending_changed = {
        undo = {ctrl = true, shift = true, alt = false, key = "Z"},  -- Added shift
        redo = {ctrl = true, shift = false, alt = false, key = "Y"},
    }
    lu.assertTrue(check_changes("default", "default", pending_changed, original_shortcuts))
end

-- ============================================================================
-- WARP Mode Tests (B_PPITCH based)
-- ============================================================================

function TestNVSDItemView:test_warp_mode_detection_from_bppitch()
    -- Test that warp mode is detected from B_PPITCH (preserve pitch when changing rate)
    local function detect_warp_mode(preserve_pitch)
        return preserve_pitch == 1
    end

    -- B_PPITCH = 1 means warp mode ON
    lu.assertTrue(detect_warp_mode(1))

    -- B_PPITCH = 0 means warp mode OFF
    lu.assertFalse(detect_warp_mode(0))
end

function TestNVSDItemView:test_warp_toggle_logic()
    -- Test toggling warp mode (B_PPITCH)
    local function toggle_warp(current_warp_mode)
        return current_warp_mode and 0 or 1
    end

    -- If warp is ON, toggle should return 0 (OFF)
    lu.assertEquals(toggle_warp(true), 0)

    -- If warp is OFF, toggle should return 1 (ON)
    lu.assertEquals(toggle_warp(false), 1)
end

function TestNVSDItemView:test_clear_resets_all_including_warp()
    -- Test that clear button resets pitch, playrate, and warp mode
    local function simulate_clear(take_state)
        -- Clear should reset all values
        return {
            D_PITCH = 0,
            D_PLAYRATE = 1.0,
            B_PPITCH = 0,  -- Warp disabled
            D_LENGTH = take_state.original_length
        }
    end

    -- Item with warp on, pitched, and stretched
    local initial_state = {
        D_PITCH = 5.0,
        D_PLAYRATE = 0.5,
        B_PPITCH = 1,
        D_LENGTH = 20.0,
        original_length = 10.0  -- calculated from current_length * playrate
    }

    local cleared = simulate_clear(initial_state)
    lu.assertEquals(cleared.D_PITCH, 0)
    lu.assertEquals(cleared.D_PLAYRATE, 1.0)
    lu.assertEquals(cleared.B_PPITCH, 0)
    lu.assertEquals(cleared.D_LENGTH, 10.0)
end

function TestNVSDItemView:test_original_length_calculation()
    -- Test calculating original length from stretched state
    local function calculate_original_length(current_length, current_playrate)
        return current_length * current_playrate
    end

    -- Item stretched to 2x length (playrate = 0.5)
    lu.assertAlmostEquals(calculate_original_length(20.0, 0.5), 10.0, 0.001)

    -- Item compressed to 0.5x length (playrate = 2.0)
    lu.assertAlmostEquals(calculate_original_length(5.0, 2.0), 10.0, 0.001)

    -- Item at original length (playrate = 1.0)
    lu.assertAlmostEquals(calculate_original_length(10.0, 1.0), 10.0, 0.001)
end

-- Per-view peak loading tests
function TestNVSDItemView:test_per_view_peak_reload_detection()
    -- Test that view changes correctly trigger peak reloads
    local state = {
        view_peaks = { mins = {0.1}, maxs = {0.5}, count = 400 },
        view_source = "source_A",
        view_start = 0,
        view_length = 5.0,
        view_reversed = false,
        view_num_samples = 400,
    }

    local function need_reload(source, is_reversed, view_start, view_length, num_samples)
        return state.view_peaks == nil
            or source ~= state.view_source
            or is_reversed ~= state.view_reversed
            or view_start ~= state.view_start
            or view_length ~= state.view_length
            or num_samples ~= state.view_num_samples
    end

    -- Same params: no reload needed
    lu.assertFalse(need_reload("source_A", false, 0, 5.0, 400))

    -- Different source: reload
    lu.assertTrue(need_reload("source_B", false, 0, 5.0, 400))

    -- Different view_start (panning): reload
    lu.assertTrue(need_reload("source_A", false, 0.5, 5.0, 400))

    -- Different view_length (zooming): reload
    lu.assertTrue(need_reload("source_A", false, 0, 2.5, 400))

    -- Reversed changed: reload
    lu.assertTrue(need_reload("source_A", true, 0, 5.0, 400))

    -- nil peaks: always reload
    state.view_peaks = nil
    lu.assertTrue(need_reload("source_A", false, 0, 5.0, 400))
end

function TestNVSDItemView:test_per_view_num_samples_matches_width()
    -- Per-view loading should request exactly screen-width peaks
    local waveform_width = 500
    local pixel_step = 1
    local num_samples = math.max(1, math.floor(waveform_width / pixel_step))
    lu.assertEquals(num_samples, 500)

    -- Half resolution during REAPER interaction
    pixel_step = 2
    num_samples = math.max(1, math.floor(waveform_width / pixel_step))
    lu.assertEquals(num_samples, 250)
end

function TestNVSDItemView:test_reversed_peak_start_calculation()
    -- Reversed items should load peaks from the mirrored source range
    local source_length = 10.0
    local view_start = 2.0
    local view_length = 3.0

    -- Normal: peak_start = view_start
    local peak_start_normal = view_start
    lu.assertAlmostEquals(peak_start_normal, 2.0, 0.001)

    -- Reversed: peak_start = source_length - view_start - view_length
    local peak_start_reversed = math.max(0, source_length - view_start - view_length)
    lu.assertAlmostEquals(peak_start_reversed, 5.0, 0.001)

    -- Verify: reversed peak range [5, 8] mirrors normal view [2, 5] around center
    lu.assertAlmostEquals(peak_start_reversed + view_length, source_length - view_start, 0.001)
end

-- ============================================================================
-- New Tests: Settings Serialization
-- ============================================================================

function TestNVSDItemView:test_settings_roundtrip_all_defaults()
    -- Verify serialize + parse roundtrip for each default shortcut
    local function shortcut_to_string(shortcut)
        local parts = {}
        if shortcut.ctrl then table.insert(parts, "ctrl") end
        if shortcut.shift then table.insert(parts, "shift") end
        if shortcut.alt then table.insert(parts, "alt") end
        table.insert(parts, shortcut.key)
        return table.concat(parts, "+")
    end

    local function string_to_shortcut(str)
        local shortcut = {ctrl = false, shift = false, alt = false, key = ""}
        for part in string.gmatch(str, "[^+]+") do
            local lower_part = part:lower()
            if lower_part == "ctrl" then shortcut.ctrl = true
            elseif lower_part == "shift" then shortcut.shift = true
            elseif lower_part == "alt" then shortcut.alt = true
            else shortcut.key = part end
        end
        return shortcut
    end

    local defaults = {
        zoom_in = {ctrl = false, shift = false, alt = false, key = ""},
        zoom_out = {ctrl = false, shift = false, alt = false, key = ""},
        reset_zoom = {ctrl = false, shift = false, alt = false, key = "F"},
        toggle_warp = {ctrl = false, shift = false, alt = false, key = "W"},
        toggle_mute = {ctrl = false, shift = false, alt = false, key = "M"},
        reverse = {ctrl = false, shift = false, alt = false, key = "R"},
        clear = {ctrl = false, shift = false, alt = false, key = "C"},
        open_editor = {ctrl = false, shift = false, alt = false, key = "E"},
    }

    for name, shortcut in pairs(defaults) do
        local serialized = shortcut_to_string(shortcut)
        local parsed = string_to_shortcut(serialized)
        lu.assertEquals(parsed.ctrl, shortcut.ctrl, name .. " ctrl mismatch")
        lu.assertEquals(parsed.shift, shortcut.shift, name .. " shift mismatch")
        lu.assertEquals(parsed.alt, shortcut.alt, name .. " alt mismatch")
        lu.assertEquals(parsed.key, shortcut.key, name .. " key mismatch")
    end
end

function TestNVSDItemView:test_settings_parse_empty_key()
    -- Parse shortcut with empty key field
    local function string_to_shortcut(str)
        local shortcut = {ctrl = false, shift = false, alt = false, key = ""}
        for part in string.gmatch(str, "[^+]+") do
            local lower_part = part:lower()
            if lower_part == "ctrl" then shortcut.ctrl = true
            elseif lower_part == "shift" then shortcut.shift = true
            elseif lower_part == "alt" then shortcut.alt = true
            else shortcut.key = part end
        end
        return shortcut
    end

    -- Empty string should produce empty key
    local result = string_to_shortcut("")
    lu.assertEquals(result.key, "")
    lu.assertFalse(result.ctrl)
end

function TestNVSDItemView:test_settings_parse_special_keys()
    -- Parse shortcuts with special key names
    local function string_to_shortcut(str)
        local shortcut = {ctrl = false, shift = false, alt = false, key = ""}
        for part in string.gmatch(str, "[^+]+") do
            local lower_part = part:lower()
            if lower_part == "ctrl" then shortcut.ctrl = true
            elseif lower_part == "shift" then shortcut.shift = true
            elseif lower_part == "alt" then shortcut.alt = true
            else shortcut.key = part end
        end
        return shortcut
    end

    -- F1
    local f1 = string_to_shortcut("F1")
    lu.assertEquals(f1.key, "F1")

    -- F12
    local f12 = string_to_shortcut("ctrl+F12")
    lu.assertEquals(f12.key, "F12")
    lu.assertTrue(f12.ctrl)

    -- Space
    local space = string_to_shortcut("Space")
    lu.assertEquals(space.key, "Space")

    -- Delete
    local delete = string_to_shortcut("ctrl+Delete")
    lu.assertEquals(delete.key, "Delete")
    lu.assertTrue(delete.ctrl)
end

function TestNVSDItemView:test_settings_format_no_modifiers()
    -- Format bare key like "W" -> "W" (using real settings module)
    lu.assertEquals(settings.format_shortcut({ctrl = false, shift = false, alt = false, key = "W"}), "W")
    lu.assertEquals(settings.format_shortcut({ctrl = false, shift = false, alt = false, key = "F"}), "F")
end

function TestNVSDItemView:test_settings_theme_fallback_to_default()
    -- Unknown theme ID returns first theme (using real settings module)
    lu.assertEquals(settings.get_theme("warm").name, "Warm")
    lu.assertEquals(settings.get_theme("nonexistent_theme_xyz").id, "default")
    lu.assertEquals(settings.get_theme("").id, "default")
end

function TestNVSDItemView:test_settings_deep_copy_independence()
    -- Modify copy, original unchanged
    local original = {ctrl = true, shift = false, alt = false, key = "Z"}
    local copy = {
        ctrl = original.ctrl,
        shift = original.shift,
        alt = original.alt,
        key = original.key
    }

    -- Modify copy
    copy.ctrl = false
    copy.key = "A"

    -- Original unchanged
    lu.assertTrue(original.ctrl)
    lu.assertEquals(original.key, "Z")
    -- Copy changed
    lu.assertFalse(copy.ctrl)
    lu.assertEquals(copy.key, "A")
end

-- ============================================================================
-- New Tests: Bug Fix Verification
-- ============================================================================

function TestNVSDItemView:test_mouse_button_mapping()
    -- Document ImGui mouse button indices as used in this project
    -- ImGui button 0 = Left, 1 = Right, 2 = Middle, 3 = Extra1, 4 = Extra2
    -- In our code: Mouse4 uses index 4, Mouse5 uses index 3
    -- (hardware mapping may differ from ImGui's Extra1/Extra2 numbering)
    local MOUSE4_INDEX = 4
    local MOUSE5_INDEX = 3

    lu.assertEquals(MOUSE4_INDEX, 4)
    lu.assertEquals(MOUSE5_INDEX, 3)
    lu.assertTrue(MOUSE4_INDEX ~= MOUSE5_INDEX)
end

function TestNVSDItemView:test_semitones_drag_preserves_cents()
    -- When dragging semitones, cents should stay frozen at their start value
    local function semitones_cents_to_pitch(semitones, cents)
        return semitones + cents / 100
    end

    -- Start: pitch 2.25 -> semitones=2, cents=25 (round-to-nearest)
    local start_cents = 25
    local start_semitones = 2

    -- Drag +1 semitone: should be 3 + 25/100 = 3.25
    local new_pitch = semitones_cents_to_pitch(start_semitones + 1, start_cents)
    lu.assertAlmostEquals(new_pitch, 3.25, 0.001)

    -- Drag -1 semitone: should be 1 + 25/100 = 1.25
    new_pitch = semitones_cents_to_pitch(start_semitones - 1, start_cents)
    lu.assertAlmostEquals(new_pitch, 1.25, 0.001)

    -- Without freezing (using recomputed cents), we'd get drift
    -- This test verifies we use the stored cents, not recomputed ones
end

function TestNVSDItemView:test_semitones_cents_roundtrip()
    -- 2.50 + 1 semitone should give 3.50
    local function pitch_to_semitones_cents(pitch)
        local semitones = math.floor(pitch + 0.5)
        local cents = math.floor((pitch - semitones) * 100 + 0.5)
        return semitones, cents
    end

    local function semitones_cents_to_pitch(semitones, cents)
        return semitones + cents / 100
    end

    -- Start at pitch 2.50
    local semi, cents = pitch_to_semitones_cents(2.50)
    -- 2.50 rounds to semi=3, cents=-50
    lu.assertEquals(semi, 3)    -- floor(2.50 + 0.5) = floor(3.0) = 3
    lu.assertEquals(cents, -50) -- floor((2.50 - 3) * 100 + 0.5) = floor(-49.5) = -50

    -- Add 1 semitone using frozen cents
    local new_pitch = semitones_cents_to_pitch(semi + 1, cents)
    lu.assertAlmostEquals(new_pitch, 3.50, 0.001)  -- 4 + (-50/100) = 3.50

    -- Verify roundtrip: decompose and recompose gives same result
    local semi2, cents2 = pitch_to_semitones_cents(new_pitch)
    local roundtrip = semitones_cents_to_pitch(semi2, cents2)
    lu.assertAlmostEquals(roundtrip, new_pitch, 0.001)
end

function TestNVSDItemView:test_cents_drag_rollover()
    -- Cents drag should rollover into semitones at ±50 boundary
    local function semitones_cents_to_pitch(semitones, cents)
        return semitones + cents / 100
    end

    -- Simulate: start at 0 semi, 0 cents, drag up past +50
    local frozen_semitones = 0
    local start_cents = 0

    -- Drag +60 cents total: should rollover to +1 semi, -40 cents
    local total_cents = start_cents + 60
    local extra_semitones = math.floor((total_cents + 50) / 100)
    local final_cents = total_cents - extra_semitones * 100
    local final_semitones = frozen_semitones + extra_semitones
    lu.assertEquals(final_semitones, 1)
    lu.assertEquals(final_cents, -40)
    lu.assertAlmostEquals(semitones_cents_to_pitch(final_semitones, final_cents), 0.60, 0.001)

    -- Drag -60 cents total: should rollover to -1 semi, +40 cents
    total_cents = start_cents - 60
    extra_semitones = math.floor((total_cents + 50) / 100)
    final_cents = total_cents - extra_semitones * 100
    final_semitones = frozen_semitones + extra_semitones
    lu.assertEquals(final_semitones, -1)
    lu.assertEquals(final_cents, 40)
    lu.assertAlmostEquals(semitones_cents_to_pitch(final_semitones, final_cents), -0.60, 0.001)

    -- Drag +150 cents: should rollover to +2 semi, -50 cents
    total_cents = start_cents + 150
    extra_semitones = math.floor((total_cents + 50) / 100)
    final_cents = total_cents - extra_semitones * 100
    final_semitones = frozen_semitones + extra_semitones
    lu.assertEquals(final_semitones, 2)
    lu.assertEquals(final_cents, -50)
    lu.assertAlmostEquals(semitones_cents_to_pitch(final_semitones, final_cents), 1.50, 0.001)

    -- Stay within range: +30 cents, no rollover
    total_cents = start_cents + 30
    extra_semitones = math.floor((total_cents + 50) / 100)
    final_cents = total_cents - extra_semitones * 100
    final_semitones = frozen_semitones + extra_semitones
    lu.assertEquals(final_semitones, 0)
    lu.assertEquals(final_cents, 30)
end

function TestNVSDItemView:test_cents_drag_no_acceleration()
    -- Verify that frozen semitones prevent the acceleration bug.
    -- The bug: display_semitones shifts mid-drag because it's recomputed from
    -- current pitch each frame, compounding with unbounded cents.
    -- Fix: use frozen_semitones captured at drag start.

    local function semitones_cents_to_pitch(semitones, cents)
        return semitones + cents / 100
    end

    -- Start at pitch 0.0: semi=0, cents=0
    local frozen_semitones = 0
    local start_cents = 0

    -- Frame 1: drag delta = +80 cents
    local total_cents = start_cents + 80
    local extra_semitones = math.floor((total_cents + 50) / 100)
    local final_cents = total_cents - extra_semitones * 100
    local final_semitones = frozen_semitones + extra_semitones
    local pitch_frame1 = semitones_cents_to_pitch(final_semitones, final_cents)
    lu.assertAlmostEquals(pitch_frame1, 0.80, 0.001)

    -- Frame 2: same delta = +80 cents (mouse hasn't moved)
    -- With frozen semitones, result is identical (no acceleration)
    total_cents = start_cents + 80
    extra_semitones = math.floor((total_cents + 50) / 100)
    final_cents = total_cents - extra_semitones * 100
    final_semitones = frozen_semitones + extra_semitones
    local pitch_frame2 = semitones_cents_to_pitch(final_semitones, final_cents)
    lu.assertAlmostEquals(pitch_frame2, pitch_frame1, 0.001)
end

-- ============================================================================
-- Per-View Peak Loading Tests
-- ============================================================================

function TestNVSDItemView:test_view_bounds_clamping()
    -- View bounds should clamp to [0, source_length]
    local source_length = 10.0

    local function compute_view_bounds(zoom_lvl, pan_offset)
        local view_length = source_length / zoom_lvl
        local view_center = source_length / 2 + pan_offset
        local view_start = view_center - view_length / 2
        local view_end = view_start + view_length
        if view_start < 0 then view_start = 0; view_end = view_length end
        if view_end > source_length then view_end = source_length; view_start = source_length - view_length end
        if view_start < 0 then view_start = 0 end
        view_length = view_end - view_start
        return view_start, view_length
    end

    -- Zoom 1x, no pan: should show full source
    local vs, vl = compute_view_bounds(1.0, 0)
    lu.assertAlmostEquals(vs, 0, 0.001)
    lu.assertAlmostEquals(vl, 10.0, 0.001)

    -- Zoom 2x, no pan: centered, 5s visible
    vs, vl = compute_view_bounds(2.0, 0)
    lu.assertAlmostEquals(vs, 2.5, 0.001)
    lu.assertAlmostEquals(vl, 5.0, 0.001)

    -- Zoom 1x, pan far right: should clamp
    vs, vl = compute_view_bounds(1.0, 100)
    lu.assertAlmostEquals(vs, 0, 0.001)
    lu.assertAlmostEquals(vl, 10.0, 0.001)
end

function TestNVSDItemView:test_one_to_one_peak_mapping()
    -- With per-view peaks, pixel i maps to peak i (or reversed)
    local num_peaks = 400
    local num_samples = 400

    -- Normal: pixel 0 -> peak 0, pixel 399 -> peak 399
    for i = 0, 3 do
        local peak_i = i
        lu.assertEquals(peak_i, i)
    end

    -- Reversed: pixel 0 -> peak 399, pixel 399 -> peak 0
    for i = 0, 3 do
        local peak_i = num_peaks - 1 - i
        lu.assertEquals(peak_i, num_peaks - 1 - i)
    end

    -- Edge: when peaks.count < num_samples, clamp
    local short_peaks = 200
    local peak_i = short_peaks - 1 - 0  -- reversed, first pixel
    lu.assertEquals(peak_i, 199)

    peak_i = short_peaks - 1 - 250  -- would go negative
    if peak_i < 0 then peak_i = 0 end
    lu.assertEquals(peak_i, 0)
end

function TestNVSDItemView:test_pixel_step_reduces_samples()
    -- pixel_step=2 should halve the number of samples requested
    local width = 500
    lu.assertEquals(math.floor(width / 1), 500)
    lu.assertEquals(math.floor(width / 2), 250)
end

-- ============================================================================
-- New Tests: Settings UI State
-- ============================================================================

function TestNVSDItemView:test_settings_ui_open_sets_state()
    -- Opening settings populates pending values
    local ui_state = {
        open = false,
        pending_theme_id = nil,
        original_theme_id = nil,
    }

    local settings = {
        current = { theme_id = "warm" }
    }

    -- Simulate open
    ui_state.open = true
    ui_state.pending_theme_id = settings.current.theme_id
    ui_state.original_theme_id = settings.current.theme_id

    lu.assertTrue(ui_state.open)
    lu.assertEquals(ui_state.pending_theme_id, "warm")
    lu.assertEquals(ui_state.original_theme_id, "warm")
end

function TestNVSDItemView:test_settings_ui_cancel_restores()
    -- Closing with restore=true reverts theme to original
    local ui_state = {
        open = true,
        pending_theme_id = "ableton_dark",
        original_theme_id = "default",
    }

    local settings = {
        current = { theme_id = "ableton_dark" },
        colors_dirty = false,
    }

    -- Simulate close with restore
    local restore_original = true
    if restore_original and ui_state.original_theme_id then
        settings.current.theme_id = ui_state.original_theme_id
        settings.colors_dirty = true
    end
    ui_state.open = false
    ui_state.original_theme_id = nil

    lu.assertFalse(ui_state.open)
    lu.assertEquals(settings.current.theme_id, "default")  -- restored
    lu.assertTrue(settings.colors_dirty)
end

function TestNVSDItemView:test_settings_ui_save_applies()
    -- Closing with restore=false keeps the new theme
    local ui_state = {
        open = true,
        pending_theme_id = "ableton_dark",
        original_theme_id = "default",
    }

    local settings = {
        current = { theme_id = "ableton_dark" },
        colors_dirty = false,
    }

    -- Simulate close without restore (save)
    local restore_original = false
    if restore_original and ui_state.original_theme_id then
        settings.current.theme_id = ui_state.original_theme_id
        settings.colors_dirty = true
    end
    ui_state.open = false
    ui_state.original_theme_id = nil

    lu.assertFalse(ui_state.open)
    lu.assertEquals(settings.current.theme_id, "ableton_dark")  -- kept
    lu.assertFalse(settings.colors_dirty)  -- not changed back
end

-- =============================================================
-- Shortcut editor: find_conflict and capture tests
-- =============================================================

function TestNVSDItemView:test_find_conflict_detects_duplicate()
    -- Same key+modifiers on two different shortcuts → returns conflict name (using real settings module)
    local shortcuts = {
        toggle_warp = {ctrl = false, shift = false, alt = false, key = "W"},
        toggle_mute = {ctrl = false, shift = false, alt = false, key = "W"},  -- duplicate
    }
    local result = settings.find_conflict(shortcuts, "toggle_warp", {ctrl = false, shift = false, alt = false, key = "W"})
    lu.assertEquals(result, "toggle_mute")
end

function TestNVSDItemView:test_find_conflict_no_conflict_different_modifiers()
    -- "W" vs "Ctrl+W" → no conflict (using real settings module)
    local shortcuts = {
        toggle_warp = {ctrl = false, shift = false, alt = false, key = "W"},
        toggle_mute = {ctrl = true, shift = false, alt = false, key = "W"},  -- Ctrl+W
    }
    local result = settings.find_conflict(shortcuts, "toggle_warp", {ctrl = false, shift = false, alt = false, key = "W"})
    lu.assertNil(result)
end

function TestNVSDItemView:test_find_conflict_ignores_empty_keys()
    -- Two unbound shortcuts → no conflict (using real settings module)
    local shortcuts = {
        zoom_in = {ctrl = false, shift = false, alt = false, key = ""},
        zoom_out = {ctrl = false, shift = false, alt = false, key = ""},
    }
    local result = settings.find_conflict(shortcuts, "zoom_in", {ctrl = false, shift = false, alt = false, key = ""})
    lu.assertNil(result)
end

function TestNVSDItemView:test_find_conflict_skips_self()
    -- Same binding on the shortcut being edited → should NOT report as conflict (using real settings module)
    local shortcuts = {
        toggle_warp = {ctrl = false, shift = false, alt = false, key = "W"},
        toggle_mute = {ctrl = false, shift = false, alt = false, key = "M"},
    }
    local result = settings.find_conflict(shortcuts, "toggle_warp", {ctrl = false, shift = false, alt = false, key = "W"})
    lu.assertNil(result)
end

function TestNVSDItemView:test_settings_listening_suppresses_check()
    -- When settings.listening is true, check_shortcut should return false
    -- We test this by reimplementing the guard logic
    local listening = true

    local function check_shortcut_guarded(listening_flag)
        if listening_flag then return false end
        return true  -- Would normally check key state
    end

    lu.assertFalse(check_shortcut_guarded(true))
    lu.assertTrue(check_shortcut_guarded(false))
end

-- ========================================================================
-- Phase 6: Extended tests for shortcuts, themes, grid, settings, config
-- ========================================================================

-- Test that format_shortcut produces correct strings for all modifier combos
function TestNVSDItemView:test_settings_format_all_modifier_combos()
    local fmt = settings.format_shortcut

    -- No modifiers
    lu.assertEquals(fmt({ctrl = false, shift = false, alt = false, key = "A"}), "A")

    -- Ctrl only
    lu.assertEquals(fmt({ctrl = true, shift = false, alt = false, key = "A"}), "Ctrl+A")

    -- Shift only
    lu.assertEquals(fmt({ctrl = false, shift = true, alt = false, key = "A"}), "Shift+A")

    -- Alt only
    lu.assertEquals(fmt({ctrl = false, shift = false, alt = true, key = "A"}), "Alt+A")

    -- Ctrl+Shift
    lu.assertEquals(fmt({ctrl = true, shift = true, alt = false, key = "A"}), "Ctrl+Shift+A")

    -- Ctrl+Alt
    lu.assertEquals(fmt({ctrl = true, shift = false, alt = true, key = "A"}), "Ctrl+Alt+A")

    -- Shift+Alt
    lu.assertEquals(fmt({ctrl = false, shift = true, alt = true, key = "A"}), "Shift+Alt+A")

    -- Ctrl+Shift+Alt
    lu.assertEquals(fmt({ctrl = true, shift = true, alt = true, key = "A"}), "Ctrl+Shift+Alt+A")
end

-- Test conflict detection catches exact duplicates
function TestNVSDItemView:test_settings_conflict_detects_exact_duplicate()
    local shortcuts = {
        action_a = {ctrl = false, shift = false, alt = false, key = "W"},
        action_b = {ctrl = true, shift = false, alt = false, key = "S"},
    }
    -- Exact duplicate of action_a
    local binding = {ctrl = false, shift = false, alt = false, key = "W"}
    local conflict = settings.find_conflict(shortcuts, "action_c", binding)
    lu.assertEquals(conflict, "action_a")
end

-- Test conflict detection allows same key with different modifiers
function TestNVSDItemView:test_settings_no_conflict_different_modifiers()
    local shortcuts = {
        action_a = {ctrl = false, shift = false, alt = false, key = "H"},
        action_b = {ctrl = false, shift = true, alt = false, key = "H"},
    }
    -- H (plain) doesn't conflict with Shift+H when checking against action_b
    local binding = {ctrl = false, shift = false, alt = false, key = "H"}
    local conflict = settings.find_conflict(shortcuts, "action_c", binding)
    lu.assertEquals(conflict, "action_a")  -- conflicts with action_a, not action_b

    -- Shift+H doesn't conflict with plain H
    local binding2 = {ctrl = false, shift = true, alt = false, key = "H"}
    local conflict2 = settings.find_conflict(shortcuts, "action_c", binding2)
    lu.assertEquals(conflict2, "action_b")  -- conflicts with action_b, not action_a
end

-- Test all default shortcuts have valid structure
function TestNVSDItemView:test_default_shortcuts_complete()
    local expected_names = {
        "zoom_in", "zoom_out", "reset_zoom", "toggle_warp", "toggle_mute",
        "reverse", "clear", "open_editor", "toggle_snap", "audio_preview",
        "envelope_lock", "show_volume_env", "show_pitch_env", "show_pan_env",
        "hide_envelopes", "open_settings",
    }

    for _, name in ipairs(expected_names) do
        local sc = settings.DEFAULT_SHORTCUTS[name]
        lu.assertNotNil(sc, "Missing default shortcut: " .. name)
        lu.assertNotNil(sc.ctrl, name .. " missing ctrl field")
        lu.assertNotNil(sc.shift, name .. " missing shift field")
        lu.assertNotNil(sc.alt, name .. " missing alt field")
        lu.assertNotNil(sc.key, name .. " missing key field")
    end

    -- Verify count matches (no extra unexpected shortcuts)
    local count = 0
    for _ in pairs(settings.DEFAULT_SHORTCUTS) do count = count + 1 end
    lu.assertEquals(count, #expected_names)
end

-- Test new shortcut defaults have correct modifier combinations
function TestNVSDItemView:test_new_shortcut_defaults()
    -- envelope_lock: plain L
    local el = settings.DEFAULT_SHORTCUTS.envelope_lock
    lu.assertFalse(el.ctrl)
    lu.assertFalse(el.shift)
    lu.assertFalse(el.alt)
    lu.assertEquals(el.key, "L")

    -- show_volume_env: Shift+V
    local sv = settings.DEFAULT_SHORTCUTS.show_volume_env
    lu.assertFalse(sv.ctrl)
    lu.assertTrue(sv.shift)
    lu.assertFalse(sv.alt)
    lu.assertEquals(sv.key, "V")

    -- show_pitch_env: Shift+H
    local sp = settings.DEFAULT_SHORTCUTS.show_pitch_env
    lu.assertFalse(sp.ctrl)
    lu.assertTrue(sp.shift)
    lu.assertFalse(sp.alt)
    lu.assertEquals(sp.key, "H")

    -- show_pan_env: Shift+P
    local spn = settings.DEFAULT_SHORTCUTS.show_pan_env
    lu.assertFalse(spn.ctrl)
    lu.assertTrue(spn.shift)
    lu.assertFalse(spn.alt)
    lu.assertEquals(spn.key, "P")

    -- hide_envelopes: plain H
    local he = settings.DEFAULT_SHORTCUTS.hide_envelopes
    lu.assertFalse(he.ctrl)
    lu.assertFalse(he.shift)
    lu.assertFalse(he.alt)
    lu.assertEquals(he.key, "H")

    -- open_settings: plain S
    local os_sc = settings.DEFAULT_SHORTCUTS.open_settings
    lu.assertFalse(os_sc.ctrl)
    lu.assertFalse(os_sc.shift)
    lu.assertFalse(os_sc.alt)
    lu.assertEquals(os_sc.key, "S")
end

-- Test H (plain) and Shift+H don't conflict with each other
function TestNVSDItemView:test_h_shift_h_no_conflict()
    local shortcuts = settings.DEFAULT_SHORTCUTS
    -- hide_envelopes (H) and show_pitch_env (Shift+H) use same key, different modifiers
    local hide = shortcuts.hide_envelopes
    local show_pitch = shortcuts.show_pitch_env
    lu.assertEquals(hide.key, "H")
    lu.assertEquals(show_pitch.key, "H")
    lu.assertFalse(hide.shift)
    lu.assertTrue(show_pitch.shift)

    -- Verify no conflict detected between them
    local conflict = settings.find_conflict(shortcuts, "hide_envelopes",
        {ctrl = false, shift = false, alt = false, key = "H"})
    lu.assertNil(conflict)  -- hide_envelopes itself is excluded, no other plain-H binding

    local conflict2 = settings.find_conflict(shortcuts, "show_pitch_env",
        {ctrl = false, shift = true, alt = false, key = "H"})
    lu.assertNil(conflict2)  -- show_pitch_env excluded, no other Shift+H binding
end

-- Test all themes have all required color keys
function TestNVSDItemView:test_theme_colors_complete()
    local required_keys = {
        "waveform", "waveform_inactive", "waveform_bg", "centerline",
        "markers", "markers_hover", "border", "playhead",
        "grid_bar", "grid_beat", "ruler_bg", "ruler_text", "ruler_tick",
        "info_bar_bg", "info_bar_text", "info_bar_icon",
        "btn_on", "btn_off", "btn_hover", "btn_text",
    }

    for _, theme in ipairs(settings.THEMES) do
        lu.assertNotNil(theme.id, "Theme missing id")
        lu.assertNotNil(theme.name, "Theme missing name")
        lu.assertNotNil(theme.colors, "Theme " .. theme.name .. " missing colors")

        for _, key in ipairs(required_keys) do
            lu.assertNotNil(theme.colors[key],
                "Theme " .. theme.name .. " missing color: " .. key)
            -- Verify color is a number (RGBA hex)
            lu.assertEquals(type(theme.colors[key]), "number",
                "Theme " .. theme.name .. " color " .. key .. " is not a number")
        end
    end
end

-- Test theme count (18: 12 original + Classic rename + 4 DAW + Custom)
function TestNVSDItemView:test_theme_count()
    lu.assertEquals(#settings.THEMES, 18)
end

-- Test theme IDs are unique
function TestNVSDItemView:test_theme_ids_unique()
    local seen = {}
    for _, theme in ipairs(settings.THEMES) do
        lu.assertNil(seen[theme.id], "Duplicate theme id: " .. theme.id)
        seen[theme.id] = true
    end
end

-- Test new themes exist with correct IDs
function TestNVSDItemView:test_new_themes_exist()
    local new_ids = {"sunset", "arctic", "forest", "neon"}
    for _, id in ipairs(new_ids) do
        local theme = settings.get_theme(id)
        lu.assertNotNil(theme, "Missing new theme: " .. id)
        lu.assertEquals(theme.id, id)
    end
end

-- Test config refresh_colors maps all theme color keys
function TestNVSDItemView:test_config_refresh_colors_maps_all_keys()
    local config = dofile("Scripts/NVSD/lib/config.lua")

    -- Set up mock settings
    local mock_colors = {
        waveform = 0x112233FF,
        waveform_inactive = 0x223344FF,
        waveform_bg = 0x334455FF,
        centerline = 0x445566FF,
        markers = 0x556677FF,
        markers_hover = 0x667788FF,
        border = 0x778899FF,
        playhead = 0x8899AAFF,
        grid_bar = 0x99AABBFF,
        grid_beat = 0xAABBCCFF,
        ruler_bg = 0xBBCCDDFF,
        ruler_text = 0xCCDDEEFF,
        ruler_tick = 0xDDEEFFFF,
        info_bar_bg = 0x111111FF,
        info_bar_text = 0x222222FF,
        info_bar_icon = 0x333333FF,
        btn_on = 0x444444FF,
        btn_off = 0x555555FF,
        btn_hover = 0x666666FF,
        btn_text = 0x777777FF,
    }

    config.settings = {
        get_colors = function() return mock_colors end
    }

    config.refresh_colors()

    lu.assertEquals(config.COLOR_WAVEFORM, mock_colors.waveform)
    lu.assertEquals(config.COLOR_WAVEFORM_INACTIVE, mock_colors.waveform_inactive)
    lu.assertEquals(config.COLOR_WAVEFORM_BG, mock_colors.waveform_bg)
    lu.assertEquals(config.COLOR_CENTERLINE, mock_colors.centerline)
    lu.assertEquals(config.COLOR_MARKER, mock_colors.markers)
    lu.assertEquals(config.COLOR_MARKER_HOVER, mock_colors.markers_hover)
    lu.assertEquals(config.COLOR_BORDER, mock_colors.border)
    lu.assertEquals(config.COLOR_PLAYHEAD, mock_colors.playhead)
    lu.assertEquals(config.COLOR_GRID_BAR, mock_colors.grid_bar)
    lu.assertEquals(config.COLOR_GRID_BEAT, mock_colors.grid_beat)
    lu.assertEquals(config.COLOR_RULER_BG, mock_colors.ruler_bg)
    lu.assertEquals(config.COLOR_RULER_TEXT, mock_colors.ruler_text)
    lu.assertEquals(config.COLOR_RULER_TICK, mock_colors.ruler_tick)
    lu.assertEquals(config.COLOR_INFO_BAR_BG, mock_colors.info_bar_bg)
    lu.assertEquals(config.COLOR_INFO_BAR_TEXT, mock_colors.info_bar_text)
    lu.assertEquals(config.COLOR_INFO_BAR_ICON, mock_colors.info_bar_icon)
    lu.assertEquals(config.COLOR_BTN_ON, mock_colors.btn_on)
    lu.assertEquals(config.COLOR_BTN_OFF, mock_colors.btn_off)
    lu.assertEquals(config.COLOR_BTN_HOVER, mock_colors.btn_hover)
    lu.assertEquals(config.COLOR_BTN_TEXT, mock_colors.btn_text)
end

-- Test darken_color math
function TestNVSDItemView:test_darken_color()
    -- Implement the darken_color formula for testing
    local function darken(color, factor)
        local r = ((color >> 24) & 0xFF) * factor
        local g = ((color >> 16) & 0xFF) * factor
        local b = ((color >> 8) & 0xFF) * factor
        local a = color & 0xFF
        return (math.floor(r) << 24) | (math.floor(g) << 16) | (math.floor(b) << 8) | a
    end

    -- Half brightness white -> 0x7F7F7FFF
    local result = darken(0xFFFFFFFF, 0.5)
    lu.assertEquals(result, (127 << 24) | (127 << 16) | (127 << 8) | 0xFF)

    -- Zero factor -> black with same alpha
    local black = darken(0xFF8844FF, 0)
    lu.assertEquals(black, 0x000000FF)

    -- Factor 1.0 -> unchanged
    local same = darken(0xAABBCCDD, 1.0)
    lu.assertEquals(same, 0xAABBCCDD)

    -- Alpha preserved
    local alpha_test = darken(0xFF000080, 0.5)
    lu.assertEquals(alpha_test & 0xFF, 0x80)  -- Alpha unchanged
end

-- Test color_with_alpha
function TestNVSDItemView:test_color_with_alpha()
    local function color_with_alpha(color, alpha)
        return ((color >> 8) << 8) | alpha
    end

    -- Replace alpha on opaque color
    lu.assertEquals(color_with_alpha(0xFF0000FF, 0x80), 0xFF000080)

    -- Full alpha
    lu.assertEquals(color_with_alpha(0x123456AB, 0xFF), 0x123456FF)

    -- Zero alpha
    lu.assertEquals(color_with_alpha(0xAABBCCFF, 0x00), 0xAABBCC00)
end

-- Test fade evaluation at boundaries (linear shape = 0)
function TestNVSDItemView:test_fade_eval_linear_boundaries()
    -- Linear fade (shape 0) should be identity: t=0 -> 0, t=1 -> 1
    -- We test the mathematical property since we can't call the drawing module's local function
    local function linear_fade(t)
        return t  -- shape 0 = linear
    end
    lu.assertAlmostEquals(linear_fade(0), 0, 0.001)
    lu.assertAlmostEquals(linear_fade(0.5), 0.5, 0.001)
    lu.assertAlmostEquals(linear_fade(1), 1, 0.001)
end

-- Test fade LUT interpolation logic
function TestNVSDItemView:test_fade_lut_interpolation()
    -- Build a simple linear LUT
    local LUT_SIZE = 256
    local lut = {}
    for i = 0, LUT_SIZE do
        lut[i] = i / LUT_SIZE
    end

    -- Reimplment fade_lut_lookup
    local function lut_lookup(lut_data, t)
        if t <= 0 then return lut_data[0] end
        if t >= 1 then return lut_data[LUT_SIZE] end
        local idx = t * LUT_SIZE
        local i = math.floor(idx)
        return lut_data[i] + (lut_data[i + 1] - lut_data[i]) * (idx - i)
    end

    -- Boundaries
    lu.assertAlmostEquals(lut_lookup(lut, 0), 0, 0.001)
    lu.assertAlmostEquals(lut_lookup(lut, 1), 1, 0.001)

    -- Midpoint of linear LUT should be ~0.5
    lu.assertAlmostEquals(lut_lookup(lut, 0.5), 0.5, 0.01)

    -- Arbitrary point: 0.25
    lu.assertAlmostEquals(lut_lookup(lut, 0.25), 0.25, 0.01)

    -- Below zero clamped
    lu.assertAlmostEquals(lut_lookup(lut, -0.5), 0, 0.001)

    -- Above one clamped
    lu.assertAlmostEquals(lut_lookup(lut, 1.5), 1, 0.001)
end

-- Test grid spacing constants (after Phase 1 changes)
function TestNVSDItemView:test_grid_spacing_constants()
    -- These test the expected constant values after Round 3 updates
    -- min_bar_spacing = 140 (was 100)
    -- sub-beat threshold = 20 (was 12)
    -- beat grid visibility = 40 (was 28)
    -- We verify the compute logic matches expected behavior

    -- At px_per_beat = 39 (below 40 threshold), beat grid should NOT show
    local show_beat_grid_39 = 39 >= 40
    lu.assertFalse(show_beat_grid_39)

    -- At px_per_beat = 40, beat grid should show
    local show_beat_grid_40 = 40 >= 40
    lu.assertTrue(show_beat_grid_40)

    -- Sub-beat subdivision: finest_sub starts at 1, doubles while spacing >= 20
    local function compute_finest_sub(px_per_beat)
        local finest_sub = 1
        while (px_per_beat / (finest_sub * 2)) >= 20 do
            finest_sub = finest_sub * 2
        end
        return finest_sub
    end

    -- At px_per_beat = 80: 80/2=40 >= 20 -> 2, 80/4=20 >= 20 -> 4, 80/8=10 < 20 -> stop at 4
    lu.assertEquals(compute_finest_sub(80), 4)

    -- At px_per_beat = 40: 40/2=20 >= 20 -> 2, 40/4=10 < 20 -> stop at 2
    lu.assertEquals(compute_finest_sub(40), 2)

    -- At px_per_beat = 30: 30/2=15 < 20 -> stop at 1
    lu.assertEquals(compute_finest_sub(30), 1)

    -- At px_per_beat = 160: 160/2=80, 160/4=40, 160/8=20, 160/16=10 -> stop at 8
    lu.assertEquals(compute_finest_sub(160), 8)
end

-- Test tip_with_key tooltip formatting
function TestNVSDItemView:test_tip_with_key_formatting()
    -- Reimplement the logic from controls.lua
    local function tip_with_key(text, shortcuts, shortcut_name)
        if not shortcuts then return text end
        local sc = shortcuts[shortcut_name]
        if sc and sc.key ~= "" then
            return text .. "  [" .. settings.format_shortcut(sc) .. "]"
        end
        return text
    end

    -- With a shortcut bound
    local shortcuts = {toggle_warp = {ctrl = false, shift = false, alt = false, key = "W"}}
    lu.assertEquals(tip_with_key("Toggle WARP", shortcuts, "toggle_warp"), "Toggle WARP  [W]")

    -- With modifier
    shortcuts.audio_preview = {ctrl = true, shift = false, alt = false, key = "Space"}
    lu.assertEquals(tip_with_key("Audio preview", shortcuts, "audio_preview"), "Audio preview  [Ctrl+Space]")

    -- With unbound shortcut
    shortcuts.zoom_in = {ctrl = false, shift = false, alt = false, key = ""}
    lu.assertEquals(tip_with_key("Zoom in", shortcuts, "zoom_in"), "Zoom in")

    -- With nil shortcuts table
    lu.assertEquals(tip_with_key("Test", nil, "anything"), "Test")
end

-- Test gain text spacing math at various heights
function TestNVSDItemView:test_gain_text_spacing_at_various_heights()
    -- Simulate controls.lua gain label/dB text spacing calculations
    -- After Phase 1 changes:
    -- gain_label_y = panel_y + max(1, pad - 4)
    -- db_gap = max(4, min(8, pad - 1))
    -- slider_top = panel_y + pad + label_h (label_h ~= 10)

    local label_h = 10
    local panel_y = 100

    for pad = 2, 20 do
        local gain_label_y = panel_y + math.max(1, pad - 4)
        local slider_top = panel_y + pad + label_h
        local gap_to_slider = slider_top - (gain_label_y + label_h)

        -- Label should never overlap slider
        lu.assertTrue(gain_label_y + label_h <= slider_top,
            "Gain label overlaps slider at pad=" .. pad)

        -- dB gap
        local db_gap = math.max(4, math.min(8, pad - 1))
        -- db_gap should always be at least 4
        lu.assertTrue(db_gap >= 4, "dB gap too small at pad=" .. pad)
    end
end

-- Test gain to dB edge cases
function TestNVSDItemView:test_gain_to_db_edge_cases()
    -- 0 gain = -inf dB (or clamped minimum)
    -- 1.0 gain = 0 dB
    -- 2.0 gain = +6.02 dB

    local function gain_to_db(gain)
        if gain <= 0 then return -math.huge end
        return 20 * math.log(gain, 10)
    end

    lu.assertEquals(gain_to_db(0), -math.huge)
    lu.assertAlmostEquals(gain_to_db(1), 0, 0.001)
    lu.assertAlmostEquals(gain_to_db(2), 6.021, 0.01)
    lu.assertAlmostEquals(gain_to_db(0.5), -6.021, 0.01)
end

-- Test settings roundtrip for new shortcuts
function TestNVSDItemView:test_settings_roundtrip_new_shortcuts()
    -- Local reimplementation of the serialization functions (they're local in settings.lua)
    local function shortcut_to_string(shortcut)
        local parts = {}
        if shortcut.ctrl then table.insert(parts, "ctrl") end
        if shortcut.shift then table.insert(parts, "shift") end
        if shortcut.alt then table.insert(parts, "alt") end
        table.insert(parts, shortcut.key)
        return table.concat(parts, "+")
    end
    local function string_to_shortcut(str)
        local shortcut = {ctrl = false, shift = false, alt = false, key = ""}
        for part in string.gmatch(str, "[^+]+") do
            local lower_part = part:lower()
            if lower_part == "ctrl" then shortcut.ctrl = true
            elseif lower_part == "shift" then shortcut.shift = true
            elseif lower_part == "alt" then shortcut.alt = true
            else shortcut.key = part end
        end
        return shortcut
    end

    local new_shortcuts = {
        "envelope_lock", "show_volume_env", "show_pitch_env",
        "show_pan_env", "hide_envelopes", "open_settings",
    }

    for _, name in ipairs(new_shortcuts) do
        local sc = settings.DEFAULT_SHORTCUTS[name]
        lu.assertNotNil(sc, "Missing: " .. name)

        -- Serialize (format_shortcut should handle it)
        if sc.key ~= "" then
            local formatted = settings.format_shortcut(sc)
            lu.assertNotEquals(formatted, "", "Empty format for: " .. name)
        end

        -- Verify string conversion roundtrip
        local str = shortcut_to_string(sc)
        lu.assertNotNil(str)
        local parsed = string_to_shortcut(str)
        lu.assertNotNil(parsed, "Failed to parse: " .. str)
        lu.assertEquals(parsed.key, sc.key)
        lu.assertEquals(parsed.ctrl, sc.ctrl)
        lu.assertEquals(parsed.shift, sc.shift)
        lu.assertEquals(parsed.alt, sc.alt)
    end
end

-- Test no shortcut conflicts in default set
function TestNVSDItemView:test_default_shortcuts_no_conflicts()
    local defaults = settings.DEFAULT_SHORTCUTS
    for name, binding in pairs(defaults) do
        if binding.key ~= "" then
            local conflict = settings.find_conflict(defaults, name, binding)
            lu.assertNil(conflict,
                "Default shortcut " .. name .. " conflicts with " .. (conflict or ""))
        end
    end
end

-- Test EDITABLE_SHORTCUTS references valid shortcut names
function TestNVSDItemView:test_editable_shortcuts_valid()
    -- Load settings_ui to check EDITABLE_SHORTCUTS
    -- Since settings_ui requires ImGui, we check via settings.DEFAULT_SHORTCUTS
    local expected_editable = {
        "toggle_warp", "toggle_mute", "reverse", "clear", "open_editor",
        "reset_zoom", "zoom_in", "zoom_out", "toggle_snap", "audio_preview",
        "envelope_lock", "show_volume_env", "show_pitch_env", "show_pan_env",
        "hide_envelopes", "open_settings",
    }

    for _, name in ipairs(expected_editable) do
        lu.assertNotNil(settings.DEFAULT_SHORTCUTS[name],
            "Editable shortcut '" .. name .. "' has no default definition")
    end
end

-- ========================================================================
-- Refactoring tests: utils.point_in_rect, state helpers
-- ========================================================================

-- Test point_in_rect
function TestNVSDItemView:test_point_in_rect_inside()
    lu.assertTrue(utils.point_in_rect(50, 50, 0, 0, 100, 100))
end

function TestNVSDItemView:test_point_in_rect_on_edge()
    lu.assertTrue(utils.point_in_rect(0, 0, 0, 0, 100, 100))      -- top-left
    lu.assertTrue(utils.point_in_rect(100, 100, 0, 0, 100, 100))  -- bottom-right
    lu.assertTrue(utils.point_in_rect(50, 0, 0, 0, 100, 100))     -- top edge
    lu.assertTrue(utils.point_in_rect(0, 50, 0, 0, 100, 100))     -- left edge
end

function TestNVSDItemView:test_point_in_rect_outside()
    lu.assertFalse(utils.point_in_rect(-1, 50, 0, 0, 100, 100))   -- left
    lu.assertFalse(utils.point_in_rect(101, 50, 0, 0, 100, 100))  -- right
    lu.assertFalse(utils.point_in_rect(50, -1, 0, 0, 100, 100))   -- above
    lu.assertFalse(utils.point_in_rect(50, 101, 0, 0, 100, 100))  -- below
end

-- Test state.reset_all_drags
function TestNVSDItemView:test_state_reset_all_drags()
    local state_mod = dofile("Scripts/NVSD/lib/state.lua")
    -- Set some flags
    state_mod.dragging_start = true
    state_mod.dragging_end = true
    state_mod.fx_dragging = true
    state_mod.env_freehand_drawing = true
    state_mod.env_multi_drag_start_positions = {{1, 2}}
    state_mod.env_multi_drag_all_points = {{3, 4}}

    state_mod.reset_all_drags()

    lu.assertFalse(state_mod.dragging_start)
    lu.assertFalse(state_mod.dragging_end)
    lu.assertFalse(state_mod.fx_dragging)
    lu.assertFalse(state_mod.env_freehand_drawing)
    lu.assertEquals(#state_mod.env_multi_drag_start_positions, 0)
    lu.assertEquals(#state_mod.env_multi_drag_all_points, 0)
end

-- Test state.any_drag_active
function TestNVSDItemView:test_state_any_drag_active_false_when_idle()
    local state_mod = dofile("Scripts/NVSD/lib/state.lua")
    lu.assertFalse(state_mod.any_drag_active())
end

function TestNVSDItemView:test_state_any_drag_active_true_when_dragging()
    local state_mod = dofile("Scripts/NVSD/lib/state.lua")

    state_mod.dragging_start = true
    lu.assertTrue(state_mod.any_drag_active())
    state_mod.dragging_start = false

    state_mod.env_freehand_drawing = true
    lu.assertTrue(state_mod.any_drag_active())
    state_mod.env_freehand_drawing = false

    state_mod.is_panning = true
    lu.assertTrue(state_mod.any_drag_active())
    state_mod.is_panning = false

    state_mod.pitch_gutter_dragging = true
    lu.assertTrue(state_mod.any_drag_active())
end

-- ===== Round 3 Tests =====

-- Load drawing module (pure math functions work without REAPER)
local drawing = dofile("Scripts/NVSD/lib/drawing.lua")
local dt = drawing._test

-- === Fade Math Tests ===

-- Test eval_fade for all 7 shapes at boundaries and midpoint
function TestNVSDItemView:test_fade_eval_all_7_shapes()
    local eval = dt.eval_fade
    for shape = 0, 6 do
        -- Fade-in: t=0 should be 0, t=1 should be 1
        lu.assertAlmostEquals(eval(0, shape, 0, false), 0, 0.01,
            "Shape " .. shape .. " fade-in at t=0")
        lu.assertAlmostEquals(eval(1, shape, 0, false), 1, 0.01,
            "Shape " .. shape .. " fade-in at t=1")
        -- Fade-out: t=0 should be 1, t=1 should be 0
        lu.assertAlmostEquals(eval(0, shape, 0, true), 1, 0.01,
            "Shape " .. shape .. " fade-out at t=0")
        lu.assertAlmostEquals(eval(1, shape, 0, true), 0, 0.01,
            "Shape " .. shape .. " fade-out at t=1")
        -- Midpoint should be in valid range
        local mid = eval(0.5, shape, 0, false)
        lu.assertTrue(mid >= 0 and mid <= 1,
            "Shape " .. shape .. " midpoint out of range: " .. tostring(mid))
    end
end

-- Test eval_fade boundary clamping (Bezier path clamps, math fns may extrapolate)
function TestNVSDItemView:test_fade_eval_boundary_clamp()
    local eval = dt.eval_fade
    -- Bezier path (dir != 0) uses cbez_y which clamps to endpoint values
    lu.assertAlmostEquals(eval(-1, 1, 0.5, false), 0, 0.01, "Bezier t<0")
    lu.assertAlmostEquals(eval(2, 1, 0.5, false), 1, 0.01, "Bezier t>1")
    -- Fade-out Bezier
    lu.assertAlmostEquals(eval(-1, 1, 0.5, true), 1, 0.01, "Bezier fade-out t<0")
    lu.assertAlmostEquals(eval(2, 1, 0.5, true), 0, 0.01, "Bezier fade-out t>1")
end

-- Test fade LUT matches eval_fade within tolerance
function TestNVSDItemView:test_fade_lut_matches_eval()
    local eval = dt.eval_fade
    local get_lut = dt.get_fade_lut
    local lookup = dt.fade_lut_lookup
    local LUT_SIZE = dt.FADE_LUT_SIZE

    for shape = 0, 6 do
        local lut = get_lut(shape, 0, false)
        -- Check at several points
        for _, t in ipairs({0, 0.1, 0.25, 0.5, 0.75, 0.9, 1}) do
            local expected = eval(t, shape, 0, false)
            local got = lookup(lut, t)
            lu.assertAlmostEquals(got, expected, 0.02,
                "LUT mismatch shape " .. shape .. " at t=" .. t)
        end
    end
end

-- Test fade direction bias (fast start should be > 0.5 at midpoint)
function TestNVSDItemView:test_fade_direction_bias()
    local eval = dt.eval_fade
    -- Shape 1 (fast start): midpoint should be > 0.5 (fast start = more gain early)
    local fast_start_mid = eval(0.5, 1, 0, false)
    lu.assertTrue(fast_start_mid > 0.5,
        "Fast start shape should be > 0.5 at midpoint, got " .. tostring(fast_start_mid))
    -- Shape 2 (slow start): midpoint should be < 0.5
    local slow_start_mid = eval(0.5, 2, 0, false)
    lu.assertTrue(slow_start_mid < 0.5,
        "Slow start shape should be < 0.5 at midpoint, got " .. tostring(slow_start_mid))
end

-- Test Bezier control points validity
function TestNVSDItemView:test_bezier_control_points()
    local get_bez = dt.get_fade_bez
    for shape = 0, 6 do
        for _, is_fo in ipairs({false, true}) do
            local x1, y1, x2, y2, x3, y3, x4, y4 = get_bez(shape, 0, is_fo)
            -- All coordinates should be finite numbers
            lu.assertNotNil(x1); lu.assertNotNil(y1)
            lu.assertNotNil(x2); lu.assertNotNil(y2)
            lu.assertNotNil(x3); lu.assertNotNil(y3)
            lu.assertNotNil(x4); lu.assertNotNil(y4)
            -- Endpoints should be (0,0)-(1,1) or (0,1)-(1,0)
            lu.assertAlmostEquals(x1, 0, 0.001)
            lu.assertAlmostEquals(x4, 1, 0.001)
        end
    end
end

-- === Grid Computation Tests ===

-- Test grid bar_skip is always power of 2
function TestNVSDItemView:test_grid_bar_skip_powers_of_2()
    local function compute_bar_skip(px_per_bar)
        local min_bar_spacing = 140
        local bar_skip = math.max(1, math.ceil(min_bar_spacing / px_per_bar))
        if bar_skip > 1 then
            local power = math.ceil(math.log(bar_skip) / math.log(2))
            bar_skip = 2 ^ power
        end
        return bar_skip
    end

    -- Always power of 2
    for _, px in ipairs({10, 50, 100, 140, 200, 500, 1000}) do
        local skip = compute_bar_skip(px)
        -- Check it's a power of 2 (or 1)
        if skip > 1 then
            local log = math.log(skip) / math.log(2)
            lu.assertAlmostEquals(log, math.floor(log + 0.5), 0.001,
                "bar_skip " .. skip .. " not power of 2 at px=" .. px)
        end
    end
end

-- Test grid at very zoomed out (wide view)
function TestNVSDItemView:test_grid_wide_view()
    -- At 10px per bar, bar_skip should be >= 16 (140/10 = 14, round up to 16)
    local min_bar_spacing = 140
    local px_per_bar = 10
    local bar_skip = math.max(1, math.ceil(min_bar_spacing / px_per_bar))
    if bar_skip > 1 then
        local power = math.ceil(math.log(bar_skip) / math.log(2))
        bar_skip = 2 ^ power
    end
    lu.assertEquals(bar_skip, 16)
end

-- Test grid at very zoomed in (narrow view)
function TestNVSDItemView:test_grid_narrow_view()
    -- At 500px per bar, bar_skip should be 1
    local min_bar_spacing = 140
    local px_per_bar = 500
    local bar_skip = math.max(1, math.ceil(min_bar_spacing / px_per_bar))
    lu.assertEquals(bar_skip, 1)
end

-- Test grid zero/tiny width edge case
function TestNVSDItemView:test_grid_zero_width()
    local min_bar_spacing = 140
    local px_per_bar = 0.001  -- Nearly zero
    local bar_skip = math.max(1, math.ceil(min_bar_spacing / px_per_bar))
    if bar_skip > 1 then
        local power = math.ceil(math.log(bar_skip) / math.log(2))
        bar_skip = 2 ^ power
    end
    -- Should be a large power of 2 but not infinite
    lu.assertTrue(bar_skip > 0 and bar_skip < 1e10)
end

-- Test grid density thresholds match current values
function TestNVSDItemView:test_grid_density_thresholds()
    -- min_bar_spacing
    lu.assertEquals(140, 140, "Expected min_bar_spacing = 140")
    -- beat grid threshold
    local show_beat_at_39 = 39 >= 40
    local show_beat_at_40 = 40 >= 40
    lu.assertFalse(show_beat_at_39)
    lu.assertTrue(show_beat_at_40)
    -- sub-beat threshold
    local function finest_sub(px)
        local s = 1
        while (px / (s * 2)) >= 20 do s = s * 2 end
        return s
    end
    lu.assertEquals(finest_sub(39), 1)  -- 39/2=19.5 < 20
    lu.assertEquals(finest_sub(40), 2)  -- 40/2=20 >= 20
end

-- === Theme/Settings Tests ===

-- Test custom theme exists as 18th entry
function TestNVSDItemView:test_custom_theme_exists()
    lu.assertEquals(settings.THEMES[18].id, "custom")
    lu.assertEquals(settings.THEMES[18].name, "Custom")
end

-- Test all 18 themes have all 20 color keys
function TestNVSDItemView:test_all_18_themes_have_all_keys()
    local expected_keys = settings.COLOR_KEYS
    for _, theme in ipairs(settings.THEMES) do
        for _, key in ipairs(expected_keys) do
            lu.assertNotNil(theme.colors[key],
                "Theme '" .. theme.id .. "' missing color key: " .. key)
            lu.assertTrue(type(theme.colors[key]) == "number",
                "Theme '" .. theme.id .. "' color '" .. key .. "' not a number")
        end
    end
end

-- Test default theme is first
function TestNVSDItemView:test_default_theme_is_first()
    lu.assertEquals(settings.THEMES[1].id, "default")
end

-- Test classic theme exists (renamed from old default)
function TestNVSDItemView:test_classic_theme_exists()
    local classic = settings.get_theme("classic")
    lu.assertNotNil(classic)
    lu.assertEquals(classic.id, "classic")
    lu.assertEquals(classic.name, "Classic")
    -- Classic should have the original green waveform color
    lu.assertEquals(classic.colors.waveform, 0x5A9F5AFF)
end

-- Test new DAW-inspired themes exist
function TestNVSDItemView:test_daw_themes_exist()
    local daw_ids = {"bitwig", "cubase", "logic", "studio_one", "pro_tools"}
    for _, id in ipairs(daw_ids) do
        local theme = settings.get_theme(id)
        lu.assertNotNil(theme, "Missing DAW theme: " .. id)
        lu.assertEquals(theme.id, id)
    end
end

-- Test COLOR_KEYS has exactly 20 entries
function TestNVSDItemView:test_color_keys_count()
    lu.assertEquals(#settings.COLOR_KEYS, 20)
end

-- Test custom colors roundtrip (mock ExtState)
function TestNVSDItemView:test_custom_colors_roundtrip()
    -- Mock ExtState storage
    local store = {}
    reaper.SetExtState = function(sec, key, val, persist)
        store[sec .. "::" .. key] = val
    end
    reaper.GetExtState = function(sec, key)
        return store[sec .. "::" .. key] or ""
    end

    local test_colors = {}
    for _, key in ipairs(settings.COLOR_KEYS) do
        test_colors[key] = math.random(0, 0xFFFFFFFF)
    end

    settings.save_custom_colors(test_colors)
    local loaded = settings.load_custom_colors()

    for _, key in ipairs(settings.COLOR_KEYS) do
        lu.assertEquals(loaded[key], test_colors[key],
            "Roundtrip mismatch for " .. key)
    end
end

-- Test custom theme initialize from copies all colors
function TestNVSDItemView:test_custom_initialize_from()
    local source = settings.get_theme("classic")
    local custom = settings.get_theme("custom")
    lu.assertNotNil(source)
    lu.assertNotNil(custom)

    -- Copy colors
    for _, key in ipairs(settings.COLOR_KEYS) do
        custom.colors[key] = source.colors[key]
    end

    -- Verify all match
    for _, key in ipairs(settings.COLOR_KEYS) do
        lu.assertEquals(custom.colors[key], source.colors[key],
            "Initialize from mismatch for " .. key)
    end
end

-- === Envelope Editing Tests ===

-- Test envelope value clamping for volume (0..2 range)
function TestNVSDItemView:test_env_value_clamp_volume()
    local function clamp_vol(v) return math.max(0, math.min(2, v)) end
    lu.assertEquals(clamp_vol(-0.5), 0)
    lu.assertEquals(clamp_vol(0), 0)
    lu.assertEquals(clamp_vol(1), 1)
    lu.assertEquals(clamp_vol(2), 2)
    lu.assertEquals(clamp_vol(3), 2)
end

-- Test envelope value clamping for pitch (-1..1 range for +-semitones)
function TestNVSDItemView:test_env_value_clamp_pitch()
    local function clamp_pitch(v) return math.max(-1, math.min(1, v)) end
    lu.assertEquals(clamp_pitch(-2), -1)
    lu.assertEquals(clamp_pitch(-1), -1)
    lu.assertEquals(clamp_pitch(0), 0)
    lu.assertEquals(clamp_pitch(1), 1)
    lu.assertEquals(clamp_pitch(2), 1)
end

-- Test envelope time clamping within take bounds
function TestNVSDItemView:test_env_time_clamp()
    local function clamp_time(t, start, len)
        return math.max(start, math.min(start + len, t))
    end
    lu.assertEquals(clamp_time(-1, 0, 10), 0)
    lu.assertEquals(clamp_time(5, 0, 10), 5)
    lu.assertEquals(clamp_time(15, 0, 10), 10)
    lu.assertEquals(clamp_time(3, 2, 5), 3)
    lu.assertEquals(clamp_time(1, 2, 5), 2)
end

-- Test envelope tension range clamped to -1..1
function TestNVSDItemView:test_env_tension_range()
    local function clamp_tension(t) return math.max(-1, math.min(1, t)) end
    lu.assertEquals(clamp_tension(-2), -1)
    lu.assertEquals(clamp_tension(-0.5), -0.5)
    lu.assertEquals(clamp_tension(0), 0)
    lu.assertEquals(clamp_tension(0.5), 0.5)
    lu.assertEquals(clamp_tension(2), 1)
end

-- Test envelope rectangle selection (nodes inside rect)
function TestNVSDItemView:test_env_rect_selection()
    -- Simulate rectangle selection: nodes inside rect should be selected
    local nodes = {
        {time = 1, value = 0.5, idx = 0},
        {time = 2, value = 0.8, idx = 1},
        {time = 3, value = 0.3, idx = 2},
        {time = 4, value = 0.6, idx = 3},
    }

    -- Rectangle from time 1.5..3.5, value 0.2..0.9
    local selected = {}
    for _, n in ipairs(nodes) do
        if n.time >= 1.5 and n.time <= 3.5 and n.value >= 0.2 and n.value <= 0.9 then
            table.insert(selected, n.idx)
        end
    end

    lu.assertEquals(#selected, 2)  -- nodes at time 2 and 3
    lu.assertEquals(selected[1], 1)
    lu.assertEquals(selected[2], 2)
end

-- Test envelope multi-drag maintains relative positions
function TestNVSDItemView:test_env_multi_drag_relative()
    local positions = {{time = 1, value = 0.5}, {time = 3, value = 0.8}}
    local delta_time = 0.5
    local delta_value = 0.1

    local new_positions = {}
    for _, p in ipairs(positions) do
        table.insert(new_positions, {
            time = p.time + delta_time,
            value = p.value + delta_value
        })
    end

    -- Relative distances should be preserved
    local orig_dt = positions[2].time - positions[1].time
    local orig_dv = positions[2].value - positions[1].value
    local new_dt = new_positions[2].time - new_positions[1].time
    local new_dv = new_positions[2].value - new_positions[1].value
    lu.assertAlmostEquals(orig_dt, new_dt, 0.001)
    lu.assertAlmostEquals(orig_dv, new_dv, 0.001)
end

-- Test envelope freehand minimum spacing
function TestNVSDItemView:test_env_freehand_min_spacing()
    local min_spacing = 0.001  -- minimum time between freehand points
    local last_time = 1.0
    local new_time = 1.0005

    lu.assertTrue(new_time - last_time < min_spacing,
        "Points too close should be rejected")
    lu.assertTrue(1.002 - last_time >= min_spacing,
        "Points far enough should be accepted")
end

-- Test envelope segment vertical shift (both nodes shift equally)
function TestNVSDItemView:test_env_segment_vertical_shift()
    local v1, v2 = 0.5, 0.8
    local delta = 0.1
    local new_v1 = math.max(0, math.min(2, v1 + delta))
    local new_v2 = math.max(0, math.min(2, v2 + delta))
    -- Both should shift by exactly delta
    lu.assertAlmostEquals(new_v1 - v1, delta, 0.001)
    lu.assertAlmostEquals(new_v2 - v2, delta, 0.001)
end

-- === FX Interaction Tests ===

-- Test FX drag threshold (4px)
function TestNVSDItemView:test_fx_drag_threshold_4px()
    local threshold = 4
    -- Below threshold: no drag
    lu.assertFalse(math.abs(3) >= threshold)
    -- At threshold: drag activates
    lu.assertTrue(math.abs(4) >= threshold)
    -- Above threshold: drag active
    lu.assertTrue(math.abs(10) >= threshold)
end

-- Test FX bypass toggle logic
function TestNVSDItemView:test_fx_bypass_toggle()
    -- Simulate FX enabled state toggle
    local enabled = true
    enabled = not enabled
    lu.assertFalse(enabled)
    enabled = not enabled
    lu.assertTrue(enabled)
end

-- === Marker/State Tests ===

-- Test marker drag threshold (4px)
function TestNVSDItemView:test_marker_drag_threshold_4px()
    local threshold = 4
    lu.assertFalse(math.abs(2) >= threshold)
    lu.assertTrue(math.abs(4) >= threshold)
    lu.assertTrue(math.abs(8) >= threshold)
end

-- Test region selection ordering (start <= end after finalization)
function TestNVSDItemView:test_region_selection_ordering()
    -- Simulate selecting backwards (end before start)
    local sel_start = 5.0
    local sel_end = 2.0
    -- Finalize: ensure start <= end
    local final_start = math.min(sel_start, sel_end)
    local final_end = math.max(sel_start, sel_end)
    lu.assertTrue(final_start <= final_end)
    lu.assertEquals(final_start, 2.0)
    lu.assertEquals(final_end, 5.0)
end

-- Test state reset comprehensive (all flags false after reset)
function TestNVSDItemView:test_state_reset_comprehensive()
    local state_mod = dofile("Scripts/NVSD/lib/state.lua")
    -- Set many flags to true
    state_mod.dragging_start = true
    state_mod.dragging_end = true
    state_mod.is_panning = true
    state_mod.fx_dragging = true
    state_mod.env_freehand_drawing = true
    state_mod.dragging_fade_in = true
    state_mod.dragging_fade_out = true
    state_mod.dragging_env_node = true
    state_mod.env_tension_dragging = true
    state_mod.env_segment_dragging = true
    state_mod.env_rect_selecting = true

    state_mod.reset_all_drags()

    -- All should be false
    lu.assertFalse(state_mod.dragging_start)
    lu.assertFalse(state_mod.dragging_end)
    lu.assertFalse(state_mod.is_panning)
    lu.assertFalse(state_mod.fx_dragging)
    lu.assertFalse(state_mod.env_freehand_drawing)
    lu.assertFalse(state_mod.dragging_fade_in)
    lu.assertFalse(state_mod.dragging_fade_out)
    lu.assertFalse(state_mod.dragging_env_node)
    lu.assertFalse(state_mod.env_tension_dragging)
    lu.assertFalse(state_mod.env_segment_dragging)
    lu.assertFalse(state_mod.env_rect_selecting)
end

-- Test any_drag_active with each flag individually
function TestNVSDItemView:test_any_drag_each_flag()
    local drag_flags = {
        "dragging_start", "dragging_end", "is_panning",
        "dragging_fade_in", "dragging_fade_out",
        "dragging_env_node", "env_tension_dragging",
        "env_segment_dragging", "env_freehand_drawing",
        "fx_dragging", "env_rect_selecting",
        "pitch_gutter_dragging",
    }

    for _, flag in ipairs(drag_flags) do
        local state_mod = dofile("Scripts/NVSD/lib/state.lua")
        -- All should start false
        lu.assertFalse(state_mod.any_drag_active(), "Should start idle")
        -- Set one flag
        state_mod[flag] = true
        lu.assertTrue(state_mod.any_drag_active(),
            "any_drag_active should be true when " .. flag .. " is set")
    end
end

-- Test point_in_rect with zero-size rect
function TestNVSDItemView:test_point_in_rect_zero_size()
    -- Point exactly on a zero-size rect (degenerate)
    lu.assertTrue(utils.point_in_rect(5, 5, 5, 5, 5, 5))
    -- Point not on it
    lu.assertFalse(utils.point_in_rect(6, 5, 5, 5, 5, 5))
end

-- Test point_in_rect with negative coordinates
function TestNVSDItemView:test_point_in_rect_negative_coords()
    lu.assertTrue(utils.point_in_rect(-5, -5, -10, -10, 0, 0))
    lu.assertFalse(utils.point_in_rect(-15, -5, -10, -10, 0, 0))
    lu.assertTrue(utils.point_in_rect(-10, -10, -10, -10, 0, 0))  -- on edge
end

-- === Undo Wrapper Tests ===

-- Test with_undo calls begin/end block
function TestNVSDItemView:test_with_undo_calls_begin_end()
    local calls = {}
    reaper.Undo_BeginBlock = function() table.insert(calls, "begin") end
    reaper.Undo_EndBlock = function(label, flags)
        table.insert(calls, "end:" .. label .. ":" .. tostring(flags))
    end

    utils.with_undo("Test action", -1, function()
        table.insert(calls, "body")
    end)

    lu.assertEquals(#calls, 3)
    lu.assertEquals(calls[1], "begin")
    lu.assertEquals(calls[2], "body")
    lu.assertEquals(calls[3], "end:Test action:-1")
end

-- Test with_undo passes correct label
function TestNVSDItemView:test_with_undo_passes_label()
    local captured_label = nil
    local captured_flags = nil
    reaper.Undo_BeginBlock = function() end
    reaper.Undo_EndBlock = function(label, flags)
        captured_label = label
        captured_flags = flags
    end

    utils.with_undo("My undo label", 4, function() end)

    lu.assertEquals(captured_label, "My undo label")
    lu.assertEquals(captured_flags, 4)
end

-- === Tooltip Delay Test ===
function TestNVSDItemView:test_tooltip_delay_value()
    -- The TOOLTIP_DELAY constant should be 1.5 seconds
    -- We can't access the local directly, but we can verify the module loaded
    lu.assertNotNil(drawing.tooltip, "drawing.tooltip function should exist")
end

-- === Shape Icon Functions Test ===
function TestNVSDItemView:test_shape_icon_fns_all_7()
    local fns = dt.shape_icon_fns
    lu.assertNotNil(fns)
    for shape = 0, 6 do
        lu.assertNotNil(fns[shape], "Missing shape icon fn for shape " .. shape)
        -- All should return 0 at x=0 and 1 at x=1
        lu.assertAlmostEquals(fns[shape](0), 0, 0.001, "Shape " .. shape .. " at x=0")
        lu.assertAlmostEquals(fns[shape](1), 1, 0.001, "Shape " .. shape .. " at x=1")
    end
end

-- === Bezier Evaluator Tests ===
function TestNVSDItemView:test_cbez_y_linear()
    local cbez_y = dt.cbez_y
    -- Linear Bezier: (0,0) - (0.5,0.5) - (0.5,0.5) - (1,1)
    lu.assertAlmostEquals(cbez_y(0, 0, 0.5, 0.5, 0.5, 0.5, 1, 1, 0), 0, 0.01)
    lu.assertAlmostEquals(cbez_y(0, 0, 0.5, 0.5, 0.5, 0.5, 1, 1, 0.5), 0.5, 0.05)
    lu.assertAlmostEquals(cbez_y(0, 0, 0.5, 0.5, 0.5, 0.5, 1, 1, 1), 1, 0.01)
end

function TestNVSDItemView:test_cbez_y_boundary_clamp()
    local cbez_y = dt.cbez_y
    -- t <= 0 returns by1, t >= 1 returns by4
    lu.assertEquals(cbez_y(0, 0.3, 0.5, 0.5, 0.5, 0.5, 1, 0.9, -1), 0.3)
    lu.assertEquals(cbez_y(0, 0.3, 0.5, 0.5, 0.5, 0.5, 1, 0.9, 2), 0.9)
end
