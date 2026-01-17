`timescale 1ns / 1ps

/**
 * A performance counter that starts counting and continues counting if the is_handshake signal is
 * high. It stops counting if the is_last signal is high and holds the counter value until the next 
 * count starts. If the is_last signal is high as it starts counting, it will return 1 as the number 
 * of cycles. It also counts the idle cycles when it is currently counting but handshake is not high.
 */
module PerformanceCounter (
    input logic clk,
    input logic rst_n,

    input logic is_handshake,
    input logic is_last,

    output data64_t cycles,
    output data64_t idle_cycles
);

typedef enum logic {
    WAIT,    // Waiting for first handshake
    COUNTING // Counting cycles between first handshake and last
} state_t;

state_t  state,      n_state;
data64_t cycles_reg, n_cycles_reg;
data64_t idle_reg,   n_idle_reg;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        state      <= WAIT;
        cycles_reg <= '0;
        idle_reg   <= '0;
    end else begin
        state      <= n_state;
        cycles_reg <= n_cycles_reg;
        idle_reg   <= n_idle_reg;
    end
end

always_comb begin
    n_state      = state;
    n_cycles_reg = cycles_reg;
    n_idle_reg   = idle_reg;

    case (state)
        WAIT: begin
            if (is_handshake) begin
                n_cycles_reg = 1;
                n_idle_reg   = '0;

                if (!is_last) begin
                    n_state = COUNTING;
                end
            end
        end
        COUNTING: begin
            n_cycles_reg = cycles_reg + 1;

            if (!is_handshake) begin
                n_idle_reg = idle_reg + 1;
            end
            
            if (is_last) begin
                n_state = WAIT;
            end
        end
    endcase
end

assign cycles      = cycles_reg;
assign idle_cycles = idle_reg;

endmodule
