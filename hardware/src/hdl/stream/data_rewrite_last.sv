`timescale 1ns / 1ps

import lynxTypes::*;
import libstf::*;

/**
 * Shared state machine for the *RewriteLast modules. It tracks a running count of values and, on the
 * beat where that count reaches the number configured through `num_elements`, asserts `force_last`.
 * After that beat it waits for the next `num_elements` configuration. Null beats (keep == 0) are
 * dropped: they are accepted from the input but never forwarded and do not affect the count.
 *
 * This module is interface-agnostic: the wrappers (TypedRewriteLast, DataRewriteLast) compute the
 * number of values carried by the current beat (`in_num_elements`) and wire up their respective
 * data/keep/typ passthrough; everything else lives here.
 */
module RewriteLastCore #(
    parameter type size_t = data32_t,
    parameter ELEMENT_BITS = 8 // wide enough to hold in_num_elements
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s num_elements, // #(size_t)

    // Per-beat status driven by the wrapper.
    input logic                       in_valid,
    input logic                       in_is_null_beat,
    input logic [ELEMENT_BITS - 1:0]  in_num_elements,
    input logic                       out_ready,

    // Controls consumed by the wrapper.
    output logic force_last,
    output logic out_valid,
    output logic in_ready
);

typedef enum logic {
    WAITING,  // Waiting for num_elements configuration
    REWRITING // Counting remaining values until rewriting last signal
} state_t;

state_t state;
size_t  remaining, n_remaining;

assign num_elements.ready = (state == WAITING);

assign force_last  = (state == REWRITING && in_num_elements >= remaining);
assign n_remaining = remaining - in_num_elements;

`ifndef SYNTHESIS
// A single beat must never carry more values than remain to be counted.
assert property (@(posedge clk) disable iff (!rst_n)
    !(state == REWRITING && in_valid && !in_is_null_beat) || in_num_elements <= remaining)
else $fatal(1, "RewriteLastCore beat carries %0d values but only %0d more expected!", in_num_elements, remaining);
`endif

always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        remaining <= 'X;
        state     <= WAITING;
    end else begin
        if (state == WAITING) begin
            if (num_elements.valid) begin
                remaining <= num_elements.data;
                state     <= REWRITING;
            end
        end else begin
            if (in_valid && in_ready && !in_is_null_beat) begin
                remaining <= n_remaining;

                if (force_last) begin
                    state <= WAITING;
                end
            end
        end
    end
end

assign in_ready  = (in_valid && in_is_null_beat) || (state == REWRITING && out_ready);
assign out_valid = (state == REWRITING) && in_valid && !in_is_null_beat;

endmodule

/**
 * Passes a typed ndata stream through unchanged, except that it forces `last` high on the beat
 * where a running count of typed values reaches the number configured through `num_elements`. After
 * emitting that last beat, it waits for the next `num_elements` configuration.
 */
module TypedRewriteLast #(
    parameter type size_t = data32_t,
    parameter DATABEAT_SIZE = AXI_DATA_BITS / 8
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s num_elements, // #(size_t)

    typed_ndata_i.s in, // #(DATABEAT_SIZE)
    typed_ndata_i.m out // #(DATABEAT_SIZE)
);

// This is on purpose 1 bit wider to account for the case where keep is 0xf..f
localparam ELEMENT_BITS = $clog2(DATABEAT_SIZE) + 1;
logic [ELEMENT_BITS - 1:0] in_num_bytes, in_num_elements;
assign in_num_bytes = $countones(in.keep);

always_comb begin
    in_num_elements = '0;

    case (in.typ)
        BYTE_T: begin
            in_num_elements = in_num_bytes;
        end
        INT32_T, FLOAT_T: begin
            in_num_elements = in_num_bytes / 4;
        end
        INT64_T, DOUBLE_T: begin
            in_num_elements = in_num_bytes / 8;
        end
        default: begin
        `ifndef SYNTHESIS
            if (in.valid) begin
                $fatal(1, "Unexpected type %d in TypedRewriteLast", in.typ);
            end
        `endif
        end
    endcase
end

logic force_last;
RewriteLastCore #(
    .size_t(size_t),
    .ELEMENT_BITS(ELEMENT_BITS)
) inst_core (
    .clk(clk),
    .rst_n(rst_n),

    .num_elements(num_elements),

    .in_valid(in.valid),
    .in_is_null_beat(in.keep == '0),
    .in_num_elements(in_num_elements),
    .out_ready(out.ready),

    .force_last(force_last),
    .out_valid(out.valid),
    .in_ready(in.ready)
);

// -- Passthrough ----------------------------------------------------------------------------------
assign out.data  = in.data;
assign out.typ   = in.typ;
assign out.keep  = in.keep;
assign out.last  = force_last;

endmodule

/**
 * Passes an ndata stream through unchanged, except that it forces `last` high on the beat where a
 * running count of elements reaches the number configured through `num_elements`. After emitting
 * that last beat, it waits for the next `num_elements` configuration.
 *
 * Untyped analogue of TypedRewriteLast: each keep bit is exactly one element, so the per-beat value
 * count is just $countones(keep).
 */
module DataRewriteLast #(
    parameter type data_t,
    parameter NUM_ELEMENTS,
    parameter type size_t = data32_t
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s num_elements, // #(size_t)

    ndata_i.s in, // #(data_t, NUM_ELEMENTS)
    ndata_i.m out // #(data_t, NUM_ELEMENTS)
);

// This is on purpose 1 bit wider to account for the case where keep is all ones.
localparam ELEMENT_BITS = $clog2(NUM_ELEMENTS) + 1;
logic [ELEMENT_BITS - 1:0] in_num_elements;
assign in_num_elements = $countones(in.keep);

logic force_last;
RewriteLastCore #(
    .size_t(size_t),
    .ELEMENT_BITS(ELEMENT_BITS)
) inst_core (
    .clk(clk),
    .rst_n(rst_n),

    .num_elements(num_elements),

    .in_valid(in.valid),
    .in_is_null_beat(in.keep == '0),
    .in_num_elements(in_num_elements),
    .out_ready(out.ready),

    .force_last(force_last),
    .out_valid(out.valid),
    .in_ready(in.ready)
);

// -- Passthrough ----------------------------------------------------------------------------------
assign out.data  = in.data;
assign out.keep  = in.keep;
assign out.last  = force_last;

endmodule
