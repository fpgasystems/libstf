`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * Returns the value corresponding to the read_addr to resp_data. If the read_addr is out of bounds,
 * it returns an error.
 */
module ConfigReadRegisterFile
    import lynxTypes::*;
#(
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
localparam ADDR_BITS = NUM_REGS > 1 ? $clog2(NUM_REGS) : 1;

typedef enum logic[1:0] {WAIT, LOOKUP, RESPOND} state_t;
state_t state;

logic[ADDR_BITS - 1:0] addr, n_addr;
logic                  addr_valid, n_addr_valid;

logic[AXIL_DATA_BITS - 1:0] n_resp_data;

// -- Logic ----------------------------------------------------------------------------------------
assign in.read_ready = state == WAIT;

assign n_addr       = ADDR_BITS'(in.read_addr);
assign n_addr_valid = in.read_addr < NUM_REGS;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        state      <= WAIT;
        addr       <= 'X;
        addr_valid <= 'X;

        in.resp_data  <= 'X;
        in.resp_error <= 'X;
        in.resp_valid <= 1'b0;
    end else begin
        case (state)
            WAIT: begin
                if (in.read_valid) begin
                    state      <= LOOKUP;
                    addr       <= n_addr;
                    addr_valid <= n_addr_valid;
                end
            end
            LOOKUP: begin
                state <= RESPOND;

                in.resp_data  <= n_resp_data;
                in.resp_error <= !addr_valid;
                in.resp_valid <= 1'b1;
            end
            default: begin
                if (in.resp_ready) begin
                    state         <= WAIT;
                    in.resp_valid <= 1'b0;
                end
            end
        endcase
    end
end

always_comb begin
    n_resp_data = '0;

    if (addr_valid) begin
        n_resp_data = values[addr];
    end
end

endmodule
