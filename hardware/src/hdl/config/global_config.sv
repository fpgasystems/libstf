`timescale 1ns / 1ps

`include "axi_macros.svh"
`include "axi_intf.sv"
`include "libstf_macros.svh"

/**
 * This module handles the configuration of the design. As the first parameter, it takes a system id 
 * that should be a unique identifier so the software side can check which design is loaded to the 
 * FPGA. It also takes a number of configurations and their address space bounds.
 *
 * On the axi_ctrl input, it receives configuration messages and forwards them to the corresponding 
 * configuration based on the address spaces.
 */
module GlobalConfig #(
    parameter integer SYSTEM_ID,
    parameter integer NUM_CONFIGS,
    parameter integer ADDR_SPACE_SIZES[NUM_CONFIGS]
) (
    input logic clk,
    input logic rst_n,

    AXI4L.s axi_ctrl,

    write_config_i.m write_configs[NUM_CONFIGS],
    read_config_i.m  read_configs[NUM_CONFIGS]
);

`RESET_RESYNC // Reset pipelining

// -- Global parameters ----------------------------------------------------------------------------
typedef integer bounds_t[NUM_CONFIGS + 2];

localparam integer NUM_GLOBAL_REGS = 2 + NUM_CONFIGS;

// Prefix sum including the global read registers
function automatic bounds_t get_read_bounds();
    bounds_t result;
    result[0] = 0;
    result[1] = NUM_GLOBAL_REGS;

    for (int i = 0; i < NUM_CONFIGS; i++) begin
        result[i + 2] = result[i + 1] + ADDR_SPACE_SIZES[i];
    end

    return result;
endfunction;

localparam bounds_t ADDR_SPACE_BOUNDS = get_read_bounds();
localparam integer NUM_TOTAL_REGS  = ADDR_SPACE_BOUNDS[NUM_CONFIGS + 1];

// Note: We read the address shifted to the right by ADDR_LSB (3)
// The reason is that the address is supposed to address bytes,
// not registers but we work based on registers!
// Every register has AXIL_DATA_BITS (64) bits/8 bytes
// -> We shift the address by 3 bit to the right
//    To address the whole register!
localparam integer ADDR_LSB = $clog2(AXIL_DATA_BITS / 8);
localparam integer ADDR_MSB = $clog2(NUM_TOTAL_REGS);
localparam integer AXI_ADDR_BITS = ADDR_LSB + ADDR_MSB;

// Response status codes
localparam logic[1:0] RESP_OKAY   = 2'b00;
localparam logic[1:0] RESP_SLVERR = 2'b10;

// =================================================================================================
// Write
// =================================================================================================

// Note: It is possible that the write address & data are valid but there is no valid data to write
//       (axi_ctrl.wstrb is all zeroes). In this case we cannot set the register to valid as this 
//       case is different from writing all zero to the registers.
// -> We track whether there is any valid data to determine if the register is actually written.
logic any_wstrb;
assign any_wstrb = |axi_ctrl.wstrb;

write_config_i pre_write_splitter_config(.clk(clk), .rst_n(reset_synced));

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        pre_write_splitter_config.valid <= 1'b0;
    end else begin
        if (axi_ctrl.awvalid && axi_ctrl.wvalid) begin // Address and data valid
            pre_write_splitter_config.data  <= axi_ctrl.wdata;
            pre_write_splitter_config.addr  <= axi_ctrl.awaddr[ADDR_LSB+:ADDR_MSB];
            pre_write_splitter_config.valid <= any_wstrb;
        end else begin
            pre_write_splitter_config.valid <= 1'b0;
        end
    end
end

WriteConfigSplitter #(
    .NUM_CONFIGS(NUM_CONFIGS),
    .ADDR_SPACE_BOUNDS(ADDR_SPACE_BOUNDS[1:NUM_CONFIGS + 1])
) inst_write_config_splitter (
    .clk(clk),
    .rst_n(reset_synced),

    .in(pre_write_splitter_config),
    .out(write_configs)
);

// -- AXI4L handshaking logic ----------------------------------------------------------------------

// Write address & data
assign axi_ctrl.awready = axi_ctrl.wvalid;
assign axi_ctrl.wready  = axi_ctrl.awvalid;

// Write acknowledge
assign axi_ctrl.bresp = RESP_OKAY; // We cannot correctly handle errors here because burst writes 
                                   // that occur in real hardware may write addresses that do not 
                                   // correspond to an actual register. Thus, we always return 
                                   // RESP_OKAY.

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        axi_ctrl.bvalid <= 1'b0;
    end else begin
        if (axi_ctrl.awvalid && axi_ctrl.wvalid) begin
            axi_ctrl.bvalid <= 1'b1;
        end else if (axi_ctrl.bready) begin
            axi_ctrl.bvalid <= 1'b0;
        end
    end
end

// =================================================================================================
// Read
// =================================================================================================
read_config_i pre_read_splitter_config(.clk(clk), .rst_n(reset_synced));
read_config_i internal_read_configs[NUM_CONFIGS + 1](.clk(clk), .rst_n(reset_synced));

always_ff @(posedge clk) begin
    if(reset_synced == 1'b0) begin
        pre_read_splitter_config.read_valid <= 1'b0;
    end else begin
        if (pre_read_splitter_config.read_ready) begin
            pre_read_splitter_config.read_addr  <= axi_ctrl.araddr[ADDR_LSB+:ADDR_MSB];
            pre_read_splitter_config.read_valid <= axi_ctrl.arvalid;
        end
    end
end

ReadConfigSplitter #(
    .NUM_CONFIGS(NUM_CONFIGS + 1),
    .ADDR_SPACE_BOUNDS(ADDR_SPACE_BOUNDS)
) inst_read_config_splitter (
    .clk(clk),
    .rst_n(reset_synced),

    .in(pre_read_splitter_config),
    .out(internal_read_configs)
);

// Global register file for system id, number of configurations and configuration address spaces
logic[AXIL_DATA_BITS - 1:0] global_registers[NUM_GLOBAL_REGS];

assign global_registers[0] = SYSTEM_ID;
assign global_registers[1] = NUM_CONFIGS;

for (genvar I = 0; I < NUM_CONFIGS; I++) begin
    assign global_registers[I + 2] = ADDR_SPACE_BOUNDS[I + 2];
end

ConfigReadRegisterFile #(
    .NUM_REGS(NUM_GLOBAL_REGS)
) inst_read_register_file (
    .clk(clk),
    .rst_n(reset_synced),

    .in(internal_read_configs[0]),
    .values(global_registers)
);

// All other read configs
for (genvar I = 0; I < NUM_CONFIGS; I++) begin
    assign read_configs[I].read_addr  = internal_read_configs[I + 1].read_addr;
    assign read_configs[I].read_valid = internal_read_configs[I + 1].read_valid;
    assign internal_read_configs[I + 1].read_ready = read_configs[I].read_ready;

    assign internal_read_configs[I + 1].resp_data  = read_configs[I].resp_data;
    assign internal_read_configs[I + 1].resp_error = read_configs[I].resp_error;
    assign internal_read_configs[I + 1].resp_valid = read_configs[I].resp_valid;
    assign read_configs[I].resp_ready = internal_read_configs[I + 1].resp_ready;
end

// -- AXI4L handshaking logic ----------------------------------------------------------------------

// Read address
assign axi_ctrl.arready = pre_read_splitter_config.read_ready;

// Read response: rvalid and rresp
assign axi_ctrl.rdata  = pre_read_splitter_config.resp_data;
assign axi_ctrl.rresp  = RESP_OKAY; // We cannot correctly handle errors here because burst reads 
                                    // that occur in real hardware may read addresses that do not 
                                    // correspond to an actual register. Thus, we always return 
                                    // RESP_OKAY.
assign axi_ctrl.rvalid = pre_read_splitter_config.resp_valid;

assign pre_read_splitter_config.resp_ready = axi_ctrl.rready;

endmodule
