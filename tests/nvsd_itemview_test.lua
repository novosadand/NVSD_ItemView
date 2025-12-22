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

function TestNVSDItemView:test_zoom_min_calculation()
    -- Test calculating minimum zoom to show both markers
    local function calc_min_zoom(start_offset, source_item_length, source_length)
        local left_marker = start_offset
        local right_marker = start_offset + source_item_length
        local marker_span = right_marker - left_marker
        local padded_span = marker_span * 1.4  -- 20% padding each side
        local base_view_length = math.max(source_length, source_item_length)
        local min_zoom = base_view_length / padded_span
        return math.max(0.1, min_zoom)
    end

    -- Item same size as source: min_zoom should be around 0.71 (1/1.4)
    local min_zoom = calc_min_zoom(0, 10, 10)
    lu.assertAlmostEquals(min_zoom, 10 / 14, 0.01)

    -- Item smaller than source: min_zoom should be lower
    min_zoom = calc_min_zoom(2, 5, 10)
    lu.assertAlmostEquals(min_zoom, 10 / 7, 0.01)  -- base=10, padded_span=7

    -- Item larger than source (looping): base uses item length
    min_zoom = calc_min_zoom(0, 20, 10)
    lu.assertAlmostEquals(min_zoom, 20 / 28, 0.01)  -- base=20, padded_span=28
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

function TestNVSDItemView:test_view_start_calculation()
    -- Test view_start calculation (centering view on item)
    local function calc_view_start(start_offset, source_item_length, source_length, zoom_level, pan_offset)
        local base_view_length = math.max(source_length, source_item_length)
        local view_length = base_view_length / zoom_level
        local item_center = start_offset + source_item_length / 2
        local view_start = item_center - view_length / 2 + pan_offset
        return view_start, view_length
    end

    -- Item fits in source, zoom 1, no pan
    local view_start, view_length = calc_view_start(2, 5, 10, 1, 0)
    lu.assertAlmostEquals(view_length, 10, 0.001)
    lu.assertAlmostEquals(view_start, 4.5 - 5, 0.001)  -- center=4.5, half_view=5

    -- Zoom 2x
    view_start, view_length = calc_view_start(2, 5, 10, 2, 0)
    lu.assertAlmostEquals(view_length, 5, 0.001)
    lu.assertAlmostEquals(view_start, 4.5 - 2.5, 0.001)

    -- With pan offset
    view_start, view_length = calc_view_start(2, 5, 10, 1, 2)
    lu.assertAlmostEquals(view_start, -0.5 + 2, 0.001)  -- shifted by pan
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

function TestNVSDItemView:test_zoom_to_cursor_pan_calculation()
    -- Test that zooming to cursor keeps the time under cursor fixed
    local function calc_new_pan_offset(
        cursor_x, wave_x, waveform_width,
        view_start, view_length,
        old_zoom, new_zoom,
        base_view_length, item_center
    )
        local cursor_fraction = math.max(0, math.min(1, (cursor_x - wave_x) / waveform_width))
        local time_under_cursor = view_start + cursor_fraction * view_length
        local new_view_length = base_view_length / new_zoom
        return time_under_cursor - item_center + new_view_length * (0.5 - cursor_fraction)
    end

    -- Cursor at center, zoom in: pan should stay 0
    local new_pan = calc_new_pan_offset(
        350, 100, 500,  -- cursor at center of waveform
        -0.5, 10,       -- view_start, view_length
        1, 2,           -- old_zoom, new_zoom
        10, 4.5         -- base_view_length, item_center
    )
    -- At center, cursor_fraction=0.5, time_under_cursor=4.5
    -- new_view_length=5, pan = 4.5 - 4.5 + 5*(0.5-0.5) = 0
    lu.assertAlmostEquals(new_pan, 0, 0.01)
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
