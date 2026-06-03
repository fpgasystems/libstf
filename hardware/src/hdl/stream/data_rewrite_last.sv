`timescale 1ns / 1ps

import lynxTypes::*;
import libstf::*;

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

typedef enum logic {
    WAITING,  // Waiting for num_elements configuration
    REWRITING // Counting remaining values until rewriting last signal
} state_t;

state_t state;
size_t  remaining, n_remaining;
logic   is_null_beat;
logic   force_last;

assign num_elements.ready = (state == WAITING);

// This is on purpose 1 bit wider to account for the case where keep is 0xf..f
logic [$clog2(DATABEAT_SIZE):0] in_num_bytes, in_num_elements;
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

assign is_null_beat = in.keep == '0;
assign force_last   = (state == REWRITING && in_num_elements >= remaining);
assign n_remaining  = remaining - in_num_elements;

`ifndef SYNTHESIS
// A single beat must never carry more typed values than remain to be counted.
assert property (@(posedge clk) disable iff (!rst_n)
    !(state == REWRITING && in.valid) || in_num_elements <= remaining)
else $fatal(1, "TypedRewriteLast beat carries %0d values but only %0d more expected!", in_num_elements, remaining);
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
            if (in.valid && in.ready) begin
                remaining <= n_remaining;

                if (force_last) begin
                    state <= WAITING;
                end
            end
        end
    end
end

// -- Passthrough ----------------------------------------------------------------------------------
assign in.ready  = (in.valid && is_null_beat) || (state == REWRITING && out.ready);

assign out.data  = in.data;
assign out.typ   = in.typ;
assign out.keep  = in.keep;
assign out.last  = force_last;
assign out.valid = !(state == WAITING) && in.valid && !is_null_beat;

endmodule
