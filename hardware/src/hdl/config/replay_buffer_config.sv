`timescale 1ns / 1ps

import libstf::*;

`include "libstf_macros.svh"
`include "config_macros.svh"

/**
 * Configures NUM_BUFFERS ReplayBuffers. The read registers hold the ID of the configuration,
 * NUM_BUFFERS, how many numbers of reads can be enqueued per buffer at most
 * (MAXIMUM_NUM_ENQUEUED_STREAMS), and the TRANSFER_SIZE of the buffers in bytes. Each buffer has
 * three write registers:
 *   3 * I     The base vaddr of the card memory ring buffer
 *   3 * I + 1 The size of the ring buffer in bytes. Writing it commits base and size, so the base
 *             has to be written first.
 *   3 * I + 2 Enqueues how often the next stream is read. Every stream needs one value >= 1.
 */
module ReplayBufferConfig #(
    parameter NUM_BUFFERS,
    parameter TRANSFER_SIZE = TRANSFER_SIZE_BYTES // Must match the ReplayBuffers
) (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    replay_buffer_config_i.m out[NUM_BUFFERS]
);

`RESET_RESYNC // Reset pipelining

`ASSERT_ELAB(NUM_BUFFERS > 0)

// -- Read -----------------------------------------------------------------------------------------
logic[AXIL_DATA_BITS - 1:0] read_registers[4];

assign read_registers[0] = REPLAY_BUFFER_CONFIG_ID;
assign read_registers[1] = NUM_BUFFERS;
assign read_registers[2] = MAXIMUM_NUM_ENQUEUED_STREAMS;
assign read_registers[3] = TRANSFER_SIZE;

ConfigReadRegisterFile #(
    .NUM_REGS(4)
) inst_read_register_file (
    .clk(clk),
    .rst_n(reset_synced),

    .in(read_config),
    .values(read_registers)
);

// -- Write ----------------------------------------------------------------------------------------
for (genvar I = 0; I < NUM_BUFFERS; I++) begin
    ready_valid_i #(vaddress_t) size(clk, reset_synced);
    ready_valid_i #(data32_t)   num_reads(clk, reset_synced);
    
    ConfigWriteRegister #(3 * I, vaddress_t) inst_base (clk, write_config, out[I].base);
    ConfigWriteReadyRegister #(3 * I + 1, vaddress_t) inst_size (clk, reset_synced, write_config, size);
    ConfigWriteFIFO #(3 * I + 2, MAXIMUM_NUM_ENQUEUED_STREAMS, data32_t) inst_num_reads (clk, reset_synced, write_config, num_reads);

    assign out[I].size  = size.data;
    assign out[I].valid = size.valid;
    assign size.ready   = 1'b1;

    `CONFIG_INTF_TO_SIGNALS(num_reads, out[I].num_reads)
end

endmodule
