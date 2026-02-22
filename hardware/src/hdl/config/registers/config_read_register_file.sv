`timescale 1ns / 1ps

/**
 * Returns the value corresponding to the read_addr to resp_data. If the read_addr is out of bounds,
 * it returns an error.
 */
module ConfigReadRegisterFile #(
    parameter integer NUM_REGS
) (
    input logic clk,
    input logic rst_n,

    read_config_i.s in,
    
    logic[AXIL_DATA_BITS - 1:0] values[NUM_REGS]
);

// -- Assertions -----------------------------------------------------------------------------------
`ASSERT_ELAB(NUM_REGS > 0)

// -- Signals --------------------------------------------------------------------------------------
typedef enum logic {WAIT, RESPOND} state_t;
state_t state;

logic[NUM_REGS - 1:0] addr_matches;

logic[AXIL_DATA_BITS - 1:0] n_resp_data;

// -- Logic ----------------------------------------------------------------------------------------
assign in.read_ready = state == WAIT;

for (genvar I = 0; I < NUM_REGS; I++) begin
    assign addr_matches[I] = in.read_addr == I;
end

always_ff @(posedge clk) begin
    if (!rst_n) begin
        state         <= WAIT;
        in.resp_valid <= 1'b0;
    end else begin
        if (state == WAIT) begin
            if (in.read_valid) begin
                state    <= RESPOND;

                in.resp_data = n_resp_data;
                in.resp_error = !(|addr_matches);
                in.resp_valid = 1'b1;
            end
        end else begin
            if (in.resp_ready) begin
                state         <= WAIT;
                in.resp_valid <= 1'b0;
            end
        end
    end
end

always_comb begin
    n_resp_data = '0;

    for (int i = 0; i < NUM_REGS; i++) begin
        n_resp_data |= addr_matches[i] ? values[i] : '0;
    end
end

endmodule
