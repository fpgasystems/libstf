import libstf::*;

parameter NUM_ELEMENTS = 512 / 8;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb axi_ctrl.tie_off_s();
always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();

for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb axis_host_send[I].tie_off_m();
    always_comb axis_host_recv[I].tie_off_s();
end

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Interfaces -----------------------------------------------------------------------------------
AXI4S #(.AXI4S_DATA_BITS(512)) axis_host_recv_0(.aclk(clk), .aresetn(rst_n));
ndata_i #(data8_t, NUM_ELEMENTS) normalizer_in();
ndata_i #(data8_t, NUM_ELEMENTS) normalizer_out();
AXI4S #(.AXI4S_DATA_BITS(512)) axis_host_send_0(.aclk(clk), .aresetn(rst_n));

// -- Input wiring ---------------------------------------------------------------------------------

// To test the normalization we assume fixed data and assign the data of the incoming host stream to 
// the keep of the normalizer input.
assign axis_host_recv_0.tdata  = 512'h3F3E3D3C3B3A393837363534333231302F2E2D2C2B2A292827262524232221201F1E1D1C1B1A191817161514131211100F0E0D0C0B0A09080706050403020100;
assign axis_host_recv_0.tvalid = axis_host_recv[0].tvalid;
assign axis_host_recv_0.tkeep  = axis_host_recv[0].tdata[63:0];
assign axis_host_recv_0.tlast  = axis_host_recv[0].tlast;
assign axis_host_recv[0].tready = axis_host_recv_0.tready;

AXIToNData #(
    .data_t(data8_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_axi_to_ndata (
    .clk(clk),
    .rst_n(rst_n),

    .in(axis_host_recv_0),
    .out(normalizer_in)
);

// -- Stream Normalizer ----------------------------------------------------------------------------
DataNormalizer #( 
  .data_t(data8_t),
  .NUM_ELEMENTS(NUM_ELEMENTS),
  .ENABLE_COMPACTOR(1)
) inst_normalizer (
  .clk(clk),
  .rst_n(rst_n),

  .in(normalizer_in),
  .out(normalizer_out)
);

// -- Output wiring --------------------------------------------------------------------------------
NDataToAXI #(
    .data_t(data8_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_ndata_to_axi (
    .clk(clk),
    .rst_n(reset_synced),

    .in(normalizer_out),
    .out(axis_host_send_0)
);

`AXIS_ASSIGN(axis_host_send_0, axis_host_send[0])
