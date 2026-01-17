`timescale 1ns / 1ps

`include "libstf_macros.svh"

/**
 * Converts a ndata stream to an AXI stream.
 *
 * Hint: Currently supports same number of input and output elements and doubling the stream width.
 */
module NDataToAXI #(
    parameter type data_t,
    parameter NUM_ELEMENTS,
    parameter AXI_WIDTH = AXI_DATA_BITS,
    parameter NUM_AXI_ELEMENTS = AXI_WIDTH / $bits(data_t)
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in, // #(data_t, NUM_ELEMENTS)

    AXI4S.m out // #(AXI_WIDTH)
);

localparam AXI_ELEMENT_WIDTH = AXI_WIDTH / NUM_AXI_ELEMENTS;
localparam AXI_ELEMENT_SIZE = AXI_ELEMENT_WIDTH / 8;

`ASSERT_ELAB(AXI_WIDTH == AXI_ELEMENT_WIDTH * NUM_AXI_ELEMENTS)
`ASSERT_ELAB($bits(data_t) <= AXI_ELEMENT_WIDTH)
`ASSERT_ELAB(NUM_ELEMENTS == NUM_AXI_ELEMENTS || 2 * NUM_ELEMENTS == NUM_AXI_ELEMENTS)

ndata_i #(data_t, NUM_AXI_ELEMENTS) internal();

NDataWidthConverter #(
    .data_t(data_t)
) inst_width_converter (
    .clk(clk),
    .rst_n(rst_n),

    .in(in),
    .out(internal)
);

assign internal.ready = out.tready;

for (genvar I = 0; I < NUM_AXI_ELEMENTS; I++) begin
    assign out.tdata[I * AXI_ELEMENT_WIDTH+:AXI_ELEMENT_WIDTH] = AXI_ELEMENT_WIDTH'(internal.data[I]);

    for (genvar J = 0; J < AXI_ELEMENT_SIZE; J++) begin
        assign out.tkeep[I * AXI_ELEMENT_SIZE + J] = internal.keep[I];
    end
end

assign out.tlast  = internal.last;
assign out.tvalid = internal.valid;

endmodule

/**
 * Converts an AXI stream to a ndata stream.
 *
 * Hint: Currently supports same number of input and output elements and halving the stream width.
 */
module AXIToNData #(
    parameter type data_t,
    parameter NUM_ELEMENTS,
    parameter AXI_WIDTH = AXI_DATA_BITS,
    parameter NUM_AXI_ELEMENTS = AXI_WIDTH / $bits(data_t)
) (
    input logic clk,
    input logic rst_n,

    AXI4S.s in, // #(AXI_WIDTH)

    ndata_i.m out // #(data_t, NUM_ELEMENTS)
);

localparam AXI_ELEMENT_WIDTH = AXI_WIDTH / NUM_AXI_ELEMENTS;
localparam AXI_ELEMENT_SIZE = AXI_ELEMENT_WIDTH / 8;

`ASSERT_ELAB(AXI_WIDTH == AXI_ELEMENT_WIDTH * NUM_AXI_ELEMENTS)
`ASSERT_ELAB($bits(data_t) <= AXI_ELEMENT_WIDTH)
`ASSERT_ELAB(NUM_ELEMENTS == NUM_AXI_ELEMENTS || NUM_ELEMENTS == NUM_AXI_ELEMENTS / 2)

AXI4S #(AXI_ELEMENT_WIDTH * NUM_ELEMENTS) internal(.aclk(clk), .aresetn(rst_n));

AXIWidthConverter inst_width_converter (
    .clk(clk),
    .rst_n(rst_n),

    .in(in),
    .out(internal)
);

assign internal.tready = out.ready;

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign out.data[I] = internal.tdata[I * AXI_ELEMENT_WIDTH+:$bits(data_t)];
    assign out.keep[I] = internal.tkeep[I * AXI_ELEMENT_SIZE];
end

assign out.last  = internal.tlast;
assign out.valid = internal.tvalid;

endmodule

/**
 * Converts an AXI stream to a data stream. If the last data beat of the incoming stream is not 
 * full, this returns data beats that have a low keep.
 */
module AXIToData #(
    parameter type data_t,
    parameter AXI_WIDTH = 512,
    parameter DATA_WIDTH = $bits(data_t),
    parameter NUM_ELEMENTS = AXI_WIDTH / DATA_WIDTH
) (
    input logic clk,
    input logic rst_n,

    AXI4S.s in, // #(AXI_WIDTH)

    data_i.m out // #(data_t)
);

generate if (NUM_ELEMENTS == 1) begin

`ASSERT_ELAB(DATA_WIDTH == AXI_WIDTH)

assign in.tready = out.ready;
assign out.keep  = &in.tkeep;
assign out.last  = in.tlast;
assign out.valid = in.tvalid;
assign out.data  = in.tdata;

end else begin

logic[$clog2(NUM_ELEMENTS) - 1:0] counter;

assign in.tready = out.ready && counter == NUM_ELEMENTS - 1;

always_ff @(posedge clk) begin
    if (rst_n == 1'b0) begin
        counter <= '0;
    end else begin
        if (in.tvalid && out.ready) begin
            counter <= counter + 1;
        end
    end
end

assign out.data  = in.tdata[counter * DATA_WIDTH+:DATA_WIDTH];
assign out.keep  = in.tkeep[counter * DATA_WIDTH / 8];
assign out.last  = in.tlast && counter == NUM_ELEMENTS - 1;
assign out.valid = in.tvalid;

end endgenerate

endmodule
