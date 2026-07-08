import libstf::*;
import lynxTypes::*;

`include "axi_macros.svh"

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

// -- Interfaces -----------------------------------------------------------------------------------
parameter NUM_ELEMENTS = 512 / 8;
parameter PREVIEW_SIZE = 3;
ndata_i #(data8_t, NUM_ELEMENTS) preview_in(aclk, aresetn);
ndata_i #(data8_t, NUM_ELEMENTS + PREVIEW_SIZE) preview_out (aclk, aresetn);
ndata_i #(data8_t, NUM_ELEMENTS) out_stream_0(aclk, aresetn);
ndata_i #(data8_t, NUM_ELEMENTS) out_stream_1(aclk, aresetn);
ndata_i #(data8_t, NUM_ELEMENTS) out_stream_1_normalized(aclk, aresetn);

AXI4S #(.AXI4S_DATA_BITS(512)) axis_host_recv_0(.aclk(aclk), .aresetn(aresetn));
AXI4S #(.AXI4S_DATA_BITS(512)) axis_host_send_0(.aclk(aclk), .aresetn(aresetn));
AXI4S #(.AXI4S_DATA_BITS(512)) axis_host_send_1(.aclk(aclk), .aresetn(aresetn));
`AXIS_ASSIGN(axis_host_recv[0], axis_host_recv_0)
`AXIS_ASSIGN(axis_host_send_0, axis_host_send[0])
`AXIS_ASSIGN(axis_host_send_1, axis_host_send[1])

AXIToNData #(
    .data_t(data8_t),
    .NUM_ELEMENTS(NUM_ELEMENTS)
) inst_axi_to_ndata (
    .clk(clk),
    .rst_n(rst_n),

    .in(axis_host_recv_0),
    .out(preview_in)
);

Lookahead#(
    .data_t(data8_t),
    .NUM_ELEMENTS(NUM_ELEMENTS),
    .PREVIEW_SIZE(PREVIEW_SIZE)
) preview (
    .clk(aclk),
    .rst_n(aresetn),

    .in(preview_in),
    .out(preview_out)
);

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
) normalize_out_1 (
    .clk(aclk),
    .rst_n(aresetn),

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

for (genvar i = 0; i < NUM_ELEMENTS; ++i) begin
    assign out_stream_0.data[i] = preview_out.data[i];
    assign out_stream_0.keep[i] = preview_out.keep[i];
    assign out_stream_1.data[i] = i < PREVIEW_SIZE ? preview_out.data[NUM_ELEMENTS + i] : 0;
    assign out_stream_1.keep[i] = i < PREVIEW_SIZE & preview_out.keep[NUM_ELEMENTS + i];
end

assign out_stream_0.last = preview_out.last;
assign out_stream_0.valid = preview_out.valid && out_stream_1.ready;
assign out_stream_1.last = preview_out.last;
assign out_stream_1.valid = preview_out.valid && out_stream_0.ready;
assign preview_out.ready = out_stream_0.ready && out_stream_1.ready;
