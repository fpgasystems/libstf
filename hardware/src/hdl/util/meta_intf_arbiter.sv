`timescale 1ns / 1ps

`include "libstf_macros.svh"

// This module performs a round-robin based arbitration for metaIntf interfaces. The data_t for the
// data field for each interface can be supplied as a parameter.
//
// From the given N_INTERFACES input interfaces, the module selects one interface to write to the
// output in a round-robin fashion. Should the selected interface not have any data available, any
// other interface with valid data is selected. This ensures the output interface can be written to
// in every cycle and no starvation is encountered. Moreover, fair resource sharing is ensured due
// to the round-robin implementation. Each interface has to wait at most N_INTERFACES - 1 cycles
// between outputs.
module MetaIntfArbiter
    import lynxTypes::*;
#(
    parameter int N_INTERFACES = N_STRM_AXI,
    parameter type data_t = logic[63:0],
    localparam int SELECT_BITS = N_INTERFACES > 1 ? $clog2(N_INTERFACES) : 1
) (
    input logic clk,
    input logic rst_n,

    // The interface to select from
    metaIntf.s in[N_INTERFACES], // #(data_t)

    // The interface to assign to
    metaIntf.m out, // #(data_t)
    // The index of the input interface that out holds
    output logic [SELECT_BITS - 1:0] out_select
);

`RESET_RESYNC // Reset pipelining

localparam int N_BITS = $clog2(N_INTERFACES);

// Which stream would be next, according to round-robin
logic [N_BITS - 1 : 0] input_stream_rr_next;
// The actual stream we select this cycle to pipe to the output.
// This is the round-robin stream if possible.
// Otherwise, it's the next valid stream.
logic [N_BITS - 1 : 0] input_stream_select;

logic can_load;
assign can_load = ~out.valid | out.ready;

// We keep a buffer of input for every stream
data_t [N_INTERFACES - 1 : 0] data_buf;
logic [N_INTERFACES - 1 : 0] buf_valid;

// -- Assign ready and buffers for the input -------------------------------------------------------
logic [N_INTERFACES - 1 : 0] in_valid;
data_t [N_INTERFACES - 1 : 0] in_data;
logic [N_INTERFACES - 1 : 0] in_ready;

for (genvar STREAM = 0; STREAM < N_INTERFACES; STREAM++) begin : gen_interfaces
    assign in_valid[STREAM]      = in[STREAM].valid;
    assign in_data[STREAM]       = in[STREAM].data;
    assign in[STREAM].ready      = in_ready[STREAM];
end

data_t [N_INTERFACES - 1 : 0] n_data_buf;
logic [N_INTERFACES - 1 : 0] n_buf_valid;

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        data_buf  <= 'X;
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

// -- Make the arbitration decision ----------------------------------------------------------------
always_comb begin
    // Default to stream 0 if there is not a single valid buffer entry
    input_stream_select = 0;

    if ((|buf_valid) == 1'b1) begin
        // If the stream we want has valid data, choose this stream!
        if (buf_valid[input_stream_rr_next]) begin
            input_stream_select = input_stream_rr_next;
        end else begin
            // Choose any valid stream
            for (int stream = N_INTERFACES - 1; stream >= 0; stream--) begin
                if (buf_valid[stream]) begin
                    input_stream_select = stream;
                    break;
                end
            end
        end
    end
end

// -- Assign the output and update round-robin stream selection ------------------------------------
logic                    n_out_valid;
data_t                   n_out_data;
logic[SELECT_BITS - 1:0] n_out_select;
logic[N_BITS - 1 : 0]    n_input_stream_rr_next;

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        out.data             <= 'X;
        out.valid            <= 1'b0;
        out_select           <= 'X;
        input_stream_rr_next <= '0;
    end else begin
        out.data             <= n_out_data;
        out.valid            <= n_out_valid;
        out_select           <= n_out_select;
        input_stream_rr_next <= n_input_stream_rr_next;
    end
end

always_comb begin
    n_out_data             = out.data;
    n_out_valid            = out.valid;
    n_out_select           = out_select;
    n_input_stream_rr_next = input_stream_rr_next;

    if (can_load) begin
        if (buf_valid[input_stream_select]) begin
            n_out_data             = data_buf[input_stream_select];
            n_out_valid            = 1'b1;
            n_out_select           = SELECT_BITS'(input_stream_select);
            n_input_stream_rr_next =
                (input_stream_rr_next == N_INTERFACES - 1) ? '0 : input_stream_rr_next + 1;
        end else begin
            n_out_valid = 1'b0;
        end
    end
end

endmodule
