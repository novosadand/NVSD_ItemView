# NVSD ItemView for REAPER

Ableton-style clip view for REAPER audio items. See the full source waveform, drag markers to edit boundaries.

## Quick Start

1. Select an audio item
2. Run the script
3. Drag the blue markers to adjust start/end points

## Controls

**Waveform:**
- `Drag markers` - Adjust start/end
- `Alt + drag` - Slide both markers (keeps length)
- `Ctrl + scroll` - Zoom in/out
- `Ruler drag` - Zoom (vertical) + Pan (horizontal)
- `Middle mouse drag` - Pan
- `Mouse 4/5` - Quick set start/end to cursor

**Left Panel:**
- `WARP` - Toggle "preserve pitch when changing rate" (mirrors REAPER's item properties checkbox)
- `Algorithm dropdown` - Select pitch algorithm (when WARP is on)
- `Clear` - Reset item to default state (pitch=0, rate=1.0, warp off, original length)
- `Reverse` - Reverse the audio
- `Edit` - Open in external editor
- `Gain slider` - Volume control (+24dB to -inf)
- `Pitch knob` - Pitch adjustment (+/-48 semitones)
- `Semitones/Cents boxes` - Fine pitch control

**General:**
- `Shift + drag` - Fine adjustment on any control
- `Double-click` - Reset to default
- Click filename in info bar to open in Media Explorer
- Click mute checkbox to toggle mute

**Keyboard (when window focused):**
- `Space` - Play/Stop (forwarded to REAPER)
- `Ctrl+Z` - Undo
- `Ctrl+Y` / `Ctrl+Shift+Z` - Redo
- `W` - Toggle WARP mode
- `M` - Toggle mute
- `R` - Reverse item
- `C` - Clear pitch/speed
- `E` - Open in external editor
- `F` - Reset zoom to fit

All keyboard shortcuts are customizable via Settings.

## Requirements

- **Required:** [ReaImGui](https://forum.cockos.com/showthread.php?t=250419) (install via ReaPack)
- **Recommended:** [SWS Extension](https://www.sws-extension.org/) (enables reverse detection display)
- **Optional:** [js_ReaScriptAPI](https://forum.cockos.com/showthread.php?t=212174) (smooth cursor lock on knob/slider drags)

## Installation (ReaPack)

1. In REAPER: Extensions > ReaPack > Import repositories
2. Paste: `https://raw.githubusercontent.com/novosadand/NVSD_ItemView/master/index.xml`
3. Extensions > ReaPack > Browse packages
4. Search "NVSD ItemView" > Right-click > Install
5. Also install **ReaImGui** from ReaPack if you don't have it
6. Restart REAPER — the script appears in your Actions list

## Manual Installation

1. Extract the ZIP to your REAPER Scripts folder (e.g., `REAPER/Scripts/NVSD/`)
2. In REAPER: Actions > Show action list > Load ReaScript
3. Select `NVSD_ItemView.lua`
4. Optionally assign a keyboard shortcut or add to toolbar

## Docking

Right-click the window title bar > Dock window > Choose position (top, bottom, left, right). Works great in the bottom docker for a DAW-style workflow.

## Settings

Open settings via:
- Gear icon (top right of info bar)
- Right-click anywhere > Settings...
- Search "NVSD ItemView Settings" in Actions list

**Color Themes:** Choose from 8 preset themes (Default, Modern, Ableton Dark, Pro Tools, High Contrast, Warm, Cool, Monochrome)

**Keyboard Shortcuts:** Customize all action shortcuts (WARP, mute, reverse, clear, edit, zoom). Click a binding, press a new key. Supports Ctrl/Shift/Alt modifiers.

Settings persist across sessions.

## Tips

- Markers snap to REAPER's grid and source boundaries
- Drag markers past source boundaries to create loops
- Click filename in info bar to open in Media Explorer
