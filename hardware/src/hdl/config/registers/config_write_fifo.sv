`timescale 1ns / 1ps

`include "libstf_macros.svh"

module ConfigWriteFIFO #(
    parameter int ADDR,
    parameter int DEPTH,
    parameter type data_t
) (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    ready_valid_i.m  out // #(data_t)
);

`ASSERT_ELAB(DEPTH > 1 && 2 ** $clog2(DEPTH) == DEPTH)

logic valid;

ready_valid_i #(data_t) internal(clk, rst_n);

assign valid = write_config.valid && write_config.addr == ADDR;

MehdiFIFO #(
    .DEPTH(DEPTH),
    .WIDTH($bits(data_t)),
    .STYLE(DEPTH <= 64 ? "distributed" : "block")
) inst_fifo (
    .clk(clk),
    .rst_n(rst_n),

    .in_data(data_t'(write_config.data)),
    .in_valid(valid),
    .in_ready(),

    .out_data(internal.data),
    .out_valid(internal.valid),
    .out_ready(internal.ready),

    .filling_level()
);

ReadyValidShiftRegister #(data_t, 1) inst_reg (
    .clk(clk),
    .rst_n(rst_n),

    .in(internal),
    .out(out)
);

endmodule
