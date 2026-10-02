import libstf::*;

`include "libstf_macros.svh"

interface valid_i #(
    parameter type data_t
) (
    input logic clk,
    input logic rst_n
);
    data_t data;
    logic  valid;

    task tie_off_m(); // Tie off unused slave signals
        data = '0;
        valid = 1'b0;
    endtask

    modport m (
        import tie_off_m,
        output data, valid
    );

    modport s (
        input data, valid
    );

`ifndef SYNTHESIS
    `STF_ASSERT_NOT_UNDEFINED(valid)
`endif

endinterface

interface ready_valid_i #(
    parameter type data_t
) (
    input logic clk,
    input logic rst_n
);
    data_t data;
    logic  valid;
    logic  ready;

    task tie_off_m(); // Tie off unused slave signals
        data  = '0;
        valid = 1'b0;
    endtask

    task tie_off_s(); // Tie off unused master signals
        ready = 1'b0;
    endtask

    modport m (
        import tie_off_m,
        input  ready,
        output data, valid
    );

    modport s (
        import tie_off_s,
        input  data, valid,
        output ready
    );

`ifndef SYNTHESIS
    `STF_ASSERT_STABLE(data, valid, ready)
    `STF_ASSERT_NOT_UNDEFINED(valid)
    `STF_ASSERT_NOT_UNDEFINED(ready)
`endif

endinterface

interface data_i #(
    parameter type data_t
) (
    input logic clk,
    input logic rst_n
);
    data_t data;
    logic  keep;
    logic  last;
    logic  valid;
    logic  ready;

    task tie_off_m(); // Tie off unused slave signals
        data  = '0;
        keep  = 1'b0;
        last  = 1'b0;
        valid = 1'b0;
    endtask

    task tie_off_s(); // Tie off unused master signals
        ready = 1'b0;
    endtask

    modport m (
        import tie_off_m,
        input  ready,
        output data, keep, last, valid
    );

    modport s (
        import tie_off_s,
        input  data, keep, last, valid,
        output ready
    );

`ifndef SYNTHESIS
    `STF_ASSERT_SIGNAL_STABLE(data)
    `STF_ASSERT_SIGNAL_STABLE(keep)
    `STF_ASSERT_SIGNAL_STABLE(last)
    `STF_ASSERT_NOT_UNDEFINED(valid)
    `STF_ASSERT_NOT_UNDEFINED(ready)
`endif

endinterface

interface ndata_i #(
    parameter type data_t,
    parameter NUM_ELEMENTS
) (
    input logic clk,
    input logic rst_n
);
    data_t[NUM_ELEMENTS - 1:0] data;
    logic[NUM_ELEMENTS - 1:0]  keep;
    logic                      last;
    logic                      valid;
    logic                      ready;

    task tie_off_m(); // Tie off unused slave signals
        data  = '0;
        keep  = '0;
        last  = 1'b0;
        valid = 1'b0;
    endtask

    task tie_off_s(); // Tie off unused master signals
        ready = 1'b0;
    endtask

    modport m (
        import tie_off_m,
        input  ready,
        output data, keep, last, valid
    );

    modport s (
        import tie_off_s,
        input  data, keep, last, valid,
        output ready
    );

`ifndef SYNTHESIS
    `STF_ASSERT_SIGNAL_STABLE(data)
    `STF_ASSERT_SIGNAL_STABLE(keep)
    `STF_ASSERT_SIGNAL_STABLE(last)
    `STF_ASSERT_NOT_UNDEFINED(valid)
    `STF_ASSERT_NOT_UNDEFINED(ready)
`endif

endinterface

interface tagged_i #(
    parameter type data_t,
    parameter TAG_WIDTH
) (
    input logic clk,
    input logic rst_n
);
    data_t                 data;
    logic[TAG_WIDTH - 1:0] tag;
    logic                  keep;
    logic                  last;
    logic                  valid;
    logic                  ready;

    task tie_off_m(); // Tie off unused slave signals
        data  = '0;
        tag   = '0;
        keep  = 1'b0;
        last  = 1'b0;
        valid = 1'b0;
    endtask

    task tie_off_s(); // Tie off unused master signals
        ready = 1'b0;
    endtask

    modport m (
        import tie_off_m,
        input  ready,
        output data, tag, keep, last, valid
    );

    modport s (
        import tie_off_s,
        input  data, tag, keep, last, valid,
        output ready
    );

`ifndef SYNTHESIS
    `STF_ASSERT_SIGNAL_STABLE(data)
    `STF_ASSERT_SIGNAL_STABLE(tag)
    `STF_ASSERT_SIGNAL_STABLE(keep)
    `STF_ASSERT_SIGNAL_STABLE(last)
    `STF_ASSERT_NOT_UNDEFINED(valid)
    `STF_ASSERT_NOT_UNDEFINED(ready)
`endif

endinterface

interface ntagged_i #(
    parameter type data_t,
    parameter TAG_WIDTH,
    parameter NUM_ELEMENTS
) (
    input logic clk,
    input logic rst_n
);
    typedef logic[TAG_WIDTH - 1:0] tag_t;

    data_t[NUM_ELEMENTS - 1:0] data;
    tag_t[NUM_ELEMENTS - 1:0]  tag;
    logic[NUM_ELEMENTS - 1:0]  keep;
    logic                      last;
    logic                      valid;
    logic                      ready;

    task tie_off_m(); // Tie off unused slave signals
        data  = '0;
        tag   = '0;
        keep  = '0;
        last  = 1'b0;
        valid = 1'b0;
    endtask

    task tie_off_s(); // Tie off unused master signals
        ready = 1'b0;
    endtask

    modport m (
        import tie_off_m,
        input  ready,
        output data, tag, keep, last, valid
    );

    modport s (
        import tie_off_s,
        input  data, tag, keep, last, valid,
        output ready
    );

`ifndef SYNTHESIS
    `STF_ASSERT_SIGNAL_STABLE(data)
    `STF_ASSERT_SIGNAL_STABLE(tag)
    `STF_ASSERT_SIGNAL_STABLE(keep)
    `STF_ASSERT_SIGNAL_STABLE(last)
    `STF_ASSERT_NOT_UNDEFINED(valid)
    `STF_ASSERT_NOT_UNDEFINED(ready)
`endif

endinterface

interface typed_ndata_i #(
    parameter NUM_ELEMENTS,
    parameter type data_t = data8_t
) (
    input logic clk,
    input logic rst_n
);
    data_t[NUM_ELEMENTS - 1:0] data;
    type_t                       typ; // Type cannot be used as it's a keyword in SystemVerilog
    logic[NUM_ELEMENTS - 1:0]   keep;
    logic                        last;
    logic                        valid;
    logic                        ready;

    task tie_off_m(); // Tie off unused slave signals
        data  = '0;
        typ   = BYTE_T;
        keep  = '0;
        last  = 1'b0;
        valid = 1'b0;
    endtask

    task tie_off_s(); // Tie off unused master signals
        ready = 1'b0;
    endtask

    modport m (
        import tie_off_m,
        input  ready,
        output data, typ, keep, last, valid
    );

    modport s (
        import tie_off_s,
        input  data, typ, keep, last, valid,
        output ready
    );

`ifndef SYNTHESIS
    `STF_ASSERT_SIGNAL_STABLE(data)
    `STF_ASSERT_SIGNAL_STABLE(typ)
    `STF_ASSERT_SIGNAL_STABLE(keep)
    `STF_ASSERT_SIGNAL_STABLE(last)
    `STF_ASSERT_NOT_UNDEFINED(valid)
    `STF_ASSERT_NOT_UNDEFINED(ready)
`endif

endinterface
