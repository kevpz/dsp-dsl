# Dual slightly detuned additive saw pad.

# Basic sine oscillator.
osc(freq) = sin(phase(freq))

# One saw partial with 1/n-style amplitude.
harmonic(freq, partial, amp) = mul(osc(mul(freq, partial)), amp)

# Additive saw from the first eight partials.
saw(freq) = mul(mix(harmonic(freq, 1, 1.0), harmonic(freq, 2, 0.5), harmonic(freq, 3, 0.3333333333), harmonic(freq, 4, 0.25), harmonic(freq, 5, 0.2), harmonic(freq, 6, 0.1666666667), harmonic(freq, 7, 0.1428571429), harmonic(freq, 8, 0.125)), 0.6)

# Two nearby saws for slow beating and width.
dual_saw(center) = mix(saw(mul(center, 0.9975)), saw(mul(center, 1.0025)))

input note
input gate

# MIDI note to the shared center frequency.
center = mtof(note)

# Slow pad envelope.
env = adsr(gate, 0.18, 0.35, 0.90, 0.90)

# Separate filter envelope for the opening sweep.
filter_env = adsr(gate, 0.05, 0.45, 0.55, 0.90)

# Detuned pair creates the classic width and beating.
stack = dual_saw(center)

# Keep the pad warm rather than bright.
cutoff = lerp(filter_env, 500, 2400)
body = lowpass(stack, cutoff)
out = mul(mul(body, env), 0.35)
