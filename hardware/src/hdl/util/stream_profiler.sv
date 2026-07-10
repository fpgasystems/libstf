`timescale 1ns / 1ps

import libstf::*;

/**
 * A stream profiler that starts counting when it sees the first valid data beat. It counts the
 * number of handshakes, starved cycles, stalled cycles, and idle pauses after a stream finishes
 * with a last before the next stream arrives. Asserting stop returns the profiler to the WAIT 
 * state, holding its counters until the next valid data beat re-zeroes them.
 *
 * Idle cycles between streams are accumulated in a separate register while in the IDLE state and are
 * only added to the idle count once the next valid data beat arrives, so trailing idle cycles after
 * the final stream (with no subsequent stream) are not counted.
 */
module StreamProfiler #(
    parameter int OUT_REG_LEVELS = 1
) (
    input logic clk,
    input logic rst_n,

    input logic last,
    input logic valid,
    input logic ready,

    stream_profile_i.m profile
);

typedef enum logic[1:0] {
    WAIT,   // Waiting for first handshake
    STREAM, // Counting cycles in a stream
    IDLE    // Counting cycles between streams
} state_t;

state_t  state,          n_state;
data64_t handshakes_reg, n_handshakes_reg;
data64_t starved_reg,    n_starved_reg;
data64_t stalled_reg,    n_stalled_reg;
data64_t idle_reg,       n_idle_reg;
data64_t idle_acc_reg,   n_idle_acc_reg;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        state <= WAIT;

        handshakes_reg <= 'X;
        starved_reg    <= 'X;
        stalled_reg    <= 'X;
        idle_reg       <= 'X;
        idle_acc_reg   <= 'X;
    end else begin
        state <= n_state;

        handshakes_reg <= n_handshakes_reg;
        starved_reg    <= n_starved_reg;
        stalled_reg    <= n_stalled_reg;
        idle_reg       <= n_idle_reg;
        idle_acc_reg   <= n_idle_acc_reg;
    end
end

always_comb begin
    n_state = state;

    n_handshakes_reg = handshakes_reg;
    n_starved_reg    = starved_reg;
    n_stalled_reg    = stalled_reg;
    n_idle_reg       = idle_reg;
    n_idle_acc_reg   = idle_acc_reg;

    case (state)
        WAIT: begin
            if (valid) begin
                n_state = STREAM;

                n_handshakes_reg = '0;
                n_starved_reg    = '0;
                n_stalled_reg    = '0;
                n_idle_reg       = '0;
                n_idle_acc_reg   = '0;

                if (ready) begin
                    n_handshakes_reg = 1;
                end else begin
                    n_stalled_reg = 1;
                end
            end
        end
        STREAM: begin
            if (valid) begin
                if (ready) begin
                    n_handshakes_reg = handshakes_reg + 1;

                    if (last) begin
                        n_state = IDLE;
                    end
                end else begin
                    n_stalled_reg = stalled_reg + 1;
                end
            end else begin
                n_starved_reg = starved_reg + 1;
            end
        end
        IDLE: begin
            if (valid) begin
                n_state = STREAM;

                n_idle_reg     = idle_reg + idle_acc_reg;
                n_idle_acc_reg = '0;

                if (ready) begin
                    n_handshakes_reg = handshakes_reg + 1;

                    if (last) begin
                        n_state = IDLE;
                    end
                end else begin
                    n_stalled_reg = stalled_reg + 1;
                end
            end else begin
                n_idle_acc_reg = idle_acc_reg + 1;
            end
        end
    endcase

    if (profile.stop) begin
        n_state = WAIT;
    end
end

stream_profile_t counters_reg;
assign counters_reg = '{
    handshakes_cycles: handshakes_reg,
    starved_cycles:    starved_reg,
    stalled_cycles:    stalled_reg,
    idle_cycles:       idle_reg
};

ShiftRegister #(.WIDTH($bits(stream_profile_t)), .LEVELS(OUT_REG_LEVELS)) inst_counters_sr (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data(counters_reg),
    .o_data(profile.counters)
);

endmodule
