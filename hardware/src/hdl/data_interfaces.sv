import libstf::*;

interface valid_i #(
    parameter type data_t
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
endinterface

interface ready_valid_i #(
    parameter type data_t
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
endinterface

interface data_i #(
    parameter type data_t
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
endinterface

interface ndata_i #(
    parameter type data_t,
    parameter NUM_ELEMENTS
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
endinterface

interface tagged_i #(
    parameter type data_t,
    parameter TAG_WIDTH
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
endinterface

interface ntagged_i #(
    parameter type data_t,
    parameter TAG_WIDTH,
    parameter NUM_ELEMENTS
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
endinterface

interface typed_ndata_i #(
    parameter DATABEAT_SIZE
);
    data8_t[DATABEAT_SIZE - 1:0] data;
    type_t                       typ; // Type cannot be used as it's a keyword in SystemVerilog
    logic[DATABEAT_SIZE - 1:0]   keep;
    logic                        last;
    logic                        valid;
    logic                        ready;

    task tie_off_m(); // Tie off unused slave signals
        data  = '0;
        typ   = '0;
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
endinterface
