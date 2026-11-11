`timescale 1ns / 1ps

`include "axi_macros.svh"
`include "lynx_macros.svh"
`include "libstf_macros.svh"

/**
 * This module transfers NUM_PORTS AXI4S ports via FPGA-initiated transfers, over NUM_STREAMS
 * Coyote streams. Stream S carries the next PORTS_PER_STREAM[S] ports. Interrupts carry
 * the port index.
 *
 * IMPORTANT:
 * This component assumes normalized streams.
 * E.g. the keep signal should be all 1s, except for data beats that contain a last signal.
 * In other words: Writing data that is not all 1s and not last will result in UNEXPECTED behavior.
 */
module OutputWriter
    import lynxTypes::*;
    import libstf::*;
#(
    parameter int NUM_STREAMS = N_STRM_AXI,
    // verilog_lint: waive packed-dimensions-range-ordering
    parameter logic [0:NUM_STREAMS - 1][31:0] PORTS_PER_STREAM = '{default: 1},
    localparam int NUM_PORTS = SUM(PORTS_PER_STREAM)
) (
    input logic clk,
    input logic rst_n,

    metaIntf.m sq_wr,
    metaIntf.s cq_wr,
    metaIntf.m notify,

    mem_config_i.s mem_config[NUM_PORTS],

    AXI4S.s  data_in[NUM_PORTS],
    AXI4SR.m data_out[NUM_STREAMS],

    // Counts the interrupts (notifications) sent to the host.
    output data64_t notify_count
);

`RESET_RESYNC // Reset pipelining

function automatic int first_port(int stream);
    int first = 0;
    for (int S = 0; S < stream; S++) begin
        first += PORTS_PER_STREAM[S];
    end
    return first;
endfunction

`ASSERT_ELAB(NUM_STREAMS > 0 && NUM_STREAMS <= N_STRM_AXI,
    "NUM_STREAMS has to be in [1, N_STRM_AXI]")
`ASSERT_ELAB(NUM_PORTS <= 8, "Interrupts carry the port id in 3 bits")

`ifndef SYNTHESIS
for(genvar I = 0; I < NUM_PORTS; I++) begin : gen_port_assertions
    assert property (@(posedge clk) disable iff (!reset_synced)
        !data_in[I].tvalid || data_in[I].tlast || &data_in[I].tkeep)
    else $fatal(1, "Non-last keep signal (%h) must be all 1s!", data_in[I].tkeep);
    assert property (@(posedge clk) disable iff (!reset_synced)
        !data_in[I].tvalid || !data_in[I].tlast || $onehot0(data_in[I].tkeep + 1'b1))
    else $fatal(1,
        "Last keep signal (%h) must be contiguous starting from the least significant bit!",
        data_in[I].tkeep);
end
`endif

// -- De-mux and arbiter the queue and notify signals ----------------------------------------------
metaIntf #(.STYPE(req_t))     sq_wr_strm  [NUM_STREAMS](.aclk(clk), .aresetn(reset_synced));
metaIntf #(.STYPE(ack_t))     cq_wr_strm  [NUM_STREAMS](.aclk(clk), .aresetn(reset_synced));
metaIntf #(.STYPE(irq_not_t)) notify_port [NUM_PORTS] (.aclk(clk), .aresetn(reset_synced));

MetaIntfArbiter #(
  .N_INTERFACES(NUM_STREAMS),
  .data_t(req_t)
) inst_sq_wr_arbiter (
  .clk(clk),
  .rst_n(reset_synced),
  .intf_in(sq_wr_strm),
  .intf_out(sq_wr),
  .intf_out_select()
);

CQDemultiplexer #(
  .N_STREAMS(NUM_STREAMS)
) inst_cq_wr_de_mux (
  .clk(clk),
  .rst_n(reset_synced),
  .data_in(cq_wr),
  .data_out(cq_wr_strm)
);

MetaIntfArbiter #(
  .N_INTERFACES(NUM_PORTS),
  .data_t(irq_not_t)
) inst_notify_arbiter (
  .clk(clk),
  .rst_n(reset_synced),
  .intf_in(notify_port),
  .intf_out(notify),
  .intf_out_select()
);

// -- Notify counter -------------------------------------------------------------------------------
data64_t notify_count_reg;

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        notify_count_reg <= '0;
    end else if (notify.valid && notify.ready) begin
        notify_count_reg <= notify_count_reg + 1;
    end
end

assign notify_count = notify_count_reg;

// -- FPGA-initiated transfers ---------------------------------------------------------------------
localparam int NUM_SKID_STAGES = 2;

for (genvar S = 0; S < NUM_STREAMS; S++) begin : gen_streams
    localparam int FIRST = first_port(S);
    localparam int N     = PORTS_PER_STREAM[S];

    `ASSERT_ELAB(N > 0, "Every stream needs at least one port")

`ifndef DISABLE_OUTPUT_WRITER
    metaIntf #(.STYPE(req_t)) sq_wr_writers[N](.aclk(clk), .aresetn(reset_synced));
    metaIntf #(.STYPE(ack_t)) cq_wr_writers[N](.aclk(clk), .aresetn(reset_synced));
    AXI4SR                    writer_outs  [N](.aclk(clk), .aresetn(reset_synced));

    for (genvar J = 0; J < N; J++) begin : gen_ports
        stream_writer_notify_i stream_notify (.clk(clk), .rst_n(reset_synced));
        stream_writer_notify_i stream_issued (.clk(clk), .rst_n(reset_synced));
        always_comb stream_issued.tie_off_s(); // Unused

        metaIntf #(.STYPE(irq_not_t)) notify_writer(.aclk(clk), .aresetn(reset_synced));

        // Invoke the FPGA-initiated transfers for this port
        StreamWriter #(
            .AXI_STRM_ID(S),
            .TRANSFER_LENGTH_BYTES(TRANSFER_SIZE_BYTES)
        ) inst_stream_writer (
            .clk(clk),
            .rst_n(reset_synced),

            .sq_wr(sq_wr_writers[J]),
            .cq_wr(cq_wr_writers[J]),
            .notify(stream_notify),
            .issued(stream_issued),

            .mem_config(mem_config[FIRST + J]),

            .input_data(data_in[FIRST + J]),
            .output_data(writer_outs[J])
        );

        // The interrupt carries the port, not the stream
        NotifyMetaIntfAdapter #(
            .AXI_STRM_ID(FIRST + J)
        ) inst_notify_adapter (
            .in(stream_notify),
            .out(notify_writer)
        );

        MetaIntfSkidBuffer #(
            .data_t(irq_not_t),
            .NUM_STAGES(NUM_SKID_STAGES)
        ) inst_notify_skid (
            .clk(clk),
            .rst_n(reset_synced),

            .in(notify_writer),
            .out(notify_port[FIRST + J])
        );
    end

    metaIntf #(.STYPE(req_t)) sq_wr_stream(.aclk(clk), .aresetn(reset_synced));
    AXI4SR                    stream_out  (.aclk(clk), .aresetn(reset_synced));

    if (N == 1) begin : gen_single_port
        `META_ASSIGN(sq_wr_writers[0], sq_wr_stream)
        `META_ASSIGN(cq_wr_strm[S], cq_wr_writers[0])
        `AXISR_ASSIGN(writer_outs[0], stream_out)
    end else begin : gen_shared_stream
        StreamWriterArbiter #(
            .N_WRITERS(N),
            .AXI_STRM_ID(S)
        ) inst_arbiter (
            .clk(clk),
            .rst_n(reset_synced),

            .sq_wr_in(sq_wr_writers),
            .cq_wr_out(cq_wr_writers),
            .data_in(writer_outs),

            .sq_wr_out(sq_wr_stream),
            .cq_wr_in(cq_wr_strm[S]),
            .data_out(stream_out)
        );
    end

    MetaIntfSkidBuffer #(
        .data_t(req_t),
        .NUM_STAGES(NUM_SKID_STAGES)
    ) inst_sq_wr_skid (
        .clk(clk),
        .rst_n(reset_synced),

        .in(sq_wr_stream),
        .out(sq_wr_strm[S])
    );

    AXI4S stream_out_s (.aclk(clk), .aresetn(reset_synced));
    AXI4S data_out_s   (.aclk(clk), .aresetn(reset_synced));

    // The StreamWriter always sends with tid 0
    `AXIS_ASSIGN(stream_out, stream_out_s)

    AXISkidBuffer inst_data_out_skid (
        .clk(clk),
        .rst_n(reset_synced),

        .in(stream_out_s),
        .out(data_out_s)
    );

    `AXIS_ASSIGN(data_out_s, data_out[S])
    assign data_out[S].tid = '0;
`else
    `ASSERT_ELAB(N == 1, "Without the output writer every port needs its own stream")

    // Tie of the interfaces we don't need
    always_comb sq_wr_strm [S].tie_off_m();
    always_comb notify_port[FIRST].tie_off_m();
    always_comb cq_wr_strm [S].tie_off_s();

    always_comb mem_config[FIRST].tie_off_s();

    // The output writer can be disabled for certain test cases.
    // In this case, we simply pipe through all the data
    `AXIS_ASSIGN(data_in[FIRST], data_out[S]);
`endif
end

endmodule
