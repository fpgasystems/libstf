`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * The WriteConfigSplitter splits a write config interface into multiple config interfaces based on 
 * address space bounds. I also substracts the corresponding address space bound from the address it 
 * passes on. The address space has to start at 0.
 */
module WriteConfigSplitter #(
    parameter integer NUM_CONFIGS,
    parameter integer ADDR_SPACE_BOUNDS[NUM_CONFIGS + 1],
    parameter integer REG_LEVELS = 1
) (
    input logic clk,
    input logic rst_n,

    write_config_i.s in,
    write_config_i.m out[NUM_CONFIGS]
);

`RESET_RESYNC // Reset pipelining

logic[NUM_CONFIGS:0]     smaller_than_bound;
logic[NUM_CONFIGS - 1:0] addr_matches, out_valid;

write_config_i internal[NUM_CONFIGS](.clk(clk), .rst_n(reset_synced));

`ifndef SYNTHESIS
// Address needs to be within address space bounds
assert property (@(posedge clk) disable iff (!reset_synced) !in.valid || 
    (in.addr >= ADDR_SPACE_BOUNDS[0] && in.addr < ADDR_SPACE_BOUNDS[NUM_CONFIGS]))
else $fatal(1, "Write address %0d is out-of-bounds!", in.addr);
`endif

assign smaller_than_bound[0] = 1'b0;

for (genvar I = 0; I < NUM_CONFIGS; I++) begin
    assign smaller_than_bound[I + 1] = in.addr < ADDR_SPACE_BOUNDS[I + 1];
    assign addr_matches[I]           = !smaller_than_bound[I] && smaller_than_bound[I + 1];

    assign internal[I].addr  = in.addr - ADDR_SPACE_BOUNDS[I];
    assign internal[I].data  = in.data;
    assign internal[I].valid = in.valid && addr_matches[I] ? 1'b1 : 1'b0;

    ShiftRegister #(.WIDTH(AXI_ADDR_BITS + AXIL_DATA_BITS + 1), .LEVELS(REG_LEVELS)) inst_shift_reg (
        .i_clk(clk),
        .i_rst_n(reset_synced),

        .i_data({internal[I].addr, internal[I].data, internal[I].valid}),
        .o_data({     out[I].addr,      out[I].data,      out[I].valid})
    );
end

endmodule
