`timescale 1ns / 1ps

import libstf::*;

/**
 * Converts a NUM_ELEMENTS ndata stream containing 32bit or 64bit elements to a 64 * NUM_ELEMENTS 
 * AXI stream. Use this in cases where you want to have a fixed number of elements in the stream,
 * but the width of the elements in the AXI stream may differ.
 */
module NDataToAXITyped #(
    parameter NUM_ELEMENTS
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s out_type, // #(type_t)

    ndata_i.s in, // #(data_t, NUM_ELEMENTS)
    AXI4S.m   out // #(AXI_WIDTH)
);

localparam DATA_WIDTH = 64;
localparam AXI_WIDTH = DATA_WIDTH * NUM_ELEMENTS;

typedef logic[AXI_WIDTH / 8 - 1:0] keep_t;

// -- Signals --------------------------------------------------------------------------------------
logic is_upper, n_is_upper;
logic is_32bit;
logic both_valid;

logic[AXI_WIDTH / 2 - 1:0]  data_32bit;
logic[AXI_WIDTH / 16 - 1:0] keep_32bit;
keep_t keep_64bit;

logic[AXI_WIDTH - 1:0] data, n_data;
keep_t keep,  n_keep;
logic  last,  n_last;
logic  valid, n_valid;

// -- Assertions -----------------------------------------------------------------------------------
`ifndef SYNTHESIS
assert property (@(posedge clk) disable iff (!rst_n) !out_type.valid || GET_TYPE_WIDTH(out_type.data) == 32 || GET_TYPE_WIDTH(out_type.data) == 64)
else $fatal(1, "Type width %0d is not supported!", GET_TYPE_WIDTH(out_type.data));
`endif

// -- Logic ----------------------------------------------------------------------------------------
assign is_32bit = GET_TYPE_WIDTH(out_type.data) == 32;
assign both_valid = out_type.valid && in.valid;

assign out_type.ready = in.valid && in.last && out.tready;

assign in.ready = out_type.valid && out.tready;

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign data_32bit[32 * I+:32] = in.data[I][0+:32];

    for (genvar J = 0; J < 4; J++) begin
        assign keep_32bit[I * 4 + J] = in.keep[I];
    end
    for (genvar J = 0; J < 8; J++) begin
        assign keep_64bit[I * 8 + J] = in.keep[I];
    end
end

always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        is_upper <= 1'b0;

        valid <= 1'b0;
    end else begin
        is_upper <= n_is_upper;

        data  <= n_data;
        keep  <= n_keep;
        last  <= n_last;
        valid <= n_valid;
    end
end

always_comb begin
    n_is_upper = is_upper;

    n_data  = data;
    n_keep  = keep;
    n_last  = last;
    n_valid = 1'b0;

    if (out.tready) begin
        if (both_valid) begin
            if (!in.last) begin
                n_is_upper = ~is_upper;
            end else begin
                n_is_upper = 1'b0;
            end
        end

        if (is_32bit) begin
            if (is_upper == 1'b0) begin // lower
                n_data[AXI_WIDTH / 2 - 1:0]              = data_32bit;
                n_keep[AXI_WIDTH / 8 - 1:AXI_WIDTH / 16] = '0;
                n_keep[AXI_WIDTH / 16 - 1:0]             = keep_32bit;

                if (in.last) begin
                    n_valid = both_valid;
                end
            end else begin // upper
                n_data[AXI_WIDTH - 1:AXI_WIDTH / 2]      = data_32bit;
                n_keep[AXI_WIDTH / 8 - 1:AXI_WIDTH / 16] = keep_32bit;
                n_valid = both_valid;
            end
        end else begin
            n_data  = in.data;
            n_keep  = keep_64bit;
            n_valid = both_valid;
        end

        n_last = in.last;
    end else begin
        n_valid = valid;
    end
end

assign out.tdata  = data;
assign out.tkeep  = keep;
assign out.tlast  = last;
assign out.tvalid = valid;

endmodule

/**
 * Converts an 64 * NUM_ELEMENTS AXI stream containing 32bit or 64bit elements to a NUM_ELEMENTS 
 * ndata stream. Use this in cases where you want to have a fixed number of elements in the stream,
 * but the width of the elements in the AXI stream may differ.
 */
module AXIToNDataTyped #(
    parameter NUM_ELEMENTS
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s in_type, // #(type_t)

    AXI4S.s   in,   // #(AXI_WIDTH)
    ndata_i.m out // #(data_t, NUM_ELEMENTS)
);

localparam DATA_WIDTH = 64;
localparam AXI_WIDTH = DATA_WIDTH * NUM_ELEMENTS;

logic is_upper;
logic is_32bit;
logic actual_ready;

data64_t[NUM_ELEMENTS - 1:0] data_32bit;
logic[NUM_ELEMENTS - 1:0]    keep_32bit, keep_64bit;

// -- Assertions -----------------------------------------------------------------------------------
assert property (@(posedge clk) disable iff (!rst_n) !in_type.valid || GET_TYPE_WIDTH(in_type.data) == 32 || GET_TYPE_WIDTH(in_type.data) == 64)
else $fatal(1, "Type width %0d is not supported!", GET_TYPE_WIDTH(in_type.data));

assign is_32bit = GET_TYPE_WIDTH(in_type.data) == 32;
assign actual_ready = is_32bit ? out.ready && is_upper == 1'b1 : out.ready;
assign in_type.ready = in.tvalid && in.tlast && actual_ready;

assign in.tready = in_type.valid && actual_ready;

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign data_32bit[I][0+:32] = is_upper == 1'b0 ? in.tdata[32 * I+:32] : in.tdata[32 * I + AXI_WIDTH / 2+:32];
    assign data_32bit[I][32+:32] = '0;

    assign keep_32bit[I] = is_upper == 1'b0 ? in.tkeep[I * 4] : in.tkeep[I * 4 + AXI_WIDTH / 16];
    assign keep_64bit[I] = in.tkeep[I * 8];
end

always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        is_upper <= 1'b0;
    end else begin
        if (in_type.valid && in.tvalid && out.ready) begin
            is_upper <= ~is_upper;
        end
    end
end

assign out.data  = is_32bit ? data_32bit : in.tdata;
assign out.keep  = is_32bit ? keep_32bit : keep_64bit;
assign out.last  = is_32bit ? in.tlast && is_upper == 1'b1 : in.tlast;
assign out.valid = in_type.valid && in.tvalid;

endmodule

/**
 * Converts an data8_t ndata stream to a typed ndata stream.
 */
module NDataToTypedNData #(
    parameter DATABEAT_SIZE
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s in_type,     // #(type_t)
    ndata_i in,                  // #(data8_t, DATABEAT_SIZE)

    typed_ndata_i.m out          // #(DATABEAT_SIZE)
);

valid_i #(type_t) keep_type ();
always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        keep_type.valid <= 0;
    end else begin
        if (in_type.ready && in_type.valid) begin
            keep_type.valid <= 1;
            keep_type.data <= in_type.data;
        end

        if (out.ready && out.valid && out.last) begin
            keep_type.valid <= 0;
        end
    end
end

valid_i #(type_t) typ ();
always_comb begin
    if (keep_type.valid) begin
        typ.valid = keep_type.valid;
        typ.data = keep_type.data;
    end else if (in_type.ready && in_type.valid) begin
        typ.valid = 1;
        typ.data = in_type.data;
    end else begin
        typ.valid = 0;
    end
end

assign in_type.ready = ~keep_type.valid;
assign in.ready = typ.valid && out.ready; // ready chaining

for (genvar I = 0; I < DATABEAT_SIZE; I++) begin
    assign out.data[I] = in.data[I];
    assign out.keep[I] = in.keep[I];
end

assign out.last  = in.last;
assign out.valid = typ.valid && in.valid;
assign out.typ = typ.data;

endmodule

/**
 * Converts an AXI stream to a typed ndata stream.
 */
module AXIToTypedNData #(
    parameter DATABEAT_SIZE,
    parameter AXI_WIDTH = DATABEAT_SIZE * 8
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s in_type,     // #(type_t)
    AXI4S.s in,                  // #(AXI_WIDTH)

    typed_ndata_i.m out          // #(DATABEAT_SIZE)
);

ndata_i #(data8_t, DATABEAT_SIZE) inner ();

AXIToNData #(
    .data_t(data8_t),
    .NUM_ELEMENTS(DATABEAT_SIZE),
    .AXI_WIDTH(AXI_WIDTH)
) inst_axi_to_ndata (
    .clk(clk),
    .rst_n(rst_n),

    .in(in),
    .out(inner)
);

NDataToTypedNData #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_ndata_to_typed_ndata (
    .clk(clk),
    .rst_n(rst_n),

    .in_type(in_type),
    .in(inner),

    .out(out)
);

endmodule

/**
 * Converts a typed ndata stream into an AXI stream.
 */
module TypedNDataToAXI #(
    parameter DATABEAT_SIZE,
    parameter AXI_WIDTH = DATABEAT_SIZE * 8
) (
    input logic clk,
    input logic rst_n,

    typed_ndata_i.s in,         // #(DATABEAT_SIZE)

    AXI4S.m out                 // #(AXI_WIDTH)
);

ndata_i #(data8_t, DATABEAT_SIZE) inner ();

// Discard the typ field on the typed_ndata_i.
// After that, typed_ndata_i is the same as ndata_i.
`DATA_ASSIGN(in, inner)

NDataToAXI #(
    .data_t(data8_t),
    .NUM_ELEMENTS(DATABEAT_SIZE),
    .AXI_WIDTH(AXI_WIDTH)
) inst_axi_to_ndata (
    .clk(clk),
    .rst_n(rst_n),

    .in(inner),
    .out(out)
);

endmodule
