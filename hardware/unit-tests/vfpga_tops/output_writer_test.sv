
// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb sq_rd.tie_off_m();
always_comb cq_rd.tie_off_s();

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Configuration --------------------------------------------------------------------------------
write_config_i write_configs[1](.*);
read_config_i  read_configs [1](.*);

GlobalConfig #(
    .SYSTEM_ID(0),
    .NUM_CONFIGS(1),
    .ADDR_SPACE_SIZES({N_STRM_AXI + 1})
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

mem_config_i mem_config[N_STRM_AXI](.*);
MemConfig #(
    .NUM_STREAMS(N_STRM_AXI)
) inst_mem_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(mem_config)
);

// -- Output writer --------------------------------------
AXI4S axi_host_recv[N_STRM_AXI](.aclk(clk), .aresetn(rst_n));
for (genvar I = 0; I < N_STRM_AXI; I++) begin
    `AXIS_ASSIGN(axis_host_recv[I], axi_host_recv[I]) // AXI4SR to AXI4S
end

OutputWriter inst_output_writer (
    .clk(aclk),
    .rst_n(rst_n),

    .sq_wr(sq_wr),
    .cq_wr(cq_wr),
    .notify(notify),

    .mem_config(mem_config),

    .data_in(axi_host_recv),
    .data_out(axis_host_send)
);
