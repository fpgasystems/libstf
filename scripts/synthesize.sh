#!/bin/bash

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(dirname "$script_dir")"

usage() {
    cat <<'EOF'
Usage: synthesize.sh <test-case>

Configure and launch a Vivado bitstream build for one of the libSTF unit-test
designs in a fresh hardware/build-NN directory (run detached in a tmux
session). After the Vivado projects are created, the vfpga_top.svh of the
selected unit test is copied into the user project (hardware/src/vfpga_top.svh
is left untouched) before the bitstream generation starts.

Test cases:
  output-writer        Build the output writer test case.
  typed-dict           Build the typed dictionary test case.

Options:
  -h, --help           Show this help message and exit.

Examples:
  synthesize.sh output-writer
  synthesize.sh typed-dict
EOF
}

test_case=""
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        output-writer|output_writer) test_case=output_writer_test ;;
        typed-dict|typed_dict) test_case=typed_dict_test ;;
        *) echo "Unknown argument: $1" >&2; echo "" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

if [ -z "$test_case" ]; then
    echo "No test case given." >&2
    echo "" >&2
    usage >&2
    exit 1
fi

pushd "$repo_dir/hardware"

# Finds the build directory with the highest number and starts the synthesis in a new directory with that number + 1
n=0
for d in build-[0-9][0-9]; do
    [ -d "$d" ] || continue
    num="${d#build-}"
    [ "$((10#$num))" -gt "$n" ] && n=$((10#$num))
done
build_dir="$PWD/build-$(printf '%02d' $((n + 1)))"
echo "Building $test_case bitstream in hardware/$(basename "$build_dir")..."

mkdir "$build_dir"
cmake -S . -B "$build_dir" || exit 1

top_file="$repo_dir/hardware/unit-tests/vfpga_tops/$test_case.sv"

# The project target copies hardware/src/vfpga_top.svh into the user project. The copy there is
# replaced with the unit-test top before the bitstream generation reads it.
project_cmd="cmake --build $build_dir --target project &> $build_dir/bitgen.log"
copy_cmd="cp -v $top_file $build_dir/libstf_config_0/user_c0_0/hdl/vfpga_top.svh >> $build_dir/bitgen.log 2>&1"
bitgen_cmd="cmake --build $build_dir --target bitgen &>> $build_dir/bitgen.log"

tmux new-session -d -s "libstf-$(basename "$build_dir")" "$project_cmd && $copy_cmd && $bitgen_cmd"
echo "Synthesis running in tmux session libstf-$(basename "$build_dir") (log: $build_dir/bitgen.log)"
