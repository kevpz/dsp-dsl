# Additive saw approximation with slow per-partial phase motion.

phase_modulated(base_freq, harmonic, lfo_rate, lfo_depth) = mod(phase(mul(base_freq, harmonic)), sin(phase(lfo_rate)), lfo_depth)
drifting_partial(base_freq, harmonic, amp, lfo_rate, lfo_depth) = mul(sin(phase_modulated(base_freq, harmonic, lfo_rate, lfo_depth)), amp)
phase_saw(freq) = mul(mix(drifting_partial(freq, 1, 1.0, 0.07, 0.010), drifting_partial(freq, 2, 0.5, 0.11, 0.015), drifting_partial(freq, 3, 0.3333333333, 0.17, 0.020), drifting_partial(freq, 4, 0.25, 0.23, 0.025), drifting_partial(freq, 5, 0.2, 0.31, 0.030), drifting_partial(freq, 6, 0.1666666667, 0.41, 0.035), drifting_partial(freq, 7, 0.1428571429, 0.53, 0.040), drifting_partial(freq, 8, 0.125, 0.67, 0.045)), 0.35)

input note
input gate

freq = mtof(note)
env = adsr(gate, 0.005, 0.12, 0.75, 0.25)
body = phase_saw(freq)
out = mul(body, env)
