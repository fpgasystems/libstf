`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * The Coupler combines individual, decoupled data streams into one ndata stream.
 * It waits until the valid signals of all incoming streams are high before it passes on the next
 * data beat.
 */
module Coupler #(
    parameter type data_t, // the data type of the inputs
    parameter int NUM_ELEMENTS,
    parameter int MAX_IN_TRANSIT,
    parameter int EN_SKID_BUFFER = 1
) (
    input logic clk,
    input logic rst_n,

    // NUM_ELEMENTS keep bits and one last bit
    valid_i.s mask, // #(logic[NUM_ELEMENTS:0])

    data_i.s  in[NUM_ELEMENTS], // #(data_t)
    ndata_i.m out               // #(data_t, NUM_ELEMENTS)
);

`ASSERT_ELAB(NUM_ELEMENTS == out.NUM_ELEMENTS)

typedef struct packed {
    logic[NUM_ELEMENTS - 1:0] keep;
    logic                     last;
} mask_t;

logic[NUM_ELEMENTS - 1:0] in_valid;
logic                     data_beat_complete;

ready_valid_i #(mask_t)               fifo_mask(clk, rst_n), curr_mask(clk, rst_n);
ndata_i       #(data_t, NUM_ELEMENTS) internal(clk, rst_n);

MehdiFIFO #(
    .DEPTH(MAX_IN_TRANSIT),
    .WIDTH(NUM_ELEMENTS + 1)
) inst_mask_fifo (
    .clk(clk),
    .rst_n(rst_n),

    .in_data(mask.data),
    .in_valid(mask.valid),
    .in_ready(),

    .out_data(fifo_mask.data),
    .out_valid(fifo_mask.valid),
    .out_ready(fifo_mask.ready),

    .filling_level()
);

SkidBuffer #(mask_t) inst_mask_skid_buffer (
    .clk(clk),
    .rst_n(rst_n),

    .in(fifo_mask),
    .out(curr_mask)
);

assign curr_mask.ready = data_beat_complete && internal.ready;
assign data_beat_complete = curr_mask.valid &&
                            (in_valid & curr_mask.data.keep) == curr_mask.data.keep;

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin : gen_in_valid
    assign in_valid[I] = in[I].valid;
end

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin : gen_lanes
    assign in[I].ready = curr_mask.data.keep[I] && curr_mask.ready;

    assign internal.data[I] = in[I].data;
    assign internal.keep[I] = curr_mask.data.keep[I] ? in[I].keep : 1'b0;
end

assign internal.last  = curr_mask.data.last;
assign internal.valid = data_beat_complete;

generate if (EN_SKID_BUFFER) begin : gen_skid_buffer
    NDataSkidBuffer #(data_t, NUM_ELEMENTS) inst_skid_buffer (
        .clk(clk),
        .rst_n(rst_n),

        .in(internal),
        .out(out)
    );
end else begin : gen_no_skid_buffer
    `DATA_ASSIGN(internal, out)
end endgenerate

endmodule
