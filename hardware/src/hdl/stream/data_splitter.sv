`timescale 1ns / 1ps

/**
 * Splits up a composite data stream into a left and a right stream
 */
module DataSplitter #(
    parameter type left_data_t,
    parameter type right_data_t,
    parameter NUM_ELEMENTS
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in,

    ndata_i.m left_out, // #(left_data_t, NUM_ELEMENTS)
    ndata_i.m right_out // #(right_data_t, NUM_ELEMENTS)
);

typedef struct packed {
    left_data_t  left;
    right_data_t right;
} full_data_t;

full_data_t[NUM_ELEMENTS - 1:0] in_data;
logic[1:0] is_ready, is_handshake, was_handshake;

assign is_ready[0] = left_out.ready;
assign is_ready[1] = right_out.ready;

assign is_handshake[0] = in.valid & left_out.ready;
assign is_handshake[1] = in.valid & right_out.ready;

assign in.ready = &(was_handshake | is_ready);

always_ff @(posedge clk) begin
    if (!rst_n) begin
        was_handshake <= '0;
    end else begin
        if (in.ready) begin
            was_handshake <= '0;
        end else begin
            was_handshake <= was_handshake | is_handshake;
        end
    end
end

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign in_data[I]  = full_data_t'(in.data[I]);
    assign left_out.data[I]  = in_data[I].left;
    assign right_out.data[I] = in_data[I].right;
end

assign left_out.keep =  in.keep;
assign left_out.last =  in.last;
assign left_out.valid = in.valid & ~was_handshake[0];

assign right_out.keep =  in.keep;
assign right_out.last =  in.last;
assign right_out.valid = in.valid & ~was_handshake[1];

endmodule
