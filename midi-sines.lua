-- MIDI SINES
-- 16-band MIDI drone/rhythm machine
-- Inspired by Sines (@aidanreilly)
--
-- Replaces FM drones with MIDI voices:
--   Bass -> Sub 37 (mono, ch 7)
--   Chords -> OB-6 (6-voice, ch 4)
--   Lead -> Pro 3 (mono, ch 3)
--   Drums -> Digitakt (ch 15)
--
-- Progression sequencer changes root note,
-- all voices follow, staying in key.
-- 3 synths -> 3 separate amps
--
-- E1: page | K2: play/stop
-- BANDS: E2 select, E3 volume/param, K3 cycle edit
-- PROG: E2 navigate, E3 adjust, K3 add step
--
-- v0.1 @clf

local MusicUtil = require "musicutil"
local Voices = include("midi-sines/lib/voices")
local MidiMix = include("midi-sines/lib/midimix")

-- ===== CONSTANTS =====

local NUM_BANDS = 16
local PAGES = {"BANDS", "PROG", "CONFIG"}
local ROLES = {"bass", "chord", "lead", "kick", "snare", "hat"}
local ROLE_SHORT = {bass="B", chord="C", lead="L", kick="K", snare="S", hat="H"}
local ROLE_COLORS = {bass=12, chord=15, lead=10, kick=6, snare=5, hat=4}
local NUMERALS = {"I", "ii", "iii", "IV", "V", "vi", "vii"}
local EDIT_NAMES = {"VOL", "ROLE", "DEG", "OCT", "RATE"}
local NOTE_NAMES = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

-- Default band configs
local DEFAULTS = {
  {role="bass",  degree=1, octave=-1, rate=0},
  {role="bass",  degree=5, octave=-1, rate=0},
  {role="chord", degree=1, octave=0,  rate=0},
  {role="chord", degree=3, octave=0,  rate=0},
  {role="chord", degree=5, octave=0,  rate=0},
  {role="chord", degree=7, octave=0,  rate=0},
  {role="chord", degree=2, octave=1,  rate=0},
  {role="chord", degree=4, octave=1,  rate=0},
  {role="lead",  degree=1, octave=1,  rate=0},
  {role="lead",  degree=5, octave=1,  rate=0},
  {role="lead",  degree=3, octave=2,  rate=0},
  {role="kick",  degree=1, octave=0,  rate=4},
  {role="kick",  degree=1, octave=0,  rate=8},
  {role="snare", degree=1, octave=0,  rate=8},
  {role="hat",   degree=1, octave=0,  rate=2},
  {role="hat",   degree=1, octave=0,  rate=1},
}

-- ===== STATE =====

local vm = nil            -- VoiceManager
local mm = nil            -- MidiMix controller
local bands = {}          -- 16 bands: {role, degree, octave, rate, vol}
local playing = false
local main_clock = nil
local redraw_clock = nil
local sixteenth = 0       -- 16th note counter

-- Progression
local prog = {
  steps = {1, 6, 4, 5},  -- I vi IV V
  position = 1,
  beats_per_step = 4,
}

-- UI
local page = 1
local cursor = 1          -- selected band (1-16)
local edit_field = 1      -- 1=vol, 2=role, 3=degree, 4=octave, 5=rate
local prog_cursor = 1     -- selected prog field
local prog_step_cursor = 1
local flash = {}          -- per-band note flash

-- ===== HELPERS =====

-- Get MIDI device name by vport number (1-16)
-- midi.connect(n) uses vports, NOT device IDs
function get_midi_device_name(port)
  -- vports is the correct lookup for midi.connect() port numbers
  if midi.vports and midi.vports[port] then
    local vp = midi.vports[port]
    if vp.name and vp.name ~= "none" and vp.name ~= "" then
      return vp.name
    end
  end
  return "none"
end

-- Config page state
local config_cursor = 1  -- 1=MIDI out, 2=MIDIMIX, 3-6=channels
local CONFIG_FIELDS = {"MIDI Out", "MIDIMIX", "Bass Ch", "Chord Ch", "Lead Ch", "Drum Ch"}

-- ===== INIT =====

function init()
  -- Build bands from defaults
  for i = 1, NUM_BANDS do
    local d = DEFAULTS[i]
    bands[i] = {
      role = d.role,
      degree = d.degree,
      octave = d.octave,
      rate = d.rate,
      vol = 0,
    }
    flash[i] = 0
  end

  -- Voice manager
  vm = Voices.new()

  -- Params
  params:add_separator("MIDI SINES")

  params:add_number("midi_device", "MIDI Device", 1, 16, 1)
  params:set_action("midi_device", function(val)
    vm:connect(val)
  end)

  params:add_number("bass_ch", "Bass Ch", 1, 16, 7)
  params:set_action("bass_ch", function(val) vm:set_primary_ch("bass", val) end)

  params:add_number("chord_ch", "Chord Ch", 1, 16, 4)
  params:set_action("chord_ch", function(val) vm:set_primary_ch("chord", val) end)

  params:add_number("lead_ch", "Lead Ch", 1, 16, 3)
  params:set_action("lead_ch", function(val) vm:set_primary_ch("lead", val) end)

  params:add_number("drum_ch", "Drum Ch", 1, 16, 15)
  params:set_action("drum_ch", function(val) vm.drum_channels[1] = val end)

  params:add_number("bass_voices", "Bass Voices", 1, 4, 1)
  params:set_action("bass_voices", function(val) vm.pools.bass.max = val end)

  params:add_number("chord_voices", "Chord Voices", 1, 8, 6)
  params:set_action("chord_voices", function(val) vm.pools.chord.max = val end)

  params:add_number("lead_voices", "Lead Voices", 1, 4, 1)
  params:set_action("lead_voices", function(val) vm.pools.lead.max = val end)

  params:add_option("key", "Key", NOTE_NAMES, 1)
  params:set_action("key", function(val)
    vm:set_key(val)
  end)

  params:add_option("scale", "Scale",
    (function()
      local names = {}
      for i = 1, #MusicUtil.SCALES do
        table.insert(names, MusicUtil.SCALES[i].name)
      end
      return names
    end)(), 1)
  params:set_action("scale", function(val)
    vm:set_scale(val)
  end)

  params:add_option("quantize", "Quantize", {"Scale", "Chromatic"}, 1)
  params:set_action("quantize", function(val)
    vm.quantize = (val == 1)
  end)

  params:add_number("beats_per_step", "Beats/Step", 1, 16, 4)
  params:set_action("beats_per_step", function(val)
    prog.beats_per_step = val
  end)

  -- Drum note params
  params:add_number("kick_note", "Kick Note", 0, 127, 0)
  params:set_action("kick_note", function(val) vm.drum_notes.kick = val end)

  params:add_number("snare_note", "Snare Note", 0, 127, 1)
  params:set_action("snare_note", function(val) vm.drum_notes.snare = val end)

  params:add_number("hat_note", "Hat Note", 0, 127, 2)
  params:set_action("hat_note", function(val) vm.drum_notes.hat = val end)

  -- MIDIMIX params
  params:add_separator("MIDIMIX")

  params:add_number("midimix_device", "MIDIMIX Device", 1, 16, 1)
  params:set_action("midimix_device", function(val)
    mm:connect(val)
    mm:update_leds(bands)
    print("MIDIMIX -> device " .. val .. ": " .. get_midi_device_name(val))
  end)

  -- Scan and print all MIDI devices
  print("--- MIDI DEVICES ---")
  local midimix_port = nil
  local all_ports = {}
  for i = 1, 16 do
    local name = get_midi_device_name(i)
    if name ~= "none" then
      print("  " .. i .. ": " .. name)
      table.insert(all_ports, {port = i, name = name})
      -- Auto-detect MIDIMIX
      local lower = string.lower(name)
      if string.find(lower, "midi mix") or
         string.find(lower, "midimix") or
         string.find(lower, "akai") then
        midimix_port = i
      end
    end
  end
  print("--------------------")

  -- Find MIDI out: first device that is NOT the MIDIMIX
  local midi_out_port = nil
  for _, d in ipairs(all_ports) do
    if d.port ~= midimix_port then
      midi_out_port = d.port
      break
    end
  end
  -- Fallback: if only one device and it's the MIDIMIX, use port 1 anyway
  if not midi_out_port then midi_out_port = 1 end

  -- Connect MIDI out
  vm:connect(midi_out_port)
  params:set("midi_device", midi_out_port, true)
  print("MIDI OUT -> device " .. midi_out_port .. ": " .. get_midi_device_name(midi_out_port))

  -- Connect MIDIMIX
  mm = MidiMix.new()
  setup_midimix()
  local mm_port = midimix_port or 2  -- default to 2 if not found
  mm:connect(mm_port)
  params:set("midimix_device", mm_port, true)
  if midimix_port then
    print("MIDIMIX auto-detected on device " .. mm_port .. ": " .. get_midi_device_name(mm_port))
  else
    print("MIDIMIX not auto-detected. Go to CONFIG page (E1) and set device with E3.")
  end

  -- Redraw clock
  redraw_clock = clock.run(function()
    while true do
      clock.sleep(1/12)
      decay_flash()
      redraw()
    end
  end)

  print("MIDI SINES loaded")
  print("MIDIMIX: faders=volume, knobs=degree/octave/rate")
  print("MIDIMIX: mute=toggle, solo=cycle role, bank=1-8/9-16")
end

-- ===== MIDIMIX CALLBACKS =====

function setup_midimix()
  -- Faders: band volume
  mm.on_volume = function(band_idx, vol)
    if band_idx >= 1 and band_idx <= NUM_BANDS then
      set_band_vol(band_idx, vol)
      cursor = band_idx  -- follow selection
      mm:update_leds(bands)
    end
  end

  -- Knob row 1: degree
  mm.on_degree = function(band_idx, degree)
    if band_idx >= 1 and band_idx <= NUM_BANDS then
      bands[band_idx].degree = degree
      cursor = band_idx
      if bands[band_idx].vol > 0 and is_melodic(bands[band_idx].role) then
        if vm:has_voice(band_idx, bands[band_idx].role) then
          activate_band(band_idx)
        end
      end
    end
  end

  -- Knob row 2: program change (sent to the band's synth channel)
  mm.on_pc = function(band_idx, program)
    if band_idx >= 1 and band_idx <= NUM_BANDS then
      local b = bands[band_idx]
      vm:send_pc(b.role, program)
      cursor = band_idx
      print("PC " .. program .. " -> " .. b.role)
    end
  end

  -- Knob row 3: rate
  mm.on_rate = function(band_idx, rate)
    if band_idx >= 1 and band_idx <= NUM_BANDS then
      bands[band_idx].rate = rate
      cursor = band_idx
      -- If going back to drone, retrigger
      if rate == 0 and bands[band_idx].vol > 0 and is_melodic(bands[band_idx].role) then
        if vm:has_voice(band_idx, bands[band_idx].role) then
          activate_band(band_idx)
        end
      end
    end
  end

  -- Mute buttons: toggle band on/off
  mm.on_mute_toggle = function(band_idx)
    if band_idx >= 1 and band_idx <= NUM_BANDS then
      local b = bands[band_idx]
      if b.vol > 0 then
        -- Mute: save volume, set to 0
        mm.saved_vol[band_idx] = b.vol
        set_band_vol(band_idx, 0)
      else
        -- Unmute: restore saved volume
        local restore = mm.saved_vol[band_idx]
        if restore <= 0 then restore = 0.5 end
        set_band_vol(band_idx, restore)
      end
      cursor = band_idx
      mm:update_leds(bands)
    end
  end

  -- Solo buttons: cycle role
  mm.on_role_cycle = function(band_idx)
    if band_idx >= 1 and band_idx <= NUM_BANDS then
      local b = bands[band_idx]
      local idx = 1
      for i, r in ipairs(ROLES) do
        if r == b.role then idx = i; break end
      end
      local old_role = b.role
      idx = (idx % #ROLES) + 1
      local new_role = ROLES[idx]
      if b.vol > 0 then deactivate_band(band_idx) end
      b.role = new_role
      if b.vol > 0 and is_melodic(new_role) then
        activate_band(band_idx)
      end
      cursor = band_idx
    end
  end

  -- Master fader: beats per step
  mm.on_beats = function(beats)
    prog.beats_per_step = beats
    params:set("beats_per_step", beats)
  end

  -- Bank switch
  mm.on_bank = function(bank)
    -- Update screen cursor to show the active bank
    if bank == 0 then
      cursor = util.clamp(cursor, 1, 8)
    else
      cursor = util.clamp(cursor, 9, 16)
    end
    mm:update_leds(bands)
  end

  -- Rec arm buttons: play/stop toggle per band
  -- (using as a secondary function: start/stop the clock)
  mm.on_rec = function(band_idx)
    -- Any rec arm button toggles play/stop
    if playing then
      stop_playing()
    else
      start_playing()
    end
    mm:update_leds(bands)
  end

  -- SEND ALL button (above master fader) = PANIC
  mm.on_panic = function()
    print("PANIC! All notes off")
    stop_playing()
    -- Zero all band volumes
    for i = 1, NUM_BANDS do
      bands[i].vol = 0
    end
    vm:all_off()
    mm:update_leds(bands)
  end
end

-- ===== FLASH =====

function decay_flash()
  for i = 1, NUM_BANDS do
    if flash[i] > 0 then flash[i] = flash[i] - 1 end
  end
end

-- ===== CLOCK =====

function is_drum(role)
  return role == "kick" or role == "snare" or role == "hat"
end

function is_melodic(role)
  return role == "bass" or role == "chord" or role == "lead"
end

function get_chord_root()
  return prog.steps[prog.position] or 1
end

function activate_band(i)
  local b = bands[i]
  if is_melodic(b.role) then
    vm:activate_melodic(i, bands, get_chord_root())
    flash[i] = 4
  end
end

function deactivate_band(i)
  local b = bands[i]
  if is_melodic(b.role) then
    vm:deactivate(i, b.role)
  end
end

-- Set band volume with voice management
function set_band_vol(i, vol)
  local b = bands[i]
  local old_vol = b.vol
  b.vol = vol

  if is_melodic(b.role) then
    if vol > 0 and old_vol == 0 then
      -- Turning on: acquire voice
      activate_band(i)
    elseif vol == 0 and old_vol > 0 then
      -- Turning off: release voice
      deactivate_band(i)
    elseif vol > 0 then
      -- Volume changed: update velocity if we have a voice
      if vm:has_voice(i, b.role) then
        activate_band(i)  -- retriggers with new velocity
      else
        -- Try to steal now that we might be louder
        activate_band(i)
      end
    end
  end
  -- Drums handled by the clock
end

function start_playing()
  if playing then return end
  playing = true
  sixteenth = 0
  prog.position = 1

  -- Activate all bands that have volume > 0
  for i = 1, NUM_BANDS do
    if bands[i].vol > 0 and is_melodic(bands[i].role) then
      activate_band(i)
    end
  end

  main_clock = clock.run(function()
    while playing do
      sixteenth = sixteenth + 1

      -- === DRUMS ===
      for i = 1, NUM_BANDS do
        local b = bands[i]
        if b.vol > 0 and is_drum(b.role) and b.rate > 0 then
          if (sixteenth - 1) % b.rate == 0 then
            local vel = math.floor(b.vol * 127)
            vm:trigger_drum(b.role, vel)
            flash[i] = 3
            -- Schedule note off
            clock.run(function()
              clock.sleep(0.05)
              vm:release_drum(b.role)
            end)
          end
        end
      end

      -- === MELODIC PULSE ===
      for i = 1, NUM_BANDS do
        local b = bands[i]
        if b.vol > 0 and is_melodic(b.role) and b.rate > 0 then
          if vm:has_voice(i, b.role) then
            if (sixteenth - 1) % b.rate == 0 then
              -- Note on
              activate_band(i)
            elseif (sixteenth - 1) % b.rate == math.floor(b.rate / 2) then
              -- Note off (half-way through cycle)
              vm:release(i)
            end
          end
        end
      end

      -- === PROGRESSION ===
      local step_sixteenths = prog.beats_per_step * 4
      if sixteenth % step_sixteenths == 0 then
        prog.position = (prog.position % #prog.steps) + 1
        vm:retrigger_all(bands, get_chord_root())
      end

      clock.sync(1/4)  -- sync to 16th note
    end
  end)
end

function stop_playing()
  playing = false
  if main_clock then
    clock.cancel(main_clock)
    main_clock = nil
  end
  vm:all_off()
end

-- ===== DRAWING =====

function redraw()
  screen.clear()
  screen.aa(0)
  screen.font_face(1)
  screen.font_size(8)

  -- Page header
  screen.level(3)
  screen.move(0, 6)
  screen.text(PAGES[page])

  -- Page dots
  for i = 1, #PAGES do
    screen.level(i == page and 15 or 2)
    screen.rect(108 + (i - 1) * 7, 1, 4, 4)
    screen.fill()
  end

  if page == 1 then
    draw_bands()
  elseif page == 2 then
    draw_prog()
  elseif page == 3 then
    draw_config()
  end

  screen.update()
end

function draw_bands()
  local bar_w = 6
  local bar_gap = 2
  local bar_max_h = 32
  local bar_y = 42  -- bottom of bars

  -- Draw 16 bars
  for i = 1, NUM_BANDS do
    local b = bands[i]
    local x = (i - 1) * (bar_w + bar_gap)
    local h = math.floor(b.vol * bar_max_h)
    local is_selected = (i == cursor)

    -- Bar background
    screen.level(is_selected and 3 or 1)
    screen.rect(x, bar_y - bar_max_h, bar_w, bar_max_h)
    screen.fill()

    -- Bar fill
    if h > 0 then
      local lvl = ROLE_COLORS[b.role] or 8
      if flash[i] > 0 then lvl = 15 end
      screen.level(lvl)
      screen.rect(x, bar_y - h, bar_w, h)
      screen.fill()
    end

    -- Selection bracket
    if is_selected then
      screen.level(15)
      screen.rect(x - 1, bar_y - bar_max_h - 2, bar_w + 2, bar_max_h + 4)
      screen.stroke()
    end

    -- Role label below bar
    screen.level(is_selected and 15 or 4)
    screen.move(x + 1, bar_y + 8)
    screen.text(ROLE_SHORT[b.role] or "?")
  end

  -- Bottom info line
  local chord_deg = get_chord_root()
  local numeral = NUMERALS[chord_deg] or tostring(chord_deg)
  local key_name = NOTE_NAMES[vm.key_idx] or "C"
  local scale_name = MusicUtil.SCALES[vm.scale_idx].name

  screen.level(8)
  screen.move(0, 58)
  screen.text(key_name .. " " .. scale_name:sub(1, 3))

  screen.level(playing and 15 or 5)
  screen.move(42, 58)
  screen.text(numeral)

  -- Show what E3 controls
  screen.level(6)
  screen.move(58, 58)
  screen.text("E3:" .. EDIT_NAMES[edit_field])

  -- Play indicator
  screen.level(playing and 15 or 3)
  screen.move(108, 58)
  screen.text(playing and ">>>" or "---")

  -- Voice status line + bank indicator
  screen.level(3)
  screen.move(0, 64)
  local bank_str = mm and ("[" .. (mm.bank == 0 and "1-8" or "9-16") .. "]") or ""
  screen.text("B:" .. vm:pool_status("bass")
    .. " C:" .. vm:pool_status("chord")
    .. " L:" .. vm:pool_status("lead")
    .. " " .. bank_str)
end

function draw_prog()
  -- Chord sequence visualization
  local num_steps = #prog.steps
  local step_w = math.min(24, math.floor(120 / math.max(num_steps, 1)))

  for i = 1, num_steps do
    local x = (i - 1) * step_w + 4
    local deg = prog.steps[i]
    local numeral = NUMERALS[deg] or tostring(deg)
    local is_current = (i == prog.position and playing)
    local is_selected = (i == prog_step_cursor and prog_cursor == 1)

    -- Box
    screen.level(is_current and 15 or (is_selected and 8 or 2))
    screen.rect(x, 10, step_w - 2, 16)
    if is_current then
      screen.fill()
      screen.level(0)
    else
      screen.stroke()
      screen.level(is_selected and 15 or 6)
    end

    -- Numeral
    screen.move(x + math.floor(step_w / 2) - 2, 22)
    screen.text(numeral)
  end

  -- Settings below
  local fields = {
    {"Steps", "E2/E3: select/change step"},
    {"Beats/Step", tostring(prog.beats_per_step)},
    {"Key", NOTE_NAMES[vm.key_idx]},
    {"Scale", MusicUtil.SCALES[vm.scale_idx].name:sub(1, 12)},
    {"Quantize", vm.quantize and "Scale" or "Chromatic"},
  }

  for i = 2, #fields do
    local y = 24 + (i - 1) * 9
    local selected = (prog_cursor == i)
    screen.level(selected and 15 or 5)
    screen.move(0, y)
    screen.text(fields[i][1] .. ": " .. fields[i][2])
  end

  -- Help
  screen.level(3)
  screen.move(0, 64)
  screen.text("K3:add step  K2+K3:del last")
end

function draw_config()
  -- MIDI device selection
  local out_port = params:get("midi_device")
  local mm_port = params:get("midimix_device")
  local out_name = get_midi_device_name(out_port)
  local mm_name = get_midi_device_name(mm_port)

  local rows = {
    {"MIDI Out:", out_port .. ": " .. out_name:sub(1, 16)},
    {"MIDIMIX:",  mm_port .. ": " .. mm_name:sub(1, 16)},
    {"Bass:",     "ch " .. vm:channels_str("bass") .. "  max " .. vm.pools.bass.max .. "  " .. vm:pool_status("bass")},
    {"Chord:",    "ch " .. vm:channels_str("chord") .. "  max " .. vm.pools.chord.max .. "  " .. vm:pool_status("chord")},
    {"Lead:",     "ch " .. vm:channels_str("lead") .. "  max " .. vm.pools.lead.max .. "  " .. vm:pool_status("lead")},
    {"Drum:",     "ch " .. vm:drum_channels_str() .. "  K:" .. vm.drum_notes.kick .. " S:" .. vm.drum_notes.snare .. " H:" .. vm.drum_notes.hat},
  }

  for i, row in ipairs(rows) do
    local y = 4 + i * 9
    local selected = (config_cursor == i)
    screen.level(selected and 15 or 5)
    screen.move(0, y)
    screen.text(row[1])
    screen.level(selected and 12 or 4)
    screen.move(48, y)
    screen.text(row[2])
  end

  -- Help
  screen.level(3)
  screen.move(0, 64)
  screen.text("E3:ch  K3:+ch  K1+K3:-ch")
end

-- ===== INPUT =====

function enc(n, d)
  if n == 1 then
    page = util.clamp(page + d, 1, #PAGES)

  elseif page == 1 then
    enc_bands(n, d)
  elseif page == 2 then
    enc_prog(n, d)
  elseif page == 3 then
    enc_config(n, d)
  end
  redraw()
end

function enc_bands(n, d)
  if n == 2 then
    cursor = util.clamp(cursor + d, 1, NUM_BANDS)
  elseif n == 3 then
    local b = bands[cursor]
    if edit_field == 1 then
      -- Volume
      local new_vol = util.clamp(b.vol + d * 0.05, 0, 1)
      set_band_vol(cursor, new_vol)
    elseif edit_field == 2 then
      -- Role
      local idx = 1
      for i, r in ipairs(ROLES) do
        if r == b.role then idx = i; break end
      end
      local old_role = b.role
      idx = util.clamp(idx + d, 1, #ROLES)
      local new_role = ROLES[idx]
      if new_role ~= old_role then
        -- Deactivate from old pool, switch role
        if b.vol > 0 then deactivate_band(cursor) end
        b.role = new_role
        if b.vol > 0 and is_melodic(new_role) then
          activate_band(cursor)
        end
      end
    elseif edit_field == 3 then
      -- Degree
      b.degree = util.clamp(b.degree + d, 1, 7)
      if b.vol > 0 and is_melodic(b.role) and vm:has_voice(cursor, b.role) then
        activate_band(cursor)
      end
    elseif edit_field == 4 then
      -- Octave
      b.octave = util.clamp(b.octave + d, -3, 3)
      if b.vol > 0 and is_melodic(b.role) and vm:has_voice(cursor, b.role) then
        activate_band(cursor)
      end
    elseif edit_field == 5 then
      -- Rate (0=drone, 1-16=pulse division in 16ths)
      b.rate = util.clamp(b.rate + d, 0, 16)
      -- If switching from drone to pulse or vice versa while active
      if b.vol > 0 and is_melodic(b.role) and vm:has_voice(cursor, b.role) then
        if b.rate == 0 then
          -- Back to drone: make sure note is on
          activate_band(cursor)
        end
      end
    end
  end
end

function enc_prog(n, d)
  if n == 2 then
    if prog_cursor == 1 then
      -- Navigate steps
      prog_step_cursor = util.clamp(prog_step_cursor + d, 1, math.max(1, #prog.steps))
    else
      -- Navigate fields
      prog_cursor = util.clamp(prog_cursor + d, 1, 5)
    end
  elseif n == 3 then
    if prog_cursor == 1 then
      -- Change step degree
      if #prog.steps > 0 then
        local deg = prog.steps[prog_step_cursor]
        deg = util.clamp(deg + d, 1, 7)
        prog.steps[prog_step_cursor] = deg
      end
    elseif prog_cursor == 2 then
      -- Beats per step
      prog.beats_per_step = util.clamp(prog.beats_per_step + d, 1, 16)
    elseif prog_cursor == 3 then
      -- Key
      local k = util.clamp(vm.key_idx + d, 1, 12)
      vm:set_key(k)
      params:set("key", k)
      if playing then
        vm:retrigger_all(bands, get_chord_root())
      end
    elseif prog_cursor == 4 then
      -- Scale
      local s = util.clamp(vm.scale_idx + d, 1, #MusicUtil.SCALES)
      vm:set_scale(s)
      params:set("scale", s)
      if playing then
        vm:retrigger_all(bands, get_chord_root())
      end
    elseif prog_cursor == 5 then
      -- Quantize toggle
      vm.quantize = not vm.quantize
      params:set("quantize", vm.quantize and 1 or 2)
      if playing then
        vm:retrigger_all(bands, get_chord_root())
      end
    end
  end
end

function enc_config(n, d)
  if n == 2 then
    config_cursor = util.clamp(config_cursor + d, 1, #CONFIG_FIELDS)
  elseif n == 3 then
    if config_cursor == 1 then
      -- MIDI Out device
      local val = util.clamp(params:get("midi_device") + d, 1, 16)
      params:set("midi_device", val)
    elseif config_cursor == 2 then
      -- MIDIMIX device
      local val = util.clamp(params:get("midimix_device") + d, 1, 16)
      params:set("midimix_device", val)
    elseif config_cursor == 3 then
      local val = util.clamp(vm:get_primary_ch("bass") + d, 1, 16)
      vm:set_primary_ch("bass", val)
      params:set("bass_ch", val)
    elseif config_cursor == 4 then
      local val = util.clamp(vm:get_primary_ch("chord") + d, 1, 16)
      vm:set_primary_ch("chord", val)
      params:set("chord_ch", val)
    elseif config_cursor == 5 then
      local val = util.clamp(vm:get_primary_ch("lead") + d, 1, 16)
      vm:set_primary_ch("lead", val)
      params:set("lead_ch", val)
    elseif config_cursor == 6 then
      local val = util.clamp(vm.drum_channels[1] + d, 1, 16)
      vm.drum_channels[1] = val
      params:set("drum_ch", val)
    end
  end
end

local k1_held = false

function key(n, z)
  if n == 1 then
    k1_held = (z == 1)
    return
  end

  if z ~= 1 then return end

  if n == 2 then
    -- Play/stop (global)
    if playing then
      stop_playing()
    else
      start_playing()
    end
  elseif n == 3 then
    if page == 1 then
      -- Cycle edit field
      edit_field = (edit_field % #EDIT_NAMES) + 1
    elseif page == 2 then
      if k1_held and #prog.steps > 1 then
        -- Delete last step
        table.remove(prog.steps)
        prog_step_cursor = util.clamp(prog_step_cursor, 1, #prog.steps)
      else
        -- Add step after cursor
        local new_deg = prog.steps[prog_step_cursor] or 1
        table.insert(prog.steps, prog_step_cursor + 1, new_deg)
        prog_step_cursor = prog_step_cursor + 1
      end

      -- Toggle between step select and field select
      if not k1_held and prog_cursor ~= 1 then
        prog_cursor = 1
      elseif not k1_held and prog_cursor == 1 then
        prog_cursor = 2
      end
    elseif page == 3 then
      -- CONFIG page: K3 adds channel, K1+K3 removes last channel
      local roles = {"bass", "chord", "lead"}
      if config_cursor >= 3 and config_cursor <= 5 then
        local role = roles[config_cursor - 2]
        if k1_held then
          -- Remove last extra channel
          local chs = vm.pools[role].channels
          if #chs > 1 then
            local removed = chs[#chs]
            vm:remove_channel(role, removed)
            print(role .. ": removed ch " .. removed .. " -> " .. vm:channels_str(role))
          end
        else
          -- Add next channel (primary + 1)
          local primary = vm:get_primary_ch(role)
          local new_ch = primary + #vm.pools[role].channels
          if new_ch > 16 then new_ch = 1 end
          if vm:add_channel(role, new_ch) then
            print(role .. ": added ch " .. new_ch .. " -> " .. vm:channels_str(role))
          end
        end
      elseif config_cursor == 6 then
        -- Drum channels
        if k1_held then
          local chs = vm.drum_channels
          if #chs > 1 then
            local removed = chs[#chs]
            vm:remove_drum_channel(removed)
            print("drum: removed ch " .. removed .. " -> " .. vm:drum_channels_str())
          end
        else
          local new_ch = vm.drum_channels[1] + #vm.drum_channels
          if new_ch > 16 then new_ch = 1 end
          if vm:add_drum_channel(new_ch) then
            print("drum: added ch " .. new_ch .. " -> " .. vm:drum_channels_str())
          end
        end
      end
    end
  end
  redraw()
end

-- ===== CLEANUP =====

function cleanup()
  if redraw_clock then clock.cancel(redraw_clock) end
  stop_playing()
  if mm then mm:leds_off() end
end
