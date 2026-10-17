`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * A sub-configuration that can be used to expose a bunch of signals as readable and writeable 
 * configuration registers. Useful when you want to access signals that do not necessarily belong to 
 * any major component. We use this, for example, in the output buffer manager example to expose 
 * performance counters that we don't need in the MemConfig otherwise.
 */
module GenericConfig
    import lynxTypes::*;
    import libstf::*;
#(
    parameter NUM_READ_REGISTERS,
    parameter NUM_WRITE_REGISTERS
) (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    read_config_i.s  read_config,

    input logic[AXIL_DATA_BITS - 1:0] in[NUM_READ_REGISTERS],
    output logic[AXIL_DATA_BITS - 1:0] out[NUM_WRITE_REGISTERS]
);

`RESET_RESYNC // Reset pipelining

`ASSERT_ELAB(NUM_READ_REGISTERS  > 0)
`ASSERT_ELAB(NUM_WRITE_REGISTERS > 0)

// -- Read -----------------------------------------------------------------------------------------
logic[AXIL_DATA_BITS - 1:0] read_registers[NUM_READ_REGISTERS + 1];

assign read_registers[0] = GENERIC_CONFIG_ID;
for (genvar I = 0; I < NUM_READ_REGISTERS; I++) begin
    assign read_registers[I + 1] = in[I];
end

ConfigReadRegisterFile #(
    .NUM_REGS(NUM_READ_REGISTERS + 1)
) inst_read_reg_file (
    .clk(clk),
    .rst_n(reset_synced),

    .in(read_config),
    .values(read_registers)
);

// -- Write ----------------------------------------------------------------------------------------
for (genvar I = 0; I < NUM_WRITE_REGISTERS; I++) begin
    ConfigWriteRegister #(I, data64_t) inst_write_reg (clk, write_config, out[I]);
end

endmodule
