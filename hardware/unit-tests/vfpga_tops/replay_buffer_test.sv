import libstf::*;
import lynxTypes::*;

`include "axi_macros.svh"

/**
 * vFPGA top of the replay buffer unit tests and example. The streams from host stream 0 go through a
 * ReplayBuffer in card memory and are sent back on host stream 0 as often as configured.
 *
 * Configurations:
 *   0: ReplayBufferConfig for the ring buffer and the number of reads per stream
 *   1: GenericConfig with stream profiles of the buffer input and output. Write register 0 sets the
 *      number of input streams per run, write register 1 the number of output streams per run.
 *      After a run, the read registers hold the profile of the run: 5 counters for the input
 *      followed by 5 counters for the output (handshakes, starved, stalled, idle, and last
 *      handshakes).
 *
 * The unit tests change the design with the following defines:
 *   REPLAY_BUFFER_TRANSFER_SIZE       Transfer size of the buffer in bytes
 *   REPLAY_BUFFER_TEST_EMPTY_STREAMS  Turns single-beat input streams of only zeros into empty streams
 *   REPLAY_BUFFER_THROTTLE            Applies back pressure to the buffer output
 */

// -- Tie-off unused interfaces and signals --------------------------------------------------------
always_comb notify.tie_off_m();

for (genvar I = 1; I < N_STRM_AXI; I++) begin
    always_comb axis_host_send[I].tie_off_m();
    always_comb axis_host_recv[I].tie_off_s();
end
for (genvar I = 1; I < N_CARD_AXI; I++) begin
    always_comb axis_card_send[I].tie_off_m();
    always_comb axis_card_recv[I].tie_off_s();
end

// -- Fix clock and reset names --------------------------------------------------------------------
logic clk;
logic rst_n;

assign clk   = aclk;
assign rst_n = aresetn;

// -- Configuration of the buffer ------------------------------------------------------------------
// The unit tests use small transfers to exercise many transfers with little data
`ifdef REPLAY_BUFFER_TRANSFER_SIZE
localparam integer TRANSFER_SIZE = `REPLAY_BUFFER_TRANSFER_SIZE;
`else
localparam integer TRANSFER_SIZE = TRANSFER_SIZE_BYTES;
`endif

// -- Configuration --------------------------------------------------------------------------------
localparam integer NUM_PROFILES         = 2;
localparam integer COUNTERS_PER_PROFILE = 5;

write_config_i write_configs[2](clk, rst_n);
read_config_i  read_configs [2](clk, rst_n);

GlobalConfig #(
    .SYSTEM_ID(0),
    .NUM_CONFIGS(2),
    .ADDR_SPACE_SIZES({4, NUM_PROFILES * COUNTERS_PER_PROFILE + 1})
) inst_config (
    .clk(clk),
    .rst_n(rst_n),

    .axi_ctrl(axi_ctrl),

    .write_configs(write_configs),
    .read_configs(read_configs)
);

replay_buffer_config_i buffer_config[1](clk, rst_n);
ReplayBufferConfig #(
    .NUM_BUFFERS(1),
    .TRANSFER_SIZE(TRANSFER_SIZE)
) inst_replay_buffer_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[0]),
    .read_config(read_configs[0]),

    .out(buffer_config)
);

data64_t profile_counters[NUM_PROFILES * COUNTERS_PER_PROFILE];
data64_t streams_per_run[NUM_PROFILES];

GenericConfig #(
    .NUM_READ_REGISTERS(NUM_PROFILES * COUNTERS_PER_PROFILE),
    .NUM_WRITE_REGISTERS(NUM_PROFILES)
) inst_generic_config (
    .clk(clk),
    .rst_n(rst_n),

    .write_config(write_configs[1]),
    .read_config(read_configs[1]),

    .in(profile_counters),
    .out(streams_per_run)
);

// -- Input ----------------------------------------------------------------------------------------
AXI4S axi_host_recv_0(.aclk(clk), .aresetn(rst_n));
AXI4S buffer_in(.aclk(clk), .aresetn(rst_n));
`AXIS_ASSIGN(axis_host_recv[0], axi_host_recv_0) // AXI4SR to AXI4S

`ifdef REPLAY_BUFFER_TEST_EMPTY_STREAMS
// The host cannot send empty streams. To create them in the unit tests, every input beat that only
// contains zero bytes is turned into a null beat (keep == '0). A single beat stream of only zeros
// thus becomes empty. Longer zero streams are not supported as the StreamWriter requires full
// non-last beats.
logic[AXI_DATA_BITS / 8 - 1:0] byte_empty;
for (genvar I = 0; I < AXI_DATA_BITS / 8; I++) begin
    assign byte_empty[I] = !axi_host_recv_0.tkeep[I] || axi_host_recv_0.tdata[I * 8+:8] == '0;
end

assign buffer_in.tdata  = axi_host_recv_0.tdata;
assign buffer_in.tkeep  = &byte_empty ? '0 : axi_host_recv_0.tkeep;
assign buffer_in.tlast  = axi_host_recv_0.tlast;
assign buffer_in.tvalid = axi_host_recv_0.tvalid;
assign axi_host_recv_0.tready = buffer_in.tready;
`else
`AXIS_ASSIGN(axi_host_recv_0, buffer_in)
`endif

// -- Replay buffer --------------------------------------------------------------------------------
AXI4S buffer_out(.aclk(clk), .aresetn(rst_n));
replay_buffer_link_i link (.clk(clk), .rst_n(rst_n));

ReplayBufferWriter #(
    .TRANSFER_SIZE(TRANSFER_SIZE)
) inst_replay_buffer_writer (
    .clk(clk),
    .rst_n(rst_n),

    .sq_wr(sq_wr),
    .cq_wr(cq_wr),

    .buffer_config(buffer_config[0]),

    .link(link),

    .in(buffer_in),
    .out(axis_card_send[0])
);

ReplayBufferReader #(
    .TRANSFER_SIZE(TRANSFER_SIZE)
) inst_replay_buffer_reader (
    .clk(clk),
    .rst_n(rst_n),

    .sq_rd(sq_rd),
    .cq_rd(cq_rd),

    .buffer_config(buffer_config[0]),

    .link(link),

    .in(axis_card_recv[0]),
    .out(buffer_out)
);

// -- Output ---------------------------------------------------------------------------------------
AXI4S throttled_out(.aclk(clk), .aresetn(rst_n));

`ifdef REPLAY_BUFFER_THROTTLE
// Only accepts a beat from the reader in roughly every fourth cycle to backpressure it
logic[7:0] lfsr;
logic      throttle_open;
assign throttle_open = lfsr[1:0] == '0;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        lfsr                 <= 8'h1;
        throttled_out.tvalid <= 1'b0;
    end else begin
        lfsr <= {lfsr[6:0], lfsr[7] ^ lfsr[5] ^ lfsr[4] ^ lfsr[3]};

        if (buffer_out.tvalid && buffer_out.tready) begin
            throttled_out.tdata  <= buffer_out.tdata;
            throttled_out.tkeep  <= buffer_out.tkeep;
            throttled_out.tlast  <= buffer_out.tlast;
            throttled_out.tvalid <= 1'b1;
        end else if (throttled_out.tready) begin
            throttled_out.tvalid <= 1'b0;
        end
    end
end

assign buffer_out.tready = throttle_open && (!throttled_out.tvalid || throttled_out.tready);
`else
`AXIS_ASSIGN(buffer_out, throttled_out)
`endif

`ifdef REPLAY_BUFFER_TEST_EMPTY_STREAMS
// The host does not expect any data for empty streams, so we drop their null beat
AXI4S axi_host_send_0(.aclk(clk), .aresetn(rst_n));
assign axi_host_send_0.tdata  = throttled_out.tdata;
assign axi_host_send_0.tkeep  = throttled_out.tkeep;
assign axi_host_send_0.tlast  = throttled_out.tlast;
assign axi_host_send_0.tvalid = throttled_out.tvalid && throttled_out.tkeep != '0;
assign throttled_out.tready   = axi_host_send_0.tready || (throttled_out.tvalid && throttled_out.tkeep == '0);

`AXIS_ASSIGN(axi_host_send_0, axis_host_send[0]) // AXI4S to AXI4SR
`else
`AXIS_ASSIGN(throttled_out, axis_host_send[0]) // AXI4S to AXI4SR
`endif

// -- Profiling ------------------------------------------------------------------------------------
// Profiles the buffer input (0) and output (1). Each profile stops after the configured number of
// streams, so it holds the counters of the last run until the first beat of the next run.
logic profiled_valid[NUM_PROFILES], profiled_ready[NUM_PROFILES], profiled_last[NUM_PROFILES];

assign profiled_valid[0] = buffer_in.tvalid;
assign profiled_ready[0] = buffer_in.tready;
assign profiled_last[0]  = buffer_in.tlast;

assign profiled_valid[1] = buffer_out.tvalid;
assign profiled_ready[1] = buffer_out.tready;
assign profiled_last[1]  = buffer_out.tlast;

for (genvar I = 0; I < NUM_PROFILES; I++) begin
    data64_t stream_counter;
    logic    is_stop;

    assign is_stop = profiled_valid[I] && profiled_ready[I] && profiled_last[I] &&
                     stream_counter == streams_per_run[I] - 1;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            stream_counter <= '0;
        end else if (profiled_valid[I] && profiled_ready[I] && profiled_last[I]) begin
            stream_counter <= is_stop ? '0 : stream_counter + 1;
        end
    end

    stream_profile_i profile();
    assign profile.stop = is_stop;

    StreamProfiler inst_profiler (
        .clk(clk),
        .rst_n(rst_n),

        .last (profiled_last[I]),
        .valid(profiled_valid[I]),
        .ready(profiled_ready[I]),

        .profile(profile)
    );

    assign profile_counters[COUNTERS_PER_PROFILE * I]     = profile.counters.handshakes_cycles;
    assign profile_counters[COUNTERS_PER_PROFILE * I + 1] = profile.counters.starved_cycles;
    assign profile_counters[COUNTERS_PER_PROFILE * I + 2] = profile.counters.stalled_cycles;
    assign profile_counters[COUNTERS_PER_PROFILE * I + 3] = profile.counters.idle_cycles;
    assign profile_counters[COUNTERS_PER_PROFILE * I + 4] = profile.counters.last_handshakes;
end

// -- Stream boundary checks -----------------------------------------------------------------------
`ifndef SYNTHESIS
// The host only checks the number of bytes it receives, not where the last signals are. Therefore,
// we check here that the buffer reproduces the stream boundaries of its input. Every input stream
// has to appear as often at the output as it is configured to be read.
int unsigned expected_stream_bytes[$];
int unsigned expected_num_reads[$];
int unsigned in_stream_bytes, out_stream_bytes, out_stream_reads;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        in_stream_bytes  <= 0;
        out_stream_bytes <= 0;
        out_stream_reads <= 0;
    end else begin
        if (buffer_config[0].num_reads_valid && buffer_config[0].num_reads_ready) begin
            expected_num_reads.push_back(buffer_config[0].num_reads_data);
        end

        if (buffer_in.tvalid && buffer_in.tready) begin
            if (buffer_in.tlast) begin
                expected_stream_bytes.push_back(in_stream_bytes + $countones(buffer_in.tkeep));
                in_stream_bytes <= 0;
            end else begin
                in_stream_bytes <= in_stream_bytes + $countones(buffer_in.tkeep);
            end
        end

        if (buffer_out.tvalid && buffer_out.tready) begin
            if (buffer_out.tlast) begin
                if (expected_stream_bytes.size() == 0 || expected_num_reads.size() == 0) begin
                    $fatal(1, "ReplayBuffer emitted a last signal without a corresponding input stream!");
                end else if (expected_stream_bytes[0] != out_stream_bytes + $countones(buffer_out.tkeep)) begin
                    $fatal(1, "ReplayBuffer output stream has %0d bytes but the input stream had %0d bytes!",
                        out_stream_bytes + $countones(buffer_out.tkeep), expected_stream_bytes[0]);
                end

                if (out_stream_reads + 1 == expected_num_reads[0]) begin
                    void'(expected_stream_bytes.pop_front());
                    void'(expected_num_reads.pop_front());
                    out_stream_reads <= 0;
                end else begin
                    out_stream_reads <= out_stream_reads + 1;
                end
                out_stream_bytes <= 0;
            end else begin
                out_stream_bytes <= out_stream_bytes + $countones(buffer_out.tkeep);
            end
        end
    end
end
`endif
