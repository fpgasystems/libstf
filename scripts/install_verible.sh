#!/bin/bash

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
mkdir -p "${install_path}/bin"

version="v0.0-4298-g085eef05"
archive="verible-${version}-linux-static-x86_64.tar.gz"

echo "Downloading into ${download_path} and installing into ${install_path}"

# Download the prebuilt static binaries
pushd "${download_path}"
wget "https://github.com/chipsalliance/verible/releases/download/${version}/${archive}"
tar xzf "${archive}"
rm "${archive}"

# Install
cp "verible-${version}/bin/"* "${install_path}/bin/"
popd
