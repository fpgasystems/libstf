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
    parameter ELEMENT_BITS = 8, // wide enough to hold in_num_elements
    // When set, the forced-last beat is allowed to carry more values than remain; the wrapper masks
    // that beat's keep down to `remaining_elements` to strip the surplus. Used for reads whose length
    // was rounded up to a beat multiple. Default 0 keeps the strict no-overshoot invariant.
    parameter ALLOW_OVERSHOOT = 0
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s num_elements, // #(size_t)

    // Per-beat status driven by the wrapper.
    input logic                      in_valid,
    input logic                      in_is_null_beat,
    input logic[ELEMENT_BITS - 1:0]  in_num_elements,
    input logic                      out_ready,

    // Controls consumed by the wrapper.
    output logic                     force_last,
    output logic[ELEMENT_BITS - 1:0] remaining_elements, // values still expected at start of this beat
    output logic                     out_valid,
    output logic                     in_ready
);

typedef enum logic {
    WAITING,  // Waiting for num_elements configuration
    REWRITING // Counting remaining values until rewriting last signal
} state_t;

state_t state;
size_t  remaining, n_remaining;
logic   remaining_fits; // True when `remaining` fits in ELEMENT_BITS (its high bits are all zero).

assign num_elements.ready = (state == WAITING);

assign force_last  = (state == REWRITING) &&
                     remaining_fits && (in_num_elements >= remaining[ELEMENT_BITS-1:0]);
assign n_remaining = remaining - in_num_elements;
assign remaining_elements = remaining[ELEMENT_BITS-1:0];

`ifndef SYNTHESIS
// A single beat must never carry more values than remain to be counted -- unless overshoot is
// explicitly allowed, in which case the surplus is only tolerated on the forced-last beat (the
// wrapper masks it away).
assert property (@(posedge clk) disable iff (!rst_n)
    !(state == REWRITING && in_valid && !in_is_null_beat) || in_num_elements <= remaining
    || (ALLOW_OVERSHOOT && force_last))
else $fatal(1, "RewriteLastCore beat carries %0d values but only %0d more expected!", in_num_elements, remaining);
`endif

always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        remaining      <= 'X;
        remaining_fits <= 'X;
        state          <= WAITING;
    end else begin
        if (state == WAITING) begin
            if (num_elements.valid) begin
                remaining      <= num_elements.data;
                remaining_fits <= (num_elements.data[$bits(remaining) - 1:ELEMENT_BITS] == '0);
                state          <= REWRITING;
            end
        end else begin
            if (in_valid && in_ready && !in_is_null_beat) begin
                remaining      <= n_remaining;
                remaining_fits <= (n_remaining[$bits(remaining) - 1:ELEMENT_BITS] == '0);

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
    parameter type size_t = data32_t,
    // When set, the forced-last beat's keep is masked down to the number of elements that actually
    // remained, stripping any trailing padding (e.g. a read whose length was rounded up to a beat
    // multiple). Default 0 leaves keep untouched and keeps the strict no-overshoot invariant.
    parameter STRIP_TRAILING = 0
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
logic [ELEMENT_BITS - 1:0] remaining_elements;
RewriteLastCore #(
    .size_t(size_t),
    .ELEMENT_BITS(ELEMENT_BITS),
    .ALLOW_OVERSHOOT(STRIP_TRAILING)
) inst_core (
    .clk(clk),
    .rst_n(rst_n),

    .num_elements(num_elements),

    .in_valid(in.valid),
    .in_is_null_beat(in.keep == '0),
    .in_num_elements(in_num_elements),
    .out_ready(out.ready),

    .force_last(force_last),
    .remaining_elements(remaining_elements),
    .out_valid(out.valid),
    .in_ready(in.ready)
);

// Keep mask for the forced-last beat: the low `remaining_elements` elements stay valid, the rest
// (rounding padding) are stripped. Each keep bit is exactly one element here.
logic [NUM_ELEMENTS - 1:0] last_keep_mask;
for (genvar gi = 0; gi < NUM_ELEMENTS; gi++) begin : gen_last_keep_mask
    assign last_keep_mask[gi] = (gi < remaining_elements);
end

// -- Passthrough (with optional trailing strip on the forced-last beat) ---------------------------
assign out.data  = in.data;
assign out.keep  = (STRIP_TRAILING && force_last) ? (in.keep & last_keep_mask) : in.keep;
assign out.last  = force_last;

endmodule
