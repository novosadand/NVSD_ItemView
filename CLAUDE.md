# NVSD_ItemView - REAPER Script

## Project Overview
NVSD_ItemView is a REAPER script that provides an Ableton-style clip view for audio items. It displays a waveform visualization of the source audio with draggable markers to control which portion of the audio the item plays.

## Task Management

**WORKFLOW: When given multiple tasks, add them to the todo list below FIRST, then work through them and update status.**
- Skip this for single/simple tasks
- Mark items as done when completed
- Remove completed items periodically to keep list clean

### Current Todo List
- (empty)

---

## Development Workflow

**IMPORTANT: Always run tests then sync after making changes.**

- **Dev folder (WSL)**: `~/dev/NVSD_ItemView/`
- **Windows folder**: `D:\production\# BOUGHT & FREE soft\Reaper\NVSD_ItemView\`

```bash
# ALWAYS run after making changes (tests + sync):
cd ~/dev/NVSD_ItemView && lua5.4 tests/run_tests.lua && ./sync.sh
```

## Test-Driven Development (TDD)

**MANDATORY: Always follow TDD for every feature. Always run tests automatically.**

1. **Write tests first** - Before implementing any feature, write unit tests that define expected behavior
2. **Run tests (they should fail)** - `lua5.4 tests/run_tests.lua`
3. **Implement the feature** - Write minimal code to make tests pass
4. **Run tests (they should pass)** - `lua5.4 tests/run_tests.lua`
5. **Refactor** - Clean up code while keeping tests green
6. **Sync and test in REAPER** - `./sync.sh` then test in actual REAPER

### Testing Framework
Using LuaUnit (single-file, no dependencies) for unit tests:
- Test files: `tests/*_test.lua`
- **Run tests**: `lua5.4 tests/run_tests.lua` (run automatically before every sync!)

### What to Test
- Pure logic functions (calculations, transformations)
- State management
- Edge cases (no selection, MIDI items, invalid inputs)
- Mock REAPER API calls when testing outside REAPER

## Lua/REAPER Best Practices

### Variable Scope
- **Always use `local`** unless variable must be global
- Local variables are faster and prevent naming collisions
- Limit scope to where variables are needed

### Naming Conventions
- Use explicit names starting with verbs for functions: `get_peaks()`, `draw_waveform()`
- Use descriptive variable names without abbreviations
- Optional type suffix: `item_count_int`, `source_name_str`

### REAPER-Specific
- **Indices start at 0** in REAPER API (unlike Lua's 1-based)
- Always call `reaper.UpdateArrange()` after modifying items
- Use `reaper.defer()` for continuous GUI updates
- Wrap undo points: `reaper.Undo_BeginBlock()` / `reaper.Undo_EndBlock()`

### Code Organization
- **DRY** - Don't repeat yourself; extract reusable functions
- One function per file for shared utilities (use `require`)
- Include descriptive header comments in each script
- Use comments to explain "why", not "what"

### Performance
- Cache expensive operations (e.g., peak data)
- Avoid recalculating in every frame unless necessary
- Use local references for frequently accessed globals

## Technology Stack
- **Language**: Lua
- **GUI Framework**: ReaImGui extension for REAPER
- **Target**: REAPER 6.0+

## Research Documentation

**IMPORTANT: After researching any REAPER API or technical topic, document findings in `docs/`.**

- Create/update markdown files in `docs/` folder
- Include API function signatures, parameters, and return values
- Document buffer formats, gotchas, and working code examples
- Reference official docs and forum discussions

Current documentation:
- `docs/REAPER_WAVEFORM_RENDERING.md` - PCM_Source_GetPeaks buffer format
- `docs/REAPER_TIMELINE_GRID.md` - Timeline, tempo, and bar/beat conversion

## File Structure
- `NVSD_ItemView.lua` - Main script file
- `CLAUDE.md` - Project documentation
- `sync.sh` - Sync script (WSL dev folder only)
- `docs/` - Research documentation
  - `REAPER_WAVEFORM_RENDERING.md` - Waveform API reference
  - `REAPER_TIMELINE_GRID.md` - Timeline/grid API reference
- `tests/` - Unit tests (not synced to Windows)
  - `luaunit.lua` - LuaUnit testing framework
  - `run_tests.lua` - Test runner
  - `nvsd_itemview_test.lua` - Tests for main script

### Running Tests
```bash
# Requires Lua 5.4 installed: sudo apt install lua5.4
cd ~/dev/NVSD_ItemView && lua5.4 tests/run_tests.lua
```

## Key Concepts

### REAPER Terminology
- **Item**: A region on a track that plays audio/MIDI
- **Take**: The actual media content within an item (an item can have multiple takes)
- **Source**: The underlying audio file referenced by a take
- **Offset**: Where within the source audio the take starts playing from

### Core REAPER API Functions Used
- `reaper.GetSelectedMediaItem(0, i)` - Get selected item by index
- `reaper.GetActiveTake(item)` - Get active take from item
- `reaper.GetMediaItemTake_Source(take)` - Get PCM source from take
- `reaper.PCM_Source_GetPeaks(source, ...)` - Get waveform peak data
- `reaper.GetMediaItemTakeInfo_Value(take, "D_STARTOFFS")` - Get take offset
- `reaper.SetMediaItemTakeInfo_Value(take, "D_STARTOFFS", value)` - Set take offset
- `reaper.GetMediaItemInfo_Value(item, "D_LENGTH")` - Get item length

### ReaImGui Patterns
- Context created once, reused across frames
- Main loop via `reaper.defer()` for continuous updates
- Drawing done through draw lists for custom graphics

## Development Notes
- Script requires ReaImGui extension (install via ReaPack)
- Test with various audio file lengths and sample rates
- Handle edge cases: no selection, MIDI items, empty items

## Future Features
- Pitch control slider
- Volume control slider
- Pitch algorithm selector dropdown
- Zoom controls for waveform view
