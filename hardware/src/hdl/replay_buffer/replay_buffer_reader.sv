`timescale 1ns / 1ps

`include "axi_macros.svh"
`include "lynx_macros.svh"
`include "libstf_macros.svh"

/**
 * The reading side of a ReplayBuffer. It reads the transfers announced by the ReplayBufferWriter
 * via the link from the card memory and streams them to out. Every stream is read as often as
 * configured via buffer_config.num_reads, one after another. Each read produces a complete output
 * stream.
 *
 * The reader accepts every written transfer immediately, so the writer can run ahead as far as the
 * ring buffer allows. Consecutive transfers of a stream are contiguous unless the writer wrapped
 * around the end of the ring buffer, so we sum them up into extents. An extent ends at the end of a
 * stream or at a wrap. At most MAX_WAITING_EXTENTS extents can wait for the reader.
 *
 * The first read of a stream reads its extents as soon as they are written, in reads of at most
 * MAX_TRANSFERS_PER_READ transfers. A stream that is read once releases its memory read by read,
 * so it can be larger than the ring buffer. A stream that is read multiple times is only released
 * after its last read. Therefore, it has to fit into the ring buffer completely, together with the
 * bytes skipped at the end of the ring buffer. Otherwise, the buffer deadlocks. Such a stream wraps
 * around the end of the ring buffer at most once, so we remember it as at most two segments.
 *
 * The in port must be wired to axis_card_recv[AXI_STRM_ID].
 */
module ReplayBufferReader
    import lynxTypes::*;
    import libstf::*;
#(
    parameter int AXI_STRM_ID = 0,
    parameter int TRANSFER_SIZE = TRANSFER_SIZE_BYTES,
    parameter int MAX_TRANSFERS_PER_READ = 16,
    parameter int MAX_WAITING_EXTENTS = MAXIMUM_NUM_ENQUEUED_STREAMS
) (
    input logic clk,
    input logic rst_n,

    metaIntf.m sq_rd, // #(req_t)
    metaIntf.s cq_rd, // #(ack_t)

    replay_buffer_config_i.reader buffer_config,

    replay_buffer_link_i.s link,

    AXI4SR.s in, // #(AXI_DATA_BITS)
    AXI4S.m  out // #(AXI_DATA_BITS)
);

`RESET_RESYNC // Reset pipelining

// -- Parameters -----------------------------------------------------------------------------------
localparam int AXI_DATA_BYTES = AXI_DATA_BITS / 8;
localparam vaddress_t MAX_READ_BYTES = MAX_TRANSFERS_PER_READ * TRANSFER_SIZE;
localparam int MAX_OUTSTANDING_READS = 16;

`ASSERT_ELAB(AXI_STRM_ID >= 0 && AXI_STRM_ID < N_CARD_AXI, "AXI_STRM_ID has to be a card stream")
`ASSERT_ELAB(MAX_TRANSFERS_PER_READ > 0, "Every read needs to read at least one transfer")

function automatic vaddress_t align(vaddress_t value);
    return (value + AXI_DATA_BYTES - 1) & ~vaddress_t'(AXI_DATA_BYTES - 1);
endfunction

// The end of the ring buffer
vaddress_t ring_end;

// -- Extents --------------------------------------------------------------------------------------
typedef struct packed {
    vaddress_t vaddr;
    vaddress_t size;         // In bytes
    vaddress_t size_aligned; // The size aligned to AXI_DATA_BYTES, stored for timing
    logic      last;         // Whether the extent ends a stream
} extent_t;

// The newest extent, which might still grow. Once it is closed, it moves to the extent FIFO.
extent_t   tail;
logic      tail_valid, tail_closed;
vaddress_t tail_end; // Where the next transfer starts if it continues the tail
logic      link_continues_tail;

assign link_continues_tail = tail_valid && !tail_closed && link.vaddr == tail_end;

extent_t extent_out;
logic    extent_in_valid, extent_in_ready, extent_out_valid, extent_out_ready;
// The number of extents in the FIFO, which we track ourselves because the FIFO output might lag
// behind its input
logic[$clog2(MAX_WAITING_EXTENTS + 1) - 1:0] num_extents, n_num_extents;
// Whether num_extents != 0. It selects the head and has a high fanout, so it is registered.
logic has_extents;

// Distributed RAM registers the output, which the read logic below needs for timing
MehdiFIFO #(
    .WIDTH($bits(extent_t)),
    .DEPTH(MAX_WAITING_EXTENTS),
    .STYLE("distributed")
) inst_extent_fifo (
    .clk(clk),
    .rst_n(reset_synced),

    .in_data(tail),
    .in_valid(extent_in_valid),
    .in_ready(extent_in_ready),

    .out_data(extent_out),
    .out_valid(extent_out_valid),
    .out_ready(extent_out_ready),

    .filling_level()
);

assign extent_in_valid = tail_valid && tail_closed;
// A transfer either continues the tail or starts the next tail once the closed tail moved to the
// FIFO. The vaddr is only compared while it is valid, so ready is always defined.
assign link.ready = !tail_valid || (!tail_closed && (!link.valid || link.vaddr == tail_end));

// How many extents that end a stream were closed but not yet read
logic[$clog2(MAX_WAITING_EXTENTS + 2) - 1:0] num_closed_streams;

// -- Read engine state ----------------------------------------------------------------------------
typedef enum logic[1:0] {
    WAIT_FOR_STREAM, // Waits for the number of reads of the next stream
    FIRST_READ,      // Reads the extents of the stream while they are written
    REPLAY           // Reads the segments of the stored stream again
} state_t;
state_t state;

// How often we still need to read the current stream after the ongoing read
data32_t remaining_reads;

// The oldest extent: the head of the FIFO or, if the FIFO is empty, the open tail
logic      head_valid, head_closed;
extent_t   head;
vaddress_t head_read;     // Bytes of the oldest extent we already read
vaddress_t head_read_max; // head_read + MAX_READ_BYTES, registered for timing

always_comb begin
    if (has_extents) begin
        head        = extent_out;
        head_valid  = extent_out_valid;
        head_closed = 1'b1;
    end else begin
        head        = tail;
        head_valid  = tail_valid && !tail_closed;
        head_closed = 1'b0;
    end
end

// The stored stream: segment 0 and, if it wraps around the end of the ring buffer, segment 1
vaddress_t seg_vaddr[2], seg_size[2], seg_end[2];
logic      wrapped;
logic[1:0] num_segments;
logic      replay_seg;
// The bytes the stored stream occupies in the ring buffer, including the bytes the writer skipped
// at the end of the ring buffer between its segments
vaddress_t stream_span;
// The bytes from the start of segment 0 to the end of the ring buffer, precomputed for timing
vaddress_t seg_to_ring_end;

// We cannot release anything of a stream we read multiple times before we got all of it
assign link.holding = state == FIRST_READ && remaining_reads != 0 && num_closed_streams == 0;

// -- Releases -------------------------------------------------------------------------------------
// Every read we hand to the StreamReader remembers which memory it releases once it is done.
typedef struct packed {
    logic      release_memory;
    vaddress_t start; // Where the released memory starts if no bytes were skipped before it
    vaddress_t span;  // The bytes of the released memory after start
    vaddress_t end_vaddr;
} release_t;

release_t release_in, release_out;
logic     release_in_valid, release_in_ready, release_out_valid;
logic     buffer_done;

MehdiFIFO #(
    .WIDTH($bits(release_t)),
    .DEPTH(MAX_OUTSTANDING_READS),
    .STYLE("distributed")
) inst_release_fifo (
    .clk(clk),
    .rst_n(reset_synced),

    .in_data(release_in),
    .in_valid(release_in_valid),
    .in_ready(release_in_ready),

    .out_data(release_out),
    .out_valid(release_out_valid),
    .out_ready(buffer_done),

    .filling_level()
);

// The end of the memory we already released
vaddress_t released_end;

// If the released memory does not continue the previously released memory, it starts at the base
// after the writer skipped the rest of the ring buffer. The release is registered for timing.
always_ff @(posedge clk) begin
    if (!reset_synced) begin
        link.released_valid <= 1'b0;
    end else begin
        link.released_valid <= buffer_done && release_out.release_memory;
    end

    link.released_bytes <= (release_out.start != released_end ? ring_end - released_end : '0) +
                           release_out.span;
    if (buffer_done && release_out.release_memory) begin
        released_end <= release_out.end_vaddr;
    end

    if (buffer_config.valid) begin
        released_end <= buffer_config.base;
    end
end

// -- Reads ----------------------------------------------------------------------------------------
// The next read we hand to the StreamReader. It is held in registers, so it is stable until it is
// accepted, even though the tail keeps growing.
mem_read_config_i mem_config (.clk(clk), .rst_n(reset_synced));

logic      read_valid;
vaddress_t read_vaddr, read_size;
logic      read_last;
release_t  read_release;

assign mem_config.vaddr = read_vaddr;
assign mem_config.size  = read_size;
assign mem_config.last  = read_last;
assign mem_config.valid = read_valid && release_in_ready;

assign release_in       = read_release;
assign release_in_valid = mem_config.valid && mem_config.ready;

// The next read of the first read of a stream. Only the last transfer of a stream can be unaligned,
// so head_read is aligned while bytes of the head are available. For timing, we compute the values
// that depend on the read size for both cases in parallel.
vaddress_t head_available, first_read_size;
logic      read_more; // Whether more than MAX_READ_BYTES of the head are available

assign head_available  = head.size - head_read;
assign read_more       = head.size > head_read_max;
assign first_read_size = read_more ? MAX_READ_BYTES : head_available;

// We take the oldest extent from the FIFO once we read all of it. If the FIFO is not empty, it
// holds the head, so we compare its output directly.
assign extent_out_ready = state == FIRST_READ && !read_valid && has_extents &&
                          extent_out_valid && extent_out.size <= head_read_max;

assign buffer_config.num_reads_ready = state == WAIT_FOR_STREAM;

// -- Assertions -----------------------------------------------------------------------------------
`ifndef SYNTHESIS
assert property (@(posedge clk) disable iff (!reset_synced)
    !buffer_config.num_reads_valid || buffer_config.num_reads_data > 0)
else $fatal(1, "Every stream has to be read at least once!");
// A stream that is read multiple times and wraps around the end of the ring buffer twice cannot
// have fit into the ring buffer
assert property (@(posedge clk) disable iff (!reset_synced)
    !(extent_out_ready && remaining_reads != 0 && num_segments == 2))
else $fatal(1, "A stream that is read multiple times does not fit into the ring buffer!");
`endif

// -- State machine --------------------------------------------------------------------------------
assign n_num_extents = num_extents + (extent_in_valid && extent_in_ready) - extent_out_ready;

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        tail        <= 'X;
        tail_valid  <= 1'b0;
        tail_end    <= 'X;
        tail_closed <= 1'b0;

        num_extents        <= '0;
        has_extents        <= 1'b0;
        num_closed_streams <= '0;

        remaining_reads <= '0;
        head_read       <= '0;
        head_read_max   <= MAX_READ_BYTES;
        num_segments    <= '0;
        wrapped         <= 1'b0;

        read_valid <= 1'b0;
        read_vaddr <= 'X;
        read_size  <= 'X;
        read_last  <= 'X;

        read_release <= 'X;

        seg_vaddr   <= '{default: 'X};
        seg_size    <= '{default: 'X};
        seg_end     <= '{default: 'X};
        stream_span <= 'X;

        seg_to_ring_end <= 'X;

        replay_seg <= 1'b0;

        ring_end <= 'X;

        state <= WAIT_FOR_STREAM;
    end else begin
        // -- Extents ------------------------------------------------------------------------------
        if (link.valid && link.ready) begin
            // Only the last transfer of a stream can be unaligned, so the aligned sizes add up
            if (link_continues_tail) begin
                tail.size         <= tail.size + link.size;
                tail.size_aligned <= tail.size_aligned + align(link.size);
                tail.last         <= link.last;
            end else begin
                tail.vaddr        <= link.vaddr;
                tail.size         <= link.size;
                tail.size_aligned <= align(link.size);
                tail.last         <= link.last;
                tail_valid        <= 1'b1;
            end
            tail_end    <= link.vaddr + align(link.size);
            tail_closed <= link.last;
        end else if (link.valid && tail_valid && !tail_closed && !link_continues_tail) begin
            // The writer wrapped around the end of the ring buffer
            tail_closed <= 1'b1;
        end

        if (extent_in_valid && extent_in_ready) begin
            tail_valid <= 1'b0;
        end

        num_extents        <= n_num_extents;
        has_extents        <= n_num_extents != 0;
        num_closed_streams <= num_closed_streams + (link.valid && link.ready && link.last) -
                              (extent_out_ready && extent_out.last);

        // -- Reads --------------------------------------------------------------------------------
        if (mem_config.valid && mem_config.ready) begin
            read_valid <= 1'b0;
        end

        case (state)
            WAIT_FOR_STREAM: begin
                if (buffer_config.num_reads_valid) begin
                    remaining_reads <= buffer_config.num_reads_data - 1;
                    head_read       <= '0;
                    head_read_max   <= MAX_READ_BYTES;
                    num_segments    <= '0;
                    wrapped         <= 1'b0;

                    state <= FIRST_READ;
                end
            end

            FIRST_READ: begin
                if (!read_valid && head_valid &&
                    (head_available != 0 || (head_closed && head.size == 0))) begin
                    // Read what was written of the oldest extent. A closed extent without data is
                    // an empty stream.
                    read_valid <= 1'b1;
                    read_vaddr <= head.vaddr + head_read;
                    read_size  <= first_read_size;
                    read_last  <= head_closed && !read_more && head.last;

                    read_release.release_memory <= remaining_reads == 0;
                    read_release.start          <= head.vaddr + head_read;
                    read_release.span           <= read_more ? MAX_READ_BYTES :
                                                               head.size_aligned - head_read;
                    read_release.end_vaddr      <= head.vaddr +
                                                   (read_more ? head_read_max : head.size_aligned);

                    head_read     <= read_more ? head_read_max : head.size;
                    head_read_max <= (read_more ? head_read_max : head.size) + MAX_READ_BYTES;
                end

                if (extent_out_ready) begin
                    head_read     <= '0;
                    head_read_max <= MAX_READ_BYTES;

                    // Remember where the stream is stored for the replays
                    if (num_segments == 0) begin
                        seg_vaddr[0]    <= head.vaddr;
                        seg_size[0]     <= head.size;
                        seg_end[0]      <= head.vaddr + head.size_aligned;
                        stream_span     <= head.size_aligned;
                        seg_to_ring_end <= ring_end - head.vaddr;
                    end else if (num_segments == 1) begin
                        // Segment 0 and the skipped bytes span from seg_vaddr[0] to ring_end
                        wrapped      <= 1'b1;
                        seg_vaddr[1] <= head.vaddr;
                        seg_size[1]  <= head.size;
                        seg_end[1]   <= head.vaddr + head.size_aligned;
                        stream_span  <= seg_to_ring_end + head.size_aligned;
                    end
                    num_segments <= num_segments == 2 ? 2'd2 : num_segments + 1;

                    if (head.last) begin
                        replay_seg <= 1'b0;
                        state      <= remaining_reads == 0 ? WAIT_FOR_STREAM : REPLAY;
                    end
                end
            end

            REPLAY: begin
                if (!read_valid) begin
                    // The last segment of the last read releases the whole stream
                    read_valid <= 1'b1;
                    read_vaddr <= seg_vaddr[replay_seg];
                    read_size  <= seg_size[replay_seg];
                    read_last  <= !wrapped || replay_seg;

                    read_release.release_memory <= remaining_reads == 1 && (!wrapped || replay_seg);
                    read_release.start          <= seg_vaddr[0];
                    read_release.span           <= stream_span;
                    read_release.end_vaddr      <= wrapped ? seg_end[1] : seg_end[0];

                    if (wrapped && !replay_seg) begin
                        replay_seg <= 1'b1;
                    end else begin
                        replay_seg      <= 1'b0;
                        remaining_reads <= remaining_reads - 1;
                        if (remaining_reads == 1) begin
                            state <= WAIT_FOR_STREAM;
                        end
                    end
                end
            end
            default: ;
        endcase

        // Reset everything for a new ring buffer
        if (buffer_config.valid) begin
            ring_end           <= buffer_config.base + buffer_config.size;
            tail_valid         <= 1'b0;
            num_extents        <= '0;
            has_extents        <= 1'b0;
            num_closed_streams <= '0;
            read_valid         <= 1'b0;

            state <= WAIT_FOR_STREAM;
        end
    end
end

// -- Stream reader --------------------------------------------------------------------------------
StreamReader #(
    .STRM(STRM_CARD),
    .AXI_STRM_ID(AXI_STRM_ID),
    .TRANSFER_LENGTH_BYTES(TRANSFER_SIZE),
    .MAX_OUTSTANDING_TRANSFERS(MAX_OUTSTANDING_READS)
) inst_stream_reader (
    .clk(clk),
    .rst_n(reset_synced),

    .sq_rd(sq_rd),
    .cq_rd(cq_rd),

    .mem_config(mem_config),
    .buffer_done(buffer_done),

    .in(in),
    .out(out)
);

endmodule
