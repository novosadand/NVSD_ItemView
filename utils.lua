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

-- Convert pitch float to semitones and cents display values
function utils.pitch_to_semitones_cents(pitch)
  local semitones
  if pitch >= 0 then
    semitones = math.floor(pitch)
  else
    semitones = math.ceil(pitch)
  end
  local cents = math.floor((pitch - semitones) * 100 + 0.5)
  if cents >= 100 then
    cents = 0
    semitones = semitones + 1
  elseif cents <= -100 then
    cents = 0
    semitones = semitones - 1
  end
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

-- Get bit depth from WAV file header
function utils.get_wav_bit_depth(file_path)
  if not file_path or file_path == "" then return nil end
  local f = io.open(file_path, "rb")
  if not f then return nil end

  local riff = f:read(4)
  if riff ~= "RIFF" then f:close() return nil end

  f:read(4)
  local wave = f:read(4)
  if wave ~= "WAVE" then f:close() return nil end

  while true do
    local chunk_id = f:read(4)
    if not chunk_id then f:close() return nil end

    local chunk_size_bytes = f:read(4)
    if not chunk_size_bytes then f:close() return nil end

    local chunk_size = string.byte(chunk_size_bytes, 1) +
                       string.byte(chunk_size_bytes, 2) * 256 +
                       string.byte(chunk_size_bytes, 3) * 65536 +
                       string.byte(chunk_size_bytes, 4) * 16777216

    if chunk_id == "fmt " then
      local fmt_data = f:read(math.min(chunk_size, 16))
      if fmt_data and #fmt_data >= 16 then
        local bits_per_sample = string.byte(fmt_data, 15) + string.byte(fmt_data, 16) * 256
        f:close()
        return bits_per_sample
      end
      f:close()
      return nil
    else
      f:seek("cur", chunk_size)
    end
  end
end

-- Get peaks data from audio source for a specific time range
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
  local api_start = math.max(0, start_time)

  local ret = reaper.PCM_Source_GetPeaks(source, peakrate, api_start, num_channels, num_samples, 0, buf)

  if ret == 0 then return nil, "GetPeaks returned 0" end

  local peaks = {}
  local actual_samples = math.min(ret & 0xFFFFF, num_samples)
  local min_block_offset = actual_samples * num_channels

  for i = 1, actual_samples do
    local channels = {}

    if num_channels == 1 then
      channels[1] = {
        min = buf[min_block_offset + i] or 0,
        max = buf[i] or 0
      }
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

  return peaks, num_channels
end

-- Get peaks for entire source
function utils.get_peaks(source, num_samples)
  if not source then return nil, "no source" end
  local source_length = reaper.GetMediaSourceLength(source)
  return utils.get_peaks_for_range(source, 0, source_length, num_samples)
end

-- Build LOD (Level of Detail) peaks for fast rendering at any zoom level
-- Each level aggregates 4x the previous: L0=original, L1=4x, L2=16x, L3=64x
function utils.build_lod_peaks(peaks, num_channels)
  if not peaks or #peaks == 0 then return nil end

  local lod = {peaks}  -- Level 0 is original

  local current = peaks
  for level = 1, 4 do  -- Build 4 additional levels
    local factor = 4
    local new_len = math.floor(#current / factor)
    if new_len < 10 then break end  -- Stop if too few peaks

    local aggregated = {}
    for i = 1, new_len do
      local base = (i - 1) * factor + 1
      local channels = {}

      for ch = 1, num_channels do
        local ch_min, ch_max = 1, -1
        for j = 0, factor - 1 do
          local p = current[base + j]
          if p then
            local ch_peak = p[ch] or p[1]
            if ch_peak.min < ch_min then ch_min = ch_peak.min end
            if ch_peak.max > ch_max then ch_max = ch_peak.max end
          end
        end
        channels[ch] = {min = ch_min, max = ch_max}
      end

      aggregated[i] = channels
    end

    lod[level + 1] = aggregated
    current = aggregated
  end

  return lod
end

-- Select appropriate LOD level based on peaks needed per pixel
function utils.select_lod_level(lod, peaks_per_pixel)
  if not lod then return nil, 1 end

  -- Each level reduces by 4x, so:
  -- Level 0: original, Level 1: 4x, Level 2: 16x, Level 3: 64x, Level 4: 256x
  local level = 1
  local threshold = peaks_per_pixel

  if threshold > 128 and lod[5] then level = 5
  elseif threshold > 32 and lod[4] then level = 4
  elseif threshold > 8 and lod[3] then level = 3
  elseif threshold > 2 and lod[2] then level = 2
  end

  return lod[level], 4 ^ (level - 1)  -- Return peaks and scale factor
end

-- Check if mouse is near marker
function utils.is_near_marker(mouse_x, marker_x, threshold)
  return math.abs(mouse_x - marker_x) < threshold
end

return utils
