`timescale 1ns / 1ps

/**
 * The Creditor lets through new data beats as long as there is credit left. Credits have to be 
 * returned after the credited section of code.
 */
module Creditor #(
    parameter MAX_IN_TRANSIT
) (
    input logic clk,
    input logic rst_n,
    
    ndata_i.s in,  // #(data_t, NUM_ELEMENTS)
    ndata_i.m out, // #(data_t, NUM_ELEMENTS) 

    input logic credit_return
);

`ifndef SYNTHESIS
assert property (@(posedge clk) disable iff (!rst_n) !$isunknown(credit_return))
else $fatal(1, "Credit return signal cannot be undefined!");
`endif

logic[$clog2(MAX_IN_TRANSIT):0] credit_count, n_credit_count;
logic has_credit;

always_ff @(posedge clk) begin
    if(!rst_n) begin
        credit_count <= MAX_IN_TRANSIT - 1;
    end else begin
        credit_count <= n_credit_count;
    end
end

always_comb begin
    n_credit_count = credit_count;

    if (in.valid && out.ready) begin
        if (has_credit && !credit_return) begin
            n_credit_count = credit_count - 1;
        end
    end else begin
        if (credit_return) begin
            n_credit_count = credit_count + 1;
        end
    end
end

assign has_credit = !(credit_count == 0);

assign in.ready = has_credit || credit_return ? out.ready : 1'b0;

assign out.data  = in.data;
assign out.keep  = in.keep;
assign out.last  = in.last;
assign out.valid = has_credit || credit_return ? in.valid : 1'b0;

endmodule
