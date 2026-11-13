`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * A stream profiler that starts counting when it sees the first valid data beat. It counts the
 * number of handshakes, starved cycles, stalled cycles, idle pauses after a stream finishes
 * with a last before the next stream arrives, and last handshakes (i.e. completed streams).
 * Asserting stop returns the profiler to the WAIT state, holding its counters until the next
 * valid data beat re-zeroes them.
 *
 * Idle cycles between streams are counted in a separate register while in the IDLE state. The idle
 * count takes this value once the next valid data beat arrives, so trailing idle cycles after the
 * final stream (with no subsequent stream) are not counted.
 *
 * The counters are COUNTER_WIDTH bits wide and zero-extended to 64 bits. 48 bits last for more than
 * 13 days at 250 MHz. OUT_REG_LEVELS adds register stages to the counters output.
 */
module StreamProfiler
    import libstf::*;
#(
    parameter int COUNTER_WIDTH  = 48,
    parameter int OUT_REG_LEVELS = 0
) (
    input logic clk,
    input logic rst_n,

    input logic last,
    input logic valid,
    input logic ready,

    stream_profile_i.m profile
);

`RESET_RESYNC // Reset pipelining

`ASSERT_ELAB(COUNTER_WIDTH > 0 && COUNTER_WIDTH <= 64, "COUNTER_WIDTH has to be in [1, 64]")
`ASSERT_ELAB(OUT_REG_LEVELS >= 0)

typedef logic[COUNTER_WIDTH - 1:0] counter_t;

typedef enum logic[1:0] {
    WAIT,   // Waiting for first handshake
    STREAM, // Counting cycles in a stream
    IDLE    // Counting cycles between streams
} state_t;

logic in_last_reg, in_valid_reg, in_ready_reg, stop_reg;

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        in_last_reg  <= 1'b0;
        in_valid_reg <= 1'b0;
        in_ready_reg <= 1'b0;
        stop_reg     <= 1'b0;
    end else begin
        in_last_reg  <= last;
        in_valid_reg <= valid;
        in_ready_reg <= ready;
        stop_reg     <= profile.stop;
    end
end

state_t  state,          n_state;
counter_t handshakes_reg, n_handshakes_reg;
counter_t starved_reg,    n_starved_reg;
counter_t stalled_reg,    n_stalled_reg;
counter_t idle_reg,       n_idle_reg;
counter_t idle_count_reg, n_idle_count_reg; // All idle cycles, including the trailing ones
counter_t last_reg,       n_last_reg;

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        state <= WAIT;

        handshakes_reg <= '0;
        starved_reg    <= '0;
        stalled_reg    <= '0;
        idle_reg       <= '0;
        idle_count_reg <= '0;
        last_reg       <= '0;
    end else begin
        state <= n_state;

        handshakes_reg <= n_handshakes_reg;
        starved_reg    <= n_starved_reg;
        stalled_reg    <= n_stalled_reg;
        idle_reg       <= n_idle_reg;
        idle_count_reg <= n_idle_count_reg;
        last_reg       <= n_last_reg;
    end
end

always_comb begin
    n_state = state;

    n_handshakes_reg = handshakes_reg;
    n_starved_reg    = starved_reg;
    n_stalled_reg    = stalled_reg;
    n_idle_reg       = idle_reg;
    n_idle_count_reg = idle_count_reg;
    n_last_reg       = last_reg;

    case (state)
        WAIT: begin
            if (in_valid_reg) begin
                n_state = STREAM;

                n_handshakes_reg = '0;
                n_starved_reg    = '0;
                n_stalled_reg    = '0;
                n_idle_reg       = '0;
                n_idle_count_reg = '0;
                n_last_reg       = '0;

                if (in_ready_reg) begin
                    n_handshakes_reg = 1;

                    if (in_last_reg) begin
                        n_state    = IDLE;
                        n_last_reg = 1;
                    end
                end else begin
                    n_stalled_reg = 1;
                end
            end
        end
        STREAM: begin
            if (in_valid_reg) begin
                if (in_ready_reg) begin
                    n_handshakes_reg = handshakes_reg + 1;

                    if (in_last_reg) begin
                        n_state    = IDLE;
                        n_last_reg = last_reg + 1;
                    end
                end else begin
                    n_stalled_reg = stalled_reg + 1;
                end
            end else begin
                n_starved_reg = starved_reg + 1;
            end
        end
        IDLE: begin
            if (in_valid_reg) begin
                n_state = STREAM;

                n_idle_reg = idle_count_reg;

                if (in_ready_reg) begin
                    n_handshakes_reg = handshakes_reg + 1;

                    if (in_last_reg) begin
                        n_state    = IDLE;
                        n_last_reg = last_reg + 1;
                    end
                end else begin
                    n_stalled_reg = stalled_reg + 1;
                end
            end else begin
                n_idle_count_reg = idle_count_reg + 1;
            end
        end
        default: ;
    endcase

    if (stop_reg) begin
        n_state = WAIT;
    end
end

stream_profile_t counters;
assign counters = '{
    handshakes_cycles: data64_t'(handshakes_reg),
    starved_cycles:    data64_t'(starved_reg),
    stalled_cycles:    data64_t'(stalled_reg),
    idle_cycles:       data64_t'(idle_reg),
    last_handshakes:   data64_t'(last_reg)
};

if (OUT_REG_LEVELS > 0) begin : gen_out_regs
    ShiftRegister #(.WIDTH($bits(stream_profile_t)), .LEVELS(OUT_REG_LEVELS)) inst_counters_sr (
        .clk(clk),
        .rst_n(reset_synced),

        .in_data(counters),
        .out_data(profile.counters)
    );
end else begin : gen_no_out_regs
    assign profile.counters = counters;
end

endmodule
