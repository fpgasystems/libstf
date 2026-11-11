`timescale 1ns / 1ps

`include "libstf_macros.svh"

module MultiInsertFIFOAXI #(
    parameter int DEPTH,
    parameter int DATA_WIDTH,
    parameter int FACTOR
) (
    input logic clk,
    input logic rst_n,

    AXI4S.s in,  // #(FACTOR * DATA_WIDTH)
    AXI4S.m out, // #(DATA_WIDTH)

    output logic[$clog2(DEPTH):0] filling_level
);

localparam int FIFO_WIDTH = DATA_WIDTH + DATA_WIDTH / 8 + 1;
localparam int TOTAL_WIDTH = FIFO_WIDTH * FACTOR;

`ASSERT_ELAB(DATA_WIDTH == out.AXI4S_DATA_BITS)
`ASSERT_ELAB(FACTOR * DATA_WIDTH == in.AXI4S_DATA_BITS)
`ASSERT_ELAB(FACTOR >= 2 && 2**$clog2(FACTOR) == FACTOR, "FACTOR has to be a power of two > 1")

logic[TOTAL_WIDTH - 1:0] data_flattened;

AXI4S #(DATA_WIDTH) axis_fifo(.aclk(clk), .aresetn(rst_n));
AXI4S #(DATA_WIDTH) axis_reg (.aclk(clk), .aresetn(rst_n));

for (genvar I = 0; I < FACTOR; I++) begin : gen_flatten
    assign data_flattened[FIFO_WIDTH * I +: FIFO_WIDTH] = {
        in.tdata[DATA_WIDTH * I +: DATA_WIDTH],
        in.tkeep[DATA_WIDTH / 8 * I +: DATA_WIDTH / 8],
        I == FACTOR - 1 ? in.tlast : 1'b0
    };
end

MultiInsertFIFO #(DEPTH, FIFO_WIDTH, FACTOR) inst_fifo (
    .clk(clk),
    .rst_n(rst_n),

    .in_data(data_flattened),
    .in_valid(in.tvalid),
    .in_ready(in.tready),

    .out_data({axis_fifo.tdata, axis_fifo.tkeep, axis_fifo.tlast}),
    .out_valid(axis_fifo.tvalid),
    .out_ready(out.tready),

    .filling_level(filling_level)
);

always_ff @(posedge clk) begin // Remove data beats with keep 0
    if (!rst_n) begin
        axis_reg.tdata  <= 'X;
        axis_reg.tkeep  <= 'X;
        axis_reg.tlast  <= 'X;
        axis_reg.tvalid <= 0;

        out.tdata  <= 'X;
        out.tkeep  <= 'X;
        out.tlast  <= 'X;
        out.tvalid <= 0;
    end else begin
        if (out.tready) begin
            out.tvalid <= 0;

            if (axis_fifo.tvalid) begin
                if (|axis_fifo.tkeep) begin
                    axis_reg.tdata <= axis_fifo.tdata;
                    axis_reg.tkeep <= axis_fifo.tkeep;
                end
                axis_reg.tlast <= axis_fifo.tlast;
            end

            if (!axis_reg.tvalid || axis_reg.tlast) begin
                axis_reg.tvalid <= axis_fifo.tvalid;
            end

            if (axis_reg.tlast || (axis_fifo.tvalid && |axis_fifo.tkeep)) begin
                out.tdata  <= axis_reg.tdata;
                out.tkeep  <= axis_reg.tkeep;
                out.tlast  <= axis_reg.tlast;
                out.tvalid <= axis_reg.tvalid;
            end
        end
    end
end

endmodule
