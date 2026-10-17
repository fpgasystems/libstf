`timescale 1ns / 1ps

`include "libstf_macros.svh"

/*
 * The StreamWriter notifies on this interface once all transfers to a buffer completed, i.e., once
 * the buffer is full or a stream ended. vaddr is the start of the buffer, size the number of bytes
 * written to it, and last whether the stream ended.
 */
interface stream_writer_notify_i
    import libstf::*;
(
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

/*
 * Provides the buffers the StreamReader reads, see the StreamReader.
 */
interface mem_read_config_i
    import libstf::*;
(
    input logic clk,
    input logic rst_n
);
    vaddress_t vaddr;
    vaddress_t size;
    logic last; // Whether the buffer ends the stream, i.e., its last beat carries tlast
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
    `STF_ASSERT_STABLE(vaddr, valid, ready);
    `STF_ASSERT_STABLE(size, valid, ready);
    `STF_ASSERT_STABLE(last, valid, ready);
    `STF_ASSERT_NOT_UNDEFINED(valid);
    `STF_ASSERT_NOT_UNDEFINED(ready);
`endif
endinterface
