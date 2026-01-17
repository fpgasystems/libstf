`timescale 1ns / 1ps

/**
 * The Reorder module reorders a data stream that may have been shuffled out of order based on a 
 * pre-assigned serial number passed as the tag.
 */
module Reorder #(
    parameter type data_t,
    parameter DEPTH,
    parameter SERIAL_WIDTH = $clog2(DEPTH)
) (
    input logic clk,
    input logic rst_n,

    tagged_i.s in, // #(data_t, SERIAL_WIDTH)
    data_i.m  out  // #(data_t)
);

localparam DATA_WIDTH = $bits(data_t);
localparam RAM_WIDTH = DATA_WIDTH + 2;

logic[SERIAL_WIDTH - 1:0] ram_addr;
logic[RAM_WIDTH - 1:0]    ram_data;

logic[DEPTH - 1:0] ram_valid, n_ram_valid;

logic[SERIAL_WIDTH - 1:0] next, n_next, next_succ;

data_i #(data_t) n_out();

assign in.ready = 1'b1;

RAM #(
    .DATA_WIDTH(RAM_WIDTH),
    .ADDR_WIDTH(SERIAL_WIDTH),
    .STYLE("block"),
    .READ_AFTER_WRITE(1),
    .READ_DURING_WRITE(1)
) inst_ram (
    .clk(clk),

    .write_addr(in.tag),
    .write_data({in.data, in.keep, in.last}),
    .write_enable(in.valid),

    .read_addr(ram_addr),
    .read_data(ram_data)
);

always_ff @(posedge clk) begin
    if (!rst_n) begin
        next      <= 0;
        ram_valid <= '0;

        out.valid <= 1'b0;
    end else begin
        next      <= n_next;
        ram_valid <= n_ram_valid;

        out.data  <= n_out.data;
        out.keep  <= n_out.keep;
        out.last  <= n_out.last;
        out.valid <= n_out.valid;
    end
end

assign next_succ = next + 1;

always_comb begin
    ram_addr = next;

    n_next = next;

    n_ram_valid = ram_valid;

    n_out.data  = out.data;
    n_out.keep  = out.keep;
    n_out.last  = out.last;
    n_out.valid = 1'b0;

    if (in.valid) begin
        n_ram_valid[in.tag] = 1'b1;
    end

    if (!out.valid || out.ready) begin
        n_out.data = ram_data[2+:DATA_WIDTH];
        n_out.keep = ram_data[1];
        n_out.last = ram_data[0];

        if (ram_valid[next]) begin
            n_out.valid       = 1'b1;
            n_ram_valid[next] = 1'b0;
            ram_addr          = next_succ;
            n_next            = next_succ;
        end
    end else begin
        n_out.valid = out.valid;
    end
end

endmodule
