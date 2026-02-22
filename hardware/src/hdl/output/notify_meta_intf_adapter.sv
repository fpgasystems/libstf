`timescale 1ns / 1ps

module NotifyMetaIntfAdapter #(
    parameter AXI_STRM_ID = 0,
    parameter PID = 0
) (
    stream_writer_notify_i.s in,
    metaIntf.m out
);

always_comb begin
// The output value has 32 bits and consists of:
out.data.pid         = 6'd0;
// 1. The stream id that finished the transfer
out.data.value[2:0]  = AXI_STRM_ID;
// 2. How much data as written to the vaddr (at most 2^28 bytes are supported)
out.data.value[30:3] = in.size;
// 3. Whether this was the last transfer, i.e. all output data was written
out.data.value[31]   = in.last;
out.valid            = in.valid;
in.ready             = out.ready;
end

endmodule
