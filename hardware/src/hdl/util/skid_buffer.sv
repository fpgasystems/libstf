`timescale 1ns / 1ps

module SkidBuffer #(
    parameter type data_t
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s in, // #(data_t)
    ready_valid_i.m out // #(data_t) 
);

ready_valid_i #(data_t) tmp(), over();

always_ff @(posedge clk) begin
    if (!rst_n) begin
        tmp.valid  <= 1'b0;
        over.valid <= 1'b0;
    end else begin
        if (in.ready) begin
            tmp.data  <= in.data;
            tmp.valid <= in.valid;
        end

        if (!over.valid) begin
            over.data <= tmp.data;

            if(~out.ready) begin
                over.valid <= tmp.valid;
            end
        end

        if(out.ready) begin
            over.valid <= 1'b0;
        end
    end     
end

assign in.ready = !tmp.valid || !over.valid;

assign out.data  = over.valid ? over.data : tmp.data;
assign out.valid = tmp.valid || over.valid;

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

ready_valid_i #(tmp_t) skid_in(), skid_out();

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
    parameter type data_t,
    parameter NUM_ELEMENTS
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in, // #(data_t, NUM_ELEMENTS) 
    ndata_i.m out // #(data_t, NUM_ELEMENTS)
);

typedef struct packed {
    data_t[NUM_ELEMENTS - 1:0] data;
    logic[NUM_ELEMENTS - 1:0]  keep;
    logic                      last;
} tmp_t;

ready_valid_i #(tmp_t) skid_in(), skid_out();

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
    parameter TAG_WIDTH
) (
    input logic clk,
    input logic rst_n,

    tagged_i.s in, // #(data_t, TAG_WIDTH)
    tagged_i.m out // #(data_t, TAG_WIDTH)
);

typedef struct packed {
    data_t                 data;
    logic[TAG_WIDTH - 1:0] tag;
} tmp_t;

data_i #(tmp_t) data_in();
data_i #(tmp_t) data_out();

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

module AXISkidBuffer #(
    parameter AXI4S_DATA_BITS = AXI_DATA_BITS
) (
    input logic clk,
    input logic rst_n,

    AXI4S.s in, // #(AXI4S_DATA_BITS) 
    AXI4S.m out // #(AXI4S_DATA_BITS) 
);

typedef struct packed {
    logic[AXI4S_DATA_BITS - 1:0]     tdata;
    logic[AXI4S_DATA_BITS / 8 - 1:0] tkeep;
    logic                            tlast;
} tmp_t;

ready_valid_i #(tmp_t) skid_in(), skid_out();

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
