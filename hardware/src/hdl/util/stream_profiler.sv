`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * A stream profiler that starts counting when it sees the first valid data beat. It counts the
 * number of handshakes, starved cycles, stalled cycles, idle pauses after a stream finishes
 * with a last before the next stream arrives, and last handshakes (i.e. completed streams).
 * Asserting stop returns the profiler to the WAIT state, holding its counters until the next
 * valid data beat re-zeroes them.
 *
 * Idle cycles between streams are accumulated in a separate register while in the IDLE state and
 * are only added to the idle count once the next valid data beat arrives, so trailing idle cycles
 * after the final stream (with no subsequent stream) are not counted.
 */
module StreamProfiler
    import libstf::*;
#(
    parameter int OUT_REG_LEVELS = 1
) (
    input logic clk,
    input logic rst_n,

    input logic last,
    input logic valid,
    input logic ready,

    stream_profile_i.m profile
);

`RESET_RESYNC // Reset pipelining

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
data64_t handshakes_reg, n_handshakes_reg;
data64_t starved_reg,    n_starved_reg;
data64_t stalled_reg,    n_stalled_reg;
data64_t idle_reg,       n_idle_reg;
data64_t idle_acc_reg,   n_idle_acc_reg;
data64_t last_reg,       n_last_reg;

always_ff @(posedge clk) begin
    if (!reset_synced) begin
        state <= WAIT;

        handshakes_reg <= 'X;
        starved_reg    <= 'X;
        stalled_reg    <= 'X;
        idle_reg       <= 'X;
        idle_acc_reg   <= 'X;
        last_reg       <= 'X;
    end else begin
        state <= n_state;

        handshakes_reg <= n_handshakes_reg;
        starved_reg    <= n_starved_reg;
        stalled_reg    <= n_stalled_reg;
        idle_reg       <= n_idle_reg;
        idle_acc_reg   <= n_idle_acc_reg;
        last_reg       <= n_last_reg;
    end
end

always_comb begin
    n_state = state;

    n_handshakes_reg = handshakes_reg;
    n_starved_reg    = starved_reg;
    n_stalled_reg    = stalled_reg;
    n_idle_reg       = idle_reg;
    n_idle_acc_reg   = idle_acc_reg;
    n_last_reg       = last_reg;

    case (state)
        WAIT: begin
            if (in_valid_reg) begin
                n_state = STREAM;

                n_handshakes_reg = '0;
                n_starved_reg    = '0;
                n_stalled_reg    = '0;
                n_idle_reg       = '0;
                n_idle_acc_reg   = '0;
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

                n_idle_reg     = idle_reg + idle_acc_reg;
                n_idle_acc_reg = '0;

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
                n_idle_acc_reg = idle_acc_reg + 1;
            end
        end
        default: ;
    endcase

    if (stop_reg) begin
        n_state = WAIT;
    end
end

stream_profile_t counters_reg;
assign counters_reg = '{
    handshakes_cycles: handshakes_reg,
    starved_cycles:    starved_reg,
    stalled_cycles:    stalled_reg,
    idle_cycles:       idle_reg,
    last_handshakes:   last_reg
};

ShiftRegister #(.WIDTH($bits(stream_profile_t)), .LEVELS(OUT_REG_LEVELS)) inst_counters_sr (
    .clk(clk),
    .rst_n(reset_synced),

    .i_data(counters_reg),
    .o_data(profile.counters)
);

endmodule
