#!/bin/bash
# Lints SystemVerilog files with Verible. Lints the given files or, without arguments, all staged
# .sv and .svh files of the git repository of the current directory. This also works from a
# repository that includes libSTF as a submodule, e.g., libstf/scripts/lint.sh.
#
# Uses the .rules.verible_lint and .waivers.verible_lint at the root of that repository if there are
# any and the libSTF ones otherwise.

libstf_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="$(git rev-parse --show-toplevel)"

rules_config="${repo_root}/.rules.verible_lint"
if [ ! -f "${rules_config}" ]; then
  rules_config="${libstf_root}/.rules.verible_lint"
fi

waivers="${repo_root}/.waivers.verible_lint"
if [ ! -f "${waivers}" ]; then
  waivers="${libstf_root}/.waivers.verible_lint"
fi

verible_lint="$(command -v verible-verilog-lint || echo "$HOME/opt/bin/verible-verilog-lint")"
if [ ! -x "${verible_lint}" ]; then
  echo "verible-verilog-lint not found. Install it with" \
    "${libstf_root}/scripts/install_verible.sh." >&2
  exit 1
fi

if [ $# -gt 0 ]; then
  files=("$@")
else
  mapfile -t files < <(git -C "${repo_root}" diff --cached --name-only --diff-filter=d \
    -- '*.sv' '*.svh' | sed "s|^|${repo_root}/|")
fi

if [ ${#files[@]} -eq 0 ]; then
  echo "No SystemVerilog files to lint."
  exit 0
fi

"${verible_lint}" --rules_config="${rules_config}" --waiver_files="${waivers}" \
  "${files[@]}"
status=$?

# Verible's line-length rule skips lines that only contain a comment, so check those here
max_length="$(sed -n 's/^+line-length=length:\([0-9]*\).*/\1/p' "${rules_config}")"
awk -v max="${max_length:-100}" '
  /^[ \t]*(\/\/|\/\*|\*)/ && length($0) > max {
    printf "%s:%d:%d: Comment line length exceeds max: %d; is: %d [line-length]\n",
      FILENAME, FNR, max + 1, max, length($0)
    found = 1
  }
  END { exit found }
' "${files[@]}" || status=1

exit ${status}
