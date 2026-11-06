`timescale 1ns / 1ps

module SkidBuffer #(
    parameter type data_t
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s in, // #(data_t)
    ready_valid_i.m out // #(data_t) 
);

ready_valid_i #(data_t) head(clk, rst_n);

// The enables of the head and skid data are replicated because they reach every data bit
data_t                skid_data;
(* max_fanout = 64 *) logic skid_valid;
(* max_fanout = 64 *) logic head_load;

assign head_load = !head.valid || out.ready;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        head.data  <= 'X;
        head.valid <= 1'b0;

        skid_data  <= 'X;
        skid_valid <= 1'b0;
    end else begin
        if (head_load) begin
            head.data  <= skid_valid ? skid_data : in.data;
            head.valid <= skid_valid || in.valid;
        end

        if (in.ready) begin
            skid_data  <= in.data;
            skid_valid <= in.valid && head.valid && !out.ready;
        end else if (out.ready) begin
            skid_valid <= 1'b0;
        end
    end
end

// Assign ready to silence assertion that ready cannot be undefined. Needs to be high so we do not 
// get in trouble with with stable assertion of the interface.
assign head.ready = 1'b1;

assign in.ready = !skid_valid;

assign out.data  = head.data;
assign out.valid = head.valid;

endmodule

module DataSkidBuffer #(
    parameter type data_t
) (
    input logic clk,
    input logic rst_n,

    data_i.s in, // #(data_t) 
    data_i.m out // #(data_t) 
);

typedef struct packed {
    data_t data;
    logic  keep;
    logic  last;
} tmp_t;

ready_valid_i #(tmp_t) skid_in(clk, rst_n), skid_out(clk, rst_n);

assign skid_in.data.data = in.data;
assign skid_in.data.keep = in.keep;
assign skid_in.data.last = in.last;
assign skid_in.valid     = in.valid;
assign in.ready          = skid_in.ready;

SkidBuffer #(
    .data_t(tmp_t)
) inst_skid_buffer (
    .clk(clk),
    .rst_n(rst_n),
    
    .in(skid_in),
    .out(skid_out)
);

assign out.data       = skid_out.data.data;
assign out.keep       = skid_out.data.keep;
assign out.last       = skid_out.data.last;
assign out.valid      = skid_out.valid;
assign skid_out.ready = out.ready;

endmodule

module NDataSkidBuffer #(
    parameter type data_t
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in, // #(data_t, NUM_ELEMENTS) 
    ndata_i.m out // #(data_t, NUM_ELEMENTS)
);

localparam int NUM_ELEMENTS = in.NUM_ELEMENTS;

typedef struct packed {
    data_t[NUM_ELEMENTS - 1:0] data;
    logic[NUM_ELEMENTS - 1:0]  keep;
    logic                      last;
} tmp_t;

ready_valid_i #(tmp_t) skid_in(clk, rst_n), skid_out(clk, rst_n);

assign skid_in.data.data = in.data;
assign skid_in.data.keep = in.keep;
assign skid_in.data.last = in.last;
assign skid_in.valid     = in.valid;
assign in.ready          = skid_in.ready;

SkidBuffer #(
    .data_t(tmp_t)
) inst_skid_buffer (
    .clk(clk),
    .rst_n(rst_n),

    .in(skid_in),
    .out(skid_out)
);

assign out.data       = skid_out.data.data;
assign out.keep       = skid_out.data.keep;
assign out.last       = skid_out.data.last;
assign out.valid      = skid_out.valid;
assign skid_out.ready = out.ready;

endmodule

module TaggedSkidBuffer #(
    parameter type data_t,
    parameter type tag_t
) (
    input logic clk,
    input logic rst_n,

    tagged_i.s in, // #(data_t, tag_t)
    tagged_i.m out // #(data_t, tag_t)
);

typedef struct packed {
    data_t data;
    tag_t  tag;
} tmp_t;

data_i #(tmp_t) data_in(clk, rst_n), data_out(clk, rst_n);

assign data_in.data.data = in.data;
assign data_in.data.tag  = in.tag;
assign data_in.keep      = in.keep;
assign data_in.last      = in.last;
assign data_in.valid     = in.valid;
assign in.ready = data_in.ready;

DataSkidBuffer #(
    .data_t(tmp_t)
) inst_skid_buffer (
    .clk(clk),
    .rst_n(rst_n),

    .in(data_in),
    .out(data_out)
);

assign out.data  = data_out.data.data;
assign out.tag   = data_out.data.tag;
assign out.keep  = data_out.keep;
assign out.last  = data_out.last;
assign out.valid = data_out.valid;
assign data_out.ready = out.ready;

endmodule

module NTaggedSkidBuffer #(
    parameter type data_t,
    parameter type tag_t
) (
    input logic clk,
    input logic rst_n,

    ntagged_i.s in, // #(data_t, tag_t, NUM_ELEMENTS)
    ntagged_i.m out // #(data_t, tag_t, NUM_ELEMENTS)
);

localparam int NUM_ELEMENTS = in.NUM_ELEMENTS;

typedef struct packed {
    data_t[NUM_ELEMENTS - 1:0] data;
    tag_t[NUM_ELEMENTS - 1:0]  tag;
    logic[NUM_ELEMENTS - 1:0]  keep;
    logic                      last;
} tmp_t;

ready_valid_i #(tmp_t) skid_in(clk, rst_n), skid_out(clk, rst_n);

assign skid_in.data.data = in.data;
assign skid_in.data.tag  = in.tag;
assign skid_in.data.keep = in.keep;
assign skid_in.data.last = in.last;
assign skid_in.valid     = in.valid;
assign in.ready          = skid_in.ready;

SkidBuffer #(
    .data_t(tmp_t)
) inst_skid_buffer (
    .clk(clk),
    .rst_n(rst_n),

    .in(skid_in),
    .out(skid_out)
);

assign out.data       = skid_out.data.data;
assign out.tag        = skid_out.data.tag;
assign out.keep       = skid_out.data.keep;
assign out.last       = skid_out.data.last;
assign out.valid      = skid_out.valid;
assign skid_out.ready = out.ready;

endmodule

module AXISkidBuffer (
    input logic clk,
    input logic rst_n,

    AXI4S.s in, // #(AXI4S_DATA_BITS) 
    AXI4S.m out // #(AXI4S_DATA_BITS) 
);

localparam int AXI4S_DATA_BITS = in.AXI4S_DATA_BITS;

typedef struct packed {
    logic[AXI4S_DATA_BITS - 1:0]     tdata;
    logic[AXI4S_DATA_BITS / 8 - 1:0] tkeep;
    logic                            tlast;
} tmp_t;

ready_valid_i #(tmp_t) skid_in(clk, rst_n), skid_out(clk, rst_n);

assign skid_in.data.tdata = in.tdata;
assign skid_in.data.tkeep = in.tkeep;
assign skid_in.data.tlast = in.tlast;
assign skid_in.valid      = in.tvalid;
assign in.tready          = skid_in.ready;

SkidBuffer #(
    .data_t(tmp_t)
) inst_skid_buffer (
    .clk(clk),
    .rst_n(rst_n),
    
    .in(skid_in),
    .out(skid_out)
);

assign out.tdata       = skid_out.data.tdata;
assign out.tkeep       = skid_out.data.tkeep;
assign out.tlast       = skid_out.data.tlast;
assign out.tvalid      = skid_out.valid;
assign skid_out.ready = out.tready;

endmodule

module TypedNDataSkidBuffer
    import libstf::*;
(
    input logic clk,
    input logic rst_n,

    typed_ndata_i.s in, // #(DATABEAT_SIZE) 
    typed_ndata_i.m out // #(DATABEAT_SIZE)
);

localparam int DATABEAT_SIZE = in.DATABEAT_SIZE;

typedef struct packed {
    data8_t[DATABEAT_SIZE - 1:0] data;
    type_t                     typ;
    logic[DATABEAT_SIZE - 1:0]  keep;
    logic                      last;
} tmp_t;

ready_valid_i #(tmp_t) skid_in(clk, rst_n), skid_out(clk, rst_n);

assign skid_in.data.data = in.data;
assign skid_in.data.typ  = in.typ;
assign skid_in.data.keep = in.keep;
assign skid_in.data.last = in.last;
assign skid_in.valid     = in.valid;
assign in.ready          = skid_in.ready;

SkidBuffer #(
    .data_t(tmp_t)
) inst_skid_buffer (
    .clk(clk),
    .rst_n(rst_n),

    .in(skid_in),
    .out(skid_out)
);

assign out.data       = skid_out.data.data;
assign out.typ        = skid_out.data.typ;
assign out.keep       = skid_out.data.keep;
assign out.last       = skid_out.data.last;
assign out.valid      = skid_out.valid;
assign skid_out.ready = out.ready;

endmodule

module MetaIntfSkidBuffer #(
    parameter type STYPE = logic[63:0],
    parameter int NUM_STAGES = 1
) (
    input logic clk,
    input logic rst_n,

    metaIntf.s in, // #(STYPE)
    metaIntf.m out // #(STYPE)
);

ready_valid_i #(STYPE) stages[NUM_STAGES + 1](clk, rst_n);

assign stages[0].data  = in.data;
assign stages[0].valid = in.valid;
assign in.ready        = stages[0].ready;

for (genvar I = 0; I < NUM_STAGES; I++) begin
    SkidBuffer #(
        .data_t(STYPE)
    ) inst_skid_buffer (
        .clk(clk),
        .rst_n(rst_n),

        .in(stages[I]),
        .out(stages[I + 1])
    );
end

assign out.data                = stages[NUM_STAGES].data;
assign out.valid               = stages[NUM_STAGES].valid;
assign stages[NUM_STAGES].ready = out.ready;

endmodule
