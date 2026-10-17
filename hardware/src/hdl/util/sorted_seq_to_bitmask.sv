`timescale 1ns / 1ps

`include "libstf_macros.svh"

module SortedSeqToBitmask #(
    parameter type data_t,
    parameter NUM_ELEMENTS
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in, // #(data_t, NUM_ELEMENTS)
    data_i.m  out // #(logic[NUM_ELEMENTS - 1:0])
);

`RESET_RESYNC // Reset pipelining

localparam DATA_WIDTH = $bits(data_t);
localparam RIDX_WIDTH = $clog2(NUM_ELEMENTS) + 1;

typedef logic[NUM_ELEMENTS - 1:0] mask_t;
typedef logic[RIDX_WIDTH - 1:0]   rid_t;

// The first ID we are currently creating the mask for and IDs relative to this
data_t                    current_id, n_current_id, id_end_of_mask;
rid_t[NUM_ELEMENTS - 1:0] relative_ids;

mask_t current_mask, mask, n_mask;
mask_t current_processed, processed, n_processed;

logic data_beat_done;
logic exact_end_of_mask;

mask_t n_out_data;
logic  n_out_last;
logic  n_out_keep;
logic  n_out_valid;

always_comb begin
    for (int i = 0; i < NUM_ELEMENTS; i++) begin
        data_t diff = in.data[i] - current_id;
        relative_ids[i] = {|diff[DATA_WIDTH - 1: RIDX_WIDTH - 1], diff[RIDX_WIDTH - 2:0]};
    end
end

assign id_end_of_mask = current_id + (NUM_ELEMENTS - 1);

always_comb begin
    current_mask      = '0;
    current_processed = '0;
    exact_end_of_mask = 1'b0;

    // Set bits at the specified indices
    for (int i = 0; i < NUM_ELEMENTS; i++) begin
        if (in.keep[i] && relative_ids[i] < NUM_ELEMENTS) begin
            current_mask[relative_ids[i]] |= 1'b1;
            current_processed[i]           = 1'b1;
        end
        if (in.data[i] == id_end_of_mask) begin
            exact_end_of_mask |= 1'b1;
        end
    end
end

assign data_beat_done = (processed | current_processed) == in.keep;

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        current_id <= '0;
        processed  <= '0;
        mask       <= '0;
        
        out.data  <= 'X;
        out.last  <= 'X;
        out.keep  <= 'X;
        out.valid <= 1'b0;
    end else begin
        current_id <= n_current_id;
        processed  <= n_processed;
        mask       <= n_mask;

        out.data  <= n_out_data;
        out.last  <= n_out_last;
        out.keep  <= n_out_keep;
        out.valid <= n_out_valid;
    end
end

always_comb begin
    in.ready = 1'b0;

    n_current_id = current_id;
    n_processed  = processed;
    n_mask       = mask;

    n_out_data  = out.data;
    n_out_last  = out.last;
    n_out_keep  = out.keep;
    n_out_valid = 1'b0;

    if (out.ready || !out.valid) begin
        if (data_beat_done) begin
            in.ready = 1'b1;
        end

        if (in.valid) begin
            if (data_beat_done) begin
                n_processed = '0;
            end else begin
                n_processed = processed | current_processed;
            end

            if (!data_beat_done || exact_end_of_mask || in.last) begin
                n_current_id = current_id + NUM_ELEMENTS;

                n_out_data  = mask | current_mask;
                n_out_last  = data_beat_done && in.last;
                n_out_keep  = 1'b1;
                n_out_valid = 1'b1;

                n_mask = '0;
            end else begin
                n_mask = mask | current_mask;
            end
        end
    end else begin
        n_out_valid = out.valid;
    end
end

endmodule
