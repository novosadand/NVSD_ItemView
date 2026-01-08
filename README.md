# NVSD ItemView for REAPER

**Ableton-Style Clip View for REAPER Audio Items**

---

## TL;DR

Select an audio item, run the script. You'll see the full source waveform with blue markers showing what plays. Drag markers to edit boundaries. Use the left panel for gain/pitch. All actions support undo/redo.

**Quick Controls:**
- `Drag blue markers` - Adjust start/end
- `Alt + drag` - Slide both markers together
- `Ctrl + scroll` - Zoom
- `Middle mouse drag` - Pan
- `Mouse 4/5` - Quick set start/end
- `Shift + drag` - Fine control on sliders

---

## Table of Contents

1. [What It Does](#what-it-does)
2. [Requirements](#requirements)
3. [Installation](#installation)
4. [Quick Start](#quick-start)
5. [Complete Controls Reference](#complete-controls-reference)
6. [Left Panel Controls](#left-panel-controls)
7. [Visual Guide](#visual-guide)
8. [Tips & Tricks](#tips--tricks)
9. [Troubleshooting](#troubleshooting)

---

## What It Does

REAPER shows you only the portion of audio currently in your item. NVSD ItemView displays a **complete waveform** of your source audio with draggable markers showing exactly which portion your item plays.

**Key Features:**
- Full source waveform visualization
- Draggable start/end markers with snapping
- Looping support (extend beyond source boundaries)
- Gain slider (+24dB to -inf)
- Pitch control (48 semitones with cent precision)
- WARP mode (time-stretch vs playrate)
- Pitch algorithm selection
- Multi-channel waveform display
- Smart zoom (up to 500x)
- Timeline grid with bar numbers
- REAPER time selection overlay
- Full undo/redo support for all actions

---

## Requirements

| Requirement | Details |
|-------------|---------|
| **REAPER** | Version 6.0 or higher |
| **Required** | [ReaImGui](https://forum.cockos.com/showthread.php?t=250419) - Install via ReaPack |
| **Recommended** | [SWS/S&M Extension](https://www.sws-extension.org/) - Enables reverse detection and edge-drag display |
| **Optional** | [js_ReaScriptAPI](https://forum.cockos.com/showthread.php?t=212174) - Smooth cursor lock during drags |

### Installing Extensions

**ReaImGui (Required):**
1. REAPER → Extensions → ReaPack → Browse packages
2. Search "ReaImGui" → Install
3. Restart REAPER

**SWS Extension (Recommended):**
1. Download from [sws-extension.org](https://www.sws-extension.org/)
2. Run installer → Restart REAPER

**js_ReaScriptAPI (Optional):**
1. REAPER → Extensions → ReaPack → Browse packages
2. Search "js_ReaScriptAPI" → Install
3. Restart REAPER

---

## Installation

1. Copy the `NVSD_ItemView` folder to your REAPER Scripts folder:
   - **Windows:** `%APPDATA%\REAPER\Scripts\`
   - **macOS:** `~/Library/Application Support/REAPER/Scripts/`
   - **Linux:** `~/.config/REAPER/Scripts/`

2. In REAPER: Actions → Show action list
3. Click "Load ReaScript..." → Select `NVSD_ItemView.lua`
4. (Optional) Assign a keyboard shortcut or toolbar button

---

## Quick Start

1. **Select an audio item** in REAPER's arrange view
2. **Run the script** - Window opens showing the full source waveform
3. **Blue markers** show what portion of the source the item plays
4. **Drag the markers** to change playback boundaries
5. **Use the left panel** to adjust gain and pitch

---

## Complete Controls Reference

### Waveform Area

| Action | Effect |
|--------|--------|
| **Drag blue start marker** | Adjust where playback begins in source |
| **Drag blue end marker** | Adjust where playback ends in source |
| **Alt + drag either marker** | Slide both markers together (shift source position without changing length) |
| **Middle mouse button + drag** | Pan the waveform view left/right |
| **Ctrl + mouse wheel** | Zoom in/out centered on cursor position |
| **Mouse button 4 (back)** | Instantly set start marker to cursor position |
| **Mouse button 5 (forward)** | Instantly set end marker to cursor position |

### Ruler Area

| Action | Effect |
|--------|--------|
| **Drag up/down on ruler** | Zoom in/out (with cursor lock if js_ReaScriptAPI installed) |
| **Click and drag** | Continuous zoom adjustment |

### Info Bar (Top)

| Action | Effect |
|--------|--------|
| **Click mute square** | Toggle item mute on/off |
| **Click file name** | Open source file in REAPER's Media Explorer |

### Keyboard Shortcuts (while window focused)

| Shortcut | Effect |
|----------|--------|
| **Ctrl + Z** | Undo |
| **Ctrl + Y** or **Ctrl + Shift + Z** | Redo |

### Snapping Behavior

- Markers snap to **REAPER's grid** when snap is enabled in REAPER
- Markers snap to **source boundaries** (0 and source end) when dragged near them
- Snapping helps align loops precisely to source boundaries

---

## Left Panel Controls

### WARP Button

Toggles between two pitch modes:

| Mode | Behavior |
|------|----------|
| **WARP ON** (blue) | Pitch uses time-stretching. Item length stays constant. |
| **WARP OFF** (gray) | Pitch uses playrate. Item length changes with pitch. |

Clicking WARP converts the current pitch between modes automatically.

### Algorithm Dropdown

Only active when WARP is ON. Select the pitch-shifting algorithm:
- Project default
- Elastique (various modes)
- SoundTouch
- Rubber Band
- And more...

### Reverse Button

Reverses the audio source (uses REAPER's built-in reverse action).

### Edit Button

Opens the source file in your configured external audio editor.

### Gain Slider

| Action | Effect |
|--------|--------|
| **Drag up/down** | Adjust item volume (+24dB to -infinity) |
| **Shift + drag** | Fine adjustment (0.15x sensitivity) |
| **Double-click** | Reset to 0 dB |

The slider uses logarithmic scaling for natural volume control.

### Pitch Knob

| Action | Effect |
|--------|--------|
| **Drag up/down** | Adjust pitch (48 semitones range) |
| **Shift + drag** | Fine adjustment (0.2x sensitivity) |
| **Double-click** | Reset to 0 semitones |

### Semitones/Cents Boxes

Two small boxes below the pitch knob for precise adjustment:

| Box | Action | Effect |
|-----|--------|--------|
| **Left (semitones)** | Drag up/down | Adjust whole semitones |
| **Left (semitones)** | Double-click | Reset semitones to 0 |
| **Right (cents)** | Drag up/down | Adjust cents (0.5x sensitivity) |
| **Right (cents)** | Double-click | Reset cents to 0 |

---

## Visual Guide

### Colors and Elements

| Element | Meaning |
|---------|---------|
| **Blue markers & border** | Item playback boundaries (what you hear) |
| **Orange brackets in ruler** | Original source file start/end |
| **Light gray overlay** | Source audio not currently used |
| **Dark gray overlay** | Beyond source boundaries (looped content) |
| **Green waveform** | Active playback region |
| **Dimmed green waveform** | Inactive/unused regions |
| **Blue highlight in waveform** | REAPER's current time selection |
| **Gray triangles in ruler** | Time selection start/end points |

### Info Bar Display

Shows (from left to right):
- Mute indicator square (filled = unmuted, empty = muted)
- File icon
- Source file name (clickable)
- Sample rate
- Bit depth
- Channel count
- Duration

---

## Tips & Tricks

### Looping

- **Extend into loops:** Drag the end marker past the orange source boundary
- **Negative start offset:** Drag the start marker before the orange source start
- The dark overlay shows where looped content plays

### Workflow Tips

- **Edge-drag workflow:** Click and hold an item's edge in REAPER's arrange view - the waveform displays without selecting the item (requires SWS)
- **Dock the window:** Right-click the title bar to dock alongside other REAPER windows
- **Quick auditioning:** Changes are applied in real-time as you drag

### Zoom and Navigation

- Zoom goes up to **500x** for precise editing
- Pan is constrained to source boundaries
- Zoom centers on cursor position for intuitive navigation

### Undo/Redo

All actions create proper undo points:
- Marker adjustments
- Gain changes
- Pitch changes
- WARP mode toggle
- Mute toggle
- Reverse
- Algorithm changes

---

## Troubleshooting

**Window doesn't appear:**
- Ensure ReaImGui is installed and REAPER was restarted

**"This script requires ReaImGui" error:**
- Install ReaImGui via ReaPack and restart REAPER

**Waveform doesn't show when dragging item edges:**
- Install the SWS Extension for this feature

**Cursor jumps during drag operations:**
- Install js_ReaScriptAPI for smooth cursor locking

**MIDI items show "MIDI items not supported":**
- This script is designed for audio items only

**WARP button state wrong after undo:**
- This was fixed - WARP state now syncs with item properties

---

## License

This script is provided as-is for personal and commercial music production use.

---

## Support

For issues, feature requests, or questions, please contact the author.

---

*Made with care for the REAPER community*
