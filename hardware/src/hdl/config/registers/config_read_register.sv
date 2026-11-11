`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * This module implements a read register for a plain signal.
 */
module ConfigReadRegister
    import lynxTypes::*;
#(
    parameter int ADDR,
    parameter type value_t
) (
    input logic clk,
    input logic rst_n,

    read_config_i.s in,

    input value_t value
);

// Check that input signal fits into AXIL_DATA_BITS
`ASSERT_ELAB($bits(value_t) <= AXIL_DATA_BITS)

typedef enum logic {WAIT, RESPOND} state_t;
state_t state;

assign in.read_ready = 1'b1;

assign in.resp_data  = value;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        state         <= WAIT;
        in.resp_error <= 'X;
        in.resp_valid <= 1'b0;
    end else begin
        if (state == WAIT) begin
            if (in.read_valid) begin
                state         <= RESPOND;
                in.resp_error <= in.read_addr != ADDR;
                in.resp_valid <= 1'b1;
            end
        end else begin
            if (in.resp_ready) begin
                state         <= WAIT;
                in.resp_valid <= 1'b0;
            end
        end
    end
end

endmodule
