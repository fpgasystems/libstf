import libstf::*;
import lynxTypes::*;

`include "axi_macros.svh"

parameter NUM_ELEMENTS = 8;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();

for (genvar I = 2; I < N_STRM_AXI; I++) begin
    always_comb axis_host_recv[I].tie_off_s();
end
for (genvar I = 0; I < N_CARD_AXI; I++) begin
    always_comb axis_card_send[I].tie_off_m();
    always_comb axis_card_recv[I].tie_off_s();
end

// -- Types ----------------------------------------------------------------------------------------
typedef logic[0:0] select_t;

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Signals --------------------------------------------------------------------------------------
AXI4S axi_host_recv_0(.aclk(clk), .aresetn(rst_n));
AXI4S axi_host_recv_1(.aclk(clk), .aresetn(rst_n));

ndata_i #(data64_t, NUM_ELEMENTS) dict_values();
ndata_i #(data32_t, NUM_ELEMENTS) dict_ids();
ndata_i #(data64_t, NUM_ELEMENTS) dict_out();

AXI4S axi_out[N_STRM_AXI](.aclk(clk), .aresetn(rst_n));

// -- Configuration --------------------------------------------------------------------------------
write_config_i write_configs[1](.*);
read_config_i  read_configs [1](.*);
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

stream_config_i stream_config[1](.*);
StreamConfig #(
    .NUM_STREAMS(1)
) inst_stream_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(stream_config)
);

ready_valid_i #(type_t) data_type();
ready_valid_i #(type_t) in_data_type();
ready_valid_i #(type_t) out_data_type();

`CONFIG_SIGNALS_TO_INTF(stream_config[0].data_type, data_type)
`READY_DUPLICATE(2, data_type, {in_data_type, out_data_type})

assign stream_config[0].select_ready = 1'b1;

// -- Input multiplexing ---------------------------------------------------------------------------
// Values
`AXIS_ASSIGN(axis_host_recv[0], axi_host_recv_0) // AXI4SR to AXI4S
AXIToNDataTyped #(
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_values_axi_to_data (
    .clk(clk),
    .rst_n(rst_n),

    .in_type(in_data_type),

    .in(axi_host_recv_0),
    .out(dict_values)
);

// Indices
`AXIS_ASSIGN(axis_host_recv[1], axi_host_recv_1) // AXI4SR to AXI4S
AXIToNData #(
    .AXI_WIDTH(AXI_DATA_BITS),
    .NUM_AXI_ELEMENTS(16),
    .data_t(data32_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_dict_id_axi_to_data (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_host_recv_1),
    .out(dict_ids)
);

// -- Materialization ------------------------------------------------------------------------------
Dictionary #(
    .value_t(data64_t),
    .id_t(data32_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_dict (
    .clk(clk),
    .rst_n(rst_n),

    .in_values(dict_values),
    .in_ids(dict_ids),

    .out(dict_out)
);

// -- Output multiplexing --------------------------------------------------------------------------
NDataToAXITyped #(
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_data_to_axi (
    .clk(clk),
    .rst_n(rst_n),

    .out_type(out_data_type),

    .in(dict_out),
    .out(axi_out[0])
);

for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb axi_out[I].tie_off_m();
end

for (genvar I = 0; I < N_STRM_AXI; I++) begin
    `AXIS_ASSIGN(axi_out[I], axis_host_send[I])
end
