`timescale 1ns / 1ps

module Duplicate #(
    parameter type data_t, 
    parameter NUM_ELEMENTS,
    parameter MAX_IN_TRANSIT,
    parameter ENABLE_SKID_BUFFER = 1
) (
    input logic clk,
    input logic rst_n,

    duplicate_i.s mask,  // #(NUM_ELEMENTS)

    ndata_i.s in,    // #(data_t, NUM_ELEMENTS)
    ndata_i.m out    // #(data_t, NUM_ELEMENTS)
);

duplicate_i #(NUM_ELEMENTS) curr_mask ();

ndata_i #(data_t, NUM_ELEMENTS) d (), q ();

FIFO #(
    .DEPTH(MAX_IN_TRANSIT),
    .WIDTH($bits(curr_mask.duplicates) + $bits(curr_mask.origins))
) inst_mask_fifo (
    .i_clk(clk),
    .i_rst_n(rst_n),
    .i_data({mask.duplicates, mask.origins}),
    .i_valid(mask.valid),
    .i_ready(),
    .o_data({curr_mask.duplicates, curr_mask.origins}),
    .o_valid(curr_mask.valid),
    .o_ready(in.valid && q.ready),
    .o_filling_level()
);

assign in.ready = q.ready & curr_mask.valid;

always_comb begin
    d.data  = q.data;
    d.valid = q.valid;
    d.keep = q.keep;
    d.last = q.last;

    if (in.valid && in.ready) begin
        d.data  = in.data;
        d.keep  = in.keep;
        d.valid = 1;
        d.last  = in.last;

        for (int unsigned i = 0; i < NUM_ELEMENTS; i++) begin
            if (curr_mask.duplicates[i]) begin
                d.data[i] = in.data[curr_mask.origins[i]];
                d.keep[i] = 1;
            end
        end
    end else if (q.ready) begin
        //Drain registers
        d.valid = 0;
        d.data  = 'x;
        d.keep  = 'x;
        d.last  = 0;
    end
end

always_ff @(posedge clk) begin
    if (~rst_n) begin
        q.data  <= 'x;
        q.keep <= 'x;
        q.valid <= 0;
        q.last <= 0;
    end else begin
        q.data  <= d.data;
        q.keep <= d.keep;
        q.valid <= d.valid;
        q.last <= d.last;
    end
end

generate if (ENABLE_SKID_BUFFER) begin
    NDataSkidBuffer #(data_t, NUM_ELEMENTS) inst_skid_buffer (.clk(clk), .rst_n(rst_n), .in(q), .out(out));
end else begin
    `DATA_ASSIGN(q, out)
end endgenerate

endmodule
