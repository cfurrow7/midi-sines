# MIDI Sines

16-band MIDI drone/rhythm machine for monome norns. Inspired by [Sines](https://github.com/aidanreilly/sines) by Aidan Reilly, but replaces FM drones with MIDI output to hardware synths.

16 bands act as voices assigned to roles (bass, chord, lead, kick, snare, hat). Raise faders to bring voices in and out. A progression sequencer changes the chord root and all voices follow, staying in key.

## Requirements

- monome norns
- MIDI interface + hardware synths
- Optional: Akai MIDIMIX controller

## Install

From Maiden REPL:
```
;install https://github.com/cfurrow7/midi-sines.git
```

## Default Channel Map

| Role | Channel | Synth |
|------|---------|-------|
| Bass | 2 | Mother 32 |
| Chord | 4 + 11 | OB-6 + Evolver |
| Lead | 10 + 3 | MS-101 + Pro 3 |
| Drums | 15 | Digitakt |

Channels are configurable on the CONFIG page and support layering (up to 3 channels per role).

## Pages

### BANDS (page 1)
16 vertical bars showing each band's volume. The selected band's edit field is shown at the bottom.

- **E1**: switch page
- **E2**: select band (1-16)
- **E3**: adjust current edit field
- **K2**: play/stop progression
- **K3**: cycle edit field

Edit fields (cycle with K3):
1. **VOL** - volume (0-1)
2. **ROLE** - bass/chord/lead/kick/snare/hat
3. **DEG** - scale degree (1-7)
4. **OCT** - octave (-5 to +5)
5. **RATE** - melodic: pulse rate (0=drone, 1=1/16, 2=1/8, 4=1/4...) / drums: pattern select (0-10)
6. **ARP** - arpeggiator mode: OFF/UP/DN/UPDN/RAND

### PROG (page 2)
Chord progression editor with scale/key settings.

- **E2**: navigate fields (Steps, BPM, Beats/Step, Key, Scale, Quantize)
- **E3**: adjust selected field (on Steps row: select which step)
- **K3**: on Steps row, cycle selected step's degree
- **K1+K3**: load random preset progression

20 preset progressions included: I-V-vi-IV (pop), ii-V-I (jazz), I-IV (blues), Andalusian cadence, Pachelbel's Canon, and more.

### CONFIG (page 3)
MIDI device selection and channel configuration.

- **E2**: navigate fields
- **E3**: adjust channel/device number
- **K3**: enter add-channel mode (E3 to pick channel, K3 to confirm)
- **K1+K3**: remove last extra channel from selected role

## Arpeggiator

The arp plays the same note across octaves (base octave and +1). When multiple bands share a role and have arp enabled, their notes pool together into one arp sequence.

Example: chord bands with degrees 1, 3, 5 and arp UP:
```
1 -> 3 -> 5 -> 1(+oct) -> 3(+oct) -> 5(+oct) -> repeat
```

Arp starts automatically when enabled (sets rate to 1/8 if band was a drone). The clock is free-running by default, so arp and drums play without needing to press play. Play/stop only controls the chord progression.

## Drum Patterns

10 preset patterns per drum role (kick, snare, hat) covering house, hip hop, breakbeat, funk, dnb, techno, and more. Select with knob row 3 on MIDIMIX or the RATE edit field on drums.

## MIDIMIX Controller Map

```
 KNOB ROW 1:   DEG    DEG    DEG    DEG    DEG    DEG    DEG    DEG
 KNOB ROW 2:    PC     PC     PC     PC     PC     PC     PC     PC
 KNOB ROW 3:  RATE   RATE   RATE   RATE   RATE   RATE   RATE   RATE
               melodic = pulse rate / drums = pattern select

 MUTE:        [on/off per band]
 REC ARM:     [cycle arp mode per band]

 FADERS:       VOL    VOL    VOL    VOL    VOL    VOL    VOL    VOL

 BANK L/R:    bands 1-8 / 9-16
 SEND ALL:    PANIC (all notes off)
 SOLO:        play/stop (tap) / hold + knob row 1 = global octave
 MASTER:      BPM (20-300)
```

## Parameters

Available in norns PARAMS menu:
- MIDI Device, MIDIMIX Device
- Bass/Chord/Lead/Drum channels and voice counts
- Key, Scale, Quantize
- BPM, Beats/Step
- Kick/Snare/Hat note numbers
- Free Running (on/off)

## Credits

- Inspired by [Sines](https://github.com/aidanreilly/sines) by Aidan Reilly
- v0.1 @clf
