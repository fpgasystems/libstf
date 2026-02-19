#!/bin/bash -ex

# Determine the paths to install into
download_path="$HOME/download"
if [ -n "$DOWNLOAD_PATH" ]; then
  download_path="$DOWNLOAD_PATH"
fi
mkdir -p "${download_path}"

install_path="$HOME/opt"
if [ -n "$INSTALL_PATH" ]; then
  install_path="$INSTALL_PATH"
fi
mkdir -p "${download_path}"

echo "Downloading into ${download_path} and installing into ${install_path}"

# Clone the repository
git clone https://github.com/LLNL/Caliper.git "${download_path}/caliper"
pushd "${download_path}/caliper"

mkdir build
cd build

# Configure the compilation
# CMAKE_BUILD_TYPEL      Compile as release mode (no debug symbols, optimized)
# CMAKE_INSTALL_PREFIX:  Install path
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=${install_path} ..

# Compile & Install
make
make install

# Go back to the parent directory
popd
