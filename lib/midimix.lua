-- midimix.lua: Akai MIDIMIX controller mapping for MIDI Sines
-- 8 channels banked to control 16 bands
--
-- LAYOUT:
--   Bank A = bands 1-8, Bank B = bands 9-16
--   Faders 1-8: band volume
--   Knob row 1: degree (1-7)
--   Knob row 2: octave (-3 to +3)
--   Knob row 3: rate (0-16)
--   Mute buttons: toggle band on/off (remembers volume)
--   Solo buttons: cycle role
--   Master fader: beats per step
--   Bank Left/Right: switch bank
--
-- LEDs: mute buttons light up when band vol > 0

local MidiMix = {}
MidiMix.__index = MidiMix

-- MIDIMIX CC assignments
local FADER_CC = {19, 23, 27, 31, 49, 53, 57, 61}
local MASTER_CC = 62
local KNOB_ROW1 = {16, 20, 24, 28, 46, 50, 54, 58}  -- degree
local KNOB_ROW2 = {17, 21, 25, 29, 47, 51, 55, 59}  -- octave
local KNOB_ROW3 = {18, 22, 26, 30, 48, 52, 56, 60}  -- rate

-- MIDIMIX button notes (every 3rd note per channel)
local MUTE_NOTES = {1, 4, 7, 10, 13, 16, 19, 22}
local SOLO_NOTES = {2, 5, 8, 11, 14, 17, 20, 23}
local REC_NOTES  = {3, 6, 9, 12, 15, 18, 21, 24}
local BANK_LEFT_NOTE = 25
local BANK_RIGHT_NOTE = 26
-- Some MIDIMIX units use CC for bank buttons instead of notes
local BANK_LEFT_CC = 25
local BANK_RIGHT_CC = 26

-- Roles to cycle through
local ROLES = {"bass", "chord", "lead", "kick", "snare", "hat"}

function MidiMix.new()
  local self = setmetatable({}, MidiMix)

  self.midi_in = nil
  self.bank = 0          -- 0 = bands 1-8, 1 = bands 9-16
  self.saved_vol = {}    -- saved volumes for mute toggle
  for i = 1, 16 do self.saved_vol[i] = 0.5 end

  -- Callbacks (set by main script)
  self.on_volume = nil       -- function(band_idx, vol)
  self.on_degree = nil       -- function(band_idx, degree)
  self.on_octave = nil       -- function(band_idx, octave)
  self.on_rate = nil         -- function(band_idx, rate)
  self.on_mute_toggle = nil  -- function(band_idx)
  self.on_role_cycle = nil   -- function(band_idx)
  self.on_beats = nil        -- function(beats_per_step)
  self.on_bank = nil         -- function(bank)  -- 0 or 1
  self.on_rec = nil          -- function(band_idx)  -- rec arm, spare button

  -- Build reverse lookup tables
  self._fader_map = {}
  self._knob1_map = {}
  self._knob2_map = {}
  self._knob3_map = {}
  self._mute_map = {}
  self._solo_map = {}
  self._rec_map = {}

  for i = 1, 8 do
    self._fader_map[FADER_CC[i]] = i
    self._knob1_map[KNOB_ROW1[i]] = i
    self._knob2_map[KNOB_ROW2[i]] = i
    self._knob3_map[KNOB_ROW3[i]] = i
    self._mute_map[MUTE_NOTES[i]] = i
    self._solo_map[SOLO_NOTES[i]] = i
    self._rec_map[REC_NOTES[i]] = i
  end

  return self
end

function MidiMix:connect(device_num)
  self.midi_in = midi.connect(device_num)
  self.midi_in.event = function(data)
    self:handle_event(data)
  end
  print("MIDIMIX connected on device " .. device_num)
end

-- Get the band index for a channel (1-8) based on current bank
function MidiMix:band_for(channel)
  return channel + (self.bank * 8)
end

-- Scale CC value (0-127) to a range
local function cc_to_range(val, min, max)
  local steps = max - min
  local step = math.floor((val / 127) * steps + 0.5)
  return min + step
end

function MidiMix:handle_event(data)
  local msg = midi.to_msg(data)

  if msg.type == "cc" then
    self:handle_cc(msg.cc, msg.val)
  elseif msg.type == "note_on" and msg.vel > 0 then
    self:handle_note(msg.note)
  end
end

function MidiMix:handle_cc(cc, val)
  -- Faders: band volume
  local fader_ch = self._fader_map[cc]
  if fader_ch then
    local band = self:band_for(fader_ch)
    local vol = val / 127
    self.saved_vol[band] = vol
    if self.on_volume then self.on_volume(band, vol) end
    return
  end

  -- Master fader: beats per step
  if cc == MASTER_CC then
    local beats = cc_to_range(val, 1, 16)
    if self.on_beats then self.on_beats(beats) end
    return
  end

  -- Knob row 1: degree
  local k1 = self._knob1_map[cc]
  if k1 then
    local band = self:band_for(k1)
    local degree = cc_to_range(val, 1, 7)
    if self.on_degree then self.on_degree(band, degree) end
    return
  end

  -- Knob row 2: octave
  local k2 = self._knob2_map[cc]
  if k2 then
    local band = self:band_for(k2)
    local octave = cc_to_range(val, -3, 3)
    if self.on_octave then self.on_octave(band, octave) end
    return
  end

  -- Knob row 3: rate
  local k3 = self._knob3_map[cc]
  if k3 then
    local band = self:band_for(k3)
    local rate = cc_to_range(val, 0, 16)
    if self.on_rate then self.on_rate(band, rate) end
    return
  end

  -- Bank buttons (some units send CC instead of notes)
  if cc == BANK_LEFT_CC and val == 127 then
    self.bank = 0
    if self.on_bank then self.on_bank(0) end
    self:update_leds()
    return
  end
  if cc == BANK_RIGHT_CC and val == 127 then
    self.bank = 1
    if self.on_bank then self.on_bank(1) end
    self:update_leds()
    return
  end
end

function MidiMix:handle_note(note)
  -- Mute buttons: toggle band volume
  local mute_ch = self._mute_map[note]
  if mute_ch then
    local band = self:band_for(mute_ch)
    if self.on_mute_toggle then self.on_mute_toggle(band) end
    return
  end

  -- Solo buttons: cycle role
  local solo_ch = self._solo_map[note]
  if solo_ch then
    local band = self:band_for(solo_ch)
    if self.on_role_cycle then self.on_role_cycle(band) end
    return
  end

  -- Rec arm buttons: spare (could be used for anything)
  local rec_ch = self._rec_map[note]
  if rec_ch then
    local band = self:band_for(rec_ch)
    if self.on_rec then self.on_rec(band) end
    return
  end

  -- Bank buttons (note variant)
  if note == BANK_LEFT_NOTE then
    self.bank = 0
    if self.on_bank then self.on_bank(0) end
    self:update_leds()
    return
  end
  if note == BANK_RIGHT_NOTE then
    self.bank = 1
    if self.on_bank then self.on_bank(1) end
    self:update_leds()
    return
  end
end

-- Update MIDIMIX LEDs to reflect band states
-- Call this after volume changes or bank switches
-- bands_table: the main bands array
function MidiMix:update_leds(bands_table)
  if not self.midi_in then return end
  for ch = 1, 8 do
    local band = self:band_for(ch)
    local note = MUTE_NOTES[ch]
    if bands_table and bands_table[band] and bands_table[band].vol > 0 then
      self.midi_in:note_on(note, 127, 1)
    else
      self.midi_in:note_off(note, 0, 1)
    end
  end
end

-- Send all LEDs off
function MidiMix:leds_off()
  if not self.midi_in then return end
  for ch = 1, 8 do
    self.midi_in:note_off(MUTE_NOTES[ch], 0, 1)
  end
end

return MidiMix
