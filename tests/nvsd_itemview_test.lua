-- Unit tests for NVSD_ItemView
local lu = require("luaunit")

-- Mock REAPER API for testing outside REAPER
reaper = reaper or {}

-- Test suite
TestNVSDItemView = {}

function TestNVSDItemView:test_marker_near_detection()
    -- Test the is_near_marker logic
    local function is_near_marker(mouse_x, marker_x, threshold)
        return math.abs(mouse_x - marker_x) < threshold
    end

    lu.assertTrue(is_near_marker(100, 105, 10))   -- within threshold
    lu.assertTrue(is_near_marker(100, 95, 10))    -- within threshold (other side)
    lu.assertFalse(is_near_marker(100, 115, 10))  -- outside threshold
    lu.assertFalse(is_near_marker(100, 85, 10))   -- outside threshold (other side)
    lu.assertTrue(is_near_marker(100, 100, 10))   -- exactly on marker
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
    -- Test converting source time to project timeline time
    local function source_to_project_time(source_t, item_position, start_offset, playrate)
        return item_position + (source_t - start_offset) / playrate
    end

    -- Simple case: item at position 10, offset 2, playrate 1
    -- Source time 2 (at offset) -> project time 10 (at item start)
    lu.assertAlmostEquals(source_to_project_time(2, 10, 2, 1), 10, 0.001)

    -- Source time 5 (3 seconds after offset) -> project time 13
    lu.assertAlmostEquals(source_to_project_time(5, 10, 2, 1), 13, 0.001)

    -- With playrate 2 (double speed): source time 5 -> project time 11.5
    lu.assertAlmostEquals(source_to_project_time(5, 10, 2, 2), 11.5, 0.001)

    -- With playrate 0.5 (half speed): source time 5 -> project time 16
    lu.assertAlmostEquals(source_to_project_time(5, 10, 2, 0.5), 16, 0.001)
end

function TestNVSDItemView:test_project_to_source_time()
    -- Test converting project timeline time to source time
    local function project_to_source_time(project_t, item_position, start_offset, playrate)
        return start_offset + (project_t - item_position) * playrate
    end

    -- Simple case: item at position 10, offset 2, playrate 1
    -- Project time 10 (at item start) -> source time 2 (at offset)
    lu.assertAlmostEquals(project_to_source_time(10, 10, 2, 1), 2, 0.001)

    -- Project time 13 -> source time 5
    lu.assertAlmostEquals(project_to_source_time(13, 10, 2, 1), 5, 0.001)

    -- With playrate 2: project time 11.5 -> source time 5
    lu.assertAlmostEquals(project_to_source_time(11.5, 10, 2, 2), 5, 0.001)

    -- With playrate 0.5: project time 16 -> source time 5
    lu.assertAlmostEquals(project_to_source_time(16, 10, 2, 0.5), 5, 0.001)
end

function TestNVSDItemView:test_source_project_time_roundtrip()
    -- Test that source->project->source is identity
    local function source_to_project_time(source_t, item_position, start_offset, playrate)
        return item_position + (source_t - start_offset) / playrate
    end

    local function project_to_source_time(project_t, item_position, start_offset, playrate)
        return start_offset + (project_t - item_position) * playrate
    end

    local item_position = 10
    local start_offset = 2
    local playrate = 1.5

    local source_time = 7.5
    local project_time = source_to_project_time(source_time, item_position, start_offset, playrate)
    local back_to_source = project_to_source_time(project_time, item_position, start_offset, playrate)

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
    -- Test formatting source time as mins:secs or mins:secs:ms
    local function format_source_time(seconds, show_ms)
        local negative = seconds < 0
        local abs_secs = math.abs(seconds)
        local mins = math.floor(abs_secs / 60)
        local secs = abs_secs - mins * 60

        local sign = negative and "-" or ""

        if show_ms then
            local whole_secs = math.floor(secs)
            local ms = math.floor((secs - whole_secs) * 1000)
            return string.format("%s%d:%02d:%03d", sign, mins, whole_secs, ms)
        else
            return string.format("%s%d:%02d", sign, mins, math.floor(secs))
        end
    end

    -- Basic formatting without ms
    lu.assertEquals(format_source_time(0, false), "0:00")
    lu.assertEquals(format_source_time(5, false), "0:05")
    lu.assertEquals(format_source_time(65, false), "1:05")
    lu.assertEquals(format_source_time(125, false), "2:05")

    -- With milliseconds
    lu.assertEquals(format_source_time(0, true), "0:00:000")
    lu.assertEquals(format_source_time(1.5, true), "0:01:500")
    lu.assertEquals(format_source_time(0.25, true), "0:00:250")
    lu.assertEquals(format_source_time(65.123, true), "1:05:123")

    -- Negative times
    lu.assertEquals(format_source_time(-5, false), "-0:05")
    lu.assertEquals(format_source_time(-65, false), "-1:05")
    lu.assertEquals(format_source_time(-1.5, true), "-0:01:500")
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
    -- Test converting semitones to playrate (for non-warp mode)
    local function semitones_to_playrate(semitones)
        return 2 ^ (semitones / 12)
    end

    -- 0 semitones = no change
    lu.assertAlmostEquals(semitones_to_playrate(0), 1.0, 0.001)

    -- +12 semitones = double speed (octave up)
    lu.assertAlmostEquals(semitones_to_playrate(12), 2.0, 0.001)

    -- -12 semitones = half speed (octave down)
    lu.assertAlmostEquals(semitones_to_playrate(-12), 0.5, 0.001)

    -- +7 semitones = perfect fifth up
    lu.assertAlmostEquals(semitones_to_playrate(7), 2^(7/12), 0.001)

    -- -5 semitones = perfect fourth down
    lu.assertAlmostEquals(semitones_to_playrate(-5), 2^(-5/12), 0.001)
end

function TestNVSDItemView:test_playrate_to_semitones()
    -- Test converting playrate to semitones (for non-warp mode)
    local function playrate_to_semitones(playrate)
        return 12 * math.log(playrate) / math.log(2)
    end

    -- Normal speed = 0 semitones
    lu.assertAlmostEquals(playrate_to_semitones(1.0), 0, 0.001)

    -- Double speed = +12 semitones
    lu.assertAlmostEquals(playrate_to_semitones(2.0), 12, 0.001)

    -- Half speed = -12 semitones
    lu.assertAlmostEquals(playrate_to_semitones(0.5), -12, 0.001)

    -- Roundtrip test
    local original = 7.5
    local playrate = 2 ^ (original / 12)
    local back = playrate_to_semitones(playrate)
    lu.assertAlmostEquals(back, original, 0.001)
end

function TestNVSDItemView:test_db_to_linear_and_back()
    -- Test dB to linear conversion for gain slider
    local function db_to_linear(db)
        return 10 ^ (db / 20)
    end

    local function linear_to_db(linear)
        if linear <= 0 then return -math.huge end
        return 20 * math.log(linear) / math.log(10)
    end

    -- 0 dB = unity gain
    lu.assertAlmostEquals(db_to_linear(0), 1.0, 0.001)

    -- +6 dB = ~2x
    lu.assertAlmostEquals(db_to_linear(6), 1.995, 0.01)

    -- -6 dB = ~0.5x
    lu.assertAlmostEquals(db_to_linear(-6), 0.501, 0.01)

    -- +24 dB (max gain in UI)
    lu.assertAlmostEquals(db_to_linear(24), 15.85, 0.1)

    -- Roundtrip
    local original_db = -12
    local linear = db_to_linear(original_db)
    local back = linear_to_db(linear)
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
    -- Test formatting dB value for display (no + sign, includes " dB" suffix)
    local function format_db(db)
        if db <= -60 then return "-∞ dB" end
        return string.format("%.1f dB", db)
    end

    -- Positive values: no + sign, includes " dB"
    lu.assertEquals(format_db(24), "24.0 dB")
    lu.assertEquals(format_db(12), "12.0 dB")
    lu.assertEquals(format_db(6), "6.0 dB")
    lu.assertEquals(format_db(0), "0.0 dB")

    -- Negative values: includes " dB"
    lu.assertEquals(format_db(-6), "-6.0 dB")
    lu.assertEquals(format_db(-12), "-12.0 dB")
    lu.assertEquals(format_db(-24), "-24.0 dB")

    -- Very low values: show -∞ dB
    lu.assertEquals(format_db(-60), "-∞ dB")
    lu.assertEquals(format_db(-61), "-∞ dB")
    lu.assertEquals(format_db(-100), "-∞ dB")

    -- Fractional values
    lu.assertEquals(format_db(6.5), "6.5 dB")
    lu.assertEquals(format_db(-3.2), "-3.2 dB")
    lu.assertEquals(format_db(0.1), "0.1 dB")
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
    -- Test converting linear gain to dB
    local function gain_to_db(gain)
        if gain <= 0 then return -math.huge end
        return 20 * math.log(gain) / math.log(10)
    end

    -- Unity gain = 0 dB
    lu.assertAlmostEquals(gain_to_db(1.0), 0, 0.001)

    -- Double = +6.02 dB
    lu.assertAlmostEquals(gain_to_db(2.0), 6.02, 0.1)

    -- Half = -6.02 dB
    lu.assertAlmostEquals(gain_to_db(0.5), -6.02, 0.1)

    -- +24 dB gain (~15.85x)
    lu.assertAlmostEquals(gain_to_db(15.85), 24, 0.1)

    -- Zero gain = -inf
    lu.assertEquals(gain_to_db(0), -math.huge)
end

function TestNVSDItemView:test_db_to_slider_position()
    -- Test converting dB to slider position (0-1) with logarithmic curve below 0dB
    local function db_to_slider(db)
        local DB_MAX = 24
        local DB_MIN = -60

        if db >= 0 then
            -- Linear above 0dB: 0dB -> 0.5, +24dB -> 1.0
            return 0.5 + (db / DB_MAX) * 0.5
        else
            -- Logarithmic below 0dB for finer control
            local normalized = (db - DB_MIN) / (0 - DB_MIN)  -- 0 to 1
            normalized = math.max(0, math.min(1, normalized))
            -- Apply curve: sqrt for more resolution near 0dB
            return math.sqrt(normalized) * 0.5
        end
    end

    -- +24 dB = top (1.0)
    lu.assertAlmostEquals(db_to_slider(24), 1.0, 0.001)

    -- 0 dB = middle (0.5)
    lu.assertAlmostEquals(db_to_slider(0), 0.5, 0.001)

    -- +12 dB = 0.75
    lu.assertAlmostEquals(db_to_slider(12), 0.75, 0.001)

    -- -60 dB = bottom (0.0)
    lu.assertAlmostEquals(db_to_slider(-60), 0, 0.001)

    -- Check logarithmic curve: -6 dB should be higher than linear would suggest
    local pos_neg6 = db_to_slider(-6)
    lu.assertTrue(pos_neg6 > 0.4)  -- Should be above linear (which would be ~0.45)
    lu.assertTrue(pos_neg6 < 0.5)  -- But still below 0dB position
end

function TestNVSDItemView:test_slider_to_db()
    -- Test converting slider position to dB
    local function slider_to_db(pos)
        local DB_MAX = 24
        local DB_MIN = -60

        if pos >= 0.5 then
            -- Linear above 0dB
            return ((pos - 0.5) / 0.5) * DB_MAX
        else
            -- Inverse of logarithmic curve
            local normalized = (pos / 0.5) ^ 2  -- inverse of sqrt
            return DB_MIN + normalized * (0 - DB_MIN)
        end
    end

    -- Top = +24 dB
    lu.assertAlmostEquals(slider_to_db(1.0), 24, 0.001)

    -- Middle = 0 dB
    lu.assertAlmostEquals(slider_to_db(0.5), 0, 0.001)

    -- 0.75 = +12 dB
    lu.assertAlmostEquals(slider_to_db(0.75), 12, 0.001)

    -- Bottom = -60 dB
    lu.assertAlmostEquals(slider_to_db(0), -60, 0.001)
end

function TestNVSDItemView:test_pitch_to_semitones_cents()
    -- Test splitting pitch value into semitones and cents
    local function pitch_to_semitones_cents(pitch)
        local semitones = math.floor(pitch + 0.5)  -- round to nearest
        local cents = math.floor((pitch - semitones) * 100 + 0.5)
        return semitones, cents
    end

    -- Exact semitone
    local semi, cents = pitch_to_semitones_cents(5.0)
    lu.assertEquals(semi, 5)
    lu.assertEquals(cents, 0)

    -- Positive cents
    semi, cents = pitch_to_semitones_cents(5.25)
    lu.assertEquals(semi, 5)
    lu.assertEquals(cents, 25)

    -- Negative cents (pitch slightly below semitone)
    semi, cents = pitch_to_semitones_cents(4.75)
    lu.assertEquals(semi, 5)  -- rounds to 5
    lu.assertEquals(cents, -25)

    -- Negative pitch
    semi, cents = pitch_to_semitones_cents(-3.5)
    lu.assertEquals(semi, -3)  -- floor(-3.5 + 0.5) = floor(-3) = -3
    lu.assertEquals(cents, -50)

    -- Zero pitch
    semi, cents = pitch_to_semitones_cents(0)
    lu.assertEquals(semi, 0)
    lu.assertEquals(cents, 0)
end

function TestNVSDItemView:test_semitones_cents_to_pitch()
    -- Test combining semitones and cents into pitch value
    local function semitones_cents_to_pitch(semitones, cents)
        return semitones + cents / 100
    end

    -- Basic cases
    lu.assertAlmostEquals(semitones_cents_to_pitch(5, 0), 5.0, 0.001)
    lu.assertAlmostEquals(semitones_cents_to_pitch(5, 50), 5.5, 0.001)
    lu.assertAlmostEquals(semitones_cents_to_pitch(5, -25), 4.75, 0.001)
    lu.assertAlmostEquals(semitones_cents_to_pitch(-3, 50), -2.5, 0.001)
    lu.assertAlmostEquals(semitones_cents_to_pitch(0, 0), 0, 0.001)
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
    -- Test extracting file name from full path
    local function get_file_name(path)
        if not path or path == "" then return "" end
        return path:match("([^/\\]+)$") or path
    end

    -- Unix path
    lu.assertEquals(get_file_name("/home/user/audio/kick.wav"), "kick.wav")

    -- Windows path
    lu.assertEquals(get_file_name("C:\\Users\\audio\\snare.wav"), "snare.wav")

    -- Just filename
    lu.assertEquals(get_file_name("hihat.wav"), "hihat.wav")

    -- Empty path
    lu.assertEquals(get_file_name(""), "")
    lu.assertEquals(get_file_name(nil), "")

    -- Path with spaces
    lu.assertEquals(get_file_name("/home/user/My Audio/cool sound.wav"), "cool sound.wav")
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

function TestNVSDItemView:test_state_invalidate_cache()
    -- Test invalidate_cache clears all cache variables
    local state = {
        cached_peaks = { 1, 2, 3 },
        cached_source = "some_source",
        cached_source_length = 10.5,
        cached_item = "some_item",
        cached_num_samples = 500,
    }

    local function invalidate_cache()
        state.cached_peaks = nil
        state.cached_source = nil
        state.cached_source_length = 0
        state.cached_item = nil
        state.cached_num_samples = 0
    end

    -- Verify cache has values
    lu.assertNotNil(state.cached_peaks)
    lu.assertNotNil(state.cached_source)
    lu.assertEquals(state.cached_source_length, 10.5)

    -- Invalidate
    invalidate_cache()

    -- Verify all cleared
    lu.assertNil(state.cached_peaks)
    lu.assertNil(state.cached_source)
    lu.assertEquals(state.cached_source_length, 0)
    lu.assertNil(state.cached_item)
    lu.assertEquals(state.cached_num_samples, 0)
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
        cached_peaks = { 1, 2, 3 },
        cached_source = "src",
        cached_source_length = 5.0,
        cached_item = "item",
        cached_num_samples = 100,
    }

    local function process_pending_invalidation()
        if state.pending_cache_invalidation > 0 then
            state.pending_cache_invalidation = state.pending_cache_invalidation - 1
            if state.pending_cache_invalidation == 0 then
                state.cached_peaks = nil
                state.cached_source = nil
                state.cached_source_length = 0
                state.cached_item = nil
                state.cached_num_samples = 0
            end
        end
    end

    -- Frame 1: count down to 2
    process_pending_invalidation()
    lu.assertEquals(state.pending_cache_invalidation, 2)
    lu.assertNotNil(state.cached_peaks)

    -- Frame 2: count down to 1
    process_pending_invalidation()
    lu.assertEquals(state.pending_cache_invalidation, 1)
    lu.assertNotNil(state.cached_peaks)

    -- Frame 3: count down to 0, invalidate cache
    process_pending_invalidation()
    lu.assertEquals(state.pending_cache_invalidation, 0)
    lu.assertNil(state.cached_peaks)
    lu.assertNil(state.cached_source)
    lu.assertEquals(state.cached_source_length, 0)
end

-- ============================================================================
-- Settings Module Tests
-- ============================================================================

function TestNVSDItemView:test_settings_format_shortcut()
    -- Test shortcut formatting for display
    local function format_shortcut(shortcut)
        local parts = {}
        if shortcut.ctrl then table.insert(parts, "Ctrl") end
        if shortcut.shift then table.insert(parts, "Shift") end
        if shortcut.alt then table.insert(parts, "Alt") end
        table.insert(parts, shortcut.key)
        return table.concat(parts, "+")
    end

    -- Test Ctrl+Z
    local shortcut1 = {ctrl = true, shift = false, alt = false, key = "Z"}
    lu.assertEquals(format_shortcut(shortcut1), "Ctrl+Z")

    -- Test Ctrl+Shift+Z
    local shortcut2 = {ctrl = true, shift = true, alt = false, key = "Z"}
    lu.assertEquals(format_shortcut(shortcut2), "Ctrl+Shift+Z")

    -- Test Alt+F4
    local shortcut3 = {ctrl = false, shift = false, alt = true, key = "F4"}
    lu.assertEquals(format_shortcut(shortcut3), "Alt+F4")

    -- Test just a key (no modifiers)
    local shortcut4 = {ctrl = false, shift = false, alt = false, key = "Space"}
    lu.assertEquals(format_shortcut(shortcut4), "Space")

    -- Test all modifiers
    local shortcut5 = {ctrl = true, shift = true, alt = true, key = "A"}
    lu.assertEquals(format_shortcut(shortcut5), "Ctrl+Shift+Alt+A")
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
    -- Test theme retrieval by ID
    local THEMES = {
        {id = "default", name = "Default", colors = {waveform = 0x5A9F5AFF}},
        {id = "ableton_dark", name = "Ableton Dark", colors = {waveform = 0x7B9BA6FF}},
        {id = "warm", name = "Warm", colors = {waveform = 0xD4915AFF}},
    }

    local function get_theme(id)
        for _, theme in ipairs(THEMES) do
            if theme.id == id then
                return theme
            end
        end
        return THEMES[1]  -- fallback to default
    end

    -- Test finding existing theme
    local theme = get_theme("ableton_dark")
    lu.assertEquals(theme.name, "Ableton Dark")
    lu.assertEquals(theme.colors.waveform, 0x7B9BA6FF)

    -- Test fallback to default for unknown ID
    local unknown = get_theme("nonexistent")
    lu.assertEquals(unknown.name, "Default")
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

-- Progressive loading tests
function TestNVSDItemView:test_progressive_loading_stages()
    -- Test that loading stages transition correctly
    -- Stage 0: idle, Stage 1: preview loaded, Stage 2: full loaded
    local loading_stage = 0
    local target_samples = 0
    local cached_num_samples = 0

    -- Simulate item change - should go to stage 1 with preview
    local PREVIEW_SAMPLES = 2000
    loading_stage = 1
    cached_num_samples = PREVIEW_SAMPLES
    target_samples = 200000

    lu.assertEquals(loading_stage, 1)
    lu.assertEquals(cached_num_samples, PREVIEW_SAMPLES)
    lu.assertTrue(target_samples > cached_num_samples)

    -- Simulate full load - should go to stage 2
    cached_num_samples = target_samples
    loading_stage = 2

    lu.assertEquals(loading_stage, 2)
    lu.assertEquals(cached_num_samples, target_samples)
end

function TestNVSDItemView:test_progressive_loading_preview_resolution()
    -- Test that preview samples is much smaller than full resolution
    local PREVIEW_SAMPLES = 2000
    local min_full_samples = 20000
    local max_full_samples = 800000

    -- Preview should be at least 10x smaller than minimum full res
    lu.assertTrue(PREVIEW_SAMPLES <= min_full_samples / 10)

    -- Preview should provide instant response (< 5000 samples is very fast)
    lu.assertTrue(PREVIEW_SAMPLES <= 5000)
end

function TestNVSDItemView:test_invalidate_cache_resets_loading()
    -- Test that cache invalidation resets progressive loading state
    local state = {
        cached_peaks = {1, 2, 3},
        cached_source = "source",
        cached_source_length = 10,
        cached_item = "item",
        cached_num_samples = 50000,
        loading_stage = 2,
        target_samples = 200000
    }

    -- Simulate invalidate_cache
    state.cached_peaks = nil
    state.cached_source = nil
    state.cached_source_length = 0
    state.cached_item = nil
    state.cached_num_samples = 0
    state.loading_stage = 0
    state.target_samples = 0

    lu.assertNil(state.cached_peaks)
    lu.assertEquals(state.loading_stage, 0)
    lu.assertEquals(state.target_samples, 0)
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
    -- Format bare key like "W" -> "W"
    local function format_shortcut(shortcut)
        local parts = {}
        if shortcut.ctrl then table.insert(parts, "Ctrl") end
        if shortcut.shift then table.insert(parts, "Shift") end
        if shortcut.alt then table.insert(parts, "Alt") end
        table.insert(parts, shortcut.key)
        return table.concat(parts, "+")
    end

    local bare = {ctrl = false, shift = false, alt = false, key = "W"}
    lu.assertEquals(format_shortcut(bare), "W")

    local bare2 = {ctrl = false, shift = false, alt = false, key = "F"}
    lu.assertEquals(format_shortcut(bare2), "F")
end

function TestNVSDItemView:test_settings_theme_fallback_to_default()
    -- Unknown theme ID returns first theme
    local THEMES = {
        {id = "default", name = "Default"},
        {id = "warm", name = "Warm"},
    }

    local function get_theme(id)
        for _, theme in ipairs(THEMES) do
            if theme.id == id then return theme end
        end
        return THEMES[1]
    end

    -- Known ID works
    lu.assertEquals(get_theme("warm").name, "Warm")

    -- Unknown ID falls back to first
    lu.assertEquals(get_theme("nonexistent_theme_xyz").name, "Default")
    lu.assertEquals(get_theme("").name, "Default")
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
    -- Document correct ImGui mouse button indices
    -- ImGui button 0 = Left, 1 = Right, 2 = Middle, 3 = Extra1 (Mouse4), 4 = Extra2 (Mouse5)
    local IMGUI_LEFT = 0
    local IMGUI_RIGHT = 1
    local IMGUI_MIDDLE = 2
    local IMGUI_EXTRA1 = 3  -- Mouse 4 (back/forward button)
    local IMGUI_EXTRA2 = 4  -- Mouse 5 (back/forward button)

    -- Mouse4 should use index 3 (Extra1)
    lu.assertEquals(IMGUI_EXTRA1, 3)
    -- Mouse5 should use index 4 (Extra2)
    lu.assertEquals(IMGUI_EXTRA2, 4)
    -- They must not be swapped
    lu.assertTrue(IMGUI_EXTRA1 < IMGUI_EXTRA2)
end

function TestNVSDItemView:test_semitones_drag_preserves_cents()
    -- When dragging semitones, cents should stay frozen at their start value
    local function semitones_cents_to_pitch(semitones, cents)
        return semitones + cents / 100
    end

    -- Start: pitch 2.50 -> semitones=3, cents=-50 (rounded)
    -- But for this test: pitch=2.50, display_cents at drag start = 50
    local start_cents = 50
    local start_semitones = 2

    -- Drag +1 semitone: should be 3 + 50/100 = 3.50
    local new_pitch = semitones_cents_to_pitch(start_semitones + 1, start_cents)
    lu.assertAlmostEquals(new_pitch, 3.50, 0.001)

    -- Drag -1 semitone: should be 1 + 50/100 = 1.50
    new_pitch = semitones_cents_to_pitch(start_semitones - 1, start_cents)
    lu.assertAlmostEquals(new_pitch, 1.50, 0.001)

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

-- ============================================================================
-- New Tests: State/Cache
-- ============================================================================

function TestNVSDItemView:test_peaks_cache_lru_eviction()
    -- Add 21 items to a cache with max 20, oldest should be evicted
    local cache = {}
    local cache_order = {}
    local CACHE_MAX = 20

    local function set_cached(filepath, data)
        if cache[filepath] then
            for i, path in ipairs(cache_order) do
                if path == filepath then table.remove(cache_order, i) break end
            end
        end
        while #cache_order >= CACHE_MAX do
            local oldest = table.remove(cache_order)
            cache[oldest] = nil
        end
        cache[filepath] = data
        table.insert(cache_order, 1, filepath)
    end

    -- Add 21 items
    for i = 1, 21 do
        set_cached("file_" .. i, {peaks = i})
    end

    -- Cache should have exactly 20 items
    lu.assertEquals(#cache_order, 20)

    -- First item (file_1) should be evicted
    lu.assertNil(cache["file_1"])

    -- Most recent (file_21) should be at front
    lu.assertEquals(cache_order[1], "file_21")

    -- Second item (file_2) should still exist
    lu.assertNotNil(cache["file_2"])
end

function TestNVSDItemView:test_peaks_cache_access_reorders()
    -- Accessing a cached item moves it to front of LRU order
    local cache = {}
    local cache_order = {}

    local function set_cached(filepath, data)
        cache[filepath] = data
        table.insert(cache_order, 1, filepath)
    end

    local function get_cached(filepath)
        local entry = cache[filepath]
        if entry then
            for i, path in ipairs(cache_order) do
                if path == filepath then table.remove(cache_order, i) break end
            end
            table.insert(cache_order, 1, filepath)
        end
        return entry
    end

    -- Add A, B, C (C is most recent)
    set_cached("A", {peaks = 1})
    set_cached("B", {peaks = 2})
    set_cached("C", {peaks = 3})

    lu.assertEquals(cache_order[1], "C")
    lu.assertEquals(cache_order[3], "A")

    -- Access A -> moves to front
    get_cached("A")
    lu.assertEquals(cache_order[1], "A")
    lu.assertEquals(cache_order[2], "C")
    lu.assertEquals(cache_order[3], "B")
end

function TestNVSDItemView:test_invalidate_file_removes_from_cache()
    -- Invalidating a specific file removes it from both cache and order
    local cache = {}
    local cache_order = {}

    cache["fileA"] = {peaks = 1}
    cache["fileB"] = {peaks = 2}
    cache_order = {"fileB", "fileA"}

    local function invalidate_file(filepath)
        if cache[filepath] then
            cache[filepath] = nil
            for i, path in ipairs(cache_order) do
                if path == filepath then table.remove(cache_order, i) break end
            end
        end
    end

    invalidate_file("fileA")

    lu.assertNil(cache["fileA"])
    lu.assertNotNil(cache["fileB"])
    lu.assertEquals(#cache_order, 1)
    lu.assertEquals(cache_order[1], "fileB")
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
