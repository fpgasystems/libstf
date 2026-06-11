`timescale 1ns / 1ps

/**
 * A stream profiler that starts counting when it sees the first valid data beat and only stops upon
 * the stop signal. It counts the number of handshakes, starved cycles, stalled cycles, and idle
 * pauses after a stream finishes with a last before the next stream arrives. After it received the
 * stop signal, it holds its signals until the next valid data beat. The stop signal has to be
 * asserted on the same clock cycle as the last handshake.
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

    input logic stop,

    output stream_profile_t profile
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

                if (ready) begin
                    n_handshakes_reg = 1;

                    if (last) begin
                        if (stop) begin
                            n_state = WAIT;
                        end else begin
                            n_state = STREAM;
                        end
                    end
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
                        if (stop) begin
                            n_state = WAIT;
                        end else begin
                            n_state = IDLE;
                        end
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
                        if (stop) begin
                            n_state = WAIT;
                        end else begin
                            n_state = IDLE;
                        end
                    end
                end else begin
                    n_stalled_reg = stalled_reg + 1;
                end
            end else begin
                n_idle_acc_reg = idle_acc_reg + 1;
            end
        end
    endcase
end

ShiftRegister #(.WIDTH($bits(data64_t)), .LEVELS(OUT_REG_LEVELS)) inst_handshakes_sr (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data(handshakes_reg),
    .o_data(profile.handshakes_cycles)
);

ShiftRegister #(.WIDTH($bits(data64_t)), .LEVELS(OUT_REG_LEVELS)) inst_starved_sr (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data(starved_reg),
    .o_data(profile.starved_cycles)
);

ShiftRegister #(.WIDTH($bits(data64_t)), .LEVELS(OUT_REG_LEVELS)) inst_stalled_sr (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data(stalled_reg),
    .o_data(profile.stalled_cycles)
);

ShiftRegister #(.WIDTH($bits(data64_t)), .LEVELS(OUT_REG_LEVELS)) inst_idle_sr (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data(idle_reg),
    .o_data(profile.idle_cycles)
);

endmodule
