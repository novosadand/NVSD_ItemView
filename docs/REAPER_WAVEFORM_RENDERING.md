# REAPER Waveform Rendering Reference

Documentation of REAPER API functions for waveform visualization, compiled from research and testing.

---

## PCM_Source_GetPeaks

The primary function for getting waveform peak data.

### Function Signature

```lua
integer reaper.PCM_Source_GetPeaks(
  PCM_source src,
  number peakrate,      -- peaks per second
  number starttime,     -- start time in source (usually 0)
  integer numchannels,  -- number of channels to request
  integer numsamplesperchannel,  -- samples per channel to request
  integer want_extra_type,  -- 0 for basic, 115 ('s') for spectral
  reaper.array buf      -- output buffer
)
```

### Return Value

The return value encodes multiple pieces of information:
```lua
local ret = reaper.PCM_Source_GetPeaks(...)
local sample_count = ret & 0xFFFFF           -- bits 0-19: actual samples returned
local output_mode = (ret & 0xF00000) >> 20   -- bits 20-23: output mode
local has_extra = (ret & 0x1000000) >> 24    -- bit 24: extra type available
```

### Buffer Format (CRITICAL)

The buffer is organized in **two blocks** with **channel-interleaved data within each block**:

```
Block 1 (Maximums): [L0, R0, L1, R1, L2, R2, ...]
Block 2 (Minimums): [L0, R0, L1, R1, L2, R2, ...]
```

**For N samples with C channels:**
- Buffer size needed: `N * C * 2`
- Maximums: indices `1` to `N * C`
- Minimums: indices `N * C + 1` to `N * C * 2`

### Correct Indexing (Lua, 1-based)

```lua
local actual_samples = ret & 0xFFFFF
local min_block_offset = actual_samples * num_channels

for i = 1, actual_samples do
  if num_channels == 1 then
    -- Mono
    local max_val = buf[i]
    local min_val = buf[min_block_offset + i]
  else
    -- Stereo (or more channels)
    local base_idx = (i - 1) * num_channels + 1
    local l_max = buf[base_idx]
    local r_max = buf[base_idx + 1]
    local l_min = buf[min_block_offset + base_idx]
    local r_min = buf[min_block_offset + base_idx + 1]

    -- Combine: max of maxes, min of mins
    local max_val = math.max(l_max, r_max)
    local min_val = math.min(l_min, r_min)
  end
end
```

### Common Mistakes

1. **Wrong:** Treating data as separate per-channel blocks `[L_max_all][L_min_all][R_max_all][R_min_all]`
2. **Wrong:** Using `math.abs(ret)` instead of masking bits for sample count
3. **Wrong:** Not accounting for channel interleaving within blocks

---

## Alternative: CreateTakeAudioAccessor

For more accurate waveform rendering, use the audio accessor API to get actual sample data.

### Usage Pattern

```lua
-- Create accessor
local audio = reaper.CreateTakeAudioAccessor(take)
local samplerate = reaper.GetMediaSourceSampleRate(source)
local num_channels = reaper.GetMediaSourceNumChannels(source)

-- Create buffer
local block_size = 1024
local samplebuffer = reaper.new_array(block_size * num_channels)

-- Get samples (returns interleaved: L0, R0, L1, R1, ...)
local ret = reaper.GetAudioAccessorSamples(
  audio,
  samplerate,
  num_channels,
  starttime_sec,
  block_size,
  samplebuffer
)

-- Convert to Lua table for faster access (4-6x speedup)
local samples = samplebuffer.table()

-- Access samples
for j = 1, block_size do
  for ch = 1, num_channels do
    local pos = (j - 1) * num_channels + ch
    local sample = samples[pos]
  end
end

-- CRITICAL: Always cleanup
reaper.DestroyAudioAccessor(audio)
```

### Advantages
- Returns actual sample data, not pre-computed peaks
- Can generate custom peaks with any decimation algorithm
- Well-documented with working examples
- Standard interleaved format

### Disadvantages
- More processing required to compute peaks
- Slower for large files
- Need to handle block-based processing

---

## GetMediaItemTake_Peaks

Similar to PCM_Source_GetPeaks but works directly with takes. Same buffer format.

```lua
local retval = reaper.GetMediaItemTake_Peaks(
  take,
  peakrate,
  starttime,
  numchannels,
  numsamplesperchannel,
  want_extra_type,  -- 115 for spectral data
  buf
)
```

### Spectral Data (want_extra_type = 115)

When spectral data is available (check bit 24 of return value):
```lua
local spectral_offset = actual_samples * num_channels * 2
for i = 1, actual_samples do
  local spectral = buf[spectral_offset + i]
  local frequency = spectral & 0x7fff           -- lower 15 bits
  local tonality = (spectral >> 15) / 16384     -- upper bits, normalized
end
```

---

## Peakrate Calculation

Match peak density to pixel width for optimal display:

```lua
local num_samples = waveform_width_pixels
local peakrate = num_samples / source_length_seconds
```

---

## Performance Tips

1. **Cache peak data** - Only recalculate when source/item/size changes
2. **Convert reaper.array to Lua table** - 4-6x faster element access
3. **Match samples to pixels** - Avoid oversampling
4. **Use block processing** - For very long files with audio accessor

---

## References

- [REAPER API Documentation](https://www.reaper.fm/sdk/reascript/reascripthelp.html)
- [X-Raym's ReaScript Documentation](https://www.extremraym.com/cloud/reascript-doc/)
- [ReaScripts-Templates on GitHub](https://github.com/ReaTeam/ReaScripts-Templates)
- [Cockos Forum - PCM_Source_GetPeaks discussion](https://forums.cockos.com/showthread.php?t=249320)
- [Cockos Forum - GetMediaItemTake_Peaks](https://forum.cockos.com/showthread.php?t=188427)
