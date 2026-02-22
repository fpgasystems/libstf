`timescale 1ns / 1ps

import libstf::*;
import lynxTypes::*;

`include "axi_macros.svh"
`include "libstf_macros.svh"

/*
 * NOTE: out must be wired to axis_card_send[AXI_STRM_ID].
 */
module StreamBufferWriter #(
    parameter AXI_STRM_ID = 0,
    parameter TRANSFER_SIZE = TRANSFER_SIZE_BYTES,
    // NOTE: this is the number of tranfers that will be allocated at a time
    // when more memory is provided to the underlying StreamWriter.
    parameter TRANFERS_PER_ALLOCATION = MAXIMUM_HOST_ALLOCATION_SIZE_BYTES / TRANSFER_SIZE
) (
    input logic clk,
    input logic rst_n,

    metaIntf.m sq_wr,
    metaIntf.s cq_wr,

    AXI4S.s          in,

    stream_buffer_link_i.m link,
    AXI4SR.m         out
);

`RESET_RESYNC // Reset pipelining

localparam int ALLOCATION_BYTES = TRANFERS_PER_ALLOCATION * TRANSFER_SIZE;

// This stream is used on the host to allocate more data for the StreamWriter.
// On card memory, there's no need for allocations, new mem_config_i regions
// are provided when requested from the code below. Thus, we can just tie off
// this signal.
stream_writer_notify_i notify (.clk(clk), .rst_n(reset_synced));
mem_config_i mem_config (.clk(clk), .rst_n(reset_synced));
vaddress_t next_vaddr, next_buffer_vaddr, last_allocation_end_vaddr;

buffer_t next_buffer;
assign next_buffer.vaddr = next_vaddr;
assign next_buffer.size = TRANFERS_PER_ALLOCATION;
assign mem_config.flush_buffers = 1'b0;
assign mem_config.buffer_data   = next_buffer;
assign mem_config.buffer_valid  = 1'b1;

// This state machine ensures that the notification of a compled write is
// received by the consumer on the other end of the link. It also ensures that
// when the current memory allocation is exhausted, a new memory allocation is
// provided on the mem_config interface and acknowledged.
typedef enum logic {
    ST_NOT_FULL,
    ST_NEEDS_ALLOCATION
} state_t;
state_t state;

vaddress_t n_next_vaddr;
assign n_next_vaddr = next_vaddr + notify.size;

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        next_vaddr <= '0;
        next_buffer_vaddr <= '0;
        last_allocation_end_vaddr <= '0;

        state <= ST_NEEDS_ALLOCATION;
    end else begin
        case (state)
            ST_NOT_FULL: begin
                if (notify.ready && notify.valid) begin
                    next_vaddr <= n_next_vaddr;

                    // When we receive a last, the writer is going to assume
                    // that we want a new allocation for the next stream. This
                    // is the case when sending data to the host, but not when
                    // sending data to the card (we don't want to waste memory
                    // for a new allocation, leaving the current one half-used).
                    if (notify.last || n_next_vaddr >= last_allocation_end_vaddr) begin
                        state <= ST_NEEDS_ALLOCATION;
                    end
                end
            end

            ST_NEEDS_ALLOCATION: begin
                if (mem_config.buffer_ready) begin
                    next_buffer_vaddr <= next_buffer_vaddr + ALLOCATION_BYTES;
                    last_allocation_end_vaddr <= next_vaddr + ALLOCATION_BYTES;

                    state <= ST_NOT_FULL;
                end
            end
        endcase
    end
end

always_comb begin
    if (reset_synced == 1'b0) begin
        notify.ready = 1'b0;
        mem_config.buffer_valid = 1'b0;
    end else begin
        case (state)
            ST_NOT_FULL: begin
                notify.ready = link.ready;
                mem_config.buffer_valid = 1'b0;
            end

            ST_NEEDS_ALLOCATION: begin
                notify.ready = 1'b0;
                mem_config.buffer_valid = 1'b1;
            end
        endcase
    end

    link.vaddr = next_vaddr;
    link.size  = notify.size;
    link.last  = notify.last;
    link.valid = state == ST_NOT_FULL && notify.valid;
end

StreamWriter #(
    .STRM(STRM_CARD),
    .AXI_STRM_ID(AXI_STRM_ID),
    .TRANSFER_LENGTH_BYTES(TRANSFER_SIZE)
) inst_stream_writer (
    .clk(clk),
    .rst_n(reset_synced),

    .sq_wr(sq_wr),
    .cq_wr(cq_wr),

    .notify(notify),
    .mem_config(mem_config),

    .input_data(in),
    .output_data(out)
);

endmodule
