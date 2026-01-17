`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * This module enumerates the elements of the stream with a high keep signal and returns a tagged 
 * stream with the tags containing the indices.
 *
 * The keep signal has to be contiguous starting from the least significant bit.
 */
module DataEnumerator #(
    parameter type data_t,
    parameter NUM_ELEMENTS,
    parameter SERIAL_WIDTH
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s   in, // #(data_t, NUM_ELEMENTS)
    ntagged_i.m out // #(data_t, NUM_ELEMENTS, SERIAL_WIDTH)
);

`RESET_RESYNC // Reset pipelining

`ifndef SYNTHESIS
assert property (@(posedge clk) disable iff (!reset_synced) !in.valid || $onehot0(in.keep + 1'b1))
else $fatal(1, "Incoming keep signal (%h) most be contiguous starting from the least significant bit!", in.keep);
`endif

localparam ELEMENT_BITS = $clog2(NUM_ELEMENTS);

typedef logic[SERIAL_WIDTH - 1:0] serial_t;

serial_t serial_count;

assign in.ready = out.ready;

always_ff @(posedge clk) begin
    if(!reset_synced) begin
        serial_count <= '0;     
    end else begin
        if (in.valid && in.ready) begin
            if (!in.last) begin
                serial_count <= serial_count + $countones(in.keep);
            end else begin
                serial_count <= '0;
            end
        end else begin
            serial_count <= serial_count;
        end
    end
end

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign out.tag[I] = serial_count + I;
end

assign out.data  = in.data;
assign out.keep  = in.keep;
assign out.last  = in.last;
assign out.valid = in.valid;

endmodule