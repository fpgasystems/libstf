`timescale 1ns / 1ps

import lynxTypes::*;

`include "libstf_macros.svh"

// This module performs a round-robin based arbitration for metaIntf interfaces. The STYPE for the
// data field for each interface can be supplied as a parameter.
//
// From the given N_INTERFACES input interfaces, the module selects one interface to write to the
// output in a round-robin fashion. Should the selected interface not have any data available, any
// other interface with valid data is selected. This ensures the output interface can be written to
// in every cycle and no starvation is encountered. Moreover, fair resource sharing is ensured due
// to the round-robin implementation. Each interface has to wait at most N_INTERFACES - 1 cycles
// between outputs. 
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

logic can_load;
assign can_load = ~intf_out.valid | intf_out.ready;

// We keep a buffer of input for every stream
STYPE [N_INTERFACES - 1 : 0] data_buf;
logic [N_INTERFACES - 1 : 0] buf_valid;

// ----------------------------------------------------------------------------
// Assign ready and buffers for the input
// ----------------------------------------------------------------------------
logic [N_INTERFACES - 1 : 0] in_valid;
STYPE [N_INTERFACES - 1 : 0] in_data;
logic [N_INTERFACES - 1 : 0] in_ready;

generate
    for(genvar stream = 0; stream < N_INTERFACES; stream++) begin
        assign in_valid[stream]      = intf_in[stream].valid;
        assign in_data[stream]       = intf_in[stream].data;
        assign intf_in[stream].ready = in_ready[stream];
    end
endgenerate

STYPE [N_INTERFACES - 1 : 0] n_data_buf;
logic [N_INTERFACES - 1 : 0] n_buf_valid;

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        buf_valid <= '0;
    end else begin
        data_buf  <= n_data_buf;
        buf_valid <= n_buf_valid;
    end
end

always_comb begin
    for (int stream = 0; stream < N_INTERFACES; stream++) begin
        in_ready[stream] = (buf_valid[stream] == 1'b0) |
                           (input_stream_select == stream & can_load);

        n_data_buf[stream]  = data_buf[stream];
        n_buf_valid[stream] = buf_valid[stream];

        if (in_ready[stream]) begin
            if (in_valid[stream]) begin
                n_data_buf[stream]  = in_data[stream];
                n_buf_valid[stream] = 1'b1;
            end else begin
                n_buf_valid[stream] = 1'b0;
            end
        end
    end
end

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
logic                 n_intf_out_valid;
STYPE                 n_intf_out_data;
logic[N_BITS - 1 : 0] n_input_stream_rr_next;

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        intf_out.valid       <= 1'b0;
        input_stream_rr_next <= '0;
    end else begin
        intf_out.data        <= n_intf_out_data;
        intf_out.valid       <= n_intf_out_valid;
        input_stream_rr_next <= n_input_stream_rr_next;
    end
end

always_comb begin
    n_intf_out_data        = intf_out.data;
    n_intf_out_valid       = intf_out.valid;
    n_input_stream_rr_next = input_stream_rr_next;

    if (can_load) begin
        if (buf_valid[input_stream_select]) begin
            n_intf_out_data        = data_buf[input_stream_select];
            n_intf_out_valid       = 1'b1;
            n_input_stream_rr_next =
                (input_stream_rr_next == N_INTERFACES - 1) ? '0 : input_stream_rr_next + 1;
        end else begin
            n_intf_out_valid = 1'b0;
        end
    end
end

endmodule