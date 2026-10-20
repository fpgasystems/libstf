`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * The NDataLookahead lets downstream logic read beyond the boundary of a beat. Every output beat
 * contains the elements of the input beat followed by the first PREVIEW_SIZE elements of the next
 * input beat. The preview never crosses a stream boundary: on the last beat of a stream, the keep
 * of the preview elements is 0, even if the next stream is already waiting.
 *
 * Each beat is held until its successor arrives, so this adds one beat of latency at full
 * throughput.
 */
module NDataLookahead #(
    parameter type data_t,
    parameter int NUM_ELEMENTS,
    parameter int PREVIEW_SIZE = 3
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in, // #(data_t, NUM_ELEMENTS)
    ndata_i.m out // #(data_t, NUM_ELEMENTS + PREVIEW_SIZE)
);

`ASSERT_ELAB(PREVIEW_SIZE >= 1 && PREVIEW_SIZE <= NUM_ELEMENTS)

typedef enum logic[1:0] {
    WAIT_FIRST, // Waiting for the first beat of a stream
    GLUE,       // Holding a beat until the next beat of the same stream arrives
    EMIT_LAST   // Holding the last beat of a stream, which has no preview
} state_t;

state_t                    state, n_state;
data_t[NUM_ELEMENTS - 1:0] data,  n_data;
logic [NUM_ELEMENTS - 1:0] keep,  n_keep;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        state <= WAIT_FIRST;
    end else begin
        state <= n_state;
        data  <= n_data;
        keep  <= n_keep;
    end
end

always_comb begin
    n_state = state;
    n_data  = data;
    n_keep  = keep;

    if (in.valid && in.ready) begin
        n_state = in.last ? EMIT_LAST : GLUE;
        n_data  = in.data;
        n_keep  = in.keep;
    end else if (state == EMIT_LAST && out.ready) begin
        n_state = WAIT_FIRST;
    end
end

assign in.ready = state == WAIT_FIRST || out.ready;

assign out.data[NUM_ELEMENTS - 1:0] = data;
assign out.keep[NUM_ELEMENTS - 1:0] = keep;

// The waiting input beat only belongs to the same stream in GLUE
for (genvar I = 0; I < PREVIEW_SIZE; I++) begin
    assign out.data[NUM_ELEMENTS + I] = state == GLUE ? in.data[I] : '0;
    assign out.keep[NUM_ELEMENTS + I] = state == GLUE && in.valid && in.keep[I];
end

assign out.last  = state == EMIT_LAST;
assign out.valid = state == EMIT_LAST || (state == GLUE && in.valid);

endmodule
