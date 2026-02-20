# NVSD ItemView - Outstanding Todos

## macOS: Pitch Knob and Volume Slider Not Working - 2026-02-13 15:49

- **Investigate macOS pitch knob and volume slider** - User report that pitch knob and volume slider are non-functional on macOS. **Problem:** A macOS user reports "not working for me (pitch knob, volume slider)". These controls work on Windows but appear broken on macOS. Likely a platform-specific issue with ImGui input handling, mouse capture, or value mapping. **Files:** `Scripts/NVSD/NVSD_ItemView.lua` (pitch knob and volume slider widget code), `Scripts/NVSD/lib/drawing.lua` (widget rendering). **Solution:** Reproduce on macOS or add debug logging for knob/slider input events. Check if ImGui drag/input functions behave differently on macOS (e.g., mouse delta, drag sensitivity, or focus issues).
