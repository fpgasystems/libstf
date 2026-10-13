# Replay Buffer

Streams data through a `ReplayBuffer` in card memory. The hardware design is the `replay_buffer_test`
design ([hardware/unit-tests/vfpga_tops/replay_buffer_test.sv](../../hardware/unit-tests/vfpga_tops/replay_buffer_test.sv)):
host stream 0 goes through the replay buffer and back to host stream 0. Stream profilers on the
buffer input and output measure the device throughput.

Each run does the following:

1. The number of reads of every stream is enqueued in the `ReplayBufferConfig`.
2. `--streams` streams of `--bytes` bytes are sent to the FPGA on stream 0. The FPGA writes them to a
   ring buffer in card memory.
3. The FPGA sends every stream back `--reads` times on stream 0, all reads of a stream before the
   next stream.
4. Every received copy is compared against its input stream.

The ring buffer is allocated from the huge page memory pool, offloaded to the card memory, and
configured once at startup. A stream that is read more than once has to fit into the ring buffer
together with one transfer (64 KiB), as it is only released after its last read.

## Synthesizing the hardware

```bash
scripts/synthesize.sh replay-buffer
```

## Building the software

```bash
cmake -S . -B build && cmake --build build --target replay_buffer
```

For simulations, add `-DEN_SIMULATION=ON` to the first cmake call.

## Running the example

```bash
build/replay_buffer [OPTIONS]
```

| Option | Description |
| --- | --- |
| `-b, --bytes N` | Bytes per stream, a multiple of 8 (default: 16Mi) |
| `-n, --streams N` | Number of streams per run, at most the number of streams the replay buffer can enqueue (64) (default: 4) |
| `-k, --reads N` | How often each stream is read (default: 3) |
| `-m, --ring N` | Size of the ring buffer in card memory in bytes (default: 1Gi) |
| `-r, --runs N` | Number of runs (default: 3) |
| `-s, --seed N` | Random seed (default: 42) |

For simulations, add `COYOTE_SIM_DIR="/<path-to-this-repo>/hardware/build-sim"` before executing the
example software and use small streams, e.g., `--bytes 65536 --streams 2 --reads 2 --ring 196608`.
The simulation uses the vFPGA top of the unit test that ran last, so run a `replay_buffer_test` unit
test first.
