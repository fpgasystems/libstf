`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * Simple dual-port synchronous RAM mapped onto FPGA block or ultra RAM cells.
 *
 * One write port and one read port, both registered on the rising edge of clk:
 * a write commits write_data to write_addr when write_enable is high, and a
 * read presents the contents of read_addr on read_data within one clock cycle of
 * latency. The two ports operate independently and may be addressed in the
 * same cycle.
 *
 * By default a read that collides with a concurrent or recent write to the
 * same address returns the old (pre-write) memory contents. The forwarding
 * parameters (READ_*) override this.
 *
 * Parameters:
 *   DATA_WIDTH        - Width of a stored word in bits.
 *   ADDR_WIDTH        - Width of the address, giving 2**ADDR_WIDTH words.
 *   STYLE             - Target cell, "block" (BRAM) or "ultra" (URAM).
 *   READ_AFTER_WRITE  - Forward a write seen one cycle before a same-address read.
 *   READ_DURING_WRITE - Forward a write seen in the same cycle as a same-address read.
 *   PACK              - When set, pack several words into a single physical
 *                       memory line to recover the otherwise wasted bits of a
 *                       wide cell (e.g. the 72-bit URAM cell holding a narrower
 *                       DATA_WIDTH word). The number of words per line is the
 *                       largest power of two that fits in one cell, and the low
 *                       address bits select the slot within the line.
 */
module RAM #(
    parameter DATA_WIDTH,
    parameter ADDR_WIDTH,
    parameter STYLE = "block", // block or ultra
    parameter READ_AFTER_WRITE = 0,
    parameter READ_DURING_WRITE = 0,
    parameter PACK = 0
) (
    input logic clk,

    input logic[ADDR_WIDTH - 1:0] write_addr,
    input logic[DATA_WIDTH - 1:0] write_data,
    input logic                   write_enable,

    input  logic[ADDR_WIDTH - 1:0] read_addr,
    output logic[DATA_WIDTH - 1:0] read_data
);

`ASSERT_ELAB(STYLE == "block" || STYLE == "ultra")

localparam LINE_WIDTH = STYLE == "ultra" ? 72 : 36;
localparam CELL_DEPTH = STYLE == "ultra" ? 4096 : 1024;

// Packing only pays off when more than one word fits in a line AND the RAM is
// deep enough to span more than a single cell. If it fits in one cell the cell
// is already fully allocated, so packing would only add slot-select logic.
localparam DEEPER_THAN_CELL = (2 ** ADDR_WIDTH) > CELL_DEPTH;

// Number of words packed per line, clamped to a power of two so the slot index
// is a clean slice of the address. Packing is skipped when only one word fits.
localparam WORDS_PER_LINE  = !PACK || !DEEPER_THAN_CELL || LINE_WIDTH < DATA_WIDTH ? 1 : 2 ** $clog2(LINE_WIDTH / DATA_WIDTH);
localparam SLOT_BITS       = $clog2(WORDS_PER_LINE);
localparam LINE_ADDR_WIDTH = ADDR_WIDTH - SLOT_BITS;
localparam LINE_DATA_WIDTH = WORDS_PER_LINE * DATA_WIDTH;

// Packing must leave at least one address bit for the line index.
`ASSERT_ELAB(ADDR_WIDTH > SLOT_BITS)

typedef logic[ADDR_WIDTH - 1:0] addr_t;
typedef logic[DATA_WIDTH - 1:0] data_t;

typedef logic[LINE_ADDR_WIDTH - 1:0]                line_addr_t;
typedef logic[LINE_DATA_WIDTH - 1:0]                line_t;
typedef logic[SLOT_BITS == 0 ? 0 : SLOT_BITS - 1:0] slot_t;

function automatic line_addr_t line_of(addr_t a);
    line_of = line_addr_t'(a >> SLOT_BITS);
endfunction

function automatic slot_t slot_of(addr_t a);
    slot_of = SLOT_BITS == 0 ? 0 : slot_t'(a[SLOT_BITS - 1:0]);
endfunction

(* ram_style = STYLE *) line_t ram[2 ** LINE_ADDR_WIDTH];

addr_t[1:0] ram_write_addr;
data_t[1:0] ram_write_data;
logic[1:0]  ram_write_enable = '0;

addr_t ram_read_addr;
line_t ram_read_line;
slot_t ram_read_slot;

always_ff @(posedge clk) begin
    // Write operation
    if (write_enable) begin
        for (int s = 0; s < WORDS_PER_LINE; s++) begin
            if (slot_of(write_addr) == slot_t'(s)) begin
                ram[line_of(write_addr)][s * DATA_WIDTH +: DATA_WIDTH] <= write_data;
            end
        end
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
    ram_read_slot <= slot_of(read_addr);
    ram_read_line <= ram[line_of(read_addr)];
end

always_comb begin
    if (READ_DURING_WRITE && ram_write_enable[0] && ram_write_addr[0] == ram_read_addr) begin
        read_data = ram_write_data[0];
    end else if (READ_AFTER_WRITE && ram_write_enable[1] && ram_write_addr[1] == ram_read_addr) begin
        read_data = ram_write_data[1];
    end else begin
        read_data = ram_read_line[ram_read_slot * DATA_WIDTH +: DATA_WIDTH];
    end
end

endmodule

module ReadyRAM #(
    parameter DATA_WIDTH,
    parameter ADDR_WIDTH,
    parameter STYLE = "block", // block or ultra
    parameter READ_AFTER_WRITE = 0,
    parameter READ_DURING_WRITE = 0,
    parameter PACK = 0
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
    .READ_DURING_WRITE(READ_DURING_WRITE),
    .PACK(PACK)
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
