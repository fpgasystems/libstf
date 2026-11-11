`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * Converts an ndata_i stream to a different width.
 *
 * Note: Supports any power-of-two IN_WIDTH and OUT_WIDTH. When IN_WIDTH != OUT_WIDTH the wider side
 * must be an exact multiple of the narrower side (guaranteed for powers of two). When upscaling,
 * NUM_SLOTS narrow input beats are packed into one wide output beat. When downscaling, one wide
 * input beat is drained over up to NUM_SLOTS narrow output beats. Trailing slots without kept
 * elements are suppressed so partial (last) beats do not produce empty output beats.
 */
module NDataWidthConverter #(
    parameter type data_t,
    parameter int IN_WIDTH,
    parameter int OUT_WIDTH
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in, // #(data_t, IN_WIDTH)
    ndata_i.m out // #(data_t, OUT_WIDTH)
);

`ASSERT_ELAB(IN_WIDTH == in.NUM_ELEMENTS)
`ASSERT_ELAB(OUT_WIDTH == out.NUM_ELEMENTS)

`ASSERT_ELAB(2 ** $clog2(IN_WIDTH) == IN_WIDTH, "IN_WIDTH has to be a power of two")
`ASSERT_ELAB(2 ** $clog2(OUT_WIDTH) == OUT_WIDTH, "OUT_WIDTH has to be a power of two")

generate if (IN_WIDTH == OUT_WIDTH) begin : gen_passthrough
    `DATA_ASSIGN(in, out)
end else if (IN_WIDTH < OUT_WIDTH) begin : gen_upsize
    localparam int NUM_SLOTS          = OUT_WIDTH / IN_WIDTH;
    localparam int SLOT_COUNTER_WIDTH = $clog2(NUM_SLOTS);

    logic[SLOT_COUNTER_WIDTH - 1:0] slot_idx, n_slot_idx;

    data_t[OUT_WIDTH - 1:0] data,  n_data;
    logic [OUT_WIDTH - 1:0] keep,  n_keep;
    logic                   last,  n_last;
    logic                   valid, n_valid;

    assign in.ready = !out.valid || out.ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            slot_idx <= '0;
            data     <= 'X;
            keep     <= 'X;
            last     <= 'X;
            valid    <= 1'b0;
        end else begin
            slot_idx <= n_slot_idx;
            data     <= n_data;
            keep     <= n_keep;
            last     <= n_last;
            valid    <= n_valid;
        end
    end

    always_comb begin
        n_slot_idx = slot_idx;
        n_data     = data;
        n_keep     = keep;
        n_last     = last;
        n_valid    = 1'b0;

        if (!out.valid || out.ready) begin
            if (in.valid) begin
                if (in.last) begin
                    n_slot_idx = '0;
                end else begin
                    n_slot_idx = slot_idx + 1; // Wraps around
                end
            end

            if (slot_idx == 0) begin
                n_keep = '0;
            end

            for (int i = 0; i < IN_WIDTH; i++) begin
                n_data[slot_idx * IN_WIDTH + i] = in.data[i];
                n_keep[slot_idx * IN_WIDTH + i] = in.keep[i];
            end

            if (in.valid && (in.last || slot_idx == SLOT_COUNTER_WIDTH'(NUM_SLOTS - 1))) begin
                n_valid = 1'b1;
            end

            n_last = in.last;
        end else begin
            n_valid = valid;
        end
    end

    assign out.data  = data;
    assign out.keep  = keep;
    assign out.last  = last;
    assign out.valid = valid;
end else begin : gen_downsize // OUT_WIDTH < IN_WIDTH
    localparam int NUM_SLOTS          = IN_WIDTH / OUT_WIDTH;
    localparam int SLOT_COUNTER_WIDTH = $clog2(NUM_SLOTS);

    data_t[IN_WIDTH - 1:0] data;
    logic [IN_WIDTH - 1:0] keep;
    logic                  last;
    logic                  valid;

    logic[SLOT_COUNTER_WIDTH - 1:0] slot_idx;

    // Index of the highest slot that still contains a kept element.
    logic[SLOT_COUNTER_WIDTH - 1:0] last_slot;
    always_comb begin
        last_slot = '0;
        for (int s = 0; s < NUM_SLOTS; s++) begin
            if (|keep[s * OUT_WIDTH +: OUT_WIDTH]) begin
                last_slot = SLOT_COUNTER_WIDTH'(s);
            end
        end
    end

    logic out_fire, beat_done, can_load;
    assign out_fire  = valid && out.ready;                // current output slot is consumed
    assign beat_done = out_fire && slot_idx == last_slot; // last slot of the buffered beat consumed
    assign can_load  = !valid || beat_done;               // buffer is empty or emptied this cycle

    assign in.ready = can_load;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            slot_idx <= '0;
            valid    <= 1'b0;
            data     <= 'X;
            keep     <= 'X;
            last     <= 'X;
        end else if (can_load) begin
            slot_idx <= '0;
            valid    <= in.valid;
            data     <= in.data;
            keep     <= in.keep;
            last     <= in.last;
        end else if (out_fire) begin
            slot_idx <= slot_idx + 1; // Bounded by last_slot, so never wraps
        end
    end

    assign out.data  = data[slot_idx * OUT_WIDTH +: OUT_WIDTH];
    assign out.keep  = keep[slot_idx * OUT_WIDTH +: OUT_WIDTH];
    assign out.last  = last && slot_idx == last_slot;
    assign out.valid = valid;
end endgenerate

endmodule
