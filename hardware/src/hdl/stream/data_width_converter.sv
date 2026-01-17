`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * Converts an ndata_i stream to a different width.
 *
 * Currently only same input and output width and 8 to 16 elements is supported.
 */
module NDataWidthConverter #(
    parameter type data_t
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in, // #(data_t, IN_WIDTH)
    ndata_i.m out // #(data_t, OUT_WIDTH)
);

localparam IN_WIDTH  = in.NUM_ELEMENTS;
localparam OUT_WIDTH = out.NUM_ELEMENTS;

`ASSERT_ELAB(IN_WIDTH == OUT_WIDTH || IN_WIDTH == 8 && OUT_WIDTH == 16)

generate if (IN_WIDTH == OUT_WIDTH) begin
    `DATA_ASSIGN(in, out)
end else if (IN_WIDTH == 8 && OUT_WIDTH == 16) begin
    logic is_upper, n_is_upper;

    data_t[OUT_WIDTH - 1:0] data,  n_data;
    logic[OUT_WIDTH - 1:0]  keep,  n_keep;
    logic                   last,  n_last;
    logic                   valid, n_valid;

    assign in.ready = out.ready;

    always_ff @(posedge clk) begin
        if (rst_n == 1'b0) begin
            is_upper <= 1'b0;

            valid <= 1'b0;
        end else begin
            is_upper <= n_is_upper;

            data  <= n_data;
            keep  <= n_keep;
            last  <= n_last;
            valid <= n_valid;
        end
    end

    always_comb begin
        n_is_upper = is_upper;

        n_data  = data;
        n_keep  = keep;
        n_last  = last;
        n_valid = 1'b0;

        if (out.ready) begin
            if (in.valid) begin
                if (!in.last) begin
                    n_is_upper = ~is_upper;
                end else begin
                    n_is_upper = 1'b0;
                end
            end

            if (!is_upper) begin
                n_data[7:0]  = in.data;
                n_keep[15:8] = '0;
                n_keep[7:0]  = in.keep;
                
                if (in.last) begin
                    n_valid = in.valid;
                end
            end else begin
                n_data[15:8] = in.data;
                n_keep[15:8] = in.keep;
                n_valid      = in.valid;
            end

            n_last = in.last;
        end else begin
            n_valid = valid;
        end
    end

    assign out.data  = data;
    assign out.keep  = keep;
    assign out.last  = last;
    assign out.valid = valid;
end endgenerate

endmodule
