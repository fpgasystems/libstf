`timescale 1ns / 1ps

import lynxTypes::*;
import libstf::*;

`include "axi_macros.svh"
`include "lynx_macros.svh"
`include "libstf_macros.svh"
`include "config_macros.svh"

/**
 * This module takes the data from input_data and transfers it to the buffers provided by 
 * mem_config via FPGA-initiated transfers. These transfers are triggered via the sq_wr interface 
 * and acknowledged from the host via cq_wr.
 * Should the current buffer, provided via mem_config, become full or the input_data assert 
 * the last signal, an interrupt is triggered for the host. The host than can act accordingly and,
 * e.g., allocate more memory. The interrupt is only triggered once all transfers to the buffer
 * completed. However, we already continue with the next buffer in the meantime. The issued interface
 * already signals once all transfers to a buffer were requested.
 *
 * This component allows the following configurations:
 * STRM                  = The kind of Coyote stream. One of: STRM_CARD, STRM_HOST, STRM_TCP, or STRM_RDMA
 * AXI_STRM_ID           = Id of the stream the data will be send on
 * IS_LOCAL              = Whether this is a LOCAL_TRANSFER, i.e. between FPGA and host (1) or if RDMA is used (0)
 * TRANSFER_LENGTH_BYTES = How many bytes each transfer to the host should have
 *
 * The output_data port should be connected to the AXI stream of the stream as configured via the
 * STRM parameter.
 *
 * IMPORTANT:
 * This component assumes normalized streams.
 * E.g. the keep signal should be all 1s, except for data beats that contain a last signal.
 * In other words: Writing data that is not all 1s and not last will result in UNEXPECTED behavior.
 */
module StreamWriter #(
    parameter STRM = STRM_HOST,
    parameter AXI_STRM_ID = 0,
    parameter IS_LOCAL = 1,
    parameter TRANSFER_LENGTH_BYTES = 4096
) (
    input logic clk,
    input logic rst_n,

    metaIntf.m sq_wr,
    metaIntf.s cq_wr,

    stream_writer_notify_i .m notify, // This module triggers an interrupt when more
                                      // memory is required or all transfers are completed
    stream_writer_notify_i.m issued, // Signals as soon as all transfers to a buffer were requested,
                                     // i.e., before they completed. Ignores the ready signal.

    mem_config_i.s mem_config,

    AXI4S.s  input_data,
    AXI4SR.m output_data
);

`RESET_RESYNC // Reset pipelining

// -- Parameters -----------------------------------------------------------------------------------
// For RDMA, Coyote parses APP_WRITE requests into packets of at most the PMTU
localparam OPCODE = IS_LOCAL ? LOCAL_WRITE : APP_WRITE;
// How many bits we need to address one transfer of size TRANSFER_LENGTH_BYTES
localparam TRANSFER_ADDRESS_LEN_BITS = $clog2(TRANSFER_LENGTH_BYTES) + 1;
localparam AXI_DATA_BYTES = (AXI_DATA_BITS / 8);

// -- Assertions -----------------------------------------------------------------------------------

// TRANSFER_LENGTH_BYTES must be a multiple of AXI_DATA_BYTES
`ASSERT_ELAB(TRANSFER_LENGTH_BYTES % AXI_DATA_BYTES == 0)
// This limitations is because we support only 3 bits for the stream identifier in the 
// interrupt/notify value
`ASSERT_ELAB(N_STRM_AXI <= 8)

`ifndef SYNTHESIS
// Input stream
assert property (@(posedge clk) disable iff (!reset_synced) 
    !input_data.tvalid || input_data.tlast || &input_data.tkeep)
else $fatal(1, "Non-last keep signal (%h) must be all 1s!", input_data.tkeep);
assert property (@(posedge clk) disable iff (!reset_synced) 
    !input_data.tvalid || !input_data.tlast || $onehot0(input_data.tkeep + 1'b1))
else $fatal(1, "Last keep signal (%h) must be contiguous starting from the least significant bit!", input_data.tkeep);

// Buffers
assert property (@(posedge clk) disable iff (!reset_synced) 
    !buffer.valid || (buffer.data.size > 0))
else $fatal(1, "Buffer size (%0d) must be > 0!", buffer.data.size);
`endif

// -- Configuration --------------------------------------------------------------------------------
ready_valid_i #(buffer_t) buffer(clk, reset_synced);
`CONFIG_SIGNALS_TO_INTF(mem_config.buffer, buffer)

// -- Input logic ----------------------------------------------------------------------------------
AXI4S data_fifo_in(.aclk(clk), .aresetn(reset_synced));
logic[TRANSFER_ADDRESS_LEN_BITS - 1:0] curr_len, curr_len_succ;
logic curr_len_valid;
logic curr_len_ready;

// Suppress null data beats. Otherwise, the last interrupt is not correctly triggered
AXI4S input_data_no_nulls(.aclk(clk), .aresetn(reset_synced));
AXINullBeatSuppressor inst_null_beat_suppressor (
    .clk(clk),
    .rst_n(reset_synced),

    .in(input_data),
    .out(input_data_no_nulls)
);

// After the null beat suppression, a null beat can only be the last beat of an empty stream. It only
// enters the length FIFO (with length 0) and not the data FIFO because no transfer would ever read
// it from there. It would otherwise end up as the first beat of the next stream.
logic is_empty_stream;
assign is_empty_stream = input_data_no_nulls.tvalid && input_data_no_nulls.tkeep == '0;

// The input is ready if there is space in both FIFOs
assign input_data_no_nulls.tready = (data_fifo_in.tready || is_empty_stream) & curr_len_ready;
assign data_fifo_in.tdata  = input_data_no_nulls.tdata;
assign data_fifo_in.tkeep  = input_data_no_nulls.tkeep;
assign data_fifo_in.tvalid = input_data_no_nulls.tvalid && !is_empty_stream && curr_len_ready;
assign data_fifo_in.tlast  = input_data_no_nulls.tlast;

// Whether the transfer will get full this cycle
logic is_split;
assign is_split = curr_len == TRANSFER_LENGTH_BYTES - AXI_DATA_BYTES || input_data_no_nulls.tlast;
// Counts the number of bytes we will need to transfer.
// Whenever we reached a full transfer, the length is split.
assign curr_len_succ = curr_len + $countones(input_data_no_nulls.tkeep);
assign curr_len_valid = is_split && input_data_no_nulls.tvalid && input_data_no_nulls.tready;

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        curr_len <= 0;
    end else begin
        if (input_data_no_nulls.tvalid && input_data_no_nulls.tready) begin
            if (is_split) begin
                curr_len <= 0;
            end else begin
                curr_len <= curr_len_succ;
            end
        end
    end
end

// -- Input and length buffering -------------------------------------------------------------------
localparam integer TARGET_DATA_DEPTH = 2 * (TRANSFER_LENGTH_BYTES / AXI_DATA_BYTES);
// This ensures we don't go below the minimum size supported by the FIFO
localparam integer DATA_FIFO_DEPTH = TARGET_DATA_DEPTH >= 4 ? TARGET_DATA_DEPTH : 4;

AXI4S axis_data_fifo(.aclk(clk), .aresetn(reset_synced));
FIFOAXI #(
    .DEPTH(DATA_FIFO_DEPTH)
) inst_data_fifo (
    .clk(clk),
    .rst_n(reset_synced),

    .i_data(data_fifo_in),
    .o_data(axis_data_fifo),
    
    .filling_level()
);

logic[TRANSFER_ADDRESS_LEN_BITS - 1:0] next_len;
logic next_len_valid, next_len_ready;
MehdiFIFO #(
    .WIDTH(TRANSFER_ADDRESS_LEN_BITS),
    .DEPTH(16)
) inst_len_fifo (
    .i_clk(clk),
    .i_rst_n(reset_synced),

    .i_data(curr_len_succ),
    .i_valid(curr_len_valid),
    .i_ready(curr_len_ready),

    .o_data(next_len),
    .o_valid(next_len_valid),
    .o_ready(next_len_ready),

    .o_filling_level()
);

// -- Output logic ---------------------------------------------------------------------------------
typedef enum logic[2:0] {
    RESET = 0,
    WAIT_FOR_BUFFER = 1,
    REQUEST = 2,
    TRANSFER = 3,
    FLUSH_BUFFERS = 4
} output_state_t;
output_state_t output_state, n_output_state;

// The vaddr we currently write to
vaddress_t vaddr, n_vaddr;
// The start of the current buffer
vaddress_t buffer_vaddr, n_buffer_vaddr;
// Note: The following two types are chosen to be vaddress_t on purpose to prevent potential 
// overflow problems below.
// The number of bytes of the current buffer
vaddress_t capacity, n_capacity;
// How many bytes we have already written to vaddr
vaddress_t bytes_written_to_buffer, n_bytes_written_to_buffer;
// How many transfers we requested for the current buffer
data32_t num_requests, n_num_requests;
// Possible performance optimization: Become ready earlier such that
// WAITING for the address takes at most 1 cycle.
// However: Pay attention that you don't immediately read two addresses.
assign buffer.ready = output_state == WAIT_FOR_BUFFER || output_state == FLUSH_BUFFERS;

// Tracking of the amount of data we have written in the current transfer
localparam BEAT_BITS = $clog2(AXI_DATA_BYTES);
localparam TRANSFER_BEAT_COUNTER_WIDTH = TRANSFER_ADDRESS_LEN_BITS - BEAT_BITS;
logic[TRANSFER_BEAT_COUNTER_WIDTH - 1 : 0] beats_written_to_transfer, n_beats_written_to_transfer, beats_written_to_transfer_succ;
logic has_partial_beat;
logic current_transfer_completed;

assign has_partial_beat               = |(next_len[BEAT_BITS - 1:0]);
assign current_transfer_completed     = beats_written_to_transfer_succ == (next_len >> BEAT_BITS) + has_partial_beat;
assign beats_written_to_transfer_succ = beats_written_to_transfer + 1;

// Completions we get
assign cq_wr.ready = 1;
logic is_completion;
// Note: We used to also validate the OP code here. However, the op code is not set correctly by coyote for
// the cq_wr. Therefore, we only validate the strm & dest. This should however never cause any problems!
assign is_completion = cq_wr.valid && cq_wr.data.strm == STRM && cq_wr.data.dest == AXI_STRM_ID;

// -- Pending notifications ------------------------------------------------------------------------
// We do not wait for the completions of a buffer before we continue with the next one. Instead,
// we remember the notification of every finished buffer and send it once all its transfers
// completed. This relies on Coyote returning the completions of a stream in the order of the 
// requests, so the oldest pending notification is always the next one that can be sent.
typedef struct packed {
    vaddress_t vaddr;
    vaddress_t size;
    logic      last;
    data32_t   num_requests;
} pending_notify_t;

localparam integer PENDING_NOTIFY_DEPTH = 16;

pending_notify_t pending_in, pending_out;
logic pending_in_valid, pending_in_ready, pending_out_valid, pending_out_ready;

MehdiFIFO #(
    .WIDTH($bits(pending_notify_t)),
    .DEPTH(PENDING_NOTIFY_DEPTH)
) inst_pending_notify_fifo (
    .i_clk(clk),
    .i_rst_n(reset_synced),

    .i_data(pending_in),
    .i_valid(pending_in_valid),
    .i_ready(pending_in_ready),

    .o_data(pending_out),
    .o_valid(pending_out_valid),
    .o_ready(pending_out_ready),

    .o_filling_level()
);

`ifndef SYNTHESIS
assert property (@(posedge clk) disable iff (!reset_synced) !pending_in_valid || pending_in_ready)
else $fatal(1, "Pending notification FIFO overflow!");
`endif

// Completions that we have not yet attributed to a sent notification
data32_t num_completions, n_num_completions;

// -- Send queue requests --------------------------------------------------------------------------
// Sends a request over transfers with at most TRANSFER_LENGTH_BYTES
always_comb begin
    sq_wr.data = '0; // Null everything else

    sq_wr.data.opcode = OPCODE;
    sq_wr.data.strm   = STRM;
    sq_wr.data.mode   = RDMA_MODE_PARSE;
    sq_wr.data.rdma   = ~IS_LOCAL;
    sq_wr.data.remote = ~IS_LOCAL;

    // Note: We always send to coyote thread id 0.
    sq_wr.data.pid  = 0;
    sq_wr.data.dest = AXI_STRM_ID;

    sq_wr.data.vaddr = vaddr;
    sq_wr.data.len   = next_len;
                                                                                              
    // We always mark the transfer as last so we get
    // one acknowledgement per transfer!
    sq_wr.data.last = 1;
    
    // Note: There is a special case where we need to transfer 0 bytes of data.
    // In this case, we don't need to do any request, but only invoke the interrupt.
    // We only start a transfer if we can remember the notification of its buffer afterwards.
    // This is the only place that adds pending notifications, so the space is still there when the 
    // buffer is done.
    sq_wr.valid = output_state == REQUEST & next_len_valid & next_len > 0 & pending_in_ready;
end

// -- Interrupts -----------------------------------------------------------------------------------
always_comb begin
    notify.vaddr = pending_out.vaddr;
    notify.size  = pending_out.size;
    notify.last  = pending_out.last;
    notify.valid = pending_out_valid && num_completions >= pending_out.num_requests;

    pending_out_ready = notify.valid && notify.ready;
end

// -- State machine --------------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        num_completions <= '0;

        output_state <= RESET;
    end else begin
        bytes_written_to_buffer   <= n_bytes_written_to_buffer;
        beats_written_to_transfer <= n_beats_written_to_transfer;
        num_requests              <= n_num_requests;
        num_completions           <= n_num_completions;

        vaddr        <= n_vaddr;
        buffer_vaddr <= n_buffer_vaddr;
        capacity     <= n_capacity;

        output_state <= n_output_state;
    end
end

assign issued.vaddr = pending_in.vaddr;
assign issued.size  = pending_in.size;
assign issued.last  = pending_in.last;
assign issued.valid = pending_in_valid;

always_comb begin
    next_len_ready = 1'b0;

    n_bytes_written_to_buffer   = bytes_written_to_buffer;
    n_beats_written_to_transfer = beats_written_to_transfer;
    n_num_requests              = num_requests;

    n_vaddr        = vaddr;
    n_buffer_vaddr = buffer_vaddr;
    n_capacity     = capacity;

    n_output_state = output_state;

    pending_in.vaddr        = buffer_vaddr;
    pending_in.size         = bytes_written_to_buffer;
    pending_in.last         = 1'b0;
    pending_in.num_requests = num_requests;
    pending_in_valid        = 1'b0;

    n_num_completions = num_completions + is_completion - (pending_out_ready ? pending_out.num_requests : '0);

    case(output_state)
        RESET: begin
            n_output_state = WAIT_FOR_BUFFER;
        end
        WAIT_FOR_BUFFER: begin
            if (buffer.valid) begin
                // Reset the current state
                n_bytes_written_to_buffer = '0;
                n_num_requests            = '0;

                // Get the memory address & capacity
                n_vaddr        = buffer.data.vaddr;
                n_buffer_vaddr = buffer.data.vaddr;
                n_capacity     = buffer.data.size << $clog2(TRANSFER_LENGTH_BYTES);

                n_output_state = REQUEST;
            end end
        REQUEST: begin
            // Requests the next transfer over next_len
            // Possible optimization: Transfer first data beat in REQUEST state already
            if (next_len_valid) begin
                // There can be a situation where we need to send 0 bytes.
                // E.g. if the input did not produce any output.
                // In this case we don't need to send any request and can only trigger the interrupt
                if (next_len != 0) begin
                    if (sq_wr.valid && sq_wr.ready) begin
                        // This is a valid request with data
                        n_bytes_written_to_buffer   = bytes_written_to_buffer + next_len;
                        n_beats_written_to_transfer = '0;
                        n_num_requests              = num_requests + 1;

                        n_vaddr = vaddr + next_len;
                        
                        n_output_state = TRANSFER;
                    end
                end else if (pending_in_ready) begin
                    next_len_ready = 1'b1;

                    // We cannot take the axis_data_fifo.tlast signal here because the FIFO output 
                    // will never become ready without a request to Coyote. However, the next_len 
                    // can only be zero if this was the last, empty transfer.
                    // No data, no request, or transfer. Only interrupt.
                    pending_in.last  = 1'b1;
                    pending_in_valid = 1'b1;

                    // If no bytes were written, we can just reuse the current buffer for the next 
                    // stream. Otherwise, we fetch the next buffer.
                    if (bytes_written_to_buffer != 0) begin
                        n_output_state = WAIT_FOR_BUFFER;
                    end
                end
            end end 
        TRANSFER: begin
            if (axis_data_fifo.tvalid && internal_data.tready) begin
                // If this was the last data beat of the transfer
                if (current_transfer_completed) begin
                    next_len_ready = 1'b1;

                    if (axis_data_fifo.tlast || capacity < bytes_written_to_buffer + TRANSFER_LENGTH_BYTES) begin
                        // If
                        //  1. We have reached the end of the data, OR
                        //  2. The size of the current buffer does not fit an additional transfer
                        // We trigger an interrupt once all transfers completed (which will give us 
                        // new memory, if more is needed) and continue with the next buffer.
                        pending_in.last  = axis_data_fifo.tlast;
                        pending_in_valid = 1'b1;

                        n_output_state = WAIT_FOR_BUFFER;
                    end else begin
                        // Perform next transfer!
                        n_output_state = REQUEST;
                    end
                end else begin
                    n_beats_written_to_transfer = beats_written_to_transfer_succ;
                end
            end end
        FLUSH_BUFFERS: begin
            if (!buffer.valid) begin
                n_output_state = WAIT_FOR_BUFFER;
            end end
        default:;
    endcase

    // We need to be able to separately flush the buffers because multiple buffers might be enqueued
    // by the software side that become stale after the software terminates.
    if (mem_config.flush_buffers) begin
        n_output_state = FLUSH_BUFFERS;
    end
end

// -- Assign output data ---------------------------------------------------------------------------
AXI4S internal_data(.aclk(clk), .aresetn(reset_synced));
AXI4S output_axis  (.aclk(clk), .aresetn(reset_synced));

assign internal_data.tdata   = axis_data_fifo.tdata;

assign internal_data.tkeep   = axis_data_fifo.tkeep;
assign internal_data.tlast   = current_transfer_completed;
assign internal_data.tvalid  = output_state == TRANSFER && axis_data_fifo.tvalid;
assign axis_data_fifo.tready = output_state == TRANSFER && internal_data.tready;

AXISkidBuffer inst_skid_buffer (.clk(clk), .rst_n(reset_synced), .in(internal_data), .out(output_axis));

`AXIS_ASSIGN(output_axis, output_data);
assign output_data.tid = '0;

endmodule
