import libstf::*;
import lynxTypes::*;

`include "axi_macros.svh"

parameter NUM_ELEMENTS = 512 / 8;
parameter PREVIEW_SIZE = 3;

// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb axi_ctrl.tie_off_s();
always_comb notify.tie_off_m();
always_comb sq_rd.tie_off_m();
always_comb sq_wr.tie_off_m();
always_comb cq_rd.tie_off_s();
always_comb cq_wr.tie_off_s();

if (N_STRM_AXI > 1) begin
    always_comb axis_host_recv[1].tie_off_s();
end
for (genvar I = 2; I < N_STRM_AXI; I++) begin
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
ndata_i #(data8_t, NUM_ELEMENTS) lookahead_in(clk, rst_n);
ndata_i #(data8_t, NUM_ELEMENTS + PREVIEW_SIZE) lookahead_out(clk, rst_n);
ndata_i #(data8_t, NUM_ELEMENTS) out_stream_0(clk, rst_n);
ndata_i #(data8_t, NUM_ELEMENTS) out_stream_1(clk, rst_n);
ndata_i #(data8_t, NUM_ELEMENTS) out_stream_1_normalized(clk, rst_n);
AXI4S #(.AXI4S_DATA_BITS(512)) axis_host_send_0(.aclk(clk), .aresetn(rst_n));
AXI4S #(.AXI4S_DATA_BITS(512)) axis_host_send_1(.aclk(clk), .aresetn(rst_n));

// -- Input wiring ---------------------------------------------------------------------------------
`AXIS_ASSIGN(axis_host_recv[0], axis_host_recv_0)

AXIToNData #(
    .data_t(data8_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_axi_to_ndata (
    .clk(clk),
    .rst_n(rst_n),

    .in(axis_host_recv_0),
    .out(lookahead_in)
);

// -- Lookahead ------------------------------------------------------------------------------------
NDataLookahead #(
    .data_t(data8_t),
    .NUM_ELEMENTS(NUM_ELEMENTS),
    .PREVIEW_SIZE(PREVIEW_SIZE)
) inst_lookahead (
    .clk(clk),
    .rst_n(rst_n),

    .in(lookahead_in),
    .out(lookahead_out)
);

// -- Output wiring --------------------------------------------------------------------------------

// Stream 0 contains the original beats
for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign out_stream_0.data[I] = lookahead_out.data[I];
    assign out_stream_0.keep[I] = lookahead_out.keep[I];
end
assign out_stream_0.last  = lookahead_out.last;
assign out_stream_0.valid = lookahead_out.valid && out_stream_1.ready;

// Stream 1 contains the lookahead bytes + one additional byte denoting the keeps of the lookahead
// bytes
for (genvar I = 0; I < PREVIEW_SIZE; I++) begin
    assign out_stream_1.data[I] =
        lookahead_out.keep[NUM_ELEMENTS + I] ? lookahead_out.data[NUM_ELEMENTS + I] : 0;
end
assign out_stream_1.data[PREVIEW_SIZE] = data8_t'(lookahead_out.keep[NUM_ELEMENTS +: PREVIEW_SIZE]);
for (genvar I = PREVIEW_SIZE + 1; I < NUM_ELEMENTS; I++) begin
    assign out_stream_1.data[I] = 0;
end
for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign out_stream_1.keep[I] = I <= PREVIEW_SIZE;
end
assign out_stream_1.last  = lookahead_out.last;
assign out_stream_1.valid = lookahead_out.valid && out_stream_0.ready;

assign lookahead_out.ready = out_stream_0.ready && out_stream_1.ready;

NDataToAXI #(
    .data_t(data8_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_ndata_to_axi_original_view (
    .clk(clk),
    .rst_n(rst_n),

    .in(out_stream_0),
    .out(axis_host_send_0)
);

DataNormalizer #(
    .data_t(data8_t),
    .NUM_ELEMENTS(NUM_ELEMENTS),
    .ENABLE_COMPACTOR(1),
    .COMPACTOR_REGISTER_LEVELS(1),
    .BARREL_SHIFTER_REGISTER_LEVELS(1)
) inst_normalizer (
    .clk(clk),
    .rst_n(rst_n),

    .in(out_stream_1),
    .out(out_stream_1_normalized)
);

NDataToAXI #(
    .data_t(data8_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_ndata_to_axi_extended_view (
    .clk(clk),
    .rst_n(rst_n),

    .in(out_stream_1_normalized),
    .out(axis_host_send_1)
);

`AXIS_ASSIGN(axis_host_send_0, axis_host_send[0])
`AXIS_ASSIGN(axis_host_send_1, axis_host_send[1])
