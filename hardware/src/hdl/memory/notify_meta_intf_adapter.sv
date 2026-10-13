`timescale 1ns / 1ps

/**
 * Converts the notifications of a StreamWriter to the Coyote notify interface. The 32-bit value
 * consists of:
 *   1. [2:0]  The stream id that finished the transfer
 *   2. [30:3] How much data was written to the vaddr (at most 2^28 bytes are supported)
 *   3. [31]   Whether this was the last transfer, i.e., all output data was written
 */
module NotifyMetaIntfAdapter #(
    parameter AXI_STRM_ID = 0
) (
    stream_writer_notify_i.s in,
    metaIntf.m out
);

always_comb begin
    out.data.pid         = 6'd0;
    out.data.value[2:0]  = AXI_STRM_ID;
    out.data.value[30:3] = in.size;
    out.data.value[31]   = in.last;
    out.valid            = in.valid;
    in.ready             = out.ready;
end

endmodule
