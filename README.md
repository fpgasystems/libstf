<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="img/libstf_dark.png">
    <img src="img/libstf_light.png" width=250>
  </picture>
</p>

[![SystemVerilog](https://img.shields.io/badge/SystemVerilog-IEEE%201800-blue.svg)](https://github.com/fpgasystems/libstf)
[![GitHub last commit](https://img.shields.io/github/last-commit/fpgasystems/libstf)](https://github.com/fpgasystems/libstf/commits/main)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

# A Hardware Library for Data Processing
This library is a collection of common components for developing data processing hardware. Some 
modules are specific to developing vFPGAs for [Coyote](https://github.com/fpgasystems/Coyote). The 
main functionality libSTF offers is:

- Utilities for hardware configuration accessed through an AXI4L interface (hardware/src/hdl/config)
- Crossbar (hardware/src/hdl/crossbar)
- Dictionary (hardware/src/hdl/dict)
- Stream normalization (hardware/src/hdl/normalization)
- Hardware-side stream writer and reader to write arbitrary-length streams to and read them from host or card memory, and software-side buffer manager (hardware/src/hdl/memory)
- Replay buffer that stores streams in a ring buffer in card memory and replays each of them a configurable number of times (hardware/src/hdl/replay_buffer)
- Typed data interfaces (ndata_i, data_i, ntagged_i, ...), adapters to AXI4S interfaces, and other stream routing helpers (hardware/src/data_interfaces.sv and hardware/src/hdl/stream)

It also features the corresponding software-side components to use the hardware. This repository is 
*work in progress* and quite a bit of documentation is still missing. Please feel free to 
contribute.

## Getting started (hardware)
The intended way of using libSTF is as a library in Coyote. Coyote also provides a unit testing 
framework that is used to verify the functionality of libSTF modules.

### Simulation
The recommended way to get started with libSTF is by exploring the Python unit tests in the 
`hardware/unit-tests` folder. To execute the unit tests, you have to set up a Coyote simulation 
project first. This requires the Coyote submodule to be loaded by either cloning this repo with 
submodules directly:

```bash
git clone --recurse-submodules git@github.com:fpgasystems/libstf.git
```

Or initializing the Coyote submodule as a step after cloning:

```bash
git submodule update --init --recursive
```

To set up the simulation project, execute:

```bash
./scripts/setup_simulation.sh
```

This creates a folder `hardware/build-sim` which contains the simulation project. Anytime you create 
or rename files in `src/hdl`, you have to execute this command again. Changes to existing files get 
picked up automatically. After the initial setup, the unit tests show up in VSCode in the flask tab 
on the left side.

### Adding libSTF as a dependency to your Coyote project
Add libSTF as a submodule to your new project. When setting up the `CMakeLists.txt`, add libSTF to 
the `load_apps` call as follows:

```
load_apps (
    VFPGA_C0_0 "src ../libstf/hardware/src"
)
```

Afterwards, all hardware components are available in your Coyote project.

## Getting started (software)
The libSTF software library depends on jemalloc for the HugePageMemoryPool and Caliper if profiling 
is enabled. The dependencies can be installed with the utility scripts:

```bash
./scripts/install_jemalloc.sh
./scripts/install_caliper.sh
```

This will install jemalloc and Caliper in `~/opt`. Afterwards, the libSTF software library can be 
installed as follows:

```bash
mkdir software/build
cmake -DCMAKE_PREFIX_PATH=$HOME/opt -DCMAKE_INSTALL_PREFIX=$HOME/opt -S software -B software/build
cmake --build software/build -j
cmake --install software/build
```

If you want to enable profiling, you have to add `-DLIBSTF_WITH_PROFILING=ON` to the first `cmake` 
command.

## Code style
For now, we have a couple of code style rules:

- Camel case for class names; Snake case for file names and everything else in the code
- _i suffix for interfaces
- _t suffix for types
- n_ prefix for next signals in sequential logic
- inst_ prefix for module instantiations
- The term *width* always refers to width in bits and *size* to width in bytes

## License
The libSTF code is licensed under the terms in 
[LICENSE.md](https://github.com/fpgasystems/libstf/blob/master/LICENSE.md), which corresponds to the 
MIT Licence. Any contributions to libSTF will be accepted under the same terms of license.
