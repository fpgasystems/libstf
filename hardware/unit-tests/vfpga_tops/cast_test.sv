import lynxTypes::*;
import libstf::*;

`include "axi_macros.svh"
`include "libstf_macros.svh"
`include "config_macros.svh"

parameter DATABEAT_SIZE = AXI_DATA_BITS / 8;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();

for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
    always_comb axis_host_send[I].tie_off_m();
end
for (genvar I = 0; I < N_CARD_AXI; I++) begin
    always_comb axis_card_send[I].tie_off_m();
    always_comb axis_card_recv[I].tie_off_s();
end

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Configuration --------------------------------------------------------------------------------
write_config_i write_configs[1](clk, rst_n);
read_config_i  read_configs [1](clk, rst_n);
GlobalConfig #(
    .SYSTEM_ID(0),
    .NUM_CONFIGS(1),
    .ADDR_SPACE_SIZES({2})
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

// The stream config holds the output type of each transfer
stream_config_i stream_config[1](clk, rst_n);
StreamConfig #(
    .NUM_STREAMS(1)
) inst_stream_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(stream_config)
);

ready_valid_i #(type_t) out_type(clk, rst_n);
`CONFIG_SIGNALS_TO_INTF(stream_config[0].data_type, out_type)

assign stream_config[0].select_ready = 1'b1;

// -- Input ----------------------------------------------------------------------------------------
AXI4S axi_host_recv(.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[0], axi_host_recv) // AXI4SR to AXI4S

// The input always contains 32 bit values
ready_valid_i #(type_t) in_type(clk, rst_n);
assign in_type.data  = INT32_T;
assign in_type.valid = 1'b1;

typed_ndata_i #(DATABEAT_SIZE) in_data(clk, rst_n);
AXIToTypedNData #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_axi_to_data (
    .clk(clk),
    .rst_n(rst_n),

    .in_type(in_type),

    .in(axi_host_recv),
    .out(in_data)
);

// -- Cast -----------------------------------------------------------------------------------------
typed_ndata_i #(DATABEAT_SIZE) out_data(clk, rst_n);
TypedNDataCast #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_cast (
    .clk(clk),
    .rst_n(rst_n),

    .out_type(out_type),

    .in(in_data),
    .out(out_data)
);

// -- Output ---------------------------------------------------------------------------------------
AXI4S axi_host_send(.aclk(clk), .aresetn(rst_n));
TypedNDataToAXI #(
    .DATABEAT_SIZE(DATABEAT_SIZE)
) inst_data_to_axi (
    .clk(clk),
    .rst_n(rst_n),

    .in(out_data),
    .out(axi_host_send)
);

`AXIS_ASSIGN(axi_host_send, axis_host_send[0])
