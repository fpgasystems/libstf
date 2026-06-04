`timescale 1ns / 1ps

import lynxTypes::*;

`include "libstf_macros.svh"

module DataNormalizer #(
    parameter type data_t,
    parameter NUM_ELEMENTS,
    parameter ENABLE_COMPACTOR = 0,
    parameter COMPACTOR_REGISTER_LEVELS = 1,
    parameter BARREL_SHIFTER_REGISTER_LEVELS = 1
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in, // #(data_t, NUM_ELEMENTS)
    ndata_i.m out // #(data_t, NUM_ELEMENTS)
);

logic[$clog2(NUM_ELEMENTS) - 1:0] offset;

ndata_i #(data_t, NUM_ELEMENTS) compactor_out(clk, rst_n);
ndata_i #(data_t, NUM_ELEMENTS) shifter_out(clk, rst_n);

generate if (ENABLE_COMPACTOR) begin
    DataCompactor #(.data_t(data_t), .NUM_ELEMENTS(NUM_ELEMENTS), .REGISTER_LEVELS(COMPACTOR_REGISTER_LEVELS)) inst_compactor (
        .clk(clk),
        .rst_n(rst_n),

        .in(in),
        .out(compactor_out)
    );
end else begin
    `DATA_ASSIGN(in, compactor_out);
end endgenerate

always_ff @(posedge clk) begin
    if (!rst_n) begin
        offset <= 0;
    end else begin
        if (compactor_out.valid && compactor_out.ready) begin
            if (compactor_out.last) begin
                offset <= 0;
            end else begin
                offset <= offset + $countones(compactor_out.keep);
            end
        end
    end
end

BarrelShifter #(.data_t(data_t), .NUM_ELEMENTS(NUM_ELEMENTS), .REGISTER_LEVELS(BARREL_SHIFTER_REGISTER_LEVELS)) inst_shifter (
    .clk(clk),
    .rst_n(rst_n),

    .offset(offset),
    .in(compactor_out),
    .out(shifter_out)
);

DataBeatMerge #(.data_t(data_t), .NUM_ELEMENTS(NUM_ELEMENTS)) inst_merge (
    .clk(clk),
    .rst_n(rst_n),

    .in(shifter_out),
    .out(out)
);

endmodule
