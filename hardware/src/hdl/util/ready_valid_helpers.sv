`timescale 1ns / 1ps

/**
 * The ReadyValidDuplicator creates NUM_OUTPUTS outputs based on one input. The ready signal of 
 * the input is driven when all output ready signals are high.
 */
module ReadyValidDuplicator #(
    parameter integer NUM_OUTPUTS
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s in,                 // #(data_t)
    ready_valid_i.m out[NUM_OUTPUTS] // #(data_t)
);

logic[NUM_OUTPUTS - 1:0] out_ready;
logic[NUM_OUTPUTS - 1:0] seen, n_seen;

assign in.ready = &(seen | out_ready);

always_ff @(posedge clk) begin
    if(!rst_n) begin
        seen <= '0;     
    end else begin
        seen <= n_seen;
    end
end

always_comb begin
    n_seen = seen;

    if (in.ready) begin
        n_seen = '0;
    end else if (in.valid) begin
        n_seen = seen | out_ready;
    end
end

for (genvar I = 0; I < NUM_OUTPUTS; I++) begin
    assign out_ready[I] = out[I].ready;

    assign out[I].data  = in.data;
    assign out[I].valid = in.valid && !seen[I];
end

endmodule

/**
 * The ReadyValidCombiner combines the data of two inputs into one output.
 */
module ReadyValidCombiner (
    ready_valid_i.s left,  // #(left_t)
    ready_valid_i.s right, // #(right_t)
    ready_valid_i.m out    // #({left_t, right_t})
);

assign left.ready  = right.valid && out.ready;
assign right.ready = left.valid  && out.ready;

assign out.data  = {left.data, right.data};
assign out.valid = left.valid && right.valid;

endmodule

/**
 * The ReadyValidSplitter splits one input into two outputs based on the given parameter types. The 
 * ready signal of the input is driven after both output ready signals have been high.
 */
module ReadyValidSplitter #(
    parameter type left_t,
    parameter type right_t
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s in,   // #({left_t, right_t})
    ready_valid_i.m left, // #(left_t)
    ready_valid_i.m right // #(right_t)
);

typedef struct packed {
    left_t left;
    right_t right;
} combined_t;

combined_t combined_data;

logic[1:0] out_ready;
logic[1:0] seen, n_seen;

assign in.ready = &(seen | out_ready);

always_ff @(posedge clk) begin
    if(!rst_n) begin
        seen <= '0;     
    end else begin
        seen <= n_seen;
    end
end

always_comb begin
    n_seen = seen;

    if (in.ready) begin
        n_seen = '0;
    end else if (in.valid) begin
        n_seen = seen | out_ready;
    end
end

assign out_ready[0] = left.ready;
assign out_ready[1] = right.ready;

assign combined_data = in.data;

assign left.data  = combined_data.left;
assign left.valid = in.valid && !seen[0];

assign right.data  = combined_data.right;
assign right.valid = in.valid && !seen[1];

endmodule
