-- voices.lua: Voice allocation, MIDI routing, scale management
-- Handles voice pools, stealing, and note computation
-- Supports multiple MIDI channels per role (layering)

local MusicUtil = require "musicutil"

local Voices = {}
Voices.__index = Voices

function Voices.new()
  local self = setmetatable({}, Voices)

  self.midi = nil

  -- Voice pools: melodic roles
  -- channels = array of MIDI channels (supports layering)
  self.pools = {
    bass  = { max = 1, channels = {7},  active = {} },  -- Sub 37 mono
    chord = { max = 6, channels = {4},  active = {} },  -- OB-6 6-voice
    lead  = { max = 1, channels = {3},  active = {} },  -- Pro 3 mono
  }

  -- Drum config
  self.drum_channels = {15}  -- array for layering
  self.drum_notes = { kick = 0, snare = 1, hat = 2 }  -- Digitakt tracks 1-3

  -- Currently sounding: band_idx -> { channels={}, note }
  self.sounding = {}

  -- Scale state
  self.key_idx = 1          -- 1=C, 2=C#, ... 12=B
  self.scale_idx = 1        -- index into MusicUtil.SCALES
  self.quantize = true      -- true=scale degrees, false=chromatic
  self.scale_notes = {}     -- computed MIDI note array

  self:build_scale()

  return self
end

function Voices:connect(device_num)
  self.midi = midi.connect(device_num or 1)
end

-- ===== CHANNEL MANAGEMENT =====

-- Get the primary (first) channel for a role
function Voices:get_primary_ch(role)
  local pool = self.pools[role]
  if pool and pool.channels[1] then
    return pool.channels[1]
  end
  return 1
end

-- Add a channel to a role (up to 3 channels per role)
function Voices:add_channel(role, ch)
  local pool = self.pools[role]
  if not pool then return false end
  -- Check if already present
  for _, c in ipairs(pool.channels) do
    if c == ch then return false end
  end
  if #pool.channels >= 3 then return false end
  table.insert(pool.channels, ch)
  return true
end

-- Remove a channel from a role (can't remove the last one)
function Voices:remove_channel(role, ch)
  local pool = self.pools[role]
  if not pool or #pool.channels <= 1 then return false end
  for i = #pool.channels, 1, -1 do
    if pool.channels[i] == ch then
      table.remove(pool.channels, i)
      return true
    end
  end
  return false
end

-- Set the primary channel (replaces first entry)
function Voices:set_primary_ch(role, ch)
  local pool = self.pools[role]
  if pool then
    pool.channels[1] = ch
  end
end

-- Get channel list string for display
function Voices:channels_str(role)
  local pool = self.pools[role]
  if not pool then return "---" end
  local parts = {}
  for _, ch in ipairs(pool.channels) do
    table.insert(parts, tostring(ch))
  end
  return table.concat(parts, "+")
end

-- Add drum channel
function Voices:add_drum_channel(ch)
  for _, c in ipairs(self.drum_channels) do
    if c == ch then return false end
  end
  if #self.drum_channels >= 3 then return false end
  table.insert(self.drum_channels, ch)
  return true
end

-- Remove drum channel
function Voices:remove_drum_channel(ch)
  if #self.drum_channels <= 1 then return false end
  for i = #self.drum_channels, 1, -1 do
    if self.drum_channels[i] == ch then
      table.remove(self.drum_channels, i)
      return true
    end
  end
  return false
end

function Voices:drum_channels_str()
  local parts = {}
  for _, ch in ipairs(self.drum_channels) do
    table.insert(parts, tostring(ch))
  end
  return table.concat(parts, "+")
end

-- ===== SCALE =====

function Voices:build_scale()
  local root_midi = (self.key_idx - 1) + 24  -- start from octave 1
  local scale_name = MusicUtil.SCALES[self.scale_idx].name
  self.scale_notes = MusicUtil.generate_scale_of_length(root_midi, scale_name, 64)
end

function Voices:set_key(idx)
  self.key_idx = util.clamp(idx, 1, 12)
  self:build_scale()
end

function Voices:set_scale(idx)
  self.scale_idx = util.clamp(idx, 1, #MusicUtil.SCALES)
  self:build_scale()
end

function Voices:get_note(chord_root_degree, band_degree, octave)
  if self.quantize then
    local idx = (chord_root_degree - 1) + (band_degree - 1) + (octave * 7) + 1
    idx = idx + 21
    idx = math.max(1, math.min(#self.scale_notes, idx))
    return self.scale_notes[idx]
  else
    local root_midi = (self.key_idx - 1) + 60
    local semitones = (chord_root_degree - 1) + (band_degree - 1) + (octave * 12)
    return math.max(0, math.min(127, root_midi + semitones))
  end
end

function Voices:get_note_name(midi_note)
  if midi_note then
    return MusicUtil.note_num_to_name(midi_note, true)
  end
  return "---"
end

function Voices:get_chord_name(chord_root_degree)
  local root_note = self:get_note(chord_root_degree, 1, 0)
  local name = MusicUtil.note_num_to_name(root_note, false)
  return name
end

-- ===== MIDI (multi-channel) =====

-- Send note on to all channels in a list
function Voices:note_on_multi(channels, note, vel)
  if self.midi and note then
    for _, ch in ipairs(channels) do
      self.midi:note_on(note, vel, ch)
    end
  end
end

-- Send note off to all channels in a list
function Voices:note_off_multi(channels, note)
  if self.midi and note then
    for _, ch in ipairs(channels) do
      self.midi:note_off(note, 0, ch)
    end
  end
end

function Voices:program_change(ch, program)
  if self.midi then
    self.midi:program_change(program, ch)
  end
end

-- Send PC to all channels for a role
function Voices:send_pc(role, program)
  local pool = self.pools[role]
  if pool then
    for _, ch in ipairs(pool.channels) do
      self:program_change(ch, program)
    end
  elseif role == "kick" or role == "snare" or role == "hat" then
    for _, ch in ipairs(self.drum_channels) do
      self:program_change(ch, program)
    end
  end
end

-- ===== VOICE MANAGEMENT =====

-- Release a band's sounding note (all its channels)
function Voices:release(band_idx)
  local s = self.sounding[band_idx]
  if s then
    self:note_off_multi(s.channels, s.note)
    self.sounding[band_idx] = nil
  end
end

function Voices:remove_from_pool(band_idx, role)
  local pool = self.pools[role]
  if not pool then return end
  for i = #pool.active, 1, -1 do
    if pool.active[i] == band_idx then
      table.remove(pool.active, i)
      return
    end
  end
end

function Voices:has_voice(band_idx, role)
  local pool = self.pools[role]
  if not pool then return false end
  for _, bid in ipairs(pool.active) do
    if bid == band_idx then return true end
  end
  return false
end

-- Activate a melodic band (sends to all channels for that role)
function Voices:activate_melodic(band_idx, bands_table, chord_root_degree)
  local b = bands_table[band_idx]
  local role = b.role
  local pool = self.pools[role]
  if not pool then return false end

  local note_val = self:get_note(chord_root_degree, b.degree, b.octave)
  local vel = math.floor(b.vol * 127)
  if vel < 1 then return false end

  -- Already has a voice? Just update note
  if self:has_voice(band_idx, role) then
    self:release(band_idx)
    self:note_on_multi(pool.channels, note_val, vel)
    self.sounding[band_idx] = { channels = pool.channels, note = note_val }
    return true
  end

  -- Room in pool?
  if #pool.active < pool.max then
    table.insert(pool.active, band_idx)
    self:note_on_multi(pool.channels, note_val, vel)
    self.sounding[band_idx] = { channels = pool.channels, note = note_val }
    return true
  end

  -- Voice steal: find the band with lowest volume
  local min_vol = b.vol
  local min_idx = nil
  local min_pool_pos = nil
  for pi, bid in ipairs(pool.active) do
    if bands_table[bid].vol < min_vol then
      min_vol = bands_table[bid].vol
      min_idx = bid
      min_pool_pos = pi
    end
  end

  if min_idx then
    self:release(min_idx)
    pool.active[min_pool_pos] = band_idx
    self:note_on_multi(pool.channels, note_val, vel)
    self.sounding[band_idx] = { channels = pool.channels, note = note_val }
    return true
  end

  return false
end

function Voices:deactivate(band_idx, role)
  self:release(band_idx)
  self:remove_from_pool(band_idx, role)
end

-- Trigger a drum hit (all drum channels)
function Voices:trigger_drum(role, velocity)
  local note = self.drum_notes[role]
  if note then
    self:note_on_multi(self.drum_channels, note, velocity)
  end
end

-- Release a drum hit (all drum channels)
function Voices:release_drum(role)
  local note = self.drum_notes[role]
  if note then
    self:note_off_multi(self.drum_channels, note)
  end
end

-- Retrigger all active melodic bands with new chord root
function Voices:retrigger_all(bands_table, chord_root_degree)
  for role, pool in pairs(self.pools) do
    for _, band_idx in ipairs(pool.active) do
      local b = bands_table[band_idx]
      if b.vol > 0 then
        self:release(band_idx)
        local note_val = self:get_note(chord_root_degree, b.degree, b.octave)
        local vel = math.floor(b.vol * 127)
        self:note_on_multi(pool.channels, note_val, vel)
        self.sounding[band_idx] = { channels = pool.channels, note = note_val }
      end
    end
  end
end

-- Kill everything
function Voices:all_off()
  for band_idx, _ in pairs(self.sounding) do
    self:release(band_idx)
  end
  self.sounding = {}

  for _, pool in pairs(self.pools) do
    pool.active = {}
  end

  -- All notes off CC on all channels
  if self.midi then
    local sent = {}
    for _, pool in pairs(self.pools) do
      for _, ch in ipairs(pool.channels) do
        if not sent[ch] then
          self.midi:cc(123, 0, ch)
          sent[ch] = true
        end
      end
    end
    for _, ch in ipairs(self.drum_channels) do
      if not sent[ch] then
        self.midi:cc(123, 0, ch)
        sent[ch] = true
      end
    end
  end
end

function Voices:pool_status(role)
  local pool = self.pools[role]
  if pool then
    return #pool.active .. "/" .. pool.max
  end
  return "---"
end

return Voices
