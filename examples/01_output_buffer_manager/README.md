# Output Buffer Manager Example

Shows how to use the `OutputBufferManager` of the libSTF software library together with the
`OutputWriter` on the hardware side against the `output_writer_test` hardware design
([hardware/unit-tests/vfpga_tops/output_writer_test.sv](../../hardware/unit-tests/vfpga_tops/output_writer_test.sv)).

Each run performs one loopback pass:

1. Output buffers are enqueued to the `OutputWriter` on the FPGA.
2. The input data is streamed to the FPGA on the configured streams.
3. The FPGA writes the data back through the `OutputWriter` into the enqueued buffers. Completed
   buffers are signaled with interrupts and collected by the `OutputBufferManager`.

## Synthesizing the hardware

```bash
scripts/synthesize.sh output-writer
```

## Building the software

```bash
cmake -S . -B build && cmake --build build --target output_buffer_manager
```

For simulations, add `-DEN_SIMULATION=ON` to the first cmake call.

## Running the example

```bash
build/output_buffer_manager [OPTIONS]
```

| Option | Description |
| --- | --- |
| `-e, --enqueued N` | Number of output buffers to enqueue (default: 2) |
| `-b, --buffer-size BYTES` | Output buffer capacity (default: 256MiB - 64KiB) |
| `-S, --streams N` | Number of streams (default: 1) |
| `-s, --size BYTES` | Input size (default: 512MiB) |
| `-r, --runs N` | Number of runs (default: 8) |

For simulations, add `COYOTE_SIM_DIR="/<path-to-this-repo>/hardware/build-sim"` before executing
the example software. It is recommended to set the buffer size to the minimum and a small input
size (`-b 65536 -s 1024`).
