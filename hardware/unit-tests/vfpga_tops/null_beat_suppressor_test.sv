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
for (genvar I = 0; I < N_CARD_AXI; I++) begin
    always_comb axis_card_send[I].tie_off_m();
    always_comb axis_card_recv[I].tie_off_s();
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
// Only accepts a beat from the suppressor in roughly every fourth cycle to backpressure it
AXI4S throttled_out(.aclk(clk), .aresetn(rst_n));
logic[7:0] lfsr;
logic      throttle_open;
assign throttle_open = lfsr[1:0] == '0;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        lfsr                 <= 8'h1;
        throttled_out.tvalid <= 1'b0;
    end else begin
        lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};

        if (axi_host_send.tvalid && axi_host_send.tready) begin
            throttled_out.tdata  <= axi_host_send.tdata;
            throttled_out.tkeep  <= axi_host_send.tkeep;
            throttled_out.tlast  <= axi_host_send.tlast;
            throttled_out.tvalid <= 1'b1;
        end else if (throttled_out.tready) begin
            throttled_out.tvalid <= 1'b0;
        end
    end
end

assign axi_host_send.tready = throttle_open && (!throttled_out.tvalid || throttled_out.tready);

// The host does not expect any data for empty streams, so we drop their null beat
assign axis_host_send[0].tdata  = throttled_out.tdata;
assign axis_host_send[0].tkeep  = throttled_out.tkeep;
assign axis_host_send[0].tlast  = throttled_out.tlast;
assign axis_host_send[0].tvalid = throttled_out.tvalid && throttled_out.tkeep != '0;
assign throttled_out.tready     = axis_host_send[0].tready || (throttled_out.tvalid && throttled_out.tkeep == '0);

// -- Stream boundary checks -----------------------------------------------------------------------
`ifndef SYNTHESIS
// The host only checks the number of bytes it receives, not where the last signals are. Therefore,
// we check here that every input stream, including empty ones, results in exactly one output stream.
int unsigned expected_stream_bytes[$];
int unsigned in_stream_bytes, out_stream_bytes;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        in_stream_bytes  <= 0;
        out_stream_bytes <= 0;
    end else begin
        if (suppressor_in.tvalid && suppressor_in.tready) begin
            if (suppressor_in.tlast) begin
                expected_stream_bytes.push_back(in_stream_bytes + $countones(suppressor_in.tkeep));
                in_stream_bytes <= 0;
            end else begin
                in_stream_bytes <= in_stream_bytes + $countones(suppressor_in.tkeep);
            end
        end

        if (axi_host_send.tvalid && axi_host_send.tready) begin
            if (axi_host_send.tlast) begin
                if (expected_stream_bytes.size() == 0) begin
                    $fatal(1, "NullBeatSuppressor emitted a last signal without a corresponding input stream!");
                end else if (expected_stream_bytes[0] != out_stream_bytes + $countones(axi_host_send.tkeep)) begin
                    $fatal(1, "NullBeatSuppressor output stream has %0d bytes but the input stream had %0d bytes!",
                        out_stream_bytes + $countones(axi_host_send.tkeep), expected_stream_bytes[0]);
                end
                void'(expected_stream_bytes.pop_front());
                out_stream_bytes <= 0;
            end else begin
                out_stream_bytes <= out_stream_bytes + $countones(axi_host_send.tkeep);
            end
        end
    end
end
`endif
