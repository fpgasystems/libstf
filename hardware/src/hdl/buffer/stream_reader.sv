`timescale 1ns / 1ps

import lynxTypes::*;
import libstf::*;

`include "axi_macros.svh"
`include "lynx_macros.svh"
`include "libstf_macros.svh"

/*
 * NOTE: the input_data should be wired to the AXI stream where incmonig data
 * will be streamed after a request has been sent via sq_rd.
 * For example, in the case of card memory, it should be
 * axis_card_recv[AXI_STRM_ID].
 * NOTE: the TRANSFER_LENGTH_BYTES must be the same as configured in the
 * writer.
 */
module StreamReader #(
    parameter STRM = STRM_HOST,
    parameter AXI_STRM_ID = 0,
    parameter IS_LOCAL = 1,
    parameter TRANSFER_LENGTH_BYTES = 4096
) (
    input logic clk,
    input logic rst_n,

    metaIntf.m sq_rd,
    metaIntf.s cq_rd,

    mem_read_config_i.s  mem_config,

    AXI4SR.s input_data,
    AXI4S.m  output_data
);

`RESET_RESYNC // Reset pipelining

metaIntf #(.STYPE(req_t)) debug_sq_rd (.aclk(clk), .aresetn(reset_synced));
assign debug_sq_rd.data = sq_rd.data;
assign debug_sq_rd.valid = sq_rd.valid;
assign debug_sq_rd.ready = sq_rd.ready;
metaIntf #(.STYPE(req_t)) debug_cq_rd (.aclk(clk), .aresetn(reset_synced));
assign debug_cq_rd.data = cq_rd.data;
assign debug_cq_rd.valid = cq_rd.valid;
assign debug_cq_rd.ready = cq_rd.ready;

// -- Parameters -----------------------------------------------------------------------------------
localparam RDMA_READ = 7;
localparam OPCODE = IS_LOCAL ? LOCAL_READ : RDMA_READ;
// How many bits we need to address one transfer of size TRANSFER_LENGTH_BYTES
localparam TRANSFER_ADDRESS_LEN_BITS = $clog2(TRANSFER_LENGTH_BYTES) + 1;
localparam AXI_DATA_BYTES = (AXI_DATA_BITS / 8);

// -- Assertions -----------------------------------------------------------------------------------

// TRANSFER_LENGTH_BYTES must be a multiple of AXI_DATA_BYTES
`ASSERT_ELAB(TRANSFER_LENGTH_BYTES % AXI_DATA_BYTES == 0)
// This limitations is because we support only 3 bits for the stream identifier in the 
// interrupt/notify value
`ASSERT_ELAB(N_STRM_AXI <= 8)

// Input stream
assert property (@(posedge clk) disable iff (!reset_synced) 
    !input_data.tvalid || input_data.tlast || &input_data.tkeep)
else $fatal(1, "Non-last keep signal (%h) must be all 1s!", input_data.tkeep);
assert property (@(posedge clk) disable iff (!reset_synced) 
    !input_data.tvalid || !input_data.tlast || $onehot0(input_data.tkeep + 1'b1))
else $fatal(1, "Last keep signal (%h) must be contiguous starting from the least significant bit!", input_data.tkeep);

// Allocations
assert property (@(posedge clk) disable iff (!reset_synced) 
    !mem_config.valid || (mem_config.size > 0))
else $fatal(1, "Buffer size (%0d) must be > 0!", mem_config.size);

// -- Input logic ---------------------------------------------------------------------------------
typedef enum logic[2:0] {
    WAIT_FOR_BUFFER = 0,
    REQUEST = 1,
    TRANSFER = 2
} input_state_t;
input_state_t input_state, n_input_state;

// The vaddr we currently read from
vaddress_t vaddr, n_vaddr;
// How many bytes we need to read from vaddr.
data32_t len, n_len;
// How many bytes we need to read from vaddr in the next transfer request.
data32_t next_transfer_len, n_next_transfer_len;
// How many bytes we need to read in the ongoing transfer.
data32_t curr_transfer_len, n_curr_transfer_len;
assign mem_config.ready = input_state == WAIT_FOR_BUFFER;

// Tracking of the amount of data we have written in the current transfer
localparam BEAT_BITS = $clog2(AXI_DATA_BYTES);
localparam TRANSFER_BEAT_COUNTER_WIDTH = TRANSFER_ADDRESS_LEN_BITS - BEAT_BITS;
logic[TRANSFER_BEAT_COUNTER_WIDTH - 1 : 0] beats_read_from_transfer, n_beats_read_from_transfer, beats_read_from_transfer_succ;
logic has_partial_beat, current_transfer_completed;
assign has_partial_beat              = |(curr_transfer_len[BEAT_BITS - 1:0]);
assign current_transfer_completed    = beats_read_from_transfer_succ == (curr_transfer_len >> BEAT_BITS) + has_partial_beat;
assign beats_read_from_transfer_succ = beats_read_from_transfer + 1;

// Completions we get
assign cq_rd.ready = 1;
logic is_completion;
// Note: We used to also validate the OP code here. However, the op code is not set correctly by coyote for
// the cq_rd. Therefore, we only validate the strm & dest. This should however never cause any problems!
assign is_completion = cq_rd.valid && cq_rd.data.strm == STRM && cq_rd.data.dest == AXI_STRM_ID;

// -- Send queue requests --------------------------------------------------------------------------
// Sends a request over transfers with at most TRANSFER_LENGTH_BYTES
always_comb begin
    sq_rd.data = '0; // Null everything else

    sq_rd.data.opcode = OPCODE;
    sq_rd.data.strm   = STRM;
    sq_rd.data.mode   = ~IS_LOCAL;
    sq_rd.data.rdma   = ~IS_LOCAL;
    sq_rd.data.remote = ~IS_LOCAL;

    // Note: We always send to coyote thread id 0.
    sq_rd.data.pid  = 0;
    sq_rd.data.dest = AXI_STRM_ID;

    sq_rd.data.vaddr = vaddr;
    sq_rd.data.len   = next_transfer_len;
                                                                                              
    // We always mark the transfer as last so we get
    // one acknowledgement per transfer!
    sq_rd.data.last = 1;
    
    sq_rd.valid = input_state == REQUEST;
end

// -- State machine --------------------------------------------------------------------------------
always_ff @(posedge clk) begin
    if (reset_synced == 1'b0) begin
        input_state <= WAIT_FOR_BUFFER;
    end else begin
        beats_read_from_transfer  <= n_beats_read_from_transfer;
        vaddr                     <= n_vaddr;
        len                       <= n_len;
        next_transfer_len              <= n_next_transfer_len;
        curr_transfer_len              <= n_curr_transfer_len;

        input_state <= n_input_state;
    end
end

always_comb begin
    n_beats_read_from_transfer  = beats_read_from_transfer;
    n_vaddr                     = vaddr;
    n_len                       = len;
    n_next_transfer_len         = next_transfer_len;
    n_curr_transfer_len         = curr_transfer_len;

    n_input_state = input_state;

    case(input_state)
        WAIT_FOR_BUFFER: begin
            if (mem_config.valid) begin
                // Reset the current state
                n_vaddr = mem_config.vaddr;
                n_len = mem_config.size;
                if (n_len > TRANSFER_LENGTH_BYTES) begin
                    n_next_transfer_len = TRANSFER_LENGTH_BYTES;
                end else begin
                    n_next_transfer_len = n_len;
                end

                n_input_state = REQUEST;
            end end
        REQUEST: begin
            if (sq_rd.ready) begin
                n_beats_read_from_transfer = '0;
                n_vaddr = vaddr + next_transfer_len;
                // Possible optimiaztion: subtract constant TRANSFER_LENGTH_BYTES
                // which is valid except for the last transfer. Deal with overflows.
                n_len = len - next_transfer_len;
                n_curr_transfer_len = next_transfer_len;
                if (n_len > TRANSFER_LENGTH_BYTES) begin
                    n_next_transfer_len = TRANSFER_LENGTH_BYTES;
                end else begin
                    n_next_transfer_len = n_len;
                end
                
                n_input_state = TRANSFER;
            end end 
        TRANSFER: begin
            if (input_data.tvalid && input_data.tready) begin
                // If this was the last data beat of the transfer
                if (current_transfer_completed) begin
                    if (len == 0) begin
                        n_input_state  = WAIT_FOR_BUFFER;
                    end else begin
                        // Perform next transfer!
                        n_input_state = REQUEST;
                    end
                end else begin
                    n_beats_read_from_transfer = beats_read_from_transfer_succ;
                end
            end end
        default:;
    endcase
end

// -- Assign output data ---------------------------------------------------------------------------
AXI4S internal_data(.aclk(clk), .aresetn(reset_synced));
AXI4S output_axis  (.aclk(clk), .aresetn(reset_synced));

assign internal_data.tdata   = input_data.tdata;

assign internal_data.tkeep   = input_data.tkeep;
assign internal_data.tlast   = current_transfer_completed;
assign internal_data.tvalid  = input_state == TRANSFER && input_data.tvalid;
assign input_data.tready     = input_state == TRANSFER && internal_data.tready;

AXISkidBuffer inst_skid_buffer (.clk(clk), .rst_n(reset_synced), .in(internal_data), .out(output_axis));

`AXIS_ASSIGN(output_axis, output_data);

endmodule
