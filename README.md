<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="img/libstf_dark.png">
    <img src="img/libstf_light.png" width=250>
  </picture>
</p>

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

# A Standard Library for Hardware Design

This library is a collection of common modules used to develop hardware designs. Some modules are 
specific to developing vFPGAs for Coyote. The main functionality libstf offers is:

- Interfaces that transport a specific number of elements (ndata), adapters to AXI4S interfaces, and other helpers (hardware/src/data_interfaces.sv and hardware/src/hdl/stream)
- Utilities for configuration registers accessed through an AXI4L interface (hardware/src/hdl/config)
- Crossbar (hardware/src/hdl/crossbar)
- Dictionary (hardware/src/hdl/dict)
- Stream normalization (hardware/src/hdl/normalization)
- Coyote vFPGA-specific stream output writer that generates memory requests and communicates with a output buffer manager on the CPU side (hardware/src/hdl/output)

It also features some of the corresponding software-side components to use the hardware. This 
repository is *work in progress* and quite a bit of documentation is missing. Please feel free to 
contribute.

## Getting Started (Hardware)
Clone the repo and download the Coyote submodule:
```bash
git clone --recurse-submodules https://github.com/fpgasystems/libstf
```

The recommended way to get started with libstf is to start exploring the Python unit tests in the 
`hardware/unit-tests` folder. To execute the unit tests, you have to set up the Coyote simulation 
project with:

```bash
./sim_setup.sh
```

This creates the `hardware/build_hw` folder. Anytime you create or rename files in `src/hdl`, you 
have to execute this command again. Afterwards, the unit tests should show up in VSCode.

## Getting Started (Software)
You have to install jemalloc which is required for the HugePageMemoryPool like this:

```bash
./scripts/install_jemalloc.sh
```

This will install jemalloc in `~/opt/jemalloc`. The you can build the libstf library as follows:

```bash
mkdir build && cd build
cmake -DCMAKE_PREFIX_PATH=$HOME/opt ..
make
```

Notice the `-DCMAKE_PREFIX_PATH=$HOME/opt`: this is so that CMake will look in the path where
jemalloc has been installed with the script and link libstf against it.

## Code Style
For now, we have a couple of code style rules:

- Camel case for class names and snake case for file names and everything else in the code
- _i suffix for interfaces
- _t suffix for types
- n_ prefix for next signals in state logic
- inst_ prefix for module instantiations
- The term *width* always refers to width in bits and *size* to width in bytes

## TODOs
1. Get types and NUM_ELEMENTS from interface instead of parameters (on hold because this crashes Vivado sometimes)
2. Add interface assertions

## License
The libstf code is licensed under the terms in [LICENSE.md](https://github.com/fpgasystems/libstf/blob/master/LICENSE.md), which corresponds to the MIT Licence.
Any contributions to libstf will be accepted under the same terms of license.
