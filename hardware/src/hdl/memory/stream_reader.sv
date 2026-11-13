`timescale 1ns / 1ps

`include "axi_macros.svh"
`include "lynx_macros.svh"
`include "libstf_macros.svh"

/**
 * This module reads the buffers provided by mem_config via FPGA-initiated transfers and
 * streams their data to the out stream. The transfers are triggered via the sq_rd interface. This
 * is the reading counterpart of the StreamWriter.
 *
 * Each buffer is read with transfers of at most TRANSFER_LENGTH_BYTES. tlast is only set on the
 * final beat of a buffer with mem_config.last set. A buffer with size 0 and last set produces a
 * single null beat (tkeep == '0) with tlast, i.e., an empty stream. buffer_done pulses once all
 * data of a buffer was received, i.e., once the memory of the buffer can be reused. The pulses are
 * in the order of the buffers.
 *
 * The transfers are requested as soon as possible, independent of the data that is still being
 * received. This relies on Coyote returning the data of a stream in the order of the requests. At
 * most MAX_OUTSTANDING_TRANSFERS transfers can be outstanding.
 *
 * The in stream should be connected to the AXI stream of the stream as configured via the
 * STRM parameter, e.g., axis_card_recv[AXI_STRM_ID] for card memory.
 */
module StreamReader
    import lynxTypes::*;
    import libstf::*;
#(
    parameter int STRM = STRM_HOST,
    parameter int AXI_STRM_ID = 0,
    parameter int IS_LOCAL = 1,
    parameter int TRANSFER_LENGTH_BYTES = 4096,
    parameter int MAX_OUTSTANDING_TRANSFERS = 16
) (
    input logic clk,
    input logic rst_n,

    metaIntf.m sq_rd, // #(req_t)
    metaIntf.s cq_rd, // #(ack_t)

    mem_read_config_i.s mem_config,
    output logic        buffer_done,

    AXI4SR.s in, // #(AXI_DATA_BITS)
    AXI4S.m  out // #(AXI_DATA_BITS)
);

`RESET_RESYNC // Reset pipelining

// -- Parameters -----------------------------------------------------------------------------------
// These localparams are untyped on purpose. Typing them makes the Vivado source scan fail in
// designs that do not use this module ([filemgmt 56-315]). Vivado then disables files that the
// design needs.

// For RDMA, Coyote parses RDMA_READ requests into read requests of at most the PMTU
localparam OPCODE = IS_LOCAL ? LOCAL_READ : RDMA_READ;
// How many bits we need to address one transfer of size TRANSFER_LENGTH_BYTES
localparam TRANSFER_ADDRESS_LEN_BITS = $clog2(TRANSFER_LENGTH_BYTES) + 1;
localparam AXI_DATA_BYTES = (AXI_DATA_BITS / 8);
localparam BEAT_BITS = $clog2(AXI_DATA_BYTES);

// -- Assertions -----------------------------------------------------------------------------------

// TRANSFER_LENGTH_BYTES must be a multiple of AXI_DATA_BYTES
`ASSERT_ELAB(TRANSFER_LENGTH_BYTES % AXI_DATA_BYTES == 0)

`ASSERT_ELAB(MAX_OUTSTANDING_TRANSFERS > 1 &&
    2 ** $clog2(MAX_OUTSTANDING_TRANSFERS) == MAX_OUTSTANDING_TRANSFERS,
    "MAX_OUTSTANDING_TRANSFERS has to be a power of two > 1")

`ifndef SYNTHESIS
// Input stream
assert property (@(posedge clk) disable iff (!reset_synced)
    !in.tvalid || in.tlast || &in.tkeep)
else $fatal(1, "Non-last keep signal (%h) must be all 1s!", in.tkeep);
assert property (@(posedge clk) disable iff (!reset_synced)
    !in.tvalid || !in.tlast || $onehot0(in.tkeep + 1'b1))
else $fatal(1, "Last keep signal (%h) must be contiguous starting from the least significant bit!",
    in.tkeep);

// Buffers
assert property (@(posedge clk) disable iff (!reset_synced)
    !mem_config.valid || (mem_config.size > 0) || mem_config.last)
else $fatal(1, "Buffer size (%0d) must be > 0 for non-last buffers!", mem_config.size);
`endif

// -- Outstanding transfers ------------------------------------------------------------------------
// We remember every requested transfer until we received all its data. A buffer without data gets
// an entry with length 0, so its end is signaled in order with the data of the other buffers.
typedef struct packed {
    logic[TRANSFER_ADDRESS_LEN_BITS - 1:0] len;          // Bytes of the transfer
    logic                                  buffer_end;   // Whether this is the last transfer of
                                                         // a buffer
    logic                                  buffer_last;  // Whether the buffer ends the stream
} outstanding_t;

outstanding_t outstanding_in, outstanding_out;
logic outstanding_in_valid, outstanding_in_ready, outstanding_out_valid, outstanding_out_ready;

MehdiFIFO #(
    .WIDTH($bits(outstanding_t)),
    .DEPTH(MAX_OUTSTANDING_TRANSFERS),
    .STYLE(MAX_OUTSTANDING_TRANSFERS <= 64 ? "distributed" : "block")
) inst_outstanding_fifo (
    .clk(clk),
    .rst_n(reset_synced),

    .in_data(outstanding_in),
    .in_valid(outstanding_in_valid),
    .in_ready(outstanding_in_ready),

    .out_data(outstanding_out),
    .out_valid(outstanding_out_valid),
    .out_ready(outstanding_out_ready),

    .filling_level()
);

// -- Requests -------------------------------------------------------------------------------------
typedef enum logic {
    WAIT_FOR_BUFFER,
    REQUEST
} request_state_t;
request_state_t request_state;

// The vaddr of the next transfer and how many bytes of the current buffer we still need to request
vaddress_t vaddr, remaining;
logic      buffer_last;
data32_t   next_transfer_len;

assign next_transfer_len = remaining > TRANSFER_LENGTH_BYTES ? TRANSFER_LENGTH_BYTES :
                                                               data32_t'(remaining);

// A buffer without data does not need a request, so we only enqueue it as outstanding
assign mem_config.ready = request_state == WAIT_FOR_BUFFER && outstanding_in_ready;

// We do not need the completions because the arrival of the data already tells us that a transfer
// is done
always_comb cq_rd.tie_off_s();

always_comb begin
    sq_rd.data = '0; // Null everything else

    sq_rd.data.opcode = OPCODE;
    sq_rd.data.strm   = STRM;

    // Note: We always send to coyote thread id 0.
    sq_rd.data.pid  = 0;
    sq_rd.data.dest = AXI_STRM_ID;

    sq_rd.data.vaddr = vaddr;
    sq_rd.data.len   = next_transfer_len;

    // We always mark the transfer as last so we get
    // one acknowledgement per transfer!
    sq_rd.data.last = 1;

    // We only request a transfer if we can remember it until its data arrived
    sq_rd.valid = request_state == REQUEST && outstanding_in_ready;
end

always_comb begin
    if (request_state == WAIT_FOR_BUFFER) begin
        outstanding_in.len         = '0;
        outstanding_in.buffer_end  = 1'b1;
        outstanding_in.buffer_last = mem_config.last;
        outstanding_in_valid       = mem_config.valid && mem_config.ready && mem_config.size == 0;
    end else begin
        outstanding_in.len         = next_transfer_len;
        outstanding_in.buffer_end  = remaining == next_transfer_len;
        outstanding_in.buffer_last = buffer_last;
        outstanding_in_valid       = sq_rd.valid && sq_rd.ready;
    end
end

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        vaddr       <= 'X;
        remaining   <= 'X;
        buffer_last <= 'X;

        request_state <= WAIT_FOR_BUFFER;
    end else begin
        case (request_state)
            WAIT_FOR_BUFFER: begin
                if (mem_config.valid && mem_config.ready && mem_config.size != 0) begin
                    vaddr       <= mem_config.vaddr;
                    remaining   <= mem_config.size;
                    buffer_last <= mem_config.last;

                    request_state <= REQUEST;
                end
            end

            REQUEST: begin
                if (sq_rd.valid && sq_rd.ready) begin
                    vaddr     <= vaddr + next_transfer_len;
                    remaining <= remaining - next_transfer_len;

                    if (remaining == next_transfer_len) begin
                        request_state <= WAIT_FOR_BUFFER;
                    end
                end
            end
            default: ;
        endcase
    end
end

// -- Received data --------------------------------------------------------------------------------
// Tracking of the beats we received for the oldest outstanding transfer
localparam TRANSFER_BEAT_COUNTER_WIDTH = TRANSFER_ADDRESS_LEN_BITS - BEAT_BITS;
logic[TRANSFER_BEAT_COUNTER_WIDTH - 1:0] beats_received, beats_received_succ;
logic has_partial_beat, transfer_completed, is_empty;

assign has_partial_beat    = |(outstanding_out.len[BEAT_BITS - 1:0]);
assign beats_received_succ = beats_received + 1;
assign transfer_completed  = beats_received_succ ==
                             (outstanding_out.len >> BEAT_BITS) + has_partial_beat;
assign is_empty            = outstanding_out.len == '0;

AXI4S internal_data(.aclk(clk), .aresetn(reset_synced));
AXI4S output_axis  (.aclk(clk), .aresetn(reset_synced));

always_comb begin
    if (!is_empty) begin
        internal_data.tdata  = in.tdata;
        // The last flag has to travel with the data beat. Otherwise, the next buffer could change
        // it while the final beat of this buffer is still held in the skid buffer below.
        internal_data.tkeep  = in.tkeep;
        internal_data.tlast  = transfer_completed && outstanding_out.buffer_end &&
                               outstanding_out.buffer_last;
        internal_data.tvalid = outstanding_out_valid && in.tvalid;
        in.tready            = outstanding_out_valid && internal_data.tready;

        outstanding_out_ready = in.tvalid && in.tready && transfer_completed;
    end else begin
        // A buffer without data that ends a stream produces an empty stream. Its data must not
        // follow the input, which might already receive the next transfer.
        internal_data.tdata  = '0;
        internal_data.tkeep  = '0;
        internal_data.tlast  = 1'b1;
        internal_data.tvalid = outstanding_out_valid && outstanding_out.buffer_last;
        in.tready            = 1'b0;

        outstanding_out_ready = outstanding_out_valid &&
                                (!outstanding_out.buffer_last || internal_data.tready);
    end

    buffer_done = outstanding_out_ready && outstanding_out.buffer_end;
end

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        beats_received <= '0;
    end else if (in.tvalid && in.tready) begin
        beats_received <= transfer_completed ? '0 : beats_received_succ;
    end
end

AXISkidBuffer inst_skid_buffer (
    .clk(clk),
    .rst_n(reset_synced),

    .in(internal_data),
    .out(output_axis)
);

`AXIS_ASSIGN(output_axis, out);

endmodule
