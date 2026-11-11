`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * Delays in_data by LEVELS register stages. The stages only advance while out_ready is high, so
 * the register chain stalls together with a downstream pipeline. in_ready mirrors out_ready.
 */
module ReadyShiftRegister #(
    parameter int WIDTH  = 1,
    parameter int LEVELS = 1
) (
    input logic clk,
    input logic rst_n,

    input  logic[WIDTH - 1:0] in_data,
    output logic              in_ready,

    output logic[WIDTH - 1:0] out_data,
    input  logic              out_ready
);

`ASSERT_ELAB(LEVELS > 0)

logic[LEVELS - 1:0][WIDTH - 1:0] shift_reg;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        shift_reg <= '0;
    end else if (out_ready) begin
        shift_reg[LEVELS - 1] <= in_data;
        for (int i = 0; i < LEVELS - 1; i++) begin
            shift_reg[i] <= shift_reg[i + 1];
        end
    end
end

assign in_ready = out_ready;

assign out_data = shift_reg[0];

endmodule

/**
 * Delays in_data by LEVELS register stages.
 */
module ShiftRegister #(
    parameter int WIDTH  = 1,
    parameter int LEVELS = 1
) (
    input logic clk,
    input logic rst_n,

    input  logic[WIDTH - 1:0] in_data,
    output logic[WIDTH - 1:0] out_data
);

ReadyShiftRegister #(
    .WIDTH(WIDTH),
    .LEVELS(LEVELS)
) inst_shift_reg (
    .clk(clk),
    .rst_n(rst_n),

    .in_data(in_data),
    .in_ready(),

    .out_data(out_data),
    .out_ready(1'b1)
);

endmodule
