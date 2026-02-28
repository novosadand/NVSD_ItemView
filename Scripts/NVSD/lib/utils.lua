-- NVSD_ItemView - Utilities Module
-- Conversion functions, formatting, math helpers

local utils = {}

-- Binary search: find first index in sorted array where arr[i] >= value
function utils.lower_bound(arr, value)
  local lo, hi = 1, #arr
  while lo <= hi do
    local mid = math.floor((lo + hi) / 2)
    if arr[mid] < value then lo = mid + 1 else hi = mid - 1 end
  end
  return lo
end

-- Pitch/playrate conversions
function utils.semitones_to_playrate(semitones)
  return 2 ^ (semitones / 12)
end

function utils.playrate_to_semitones(playrate)
  if playrate <= 0 then return 0 end
  return 12 * math.log(playrate) / math.log(2)
end

-- Gain/dB conversions
function utils.gain_to_db(gain)
  if gain <= 0 then return -math.huge end
  return 20 * math.log(gain) / math.log(10)
end

function utils.db_to_gain(db)
  if db <= -150 then return 0 end
  return 10 ^ (db / 20)
end

-- Slider position conversions (0-1 to dB)
function utils.slider_to_db(pos)
  if pos >= 0.5 then
    return (pos - 0.5) * 2 * 24
  else
    if pos <= 0 then return -math.huge end
    return 40 * math.log(pos * 2) / math.log(10)
  end
end

function utils.db_to_slider(db)
  if db >= 0 then
    return 0.5 + (db / 24) * 0.5
  else
    if db <= -150 then return 0 end
    return (10 ^ (db / 40)) / 2
  end
end

-- Format dB value for display
function utils.format_db(db)
  if db <= -60 then return "-∞ dB" end
  return string.format("%.1f dB", db)
end

-- Format pitch value for display
function utils.format_pitch(semitones)
  if semitones >= 0 then
    return string.format("+%d", math.floor(semitones + 0.5))
  else
    return string.format("%d", math.floor(semitones + 0.5))
  end
end

-- Convert pitch to knob angle (radians)
function utils.pitch_to_angle(pitch, pitch_max)
  local normalized = pitch / pitch_max
  local clock_angle = normalized * (5 * math.pi / 6)
  return clock_angle - math.pi / 2
end

-- Convert pan value (-1..1) to knob angle (radians)
function utils.pan_to_angle(pan)
  local clock_angle = pan * (5 * math.pi / 6)
  return clock_angle - math.pi / 2
end

-- Format pan value for display: "C", "L50", "R100", etc.
function utils.format_pan(pan)
  if math.abs(pan) < 0.005 then return "C" end
  local pct = math.floor(math.abs(pan) * 100 + 0.5)
  if pan < 0 then return "L" .. pct end
  return "R" .. pct
end

-- Convert pitch float to semitones and cents display values
-- Truncates toward zero so sign of cents matches sign of pitch:
-- 12.5 → 12 st, 50 cents; -12.5 → -12 st, -50 cents
function utils.pitch_to_semitones_cents(pitch)
  local semitones = (pitch >= 0) and math.floor(pitch) or math.ceil(pitch)
  local cents = math.floor((pitch - semitones) * 100 + 0.5)
  return semitones, cents
end

-- Convert semitones and cents back to pitch float
function utils.semitones_cents_to_pitch(semitones, cents)
  return semitones + cents / 100
end

-- Time conversions
function utils.source_to_project_time(source_t, item_position, start_offset, playrate)
  if playrate == 0 then playrate = 1 end  -- Guard against division by zero
  return item_position + (source_t - start_offset) / playrate
end

function utils.project_to_source_time(project_t, item_position, start_offset, playrate)
  return start_offset + (project_t - item_position) * playrate
end

-- Format source time as mins:secs or mins:secs:ms
function utils.format_source_time(seconds, show_ms)
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

-- Get file name from full path
function utils.get_file_name(path)
  if not path then return "" end
  return path:match("([^/\\]+)$") or path
end

-- Bit depth cache (persists across frames, keyed by file path)
local bit_depth_cache = {}

-- Get bit depth from WAV file header (cached)
function utils.get_wav_bit_depth(file_path)
  if not file_path or file_path == "" then return nil end

  local cached = bit_depth_cache[file_path]
  if cached ~= nil then
    -- false means "looked up but not a WAV" (distinguish from nil = not cached)
    return cached ~= false and cached or nil
  end

  local f = io.open(file_path, "rb")
  if not f then
    bit_depth_cache[file_path] = false
    return nil
  end

  local riff = f:read(4)
  if not riff or #riff < 4 or riff ~= "RIFF" then f:close() bit_depth_cache[file_path] = false return nil end

  local size_bytes = f:read(4)
  if not size_bytes or #size_bytes < 4 then f:close() bit_depth_cache[file_path] = false return nil end
  local wave = f:read(4)
  if not wave or #wave < 4 or wave ~= "WAVE" then f:close() bit_depth_cache[file_path] = false return nil end

  while true do
    local chunk_id = f:read(4)
    if not chunk_id or #chunk_id < 4 then f:close() bit_depth_cache[file_path] = false return nil end

    local chunk_size_bytes = f:read(4)
    if not chunk_size_bytes or #chunk_size_bytes < 4 then f:close() bit_depth_cache[file_path] = false return nil end

    local chunk_size = string.byte(chunk_size_bytes, 1) +
                       string.byte(chunk_size_bytes, 2) * 256 +
                       string.byte(chunk_size_bytes, 3) * 65536 +
                       string.byte(chunk_size_bytes, 4) * 16777216

    if chunk_size <= 0 then f:close() bit_depth_cache[file_path] = false return nil end

    if chunk_id == "fmt " then
      local fmt_data = f:read(math.min(chunk_size, 16))
      if fmt_data and #fmt_data >= 16 then
        local bits_per_sample = string.byte(fmt_data, 15) + string.byte(fmt_data, 16) * 256
        f:close()
        bit_depth_cache[file_path] = bits_per_sample
        return bits_per_sample
      end
      f:close()
      bit_depth_cache[file_path] = false
      return nil
    else
      f:seek("cur", chunk_size)
    end
  end
end

-- Get peaks data from audio source for a specific time range
-- Returns flat structure: { mins={...}, maxs={...}, count=N, channels=C }
-- Flat indexing: element for sample i, channel ch = (i-1)*channels + ch
function utils.get_peaks_for_range(source, start_time, duration, num_samples)
  if not source then return nil, "no source" end

  local source_length = reaper.GetMediaSourceLength(source)
  local sample_rate = reaper.GetMediaSourceSampleRate(source)
  local num_channels = reaper.GetMediaSourceNumChannels(source)

  if source_length <= 0 then return nil, "source_length <= 0" end
  if sample_rate <= 0 then return nil, "sample_rate <= 0" end
  if num_channels <= 0 then return nil, "num_channels <= 0" end
  if duration <= 0 then return nil, "duration <= 0" end

  local peakrate = num_samples / duration
  local buf_size = num_samples * num_channels * 2
  local buf = reaper.new_array(buf_size)
  if not buf then return nil, "failed to allocate peak buffer" end
  local api_start = math.max(0, start_time)

  local ret = reaper.PCM_Source_GetPeaks(source, peakrate, api_start, num_channels, num_samples, 0, buf)

  if ret == 0 then return nil, "GetPeaks returned 0" end

  local actual_samples = math.min(ret & 0xFFFFF, num_samples)
  local output_mode = (ret >> 20) & 0xF
  local min_block_offset = actual_samples * num_channels
  local mins = {}
  local maxs = {}

  if num_channels == 1 then
    for i = 1, actual_samples do
      mins[i] = buf[min_block_offset + i] or 0
      maxs[i] = buf[i] or 0
    end
    -- Zero-fill if REAPER returned fewer peaks than requested (peak file still building)
    for i = actual_samples + 1, num_samples do
      mins[i] = 0
      maxs[i] = 0
    end
  else
    for i = 1, actual_samples do
      local base_idx = (i - 1) * num_channels + 1
      local flat_base = (i - 1) * num_channels
      for ch = 1, num_channels do
        local flat_idx = flat_base + ch
        maxs[flat_idx] = buf[base_idx + ch - 1] or 0
        mins[flat_idx] = buf[min_block_offset + base_idx + ch - 1] or 0
      end
    end
    -- Zero-fill if REAPER returned fewer peaks than requested (peak file still building)
    for i = actual_samples + 1, num_samples do
      local flat_base = (i - 1) * num_channels
      for ch = 1, num_channels do
        maxs[flat_base + ch] = 0
        mins[flat_base + ch] = 0
      end
    end
  end

  local complete = actual_samples >= num_samples
  -- Detect partially-built .reapeaks: REAPER reports full count but only the first
  -- portion has real data (rest is zeros).  Check that the last 10% of peaks has at
  -- least one non-zero value.  If only the beginning has data, mark incomplete so the
  -- retry mechanism reloads once peak building finishes.
  if complete and actual_samples > 20 then
    local check_from = actual_samples - math.max(1, math.floor(actual_samples / 10))
    local has_end_data = false
    for i = check_from, actual_samples do
      if maxs[i] ~= 0 or mins[i] ~= 0 then
        has_end_data = true
        break
      end
    end
    if not has_end_data then complete = false end
  end
  return { mins = mins, maxs = maxs, count = num_samples, channels = num_channels, output_mode = output_mode, complete = complete }, num_channels
end

-- Get peaks for a view range, clipping to source_length (non-looped items).
-- Samples beyond source_length are zero-filled (silence).
function utils.get_peaks_for_range_clipped(source, view_start, view_length, num_samples, source_length)
  if not source then return nil, "no source" end
  if source_length <= 0 then return nil, "source_length <= 0" end
  if view_length <= 0 then return nil, "view_length <= 0" end
  if num_samples <= 0 then return nil, "num_samples <= 0" end

  local num_channels = reaper.GetMediaSourceNumChannels(source)
  if num_channels <= 0 then return nil, "num_channels <= 0" end

  local view_end = view_start + view_length
  local time_per_sample = view_length / num_samples

  -- How many samples fall within the source range?
  local valid_end = math.min(view_end, source_length)
  local valid_start = math.max(view_start, 0)
  if valid_start >= valid_end then
    -- Entire view is outside source: return all zeros
    local zeros = {}
    for i = 1, num_samples * num_channels do zeros[i] = 0 end
    return { mins = zeros, maxs = zeros, count = num_samples, channels = num_channels, output_mode = 0 }, num_channels
  end

  -- Compute sample indices for the valid portion
  local first_valid = math.floor((valid_start - view_start) / time_per_sample) + 1
  local last_valid = math.min(num_samples, math.ceil((valid_end - view_start) / time_per_sample))
  local valid_samples = last_valid - first_valid + 1

  if valid_samples <= 0 then
    local zeros = {}
    for i = 1, num_samples * num_channels do zeros[i] = 0 end
    return { mins = zeros, maxs = zeros, count = num_samples, channels = num_channels, output_mode = 0 }, num_channels
  end

  -- Load peaks only for the valid source portion
  local valid_duration = valid_samples * time_per_sample
  local peakrate = valid_samples / valid_duration
  local buf_size = valid_samples * num_channels * 2
  local buf = reaper.new_array(buf_size)
  if not buf then return nil, "failed to allocate peak buffer" end

  local ret = reaper.PCM_Source_GetPeaks(source, peakrate, valid_start, num_channels, valid_samples, 0, buf)
  if ret == 0 then return nil, "GetPeaks returned 0" end

  local actual = math.min(ret & 0xFFFFF, valid_samples)
  local output_mode = (ret >> 20) & 0xF

  -- Build full-size output with zeros for out-of-range samples
  local mins = {}
  local maxs = {}
  local total = num_samples * num_channels
  for i = 1, total do mins[i] = 0; maxs[i] = 0 end

  -- Copy valid peaks into the right position
  local min_block_offset = actual * num_channels
  if num_channels == 1 then
    for i = 1, actual do
      local out_i = first_valid + i - 1
      if out_i <= num_samples then
        mins[out_i] = buf[min_block_offset + i] or 0
        maxs[out_i] = buf[i] or 0
      end
    end
  else
    for i = 1, actual do
      local out_i = first_valid + i - 1
      if out_i <= num_samples then
        local buf_base = (i - 1) * num_channels + 1
        local out_base = (out_i - 1) * num_channels
        for ch = 1, num_channels do
          maxs[out_base + ch] = buf[buf_base + ch - 1] or 0
          mins[out_base + ch] = buf[min_block_offset + buf_base + ch - 1] or 0
        end
      end
    end
  end

  return { mins = mins, maxs = maxs, count = num_samples, channels = num_channels, output_mode = output_mode }, num_channels
end

-- Get peaks for a view range that may extend beyond [0, source_length] (looped items).
-- Splits the range into segments at source boundary crossings, loads each from the
-- wrapped source position, and assembles one contiguous peaks array.
function utils.get_peaks_for_range_looped(source, view_start, view_length, num_samples, source_length)
  if not source then return nil, "no source" end
  if source_length <= 0 then return nil, "source_length <= 0" end
  if view_length <= 0 then return nil, "view_length <= 0" end
  if num_samples <= 0 then return nil, "num_samples <= 0" end

  local num_channels = reaper.GetMediaSourceNumChannels(source)
  if num_channels <= 0 then return nil, "num_channels <= 0" end

  local time_per_sample = view_length / num_samples

  -- Build segments: contiguous runs of samples that map to a contiguous source region.
  -- A new segment starts whenever the wrapped source time jumps backwards (boundary crossing).
  local segments = {}  -- { {start_idx, count, source_start, source_duration}, ... }
  local seg_start_idx = 1
  local prev_wrapped = view_start % source_length
  if prev_wrapped < 0 then prev_wrapped = prev_wrapped + source_length end
  local seg_source_start = prev_wrapped

  for i = 2, num_samples do
    local t = view_start + (i - 1) * time_per_sample
    local wrapped = t % source_length
    if wrapped < 0 then wrapped = wrapped + source_length end

    -- Detect boundary crossing: wrapped time jumped backwards
    if wrapped < prev_wrapped - time_per_sample * 0.5 then
      -- Close current segment
      local seg_count = i - seg_start_idx
      local seg_duration = seg_count * time_per_sample
      segments[#segments + 1] = {seg_start_idx, seg_count, seg_source_start, seg_duration}
      seg_start_idx = i
      seg_source_start = wrapped
    end
    prev_wrapped = wrapped
  end
  -- Close final segment
  local seg_count = num_samples - seg_start_idx + 1
  local seg_duration = seg_count * time_per_sample
  segments[#segments + 1] = {seg_start_idx, seg_count, seg_source_start, seg_duration}

  -- Allocate output arrays
  local all_mins = {}
  local all_maxs = {}
  local output_mode = 0

  -- Load peaks for each segment and place into the output arrays
  for _, seg in ipairs(segments) do
    local idx, cnt, src_start, src_dur = seg[1], seg[2], seg[3], seg[4]

    local peakrate = cnt / src_dur
    local buf_size = cnt * num_channels * 2
    local buf = reaper.new_array(buf_size)
    if not buf then
      -- Fill with zeros on allocation failure
      for j = 1, cnt * num_channels do
        local out_pos = (idx - 1) * num_channels + j
        all_mins[out_pos] = 0
        all_maxs[out_pos] = 0
      end
    else
      local ret = reaper.PCM_Source_GetPeaks(source, peakrate, src_start, num_channels, cnt, 0, buf)
      local actual = 0
      if ret ~= 0 then
        actual = math.min(ret & 0xFFFFF, cnt)
        output_mode = (ret >> 20) & 0xF
      end

      local min_block_offset = actual * num_channels

      if num_channels == 1 then
        for i = 1, actual do
          local out_pos = (idx - 1) + i
          all_maxs[out_pos] = buf[i] or 0
          all_mins[out_pos] = buf[min_block_offset + i] or 0
        end
        -- Zero-fill any shortfall
        for i = actual + 1, cnt do
          local out_pos = (idx - 1) + i
          all_maxs[out_pos] = 0
          all_mins[out_pos] = 0
        end
      else
        for i = 1, actual do
          local base_idx = (i - 1) * num_channels + 1
          local out_base = (idx - 1 + i - 1) * num_channels
          for ch = 1, num_channels do
            all_maxs[out_base + ch] = buf[base_idx + ch - 1] or 0
            all_mins[out_base + ch] = buf[min_block_offset + base_idx + ch - 1] or 0
          end
        end
        -- Zero-fill shortfall
        for i = actual + 1, cnt do
          local out_base = (idx - 1 + i - 1) * num_channels
          for ch = 1, num_channels do
            all_maxs[out_base + ch] = 0
            all_mins[out_base + ch] = 0
          end
        end
      end
    end
  end

  return { mins = all_mins, maxs = all_maxs, count = num_samples, channels = num_channels, output_mode = output_mode }, num_channels
end

-- Check if mouse is near marker
function utils.is_near_marker(mouse_x, marker_x, threshold)
  return math.abs(mouse_x - marker_x) < threshold
end

-- Check if a point (px, py) is inside a rectangle (x1,y1)-(x2,y2)
function utils.point_in_rect(px, py, x1, y1, x2, y2)
  return px >= x1 and px <= x2 and py >= y1 and py <= y2
end

-- Undo block wrapper: wraps fn in Undo_BeginBlock/EndBlock
function utils.with_undo(label, flags, fn)
  reaper.Undo_BeginBlock()
  local ok, err = pcall(fn)
  reaper.Undo_EndBlock(label, flags)
  if not ok then error(err, 2) end
end

-- Read all stretch markers from a take, sorted by srcpos
function utils.get_stretch_markers(take)
  if not take then return {} end
  local count = reaper.GetTakeNumStretchMarkers(take)
  if count == 0 then return {} end
  local markers = {}
  for i = 0, count - 1 do
    local retval, pos, srcpos = reaper.GetTakeStretchMarker(take, i)
    if retval >= 0 then
      local slope = reaper.GetTakeStretchMarkerSlope(take, i)
      markers[#markers + 1] = { idx = i, pos = pos, srcpos = srcpos, slope = slope or 0 }
    end
  end
  table.sort(markers, function(a, b) return a.srcpos < b.srcpos end)
  return markers
end

-- Build warp map: stretch markers sorted by pos (item-time order)
function utils.build_warp_map(warp_markers)
  if not warp_markers or #warp_markers == 0 then return {} end
  local sorted = {}
  for _, sm in ipairs(warp_markers) do
    sorted[#sorted + 1] = {pos = sm.pos, srcpos = sm.srcpos, slope = sm.slope or 0}
  end
  table.sort(sorted, function(a, b) return a.pos < b.pos end)
  return sorted
end

-- Map item-time (pos) to source-time (srcpos) using warp markers
function utils.warp_pos_to_src(warp_map, pos, playrate)
  if not warp_map or #warp_map == 0 then
    return pos * (playrate or 1)
  end
  local n = #warp_map
  local first = warp_map[1]
  if pos <= first.pos then
    return first.srcpos + (pos - first.pos) * (playrate or 1)
  end
  local last = warp_map[n]
  if pos >= last.pos then
    return last.srcpos + (pos - last.pos) * (playrate or 1)
  end
  -- Binary search for the segment containing pos
  local lo, hi = 1, n - 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if pos < warp_map[mid + 1].pos then hi = mid else lo = mid + 1 end
  end
  local i = lo
  if pos >= warp_map[i].pos and pos <= warp_map[i+1].pos then
    local span = warp_map[i+1].pos - warp_map[i].pos
    if span < 0.000001 then return warp_map[i].srcpos end
    local t = (pos - warp_map[i].pos) / span
    local slope = warp_map[i].slope or 0
    local delta_src = warp_map[i+1].srcpos - warp_map[i].srcpos
    if math.abs(slope) < 0.001 then
      return warp_map[i].srcpos + t * delta_src
    else
      return warp_map[i].srcpos + t * (1 - slope * (1 - t)) * delta_src
    end
  end
  return pos * (playrate or 1)
end

-- Map source-time (srcpos) to item-time (pos) using warp markers (inverse)
function utils.warp_src_to_pos(warp_map, srcpos, playrate)
  if not warp_map or #warp_map == 0 then
    return srcpos / (playrate or 1)
  end
  local n = #warp_map
  local first = warp_map[1]
  if srcpos <= first.srcpos then
    return first.pos + (srcpos - first.srcpos) / (playrate or 1)
  end
  local last = warp_map[n]
  if srcpos >= last.srcpos then
    return last.pos + (srcpos - last.srcpos) / (playrate or 1)
  end
  -- Binary search for the segment containing srcpos
  local lo, hi = 1, n - 1
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    if srcpos < warp_map[mid + 1].srcpos then hi = mid else lo = mid + 1 end
  end
  local i = lo
  if srcpos >= warp_map[i].srcpos and srcpos <= warp_map[i+1].srcpos then
    local delta_src = warp_map[i+1].srcpos - warp_map[i].srcpos
    local pos_span = warp_map[i+1].pos - warp_map[i].pos
    if math.abs(delta_src) < 0.000001 then return warp_map[i].pos end
    local slope = warp_map[i].slope or 0
    if math.abs(slope) < 0.001 then
      local t = (srcpos - warp_map[i].srcpos) / delta_src
      return warp_map[i].pos + t * pos_span
    else
      local a = slope * delta_src
      local b = (1 - slope) * delta_src
      local c = -(srcpos - warp_map[i].srcpos)
      local disc = b*b - 4*a*c
      if disc < 0 then disc = 0 end
      local t = (-b + math.sqrt(disc)) / (2 * a)
      t = math.max(0, math.min(1, t))
      return warp_map[i].pos + t * pos_span
    end
  end
  return srcpos / (playrate or 1)
end

-- Compute the neutral pos for a srcpos — i.e., the item-time position where
-- this source point currently plays, given existing stretch markers.
-- Adding a marker with this pos/srcpos pair won't shift anything.
function utils.srcpos_to_neutral_pos(take, srcpos)
  local item = reaper.GetMediaItemTake_Item(take)
  local item_len = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local start_offs = reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")
  local sm_count = reaper.GetTakeNumStretchMarkers(take)

  -- Build sorted list of (pos, srcpos) including implicit boundaries
  local pts = {}
  pts[1] = {pos = 0, srcpos = start_offs}
  for i = 0, sm_count - 1 do
    local _, p, sp = reaper.GetTakeStretchMarker(take, i)
    pts[#pts + 1] = {pos = p, srcpos = sp}
  end
  -- Implicit end: figure out end srcpos from playrate and item length
  local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  local end_srcpos = start_offs + item_len * playrate
  pts[#pts + 1] = {pos = item_len, srcpos = end_srcpos}
  table.sort(pts, function(a, b) return a.srcpos < b.srcpos end)

  -- Find the segment containing srcpos and interpolate
  for i = 1, #pts - 1 do
    if srcpos <= pts[i + 1].srcpos or i == #pts - 1 then
      local ds = pts[i + 1].srcpos - pts[i].srcpos
      if math.abs(ds) < 0.000001 then return pts[i].pos end
      local t = (srcpos - pts[i].srcpos) / ds
      return pts[i].pos + t * (pts[i + 1].pos - pts[i].pos)
    end
  end
  return srcpos / (reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE") or 1)
end

-- Load peaks with warp mapping applied (pos-space view into source-space peaks)
function utils.get_peaks_for_range_warped(source, pos_start, pos_length, num_samples, warp_map, playrate, loop_src_len, actual_src_len)
  if not source or pos_length <= 0 or num_samples < 1 then return nil end

  local is_looped = loop_src_len and loop_src_len > 0
  -- Use caller-provided source length (cached/validated) to avoid REAPER's
  -- GetMediaSourceLength returning inflated values for looped sources.
  local source_length = is_looped and loop_src_len
      or actual_src_len
      or reaper.GetMediaSourceLength(source)

  -- Compute source-time positions for each pixel boundary
  local src_positions = {}
  for i = 0, num_samples do
    local pos = pos_start + i * (pos_length / num_samples)
    local src = utils.warp_pos_to_src(warp_map, pos, playrate)
    -- Wrap looped source positions into [0, source_length)
    if is_looped and src >= loop_src_len then
      src = src % loop_src_len
    elseif is_looped and src < 0 then
      src = src % loop_src_len
      if src < 0 then src = src + loop_src_len end
    end
    src_positions[i] = src
  end

  -- Find actual visible source range from mapped positions.
  -- For both looped and non-looped: scan positions to find the range we need.
  local src_min = math.huge
  local src_max = -math.huge
  for i = 0, num_samples do
    local s = src_positions[i]
    if s >= 0 and s <= source_length then
      if s < src_min then src_min = s end
      if s > src_max then src_max = s end
    end
  end
  if src_min == math.huge then src_min = 0; src_max = 0 end
  src_min = math.max(0, src_min)
  src_max = math.min(source_length, src_max)
  local src_duration = src_max - src_min
  if src_duration <= 0.0001 then return nil end

  -- Load source peaks at resolution proportional to the stretch ratio.
  -- When a small source region is stretched across many output pixels,
  -- we need far more source samples to avoid a blocky/low-poly waveform.
  local stretch_ratio = (num_samples > 0 and src_duration > 0)
      and (pos_length / src_duration) or 1
  local src_num_samples = math.max(math.floor(num_samples * math.max(2, stretch_ratio)), 500)
  local src_peaks = utils.get_peaks_for_range(source, src_min, src_duration, src_num_samples)
  if not src_peaks then return nil end

  local num_ch = src_peaks.channels
  local src_count = src_peaks.count
  if src_count < 1 then return nil end


  -- For each output pixel, map to source range and find min/max
  local mins = {}
  local maxs = {}

  for i = 0, num_samples - 1 do
    -- Non-looped: pixels mapping outside [0, source_length] are silence
    local raw0 = src_positions[i]
    local raw1 = src_positions[i + 1]
    local out_of_range = not is_looped
        and ((raw0 < 0 and raw1 < 0) or (raw0 > source_length and raw1 > source_length))

    local src0 = math.max(src_min, math.min(src_max, raw0))
    local src1 = math.max(src_min, math.min(src_max, raw1))

    -- For looped items, pixel spans that cross the loop boundary:
    -- just use the single-sample at each boundary (avoids scanning the entire buffer)
    if is_looped and math.abs(src1 - src0) > source_length * 0.5 then
      src1 = src0
    end

    -- Map to peak buffer indices (0-based)
    local idx0 = math.floor((src0 - src_min) / src_duration * (src_count - 1) + 0.5)
    local idx1 = math.floor((src1 - src_min) / src_duration * (src_count - 1) + 0.5)
    idx0 = math.max(0, math.min(src_count - 1, idx0))
    idx1 = math.max(0, math.min(src_count - 1, idx1))
    if idx0 > idx1 then idx0, idx1 = idx1, idx0 end

    for ch = 1, num_ch do
      local ch_min, ch_max
      if out_of_range then
        ch_min = 0
        ch_max = 0
      else
        ch_min = math.huge
        ch_max = -math.huge
        for j = idx0, idx1 do
          local flat_idx = j * num_ch + ch
          local pmin = src_peaks.mins[flat_idx]
          local pmax = src_peaks.maxs[flat_idx]
          if pmin and pmin < ch_min then ch_min = pmin end
          if pmax and pmax > ch_max then ch_max = pmax end
        end
        if ch_min == math.huge then ch_min = 0 end
        if ch_max == -math.huge then ch_max = 0 end
      end
      local flat_out = i * num_ch + ch
      mins[flat_out] = ch_min
      maxs[flat_out] = ch_max
    end
  end

  return { mins = mins, maxs = maxs, count = num_samples, channels = num_ch, output_mode = src_peaks.output_mode }, num_ch
end

-- Detect transients using dual-envelope follower (FluCoMa AmpSlice approach).
-- A fast envelope tracks attacks instantly; a slow envelope tracks the average
-- level. Onset fires when fast significantly exceeds slow. This naturally
-- produces one detection per sound event: after the initial attack, the slow
-- envelope catches up, suppressing secondary peaks and reverb tails.
-- Log compression ensures quiet transients in dynamic material are detectable.
function utils.detect_transients(source, sensitivity, min_spacing)
  sensitivity = sensitivity or 0.5
  min_spacing = min_spacing or 0.03
  local source_length = reaper.GetMediaSourceLength(source)
  local num_channels = reaper.GetMediaSourceNumChannels(source)
  if source_length <= 0 then return {} end

  -- Peakrate: 2000 Hz (0.5ms resolution)
  local peakrate = 2000
  local total_peaks = math.floor(source_length * peakrate)
  if total_peaks > 500000 then
    peakrate = math.floor(500000 / source_length)
    total_peaks = math.floor(source_length * peakrate)
  end
  if total_peaks < 2 then return {} end

  local buf = reaper.new_array(total_peaks * num_channels * 2)
  local ret = reaper.PCM_Source_GetPeaks(source, peakrate, 0, num_channels, total_peaks, 0, buf)
  local actual = math.min(ret & 0xFFFFF, total_peaks)
  if actual < 2 then return {} end

  local min_off = actual * num_channels

  -- Step 1: Raw energy envelope (max absolute peak across channels)
  local energy = {}
  local max_energy = 0
  for i = 1, actual do
    local e
    if num_channels == 1 then
      e = math.max(math.abs(buf[i] or 0), math.abs(buf[min_off + i] or 0))
    else
      local base = (i - 1) * num_channels + 1
      e = 0
      for ch = 0, num_channels - 1 do
        e = math.max(e, math.abs(buf[base + ch] or 0), math.abs(buf[min_off + base + ch] or 0))
      end
    end
    energy[i] = e
    if e > max_energy then max_energy = e end
  end

  if max_energy < 0.001 then return {} end -- silence

  -- Step 2: Log compression. Compresses dynamic range so a quiet transient
  -- (e.g. 0.05) registers proportionally closer to a loud one (0.8).
  -- gamma=10: log(1+10*0.05)=0.41, log(1+10*0.8)=2.20 (5.4x ratio vs 16x linear)
  local gamma = 10
  local log_e = {}
  for i = 1, actual do
    log_e[i] = math.log(1 + gamma * energy[i])
  end

  -- Step 3: Dual envelope follower.
  -- Fast envelope: short attack (1ms), moderate release (5ms). Tracks onsets.
  -- Slow envelope: longer attack (40ms), slow release (80ms). Tracks average level.
  -- Envelope formula: env = coeff * input + (1-coeff) * env
  -- coeff = 1 - exp(-1/(time_sec * peakrate))
  local function make_coeff(time_ms) return 1 - math.exp(-1000 / (time_ms * peakrate)) end
  local fast_atk = make_coeff(1)    -- ~1ms: jump to peaks instantly
  local fast_rel = make_coeff(5)    -- ~5ms: drop fairly quick
  local slow_atk = make_coeff(40)   -- ~40ms: rise slowly (this is the key parameter)
  local slow_rel = make_coeff(80)   -- ~80ms: release slowly

  local fast_env = 0
  local slow_env = 0
  local onset = {}

  for i = 1, actual do
    local x = log_e[i]
    -- Fast envelope: attack when rising, release when falling
    if x > fast_env then
      fast_env = fast_atk * x + (1 - fast_atk) * fast_env
    else
      fast_env = fast_rel * x + (1 - fast_rel) * fast_env
    end
    -- Slow envelope: attack when rising, release when falling
    if x > slow_env then
      slow_env = slow_atk * x + (1 - slow_atk) * slow_env
    else
      slow_env = slow_rel * x + (1 - slow_rel) * slow_env
    end
    -- Onset signal = how much fast exceeds slow (half-wave rectified)
    local diff = fast_env - slow_env
    onset[i] = diff > 0 and diff or 0
  end

  -- Step 4: Schmitt trigger peak picking.
  -- Sensitivity maps to on-threshold. Lower threshold = more detections.
  -- The onset signal for a clear transient (silence->loud) is typically 1.0-2.0.
  -- For a subtle onset it's 0.2-0.5.
  -- sensitivity 0.3 (default): on_thresh ~ 0.40 (only clear transients)
  -- sensitivity 0.5: on_thresh ~ 0.25
  -- sensitivity 0.8: on_thresh ~ 0.07
  local on_thresh = 0.55 * (1.0 - sensitivity) * (1.0 - sensitivity) + 0.04
  local off_thresh = on_thresh * 0.25  -- rearm well below trigger point

  -- Absolute energy floor: ignore detections in near-silence
  local abs_floor = max_energy * 0.01

  local min_gap = math.max(2, math.floor(peakrate * min_spacing))
  local result = {}
  local last = -min_gap
  local armed = true
  local peak_val = 0
  local peak_idx = 0
  local trigger_idx = 0  -- index where onset first crossed threshold

  for i = 1, actual do
    if armed then
      if onset[i] > on_thresh and energy[i] >= abs_floor then
        -- Entered onset region. Record the threshold crossing point
        -- and start tracking the peak for Schmitt trigger rearming.
        armed = false
        peak_val = onset[i]
        peak_idx = i
        trigger_idx = i
      end
    else
      if onset[i] > peak_val then
        peak_val = onset[i]
        peak_idx = i
      end
      if onset[i] < off_thresh or i == actual then
        -- Find the steepest energy rise between trigger and peak.
        -- This skips any soft pre-transient and lands on the main attack.
        local best_rise = 0
        local onset_idx = trigger_idx
        for j = trigger_idx, peak_idx do
          local prev = (j > 1) and log_e[j - 1] or 0
          local rise = log_e[j] - prev
          if rise > best_rise then
            best_rise = rise
            onset_idx = j
          end
        end
        if (onset_idx - last) >= min_gap then
          result[#result + 1] = (onset_idx - 1) / peakrate
          last = onset_idx
        end
        armed = true
        peak_val = 0
        peak_idx = 0
      end
    end
  end
  return result
end

-- Snap a project time to the nearest grid line.
-- Works regardless of snap on/off, respects tempo map and grid settings.
local function snap_to_grid(project_time)
  -- Primary: SWS BR_GetClosestGridDivision (handles tempo, time sig, grid)
  if reaper.BR_GetClosestGridDivision then
    return reaper.BR_GetClosestGridDivision(project_time)
  end
  -- Fallback: manual QN math with GetSetProjectGrid
  if reaper.GetSetProjectGrid then
    local _, div = reaper.GetSetProjectGrid(0, false)
    if div and div > 0 then
      local qn = reaper.TimeMap2_timeToQN(0, project_time)
      local snapped_qn = math.floor(qn / div + 0.5) * div
      return reaper.TimeMap2_QNToTime(0, snapped_qn)
    end
  end
  -- Last resort: SnapToGrid (may not work with snap off)
  return reaper.SnapToGrid(0, project_time)
end

-- Add stretch markers at transient positions (one per transient, no pre-snapping).
-- Optional range_start/range_end in SOURCE time to limit to a region.
-- Optional warp_map/playrate for correct pos computation in warped view.
-- Snapping to grid is handled separately by quantize_warp_markers_ex.
function utils.add_markers_at_transients(take, transients, range_start, range_end, warp_map, playrate)
  local sm_count = reaper.GetTakeNumStretchMarkers(take)
  -- Build list of existing srcpos for fast duplicate check
  local existing = {}
  for i = 0, sm_count - 1 do
    local _, _, srcpos = reaper.GetTakeStretchMarker(take, i)
    existing[#existing + 1] = srcpos
  end
  local count = 0
  for _, srcpos in ipairs(transients) do
    if (not range_start or srcpos >= range_start) and (not range_end or srcpos <= range_end) then
      local has = false
      for _, e in ipairs(existing) do
        if math.abs(e - srcpos) < 0.005 then has = true; break end
      end
      if not has then
        local pos = utils.srcpos_to_neutral_pos(take, srcpos)
        reaper.SetTakeStretchMarker(take, -1, pos)
        count = count + 1
      end
    end
  end
  return count
end

-- Quantize all existing stretch markers to nearest grid line.
-- Collects all markers first, then deletes and re-adds to avoid
-- index shifting (SetTakeStretchMarker can re-sort by position).
function utils.quantize_warp_markers(take)
  local item = reaper.GetMediaItemTake_Item(take)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local sm_count = reaper.GetTakeNumStretchMarkers(take)
  if sm_count == 0 then return 0 end
  local moved = 0
  for i = 0, sm_count - 1 do
    local _, pos, srcpos = reaper.GetTakeStretchMarker(take, i)
    local project_time = item_pos + pos
    local snapped_time = snap_to_grid(project_time)
    local snapped_pos = snapped_time - item_pos
    if math.abs(snapped_pos - pos) > 0.0001 then
      reaper.SetTakeStretchMarker(take, i, snapped_pos, srcpos)
      moved = moved + 1
    end
  end
  return moved
end

-- Look up the QN value for a fixed grid division id (e.g. "1/8" -> 0.5).
-- Returns nil if not found.
function utils.get_fixed_grid_qn(division_id, config)
  for _, opt in ipairs(config.GRID_FIXED_OPTIONS) do
    if opt.id == division_id then return opt.qn end
  end
  return nil
end

-- Get the effective grid division in QN for the current settings.
-- For adaptive mode, requires view_length_qn and waveform_width_px.
function utils.get_effective_grid_qn(grid_settings, config, view_length_qn, waveform_width_px)
  if grid_settings.mode == "adaptive" then
    return utils.get_adaptive_grid_qn(grid_settings.adaptive, config, view_length_qn, waveform_width_px)
  else
    return utils.get_fixed_grid_qn(grid_settings.fixed, config) or 0.5
  end
end

-- For adaptive grid, pick the finest division whose lines are at least
-- target_px pixels apart (like Ableton's adaptive grid algorithm).
-- Options are sorted coarsest-first (32, 16, 8, 4, 2, 1, 0.5, 0.25, 0.125).
function utils.get_adaptive_grid_qn(level_id, config, view_length_qn, waveform_width_px)
  local target_px = 50  -- default (medium)
  for _, lvl in ipairs(config.GRID_ADAPTIVE_LEVELS) do
    if lvl.id == level_id then target_px = lvl.target_px; break end
  end
  if waveform_width_px <= 0 or view_length_qn <= 0 then return 1 end
  local px_per_qn = waveform_width_px / view_length_qn
  -- Walk from finest to coarsest, pick the finest that meets the spacing threshold
  -- Uses extended divisions (includes 1/64, 1/128) for finer adaptive resolution
  local divs = config.GRID_ADAPTIVE_DIVISIONS
  local best_qn = divs[1]  -- fallback to coarsest (32 QN = 8 bars)
  for i = #divs, 1, -1 do
    local spacing = divs[i] * px_per_qn
    if spacing >= target_px then
      best_qn = divs[i]
      break
    end
  end
  return best_qn
end

-- Convert a QN division value to a human-readable label (e.g. 4 -> "1 Bar", 0.5 -> "1/8")
function utils.qn_to_grid_label(qn)
  -- Map QN value to denominator: 1 QN = 1/4, so denom = 4/qn
  if qn >= 32 then return "8 Bars"
  elseif qn >= 16 then return "4 Bars"
  elseif qn >= 8 then return "2 Bars"
  elseif qn >= 4 then return "1 Bar"
  elseif qn >= 2 then return "1/2"
  elseif qn >= 1 then return "1/4"
  else
    -- For fine divisions, compute denominator from QN (1 QN = quarter note = 1/4)
    local denom = math.floor(4 / qn + 0.5)
    return "1/" .. tostring(denom)
  end
end

-- Step grid narrower (direction=-1) or wider (direction=+1).
-- In fixed mode: steps through GRID_FIXED_OPTIONS. In adaptive mode: steps through GRID_ADAPTIVE_LEVELS.
function utils.step_grid(settings, config, direction)
  local grid = settings.current.grid
  if grid.mode == "fixed" then
    local opts = config.GRID_FIXED_OPTIONS
    local cur_idx = 1
    for i, opt in ipairs(opts) do
      if opt.id == grid.fixed then cur_idx = i; break end
    end
    -- Narrower = smaller QN = higher index, Wider = larger QN = lower index
    local new_idx = math.max(1, math.min(#opts, cur_idx - direction))
    settings.current.grid.fixed = opts[new_idx].id
    settings.save_grid("fixed")
  else
    local lvls = config.GRID_ADAPTIVE_LEVELS
    local cur_idx = 1
    for i, lvl in ipairs(lvls) do
      if lvl.id == grid.adaptive then cur_idx = i; break end
    end
    -- Narrower = smaller target_px = higher index, Wider = larger target_px = lower index
    local new_idx = math.max(1, math.min(#lvls, cur_idx - direction))
    settings.current.grid.adaptive = lvls[new_idx].id
    settings.save_grid("adaptive")
  end
end

-- Snap a project time to the nearest grid line at a given QN division.
-- If triplet is true, the division is multiplied by 2/3.
function utils.snap_to_division(project_time, division_qn, triplet)
  local div = triplet and (division_qn * 2 / 3) or division_qn
  local qn = reaper.TimeMap2_timeToQN(0, project_time)
  local snapped_qn = math.floor(qn / div + 0.5) * div
  return reaper.TimeMap2_QNToTime(0, snapped_qn)
end

-- Snap to compound division (straight + triplet, e.g. 1/8 + 1/8T).
-- Snaps to whichever grid line is nearest.
function utils.snap_to_compound_division(project_time, division_qn)
  local straight = utils.snap_to_division(project_time, division_qn, false)
  local triplet = utils.snap_to_division(project_time, division_qn, true)
  if math.abs(straight - project_time) <= math.abs(triplet - project_time) then
    return straight
  end
  return triplet
end

-- Resolve quantize panel grid selection to a snap function.
-- Returns a function(project_time) -> snapped_time
function utils.get_quantize_snap_fn(quantize_settings, grid_settings, config, view_length_qn, waveform_width_px)
  local qgrid = quantize_settings.grid
  local triplet = grid_settings.triplet

  -- "grid" = use info bar grid setting
  local division_qn
  if qgrid == "grid" then
    division_qn = utils.get_effective_grid_qn(grid_settings, config, view_length_qn, waveform_width_px)
  else
    division_qn = utils.get_fixed_grid_qn(qgrid, config) or 0.5
  end

  return function(t) return utils.snap_to_division(t, division_qn, triplet) end
end

-- Quantize all existing stretch markers using a custom snap function and amount.
-- snap_fn(project_time) -> snapped_time
-- amount: 0-100 (0 = no change, 100 = full snap)
function utils.quantize_warp_markers_ex(take, snap_fn, amount, range_start, range_end, selected_set)
  local item = reaper.GetMediaItemTake_Item(take)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local sm_count = reaper.GetTakeNumStretchMarkers(take)
  if sm_count == 0 then return 0 end
  local frac = (amount or 100) / 100
  local moved = 0
  for i = 0, sm_count - 1 do
    if selected_set and not selected_set[i] then goto continue end
    local _, pos, srcpos = reaper.GetTakeStretchMarker(take, i)
    -- Skip markers outside the optional range (srcpos is in source time)
    if (not range_start or srcpos >= range_start - 0.001)
        and (not range_end or srcpos <= range_end + 0.001) then
      local project_time = item_pos + pos
      local snapped_time = snap_fn(project_time)
      local snapped_pos = snapped_time - item_pos
      local new_pos = pos + (snapped_pos - pos) * frac
      if math.abs(new_pos - pos) > 0.0001 then
        reaper.SetTakeStretchMarker(take, i, new_pos, srcpos)
        moved = moved + 1
      end
    end
    ::continue::
  end
  return moved
end

-- Remap take envelope points through a warp map change so they stay attached
-- to the same source audio. For each point: old pos → source (via old_map) →
-- new pos (via new_map).
function utils.remap_envelopes_for_warp_change(take, old_map, new_map, playrate)
  if not take or not old_map or not new_map then return end
  local env_names = {"Volume", "Pitch", "Pan"}
  for _, env_name in ipairs(env_names) do
    local env = reaper.GetTakeEnvelopeByName(take, env_name)
    if env then
      local count = reaper.CountEnvelopePoints(env)
      if count > 0 then
        local points = {}
        for i = 0, count - 1 do
          local ret, time, value, shape, tension, selected = reaper.GetEnvelopePoint(env, i)
          if ret then
            local src = utils.warp_pos_to_src(old_map, time, playrate)
            local new_time = utils.warp_src_to_pos(new_map, src, playrate)
            points[#points + 1] = {time = new_time, value = value, shape = shape, tension = tension, selected = selected}
          end
        end
        reaper.DeleteEnvelopePointRange(env, -1, math.huge)
        for _, pt in ipairs(points) do
          reaper.InsertEnvelopePoint(env, pt.time, pt.value, pt.shape, pt.tension, pt.selected, true)
        end
        reaper.Envelope_SortPoints(env)
      end
    end
  end
end

--- Shift all take envelope points (Volume, Pitch, Pan) by a pos-time delta.
--- Positive delta moves points right, negative moves them left.
function utils.shift_envelope_points(take, delta)
  if not take or math.abs(delta) < 0.000001 then return end
  local env_names = { "Volume", "Pitch", "Pan" }
  for _, ename in ipairs(env_names) do
    local e = reaper.GetTakeEnvelopeByName(take, ename)
    if e then
      local np = reaper.CountEnvelopePoints(e)
      for ei = 0, np - 1 do
        local ret, pt_time, pt_val, pt_shape, pt_tension, pt_sel = reaper.GetEnvelopePoint(e, ei)
        if ret then
          reaper.SetEnvelopePoint(e, ei, pt_time + delta, pt_val, pt_shape, pt_tension, pt_sel, true)
        end
      end
      reaper.Envelope_SortPoints(e)
    end
  end
end

-- Insert a single warp marker at a view-time position.
-- Returns true if a marker was created, false if out of bounds or duplicate.
function utils.insert_warp_marker_at(take, time, is_warped, warp_map, playrate, source_length)
  local pos
  if is_warped then
    pos = time
  else
    -- In source-time view, convert source time to item-time pos
    pos = utils.srcpos_to_neutral_pos(take, time)
  end
  -- Bounds check via srcpos
  local srcpos_check = is_warped
      and utils.warp_pos_to_src(warp_map, pos, playrate) or time
  if srcpos_check < -0.001 or srcpos_check > source_length + 0.001 then return false end
  -- Check for existing marker near this pos
  local sm_count = reaper.GetTakeNumStretchMarkers(take)
  for i = 0, sm_count - 1 do
    local _, ep, _ = reaper.GetTakeStretchMarker(take, i)
    if math.abs(ep - pos) < 0.001 then return false end
  end
  -- Let REAPER auto-compute srcpos from pos (neutral: no stretching)
  reaper.SetTakeStretchMarker(take, -1, pos)
  return true
end


-- Save current item selection, deselect all, select a single item, run fn(), then restore.
function utils.with_single_item_selected(item, fn)
  local saved = {}
  for i = 0, reaper.CountSelectedMediaItems(0) - 1 do
    saved[#saved + 1] = reaper.GetSelectedMediaItem(0, i)
  end
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(item, true)
  fn()
  reaper.SelectAllMediaItems(0, false)
  for _, si in ipairs(saved) do
    if reaper.ValidatePtr(si, "MediaItem*") then
      reaper.SetMediaItemSelected(si, true)
    end
  end
end

-- Clamp fades so they don't exceed the item length after a length change.
function utils.clamp_fades_to_length(item, new_length)
  local fi = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN")
  local fo = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN")
  local fia = reaper.GetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO")
  local foa = reaper.GetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO")

  local eff_fi = math.max(fi, fia)
  local eff_fo = math.max(fo, foa)

  if eff_fi + eff_fo > new_length then
    -- Proportional scaling (uniform length change, no specific edge)
    local scale = new_length / (eff_fi + eff_fo)
    eff_fi = eff_fi * scale
    eff_fo = eff_fo * scale

    reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN", math.min(fi, eff_fi))
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN", math.min(fo, eff_fo))
    reaper.SetMediaItemInfo_Value(item, "D_FADEINLEN_AUTO", math.min(fia, eff_fi))
    reaper.SetMediaItemInfo_Value(item, "D_FADEOUTLEN_AUTO", math.min(foa, eff_fo))
  end
end

-- Reverse an item using REAPER action 41051 and invalidate cache.
function utils.reverse_item(item, state)
  utils.with_single_item_selected(item, function()
    reaper.Undo_BeginBlock()
    reaper.Main_OnCommand(41051, 0)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("NVSD_ItemView: Reverse", -1)
  end)
  state.pending_cache_invalidation = 3
end

-- Open an item in external editor (or item properties if no editor configured).
-- has_external_editor_fn should be a function returning true/false.
function utils.open_editor(item, has_external_editor_fn)
  utils.with_single_item_selected(item, function()
    if has_external_editor_fn() then
      reaper.Undo_BeginBlock()
      reaper.Main_OnCommand(40109, 0)  -- Open items in external editor
      reaper.Undo_EndBlock("NVSD_ItemView: Open in External Editor", -1)
    else
      reaper.Main_OnCommand(40009, 0)  -- Item properties dialog
    end
  end)
end

-- Enable WARP mode on a take: transfer pitch from playrate into D_PITCH.
function utils.enable_warp(take)
  local playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  local pitch_from_playrate = utils.playrate_to_semitones(playrate)
  reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", pitch_from_playrate)
  reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 1)
end

-- Disable WARP mode on a take: save stretch markers, remove them, transfer pitch to playrate.
-- Returns the saved markers array (or nil if none were saved).
function utils.disable_warp(take, state)
  local item = reaper.GetMediaItemTake_Item(take)
  local sm_count = reaper.GetTakeNumStretchMarkers(take)
  local saved = nil

  if sm_count > 0 then
    local take_guid = reaper.BR_GetMediaItemTakeGUID(take)
    if take_guid then
      saved = {}
      for si = 0, sm_count - 1 do
        local _, pos, srcpos = reaper.GetTakeStretchMarker(take, si)
        saved[#saved + 1] = { pos = pos, srcpos = srcpos }
      end
      if state.warp_saved_markers_map then
        state.warp_saved_markers_map[take_guid] = saved
      end
    end
    reaper.DeleteTakeStretchMarkers(take, 0, sm_count)
  end

  state.warp_markers = {}
  state.warp_marker_selected = {}

  local cur_pitch = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")
  local old_playrate = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")
  local old_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
  local new_playrate = utils.semitones_to_playrate(cur_pitch)

  reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", 0)
  reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", new_playrate)
  reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", 0)

  if new_playrate > 0 then
    local new_length = old_length * (old_playrate / new_playrate)
    reaper.SetMediaItemInfo_Value(item, "D_LENGTH", new_length)
    utils.clamp_fades_to_length(item, new_length)
  end

  state.warp_mode = false

  return saved
end

--- Check if a peak column is silent (all channels min and max are 0.0)
function utils.is_column_silent(peaks, col)
  for ch = 1, peaks.channels do
    local idx = (col - 1) * peaks.channels + ch
    if (peaks.mins[idx] or 0) ~= 0 or (peaks.maxs[idx] or 0) ~= 0 then
      return false
    end
  end
  return true
end

--- Measure width of the sound region starting at col (how many non-silent columns).
local function region_width(peaks, col)
  local n = peaks.count
  local w = 0
  local i = col
  while i <= n and not utils.is_column_silent(peaks, i) do
    w = w + 1
    i = i + 1
  end
  return w
end

--- Find the start column of the next sound region after a silence gap.
--- min_width: skip regions narrower than this (filters peak noise blips).
function utils.find_next_region(peaks, col, min_width)
  min_width = min_width or 5
  local n = peaks.count
  if col >= n then return nil end

  local i = col
  -- If in silence, scan forward to first non-silent
  if utils.is_column_silent(peaks, i) then
    while i <= n and utils.is_column_silent(peaks, i) do i = i + 1 end
    if i > n then return nil end
    -- Check width — if too narrow, skip and keep searching
    if region_width(peaks, i) >= min_width then return i end
    -- Fall through: treat narrow blip as part of silence, skip past it
  else
    -- In sound — skip past current sound region
    while i <= n and not utils.is_column_silent(peaks, i) do i = i + 1 end
  end

  -- Now scan forward: skip silence, check region width, repeat
  while i <= n do
    -- Skip silence
    while i <= n and utils.is_column_silent(peaks, i) do i = i + 1 end
    if i > n then return nil end
    -- Skip narrow blips
    local w = region_width(peaks, i)
    if w >= min_width then return i end
    i = i + w  -- jump past this narrow blip
  end
  return nil
end

--- Find the start column of the current or previous sound region.
--- min_width: skip regions narrower than this (filters peak noise blips).
function utils.find_prev_region(peaks, col, min_width)
  min_width = min_width or 5
  if col <= 1 then return nil end

  local i = col
  -- If in silence or narrow blip, walk backward into a real sound region
  if utils.is_column_silent(peaks, i) then
    while i > 1 and utils.is_column_silent(peaks, i - 1) do i = i - 1 end
    if i <= 1 then return nil end
    i = i - 1  -- step into previous sound region
  end

  -- Now in sound. Walk backward to find start of this region.
  while i > 1 and not utils.is_column_silent(peaks, i - 1) do i = i - 1 end
  local start = i

  -- Check if this region (or the one we started in) is wide enough
  if region_width(peaks, start) >= min_width then
    -- If start == col, we're at the start of our own region — go to previous
    if start == col then
      -- Walk backward past silence to find previous region
      local j = start - 1
      while j >= 1 do
        -- Skip silence
        while j >= 1 and utils.is_column_silent(peaks, j) do j = j - 1 end
        if j < 1 then return nil end
        -- Find start of this sound region
        while j > 1 and not utils.is_column_silent(peaks, j - 1) do j = j - 1 end
        if region_width(peaks, j) >= min_width then return j end
        -- Too narrow, keep going backward
        j = j - 1
      end
      return nil
    end
    return start
  end

  -- Region was too narrow — keep scanning backward for a real region
  local j = start - 1
  while j >= 1 do
    -- Skip silence
    while j >= 1 and utils.is_column_silent(peaks, j) do j = j - 1 end
    if j < 1 then return nil end
    -- Find start of this sound region
    while j > 1 and not utils.is_column_silent(peaks, j - 1) do j = j - 1 end
    if region_width(peaks, j) >= min_width then return j end
    -- Too narrow, keep going backward
    j = j - 1
  end
  return nil
end

--- Find nearest non-silent column, biased forward (toward next onset).
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

return utils
