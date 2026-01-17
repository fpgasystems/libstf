`timescale 1ns / 1ps

/**
 * Hasher that implements MurMur2 hashing with a pipeline of depth 6.
 */
module MurMurHasher #(
    parameter integer KEY_WIDTH = 32, // Currently, 32 and 64 are possible
    parameter integer HASH_WIDTH = 32
) (
    input logic clk,

    input  logic[KEY_WIDTH - 1:0] i_data,
    output logic o_data_ready,
    
    output logic[HASH_WIDTH - 1:0] o_data,
    input  logic i_data_ready
);

logic[KEY_WIDTH - 1:0] key_0, bitshift_key_0, xor_key_0,
                       key_2, bitshift_key_2, xor_key_2,
                       key_4, bitshift_key_4, xor_key_4;
logic[2 * KEY_WIDTH - 1:0] mult_key_1, mult_key_3;

always_comb begin
    key_0 = i_data;
    key_2 = mult_key_1[KEY_WIDTH - 1:0];
    key_4 = mult_key_3[KEY_WIDTH - 1:0];
end

always_comb begin
    bitshift_key_0 = (KEY_WIDTH == 32) ? (key_0 >> 16) : (key_0 >> 33);
    bitshift_key_2 = (KEY_WIDTH == 32) ? (key_2 >> 13) : (key_2 >> 33);
    bitshift_key_4 = (KEY_WIDTH == 32) ? (key_4 >> 16) : (key_4 >> 33);
end

always_ff @(posedge clk) begin
    if(i_data_ready) begin
        xor_key_0  <= key_0 ^ bitshift_key_0;
        mult_key_1 <= (KEY_WIDTH == 32) ? (xor_key_0 * 32'h85ebca6b) : (xor_key_0 * 64'hff51afd7ed558ccd);
        
        xor_key_2  <= key_2 ^ bitshift_key_2;
        mult_key_3 <= (KEY_WIDTH == 32) ? (xor_key_2 * 32'hc2b2ae35) : (xor_key_2 * 64'hc4ceb9fe1a85ec53);
        
        xor_key_4 <= key_4 ^ bitshift_key_4;

        o_data <= xor_key_4[HASH_WIDTH - 1:0];
    end else begin
        o_data <= o_data;
    end
end

assign o_data_ready = i_data_ready;

endmodule
