`timescale 1ns / 1ps

`include "config_macros.svh"
`include "libstf_macros.svh"

/**
 * Configures the buffers the OutputWriter writes the output streams to.
 *
 * EMPTY_STREAM_CONSUMES_BUFFER = What an input stream without data does with its buffer.
 *                                0: Nothing is written to it and no buffer is consumed.
 *                                1: A buffer is consumed so the next input stream is written to
 *                                   the next buffer (e.g. for software that provides one buffer
 *                                   per input stream ahead of time).
 *
 * The address space of this config has to fit max(NUM_STREAMS + 1, 4) registers.
 */
module MemConfig
    import lynxTypes::*;
    import libstf::*;
#(
    parameter NUM_STREAMS,
    parameter EMPTY_STREAM_CONSUMES_BUFFER = 0
) (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    mem_config_i.m out[NUM_STREAMS]
);

`RESET_RESYNC // Reset pipelining

`ASSERT_ELAB(NUM_STREAMS > 0)
`ASSERT_ELAB(MAXIMUM_NUM_ENQUEUED_BUFFERS > 0)

// -- Read -----------------------------------------------------------------------------------------
logic[AXIL_DATA_BITS - 1:0] read_registers[4];

assign read_registers[0] = MEM_CONFIG_ID;
assign read_registers[1] = NUM_STREAMS;
assign read_registers[2] = MAXIMUM_NUM_ENQUEUED_BUFFERS;
assign read_registers[3] = EMPTY_STREAM_CONSUMES_BUFFER;

ConfigReadRegisterFile #(
    .NUM_REGS(4)
) inst_read_register_file (
    .clk(clk),
    .rst_n(reset_synced),

    .in(read_config),
    .values(read_registers)
);

// -- Write ----------------------------------------------------------------------------------------
ready_valid_i #(logic) flush_buffers(clk, reset_synced);
for (genvar I = 0; I < NUM_STREAMS; I++) begin
    ready_valid_i #(buffer_t) buffer(clk, reset_synced);

    ConfigWriteFIFO #(I, MAXIMUM_NUM_ENQUEUED_BUFFERS, buffer_t) inst_buffer_fifo (clk, reset_synced, write_config, buffer);

    `CONFIG_INTF_TO_SIGNALS(buffer, out[I].buffer)

    assign out[I].flush_buffers                = flush_buffers.valid;
    assign out[I].empty_stream_consumes_buffer = EMPTY_STREAM_CONSUMES_BUFFER;
end

// We misuse this write register a bit just for its valid signal to give a pulse to the OutputWriter
// to flush all remaining potentially stale buffers. We don't actually care about the data that is 
// written.
ConfigWriteReadyRegister #(NUM_STREAMS, logic) inst_flush_buffers (clk, reset_synced, write_config, flush_buffers);

assign flush_buffers.ready = 1'b1;

endmodule
