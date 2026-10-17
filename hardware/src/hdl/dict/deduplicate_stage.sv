`timescale 1ns / 1ps

`include "libstf_macros.svh"

module DeduplicateStage #(
    parameter int unsigned ID,
    parameter type data_t, 
    parameter NUM_ELEMENTS,
    parameter int unsigned START_IDX_INCL,
    parameter int unsigned END_IDX_EXCL
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s     in,      // #(data_t, NUM_ELEMENTS)
    duplicate_i.s in_mask, // #(NUM_ELEMENTS)
    
    ndata_i.m     out,     // #(data_t, NUM_ELEMENTS)
    duplicate_i.m out_mask // #(NUM_ELEMENTS)
);

`ASSERT_ELAB(START_IDX_INCL < END_IDX_EXCL)

assign in.ready = out.ready;

ndata_i     #(data_t, NUM_ELEMENTS) data(clk, rst_n), n_data(clk, rst_n);
duplicate_i #(NUM_ELEMENTS)         mask(),           n_mask();

always_ff @(posedge clk) begin
    if (~rst_n) begin
        data.data  <= 'X;
        data.keep  <= 'X;
        data.last  <= 'X;
        data.valid <= 1'b0;

        mask.duplicates <= 'X;
        mask.origins    <= 'X;
    end else begin
        data.data  <= n_data.data;
        data.keep  <= n_data.keep;
        data.last  <= n_data.last;
        data.valid <= n_data.valid;

        mask.duplicates <= n_mask.duplicates;
        mask.origins    <= n_mask.origins;
    end
end

always_comb begin
    n_data.data  = data.data;
    n_data.keep  = data.keep;
    n_data.last  = data.last;
    n_data.valid = data.valid;

    n_mask.duplicates = mask.duplicates;
    n_mask.origins    = mask.origins;

    if (out.ready) begin
        if (in.valid) begin
            n_data.data  = in.data;
            n_data.keep  = in.keep;
            n_data.last  = in.last;
            n_data.valid = 1'b1;

            n_mask.duplicates = in_mask.duplicates;
            n_mask.origins    = in_mask.origins;

            for (int unsigned i = START_IDX_INCL; i < END_IDX_EXCL; i++) begin
                for (int unsigned j = 0; j < i; j++) begin
                    // j is always less than i
                    if (in.data[i] == in.data[j]) begin
                        n_data.keep[i] = 1'b0;

                        n_mask.duplicates[i] = in.keep[i];
                        n_mask.origins[i]    = j;

                        // Break inner loop, otherwise n_mask[i].origin might point to a
                        // location which is itself a duplicate
                        break;
                    end
                end
            end
        end else if (out.ready) begin
            n_data.valid = 1'b0;
        end
    end
end

// Assign ready to silence assertion that ready cannot be undefined. Needs to be high so we do not 
// get in trouble with with stable assertion of the interface.
assign data.ready   = 1'b1;
assign n_data.ready = 1'b1;

assign out.data  = data.data;
assign out.keep  = data.keep;
assign out.last  = data.last;
assign out.valid = data.valid;

assign out_mask.duplicates = mask.duplicates;
assign out_mask.origins    = mask.origins;

endmodule
