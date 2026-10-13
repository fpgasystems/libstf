`timescale 1ns / 1ps

import libstf::*;
import lynxTypes::*;

`include "axi_macros.svh"
`include "libstf_macros.svh"

/**
 * The writing side of a ReplayBuffer. It writes the streams from in to a ring buffer in the card
 * memory and announces every written transfer to the ReplayBufferReader via the link. The ring
 * buffer is configured via buffer_config. Its memory is reused once the reader released it, i.e.,
 * after the last read of a stream. If the ring buffer is full, the writer applies back pressure to
 * in. A stream that is read more than once has to fit into the ring buffer completely, see the
 * ReplayBufferReader.
 *
 * The ring buffer is filled one transfer of TRANSFER_SIZE bytes at a time: the memory of each
 * transfer is handed to the StreamWriter as a buffer of one transfer. The next transfer is handed
 * out as soon as the StreamWriter requested the current one. The reader, however, is only notified
 * once a write completed. Every stream starts at a multiple of AXI_DATA_BITS / 8 bytes.
 *
 * The ring buffer has to be configured before the first stream and can only be reconfigured while
 * the buffer is idle, i.e., when all streams were read. Its base has to be aligned to
 * AXI_DATA_BITS / 8 bytes and it needs to fit at least two transfers.
 *
 * The out port must be wired to axis_card_send[AXI_STRM_ID].
 */
module ReplayBufferWriter #(
    parameter AXI_STRM_ID = 0,
    parameter TRANSFER_SIZE = TRANSFER_SIZE_BYTES
) (
    input logic clk,
    input logic rst_n,

    metaIntf.m sq_wr,
    metaIntf.s cq_wr,

    replay_buffer_config_i.writer buffer_config,

    AXI4S.s in,

    replay_buffer_link_i.m link,
    AXI4SR.m               out
);

`RESET_RESYNC // Reset pipelining

// -- Parameters -----------------------------------------------------------------------------------
localparam AXI_DATA_BYTES = AXI_DATA_BITS / 8;
localparam vaddress_t TRANSFER_BYTES = TRANSFER_SIZE;

stream_writer_notify_i issued (.clk(clk), .rst_n(reset_synced));
stream_writer_notify_i notify (.clk(clk), .rst_n(reset_synced));
mem_config_i mem_config (.clk(clk), .rst_n(reset_synced));

// -- Assertions -----------------------------------------------------------------------------------
`ifndef SYNTHESIS
assert property (@(posedge clk) disable iff (!reset_synced)
    !buffer_config.valid || buffer_config.base % AXI_DATA_BYTES == 0)
else $fatal(1, "Ring buffer base (%0x) must be aligned to %0d bytes!", buffer_config.base, AXI_DATA_BYTES);
assert property (@(posedge clk) disable iff (!reset_synced)
    !buffer_config.valid || buffer_config.size >= 2 * TRANSFER_BYTES)
else $fatal(1, "Ring buffer size (%0d) must fit at least two transfers of %0d bytes!", buffer_config.size, TRANSFER_BYTES);
assert property (@(posedge clk) disable iff (!reset_synced)
    !(issued.valid && !issued.last) || issued.size == TRANSFER_BYTES)
else $fatal(1, "Non-last transfer size (%0d) must be the transfer size!", issued.size);
`endif

// -- Ring buffer state ----------------------------------------------------------------------------
typedef enum logic {
    ALLOCATE, // We need to hand the memory of the next transfer to the StreamWriter
    WRITE     // The StreamWriter writes the current transfer
} state_t;
state_t state;

logic      configured;
vaddress_t ring_base, ring_size, ring_end;

// Start of the current transfer or, in the ALLOCATE state, where the next transfer would start
vaddress_t transfer_vaddr;
// Bytes of the ring buffer that are neither reserved for transfers nor waiting for the reader
vaddress_t free_bytes;

// -- Next transfer --------------------------------------------------------------------------------
// A transfer must not wrap around the end of the ring buffer. If it does not fit before the end, we
// skip the remaining bytes and start the transfer at the base. The skipped bytes are reserved until
// the reader releases the first transfer after them.
//
// For timing, the next transfer is computed in two register stages after transfer_vaddr changed:
//   1. Where it starts and how many bytes it reserves
//   2. Whether these bytes are free
vaddress_t bytes_to_end, next_vaddr, next_reserved;
logic      next_fits, next_granted;
// Shifts in a 1 for every cycle since transfer_vaddr changed. The next transfer is valid once both
// stages were computed for the current transfer_vaddr.
logic[1:0] next_stages_valid;

assign bytes_to_end = ring_end - transfer_vaddr;

always_ff @(posedge clk) begin
    next_vaddr    <= bytes_to_end < TRANSFER_BYTES ? ring_base : transfer_vaddr;
    next_reserved <= bytes_to_end < TRANSFER_BYTES ? bytes_to_end + TRANSFER_BYTES : TRANSFER_BYTES;
    next_fits     <= free_bytes >= next_reserved;
end

buffer_t next_buffer;
assign next_buffer.vaddr = next_vaddr;
assign next_buffer.size  = 1; // In transfers

assign mem_config.buffer_data  = next_buffer;
assign mem_config.buffer_valid = state == ALLOCATE && configured && next_stages_valid[1] && next_fits;
// A new configuration drops the buffer the StreamWriter might currently hold. The StreamWriter only
// leaves its flush state once buffer_valid is low, which it is for two cycles because the
// configuration clears next_stages_valid.
assign mem_config.flush_buffers = buffer_config.valid;

assign next_granted = mem_config.buffer_valid && mem_config.buffer_ready;

// -- Issued transfers -----------------------------------------------------------------------------
// The StreamWriter tells us as soon as it requested the write of a transfer. We use this to place
// the next transfer.
vaddress_t issued_size_aligned;

assign issued_size_aligned = (issued.size + AXI_DATA_BYTES - 1) & ~vaddress_t'(AXI_DATA_BYTES - 1);
always_comb issued.tie_off_s();

// -- Notification ---------------------------------------------------------------------------------
// The StreamWriter notifies us once the write of a transfer completed. We forward it to the reader.
assign link.vaddr   = notify.vaddr;
assign link.size    = notify.size;
assign link.last    = notify.last;
assign link.valid   = notify.valid;
assign notify.ready = link.ready;

// -- Unreserved bytes -----------------------------------------------------------------------------
// Bytes become free again when the reader released them or when a non-empty stream ended before its
// last transfer was full. In the latter case, the next stream starts right after it, so we give back
// the rest of the transfer. For timing, we sum these up over two register stages before adding them
// to free_bytes. This only delays reusing the memory.
vaddress_t released_bytes, returned_bytes, unreserved_bytes;

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0 || buffer_config.valid) begin
        released_bytes   <= '0;
        returned_bytes   <= '0;
        unreserved_bytes <= '0;
    end else begin
        released_bytes   <= link.released_valid ? link.released_bytes : '0;
        returned_bytes   <= issued.valid && issued.last && issued.size != 0 ?
                            TRANSFER_BYTES - issued_size_aligned : '0;
        unreserved_bytes <= released_bytes + returned_bytes;
    end
end

// -- State machine --------------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        configured        <= 1'b0;
        next_stages_valid <= '0;

        state <= ALLOCATE;
    end else begin
        next_stages_valid <= {next_stages_valid[0], 1'b1};

        if (buffer_config.valid) begin
            configured <= 1'b1;
            ring_base  <= buffer_config.base;
            ring_size  <= buffer_config.size;
            ring_end   <= buffer_config.base + buffer_config.size;

            transfer_vaddr    <= buffer_config.base;
            next_stages_valid <= '0;
            free_bytes        <= buffer_config.size;

            state <= ALLOCATE;
        end else begin
            free_bytes <= free_bytes - (next_granted ? next_reserved : '0) + unreserved_bytes;

            case (state)
                ALLOCATE: begin
                    if (next_granted) begin
                        transfer_vaddr    <= next_vaddr;
                        next_stages_valid <= '0;

                        state <= WRITE;
                    end
                end

                WRITE: begin
                    if (issued.valid) begin
                        if (!issued.last) begin
                            // The transfer is full
                            transfer_vaddr    <= transfer_vaddr + TRANSFER_BYTES;
                            next_stages_valid <= '0;
                            state             <= ALLOCATE;
                        end else if (issued.size != 0) begin
                            transfer_vaddr    <= transfer_vaddr + issued_size_aligned;
                            next_stages_valid <= '0;
                            state             <= ALLOCATE;
                        end
                        // Otherwise, this was an empty stream and the StreamWriter keeps the memory
                        // of the current transfer
                    end
                end
            endcase
        end
    end
end

// -- Deadlock detection ---------------------------------------------------------------------------
`ifndef SYNTHESIS
// If the reader holds a stream it reads multiple times, it can only release memory once we wrote the
// rest of that stream. So if the ring buffer is too full for the next transfer of the stream, and
// no written transfer is on its way to the reader anymore, nothing can make progress.
localparam integer DEADLOCK_CYCLES = 1024;

int unsigned stalled_cycles;

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        stalled_cycles <= 0;
    end else if (state == ALLOCATE && configured && !next_fits && link.holding && !notify.valid) begin
        stalled_cycles <= stalled_cycles + 1;
    end else begin
        stalled_cycles <= 0;
    end
end

assert property (@(posedge clk) disable iff (!reset_synced) stalled_cycles < DEADLOCK_CYCLES)
else $fatal(1, "ReplayBuffer deadlock: A stream that is read multiple times does not fit into the ring buffer of %0d bytes!", ring_size);
`endif

// -- Stream writer --------------------------------------------------------------------------------
StreamWriter #(
    .STRM(STRM_CARD),
    .AXI_STRM_ID(AXI_STRM_ID),
    .TRANSFER_LENGTH_BYTES(TRANSFER_SIZE)
) inst_stream_writer (
    .clk(clk),
    .rst_n(reset_synced),

    .sq_wr(sq_wr),
    .cq_wr(cq_wr),

    .issued(issued),
    .notify(notify),

    .mem_config(mem_config),

    .input_data(in),
    .output_data(out)
);

endmodule
