`timescale 1ns / 1ps

/**
 * This module delays the reset signal by one cycle by buffering it in a register.
 *
 * This can be used to break long reset chains which can lead to timing issues and designs that are 
 * difficult to place & optimize.
 */
module ResetResync (
    input  logic clk,
    input  logic reset_in,
    output logic reset_out
);

// Initialize as not reset. We need two stages because the reset signal is asynchronous.
logic[1:0] reset_buffer = '0;

always_ff @(posedge clk) begin
    reset_buffer[0] <= reset_in;
    reset_buffer[1] <= reset_buffer[0];
end

assign reset_out = reset_buffer[1];

endmodule
