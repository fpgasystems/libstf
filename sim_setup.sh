#!/bin/bash

pushd hardware
rm -r -f build_hw
mkdir build_hw
pushd build_hw
/usr/bin/cmake ..
make sim
