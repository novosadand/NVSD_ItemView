# NVSD ItemView for REAPER

![NVSD ItemView](github%20cover2.jpg)

> Ableton-style clip view for REAPER audio items.

[![Website](https://img.shields.io/badge/Website-andrejnovosad.com-blue?style=flat&logo=googlechrome&logoColor=white)](https://andrejnovosad.com/)
[![LinkedIn](https://img.shields.io/badge/LinkedIn-Andrej%20Novosad-0A66C2?style=flat&logo=linkedin&logoColor=white)](https://www.linkedin.com/in/andrej-novosad/)
[![YouTube](https://img.shields.io/badge/YouTube-andrej__novosad-red?style=flat&logo=youtube&logoColor=white)](https://www.youtube.com/@andrej_novosad)
[![SoundCloud](https://img.shields.io/badge/SoundCloud-andrej__novosad-orange?style=flat&logo=soundcloud&logoColor=white)](https://soundcloud.com/andrej_novosad)
[![Instagram](https://img.shields.io/badge/Instagram-andrej____novosad-E4405F?style=flat&logo=instagram&logoColor=white)](https://www.instagram.com/andrej__novosad)

## TL;DR

- Select an audio item, run the script
- Drag markers to adjust start/end
- Left panel: gain, pitch, pan, WARP, reverse, FX
- Ctrl+scroll to zoom, middle-drag to pan
- Gear icon or `S` key for settings

## Quick Start

1. Select an audio item in REAPER
2. Run the script (Actions > NVSD_ItemView)
3. Drag the markers to adjust start/end points
4. Use the left panel for gain, pitch, reverse, WARP, and FX

## Installation (ReaPack)

1. In REAPER: Extensions > ReaPack > Import repositories
2. Paste: `https://raw.githubusercontent.com/novosadand/NVSD_ItemView/master/index.xml`
3. Extensions > ReaPack > Browse packages
4. Search "NVSD ItemView" > Right-click > Install
5. Also install **ReaImGui** from ReaPack if you don't have it
6. Restart REAPER. The script appears in your Actions list.

## Manual Installation

1. Extract the ZIP to your REAPER Scripts folder (e.g., `REAPER/Scripts/NVSD/`)
2. In REAPER: Actions > Show action list > Load ReaScript
3. Select `NVSD_ItemView.lua`
4. Optionally assign a keyboard shortcut or add to toolbar

## Controls

### Waveform

| Action | Description |
|--------|-------------|
| Drag markers | Adjust start/end |
| Alt + drag marker | Slide both markers (keeps length) |
| Ctrl + scroll | Zoom in/out |
| Ruler drag vertical | Zoom |
| Ruler drag horizontal | Pan |
| Middle mouse drag | Pan |
| Mouse 4 | Quick set start at cursor |
| Mouse 5 | Quick set end at cursor |
| Shift + Mouse 4 | Set fade-in end at cursor |
| Shift + Mouse 5 | Set fade-out start at cursor |
| Left-click + drag | Select time region |
| Ctrl+C | Copy selected region to clipboard |

### Left Panel

- **Gain slider**: Drag to adjust volume (+24dB to -inf). Ctrl+drag for fine control. Double-click to reset.
- **Pitch knob**: Drag to adjust pitch (+/-48 semitones). Double-click to reset.
- **Pan knob**: Drag to adjust pan. Double-click to reset.
- **Semitones/Cents boxes**: Fine pitch control. Click to edit, Shift+drag for fine adjustment.
- **WARP button**: Toggle "preserve pitch when changing rate" (mirrors REAPER's item properties checkbox).
- **Algorithm dropdown**: Select pitch algorithm (when WARP is on).
- **Reverse button**: Reverse the audio.
- **Clear button**: Reset item to default state (pitch=0, rate=1.0, warp off, original length).
- **Edit button**: Open in external editor (or Item Properties if none configured).
- **Mute checkbox**: Toggle mute.

### FX

- **Left FX button**: Toggle all FX bypass (when FX exist) / Add FX (when empty).
- **Right FX button**: Open FX chain. Alt+click to remove all FX.
- **FX list**: Click to open/close FX window. Shift+click to toggle bypass. Alt+click to delete. Checkbox toggles bypass. Drag to reorder. Right-click for context menu. Mouse wheel to scroll.

### Envelopes

| Action | Description |
|--------|-------------|
| Shift+V | Show Volume envelope |
| Shift+H | Show Pitch envelope |
| Shift+P | Show Pan envelope |
| H | Hide envelopes |
| L | Lock envelopes in place |
| Drag node | Move node |
| Alt+click node | Delete node |
| Drag segment | Move segment vertically |
| Alt+drag segment | Adjust curve tension |
| Shift+click segment | Add node |
| Ctrl+drag empty area | Freehand draw envelope |
| Right-drag | Rectangle select nodes |
| Delete | Remove selected nodes |

### Fades

Drag fade handles at item edges to adjust fade in/out length. Shift+Mouse4 to set fade-in end at cursor, Shift+Mouse5 to set fade-out start. Alt+drag the fade curve to adjust tension. Right-click a fade handle to pick a shape (Linear, Fast Start, Fast End, Fast Start Steep, Fast End Steep, Slow Start/End, Slow Start/End Steep).

### Audio Preview

Press `Ctrl+Space` to preview audio from the cursor position. Requires SWS extension.

### Keyboard Shortcuts

All shortcuts below are customizable in Settings > Shortcuts.

| Key | Action |
|-----|--------|
| W | Toggle WARP mode |
| M | Toggle mute |
| R | Reverse item |
| C | Crop markers to selection |
| Shift+C | Clear pitch/speed |
| E | Open in external editor |
| F | Reset zoom to fit |
| Z | Zoom to selection / markers (toggle) |
| Alt+Z | Unzoom completely |
| +/- | Zoom in/out |
| Ctrl+4 | Toggle envelope snap |
| L | Lock envelopes |
| Shift+V | Show Volume envelope |
| Shift+H | Show Pitch envelope |
| Shift+P | Show Pan envelope |
| H | Hide envelopes |
| S | Open settings |
| Ctrl+Space | Audio preview |

**Not rebindable:**

| Key | Action |
|-----|--------|
| Space | Play / Stop transport |
| Ctrl+Z | Undo |
| Ctrl+Y | Redo |
| Escape | Clear selection / Close |
| Delete | Delete selected nodes |
| Ctrl+C | Copy region to clipboard |

### General

- `Shift + drag` on any control for fine adjustment
- `Double-click` any knob or slider to reset to default
- Click filename in info bar to show in Explorer/Finder

## Settings

Open settings via gear icon, `S` key, right-click menu, or REAPER Actions list.

**Appearance**: Choose from 18 color themes (Default, Classic, Modern, Ableton Dark, Pro Tools, High Contrast, Warm, Cool, Monochrome, Sunset, Arctic, Forest, Neon, Bitwig, Cubase, Logic Pro, Studio One, Custom). The Custom theme lets you pick your own colors per group.

**Shortcuts**: Customize all action shortcuts. Click a binding, press a new key. Supports Ctrl/Shift/Alt modifiers. Press Backspace to clear a binding.

**Help**: Built-in reference for all controls and features.

Settings persist across sessions.

## Docking

Right-click the window title bar > Dock window > Choose position (top, bottom, left, right). Works great in the bottom docker for a DAW-style workflow.

## Requirements

- **Required:** [ReaImGui](https://forum.cockos.com/showthread.php?t=250419) (install via ReaPack)
- **Recommended:** [SWS Extension](https://www.sws-extension.org/) (enables reverse detection, audio preview, copy region)
- **Optional:** [js_ReaScriptAPI](https://forum.cockos.com/showthread.php?t=212174) (smooth cursor lock on knob/slider drags)

## Tips

- Map the script to a REAPER action shortcut for quick toggle on/off
- Markers snap to REAPER's grid and source boundaries
- Drag markers past source boundaries to create loops
- Click filename in info bar to show in Explorer/Finder
- Gain changes are non-destructive and can be undone
- WARP mode stretches audio to fit markers without pitch change
- All settings persist between sessions via ExtState
- Hover over any element for a few seconds to see a tooltip with available actions

## Support

If you find this tool useful, you can consider supporting me develop it further by buying me a coffee, thank you!

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-andrejnovosad-FFDD00?style=flat&logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/andrejnovosad)
