`timescale 1ns / 1ps

module MultiInsertFIFOAXI #(
    parameter DEPTH,
    parameter DATA_WIDTH,
    parameter FACTOR
) (
    input logic clk,
    input logic rst_n,

    AXI4S.s i_data,
    AXI4S.m o_data,

    output logic[$clog2(DEPTH):0] filling_level
);

localparam FIFO_WIDTH = DATA_WIDTH + DATA_WIDTH / 8 + 1;
localparam TOTAL_WIDTH = FIFO_WIDTH * FACTOR;

logic[TOTAL_WIDTH - 1:0] data_flattened;

AXI4S #(DATA_WIDTH) axis_fifo(.aclk(clk), .aresetn(rst_n));
AXI4S #(DATA_WIDTH) axis_reg (.aclk(clk), .aresetn(rst_n));

genvar i;
generate
for (i = 0; i < FACTOR; i++) begin
    assign data_flattened[FIFO_WIDTH * i +: FIFO_WIDTH] = {i_data.tdata[DATA_WIDTH * i +: DATA_WIDTH], i_data.tkeep[DATA_WIDTH / 8 * i +: DATA_WIDTH / 8], i == FACTOR - 1 ? i_data.tlast : 1'b0};
end
endgenerate

MultiInsertFIFO #(DEPTH, FIFO_WIDTH, FACTOR) inst_fifo (
    .i_clk(clk),
    .i_rst_n(rst_n),

    .i_data(data_flattened),
    .i_valid(i_data.tvalid),
    .o_ready(i_data.tready),

    .o_data({axis_fifo.tdata, axis_fifo.tkeep, axis_fifo.tlast}),
    .o_valid(axis_fifo.tvalid),
    .i_ready(o_data.tready),

    .o_filling_level(filling_level)
);

always_ff @(posedge clk) begin // Remove data beats with keep 0
    if (rst_n == 0) begin
        axis_reg.tvalid <= 0;
        o_data.tvalid   <= 0;
    end else begin
        if (o_data.tready) begin
            o_data.tvalid <= 0;

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
                o_data.tdata  <= axis_reg.tdata;
                o_data.tkeep  <= axis_reg.tkeep;
                o_data.tlast  <= axis_reg.tlast;
                o_data.tvalid <= axis_reg.tvalid;
            end
        end
    end
end

endmodule
