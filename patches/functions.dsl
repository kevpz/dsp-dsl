partial_lfo_freq(rate) = mod(10, sin(phase(rate)), 14)
partial_amp(rate, depth, bias) = mod(bias, sin(phase(partial_lfo_freq(rate))), depth)
partial(base_freq, harmonic, mod_rate, mod_depth, mod_bias) = mul(sin(phase(mul(base_freq, harmonic))), partial_amp(mod_rate, mod_depth, mod_bias))
voice(freq) = mix(partial(freq, 1, 0.5, 0.5, 0.5), partial(freq, 2, 1, 0.25, 0.25), partial(freq, 3, 2, 0.125, 0.125))

input note
input gate

freq = mtof(note)
env = adsr(gate, 0.01, 0.10, 0.7, 0.20)
body = voice(freq)
out = mul(body, env)
