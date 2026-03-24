# Simple drawbar-style organ with a gentle rotor wobble.

# Basic sine oscillator.
osc(freq) = sin(phase(freq))

# One organ partial.
harmonic(freq, partial, amp) = mul(osc(mul(freq, partial)), amp)

# Fixed drawbar mix, including a sub-octave.
organ_body(freq) = mix(mul(osc(mul(freq, 0.5)), 0.35), harmonic(freq, 1, 0.9), harmonic(freq, 2, 0.6), harmonic(freq, 3, 0.4), harmonic(freq, 4, 0.25), harmonic(freq, 6, 0.15))

# Small amplitude wobble for a simple rotor feel.
rotor_wobble(level, rate, amount) = mod(level, sin(phase(rate)), amount)

input note
input gate

# MIDI note to Hz.
freq = mtof(note)

# Fast keying with nearly full sustain.
env = adsr(gate, 0.005, 0.08, 0.95, 0.08)

# Slow rotor-style level motion.
rotor = rotor_wobble(0.95, 5.8, 0.05)
out = mul(mul(mul(organ_body(freq), env), rotor), 0.35)
