import libstf::*;

parameter NUM_ELEMENTS = 8;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb axi_ctrl.tie_off_s();
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

// -- Signals --------------------------------------------------------------------------------------
typedef logic[NUM_ELEMENTS - 1:0] mask_t;

AXI4S axi_host_recv_0(.aclk(clk), .aresetn(rst_n));

ndata_i #(data32_t, NUM_ELEMENTS) sorted_seq(.*);
data_i  #(mask_t)                 bitmask(.*);
ndata_i #(mask_t, 1)              bitmask_ndata(.*);

AXI4S bitmask_collected(.aclk(clk), .aresetn(rst_n));

`AXIS_ASSIGN(axis_host_recv[0], axi_host_recv_0) // AXI4SR to AXI4S
AXIToNData #(
    .AXI_WIDTH(AXI_DATA_BITS),
    .NUM_AXI_ELEMENTS(16),
    .data_t(data32_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_axi_to_ndata (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_host_recv_0),
    .out(sorted_seq)
);

SortedSeqToBitmask #(
    .data_t(data32_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_seq_to_bitmask (
    .clk(clk),
    .rst_n(rst_n),
    .in(sorted_seq),
    .out(bitmask)
);

`DATA_ASSIGN(bitmask, bitmask_ndata)
NDataToAXI #(
    .data_t(mask_t),
    .NUM_ELEMENTS(1),
    .AXI_WIDTH(AXI_DATA_BITS),
    .NUM_AXI_ELEMENTS(64)
) inst_ndata_to_axi (
    .clk(clk),
    .rst_n(rst_n),
    .in(bitmask_ndata),
    .out(bitmask_collected)
);
`AXIS_ASSIGN(bitmask_collected, axis_host_send[0])
