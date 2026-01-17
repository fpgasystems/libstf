`timescale 1ns / 1ps

module DataCompactorLevel #(
    parameter ID,
    parameter type data_t,
    parameter NUM_ELEMENTS,
    parameter REGISTER = 0,
    parameter COUNTER_WIDTH = $clog2(NUM_ELEMENTS)
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in, // #(data_t, NUM_ELEMENTS)
    input logic[COUNTER_WIDTH - 1:0] counter_in,

    ndata_i.m out, // #(data_t, NUM_ELEMENTS)
    output logic[COUNTER_WIDTH - 1:0] counter_out
);

data_t[NUM_ELEMENTS - 1:0] next_data;
logic[NUM_ELEMENTS - 1:0]  next_keep;
logic[COUNTER_WIDTH - 1:0] next_counter;

always_comb begin
    next_data = in.data;
    next_keep = in.keep;

    for (int i = 0; i < ID; i++) begin
        if (in.keep[ID] && i == counter_in) begin
            next_data[i] = in.data[ID];
            next_keep[i] = 1'b1;
        end
    end

    if (counter_in < ID || ~in.keep[ID]) begin
        next_keep[ID] = 1'b0;
    end
    
    if (in.keep[ID]) begin
        next_counter = counter_in + 1;
    end else begin
        next_counter = counter_in;
    end
end

generate if (REGISTER) begin
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            out.valid <= 1'b0;
        end else begin
            if (out.ready) begin
                out.data  <= next_data;
                out.keep  <= next_keep;
                out.last  <= in.last;
                out.valid <= in.valid;

                counter_out <= next_counter;
            end
        end
    end
end else begin
    assign out.data  = next_data;
    assign out.keep  = next_keep;
    assign out.last  = in.last;
    assign out.valid = in.valid;

    assign counter_out = next_counter;
end endgenerate

assign in.ready = out.ready;

endmodule
