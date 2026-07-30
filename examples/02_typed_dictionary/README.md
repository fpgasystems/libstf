# Typed Dictionary Benchmark

Benchmarks the `TypedDictionary` materialization pipeline against the
`typed_dict_test` hardware design
([hardware/unit-tests/vfpga_tops/typed_dict_test.sv](../../hardware/unit-tests/vfpga_tops/typed_dict_test.sv)).

Each run performs one dictionary materialization:

1. The dictionary values are streamed to the FPGA on stream 0 (build phase).
2. The 32-bit ids are streamed on stream 1 (probe phase).
3. For every id the FPGA sends back `dictionary[id]` on stream 0.

The dictionary holds `2^18` 32-bit slots (1 MiB, see `dict_id_t` in the vfpga top), so at most
`2^18` 32-bit or `2^17` 64-bit values.

## Synthesizing the hardware

```bash
scripts/synthesize.sh typed-dict
```

## Building the software

```bash
cmake -S . -B build && cmake --build build --target typed_dictionary
```

For simulations, add `-DEN_SIMULATION=ON` to the first cmake call.

## Running the example

```bash
build/typed_dictionary [OPTIONS]
```

| Option | Description |
| --- | --- |
| `-t, --type BITS` | Value type width, `32` or `64` (default: 32) |
| `-v, --values N` | Dictionary entries (default: 131072) |
| `-i, --ids N` | Ids to materialize, rounded up to a multiple of 16 (default: 16Mi) |
| `-z, --zipf THETA` | Zipf skew of the id distribution, `0` = uniform (default: 0) |
| `-d, --distinct` | Keep each id's bank but make the ids distinct, so the within-beat deduplication cannot collapse repeated ids |
| `-r, --runs N` | Number of runs (default: 5) |
| `-s, --seed N` | Random seed (default: 42) |

For simulations, add `COYOTE_SIM_DIR="/<path-to-this-repo>/hardware/build-sim"` before executing the example software.