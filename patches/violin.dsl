# Sustained bowed string with slow vibrato.

# Basic sine oscillator.
osc(freq) = sin(phase(freq))

# One bowed-string partial.
harmonic(freq, partial, amp) = mul(osc(mul(freq, partial)), amp)

# Fixed harmonic balance for the bowed tone.
violin_body(freq) = mix(harmonic(freq, 1, 1.0), harmonic(freq, 2, 0.75), harmonic(freq, 3, 0.45), harmonic(freq, 4, 0.28), harmonic(freq, 5, 0.18), harmonic(freq, 6, 0.10))

# Pitch vibrato in MIDI-note space.
vibrato(note, rate, depth) = mod(note, sin(phase(rate)), depth)

# Small level wobble to avoid a static tone.
bow_wobble(level, rate, amount) = mod(level, sin(phase(rate)), amount)

input note
input gate

# Gentle pitch motion before note-to-frequency conversion.
vibrato_note = vibrato(note, 5.3, 0.025)
freq = mtof(vibrato_note)

# Broad envelope for a sustained bow stroke.
env = adsr(gate, 0.08, 0.20, 0.90, 0.45)

# Small amplitude motion to imitate bow pressure changes.
bow = bow_wobble(0.95, 6.2, 0.05)

# Brighter while the note is strong.
cutoff = lerp(env, 1600, 5200)
body = lowpass(violin_body(freq), cutoff)
out = mul(mul(mul(body, env), bow), 0.4)
