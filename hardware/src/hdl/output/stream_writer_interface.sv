`timescale 1ns / 1ps

import libstf::*;

`include "libstf_macros.svh"

/*
 * This interface is used to notify of a completed transfer or request more
 * memory allocations on the target device. The StreamWriter will place a
 * request on this interface and wait for acknowledgement.
 *
 * In this context, acknowledgement implies that the request has been received,
 * not that a memory segment has been allocated. That is communicated to the
 * StreamWriter via the mem_config_i interface.
 */
interface stream_writer_notify_i (
    input logic clk,
    input logic rst_n
);
    vaddress_t size;
    logic last;
    logic valid;
    logic ready;

    task tie_off_m();
        valid  = 1'b0;
    endtask

    task tie_off_s();
        ready = 1'b1;
    endtask

    modport m (
        import tie_off_m,
        output size, last, valid,
        input ready
    );

    modport s (
        import tie_off_s,
        output ready,
        input size, last, valid
    );

`ifndef SYNTHESIS
    `STF_ASSERT_SIGNAL_STABLE(size);
    `STF_ASSERT_SIGNAL_STABLE(last);

    `STF_ASSERT_NOT_UNDEFINED(valid);
    `STF_ASSERT_NOT_UNDEFINED(ready);
`endif
endinterface
