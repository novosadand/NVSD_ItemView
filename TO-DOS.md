# NVSD ItemView - Outstanding Todos

## macOS: Pitch Knob and Volume Slider Not Working - 2026-02-13 15:49

- **Investigate macOS pitch knob and volume slider** - User report that pitch knob and volume slider are non-functional on macOS. **Problem:** A macOS user reports "not working for me (pitch knob, volume slider)". These controls work on Windows but appear broken on macOS. Likely a platform-specific issue with ImGui input handling, mouse capture, or value mapping. **Files:** `Scripts/NVSD/NVSD_ItemView.lua` (pitch knob and volume slider widget code), `Scripts/NVSD/lib/drawing.lua` (widget rendering). **Solution:** Reproduce on macOS or add debug logging for knob/slider input events. Check if ImGui drag/input functions behave differently on macOS (e.g., mouse delta, drag sensitivity, or focus issues).

## User Requests - 2026-02-24

### Reflect timeline playrate/pitch in ItemView
- User wants: when an item is time-stretched (e.g. rate 0.5) or pitch-shifted on the REAPER timeline, ItemView should optionally reflect that. Currently ItemView shows source waveform without timeline rate/pitch adjustments.
- Could be a Defaults toggle: "Show timeline playrate" that adjusts the displayed waveform length/position to match the effective playback duration.
- Needs research: `D_PLAYRATE` is already read for marker positioning. The waveform peaks would need to be stretched to match effective length. Pitch display could show the combined take pitch + item pitch.

### Minimal waveform-only mode / customizable UI elements
- User wants: a mode showing only the waveform, hiding all controls (knobs, info bar, toolbar, etc.). Ideally, let users choose which UI elements are visible.
- Could be implemented as a "compact mode" toggle or a set of visibility options in the Defaults tab (show info bar, show toolbar, show controls).
- Consider: toolbar is already customizable. The info bar and control knobs are the main candidates for hiding.

### Waveform looks pixelated when zoomed in
- User reports: zooming in makes the waveform look blocky/pixelated.
- Root cause: per-view peak loading uses screen-width samples. When zoomed far in, each peak covers many pixels, creating stairstepping. Need to either request more peak samples when zoomed in, or interpolate between peaks for smoother rendering.
- Check: `get_peaks_for_range` sample count vs zoom level. May need to scale sample count with zoom.

### Waveform shaped by fades and volume/pan automation
- User wants: the waveform display to visually reflect fade-in/fade-out shapes and volume/pan envelope automation, similar to how REAPER's arrange view shapes item waveforms.
- Would need to: multiply peak values by the envelope value at each sample position, and apply fade curves to the waveform amplitude.
- Moderate complexity: need to evaluate envelope at each peak position and apply gain. Fade shapes already computed for drawing handles.

### WONT DO: Multi-item warp clear
- User wants: selecting two items and clearing warp on both at once. Also, manually extending an item then pressing Warp returns it to original size.
- Decision: won't do. ItemView is a single-item viewer. Multi-item batch operations are outside scope. The warp reset behavior is by design (warp mode operates on the source region).
