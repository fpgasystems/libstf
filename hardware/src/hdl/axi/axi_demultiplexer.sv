`timescale 1ns / 1ps

import libstf::*;
import lynxTypes::*;

/**
 * Demultiplexes one input AXI stream into a set of output AXI streams based on a select 
 * configuration.
 */
module AXIDemultiplexer #(
    parameter NUM_STREAMS
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s select, // #(logic[$clog2(NUM_STREAMS) - 1:0])

    AXI4S.s in,
    AXI4S.m out[NUM_STREAMS]
);

ndata_i #(data8_t, AXI_DATA_BITS / 8) in_data();
ndata_i #(data8_t, AXI_DATA_BITS / 8) out_data[NUM_STREAMS]();

assign in_data.data  = in.tdata;
assign in_data.keep  = in.tkeep;
assign in_data.last  = in.tlast;
assign in_data.valid = in.tvalid;
assign in.tready     = in_data.ready;

DataDemultiplexer #(
    .NUM_STREAMS(NUM_STREAMS)
) inst_values_demux (
    .clk(clk),
    .rst_n(rst_n),

    .select(select),

    .in(in_data),
    .out(out_data)
);

for (genvar I = 0; I < NUM_STREAMS; I++) begin
    assign out[I].tdata      = out_data[I].data;
    assign out[I].tkeep      = out_data[I].keep;
    assign out[I].tlast      = out_data[I].last;
    assign out[I].tvalid     = out_data[I].valid;
    assign out_data[I].ready = out[I].tready;
end

endmodule
