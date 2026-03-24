# Monophonic piano with a bright attack and fast-decaying upper partials.

# Basic sine oscillator.
osc(freq) = sin(phase(freq))

# One struck partial with its own decay time.
strike(gate, decay) = adsr(gate, 0.001, decay, 0.0, 0.12)
piano_partial(freq, gate, harmonic, amp, decay) = mul(mul(osc(mul(freq, harmonic)), amp), strike(gate, decay))

# Fixed harmonic mix for the piano body.
piano_body(freq, gate) = mix(piano_partial(freq, gate, 1, 1.0, 0.90), piano_partial(freq, gate, 2, 0.65, 0.55), piano_partial(freq, gate, 3, 0.35, 0.28), piano_partial(freq, gate, 4, 0.15, 0.14), piano_partial(freq, gate, 6, 0.08, 0.05))

# Bright low-pass sweep on the initial hit.
brightness_env(gate) = adsr(gate, 0.001, 0.16, 0.0, 0.12)

input note
input gate

# MIDI note to Hz.
freq = mtof(note)

# Open the filter briefly at note onset.
brightness = lerp(brightness_env(gate), 1400, 5200)
body = piano_body(freq, gate)
tone = lowpass(body, brightness)
out = mul(tone, 0.85)
