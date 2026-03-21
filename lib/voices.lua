-- voices.lua: Voice allocation, MIDI routing, scale management
-- Handles voice pools, stealing, and note computation

local MusicUtil = require "musicutil"

local Voices = {}
Voices.__index = Voices

function Voices.new()
  local self = setmetatable({}, Voices)

  self.midi = nil

  -- Voice pools: melodic roles
  self.pools = {
    bass  = { max = 1, ch = 7,  active = {} },  -- Sub 37 mono
    chord = { max = 6, ch = 4,  active = {} },  -- OB-6 6-voice
    lead  = { max = 1, ch = 3,  active = {} },  -- Pro 3 mono
  }

  -- Drum config
  self.drum_ch = 15
  self.drum_notes = { kick = 36, snare = 38, hat = 42 }

  -- Currently sounding: band_idx -> { ch, note }
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

-- Get MIDI note for a chord_root_degree + band degree + octave
-- chord_root_degree: which scale degree is the current chord root (1-7)
-- band_degree: offset from chord root in scale degrees (1=root, 3=third, 5=fifth)
-- octave: octave offset (-3 to +3)
function Voices:get_note(chord_root_degree, band_degree, octave)
  if self.quantize then
    -- Scale-quantized: degrees map to scale steps
    local idx = (chord_root_degree - 1) + (band_degree - 1) + (octave * 7) + 1
    -- Center around octave 4 (middle C area)
    idx = idx + 21
    idx = math.max(1, math.min(#self.scale_notes, idx))
    return self.scale_notes[idx]
  else
    -- Chromatic: degrees map to semitones from root
    local root_midi = (self.key_idx - 1) + 60  -- middle C
    local semitones = (chord_root_degree - 1) + (band_degree - 1) + (octave * 12)
    return math.max(0, math.min(127, root_midi + semitones))
  end
end

-- Get the note name for display
function Voices:get_note_name(midi_note)
  if midi_note then
    return MusicUtil.note_num_to_name(midi_note, true)
  end
  return "---"
end

-- Get chord name for current progression step
function Voices:get_chord_name(chord_root_degree)
  local root_note = self:get_note(chord_root_degree, 1, 0)
  local name = MusicUtil.note_num_to_name(root_note, false)
  return name
end

-- ===== MIDI =====

function Voices:note_on(ch, note, vel)
  if self.midi and note then
    self.midi:note_on(note, vel, ch)
  end
end

function Voices:note_off(ch, note)
  if self.midi and note then
    self.midi:note_off(note, 0, ch)
  end
end

-- ===== VOICE MANAGEMENT =====

-- Release a band's sounding note
function Voices:release(band_idx)
  local s = self.sounding[band_idx]
  if s then
    self:note_off(s.ch, s.note)
    self.sounding[band_idx] = nil
  end
end

-- Remove band from its pool
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

-- Check if band has a voice in its pool
function Voices:has_voice(band_idx, role)
  local pool = self.pools[role]
  if not pool then return false end
  for _, bid in ipairs(pool.active) do
    if bid == band_idx then return true end
  end
  return false
end

-- Activate a melodic band. Returns true if voice acquired.
-- bands_table: reference to the full bands array (for volume comparison during stealing)
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
    self:note_on(pool.ch, note_val, vel)
    self.sounding[band_idx] = { ch = pool.ch, note = note_val }
    return true
  end

  -- Room in pool?
  if #pool.active < pool.max then
    table.insert(pool.active, band_idx)
    self:note_on(pool.ch, note_val, vel)
    self.sounding[band_idx] = { ch = pool.ch, note = note_val }
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
    -- Steal
    self:release(min_idx)
    pool.active[min_pool_pos] = band_idx
    self:note_on(pool.ch, note_val, vel)
    self.sounding[band_idx] = { ch = pool.ch, note = note_val }
    return true
  end

  return false  -- all voices louder than us
end

-- Deactivate a band completely
function Voices:deactivate(band_idx, role)
  self:release(band_idx)
  self:remove_from_pool(band_idx, role)
end

-- Trigger a drum hit
function Voices:trigger_drum(role, velocity)
  local note = self.drum_notes[role]
  if note then
    self:note_on(self.drum_ch, note, velocity)
  end
end

-- Release a drum hit
function Voices:release_drum(role)
  local note = self.drum_notes[role]
  if note then
    self:note_off(self.drum_ch, note)
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
        self:note_on(pool.ch, note_val, vel)
        self.sounding[band_idx] = { ch = pool.ch, note = note_val }
      end
    end
  end
end

-- Kill everything
function Voices:all_off()
  -- Release all sounding notes
  for band_idx, _ in pairs(self.sounding) do
    self:release(band_idx)
  end
  self.sounding = {}

  -- Clear pools
  for _, pool in pairs(self.pools) do
    pool.active = {}
  end

  -- All notes off CC on all channels
  if self.midi then
    for _, pool in pairs(self.pools) do
      self.midi:cc(123, 0, pool.ch)
    end
    self.midi:cc(123, 0, self.drum_ch)
  end
end

-- Get status string for a pool
function Voices:pool_status(role)
  local pool = self.pools[role]
  if pool then
    return #pool.active .. "/" .. pool.max
  end
  return "---"
end

return Voices
