`timescale 1ns / 1ps

`include "libstf_macros.svh"

module RAM #(
    parameter DATA_WIDTH,
    parameter ADDR_WIDTH,
    parameter STYLE = "block", // block or ultra
    parameter READ_AFTER_WRITE = 0,
    parameter READ_DURING_WRITE = 0
) (
    input logic clk,

    input logic[ADDR_WIDTH - 1:0] write_addr,
    input logic[DATA_WIDTH - 1:0] write_data,
    input logic                   write_enable,

    input  logic[ADDR_WIDTH - 1:0] read_addr,
    output logic[DATA_WIDTH - 1:0] read_data
);

`ASSERT_ELAB(STYLE == "block" || STYLE == "ultra")

typedef logic[ADDR_WIDTH - 1:0] addr_t;
typedef logic[DATA_WIDTH - 1:0] data_t;

(* ram_style = STYLE *) logic[DATA_WIDTH - 1:0] ram[2 ** ADDR_WIDTH];

addr_t[1:0] ram_write_addr;
data_t[1:0] ram_write_data;
logic[1:0]  ram_write_enable = '0;

addr_t ram_read_addr;
data_t ram_read_data;

always_ff @(posedge clk) begin
    // Write operation
    if (write_enable) begin
        ram[write_addr] <= write_data;
    end

    if (READ_DURING_WRITE || READ_AFTER_WRITE) begin
        ram_write_addr[0]   <= write_addr;
        ram_write_data[0]   <= write_data;
        ram_write_enable[0] <= write_enable;
    end
    if (READ_AFTER_WRITE) begin
        ram_write_addr[1]   <= ram_write_addr[0];
        ram_write_data[1]   <= ram_write_data[0];
        ram_write_enable[1] <= ram_write_enable[0];
    end

    // Read operation
    ram_read_addr <= read_addr;
    ram_read_data <= ram[read_addr];
end

always_comb begin
    if (READ_DURING_WRITE && ram_write_enable[0] && ram_write_addr[0] == ram_read_addr) begin
        read_data = ram_write_data[0];
    end else if (READ_AFTER_WRITE && ram_write_enable[1] && ram_write_addr[1] == ram_read_addr) begin
        read_data = ram_write_data[1];
    end else begin
        read_data = ram_read_data;
    end
end

endmodule

module ReadyRAM #(
    parameter DATA_WIDTH,
    parameter ADDR_WIDTH,
    parameter STYLE = "block", // block or ultra
    parameter READ_AFTER_WRITE = 0,
    parameter READ_DURING_WRITE = 0
) (
    input logic clk,

    input logic[ADDR_WIDTH - 1:0] write_addr,
    input logic[DATA_WIDTH - 1:0] write_data,
    input logic                   write_enable,

    input  logic[ADDR_WIDTH - 1:0] read_addr,
    output logic[DATA_WIDTH - 1:0] read_data,
    input  logic                   read_ready
);

logic[DATA_WIDTH - 1:0] ram_data;

logic prev_read_ready = 1'b0;
logic[DATA_WIDTH - 1:0] stalled_data;

RAM #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_WIDTH(ADDR_WIDTH),
    .STYLE(STYLE),
    .READ_AFTER_WRITE(READ_AFTER_WRITE),
    .READ_DURING_WRITE(READ_DURING_WRITE)
) inst_ram (
    .clk(clk),

    .write_addr(write_addr),
    .write_data(write_data),
    .write_enable(write_enable),

    .read_addr(read_addr),
    .read_data(ram_data)
);

always_ff @(posedge clk) begin
    prev_read_ready <= read_ready;

    if (prev_read_ready && !read_ready) begin
        stalled_data <= ram_data;
    end
end

assign read_data = !prev_read_ready ? stalled_data : ram_data;

endmodule
