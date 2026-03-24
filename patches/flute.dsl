# Soft flute with light vibrato and a simple breath shimmer.

# Basic sine oscillator.
osc(freq) = sin(phase(freq))

# One flute partial.
harmonic(freq, partial, amp) = mul(osc(mul(freq, partial)), amp)

# Mostly fundamental, with a few weak upper partials.
flute_body(freq) = mix(harmonic(freq, 1, 1.0), harmonic(freq, 2, 0.18), harmonic(freq, 3, 0.05), harmonic(freq, 4, 0.015))

# Subtle pitch vibrato in MIDI-note space.
vibrato(note, rate, depth) = mod(note, sin(phase(rate)), depth)

# Slow amplitude shimmer for breathiness.
breath_wobble(level, rate, amount) = mod(level, sin(phase(rate)), amount)

input note
input gate

# Slight pitch motion before note-to-frequency conversion.
vibrato_note = vibrato(note, 4.8, 0.010)
freq = mtof(vibrato_note)

# Soft attack and mostly steady sustain.
env = adsr(gate, 0.05, 0.18, 0.92, 0.25)

# Very slow level shimmer for a breathy tone.
air = breath_wobble(0.97, 0.35, 0.03)

# Keep the flute dark, but open slightly with the note.
cutoff = lerp(env, 900, 2600)
body = lowpass(flute_body(freq), cutoff)
out = mul(mul(mul(body, env), air), 0.7)
