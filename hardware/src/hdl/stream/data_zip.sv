`timescale 1ns / 1ps

// Turns two ndata streams into one stream of pairs of values, 
// interleaving left and right elements.
module NDataZip #(
    parameter type left_t,
    parameter type right_t,
    parameter NUM_ELEMENTS
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s left_in, // #(left_t, NUM_ELEMENTS)
    ndata_i.s right_in, // #(right_t, NUM_ELEMENTS)

    ndata_i.m out // #((left_t, right_t), NUM_ELEMENTS)
);

typedef struct packed {
    left_t left;
    right_t right;
} zipped_t;

zipped_t[NUM_ELEMENTS - 1:0] out_data;

always_comb out.valid = left_in.valid & right_in.valid;

always_comb left_in.ready = out.valid & out.ready;
always_comb right_in.ready = out.valid & out.ready;

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin 
    assign out_data[I].left = left_in.data[I];
    assign out_data[I].right = right_in.data[I];

    assign out.data[I] = out_data[I];
end

assign out.keep = left_in.keep & right_in.keep;
// NOTE: Edge case if not same length?
assign out.last = left_in.last & right_in.last;

endmodule
