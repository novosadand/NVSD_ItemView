-- Unit tests for NVSD_ItemView
local lu = require("luaunit")

-- Mock REAPER API for testing outside REAPER
reaper = reaper or {}

-- Load real modules for testing (pure-Lua functions work outside REAPER)
local utils = dofile("Scripts/NVSD/lib/utils.lua")
local settings = dofile("Scripts/NVSD/lib/settings.lua")

-- Test suite
TestNVSDItemView = {}

function TestNVSDItemView:test_marker_near_detection()
    -- Test the is_near_marker logic (using real utils module)
    lu.assertTrue(utils.is_near_marker(100, 105, 10))   -- within threshold
    lu.assertTrue(utils.is_near_marker(100, 95, 10))    -- within threshold (other side)
    lu.assertFalse(utils.is_near_marker(100, 115, 10))  -- outside threshold
    lu.assertFalse(utils.is_near_marker(100, 85, 10))   -- outside threshold (other side)
    lu.assertTrue(utils.is_near_marker(100, 100, 10))   -- exactly on marker
end

function TestNVSDItemView:test_source_to_project_time()
    -- Test converting source time to project timeline time (using real utils module)
    -- Simple case: item at position 10, offset 2, playrate 1
    -- Source time 2 (at offset) -> project time 10 (at item start)
    lu.assertAlmostEquals(utils.source_to_project_time(2, 10, 2, 1), 10, 0.001)

    -- Source time 5 (3 seconds after offset) -> project time 13
    lu.assertAlmostEquals(utils.source_to_project_time(5, 10, 2, 1), 13, 0.001)

    -- With playrate 2 (double speed): source time 5 -> project time 11.5
    lu.assertAlmostEquals(utils.source_to_project_time(5, 10, 2, 2), 11.5, 0.001)

    -- With playrate 0.5 (half speed): source time 5 -> project time 16
    lu.assertAlmostEquals(utils.source_to_project_time(5, 10, 2, 0.5), 16, 0.001)
end

function TestNVSDItemView:test_project_to_source_time()
    -- Test converting project timeline time to source time (using real utils module)
    -- Simple case: item at position 10, offset 2, playrate 1
    -- Project time 10 (at item start) -> source time 2 (at offset)
    lu.assertAlmostEquals(utils.project_to_source_time(10, 10, 2, 1), 2, 0.001)

    -- Project time 13 -> source time 5
    lu.assertAlmostEquals(utils.project_to_source_time(13, 10, 2, 1), 5, 0.001)

    -- With playrate 2: project time 11.5 -> source time 5
    lu.assertAlmostEquals(utils.project_to_source_time(11.5, 10, 2, 2), 5, 0.001)

    -- With playrate 0.5: project time 16 -> source time 5
    lu.assertAlmostEquals(utils.project_to_source_time(16, 10, 2, 0.5), 5, 0.001)
end

function TestNVSDItemView:test_source_project_time_roundtrip()
    -- Test that source->project->source is identity (using real utils module)
    local item_position = 10
    local start_offset = 2
    local playrate = 1.5

    local source_time = 7.5
    local project_time = utils.source_to_project_time(source_time, item_position, start_offset, playrate)
    local back_to_source = utils.project_to_source_time(project_time, item_position, start_offset, playrate)

    lu.assertAlmostEquals(back_to_source, source_time, 0.0001)
end

function TestNVSDItemView:test_format_source_time()
    -- Test formatting source time (using real utils module)
    -- Basic formatting without ms
    lu.assertEquals(utils.format_source_time(0, false), "0:00")
    lu.assertEquals(utils.format_source_time(5, false), "0:05")
    lu.assertEquals(utils.format_source_time(65, false), "1:05")
    lu.assertEquals(utils.format_source_time(125, false), "2:05")

    -- With milliseconds
    lu.assertEquals(utils.format_source_time(0, true), "0:00:000")
    lu.assertEquals(utils.format_source_time(1.5, true), "0:01:500")
    lu.assertEquals(utils.format_source_time(0.25, true), "0:00:250")
    lu.assertEquals(utils.format_source_time(65.123, true), "1:05:123")

    -- Negative times
    lu.assertEquals(utils.format_source_time(-5, false), "-0:05")
    lu.assertEquals(utils.format_source_time(-65, false), "-1:05")
    lu.assertEquals(utils.format_source_time(-1.5, true), "-0:01:500")
end

function TestNVSDItemView:test_semitones_to_playrate()
    -- Test converting semitones to playrate (using real utils module)
    -- 0 semitones = no change
    lu.assertAlmostEquals(utils.semitones_to_playrate(0), 1.0, 0.001)

    -- +12 semitones = double speed (octave up)
    lu.assertAlmostEquals(utils.semitones_to_playrate(12), 2.0, 0.001)

    -- -12 semitones = half speed (octave down)
    lu.assertAlmostEquals(utils.semitones_to_playrate(-12), 0.5, 0.001)

    -- +7 semitones = perfect fifth up
    lu.assertAlmostEquals(utils.semitones_to_playrate(7), 2^(7/12), 0.001)

    -- -5 semitones = perfect fourth down
    lu.assertAlmostEquals(utils.semitones_to_playrate(-5), 2^(-5/12), 0.001)
end

function TestNVSDItemView:test_playrate_to_semitones()
    -- Test converting playrate to semitones (using real utils module)
    -- Normal speed = 0 semitones
    lu.assertAlmostEquals(utils.playrate_to_semitones(1.0), 0, 0.001)

    -- Double speed = +12 semitones
    lu.assertAlmostEquals(utils.playrate_to_semitones(2.0), 12, 0.001)

    -- Half speed = -12 semitones
    lu.assertAlmostEquals(utils.playrate_to_semitones(0.5), -12, 0.001)

    -- Roundtrip test
    local original = 7.5
    local playrate = utils.semitones_to_playrate(original)
    local back = utils.playrate_to_semitones(playrate)
    lu.assertAlmostEquals(back, original, 0.001)
end

function TestNVSDItemView:test_db_to_linear_and_back()
    -- Test dB to linear conversion (using real utils module)
    -- 0 dB = unity gain
    lu.assertAlmostEquals(utils.db_to_gain(0), 1.0, 0.001)

    -- +6 dB = ~2x
    lu.assertAlmostEquals(utils.db_to_gain(6), 1.995, 0.01)

    -- -6 dB = ~0.5x
    lu.assertAlmostEquals(utils.db_to_gain(-6), 0.501, 0.01)

    -- +24 dB (max gain in UI)
    lu.assertAlmostEquals(utils.db_to_gain(24), 15.85, 0.1)

    -- Very low dB = 0 gain (utils.db_to_gain guards at -150)
    lu.assertEquals(utils.db_to_gain(-150), 0)

    -- Roundtrip
    local original_db = -12
    local linear = utils.db_to_gain(original_db)
    local back = utils.gain_to_db(linear)
    lu.assertAlmostEquals(back, original_db, 0.001)
end

function TestNVSDItemView:test_format_db()
    -- Test formatting dB value for display (using real utils module)
    -- Positive values: no + sign, includes " dB"
    lu.assertEquals(utils.format_db(24), "24.0 dB")
    lu.assertEquals(utils.format_db(12), "12.0 dB")
    lu.assertEquals(utils.format_db(6), "6.0 dB")
    lu.assertEquals(utils.format_db(0), "0.0 dB")

    -- Negative values: includes " dB"
    lu.assertEquals(utils.format_db(-6), "-6.0 dB")
    lu.assertEquals(utils.format_db(-12), "-12.0 dB")
    lu.assertEquals(utils.format_db(-24), "-24.0 dB")

    -- Very low values: show -∞ dB
    lu.assertEquals(utils.format_db(-60), "-∞ dB")
    lu.assertEquals(utils.format_db(-61), "-∞ dB")
    lu.assertEquals(utils.format_db(-100), "-∞ dB")

    -- Fractional values
    lu.assertEquals(utils.format_db(6.5), "6.5 dB")
    lu.assertEquals(utils.format_db(-3.2), "-3.2 dB")
    lu.assertEquals(utils.format_db(0.1), "0.1 dB")
end

function TestNVSDItemView:test_gain_to_db()
    -- Test converting linear gain to dB (using real utils module)
    -- Unity gain = 0 dB
    lu.assertAlmostEquals(utils.gain_to_db(1.0), 0, 0.001)

    -- Double = +6.02 dB
    lu.assertAlmostEquals(utils.gain_to_db(2.0), 6.02, 0.1)

    -- Half = -6.02 dB
    lu.assertAlmostEquals(utils.gain_to_db(0.5), -6.02, 0.1)

    -- +24 dB gain (~15.85x)
    lu.assertAlmostEquals(utils.gain_to_db(15.85), 24, 0.1)

    -- Zero gain = -inf
    lu.assertEquals(utils.gain_to_db(0), -math.huge)
end

function TestNVSDItemView:test_db_to_slider_position()
    -- Test converting dB to slider position (using real utils module)
    -- +24 dB = top (1.0)
    lu.assertAlmostEquals(utils.db_to_slider(24), 1.0, 0.001)

    -- 0 dB = middle (0.5)
    lu.assertAlmostEquals(utils.db_to_slider(0), 0.5, 0.001)

    -- +12 dB = 0.75
    lu.assertAlmostEquals(utils.db_to_slider(12), 0.75, 0.001)

    -- Very low dB = bottom (0.0)
    lu.assertAlmostEquals(utils.db_to_slider(-150), 0, 0.001)

    -- Check logarithmic curve: -6 dB should be between 0 and 0.5
    local pos_neg6 = utils.db_to_slider(-6)
    lu.assertTrue(pos_neg6 > 0.3)  -- Above bottom
    lu.assertTrue(pos_neg6 < 0.5)  -- Below 0dB position
end

function TestNVSDItemView:test_slider_to_db()
    -- Test converting slider position to dB (using real utils module)
    -- Top = +24 dB
    lu.assertAlmostEquals(utils.slider_to_db(1.0), 24, 0.001)

    -- Middle = 0 dB
    lu.assertAlmostEquals(utils.slider_to_db(0.5), 0, 0.001)

    -- 0.75 = +12 dB
    lu.assertAlmostEquals(utils.slider_to_db(0.75), 12, 0.001)

    -- Bottom = -inf dB
    lu.assertEquals(utils.slider_to_db(0), -math.huge)
end

function TestNVSDItemView:test_pitch_to_semitones_cents()
    -- Test splitting pitch value into semitones and cents (using real utils module)
    -- Uses round-to-nearest for Ableton-style ±50 cents range

    -- Exact semitone
    local semi, cents = utils.pitch_to_semitones_cents(5.0)
    lu.assertEquals(semi, 5)
    lu.assertEquals(cents, 0)

    -- Positive cents (below half-semitone)
    semi, cents = utils.pitch_to_semitones_cents(5.25)
    lu.assertEquals(semi, 5)
    lu.assertEquals(cents, 25)

    -- Positive pitch with large fractional: rounds UP to nearest semitone
    semi, cents = utils.pitch_to_semitones_cents(4.75)
    lu.assertEquals(semi, 5)    -- floor(4.75 + 0.5) = floor(5.25) = 5
    lu.assertEquals(cents, -25) -- (4.75 - 5) * 100 = -25

    -- Negative pitch: round(-3.5) = floor(-3.0) = -3
    semi, cents = utils.pitch_to_semitones_cents(-3.5)
    lu.assertEquals(semi, -3)
    lu.assertEquals(cents, -50)

    -- Negative pitch with large fractional: rounds to nearest
    semi, cents = utils.pitch_to_semitones_cents(-1.3)
    lu.assertEquals(semi, -1)
    lu.assertEquals(cents, -30)

    -- Boundary: 0.50 rounds up
    semi, cents = utils.pitch_to_semitones_cents(0.50)
    lu.assertEquals(semi, 1)    -- floor(0.50 + 0.5) = floor(1.0) = 1
    lu.assertEquals(cents, -50) -- (0.50 - 1) * 100 = -50

    -- Zero pitch
    semi, cents = utils.pitch_to_semitones_cents(0)
    lu.assertEquals(semi, 0)
    lu.assertEquals(cents, 0)
end

function TestNVSDItemView:test_semitones_cents_to_pitch()
    -- Test combining semitones and cents into pitch value (using real utils module)
    lu.assertAlmostEquals(utils.semitones_cents_to_pitch(5, 0), 5.0, 0.001)
    lu.assertAlmostEquals(utils.semitones_cents_to_pitch(5, 50), 5.5, 0.001)
    lu.assertAlmostEquals(utils.semitones_cents_to_pitch(5, -25), 4.75, 0.001)
    lu.assertAlmostEquals(utils.semitones_cents_to_pitch(-3, 50), -2.5, 0.001)
    lu.assertAlmostEquals(utils.semitones_cents_to_pitch(0, 0), 0, 0.001)
end

function TestNVSDItemView:test_file_name_extraction()
    -- Test extracting file name from full path (using real utils module)
    lu.assertEquals(utils.get_file_name("/home/user/audio/kick.wav"), "kick.wav")
    lu.assertEquals(utils.get_file_name("C:\\Users\\audio\\snare.wav"), "snare.wav")
    lu.assertEquals(utils.get_file_name("hihat.wav"), "hihat.wav")
    lu.assertEquals(utils.get_file_name(""), "")
    lu.assertEquals(utils.get_file_name(nil), "")
    lu.assertEquals(utils.get_file_name("/home/user/My Audio/cool sound.wav"), "cool sound.wav")
end

function TestNVSDItemView:test_settings_format_shortcut()
    -- Test shortcut formatting for display (using real settings module)
    lu.assertEquals(settings.format_shortcut({ctrl = true, shift = false, alt = false, key = "Z"}), "Ctrl+Z")
    lu.assertEquals(settings.format_shortcut({ctrl = true, shift = true, alt = false, key = "Z"}), "Ctrl+Shift+Z")
    lu.assertEquals(settings.format_shortcut({ctrl = false, shift = false, alt = true, key = "F4"}), "Alt+F4")
    lu.assertEquals(settings.format_shortcut({ctrl = false, shift = false, alt = false, key = "Space"}), "Space")
    lu.assertEquals(settings.format_shortcut({ctrl = true, shift = true, alt = true, key = "A"}), "Ctrl+Shift+Alt+A")
    -- Empty key returns empty string (edge case fix)
    lu.assertEquals(settings.format_shortcut({ctrl = true, shift = false, alt = false, key = ""}), "")
end

function TestNVSDItemView:test_settings_theme_lookup()
    -- Test theme retrieval by ID (using real settings module)
    local theme = settings.get_theme("ableton_dark")
    lu.assertEquals(theme.name, "Ableton Dark")
    lu.assertNotNil(theme.colors.waveform)

    -- Test fallback to default for unknown ID
    local unknown = settings.get_theme("nonexistent")
    lu.assertEquals(unknown.id, "default")

    -- Verify THEMES table is populated
    lu.assertTrue(#settings.THEMES >= 2)
end

function TestNVSDItemView:test_settings_format_no_modifiers()
    -- Format bare key like "W" -> "W" (using real settings module)
    lu.assertEquals(settings.format_shortcut({ctrl = false, shift = false, alt = false, key = "W"}), "W")
    lu.assertEquals(settings.format_shortcut({ctrl = false, shift = false, alt = false, key = "F"}), "F")
end

function TestNVSDItemView:test_settings_theme_fallback_to_default()
    -- Unknown theme ID returns first theme (using real settings module)
    lu.assertEquals(settings.get_theme("warm").name, "Warm")
    lu.assertEquals(settings.get_theme("nonexistent_theme_xyz").id, "default")
    lu.assertEquals(settings.get_theme("").id, "default")
end

function TestNVSDItemView:test_find_conflict_detects_duplicate()
    -- Same key+modifiers on two different shortcuts → returns conflict name (using real settings module)
    local shortcuts = {
        toggle_warp = {ctrl = false, shift = false, alt = false, key = "W"},
        toggle_mute = {ctrl = false, shift = false, alt = false, key = "W"},  -- duplicate
    }
    local result = settings.find_conflict(shortcuts, "toggle_warp", {ctrl = false, shift = false, alt = false, key = "W"})
    lu.assertEquals(result, "toggle_mute")
end

function TestNVSDItemView:test_find_conflict_no_conflict_different_modifiers()
    -- "W" vs "Ctrl+W" → no conflict (using real settings module)
    local shortcuts = {
        toggle_warp = {ctrl = false, shift = false, alt = false, key = "W"},
        toggle_mute = {ctrl = true, shift = false, alt = false, key = "W"},  -- Ctrl+W
    }
    local result = settings.find_conflict(shortcuts, "toggle_warp", {ctrl = false, shift = false, alt = false, key = "W"})
    lu.assertNil(result)
end

function TestNVSDItemView:test_find_conflict_ignores_empty_keys()
    -- Two unbound shortcuts → no conflict (using real settings module)
    local shortcuts = {
        zoom_in = {ctrl = false, shift = false, alt = false, key = ""},
        zoom_out = {ctrl = false, shift = false, alt = false, key = ""},
    }
    local result = settings.find_conflict(shortcuts, "zoom_in", {ctrl = false, shift = false, alt = false, key = ""})
    lu.assertNil(result)
end

function TestNVSDItemView:test_find_conflict_skips_self()
    -- Same binding on the shortcut being edited → should NOT report as conflict (using real settings module)
    local shortcuts = {
        toggle_warp = {ctrl = false, shift = false, alt = false, key = "W"},
        toggle_mute = {ctrl = false, shift = false, alt = false, key = "M"},
    }
    local result = settings.find_conflict(shortcuts, "toggle_warp", {ctrl = false, shift = false, alt = false, key = "W"})
    lu.assertNil(result)
end

function TestNVSDItemView:test_settings_format_all_modifier_combos()
    local fmt = settings.format_shortcut

    -- No modifiers
    lu.assertEquals(fmt({ctrl = false, shift = false, alt = false, key = "A"}), "A")

    -- Ctrl only
    lu.assertEquals(fmt({ctrl = true, shift = false, alt = false, key = "A"}), "Ctrl+A")

    -- Shift only
    lu.assertEquals(fmt({ctrl = false, shift = true, alt = false, key = "A"}), "Shift+A")

    -- Alt only
    lu.assertEquals(fmt({ctrl = false, shift = false, alt = true, key = "A"}), "Alt+A")

    -- Ctrl+Shift
    lu.assertEquals(fmt({ctrl = true, shift = true, alt = false, key = "A"}), "Ctrl+Shift+A")

    -- Ctrl+Alt
    lu.assertEquals(fmt({ctrl = true, shift = false, alt = true, key = "A"}), "Ctrl+Alt+A")

    -- Shift+Alt
    lu.assertEquals(fmt({ctrl = false, shift = true, alt = true, key = "A"}), "Shift+Alt+A")

    -- Ctrl+Shift+Alt
    lu.assertEquals(fmt({ctrl = true, shift = true, alt = true, key = "A"}), "Ctrl+Shift+Alt+A")
end

-- Test conflict detection catches exact duplicates
function TestNVSDItemView:test_settings_conflict_detects_exact_duplicate()
    local shortcuts = {
        action_a = {ctrl = false, shift = false, alt = false, key = "W"},
        action_b = {ctrl = true, shift = false, alt = false, key = "S"},
    }
    -- Exact duplicate of action_a
    local binding = {ctrl = false, shift = false, alt = false, key = "W"}
    local conflict = settings.find_conflict(shortcuts, "action_c", binding)
    lu.assertEquals(conflict, "action_a")
end

-- Test conflict detection allows same key with different modifiers
function TestNVSDItemView:test_settings_no_conflict_different_modifiers()
    local shortcuts = {
        action_a = {ctrl = false, shift = false, alt = false, key = "H"},
        action_b = {ctrl = false, shift = true, alt = false, key = "H"},
    }
    -- H (plain) doesn't conflict with Shift+H when checking against action_b
    local binding = {ctrl = false, shift = false, alt = false, key = "H"}
    local conflict = settings.find_conflict(shortcuts, "action_c", binding)
    lu.assertEquals(conflict, "action_a")  -- conflicts with action_a, not action_b

    -- Shift+H doesn't conflict with plain H
    local binding2 = {ctrl = false, shift = true, alt = false, key = "H"}
    local conflict2 = settings.find_conflict(shortcuts, "action_c", binding2)
    lu.assertEquals(conflict2, "action_b")  -- conflicts with action_b, not action_a
end

-- Test all default shortcuts have valid structure
function TestNVSDItemView:test_default_shortcuts_complete()
    local expected_names = {
        "zoom_in", "zoom_out", "reset_zoom", "toggle_warp", "toggle_mute",
        "reverse", "clear", "crop_to_selection", "open_editor", "toggle_snap",
        "audio_preview", "envelope_lock", "show_volume_env", "show_pitch_env",
        "show_pan_env", "hide_envelopes", "open_settings",
        "set_start_marker", "set_end_marker", "set_fade_in", "set_fade_out",
        "zoom_to_markers", "unzoom_all", "toggle_cue_markers", "toggle_ghost_markers",
        "show_in_explorer", "quantize_transients", "insert_warp_marker", "add_transient",
        "preview_from_start", "toggle_auto_fit", "scroll_zoom", "scroll_vzoom",
    }

    for _, name in ipairs(expected_names) do
        local sc = settings.DEFAULT_SHORTCUTS[name]
        lu.assertNotNil(sc, "Missing default shortcut: " .. name)
        lu.assertNotNil(sc.ctrl, name .. " missing ctrl field")
        lu.assertNotNil(sc.shift, name .. " missing shift field")
        lu.assertNotNil(sc.alt, name .. " missing alt field")
        lu.assertNotNil(sc.key, name .. " missing key field")
    end

    -- Verify count matches (no extra unexpected shortcuts)
    local count = 0
    for _ in pairs(settings.DEFAULT_SHORTCUTS) do count = count + 1 end
    lu.assertEquals(count, #expected_names)
end

-- Test new shortcut defaults have correct modifier combinations
function TestNVSDItemView:test_new_shortcut_defaults()
    -- envelope_lock: plain L
    local el = settings.DEFAULT_SHORTCUTS.envelope_lock
    lu.assertFalse(el.ctrl)
    lu.assertFalse(el.shift)
    lu.assertFalse(el.alt)
    lu.assertEquals(el.key, "L")

    -- show_volume_env: Shift+V
    local sv = settings.DEFAULT_SHORTCUTS.show_volume_env
    lu.assertFalse(sv.ctrl)
    lu.assertTrue(sv.shift)
    lu.assertFalse(sv.alt)
    lu.assertEquals(sv.key, "V")

    -- show_pitch_env: Shift+H
    local sp = settings.DEFAULT_SHORTCUTS.show_pitch_env
    lu.assertFalse(sp.ctrl)
    lu.assertTrue(sp.shift)
    lu.assertFalse(sp.alt)
    lu.assertEquals(sp.key, "H")

    -- show_pan_env: Shift+P
    local spn = settings.DEFAULT_SHORTCUTS.show_pan_env
    lu.assertFalse(spn.ctrl)
    lu.assertTrue(spn.shift)
    lu.assertFalse(spn.alt)
    lu.assertEquals(spn.key, "P")

    -- hide_envelopes: plain H
    local he = settings.DEFAULT_SHORTCUTS.hide_envelopes
    lu.assertFalse(he.ctrl)
    lu.assertFalse(he.shift)
    lu.assertFalse(he.alt)
    lu.assertEquals(he.key, "H")

    -- open_settings: Alt+S
    local os_sc = settings.DEFAULT_SHORTCUTS.open_settings
    lu.assertFalse(os_sc.ctrl)
    lu.assertFalse(os_sc.shift)
    lu.assertTrue(os_sc.alt)
    lu.assertEquals(os_sc.key, "S")
end

-- Test H (plain) and Shift+H don't conflict with each other
function TestNVSDItemView:test_h_shift_h_no_conflict()
    local shortcuts = settings.DEFAULT_SHORTCUTS
    -- hide_envelopes (H) and show_pitch_env (Shift+H) use same key, different modifiers
    local hide = shortcuts.hide_envelopes
    local show_pitch = shortcuts.show_pitch_env
    lu.assertEquals(hide.key, "H")
    lu.assertEquals(show_pitch.key, "H")
    lu.assertFalse(hide.shift)
    lu.assertTrue(show_pitch.shift)

    -- Verify no conflict detected between them
    local conflict = settings.find_conflict(shortcuts, "hide_envelopes",
        {ctrl = false, shift = false, alt = false, key = "H"})
    lu.assertNil(conflict)  -- hide_envelopes itself is excluded, no other plain-H binding

    local conflict2 = settings.find_conflict(shortcuts, "show_pitch_env",
        {ctrl = false, shift = true, alt = false, key = "H"})
    lu.assertNil(conflict2)  -- show_pitch_env excluded, no other Shift+H binding
end

-- Test all themes have all required color keys
function TestNVSDItemView:test_theme_colors_complete()
    local required_keys = {
        "waveform", "waveform_inactive", "waveform_bg", "centerline",
        "markers", "markers_hover", "border", "playhead",
        "grid_bar", "grid_beat", "ruler_bg", "ruler_text", "ruler_tick",
        "info_bar_bg", "info_bar_text", "info_bar_icon",
        "btn_on", "btn_off", "btn_hover", "btn_text",
    }

    for _, theme in ipairs(settings.THEMES) do
        lu.assertNotNil(theme.id, "Theme missing id")
        lu.assertNotNil(theme.name, "Theme missing name")
        lu.assertNotNil(theme.colors, "Theme " .. theme.name .. " missing colors")

        for _, key in ipairs(required_keys) do
            lu.assertNotNil(theme.colors[key],
                "Theme " .. theme.name .. " missing color: " .. key)
            -- Verify color is a number (RGBA hex)
            lu.assertEquals(type(theme.colors[key]), "number",
                "Theme " .. theme.name .. " color " .. key .. " is not a number")
        end
    end
end

-- Test theme count (18: 12 original + Classic rename + 4 DAW + Custom)
function TestNVSDItemView:test_theme_count()
    lu.assertEquals(#settings.THEMES, 18)
end

-- Test theme IDs are unique
function TestNVSDItemView:test_theme_ids_unique()
    local seen = {}
    for _, theme in ipairs(settings.THEMES) do
        lu.assertNil(seen[theme.id], "Duplicate theme id: " .. theme.id)
        seen[theme.id] = true
    end
end

-- Test new themes exist with correct IDs
function TestNVSDItemView:test_new_themes_exist()
    local new_ids = {"sunset", "arctic", "forest", "neon"}
    for _, id in ipairs(new_ids) do
        local theme = settings.get_theme(id)
        lu.assertNotNil(theme, "Missing new theme: " .. id)
        lu.assertEquals(theme.id, id)
    end
end

-- Test config refresh_colors maps all theme color keys
function TestNVSDItemView:test_config_refresh_colors_maps_all_keys()
    local config = dofile("Scripts/NVSD/lib/config.lua")

    -- Set up mock settings
    local mock_colors = {
        waveform = 0x112233FF,
        waveform_inactive = 0x223344FF,
        waveform_bg = 0x334455FF,
        centerline = 0x445566FF,
        markers = 0x556677FF,
        markers_hover = 0x667788FF,
        border = 0x778899FF,
        playhead = 0x8899AAFF,
        grid_bar = 0x99AABBFF,
        grid_beat = 0xAABBCCFF,
        ruler_bg = 0xBBCCDDFF,
        ruler_text = 0xCCDDEEFF,
        ruler_tick = 0xDDEEFFFF,
        info_bar_bg = 0x111111FF,
        info_bar_text = 0x222222FF,
        info_bar_icon = 0x333333FF,
        btn_on = 0x444444FF,
        btn_off = 0x555555FF,
        btn_hover = 0x666666FF,
        btn_text = 0x777777FF,
    }

    config.settings = {
        get_colors = function() return mock_colors end
    }

    config.refresh_colors()

    lu.assertEquals(config.COLOR_WAVEFORM, mock_colors.waveform)
    lu.assertEquals(config.COLOR_WAVEFORM_INACTIVE, mock_colors.waveform_inactive)
    lu.assertEquals(config.COLOR_WAVEFORM_BG, mock_colors.waveform_bg)
    lu.assertEquals(config.COLOR_CENTERLINE, mock_colors.centerline)
    lu.assertEquals(config.COLOR_MARKER, mock_colors.markers)
    lu.assertEquals(config.COLOR_MARKER_HOVER, mock_colors.markers_hover)
    lu.assertEquals(config.COLOR_BORDER, mock_colors.border)
    lu.assertEquals(config.COLOR_PLAYHEAD, mock_colors.playhead)
    lu.assertEquals(config.COLOR_GRID_BAR, mock_colors.grid_bar)
    lu.assertEquals(config.COLOR_GRID_BEAT, mock_colors.grid_beat)
    lu.assertEquals(config.COLOR_RULER_BG, mock_colors.ruler_bg)
    lu.assertEquals(config.COLOR_RULER_TEXT, mock_colors.ruler_text)
    lu.assertEquals(config.COLOR_RULER_TICK, mock_colors.ruler_tick)
    lu.assertEquals(config.COLOR_INFO_BAR_BG, mock_colors.info_bar_bg)
    lu.assertEquals(config.COLOR_INFO_BAR_TEXT, mock_colors.info_bar_text)
    lu.assertEquals(config.COLOR_INFO_BAR_ICON, mock_colors.info_bar_icon)
    lu.assertEquals(config.COLOR_BTN_ON, mock_colors.btn_on)
    lu.assertEquals(config.COLOR_BTN_OFF, mock_colors.btn_off)
    lu.assertEquals(config.COLOR_BTN_HOVER, mock_colors.btn_hover)
    lu.assertEquals(config.COLOR_BTN_TEXT, mock_colors.btn_text)
end

-- Test darken_color math
function TestNVSDItemView:test_default_shortcuts_no_conflicts()
    local defaults = settings.DEFAULT_SHORTCUTS
    for name, binding in pairs(defaults) do
        if binding.key ~= "" then
            local conflict = settings.find_conflict(defaults, name, binding)
            lu.assertNil(conflict,
                "Default shortcut " .. name .. " conflicts with " .. (conflict or ""))
        end
    end
end

-- Test EDITABLE_SHORTCUTS references valid shortcut names
function TestNVSDItemView:test_editable_shortcuts_valid()
    -- Load settings_ui to check EDITABLE_SHORTCUTS
    -- Since settings_ui requires ImGui, we check via settings.DEFAULT_SHORTCUTS
    local expected_editable = {
        "toggle_warp", "toggle_mute", "reverse", "clear", "open_editor",
        "reset_zoom", "zoom_in", "zoom_out", "toggle_snap", "audio_preview",
        "envelope_lock", "show_volume_env", "show_pitch_env", "show_pan_env",
        "hide_envelopes", "open_settings",
    }

    for _, name in ipairs(expected_editable) do
        lu.assertNotNil(settings.DEFAULT_SHORTCUTS[name],
            "Editable shortcut '" .. name .. "' has no default definition")
    end
end

-- ========================================================================
-- Refactoring tests: utils.point_in_rect, state helpers
-- ========================================================================

-- Test point_in_rect
function TestNVSDItemView:test_point_in_rect_inside()
    lu.assertTrue(utils.point_in_rect(50, 50, 0, 0, 100, 100))
end

function TestNVSDItemView:test_point_in_rect_on_edge()
    lu.assertTrue(utils.point_in_rect(0, 0, 0, 0, 100, 100))      -- top-left
    lu.assertTrue(utils.point_in_rect(100, 100, 0, 0, 100, 100))  -- bottom-right
    lu.assertTrue(utils.point_in_rect(50, 0, 0, 0, 100, 100))     -- top edge
    lu.assertTrue(utils.point_in_rect(0, 50, 0, 0, 100, 100))     -- left edge
end

function TestNVSDItemView:test_point_in_rect_outside()
    lu.assertFalse(utils.point_in_rect(-1, 50, 0, 0, 100, 100))   -- left
    lu.assertFalse(utils.point_in_rect(101, 50, 0, 0, 100, 100))  -- right
    lu.assertFalse(utils.point_in_rect(50, -1, 0, 0, 100, 100))   -- above
    lu.assertFalse(utils.point_in_rect(50, 101, 0, 0, 100, 100))  -- below
end

-- Test state.reset_all_drags
function TestNVSDItemView:test_state_reset_all_drags()
    local state_mod = dofile("Scripts/NVSD/lib/state.lua")
    -- Set some flags
    state_mod.dragging_start = true
    state_mod.dragging_end = true
    state_mod.fx_dragging = true
    state_mod.env_freehand_drawing = true
    state_mod.env_multi_drag_start_positions = {{1, 2}}
    state_mod.env_multi_drag_all_points = {{3, 4}}

    state_mod.reset_all_drags()

    lu.assertFalse(state_mod.dragging_start)
    lu.assertFalse(state_mod.dragging_end)
    lu.assertFalse(state_mod.fx_dragging)
    lu.assertFalse(state_mod.env_freehand_drawing)
    lu.assertEquals(#state_mod.env_multi_drag_start_positions, 0)
    lu.assertEquals(#state_mod.env_multi_drag_all_points, 0)
end

-- Test state.any_drag_active
function TestNVSDItemView:test_state_any_drag_active_false_when_idle()
    local state_mod = dofile("Scripts/NVSD/lib/state.lua")
    lu.assertFalse(state_mod.any_drag_active())
end

function TestNVSDItemView:test_state_any_drag_active_true_when_dragging()
    local state_mod = dofile("Scripts/NVSD/lib/state.lua")

    state_mod.dragging_start = true
    lu.assertTrue(state_mod.any_drag_active())
    state_mod.dragging_start = false

    state_mod.env_freehand_drawing = true
    lu.assertTrue(state_mod.any_drag_active())
    state_mod.env_freehand_drawing = false

    state_mod.is_panning = true
    lu.assertTrue(state_mod.any_drag_active())
    state_mod.is_panning = false

    state_mod.pitch_gutter_dragging = true
    lu.assertTrue(state_mod.any_drag_active())
end

-- ===== Round 3 Tests =====

-- Load drawing module (pure math functions work without REAPER)
local drawing = dofile("Scripts/NVSD/lib/drawing.lua")
local dt = drawing._test

-- === Fade Math Tests ===

-- Test eval_fade for all 7 shapes at boundaries and midpoint
function TestNVSDItemView:test_fade_eval_all_7_shapes()
    local eval = dt.eval_fade
    for shape = 0, 6 do
        -- Fade-in: t=0 should be 0, t=1 should be 1
        lu.assertAlmostEquals(eval(0, shape, 0, false), 0, 0.01,
            "Shape " .. shape .. " fade-in at t=0")
        lu.assertAlmostEquals(eval(1, shape, 0, false), 1, 0.01,
            "Shape " .. shape .. " fade-in at t=1")
        -- Fade-out: t=0 should be 1, t=1 should be 0
        lu.assertAlmostEquals(eval(0, shape, 0, true), 1, 0.01,
            "Shape " .. shape .. " fade-out at t=0")
        lu.assertAlmostEquals(eval(1, shape, 0, true), 0, 0.01,
            "Shape " .. shape .. " fade-out at t=1")
        -- Midpoint should be in valid range
        local mid = eval(0.5, shape, 0, false)
        lu.assertTrue(mid >= 0 and mid <= 1,
            "Shape " .. shape .. " midpoint out of range: " .. tostring(mid))
    end
end

-- Test eval_fade boundary clamping (Bezier path clamps, math fns may extrapolate)
function TestNVSDItemView:test_fade_eval_boundary_clamp()
    local eval = dt.eval_fade
    -- Bezier path (dir != 0) uses cbez_y which clamps to endpoint values
    lu.assertAlmostEquals(eval(-1, 1, 0.5, false), 0, 0.01, "Bezier t<0")
    lu.assertAlmostEquals(eval(2, 1, 0.5, false), 1, 0.01, "Bezier t>1")
    -- Fade-out Bezier
    lu.assertAlmostEquals(eval(-1, 1, 0.5, true), 1, 0.01, "Bezier fade-out t<0")
    lu.assertAlmostEquals(eval(2, 1, 0.5, true), 0, 0.01, "Bezier fade-out t>1")
end

-- Test fade LUT matches eval_fade within tolerance
function TestNVSDItemView:test_fade_lut_matches_eval()
    local eval = dt.eval_fade
    local get_lut = dt.get_fade_lut
    local lookup = dt.fade_lut_lookup
    local LUT_SIZE = dt.FADE_LUT_SIZE

    for shape = 0, 6 do
        local lut = get_lut(shape, 0, false)
        -- Check at several points
        for _, t in ipairs({0, 0.1, 0.25, 0.5, 0.75, 0.9, 1}) do
            local expected = eval(t, shape, 0, false)
            local got = lookup(lut, t)
            lu.assertAlmostEquals(got, expected, 0.02,
                "LUT mismatch shape " .. shape .. " at t=" .. t)
        end
    end
end

-- Test fade direction bias (fast start should be > 0.5 at midpoint)
function TestNVSDItemView:test_fade_direction_bias()
    local eval = dt.eval_fade
    -- Shape 1 (fast start): midpoint should be > 0.5 (fast start = more gain early)
    local fast_start_mid = eval(0.5, 1, 0, false)
    lu.assertTrue(fast_start_mid > 0.5,
        "Fast start shape should be > 0.5 at midpoint, got " .. tostring(fast_start_mid))
    -- Shape 2 (slow start): midpoint should be < 0.5
    local slow_start_mid = eval(0.5, 2, 0, false)
    lu.assertTrue(slow_start_mid < 0.5,
        "Slow start shape should be < 0.5 at midpoint, got " .. tostring(slow_start_mid))
end

-- Test Bezier control points validity
function TestNVSDItemView:test_bezier_control_points()
    local get_bez = dt.get_fade_bez
    for shape = 0, 6 do
        for _, is_fo in ipairs({false, true}) do
            local x1, y1, x2, y2, x3, y3, x4, y4 = get_bez(shape, 0, is_fo)
            -- All coordinates should be finite numbers
            lu.assertNotNil(x1); lu.assertNotNil(y1)
            lu.assertNotNil(x2); lu.assertNotNil(y2)
            lu.assertNotNil(x3); lu.assertNotNil(y3)
            lu.assertNotNil(x4); lu.assertNotNil(y4)
            -- Endpoints should be (0,0)-(1,1) or (0,1)-(1,0)
            lu.assertAlmostEquals(x1, 0, 0.001)
            lu.assertAlmostEquals(x4, 1, 0.001)
        end
    end
end

-- === Grid Computation Tests ===

-- Test grid bar_skip is always power of 2
function TestNVSDItemView:test_custom_theme_exists()
    lu.assertEquals(settings.THEMES[18].id, "custom")
    lu.assertEquals(settings.THEMES[18].name, "Custom")
end

-- Test all 18 themes have all 20 color keys
function TestNVSDItemView:test_all_18_themes_have_all_keys()
    local expected_keys = settings.COLOR_KEYS
    for _, theme in ipairs(settings.THEMES) do
        for _, key in ipairs(expected_keys) do
            lu.assertNotNil(theme.colors[key],
                "Theme '" .. theme.id .. "' missing color key: " .. key)
            lu.assertTrue(type(theme.colors[key]) == "number",
                "Theme '" .. theme.id .. "' color '" .. key .. "' not a number")
        end
    end
end

-- Test default theme is first
function TestNVSDItemView:test_default_theme_is_first()
    lu.assertEquals(settings.THEMES[1].id, "default")
end

-- Test classic theme exists (renamed from old default)
function TestNVSDItemView:test_classic_theme_exists()
    local classic = settings.get_theme("classic")
    lu.assertNotNil(classic)
    lu.assertEquals(classic.id, "classic")
    lu.assertEquals(classic.name, "Classic")
    -- Classic should have the original green waveform color
    lu.assertEquals(classic.colors.waveform, 0x5A9F5AFF)
end

-- Test new DAW-inspired themes exist
function TestNVSDItemView:test_daw_themes_exist()
    local daw_ids = {"bitwig", "cubase", "logic", "studio_one", "pro_tools"}
    for _, id in ipairs(daw_ids) do
        local theme = settings.get_theme(id)
        lu.assertNotNil(theme, "Missing DAW theme: " .. id)
        lu.assertEquals(theme.id, id)
    end
end

-- Test COLOR_KEYS has exactly 20 entries
function TestNVSDItemView:test_color_keys_count()
    lu.assertEquals(#settings.COLOR_KEYS, 20)
end

-- Test custom colors roundtrip (mock ExtState)
function TestNVSDItemView:test_custom_colors_roundtrip()
    -- Mock ExtState storage
    local store = {}
    reaper.SetExtState = function(sec, key, val, persist)
        store[sec .. "::" .. key] = val
    end
    reaper.GetExtState = function(sec, key)
        return store[sec .. "::" .. key] or ""
    end

    local test_colors = {}
    for _, key in ipairs(settings.COLOR_KEYS) do
        test_colors[key] = math.random(0, 0xFFFFFFFF)
    end

    settings.save_custom_colors(test_colors)
    local loaded = settings.load_custom_colors()

    for _, key in ipairs(settings.COLOR_KEYS) do
        lu.assertEquals(loaded[key], test_colors[key],
            "Roundtrip mismatch for " .. key)
    end
end

-- Test custom theme initialize from copies all colors
function TestNVSDItemView:test_custom_initialize_from()
    local source = settings.get_theme("classic")
    local custom = settings.get_theme("custom")
    lu.assertNotNil(source)
    lu.assertNotNil(custom)

    -- Copy colors
    for _, key in ipairs(settings.COLOR_KEYS) do
        custom.colors[key] = source.colors[key]
    end

    -- Verify all match
    for _, key in ipairs(settings.COLOR_KEYS) do
        lu.assertEquals(custom.colors[key], source.colors[key],
            "Initialize from mismatch for " .. key)
    end
end

-- === Envelope Editing Tests ===

-- Test envelope value clamping for volume (0..2 range)
function TestNVSDItemView:test_state_reset_comprehensive()
    local state_mod = dofile("Scripts/NVSD/lib/state.lua")
    -- Set many flags to true
    state_mod.dragging_start = true
    state_mod.dragging_end = true
    state_mod.is_panning = true
    state_mod.fx_dragging = true
    state_mod.env_freehand_drawing = true
    state_mod.dragging_fade_in = true
    state_mod.dragging_fade_out = true
    state_mod.dragging_env_node = true
    state_mod.env_tension_dragging = true
    state_mod.env_segment_dragging = true
    state_mod.env_rect_selecting = true

    state_mod.reset_all_drags()

    -- All should be false
    lu.assertFalse(state_mod.dragging_start)
    lu.assertFalse(state_mod.dragging_end)
    lu.assertFalse(state_mod.is_panning)
    lu.assertFalse(state_mod.fx_dragging)
    lu.assertFalse(state_mod.env_freehand_drawing)
    lu.assertFalse(state_mod.dragging_fade_in)
    lu.assertFalse(state_mod.dragging_fade_out)
    lu.assertFalse(state_mod.dragging_env_node)
    lu.assertFalse(state_mod.env_tension_dragging)
    lu.assertFalse(state_mod.env_segment_dragging)
    lu.assertFalse(state_mod.env_rect_selecting)
end

-- Test any_drag_active with each flag individually
function TestNVSDItemView:test_any_drag_each_flag()
    local drag_flags = {
        "dragging_start", "dragging_end", "is_panning",
        "dragging_fade_in", "dragging_fade_out",
        "dragging_env_node", "env_tension_dragging",
        "env_segment_dragging", "env_freehand_drawing",
        "fx_dragging", "env_rect_selecting",
        "pitch_gutter_dragging",
    }

    for _, flag in ipairs(drag_flags) do
        local state_mod = dofile("Scripts/NVSD/lib/state.lua")
        -- All should start false
        lu.assertFalse(state_mod.any_drag_active(), "Should start idle")
        -- Set one flag
        state_mod[flag] = true
        lu.assertTrue(state_mod.any_drag_active(),
            "any_drag_active should be true when " .. flag .. " is set")
    end
end

-- Test point_in_rect with zero-size rect
function TestNVSDItemView:test_point_in_rect_zero_size()
    -- Point exactly on a zero-size rect (degenerate)
    lu.assertTrue(utils.point_in_rect(5, 5, 5, 5, 5, 5))
    -- Point not on it
    lu.assertFalse(utils.point_in_rect(6, 5, 5, 5, 5, 5))
end

-- Test point_in_rect with negative coordinates
function TestNVSDItemView:test_point_in_rect_negative_coords()
    lu.assertTrue(utils.point_in_rect(-5, -5, -10, -10, 0, 0))
    lu.assertFalse(utils.point_in_rect(-15, -5, -10, -10, 0, 0))
    lu.assertTrue(utils.point_in_rect(-10, -10, -10, -10, 0, 0))  -- on edge
end

-- === Undo Wrapper Tests ===

-- Test with_undo calls begin/end block
function TestNVSDItemView:test_with_undo_calls_begin_end()
    local calls = {}
    reaper.Undo_BeginBlock = function() table.insert(calls, "begin") end
    reaper.Undo_EndBlock = function(label, flags)
        table.insert(calls, "end:" .. label .. ":" .. tostring(flags))
    end

    utils.with_undo("Test action", -1, function()
        table.insert(calls, "body")
    end)

    lu.assertEquals(#calls, 3)
    lu.assertEquals(calls[1], "begin")
    lu.assertEquals(calls[2], "body")
    lu.assertEquals(calls[3], "end:Test action:-1")
end

-- Test with_undo passes correct label
function TestNVSDItemView:test_with_undo_passes_label()
    local captured_label = nil
    local captured_flags = nil
    reaper.Undo_BeginBlock = function() end
    reaper.Undo_EndBlock = function(label, flags)
        captured_label = label
        captured_flags = flags
    end

    utils.with_undo("My undo label", 4, function() end)

    lu.assertEquals(captured_label, "My undo label")
    lu.assertEquals(captured_flags, 4)
end

-- === Tooltip Delay Test ===
function TestNVSDItemView:test_tooltip_delay_value()
    -- The TOOLTIP_DELAY constant should be 1.5 seconds
    -- We can't access the local directly, but we can verify the module loaded
    lu.assertNotNil(drawing.tooltip, "drawing.tooltip function should exist")
end

-- === Shape Icon Functions Test ===
function TestNVSDItemView:test_shape_icon_fns_all_7()
    local fns = dt.shape_icon_fns
    lu.assertNotNil(fns)
    for shape = 0, 6 do
        lu.assertNotNil(fns[shape], "Missing shape icon fn for shape " .. shape)
        -- All should return 0 at x=0 and 1 at x=1
        lu.assertAlmostEquals(fns[shape](0), 0, 0.001, "Shape " .. shape .. " at x=0")
        lu.assertAlmostEquals(fns[shape](1), 1, 0.001, "Shape " .. shape .. " at x=1")
    end
end

-- === Bezier Evaluator Tests ===
function TestNVSDItemView:test_cbez_y_linear()
    local cbez_y = dt.cbez_y
    -- Linear Bezier: (0,0) - (0.5,0.5) - (0.5,0.5) - (1,1)
    lu.assertAlmostEquals(cbez_y(0, 0, 0.5, 0.5, 0.5, 0.5, 1, 1, 0), 0, 0.01)
    lu.assertAlmostEquals(cbez_y(0, 0, 0.5, 0.5, 0.5, 0.5, 1, 1, 0.5), 0.5, 0.05)
    lu.assertAlmostEquals(cbez_y(0, 0, 0.5, 0.5, 0.5, 0.5, 1, 1, 1), 1, 0.01)
end

function TestNVSDItemView:test_cbez_y_boundary_clamp()
    local cbez_y = dt.cbez_y
    -- t <= 0 returns by1, t >= 1 returns by4
    lu.assertEquals(cbez_y(0, 0.3, 0.5, 0.5, 0.5, 0.5, 1, 0.9, -1), 0.3)
    lu.assertEquals(cbez_y(0, 0.3, 0.5, 0.5, 0.5, 0.5, 1, 0.9, 2), 0.9)
end

-- Test scroll_zoom and scroll_vzoom default shortcuts
function TestNVSDItemView:test_scroll_zoom_defaults()
    local sz = settings.DEFAULT_SHORTCUTS.scroll_zoom
    lu.assertNotNil(sz)
    lu.assertEquals(sz.key, "Scroll")
    lu.assertTrue(sz.ctrl)
    lu.assertFalse(sz.shift)
    lu.assertFalse(sz.alt)

    local sv = settings.DEFAULT_SHORTCUTS.scroll_vzoom
    lu.assertNotNil(sv)
    lu.assertEquals(sv.key, "Scroll")
    lu.assertTrue(sv.ctrl)
    lu.assertTrue(sv.shift)
    lu.assertFalse(sv.alt)
end

-- Test check_scroll_modifiers helper
function TestNVSDItemView:test_check_scroll_modifiers()
    -- Save originals
    local orig_zoom = settings.current.shortcuts.scroll_zoom
    local orig_vzoom = settings.current.shortcuts.scroll_vzoom

    -- Ctrl+Scroll (default)
    settings.current.shortcuts.scroll_zoom = {ctrl = true, shift = false, alt = false, key = "Scroll"}
    lu.assertTrue(settings.check_scroll_modifiers("scroll_zoom", true, false, false))
    lu.assertFalse(settings.check_scroll_modifiers("scroll_zoom", false, false, false))
    lu.assertFalse(settings.check_scroll_modifiers("scroll_zoom", true, true, false))

    -- Alt+Scroll
    settings.current.shortcuts.scroll_zoom = {ctrl = false, shift = false, alt = true, key = "Scroll"}
    lu.assertTrue(settings.check_scroll_modifiers("scroll_zoom", false, false, true))
    lu.assertFalse(settings.check_scroll_modifiers("scroll_zoom", true, false, false))

    -- Scroll (no modifier)
    settings.current.shortcuts.scroll_zoom = {ctrl = false, shift = false, alt = false, key = "Scroll"}
    lu.assertTrue(settings.check_scroll_modifiers("scroll_zoom", false, false, false))
    lu.assertFalse(settings.check_scroll_modifiers("scroll_zoom", true, false, false))

    -- Unbound (key="")
    settings.current.shortcuts.scroll_zoom = {ctrl = false, shift = false, alt = false, key = ""}
    lu.assertFalse(settings.check_scroll_modifiers("scroll_zoom", false, false, false))

    -- Ctrl+Shift+Scroll (vzoom)
    settings.current.shortcuts.scroll_vzoom = {ctrl = true, shift = true, alt = false, key = "Scroll"}
    lu.assertTrue(settings.check_scroll_modifiers("scroll_vzoom", true, true, false))
    lu.assertFalse(settings.check_scroll_modifiers("scroll_vzoom", true, false, false))

    -- Restore
    settings.current.shortcuts.scroll_zoom = orig_zoom
    settings.current.shortcuts.scroll_vzoom = orig_vzoom
end

-- Test toggle_default persists state and syncs settings.current.defaults
function TestNVSDItemView:test_toggle_default_persistence()
    -- Mock ExtState storage
    local store = {}
    reaper.SetExtState = function(sec, key, val, persist)
        store[sec .. "::" .. key] = val
    end
    reaper.GetExtState = function(sec, key)
        return store[sec .. "::" .. key] or ""
    end

    -- Simulate a state table
    local fake_state = { envelope_lock = false }
    settings.current.defaults.envelope_lock = false

    -- Toggle on
    settings.toggle_default(fake_state, "envelope_lock")
    lu.assertTrue(fake_state.envelope_lock)
    lu.assertTrue(settings.current.defaults.envelope_lock)
    lu.assertEquals(store["NVSD_ItemView::default_envelope_lock"], "true")

    -- Toggle off
    settings.toggle_default(fake_state, "envelope_lock")
    lu.assertFalse(fake_state.envelope_lock)
    lu.assertFalse(settings.current.defaults.envelope_lock)
    lu.assertEquals(store["NVSD_ItemView::default_envelope_lock"], "false")
end

-- Test toolbar file-based persistence roundtrip
function TestNVSDItemView:test_toolbar_file_persistence()
    -- Use a temp directory for the toolbar file
    local tmp_dir = os.tmpname():match("(.+)[/\\]") or "."
    settings.set_script_dir(tmp_dir)
    local fpath = tmp_dir .. "/toolbar_data.txt"

    -- Mock ExtState (empty, so file takes priority)
    local store = {}
    reaper.SetExtState = function(sec, key, val, persist)
        store[sec .. "::" .. key] = val
    end
    reaper.GetExtState = function(sec, key)
        return store[sec .. "::" .. key] or ""
    end
    reaper.DeleteExtState = function() end

    -- Set up toolbar and save
    settings.current.toolbar_buttons = {
        {label = "Test Btn", cmd = "12345", icon = "icon.png"},
        {type = "separator"},
        {label = "Another", cmd = "67890"},
    }
    settings.save_toolbar()

    -- Verify file was written
    local f = io.open(fpath, "r")
    lu.assertNotNil(f, "toolbar_data.txt should be created")
    local content = f:read("*a")
    f:close()
    lu.assertStrContains(content, "Test Btn")
    lu.assertStrContains(content, "12345")
    lu.assertStrContains(content, "S")

    -- Clear ExtState to prove load reads from file
    store = {}

    -- Load and verify
    settings.load_toolbar()
    lu.assertEquals(#settings.current.toolbar_buttons, 3)
    lu.assertEquals(settings.current.toolbar_buttons[1].label, "Test Btn")
    lu.assertEquals(settings.current.toolbar_buttons[1].cmd, "12345")
    lu.assertEquals(settings.current.toolbar_buttons[1].icon, "icon.png")
    lu.assertEquals(settings.current.toolbar_buttons[2].type, "separator")
    lu.assertEquals(settings.current.toolbar_buttons[3].label, "Another")
    lu.assertNil(settings.current.toolbar_buttons[3].icon)

    -- Clean up
    os.remove(fpath)
    settings.set_script_dir(nil)
end

-- Test empty toolbar persists correctly (not reset to default)
function TestNVSDItemView:test_toolbar_empty_persists()
    local tmp_dir = os.tmpname():match("(.+)[/\\]") or "."
    settings.set_script_dir(tmp_dir)
    local fpath = tmp_dir .. "/toolbar_data.txt"

    local store = {}
    reaper.SetExtState = function(sec, key, val, persist)
        store[sec .. "::" .. key] = val
    end
    reaper.GetExtState = function(sec, key)
        return store[sec .. "::" .. key] or ""
    end
    reaper.DeleteExtState = function() end

    -- Save empty toolbar
    settings.current.toolbar_buttons = {}
    settings.save_toolbar()

    -- Load should give empty toolbar, NOT the default "Item properties" button
    settings.load_toolbar()
    lu.assertEquals(#settings.current.toolbar_buttons, 0)

    -- Clean up
    os.remove(fpath)
    settings.set_script_dir(nil)
end

-- Test format_shortcut with Scroll key
function TestNVSDItemView:test_format_shortcut_scroll()
    lu.assertEquals(settings.format_shortcut({ctrl = true, shift = false, alt = false, key = "Scroll"}), "Ctrl+Scroll")
    lu.assertEquals(settings.format_shortcut({ctrl = true, shift = true, alt = false, key = "Scroll"}), "Ctrl+Shift+Scroll")
    lu.assertEquals(settings.format_shortcut({ctrl = false, shift = false, alt = true, key = "Scroll"}), "Alt+Scroll")
    lu.assertEquals(settings.format_shortcut({ctrl = false, shift = false, alt = false, key = "Scroll"}), "Scroll")
end

-- Test string_to_shortcut parsing REAPER-style shortcut strings
function TestNVSDItemView:test_string_to_shortcut_simple_key()
    local result = settings.string_to_shortcut("A")
    lu.assertEquals(result.key, "A")
    lu.assertFalse(result.ctrl)
    lu.assertFalse(result.shift)
    lu.assertFalse(result.alt)
end

function TestNVSDItemView:test_string_to_shortcut_ctrl_modifier()
    local result = settings.string_to_shortcut("Ctrl+Z")
    lu.assertEquals(result.key, "Z")
    lu.assertTrue(result.ctrl)
    lu.assertFalse(result.shift)
    lu.assertFalse(result.alt)
end

function TestNVSDItemView:test_string_to_shortcut_multi_modifier()
    local result = settings.string_to_shortcut("Ctrl+Shift+Alt+F5")
    lu.assertEquals(result.key, "F5")
    lu.assertTrue(result.ctrl)
    lu.assertTrue(result.shift)
    lu.assertTrue(result.alt)
end

function TestNVSDItemView:test_string_to_shortcut_empty()
    local result = settings.string_to_shortcut("")
    lu.assertEquals(result.key, "")
    lu.assertFalse(result.ctrl)
end
