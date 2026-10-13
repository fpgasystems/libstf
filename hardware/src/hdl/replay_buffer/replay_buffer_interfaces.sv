`timescale 1ns / 1ps

import libstf::*;

`include "libstf_macros.svh"

/*
 * This interface links the ReplayBufferWriter and ReplayBufferReader. The writer fills the card
 * memory ring buffer one transfer at a time and sends one token per written transfer, i.e., its
 * vaddr, its size in bytes, and whether it ends a stream. A token is only sent once the write
 * completed, so the reader never reads partial data. A transfer with size 0 and last set is an
 * empty stream.
 *
 * In the other direction, the reader pulses released_valid whenever the writer can reuse the next
 * released_bytes bytes of the ring buffer. These include the bytes the writer skipped at the end
 * of the ring buffer. holding tells the writer that the reader holds the transfers of a stream it
 * reads multiple times but has not completely received yet. So the reader cannot release any
 * memory before the writer writes the rest of the stream.
 */
interface replay_buffer_link_i (
    input logic clk,
    input logic rst_n
);
    vaddress_t vaddr;
    vaddress_t size;
    logic last;
    logic valid;
    logic ready;

    vaddress_t released_bytes;
    logic released_valid;
    logic holding;

    task tie_off_m();
        valid = 1'b0;
    endtask

    task tie_off_s();
        ready          = 1'b1;
        released_valid = 1'b0;
        holding        = 1'b0;
    endtask

    modport m (
        import tie_off_m,
        output vaddr, size, last, valid,
        input ready, released_bytes, released_valid, holding
    );

    modport s (
        import tie_off_s,
        output ready, released_bytes, released_valid, holding,
        input vaddr, size, last, valid
    );

`ifndef SYNTHESIS
    `STF_ASSERT_SIGNAL_STABLE(vaddr);
    `STF_ASSERT_SIGNAL_STABLE(size);
    `STF_ASSERT_SIGNAL_STABLE(last);

    `STF_ASSERT_NOT_UNDEFINED(valid);
    `STF_ASSERT_NOT_UNDEFINED(ready);
    `STF_ASSERT_NOT_UNDEFINED(released_valid);
`endif
endinterface
