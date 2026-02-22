// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb axi_ctrl.tie_off_s();
always_comb notify.tie_off_m();

for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb axis_host_send[I].tie_off_m();
    always_comb axis_host_recv[I].tie_off_s();
end
for (genvar I = 1; I < N_CARD_AXI; I++) begin
    always_comb axis_card_send[I].tie_off_m();
    always_comb axis_card_recv[I].tie_off_s();
end

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Input ----------------------------------------------
AXI4S axi_host_send_0(.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axi_host_send_0, axis_host_send[0]) // AXI4SR to AXI4S

// -- Output ---------------------------------------------
AXI4S axi_host_recv_0(.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[0], axi_host_recv_0) // AXI4SR to AXI4S

// -- Design wiring --------------------------------------
stream_buffer_link_i link ();

StreamBufferWriter #(
    .TRANSFER_SIZE(64),
    .TRANFERS_PER_ALLOCATION(1)
) inst_stream_buffer_writer (
    .clk(aclk),
    .rst_n(rst_n),

    .sq_wr(sq_wr),
    .cq_wr(cq_wr),

    .link(link),

    .in(axi_host_recv_0),
    .out(axis_card_send[0])
);

StreamBufferReader #(
    .TRANSFER_SIZE(64)
) inst_stream_buffer_reader (
    .clk(aclk),
    .rst_n(rst_n),

    .sq_rd(sq_rd),
    .cq_rd(cq_rd),

    .link(link),

    .in(axis_card_recv[0]),
    .out(axi_host_send_0)
);
