`timescale 1ns / 1ps

module AXIMultiplexer
    import lynxTypes::*;
    import libstf::*;
#(
    parameter NUM_STREAMS
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s select, // #(logic[$clog2(NUM_STREAMS) - 1:0])

    AXI4S.s in[NUM_STREAMS],
    AXI4S.m out
);

ndata_i #(data8_t, AXI_DATA_BITS / 8) in_data[NUM_STREAMS](clk, rst_n);
ndata_i #(data8_t, AXI_DATA_BITS / 8) out_data(clk, rst_n);

for (genvar I = 0; I < NUM_STREAMS; I++) begin
    assign in_data[I].data  = in[I].tdata;
    assign in_data[I].keep  = in[I].tkeep;
    assign in_data[I].last  = in[I].tlast;
    assign in_data[I].valid = in[I].tvalid;
    assign in[I].tready     = in_data[I].ready;
end

DataMultiplexer #(
    .data_t(data8_t),
    .NUM_ELEMENTS(AXI_DATA_BITS / 8),
    .NUM_STREAMS(NUM_STREAMS)
) inst_mux (
    .clk(clk),
    .rst_n(rst_n),

    .select(select),

    .in(in_data),
    .out(out_data)
);

assign out.tdata      = out_data.data;
assign out.tkeep      = out_data.keep;
assign out.tlast      = out_data.last;
assign out.tvalid     = out_data.valid;
assign out_data.ready = out.tready;

endmodule
