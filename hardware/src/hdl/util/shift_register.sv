`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * Delays i_data by LEVELS register stages. The stages only advance while i_ready is high, so the
 * register chain stalls together with a downstream pipeline.
 */
module ReadyShiftRegister #(
    parameter int WIDTH  = 1,
    parameter int LEVELS = 1
) (
    input logic clk,
    input logic rst_n,

    input  logic[WIDTH - 1:0] i_data,
    output logic              o_ready,

    output logic[WIDTH - 1:0] o_data,
    input  logic              i_ready
);

`ASSERT_ELAB(LEVELS > 0)

logic[LEVELS - 1:0][WIDTH - 1:0] shift_reg;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        shift_reg <= '0;
    end else if (i_ready) begin
        shift_reg[LEVELS - 1] <= i_data;
        for (int i = 0; i < LEVELS - 1; i++) begin
            shift_reg[i] <= shift_reg[i + 1];
        end
    end
end

assign o_ready = i_ready;

assign o_data = shift_reg[0];

endmodule

/**
 * Delays i_data by LEVELS register stages.
 */
module ShiftRegister #(
    parameter int WIDTH  = 1,
    parameter int LEVELS = 1
) (
    input logic clk,
    input logic rst_n,

    input  logic[WIDTH - 1:0] i_data,
    output logic[WIDTH - 1:0] o_data
);

ReadyShiftRegister #(
    .WIDTH(WIDTH),
    .LEVELS(LEVELS)
) inst_shift_reg (
    .clk(clk),
    .rst_n(rst_n),

    .i_data(i_data),
    .o_ready(),

    .o_data(o_data),
    .i_ready(1'b1)
);

endmodule
