-- NVSD_ItemView - Utilities Module
-- Conversion functions, formatting, math helpers

local utils = {}

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
-- Uses round-to-nearest for Ableton-style ±50 cents range
function utils.pitch_to_semitones_cents(pitch)
  local semitones = math.floor(pitch + 0.5)
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
  local total = actual_samples * num_channels
  local mins = {}
  local maxs = {}

  if num_channels == 1 then
    for i = 1, actual_samples do
      mins[i] = buf[min_block_offset + i] or 0
      maxs[i] = buf[i] or 0
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
  end

  return { mins = mins, maxs = maxs, count = actual_samples, channels = num_channels, output_mode = output_mode }, num_channels
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
  local first = warp_map[1]
  if pos <= first.pos then
    return first.srcpos + (pos - first.pos) * (playrate or 1)
  end
  local last = warp_map[#warp_map]
  if pos >= last.pos then
    return last.srcpos + (pos - last.pos) * (playrate or 1)
  end
  for i = 1, #warp_map - 1 do
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
  end
  return pos * (playrate or 1)
end

-- Map source-time (srcpos) to item-time (pos) using warp markers (inverse)
function utils.warp_src_to_pos(warp_map, srcpos, playrate)
  if not warp_map or #warp_map == 0 then
    return srcpos / (playrate or 1)
  end
  local first = warp_map[1]
  if srcpos <= first.srcpos then
    return first.pos + (srcpos - first.srcpos) / (playrate or 1)
  end
  local last = warp_map[#warp_map]
  if srcpos >= last.srcpos then
    return last.pos + (srcpos - last.srcpos) / (playrate or 1)
  end
  for i = 1, #warp_map - 1 do
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
  end
  return srcpos / (playrate or 1)
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

  -- For looped sources: load the FULL source range (wrapping means any position is valid)
  local src_min, src_max, src_duration

  if is_looped then
    src_min = 0
    src_max = source_length
    src_duration = source_length
  else
    -- Only include positions within [0, source_length] for peak loading.
    -- Pixels mapping outside this range will output silence.
    src_min = math.huge
    src_max = -math.huge
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
    src_duration = src_max - src_min
  end
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

-- Add stretch markers at transient positions, quantized to nearest grid
-- Optional range_start/range_end in SOURCE time to limit to a region
-- Optional warp_map/playrate for correct pos computation in warped view
function utils.add_markers_at_transients(take, transients, range_start, range_end, warp_map, playrate)
  local item = reaper.GetMediaItemTake_Item(take)
  local item_pos = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
  local sm_count = reaper.GetTakeNumStretchMarkers(take)
  -- Build list of existing srcpos for fast lookup
  local existing = {}
  for i = 0, sm_count - 1 do
    local _, _, srcpos = reaper.GetTakeStretchMarker(take, i)
    existing[#existing + 1] = srcpos
  end
  -- First pass: compute snap destination for each candidate and pick the closest
  -- transient per grid point (avoids multiple markers at the same position)
  local grid_best = {}  -- snapped_pos -> {srcpos, pos, dist}
  for _, srcpos in ipairs(transients) do
    if (not range_start or srcpos >= range_start) and (not range_end or srcpos <= range_end) then
      local has = false
      for _, e in ipairs(existing) do
        if math.abs(e - srcpos) < 0.005 then has = true; break end
      end
      if not has then
        local pos = warp_map and utils.warp_src_to_pos(warp_map, srcpos, playrate or 1) or srcpos
        local snapped = snap_to_grid(item_pos + pos) - item_pos
        local dist = math.abs(pos - snapped)
        local key = string.format("%.8f", snapped)
        if not grid_best[key] or dist < grid_best[key].dist then
          grid_best[key] = {srcpos = srcpos, pos = snapped, dist = dist}
        end
      end
    end
  end
  -- Second pass: create markers (one per grid point)
  local count = 0
  for _, entry in pairs(grid_best) do
    reaper.SetTakeStretchMarker(take, -1, entry.pos, entry.srcpos)
    count = count + 1
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
  -- Collect all markers first
  local markers = {}
  for i = 0, sm_count - 1 do
    local _, pos, srcpos = reaper.GetTakeStretchMarker(take, i)
    markers[#markers + 1] = {pos = pos, srcpos = srcpos}
  end
  -- Compute snapped positions
  local moved = 0
  for _, m in ipairs(markers) do
    local project_time = item_pos + m.pos
    local snapped_time = snap_to_grid(project_time)
    local snapped_pos = snapped_time - item_pos
    if math.abs(snapped_pos - m.pos) > 0.0001 then
      m.pos = snapped_pos
      moved = moved + 1
    end
  end
  if moved > 0 then
    -- Delete all and re-add with snapped positions
    reaper.DeleteTakeStretchMarkers(take, 0, sm_count)
    for _, m in ipairs(markers) do
      reaper.SetTakeStretchMarker(take, -1, m.pos, m.srcpos)
    end
  end
  return moved
end

-- Insert a single warp marker at a view-time position.
-- Returns true if a marker was created, false if out of bounds or duplicate.
function utils.insert_warp_marker_at(take, time, is_warped, warp_map, playrate, source_length)
  local pos, srcpos
  if is_warped then
    pos = time
    srcpos = utils.warp_pos_to_src(warp_map, pos, playrate)
  else
    srcpos = time
    pos = srcpos
  end
  if srcpos < 0 or srcpos > source_length then return false end
  -- Check for existing marker at same position
  local sm_count = reaper.GetTakeNumStretchMarkers(take)
  for i = 0, sm_count - 1 do
    local _, _, sp = reaper.GetTakeStretchMarker(take, i)
    if math.abs(sp - srcpos) < 0.005 then return false end
  end
  reaper.SetTakeStretchMarker(take, -1, pos, srcpos)
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
    eff_fo = math.max(0, new_length - eff_fi)
    if eff_fo == 0 then eff_fi = math.min(eff_fi, new_length) end

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
  state.warp_marker_selected_idx = -1

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

return utils
