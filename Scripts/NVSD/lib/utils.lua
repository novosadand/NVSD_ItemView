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

return utils
