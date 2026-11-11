`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * Hasher that implements MurMur2 hashing with a pipeline of depth 6. The pipeline only advances
 * while out_ready is high. in_ready mirrors out_ready.
 */
module MurMurHasher #(
    parameter int KEY_WIDTH = 32, // Currently, 32 and 64 are possible
    parameter int HASH_WIDTH = 32
) (
    input logic clk,

    input  logic[KEY_WIDTH - 1:0] in_data,
    output logic                  in_ready,

    output logic[HASH_WIDTH - 1:0] out_data,
    input  logic                   out_ready
);

`ASSERT_ELAB(KEY_WIDTH == 32 || KEY_WIDTH == 64, "KEY_WIDTH has to be 32 or 64")
`ASSERT_ELAB(HASH_WIDTH > 0 && HASH_WIDTH <= KEY_WIDTH, "HASH_WIDTH has to be in [1, KEY_WIDTH]")

logic[KEY_WIDTH - 1:0] key_0, bitshift_key_0, xor_key_0,
                       key_2, bitshift_key_2, xor_key_2,
                       key_4, bitshift_key_4, xor_key_4;
logic[2 * KEY_WIDTH - 1:0] mult_key_1, mult_key_3;

always_comb begin
    key_0 = in_data;
    key_2 = mult_key_1[KEY_WIDTH - 1:0];
    key_4 = mult_key_3[KEY_WIDTH - 1:0];
end

always_comb begin
    bitshift_key_0 = (KEY_WIDTH == 32) ? (key_0 >> 16) : (key_0 >> 33);
    bitshift_key_2 = (KEY_WIDTH == 32) ? (key_2 >> 13) : (key_2 >> 33);
    bitshift_key_4 = (KEY_WIDTH == 32) ? (key_4 >> 16) : (key_4 >> 33);
end

always_ff @(posedge clk) begin
    if (out_ready) begin
        xor_key_0  <= key_0 ^ bitshift_key_0;
        mult_key_1 <= (KEY_WIDTH == 32) ? (xor_key_0 * 32'h85ebca6b) :
                                          (xor_key_0 * 64'hff51afd7ed558ccd);

        xor_key_2  <= key_2 ^ bitshift_key_2;
        mult_key_3 <= (KEY_WIDTH == 32) ? (xor_key_2 * 32'hc2b2ae35) :
                                          (xor_key_2 * 64'hc4ceb9fe1a85ec53);

        xor_key_4 <= key_4 ^ bitshift_key_4;

        out_data <= xor_key_4[HASH_WIDTH - 1:0];
    end else begin
        out_data <= out_data;
    end
end

assign in_ready = out_ready;

endmodule
