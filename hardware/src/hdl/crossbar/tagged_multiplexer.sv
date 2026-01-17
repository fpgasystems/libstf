`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * At the end of the stream, it waits to see all last signals before any elements of a new stream 
 * are accepted.
 */
module TaggedMultiplexer #(
    parameter type data_t,
    parameter ID,
    parameter NUM_INPUTS,
    parameter TAG_WIDTH,
    parameter LAST_HANDLING = 1, // 0: Wait until we see an element with a last signal for every input stream and produce a dummy last element; 1: Directly forward the incoming elements as they are
    parameter FILTER_KEEP = 1    // 0: Forward all elements even if the keep signal is 0, 1: Do not forward elements where keep is 0
) (
    input logic clk,
    input logic rst_n,

    tagged_i.s in[NUM_INPUTS], // #(data_t, TAG_WIDTH)
    data_i.m   out             // #(data_t)
);

`RESET_RESYNC // Reset pipelining

// Note: WAIT_ALL breaks the stream semantics because it may produce dummy last elements in the output
localparam WAIT_ALL = 0;
localparam FORWARD = 1;

// -- 1. stage: Tag matching to simplify multiplexing logic slightly -------------------------------
logic[NUM_INPUTS - 1:0] tag_matches;
tagged_i #(data_t, 1) matched[NUM_INPUTS](), mux_in[NUM_INPUTS]();

for (genvar I = 0; I < NUM_INPUTS; I++) begin
    assign tag_matches[I] = in[I].tag == ID;

    always_comb begin
        in[I].ready = 1'b1;

        matched[I].data  = in[I].data;
        matched[I].tag   = tag_matches[I];
        matched[I].keep  = in[I].keep;
        matched[I].last  = in[I].last;
        matched[I].valid = in[I].valid;

        if (((LAST_HANDLING == WAIT_ALL && in[I].last) || tag_matches[I]) && !matched[I].ready) begin
            in[I].ready = 1'b0;
        end
    end

    TaggedSkidBuffer #(data_t, 1) inst_internal_buffer (.clk(clk), .rst_n(reset_synced), .in(matched[I]), .out(mux_in[I]));
end

// -- 2. stage: Multiplex round robin --------------------------------------------------------------
logic[NUM_INPUTS - 1:0] tags, is_selected;
data_i #(data_t) selected();

data_t mux_in_data[NUM_INPUTS];
logic[NUM_INPUTS - 1:0] mux_in_keep, mux_in_last, mux_in_valid, mux_in_ready;

logic[NUM_INPUTS - 1:0] last_seen, n_last_seen;

data_i #(data_t) mux_out(), n_mux_out();

for(genvar I = 0; I < NUM_INPUTS; I++) begin
    assign mux_in[I].ready = mux_in_ready[I]; // We need to reassign these values to local arrays because SystemVerilog thinks the iterator in a process is not constant for arrays of interfaces

    assign mux_in_data[I]  = mux_in[I].data;
    assign mux_in_keep[I]  = mux_in[I].keep;
    assign mux_in_last[I]  = mux_in[I].last;
    assign mux_in_valid[I] = mux_in[I].valid;

    assign tags[I] = mux_in[I].valid && (!FILTER_KEEP || mux_in[I].keep) && mux_in[I].tag && !last_seen[I];
end

// -- Selection logic ------------------------------------------------------------------------------
// High: Masked selection for the elements before the wrap around
logic[NUM_INPUTS - 1:0] high_mask, shifted_mask, masked_tags, prefix_sum_high, is_selected_high;

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        high_mask <= '1;
    end else begin
        if (|shifted_mask) begin
            high_mask <= shifted_mask;
        end else begin
            high_mask <= '1;
        end
    end
end

assign shifted_mask = high_mask << 1;
assign masked_tags  = high_mask & tags;

assign prefix_sum_high[0]  = masked_tags[0];
assign is_selected_high[0] = masked_tags[0];

for (genvar I = 1; I < NUM_INPUTS; I++) begin
    assign prefix_sum_high[I]  = masked_tags[I] ? 1'b1 : prefix_sum_high[I - 1];
    assign is_selected_high[I] = masked_tags[I] && !prefix_sum_high[I - 1];
end

// Low: Non-masked selection for the elements after the wrap around
logic[NUM_INPUTS - 1:0] prefix_sum_low, is_selected_low;

assign prefix_sum_low[0]  = tags[0];
assign is_selected_low[0] = tags[0];

for (genvar I = 1; I < NUM_INPUTS; I++) begin
    assign prefix_sum_low[I]  = tags[I] ? 1'b1 : prefix_sum_low[I - 1];
    assign is_selected_low[I] = tags[I] && !prefix_sum_low[I - 1];
end

assign is_selected = |is_selected_high ? is_selected_high : is_selected_low;

// -- One-hot OR reduce multiplexer ----------------------------------------------------------------
always_comb begin
    selected.data  = '0;
    selected.keep  = 1'b0;
    selected.last  = 1'b0;
    selected.valid = |tags; 

    for (int i = 0; i < NUM_INPUTS; i++) begin
        selected.data |= is_selected[i] ? mux_in_data[i]  : '0;
        selected.keep |= is_selected[i] ? mux_in_keep[i]  : 1'b0;
        selected.last |= LAST_HANDLING == FORWARD && is_selected[i] ? mux_in_last[i] : 1'b0;
    end
end

// -- Output logic ---------------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (!reset_synced) begin
        last_seen     <= '0;
        mux_out.valid <= '0;
    end else begin
        last_seen <= n_last_seen;

        mux_out.data  <= n_mux_out.data;
        mux_out.keep  <= n_mux_out.keep;
        mux_out.last  <= n_mux_out.last;
        mux_out.valid <= n_mux_out.valid;
    end
end

always_comb begin
    // If we wait for all last signals, the inputs where we have seen the last belong to the next 
    // stream and cannot yet be consumed
    if (LAST_HANDLING == WAIT_ALL) begin
        mux_in_ready = ~last_seen;
    end else begin
        mux_in_ready = '1;
    end

    n_last_seen = last_seen;

    n_mux_out.data  = mux_out.data;
    n_mux_out.keep  = 1'b0;
    n_mux_out.last  = 1'b0;
    n_mux_out.valid = 1'b0; 

    if (mux_out.ready) begin
        n_mux_out.data  = selected.data;
        n_mux_out.keep  = selected.keep;
        n_mux_out.last  = selected.last;
        n_mux_out.valid = selected.valid; 

        for (int i = 0; i < NUM_INPUTS; i++) begin
            if (tags[i] && !is_selected[i]) begin
                mux_in_ready[i] = 1'b0; // Stall element
            end
            if (LAST_HANDLING == WAIT_ALL && mux_in_last[i] && (is_selected[i] || (mux_in_valid[i] && !tags[i]))) begin
                n_last_seen[i] = 1'b1; // Mark last seen
            end
        end

        // We have seen all last signals or the last element is processed in this clock cycle
        if (LAST_HANDLING == WAIT_ALL && (&last_seen || ($onehot0(tags) && &(last_seen | (mux_in_valid & mux_in_last))))) begin 
            n_last_seen     = '0;
            n_mux_out.last  = 1'b1;
            n_mux_out.valid = 1'b1;
        end
    end else begin // Not ready => Hold signals
        for (int i = 0; i < NUM_INPUTS; i++) begin
            if (tags[i]) begin
                mux_in_ready[i] = 1'b0;
            end else begin
                if (LAST_HANDLING == WAIT_ALL && mux_in_valid[i] && mux_in_last[i]) begin
                    n_last_seen[i] = 1'b1;
                end
            end
        end

        n_mux_out.keep  = mux_out.keep;
        n_mux_out.last  = mux_out.last;
        n_mux_out.valid = mux_out.valid;
    end 
end

DataSkidBuffer #(data_t) inst_output_buffer (.clk(clk), .rst_n(reset_synced), .in(mux_out), .out(out));

endmodule
