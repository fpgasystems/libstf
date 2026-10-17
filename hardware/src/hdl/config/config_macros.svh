`ifndef LIBSTF_CONFIG_MACROS_SVH
`define LIBSTF_CONFIG_MACROS_SVH

`define CONFIG_INTF_TO_SIGNALS(INTF, SIGNALS) \
    assign ``SIGNALS``_data  = INTF.data;     \
    assign ``SIGNALS``_valid = INTF.valid;    \
    assign INTF.ready    = ``SIGNALS``_ready;

`define CONFIG_SIGNALS_TO_INTF(SIGNALS, INTF) \
    assign INTF.data     = ``SIGNALS``_data;  \
    assign INTF.valid    = ``SIGNALS``_valid; \
    assign ``SIGNALS``_ready = INTF.ready;

`endif
