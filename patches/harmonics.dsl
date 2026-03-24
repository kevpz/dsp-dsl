input note
input gate

# freq from midi note.
freq = mtof(note)
env = adsr(gate, 0.01, 0.10, 0.7, 0.20)

# fundamental with a slow moving modulator.
lfo_freq_0 = range(sin(phase(0.5)), 0, 8)
lfo_0 = pos(sin(phase(lfo_freq_0)))
h_0 = mul(sin(phase(freq)), lfo_0)

# second harmonic.
lfo_freq_1 = mod(10, sin(phase(1)), 14)
lfo_1 = mod(0.25, sin(phase(lfo_freq_1)), 0.25)
h_1 = mul(sin(phase(mul(freq, 2))), lfo_1)

# third harmonic.
lfo_freq_2 = mod(10, sin(phase(2)), 14)
lfo_2 = mod(0.125, sin(phase(lfo_freq_2)), 0.125)
h_2 = mul(sin(phase(mul(freq, 3))), lfo_2)

# mix partials.
voice = mix(h_0, h_1, h_2)

# apply envelope.
out = mul(voice, env)
