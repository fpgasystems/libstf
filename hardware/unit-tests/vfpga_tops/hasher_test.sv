import libstf::*;
import lynxTypes::*;

`include "axi_macros.svh"

parameter type data_t = data32_t;
parameter NUM_ELEMENTS = 16;
parameter HASH_WIDTH = 32;

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

// -- Typedef --------------------------------------------------------------------------------------
typedef struct packed {
    data_t key;
} hasher_data_t;

// -- Signals --------------------------------------------------------------------------------------
ndata_i   #(data_t, NUM_ELEMENTS)                    ndata_in();
ndata_i   #(hasher_data_t, NUM_ELEMENTS)             hasher_in();
ntagged_i #(hasher_data_t, HASH_WIDTH, NUM_ELEMENTS) hasher_out();
ndata_i   #(data_t, NUM_ELEMENTS)                    ndata_out();

// -- Logic ----------------------------------------------------------------------------------------
AXI4S axi_host_recv(.aclk(clk), .aresetn(rst_n)), axi_host_send(.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[0], axi_host_recv)

AXIToNData #(
  .data_t(data_t),
  .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_axi_to_data (
    .clk(clk),
    .rst_n(rst_n),

    .in(axi_host_recv),
    .out(ndata_in)
);

`DATA_ASSIGN(ndata_in, hasher_in)

StreamHasher #(
    .tuple_t(hasher_data_t), 
    .NUM_TUPLES(NUM_ELEMENTS), 
    .HASH_WIDTH(HASH_WIDTH)
) inst_hasher (
    .clk(clk),
    .rst_n(rst_n),

    .in(hasher_in),
    .out(hasher_out)
);

assign ndata_out.data   = hasher_out.tag;
assign ndata_out.keep   = hasher_out.keep;
assign ndata_out.last   = hasher_out.last;
assign ndata_out.valid  = hasher_out.valid;
assign hasher_out.ready = ndata_out.ready;

NDataToAXI #(
    .data_t(data_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_probe_to_axi (
    .clk(clk),
    .rst_n(rst_n),

    .in(ndata_out),
    .out(axi_host_send)
);

`AXIS_ASSIGN(axi_host_send, axis_host_send[0])
