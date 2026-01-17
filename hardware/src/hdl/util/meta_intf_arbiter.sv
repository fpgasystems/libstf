`timescale 1ns / 1ps

import lynxTypes::*;

`include "libstf_macros.svh"

// This module performs a round-robin based arbitration
// for metaIntf types. The STYPE for the data field for each
// interface can be supplied as a parameter.
//
// From the given N_INTERFACES input interfaces, the module
// selects one interface to write to the output in a round-robin
// fashion. Should the selected interface not have any data available,
// any other interface with valid data is selected. This ensures
// the output interface can be written to in every cycle and no
// starvation is encountered. Moreover, fair resource sharing is
// ensured due to the round-robin implementation. Each interface
// has to wait at most N_INTERFACES - 1 cycles between outputs. 
module MetaIntfArbiter #(
    parameter N_INTERFACES = N_STRM_AXI,
    parameter type STYPE = logic[63:0]
) (
    input logic clk,
    input logic rst_n,

    // The interface to select form
    metaIntf.s intf_in[N_INTERFACES],

    // The interface to assign to
    metaIntf.m intf_out
);

`RESET_RESYNC // Reset pipelining

localparam integer N_BITS = $clog2(N_INTERFACES);

// Which stream would be next, according to round-robin
logic [N_BITS - 1 : 0] input_stream_rr_next;
// The actual stream we select this cycle to pipe to the output.
// This is the round-robin stream if possible.
// Otherwise, its the next valid stream.
logic [N_BITS - 1 : 0] input_stream_select;

// We keep a buffer of input for every stream
STYPE [N_INTERFACES - 1 : 0] data_buf;
logic [N_INTERFACES - 1 : 0] buf_valid;

// ----------------------------------------------------------------------------
// Assign ready and buffers for the input
// ----------------------------------------------------------------------------
generate
    for(genvar stream = 0; stream < N_INTERFACES; stream++) begin
        // Set the input ready, if:
        assign intf_in[stream].ready =
            // 1. The buffer of that stream is empty
            (buf_valid[stream] == 1'b0) |
            // 2. We will flush this streams' buffer in this cycle!
            (input_stream_select == stream & intf_out.ready);

        // Fill the data buffers
        always_ff @(posedge clk) begin
            if (reset_synced == 1'b0) begin
                buf_valid[stream] <= 0;
            end else begin
                // It can only be ready if the buffer is empty or flushed in this cycle.
                if (intf_in[stream].ready) begin
                    if (intf_in[stream].valid) begin
                        data_buf[stream] <= intf_in[stream].data;
                        buf_valid[stream] <= 1;
                    end else begin
                        // It is ready, but not valid.
                        // -> The buffer is already invalid or flushed in this cycle.
                        // We need ensure the buffer is invalid after this cycle!
                        buf_valid[stream] <= 0;
                    end
                end
            end
        end 
    end
endgenerate

// ----------------------------------------------------------------------------
// Make the arbitration decision
// ----------------------------------------------------------------------------
always_comb begin
    // Default to stream 0 if there is not a single valid buffer entry
    input_stream_select = 0;

    if ((|buf_valid) == 1'b1) begin
        // If the stream we want has valid data, choose this stream!
        if (buf_valid[input_stream_rr_next]) begin
            input_stream_select = input_stream_rr_next;
        end else begin
            // Choose any valid stream
            for(int stream = N_INTERFACES - 1; stream >= 0; stream--) begin
                if (buf_valid[stream]) begin
                    input_stream_select = stream;
                    break;
                end
            end
        end
    end
end

// ----------------------------------------------------------------------------
// Assign the output and update round-robin stream selection
// ----------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        intf_out.valid <= 0;
        input_stream_rr_next <= 0;
    end else if (intf_out.ready) begin
        // Check if we have valid output to drive
        if (buf_valid[input_stream_select]) begin
            intf_out.valid <= 1;
            intf_out.data <= data_buf[input_stream_select];
            // Increment RR stream selection
            if (input_stream_rr_next != (N_INTERFACES - 1)) begin
                input_stream_rr_next <= input_stream_rr_next + 1;
            end else begin
                input_stream_rr_next <= 0;
            end
        end else begin
            // No valid output this cycle
            intf_out.valid <= 0;
        end
    end
end

endmodule