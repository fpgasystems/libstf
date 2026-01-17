`timescale 1ns / 1ps

/**
 * The ReorderEnumerator assigns each element in an ndata input stream a serial number in the tag 
 * field of the ntagged output stream for later reordering with the Reorder module.
 */
module ReorderEnumerator #(
    parameter type data_t, 
    parameter NUM_ELEMENTS,
    parameter SERIAL_WIDTH
) (
    input logic clk,
    input logic rst_n,
    
    ndata_i.s   in, // #(data_t, NUM_ELEMENTS)
    ntagged_i.m out // #(data_t, NUM_ELEMENTS, SERIAL_WIDTH)
);

localparam DATA_BITS = $clog2(NUM_ELEMENTS);
localparam SERIAL_BEAT_BITS = SERIAL_WIDTH - DATA_BITS;

typedef logic[SERIAL_BEAT_BITS - 1:0] beat_serial_t;

beat_serial_t serial_count[NUM_ELEMENTS];

assign in.ready = out.ready;

always_ff @(posedge clk) begin
    if(!rst_n) begin
        for (int i = 0; i < NUM_ELEMENTS; i++) begin
            serial_count[i] <= '0;
        end
    end else begin
        if (in.valid && in.ready) begin
            for (int i = 0; i < NUM_ELEMENTS; i++) begin
                if (in.keep[i]) begin
                    serial_count[i] <= serial_count[i] + 1;
                end else begin
                    serial_count[i] <= serial_count[i];
                end
            end
        end else begin
            serial_count <= serial_count;
        end
    end
end

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign out.tag[I] = (serial_count[I] << DATA_BITS) + I;
end

assign out.data  = in.data;
assign out.keep  = in.keep;
assign out.last  = in.last;
assign out.valid = in.valid;

endmodule
