`timescale 1ns / 1ps

`include "libstf_macros.svh"

// FIFO that reduces an input to smaller chunks as output
module MultiInsertFIFO #(
    parameter int DEPTH, // A power of two > 1
    parameter int WIDTH,
    parameter int FACTOR // A power of two > 1
) (
    input logic clk,
    input logic rst_n,

    input  logic[FACTOR * WIDTH - 1:0] in_data,
    input  logic                       in_valid,
    output logic                       in_ready,

    output logic[WIDTH - 1:0] out_data,
    output logic              out_valid,
    input  logic              out_ready,

    output logic[$clog2(DEPTH):0] filling_level
);

localparam int SWITCH_WIDTH = $clog2(FACTOR);

`ASSERT_ELAB(DEPTH > 1 && 2 ** $clog2(DEPTH) == DEPTH, "DEPTH has to be a power of two > 1")
`ASSERT_ELAB(FACTOR > 1 && 2 ** $clog2(FACTOR) == FACTOR, "FACTOR has to be a power of two > 1")

logic[SWITCH_WIDTH - 1:0] switch, n_switch;

logic[FACTOR * WIDTH - 1:0] fifo_data;
logic fifo_valid, fifo_ready;

MehdiFIFO #(
    .DEPTH(DEPTH),
    .WIDTH(FACTOR * WIDTH)
) inst_fifo (
    .clk(clk),
    .rst_n(rst_n),

    .in_data(in_data),
    .in_valid(in_valid),
    .in_ready(in_ready),

    .out_data(fifo_data),
    .out_valid(fifo_valid),
    .out_ready(fifo_ready),

    .filling_level(filling_level)
);

always_ff @(posedge clk) begin
    if (!rst_n) begin
        switch <= '0;
    end else begin
        switch <= n_switch;
    end
end

always_comb begin
    n_switch = switch;

    if (out_ready == 1'b1 && fifo_valid == 1'b1) begin
        n_switch = switch + 1'b1;
    end
end

always_comb begin
    if (out_ready == 1'b1 && switch == '1) begin
        fifo_ready = 1'b1;
    end else begin
        fifo_ready = 1'b0;
    end
end

assign out_data  = fifo_data[switch * WIDTH +: WIDTH];
assign out_valid = fifo_valid;

endmodule
