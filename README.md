# DSP DSL

## Initial Idea

This project starts from a simple model of DSP.

A signal is a discrete-time stream of samples:

\[
x : \mathbb{Z} \to \mathbb{R}
\]

A DSP block is an operator over such streams.

There are two important cases:

- a pure pointwise operator:

\[
y[n] = F(x_1[n], x_2[n], \dots)
\]

- a causal stateful operator:

\[
s[n+1] = U(s[n], x[n]), \quad y[n] = G(s[n], x[n])
\]

## Design Decision

The language describes one mono patch as a directed acyclic graph.

- every value is a stream
- `input name` declares an external input stream
- `f(x) = expr` declares a single-expression function
- `name = expr` binds a stream
- `out = expr` is the final output

References are source-ordered, so the graph is acyclic. There is no recursion,
no feedback, and no implicit mutable state.

The core operators are:

- `add`, `sub`, `mul`, `mix`
- `mtof`
- `phase`
- `sin`
- `adsr`
- `lowpass`

The semantic split is explicit:

- `add`, `sub`, `mul`, `mix`, `mtof`, and `sin` are pure stream operators
- `phase`, `adsr`, and `lowpass` are causal stateful operators

So the language is small on purpose: operators over streams, composed in a DAG.

Example:

```txt
voice(note, gate) = mul(sin(phase(mtof(note))), adsr(gate, 0.01, 0.10, 0.7, 0.20))

input note
input gate
out = voice(note, gate)
```

Example patches are in [patches/](./patches).

## Implementation

The implementation is in Zig.

At a high level:

1. Parse the source.
2. Validate names, ordering, arity, and graph well-formedness.
3. Expand the implicit prelude and inline user-defined functions.
4. Lower the result to a normalized core DAG of builtin operators.
5. Compile that DAG to a runtime with explicit value slots and state cells.
6. Execute the same compiled form offline or in realtime.

The runtime is optimized around the language structure:

- constants are hoisted out of the sample loop
- pure subgraphs are compacted
- `sin(phase(freq))` is fused
- dense additive oscillator sums are lowered to oscillator-bank kernels

Main files:

- [src/surface.zig](./src/surface.zig): parsing, validation, normalization
- [src/lib.zig](./src/lib.zig): core compilation and runtime
- [src/realtime.zig](./src/realtime.zig): ALSA/X11 realtime host

## How To Run It

Requirements:

- Zig
- ALSA and X11 for realtime playback

Build:

```bash
zig build
```

Run tests:

```bash
zig build test
```

Check a patch:

```bash
./zig-out/bin/dspdsl check patches/piano.dsl
```

Render a few samples offline:

```bash
./zig-out/bin/dspdsl render patches/functions.dsl 4 48000 note=60 gate=0,1,1,0
```

Play a patch in realtime:

```bash
./zig-out/bin/dspdsl play patches/piano.dsl
```

The realtime player uses the laptop keyboard as a monophonic controller. Focus
the window and use the displayed key layout.
