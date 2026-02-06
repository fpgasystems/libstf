`timescale 1ns / 1ps

import libstf::*;

`include "libstf_macros.svh"

/*
 * This interface links the StreamBufferWriter and StreamBufferWriter, acting as
 * a stream where tokens are shared. Each tokens represents the amount of
 * bytes written by the latest card write. This is used to pause reads until
 * data for a region has been fully written, so that partial data is never
 * read.
 */
interface stream_buffer_link_i (
    input logic clk,
    input logic rst_n
);
    vaddress_t vaddr;
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
        output vaddr, size, last, valid,
        input ready
    );

    modport s (
        import tie_off_s,
        output ready,
        input vaddr, size, last, valid
    );

`ifndef SYNTHESIS
    `STF_ASSERT_SIGNAL_STABLE(vaddr);
    `STF_ASSERT_SIGNAL_STABLE(size);
    `STF_ASSERT_SIGNAL_STABLE(last);

    `STF_ASSERT_NOT_UNDEFINED(valid);
    `STF_ASSERT_NOT_UNDEFINED(ready);
`endif
endinterface

interface mem_read_config_i (
    input logic clk,
    input logic rst_n
);
    vaddress_t vaddr;
    data32_t size;
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
        output vaddr, size, valid,
        input ready
    );

    modport s (
        import tie_off_s,
        output ready,
        input vaddr, size, valid
    );

`ifndef SYNTHESIS
    `STF_ASSERT_STABLE(vaddr, valid, ready);
    `STF_ASSERT_STABLE(size, valid, ready);
    `STF_ASSERT_NOT_UNDEFINED(valid);
    `STF_ASSERT_NOT_UNDEFINED(ready);
`endif
endinterface
