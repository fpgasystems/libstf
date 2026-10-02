import libstf::*;
import lynxTypes::*;

`include "axi_macros.svh"

parameter NUM_LANES = AXI_DATA_BITS / 64;

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

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Signals --------------------------------------------------------------------------------------
AXI4S axi_host_recv(.aclk(clk), .aresetn(rst_n));
AXI4S suppressor_in(.aclk(clk), .aresetn(rst_n));
AXI4S axi_host_send(.aclk(clk), .aresetn(rst_n));

logic[NUM_LANES - 1:0] lane_empty;

// -- Input wiring ---------------------------------------------------------------------------------
`AXIS_ASSIGN(axis_host_recv[0], axi_host_recv)

// To create null beats from the host stream, we interpret the input as a stream of 64-bit values
// and clear the keep of every beat in which all kept values are zero.
for (genvar I = 0; I < NUM_LANES; I++) begin
    assign lane_empty[I] = !axi_host_recv.tkeep[I * 8] || axi_host_recv.tdata[I * 64+:64] == '0;
end

assign suppressor_in.tdata  = axi_host_recv.tdata;
assign suppressor_in.tkeep  = &lane_empty ? '0 : axi_host_recv.tkeep;
assign suppressor_in.tlast  = axi_host_recv.tlast;
assign suppressor_in.tvalid = axi_host_recv.tvalid;
assign axi_host_recv.tready = suppressor_in.tready;

// -- Null beat suppressor -------------------------------------------------------------------------
AXINullBeatSuppressor inst_null_beat_suppressor (
    .clk(clk),
    .rst_n(rst_n),

    .in(suppressor_in),
    .out(axi_host_send)
);

// -- Output wiring --------------------------------------------------------------------------------
`AXIS_ASSIGN(axi_host_send, axis_host_send[0])
