`timescale 1ns / 1ps

import lynxTypes::*;
import libstf::*;

`include "axi_macros.svh"
`include "lynx_macros.svh"
`include "libstf_macros.svh"

/*
 * NOTE: the input_data should be wired to the AXI stream where incmonig data
 * will be streamed after a request has been sent via sq_rd.
 * For example, in the case of card memory, it should be
 * axis_card_recv[AXI_STRM_ID].
 * NOTE: the TRANSFER_LENGTH_BYTES must be the same as configured in the
 * writer.
 */
module StreamBufferReader #(
    parameter AXI_STRM_ID = 0,
    parameter TRANSFER_SIZE = TRANSFER_SIZE_BYTES
) (
    input logic clk,
    input logic rst_n,

    metaIntf.m sq_rd,
    metaIntf.s cq_rd,

    stream_buffer_link_i.s link,

    AXI4SR.s in,
    AXI4S.m  out
);

`RESET_RESYNC // Reset pipelining

mem_read_config_i mem_config (.clk(clk), .rst_n(reset_synced));

assign mem_config.vaddr = link.vaddr;
assign mem_config.size = link.size;
assign mem_config.valid = link.valid;
assign link.ready = mem_config.ready;

AXI4S inner_out (.aclk(clk), .aresetn(reset_synced));

StreamReader #(
    .STRM(STRM_CARD),
    .AXI_STRM_ID(AXI_STRM_ID),
    .TRANSFER_LENGTH_BYTES(TRANSFER_SIZE)
) inst_stream_reader (
    .clk(clk),
    .rst_n(reset_synced),

    .sq_rd(sq_rd),
    .cq_rd(cq_rd),

    .mem_config(mem_config),

    .input_data(in),
    .output_data(inner_out)
);

logic last_received, n_last_received;

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        last_received <= 1'b0;
    end else begin
        last_received <= n_last_received;
    end
end

always_comb begin
    n_last_received = last_received;

    if (link.ready && link.valid) begin
        n_last_received = link.last;
    end
end

assign out.tdata = inner_out.tdata;
assign out.tkeep = inner_out.tkeep;
assign out.tlast = inner_out.tlast && last_received;
assign out.tvalid = inner_out.tvalid;
assign inner_out.tready = out.tready;

endmodule
