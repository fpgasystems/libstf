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
wget https://github.com/jemalloc/jemalloc/archive/refs/tags/5.3.0.zip
unzip 5.3.0.zip
rm 5.3.0.zip
mv jemalloc-5.3.0 "${download_path}/jemalloc"
pushd "${download_path}/jemalloc"

# Configure the compilation
./autogen.sh
# prefix:           Install path
# jemalloc-prefix:  prefix of all methods. This is very important as otherwise we might overwrite the default malloc!
# nareans:          Disables any default arenas (min = 1). We create own ones in the code so we disable as many of the
#                   default arenas as we can.
./configure --prefix=${install_path}/jemalloc --with-jemalloc-prefix=je_ --with-malloc-conf=narenas:1

# Compile & Install
make
make install

# Go back to the parent directory
popd
