`ifndef LIBSTF_LIBSTF_MACROS_SVH
`define LIBSTF_LIBSTF_MACROS_SVH

// This macro assumes that the clock and reset signals are clk and rst_n, respectively.
`define RESET_RESYNC            \
logic reset_synced;             \
ResetResync inst_reset_resync ( \
    .clk(clk),                  \
    .reset_in(rst_n),           \
    .reset_out(reset_synced)    \
);

`define ASSERT_ELAB(COND, MSG = "Assertion failed.") if (!(COND)) $error(MSG);

`define STF_STRINGIFY(x) $sformatf("%0s", `"x`")

`define STF_ASSERT_NOT_UNDEFINED(sig) \
assert property (@(posedge clk) disable iff (!rst_n) \
    !$isunknown(sig)) \
else $fatal(1, "Signal %s needs to not be undefined!", `STF_STRINGIFY(sig));

`define STF_ASSERT_STABLE(sig, sig_valid, sig_ready) \
assert property (@(posedge clk) disable iff (!rst_n) \
    sig_valid && !sig_ready |=> $stable(sig)) \
else $fatal(1, "Signal %s needs to be stable while valid && !ready!", `STF_STRINGIFY(sig));

`define STF_ASSERT_SIGNAL_STABLE(sig) `STF_ASSERT_STABLE(sig, valid, ready)

`define DATA_ASSIGN(s, m)         \
	assign m.data      = s.data;  \
	assign m.keep      = s.keep;  \
	assign m.last      = s.last;  \
	assign m.valid     = s.valid; \
	assign s.ready     = m.ready;

`define TAGGED_ASSIGN(s, m)       \
	assign m.data      = s.data;  \
    assign m.tag       = s.tag;   \
	assign m.keep      = s.keep;  \
	assign m.last      = s.last;  \
	assign m.valid     = s.valid; \
	assign s.ready     = m.ready;

`define READY_VALID_ASSIGN(s, m)  \
    assign m.data      = s.data;  \
    assign m.valid     = s.valid; \
    assign s.ready     = m.ready;

`endif
