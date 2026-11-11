# libSTF

Follow the code style in [CODING_STYLE.md](../CODING_STYLE.md):

@../CODING_STYLE.md

## Linting
Before every commit that touches SystemVerilog files, stage the changed files and run
`scripts/lint.sh`. Fix every violation in the lines you added or changed before committing. If
`verible-verilog-lint` is missing, install it with `scripts/install_verible.sh`.
