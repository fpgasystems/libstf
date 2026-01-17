`timescale 1ns / 1ps

import lynxTypes::*;
import libstf::*;

`include "axi_macros.svh"
`include "lynx_macros.svh"
`include "libstf_macros.svh"

/**
 * This module takes the data from input_data and transfers it to the memory regions provided by 
 * mem_config via FPGA-initiated transfers. These transfers are triggered via the sq_wr interface 
 * and acknowledged from the host via cq_wr.
 * Should the available memory region, provided via mem_config, become full or the input_data assert 
 * the last signal, an interrupt is triggered for the host. The host than can act accordingly and, 
 * e.g., allocate more memory.
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
    metaIntf.m notify, // This module triggers an interrupt when all transfers are done

    mem_config_i.s mem_config,

    AXI4S.s  input_data,
    AXI4SR.m output_data
);

`RESET_RESYNC // Reset pipelining

// -- Parameters -----------------------------------------------------------------------------------
localparam RDMA_WRITE = 7;
localparam OPCODE = IS_LOCAL ? LOCAL_WRITE : RDMA_WRITE;
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

// Allocations
assert property (@(posedge clk) disable iff (!reset_synced) 
    !buffer.valid || (buffer.data.size > 0))
else $fatal(1, "Buffer size (%0d) must be > 0!", buffer.data.size);
`endif

// -- Configuration --------------------------------------------------------------------------------
ready_valid_i #(buffer_t) buffer();
`CONFIG_SIGNALS_TO_INTF(mem_config.buffer, buffer)

// -- Input logic ----------------------------------------------------------------------------------
AXI4S data_fifo_in(.aclk(clk), .aresetn(reset_synced));
logic[TRANSFER_ADDRESS_LEN_BITS - 1:0] curr_len, curr_len_succ;
logic curr_len_valid;
logic curr_len_ready;

// The input is ready if there is space in both FIFOs
assign input_data.tready = data_fifo_in.tready & curr_len_ready;
assign data_fifo_in.tdata   = input_data.tdata;
assign data_fifo_in.tkeep   = input_data.tkeep;
assign data_fifo_in.tvalid  = input_data.tvalid;
assign data_fifo_in.tlast   = input_data.tlast;

// Whether the transfer will get full this cycle
logic is_split;
assign is_split = curr_len == TRANSFER_LENGTH_BYTES - AXI_DATA_BYTES || input_data.tlast;
// Counts the number of bytes we will need to transfer.
// Whenever we reached a full transfer, the length is split.
assign curr_len_succ = curr_len + $countones(input_data.tkeep);
assign curr_len_valid = is_split && input_data.tvalid && input_data.tready;

always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        curr_len <= 0;
    end else begin
        if (input_data.tvalid && input_data.tready) begin
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
FIFO #(
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
    WAIT_FOR_BUFFER = 0,
    REQUEST = 1,
    TRANSFER = 2,
    WAIT_COMPLETION = 3,
    WAIT_NOTIFY = 4,
    ALL_DONE = 5,
    FLUSH_BUFFERS = 6
} output_state_t;
output_state_t output_state, n_output_state;

// The vaddr we currently write to
vaddress_t vaddr, n_vaddr;
// Note: The following two types are chosen to be vaddress_t on purpose to prevent potential 
// overflow problems below.
// The number of bytes allocated at vaddr
vaddress_t capacity, n_capacity;
// How many bytes we have already written to vaddr
vaddress_t bytes_written_to_allocation, n_bytes_written_to_allocation;
// Possible performance optimization: Become ready earlier such that
// WAITING for the address takes at most 1 cycle.
// However: Pay attention that you don't immediately read two addresses.
assign buffer.ready = output_state == WAIT_FOR_BUFFER || output_state == FLUSH_BUFFERS;

// Tracking of the amount of data we have written in the current transfer
localparam BEAT_BITS = $clog2(AXI_DATA_BYTES);
localparam TRANSFER_BEAT_COUNTER_WIDTH = TRANSFER_ADDRESS_LEN_BITS - BEAT_BITS;
logic[TRANSFER_BEAT_COUNTER_WIDTH - 1 : 0] beats_written_to_transfer, n_beats_written_to_transfer, beats_written_to_transfer_succ;
vaddress_t num_requests, n_num_requests;
vaddress_t num_completed_transfers, n_num_completed_transfers;
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

// -- Send queue requests --------------------------------------------------------------------------
// Sends a request over transfers with at most TRANSFER_LENGTH_BYTES
always_comb begin
    sq_wr.data = '0; // Null everything else

    sq_wr.data.opcode = OPCODE;
    sq_wr.data.strm   = STRM;
    sq_wr.data.mode   = ~IS_LOCAL;
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
    sq_wr.valid = output_state == REQUEST & next_len_valid & next_len > 0;
end

// -- Interrupts -----------------------------------------------------------------------------------
logic all_transfers_completed;
assign all_transfers_completed = num_completed_transfers == num_requests;

logic last_transfer, n_last_transfer;
always_comb begin
    notify.data.pid   = 6'd0;
    // The output value has 32 bits and consists of:
    // 1. The stream id that finished the transfer
    notify.data.value[2:0] = AXI_STRM_ID;
    // 2. How much data as written to the vaddr (at most 2^28 bytes are supported)
    notify.data.value[30:3] = bytes_written_to_allocation;
    // 3. Whether this was the last transfer, i.e. all output data was written
    notify.data.value[31] = last_transfer;
    notify.valid = (output_state == WAIT_COMPLETION && all_transfers_completed) ||
                   (output_state == WAIT_NOTIFY);
end

// -- State machine --------------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        output_state <= WAIT_FOR_BUFFER;
    end else begin
        bytes_written_to_allocation <= n_bytes_written_to_allocation;
        beats_written_to_transfer   <= n_beats_written_to_transfer;
        num_requests                <= n_num_requests;
        num_completed_transfers     <= n_num_completed_transfers;
        last_transfer               <= n_last_transfer;

        vaddr    <= n_vaddr;
        capacity <= n_capacity;

        output_state <= n_output_state;
    end
end

always_comb begin
    next_len_ready = 1'b0;

    n_bytes_written_to_allocation = bytes_written_to_allocation;
    n_beats_written_to_transfer   = beats_written_to_transfer;
    n_num_requests                = num_requests;
    n_num_completed_transfers     = num_completed_transfers;
    n_last_transfer               = last_transfer;

    n_vaddr    = vaddr;
    n_capacity = capacity;

    n_output_state = output_state;

    if (is_completion) begin
        n_num_completed_transfers = num_completed_transfers + 1;
    end

    case(output_state)
        WAIT_FOR_BUFFER: begin
            if (buffer.valid) begin
                // Reset the current state
                n_bytes_written_to_allocation = '0;
                n_num_requests                = '0;
                n_num_completed_transfers     = '0;
                n_last_transfer               = 1'b0;

                // Get the memory address & capacity
                n_vaddr    = buffer.data.vaddr;
                n_capacity = buffer.data.size << $clog2(TRANSFER_LENGTH_BYTES);

                n_output_state    = REQUEST;
            end end
        REQUEST: begin
            // Requests the next transfer over next_len
            // Possible optimization: Transfer first data beat in REQUEST state already
            if (next_len_valid) begin
                // There can be a situation where we need to send 0 bytes.
                // E.g. if the input did not produce any output.
                // In this case we don't need to send any request and can only trigger the interrupt
                if (next_len != 0) begin
                    if (sq_wr.ready) begin
                        // This is a valid request with data
                        n_bytes_written_to_allocation = bytes_written_to_allocation + next_len;
                        n_beats_written_to_transfer   = '0;
                        n_num_requests                = num_requests + 1;

                        n_vaddr = vaddr + next_len;
                        
                        n_output_state = TRANSFER;
                    end
                end else begin
                    next_len_ready = 1'b1;

                    // We cannot take the axis_data_fifo.tlast signal here because the FIFO output 
                    // will never become ready without a request to Coyote. However, the next_len 
                    // can only be zero if this was the last, empty transfer.
                    n_last_transfer = 1'b1;

                    // No data, no request, or transfer. Only interrupt.
                    n_output_state = WAIT_NOTIFY;
                end                    
            end end 
        TRANSFER: begin
            if (axis_data_fifo.tvalid && internal_data.tready) begin
                // If this was the last data beat of the transfer
                if (current_transfer_completed) begin
                    next_len_ready = 1'b1;

                    if (axis_data_fifo.tlast || capacity < bytes_written_to_allocation + TRANSFER_LENGTH_BYTES) begin
                        // If
                        //  1. We have reached the end of the data, OR
                        //  2. The size of the current memory allocation does not fit an additional transfer
                        // We need to
                        //  1. Wait for completion
                        //  2. Trigger a interrupt (which will give us new memory, if more is needed)
                        n_last_transfer = axis_data_fifo.tlast;
                        n_output_state  = WAIT_COMPLETION;
                    end else begin
                        // Perform next transfer!
                        n_output_state = REQUEST;
                    end
                end else begin
                    n_beats_written_to_transfer = beats_written_to_transfer_succ;
                end
            end end
        WAIT_COMPLETION: begin
            if (all_transfers_completed) begin
                if (notify.ready) begin
                    n_output_state = WAIT_FOR_BUFFER;
                end else begin
                    n_output_state = WAIT_NOTIFY;
                end
            end end
        WAIT_NOTIFY: begin
            if (notify.ready) begin
                // If no bytes were written, we can just reuse the current buffer for the next 
                // stream so we null the last_transfer signal and jump to the REQUEST state.
                // Otherwise, we fetch the next buffer in in the WAIT_ADDR state.
                if (bytes_written_to_allocation == 0) begin
                    n_last_transfer = 1'b0;
                    n_output_state  = REQUEST;
                end else begin
                    n_output_state = WAIT_FOR_BUFFER;
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
