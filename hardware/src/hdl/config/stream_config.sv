`timescale 1ns / 1ps

`include "libstf_macros.svh"
`include "config_macros.svh"

module StreamConfig #(
    parameter NUM_STREAMS
) (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    stream_config_i.m out[NUM_STREAMS]
);

`RESET_RESYNC // Reset pipelining

localparam MAX_OUTSTANDING_STREAMS = 64;

// -- Read -----------------------------------------------------------------------------------------
logic[AXIL_DATA_BITS - 1:0] read_registers[2];

assign read_registers[0] = STREAM_CONFIG_ID;
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
for (genvar I = 0; I < NUM_STREAMS; I++) begin
    ready_valid_i #(stream_conf_t) conf_reg();
    ready_valid_i #(select_t)      select();
    ready_valid_i #(type_t)        data_type();

    ConfigWriteFIFO #(I, MAX_OUTSTANDING_STREAMS, stream_conf_t) inst_write_fifo (clk, reset_synced, write_config, conf_reg);

    `READY_SPLIT(select_t, type_t, conf_reg, select, data_type)

    `CONFIG_INTF_TO_SIGNALS(select,    out[I].select)
    `CONFIG_INTF_TO_SIGNALS(data_type, out[I].data_type)
end

endmodule
