`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * Moves the kept elements of every beat to the front, in order. The keep of the output beat is set
 * for its first $countones(in.keep) elements.
 *
 * Every kept element moves down by the number of dropped elements before it. The first
 * $clog2(NUM_ELEMENTS) levels count these with a parallel prefix sum (Sklansky). The other
 * $clog2(NUM_ELEMENTS) levels then move every element by 2^k in level k if bit k of its count is
 * set. Since the counts never decrease towards the back of a beat and grow by less than the
 * distance between two kept elements, no two elements ever meet in a level. This takes
 * O(NUM_ELEMENTS * log(NUM_ELEMENTS)) muxes and adders.
 *
 * REGISTER_LEVELS registers are spread evenly over the 2 * $clog2(NUM_ELEMENTS) levels.
 */
module DataCompactor #(
    parameter type data_t,
    parameter int NUM_ELEMENTS,
    parameter int REGISTER_LEVELS = 1
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in, // #(data_t, NUM_ELEMENTS)
    ndata_i.m out // #(data_t, NUM_ELEMENTS)
);

`ASSERT_ELAB(NUM_ELEMENTS == in.NUM_ELEMENTS)

`ASSERT_ELAB(NUM_ELEMENTS >= 2)

localparam int COUNT_BITS = $clog2(NUM_ELEMENTS);
localparam int NUM_LEVELS = 2 * COUNT_BITS;

typedef logic[COUNT_BITS - 1:0] count_t;

typedef struct packed {
    data_t [NUM_ELEMENTS - 1:0] data;
    logic  [NUM_ELEMENTS - 1:0] keep;
    // The number of dropped elements before an element, up to and including it. The prefix sum
    // levels build it, the move levels carry it along with the element. It may overflow for an
    // element that is dropped, which is never moved.
    count_t[NUM_ELEMENTS - 1:0] count;
    logic                       last;
} level_t;

// Level L reads stage[L] and writes stage[L + 1]
level_t stage      [NUM_LEVELS + 1];
logic   stage_valid[NUM_LEVELS + 1];
logic   stage_ready[NUM_LEVELS + 1];

level_t first;
always_comb begin
    first.data = in.data;
    first.keep = in.keep;
    first.last = in.last;
    for (int i = 0; i < NUM_ELEMENTS; i++)
        first.count[i] = count_t'(!in.keep[i]);
end
assign stage[0]       = first;
assign stage_valid[0] = in.valid;
assign in.ready       = stage_ready[0];

for (genvar L = 0; L < NUM_LEVELS; L++) begin : gen_levels
    level_t next;

    if (L < COUNT_BITS) begin : gen_prefix_sum
        // Elements in the upper half of a block of 2^(L + 1) add the count of the last element of
        // its lower half
        always_comb begin
            next = stage[L];
            for (int i = 0; i < NUM_ELEMENTS; i++)
                if ((i >> L) & 1)
                    next.count[i] = stage[L].count[i] + stage[L].count[((i >> L) << L) - 1];
        end
    end else begin : gen_move
        localparam int K        = L - COUNT_BITS;
        localparam int DISTANCE = 1 << K;

        always_comb begin
            next = stage[L];
            for (int i = 0; i < NUM_ELEMENTS; i++) begin
                automatic logic stays   = stage[L].keep[i] && !stage[L].count[i][K];
                automatic logic arrives = 1'b0;
                if (i + DISTANCE < NUM_ELEMENTS)
                    arrives = stage[L].keep[i + DISTANCE] && stage[L].count[i + DISTANCE][K];

                next.keep[i] = stays || arrives;
                if (arrives) begin
                    next.data[i]  = stage[L].data[i + DISTANCE];
                    next.count[i] = stage[L].count[i + DISTANCE];
                end
            end
        end
    end

    if (libstf::PUT_REGISTER_AT(L + 1, NUM_LEVELS, REGISTER_LEVELS)) begin : gen_register
        level_t q;
        logic   q_valid;

        always_ff @(posedge clk) begin
            if (!rst_n) begin
                q_valid <= 1'b0;
            end else if (!q_valid || stage_ready[L + 1]) begin
                q       <= next;
                q_valid <= stage_valid[L];
            end
        end

        assign stage[L + 1]       = q;
        assign stage_valid[L + 1] = q_valid;
        assign stage_ready[L]     = !q_valid || stage_ready[L + 1];
    end else begin : gen_wire
        assign stage[L + 1]       = next;
        assign stage_valid[L + 1] = stage_valid[L];
        assign stage_ready[L]     = stage_ready[L + 1];
    end
end

assign out.data  = stage[NUM_LEVELS].data;
assign out.keep  = stage[NUM_LEVELS].keep;
assign out.last  = stage[NUM_LEVELS].last;
assign out.valid = stage_valid[NUM_LEVELS];
assign stage_ready[NUM_LEVELS] = out.ready;

endmodule
