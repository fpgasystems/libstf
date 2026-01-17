`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * Can be configured to discard the input stream or forward it to the output. The ID parameter can 
 * be used to select the correct enable signal in case the enable configuration carries the signal 
 * for multiple DataSinks.
 */
module DataSink #(
    parameter integer ID,
    parameter integer ENABLE_SKID_BUFFER = 1
) (
    input logic clk,
    input logic rst_n,

    ready_valid_i.s enable, // #(logic[NUM_STREAMS - 1:0])

    ndata_i.s in, // #(data_t, NUM_ELEMENTS)
    ndata_i.m out // #(data_t, NUM_ELEMENTS)
);

localparam type    data_t       = in.data_t;
localparam integer NUM_ELEMENTS = in.NUM_ELEMENTS;

// If we don't pull this into an internal register we have to assign valid to ready which is bad
logic enable_sink;
logic enable_sink_valid;

logic was_last_data_beat;

ndata_i #(data_t, NUM_ELEMENTS) internal();

always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        enable_sink_valid <= 1'b0;
    end else begin
        if (enable.ready && enable.valid) begin
            enable_sink       <= enable.data[ID];
            enable_sink_valid <= 1'b1;
        end else if (was_last_data_beat) begin
            enable_sink_valid <= 1'b0;
        end
    end
end

assign was_last_data_beat = in.valid && in.last && in.ready;
assign enable.ready       = !enable_sink_valid || was_last_data_beat;

// Note: There is a special case for the last signal of a disabled stream. We zero out all keep 
// signals but forward the last signal as valid such that the modules after know that the stream has
// finished without getting any data.

assign in.ready = enable_sink_valid ? (!enable_sink ? internal.ready : 1'b1) : 1'b0;

assign internal.data  = in.data;
assign internal.keep  = in.keep;
assign internal.last  = in.last;
assign internal.valid = enable_sink_valid && !enable_sink ? in.valid : 1'b0;

generate if (ENABLE_SKID_BUFFER) begin
    NDataSkidBuffer #(data_t, NUM_ELEMENTS) inst_skid_buffer (.clk(clk), .rst_n(rst_n), .in(internal), .out(out));
end else begin
    `DATA_ASSIGN(internal, out)
end endgenerate

endmodule
