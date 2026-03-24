# Very bright eight-voice additive supersaw.

# Basic sine oscillator.
osc(freq) = sin(phase(freq))

# One saw partial with 1/n-style amplitude.
harmonic(freq, partial, amp) = mul(osc(mul(freq, partial)), amp)

# Bright additive saw from the first twelve partials.
saw(freq) = mul(mix(harmonic(freq, 1, 1.0), harmonic(freq, 2, 0.5), harmonic(freq, 3, 0.3333333333), harmonic(freq, 4, 0.25), harmonic(freq, 5, 0.2), harmonic(freq, 6, 0.1666666667), harmonic(freq, 7, 0.1428571429), harmonic(freq, 8, 0.125), harmonic(freq, 9, 0.1111111111), harmonic(freq, 10, 0.1), harmonic(freq, 11, 0.0909090909), harmonic(freq, 12, 0.0833333333)), 0.24)

# Eight nearby saws for dense beating.
super_saw(center) = mix(saw(mul(center, 0.992)), saw(mul(center, 0.995)), saw(mul(center, 0.997)), saw(mul(center, 0.999)), saw(mul(center, 1.001)), saw(mul(center, 1.003)), saw(mul(center, 1.005)), saw(mul(center, 1.008)))

input note
input gate

# MIDI note to the shared center frequency.
center = mtof(note)

# Fast synth envelope.
env = adsr(gate, 0.003, 0.12, 0.82, 0.20)

# Bright filter envelope keeps the attack sharp and open.
filter_env = adsr(gate, 0.002, 0.18, 0.72, 0.18)
cutoff = lerp(filter_env, 3500, 14000)

# Slight detune spread creates the supersaw body.
stack = super_saw(center)
bright = lowpass(stack, cutoff)
out = mul(mul(bright, env), 0.16)
