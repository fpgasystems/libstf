`timescale 1ns / 1ps

import lynxTypes::*;

module ConstantShifter #(
    parameter SHIFT_INDEX,
    parameter type data_t,
    parameter NUM_ELEMENTS,
    parameter REGISTER = 0,
    parameter OFFSET_WIDTH = $clog2(NUM_ELEMENTS)
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in, // #(data_t, NUM_ELEMENTS)
    input logic[OFFSET_WIDTH - 1:0] offset_in,

    ndata_i.m out, // #(data_t, NUM_ELEMENTS)
    output logic[OFFSET_WIDTH - 1:0] offset_out
);

// Calculate the shift amount from the bit index
localparam int SHIFT = 32'd1 << SHIFT_INDEX;

data_t[NUM_ELEMENTS - 1:0] data_shifted;
logic[NUM_ELEMENTS - 1:0]  keep_shifted;

always_comb begin
    if (offset_in[SHIFT_INDEX] == 1'b1) begin
        data_shifted = {in.data[NUM_ELEMENTS - SHIFT - 1:0], in.data[NUM_ELEMENTS - 1:NUM_ELEMENTS - SHIFT]};
        keep_shifted = {in.keep[NUM_ELEMENTS - SHIFT - 1:0], in.keep[NUM_ELEMENTS - 1:NUM_ELEMENTS - SHIFT]};
    end else begin
        data_shifted = in.data;
        keep_shifted = in.keep;
    end
end

generate if (REGISTER == 1) begin
    always_ff @(posedge clk) begin
        if (!rst_n == 1'b1) begin
            out.valid <= 1'b0;
        end else begin
            if (out.ready) begin
                out.data  <= data_shifted;
                out.keep  <= keep_shifted;
                out.last  <= in.last;
                out.valid <= in.valid;

                offset_out <= offset_in;
            end
        end
    end
end else begin
    assign out.data  = data_shifted;
    assign out.keep  = keep_shifted;
    assign out.last  = in.last;
    assign out.valid = in.valid;

    assign offset_out = offset_in;
end endgenerate

assign in.ready = out.ready;

endmodule
