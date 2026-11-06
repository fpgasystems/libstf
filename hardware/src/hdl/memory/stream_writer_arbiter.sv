`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * Shares one Coyote stream between N_WRITERS StreamWriters.
 *
 * All writers use the same STRM and AXI_STRM_ID, so the shell cannot tell their requests, data and
 * completions apart. A MetaIntfArbiter picks the requests round-robin and every forwarded request
 * goes into two order FIFOs. The data of each transfer is then forwarded in request order up to its
 * tlast, and the completions, which arrive in request order, are routed back in request order.
 *
 * A StreamWriter only issues a request once the whole transfer is buffered, so the transfer at the
 * head of the data order FIFO always drains and the writers cannot block each other.
 */
module StreamWriterArbiter
    import lynxTypes::*;
#(
    parameter N_WRITERS = 2,
    parameter STRM = STRM_HOST,
    parameter AXI_STRM_ID = 0,
    parameter DATA_ORDER_DEPTH = 8,
    parameter CQ_ORDER_DEPTH = 64
) (
    input logic clk,
    input logic rst_n,

    // Writer side
    metaIntf.s sq_wr_in[N_WRITERS],  // #(req_t)
    metaIntf.m cq_wr_out[N_WRITERS], // #(ack_t)
    AXI4SR.s   data_in[N_WRITERS],

    // Stream side
    metaIntf.m sq_wr_out, // #(req_t)
    metaIntf.s cq_wr_in,  // #(ack_t)
    AXI4SR.m   data_out
);

localparam int W = N_WRITERS > 1 ? $clog2(N_WRITERS) : 1;

`ASSERT_ELAB(DATA_ORDER_DEPTH > 1 && 2**$clog2(DATA_ORDER_DEPTH) == DATA_ORDER_DEPTH, "DATA_ORDER_DEPTH has to be a power of two > 1")
`ASSERT_ELAB(CQ_ORDER_DEPTH > 1 && 2**$clog2(CQ_ORDER_DEPTH) == CQ_ORDER_DEPTH, "CQ_ORDER_DEPTH has to be a power of two > 1")

// Interface arrays cannot be indexed dynamically
logic [N_WRITERS - 1:0][AXI_DATA_BITS - 1:0]     in_tdata;
logic [N_WRITERS - 1:0][AXI_DATA_BITS / 8 - 1:0] in_tkeep;
logic [N_WRITERS - 1:0][PID_BITS - 1:0]          in_tid;
logic [N_WRITERS - 1:0]                          in_tlast;
logic [N_WRITERS - 1:0]                          in_tvalid;

logic [N_WRITERS - 1:0] cq_wr_ready;

// ------ Request arbitration ----------------------------------------------
metaIntf #(.STYPE(req_t)) sq_wr_arbitrated(.aclk(clk), .aresetn(rst_n));
logic [W - 1:0]           requester;

MetaIntfArbiter #(
    .N_INTERFACES(N_WRITERS),
    .STYPE(req_t)
) inst_sq_wr_arbiter (
    .clk(clk),
    .rst_n(rst_n),

    .intf_in(sq_wr_in),
    .intf_out(sq_wr_arbitrated),
    .intf_out_select(requester)
);

logic data_order_iready, cq_order_iready, request_fire;

assign sq_wr_out.data         = sq_wr_arbitrated.data;
assign sq_wr_out.valid        = sq_wr_arbitrated.valid && data_order_iready && cq_order_iready;
assign sq_wr_arbitrated.ready = sq_wr_out.ready && data_order_iready && cq_order_iready;
assign request_fire           = sq_wr_out.valid && sq_wr_out.ready;

// ------ Order FIFOs -------------------------------------------------------
// The data order FIFO pops at the end of a transfer's data, the cq order FIFO at its completion
logic [W - 1:0] data_head, cq_head;
logic           data_head_valid, cq_head_valid;
logic           data_pop, cq_pop;

MehdiFIFO #(
    .DEPTH(DATA_ORDER_DEPTH),
    .WIDTH(W),
    .STYLE("distributed")
) inst_data_order_fifo (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data(requester),
    .i_valid(request_fire),
    .i_ready(data_order_iready),

    .o_data(data_head),
    .o_valid(data_head_valid),
    .o_ready(data_pop),

    .o_filling_level()
);

MehdiFIFO #(
    .DEPTH(CQ_ORDER_DEPTH),
    .WIDTH(W),
    .STYLE("distributed")
) inst_cq_order_fifo (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data(requester),
    .i_valid(request_fire),
    .i_ready(cq_order_iready),

    .o_data(cq_head),
    .o_valid(cq_head_valid),
    .o_ready(cq_pop),

    .o_filling_level()
);

// ------ Data --------------------------------------------------------------
assign data_out.tdata  = in_tdata[data_head];
assign data_out.tkeep  = in_tkeep[data_head];
assign data_out.tid    = in_tid[data_head];
assign data_out.tlast  = in_tlast[data_head];
assign data_out.tvalid = data_head_valid && in_tvalid[data_head];

assign data_pop = data_out.tvalid && data_out.tready && data_out.tlast;

// ------ Completions -------------------------------------------------------
// Completions of other streams are dropped, like the StreamWriter does
logic is_completion;
assign is_completion = cq_wr_in.valid && cq_wr_in.data.strm == STRM && cq_wr_in.data.dest == AXI_STRM_ID;

assign cq_wr_in.ready = !is_completion || (cq_head_valid && cq_wr_ready[cq_head]);
assign cq_pop         = is_completion && cq_wr_in.ready;

// ------ Writer connections ------------------------------------------------
for (genvar I = 0; I < N_WRITERS; I++) begin
    assign in_tdata[I]  = data_in[I].tdata;
    assign in_tkeep[I]  = data_in[I].tkeep;
    assign in_tid[I]    = data_in[I].tid;
    assign in_tlast[I]  = data_in[I].tlast;
    assign in_tvalid[I] = data_in[I].tvalid;
    assign data_in[I].tready = data_head_valid && (data_head == W'(I)) && data_out.tready;

    assign cq_wr_out[I].data  = cq_wr_in.data;
    assign cq_wr_out[I].valid = is_completion && cq_head_valid && (cq_head == W'(I));
    assign cq_wr_ready[I]     = cq_wr_out[I].ready;
end

`ifndef SYNTHESIS
assert property (@(posedge clk) disable iff (!rst_n)
    !is_completion || cq_head_valid)
else $fatal(1, "StreamWriterArbiter received a completion without an outstanding request!");
`endif

endmodule
