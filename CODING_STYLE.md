# Code style

## General
- Keep comments to a minimum for non-trivial design decisions
- Use speaking names and stay away from cryptic abbreviations
- Camel case for module names
- Snake case for file names and signals
- Upper snake case for parameters, localparams, constants, and genvars (e.g., `NUM_ELEMENTS`, 
  `genvar I`)
- _i suffix for interfaces
- _t suffix for types
- n_ prefix for next signals in sequential logic
- inst_ prefix for module instantiations
- The term *width* always refers to width in bits and *size* to width in bytes
- Lines are at most 100 columns long
- Never use semicolons in comments

## SystemVerilog

### Files and modules
- Every module file starts with `` `timescale 1ns / 1ps ``
- Every module has a `/** ... */` comment above it that describes what it does
- Check constraints on parameters at elaboration time with `` `ASSERT_ELAB(...) ``
- Split long modules into parts with section header comments padded to column 100:

```systemverilog
// -- Read -----------------------------------------------------------------------------------------
```

### Ports
- `clk` and `rst_n` are the first ports
- Name the main input and output streams `in` and `out`
- Connect module ports by name. Interfaces may use positional ports, e.g.,
  `ndata_i #(data_t, N) in(clk, rst_n)`, and parameters may be positional
- Annotate interface ports with their parameters:

  ```systemverilog
  ndata_i.s in, // #(data_t, NUM_ELEMENTS)
  ndata_i.m out // #(data_t, NUM_ELEMENTS)
  ```

- Tie off unused interfaces with `always_comb x.tie_off_m();` or `always_comb x.tie_off_s();`

### Logic
- Check for reset with `if (!rst_n)`
- In reset branches, set data registers to `'X`. Only control signals (valid, state, counters, 
  ...) get a defined reset value.
- Write state machines as a `state_t` enum with `state` and `n_state` signals and a short comment
  for every state:

  ```systemverilog
  typedef enum logic[1:0] {
      WAIT,   // Waiting for first handshake
      STREAM, // Counting cycles in a stream
      IDLE    // Counting cycles between streams
  } state_t;

  state_t state, n_state;
  ```

- Label generate blocks with a `gen_` prefix, e.g.,
  `for (genvar I = 0; I < N; I++) begin : gen_lanes`

## Testing
- Every major new module gets a unit test in `hardware/unit-tests/<name>_test.py` with its vFPGA top 
  in `hardware/unit-tests/vfpga_tops/<name>_test.sv`
