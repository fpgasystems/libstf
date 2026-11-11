`timescale 1ns / 1ps

`include "libstf_macros.svh"

module Duplicate #(
    parameter type data_t,
    parameter int NUM_ELEMENTS,
    parameter int MAX_IN_TRANSIT,
    parameter int EN_SKID_BUFFER = 1
) (
    input logic clk,
    input logic rst_n,

    duplicate_i.s mask,  // #(NUM_ELEMENTS)

    ndata_i.s in,    // #(data_t, NUM_ELEMENTS)
    ndata_i.m out    // #(data_t, NUM_ELEMENTS)
);

`ASSERT_ELAB(NUM_ELEMENTS == in.NUM_ELEMENTS)

duplicate_i #(NUM_ELEMENTS)         curr_mask();
ndata_i     #(data_t, NUM_ELEMENTS) data(clk, rst_n), n_data(clk, rst_n);

MehdiFIFO #(
    .DEPTH(MAX_IN_TRANSIT),
    .WIDTH(NUM_ELEMENTS + NUM_ELEMENTS * $clog2(NUM_ELEMENTS))
) inst_mask_fifo (
    .clk(clk),
    .rst_n(rst_n),
    .in_data({mask.duplicates, mask.origins}),
    .in_valid(mask.valid),
    .in_ready(),
    .out_data({curr_mask.duplicates, curr_mask.origins}),
    .out_valid(curr_mask.valid),
    .out_ready(in.valid && data.ready),
    .filling_level()
);

assign in.ready = data.ready & curr_mask.valid;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        data.data  <= 'X;
        data.keep  <= 'X;
        data.last  <= 'X;
        data.valid <= 1'b0;
    end else begin
        data.data  <= n_data.data;
        data.keep  <= n_data.keep;
        data.last  <= n_data.last;
        data.valid <= n_data.valid;
    end
end

always_comb begin
    n_data.data  = data.data;
    n_data.keep  = data.keep;
    n_data.last  = data.last;
    n_data.valid = data.valid;

    if (in.valid && in.ready) begin
        n_data.data  = in.data;
        n_data.keep  = in.keep;
        n_data.last  = in.last;
        n_data.valid = 1'b1;

        for (int unsigned i = 0; i < NUM_ELEMENTS; i++) begin
            if (curr_mask.duplicates[i]) begin
                n_data.data[i] = in.data[curr_mask.origins[i]];
                n_data.keep[i] = 1'b1;
            end
        end
    end else if (data.ready) begin
        n_data.valid = 1'b0;
    end
end

// Assign ready to silence assertion that ready cannot be undefined. Needs to be high so we do not
// get in trouble with the stable assertion of the interface.
assign n_data.ready = 1'b1;

generate if (EN_SKID_BUFFER) begin : gen_skid_buffer
    NDataSkidBuffer #(data_t, NUM_ELEMENTS) inst_skid_buffer (
        .clk(clk),
        .rst_n(rst_n),

        .in(data),
        .out(out)
    );
end else begin : gen_no_skid_buffer
    `DATA_ASSIGN(data, out)
end endgenerate

endmodule
