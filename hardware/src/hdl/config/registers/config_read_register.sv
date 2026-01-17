`timescale 1ns / 1ps

/**
 * This module implements a read register for a plain signal.
 */
module ConfigReadRegister #(
    parameter integer ADDR,
    parameter type value_t
) (
    input logic clk,
    input logic rst_n,

    read_config_i.s conf,

    input value_t value
);

// Check that input signal fits into AXIL_DATA_BITS
`ASSERT_ELAB($bits(value_t) <= AXIL_DATA_BITS)

typedef enum logic {WAIT, RESPOND} state_t;
state_t state;

assign conf.read_ready = 1'b1;

assign conf.resp_data  = value;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        state           <= WAIT;
        conf.resp_valid <= 1'b0;
    end else begin
        if (state == WAIT) begin
            if (conf.read_valid) begin
                state           <= RESPOND;
                conf.resp_error <= conf.read_addr != ADDR;
                conf.resp_valid <= 1'b1;
            end
        end else begin
            if (conf.resp_ready) begin
                state           <= WAIT;
                conf.resp_valid <= 1'b0;
            end
        end
    end
end

endmodule
