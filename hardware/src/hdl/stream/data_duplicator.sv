`timescale 1ns / 1ps

/**
 * The NDataDuplicator creates NUM_OUTPUTS output streams based on one input stream. The ready 
 * signal of the input is driven when all output ready signals are high.
 */
module NDataDuplicator #(
    parameter integer NUM_OUTPUTS
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in,              // #(data_t, NUM_ELEMENTS)
    ndata_i.m out[NUM_OUTPUTS] // #(data_t, NUM_ELEMENTS)
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
    assign out[I].keep  = in.keep;
    assign out[I].last  = in.last;
    assign out[I].valid = in.valid && !seen[I];
end

endmodule

/**
 * The NTaggedDuplicator creates NUM_OUTPUTS output streams based on one input stream. The ready 
 * signal of the input is driven when all output ready signals are high.
 */
module NTaggedDuplicator #(
    parameter integer NUM_OUTPUTS,
    parameter type data_t,
    parameter integer TAG_WIDTH,
    parameter integer NUM_ELEMENTS
) (
    input logic clk,
    input logic rst_n,

    ntagged_i.s in,              // #(data_t, TAG_WIDTH, NUM_ELEMENTS)
    ntagged_i.m out[NUM_OUTPUTS] // #(data_t, TAG_WIDTH, NUM_ELEMENTS)
);

typedef struct packed {
    data_t                 data;
    logic[TAG_WIDTH - 1:0] tag;
} data_tag_t;

ndata_i #(data_tag_t, NUM_ELEMENTS) internal_in(), internal_out[NUM_OUTPUTS]();

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign internal_in.data[I].data = in.data[I];
    assign internal_in.data[I].tag  = in.tag[I];
end
assign internal_in.keep  = in.keep;
assign internal_in.last  = in.last;
assign internal_in.valid = in.valid;

assign in.ready = internal_in.ready;

NDataDuplicator #(
    .NUM_OUTPUTS(NUM_OUTPUTS)
) inst_duplicator (
    .clk(clk),
    .rst_n(rst_n),

    .in(internal_in),
    .out(internal_out)
);

for (genvar O = 0; O < NUM_OUTPUTS; O++) begin
    for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
        assign out[O].data[I] = internal_out[O].data[I].data;
        assign out[O].tag[I]  = internal_out[O].data[I].tag;
    end
    assign out[O].keep  = internal_out[O].keep;
    assign out[O].last  = internal_out[O].last;
    assign out[O].valid = internal_out[O].valid;

    assign internal_out[O].ready = out[O].ready;
end

endmodule
