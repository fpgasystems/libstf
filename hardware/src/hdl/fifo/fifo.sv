`timescale 1ns / 1ps

`include "libstf_macros.svh"

// The old module name `FIFO` was clashing with another module in Coyote so the module was renamed
// to `MehdiFIFO` after Dr. Mehdi Moghaddamfar who implemented it originally.
module MehdiFIFO #(
    parameter int DEPTH, // A power of two > 1
    parameter int WIDTH,
    parameter STYLE = "block"
) (
    input logic clk,
    input logic rst_n,

    input  logic[WIDTH - 1:0] in_data,
    input  logic              in_valid,
    output logic              in_ready,

    output logic[WIDTH - 1:0] out_data,
    output logic              out_valid,
    input  logic              out_ready,

    output logic[$clog2(DEPTH):0] filling_level
);

localparam int ADDRESS_WIDTH = $clog2(DEPTH);

`ASSERT_ELAB(DEPTH > 1 && 2 ** $clog2(DEPTH) == DEPTH, "DEPTH has to be a power of two > 1")

(* ram_style = STYLE *) logic[WIDTH - 1:0] memory[DEPTH];

logic write_en;

logic[ADDRESS_WIDTH - 1:0] write_ptr, n_write_ptr, write_ptr_succ;
logic[ADDRESS_WIDTH - 1:0] read_ptr,  state_read_ptr, n_state_read_ptr, read_ptr_succ;

logic full, n_full, empty, n_empty;
logic read_fire, write_fire;

// for the case that when being empty, an element is written, it takes two cycles
// till the read can perform so this is there to make sure it all goes smoothly
// the write_after_empty = '1' during that one cycle that represents this
// particular case (cycle after the write into an empty buffer).
logic write_after_empty, n_write_after_empty;

logic[$clog2(DEPTH):0] n_filling_level;

// -- Memory ---------------------------------------------------------------------------------------
assign write_en = in_valid & (~full);

always_ff @(posedge clk)
begin
    if (write_en == 1'b1) begin
        memory[write_ptr] <= in_data;
    end
    out_data <= memory[read_ptr];
end

// -- State registers ------------------------------------------------------------------------------
always_ff @(posedge clk)
begin
    if (!rst_n) begin
        state_read_ptr    <= '0;
        write_ptr         <= '0;
        empty             <= 1'b1;
        full              <= 1'b0;
        write_after_empty <= 1'b0;

        filling_level <= '0;
    end else begin
        state_read_ptr    <= n_state_read_ptr;
        write_ptr         <= n_write_ptr;
        empty             <= n_empty;
        full              <= n_full;
        write_after_empty <= n_write_after_empty;

        filling_level <= n_filling_level;
    end
end

// -- Next state logic -----------------------------------------------------------------------------
assign read_fire  = out_ready & ~empty & ~write_after_empty;
assign write_fire = in_valid & ~full;

assign write_ptr_succ = write_ptr + 1'b1;
assign read_ptr_succ  = state_read_ptr + 1'b1;

always_comb begin
    read_ptr    = state_read_ptr;
    n_write_ptr = write_ptr;

    if (read_fire) begin
        read_ptr = read_ptr_succ;
    end
    if (write_fire) begin
        n_write_ptr = write_ptr_succ;
    end

    n_state_read_ptr = read_ptr;
    n_filling_level  = filling_level + write_fire - read_fire;

    if (full) begin
        n_full = ~read_fire;
    end else begin
        n_full = write_fire & ~read_fire & filling_level == ($clog2(DEPTH) + 1)'(DEPTH - 1);
    end

    if (empty) begin
        n_empty = ~write_fire;
    end else begin
        n_empty = read_fire & ~write_fire & read_ptr_succ == write_ptr;
    end

    // A write into an empty FIFO, or a read and a write with only one element in the FIFO
    n_write_after_empty = write_fire & (empty | (read_fire & read_ptr_succ == write_ptr));
end

// -- Outputs --------------------------------------------------------------------------------------
assign out_valid = (~empty) & (~write_after_empty);

assign in_ready = (~full) & rst_n;

endmodule
