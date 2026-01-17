`timescale 1ns / 1ps

import libstf::*;
import lynxTypes::*;

`include "axi_macros.svh"
`include "libstf_macros.svh"

/**
 * This module handles N_STRM_AXI output AXI4S streams. It transfers the output to the host via 
 * FPGA-initiated transfers.
 *
 * IMPORTANT:
 * This component assumes normalized streams.
 * E.g. the keep signal should be all 1s, except for data beats that contain a last signal.
 * In other words: Writing data that is not all 1s and not last will result in UNEXPECTED behavior.
 */
module OutputWriter (
    input logic clk,
    input logic rst_n,

    metaIntf.m sq_wr,
    metaIntf.s cq_wr,
    metaIntf.m notify,

    mem_config_i.s mem_config[N_STRM_AXI],

    AXI4S.s  data_in[N_STRM_AXI],
    AXI4SR.m data_out[N_STRM_AXI]
);

`RESET_RESYNC // Reset pipelining

`ifndef SYNTHESIS
for(genvar I = 0; I < N_STRM_AXI; I++) begin
    assert property (@(posedge clk) disable iff (!reset_synced) 
        !data_in[I].tvalid || data_in[I].tlast || &data_in[I].tkeep)
    else $fatal(1, "Non-last keep signal (%h) must be all 1s!", data_in[I].tkeep);
    assert property (@(posedge clk) disable iff (!reset_synced) 
        !data_in[I].tvalid || !data_in[I].tlast || $onehot0(data_in[I].tkeep + 1'b1))
    else $fatal(1, "Last keep signal (%h) must be contiguous starting from the least significant bit!", data_in[I].tkeep);
end
`endif

// -- De-mux and arbiter the queue and notify signals ----------------------------------------------
metaIntf #(.STYPE(req_t))     sq_wr_strm  [N_STRM_AXI](.aclk(clk), .aresetn(reset_synced));
metaIntf #(.STYPE(ack_t))     cq_wr_strm  [N_STRM_AXI](.aclk(clk), .aresetn(reset_synced));
metaIntf #(.STYPE(irq_not_t)) notify_strm [N_STRM_AXI](.aclk(clk), .aresetn(reset_synced));

MetaIntfArbiter #(
  .N_INTERFACES(N_STRM_AXI),
  .STYPE(req_t)
) inst_sq_wr_arbiter (
  .clk(clk),
  .rst_n(reset_synced),
  .intf_in(sq_wr_strm),
  .intf_out(sq_wr)
);

CQDemultiplexer #(
  .N_STREAMS(N_STRM_AXI)
) inst_cq_wr_de_mux (
  .clk(clk),
  .rst_n(reset_synced),
  .data_in(cq_wr),
  .data_out(cq_wr_strm)
);

MetaIntfArbiter #(
  .N_INTERFACES(N_STRM_AXI),
  .STYPE(irq_not_t)
) inst_notify_arbiter (
  .clk(clk),
  .rst_n(reset_synced),
  .intf_in(notify_strm),
  .intf_out(notify)
);

// -- FPGA-initiated transfers ---------------------------------------------------------------------
for(genvar I = 0; I < N_STRM_AXI; I++) begin
`ifndef DISABLE_OUTPUT_WRITER
    // Invoke the FPGA-initiated transfers for this stream
    StreamWriter #(
        .AXI_STRM_ID(I),
        .TRANSFER_LENGTH_BYTES(TRANSFER_SIZE_BYTES)
    ) inst_stream_writer (
        .clk(clk),
        .rst_n(reset_synced),

        .sq_wr(sq_wr_strm[I]),
        .cq_wr(cq_wr_strm[I]),
        .notify(notify_strm[I]),

        .mem_config(mem_config[I]),

        .input_data(data_in[I]),
        .output_data(data_out[I])
    );
`else
    // Tie of the interfaces we don't need
    always_comb sq_wr_strm [I].tie_off_m();
    always_comb notify_strm[I].tie_off_m();
    always_comb cq_wr_strm [I].tie_off_s();

    always_comb mem_config[I].tie_off_s();

    // The output writer can be disabled for certain test cases.
    // In this case, we simply pipe through all the data
    `AXIS_ASSIGN(data_in[I], data_out[I]);
`endif
end

endmodule
