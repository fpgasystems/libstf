`timescale 1ns / 1ps

import libstf::*;

`include "config_macros.svh"
`include "libstf_macros.svh"

module MemConfig #(
    parameter NUM_STREAMS
) (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    mem_config_i.m out[NUM_STREAMS]
);

`RESET_RESYNC // Reset pipelining

`ASSERT_ELAB(NUM_STREAMS > 0)

localparam MAX_NUM_ENQUEUED_BUFFERS = 64;

// -- Read -----------------------------------------------------------------------------------------
logic[AXIL_DATA_BITS - 1:0] read_registers[2];

assign read_registers[0] = MEM_CONFIG_ID;
assign read_registers[1] = NUM_STREAMS;

ConfigReadRegisterFile #(
    .NUM_REGS(2)
) inst_read_register_file (
    .clk(clk),
    .rst_n(reset_synced),

    .in(read_config),
    .values(read_registers)
);

// -- Write ----------------------------------------------------------------------------------------
ready_valid_i #(logic) flush_buffers();
for (genvar I = 0; I < NUM_STREAMS; I++) begin
    ready_valid_i #(buffer_t) buffer();

    ConfigWriteFIFO #(I, MAX_NUM_ENQUEUED_BUFFERS, buffer_t) inst_buffer_fifo (clk, reset_synced, write_config, buffer);

    `CONFIG_INTF_TO_SIGNALS(buffer, out[I].buffer)

    assign out[I].flush_buffers = flush_buffers.valid;
end

// We misuse this write register a bit just for its valid signal to give a pulse to the OutputWriter
// to flush all remaining potentially stale buffers. We don't actually care about the data that is 
// written.
ConfigWriteReadyRegister #(NUM_STREAMS, logic) inst_flush_buffers (clk, reset_synced, write_config, flush_buffers);

assign flush_buffers.ready = 1'b1;

endmodule
