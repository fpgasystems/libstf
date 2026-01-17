`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * The Coupler combines individual, decoupled data streams into one ndata stream.
 * It waits until the valid signals of all incoming streams are high before it passes on the next 
 * data beat.
 */
module Coupler #(
    parameter NUM_ELEMENTS,
    parameter MAX_IN_TRANSIT,
    parameter ENABLE_SKID_BUFFER = 1
) (
    input logic clk,
    input logic rst_n,

    valid_i.s mask, // logic[NUM_ELEMENTS:0] -> NUM_ELEMENTS keep bits and one last bit

    data_i.s  in[NUM_ELEMENTS], // #(data_t)
    ndata_i.m out               // #(data_t, NUM_ELEMENTS)
);

localparam type data_t = out.data_t;

typedef struct packed {
    logic[NUM_ELEMENTS - 1:0] keep;
    logic                     last;
} mask_t;

logic[NUM_ELEMENTS - 1:0] in_valid;
logic                     data_beat_complete;

ready_valid_i #(mask_t) curr_mask();

ndata_i #(data_t, NUM_ELEMENTS) internal();

FIFO #(
    .DEPTH(MAX_IN_TRANSIT),
    .WIDTH(NUM_ELEMENTS + 1)
) inst_mask_fifo (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data(mask.data),
    .i_valid(mask.valid),
    .i_ready(),

    .o_data(curr_mask.data),
    .o_valid(curr_mask.valid),
    .o_ready(curr_mask.ready),

    .o_filling_level()
);

assign curr_mask.ready = data_beat_complete && internal.ready;
assign data_beat_complete = curr_mask.valid && (in_valid & curr_mask.data.keep) == curr_mask.data.keep;

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign in_valid[I] = in[I].valid;
end

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign in[I].ready = curr_mask.data.keep[I] && curr_mask.ready;

    assign internal.data[I] = in[I].data;
    assign internal.keep[I] = curr_mask.data.keep[I] ? in[I].keep : 1'b0;
end

assign internal.last  = curr_mask.data.last;
assign internal.valid = data_beat_complete;

generate if (ENABLE_SKID_BUFFER) begin
    NDataSkidBuffer #(data_t, NUM_ELEMENTS) inst_skid_buffer (.clk(clk), .rst_n(rst_n), .in(internal), .out(out));
end else begin
    `DATA_ASSIGN(internal, out)
end endgenerate

endmodule
