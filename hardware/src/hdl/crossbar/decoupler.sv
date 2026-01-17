`timescale 1ns / 1ps

/**
 * The Decoupler splits up data beats of an ndata stream into individual data streams per element.
 */
module Decoupler #(
    parameter type data_t, 
    parameter NUM_ELEMENTS
) (
    input logic clk,
    input logic rst_n,
    
    ndata_i.s in,               // #(data_t, NUM_ELEMENTS)
    data_i.m  out[NUM_ELEMENTS] // #(data_t)
);

data_i #(data_t) n_out[NUM_ELEMENTS]();
logic[NUM_ELEMENTS - 1:0] out_valid, out_ready;

assign in.ready = ~|out_valid || &out_ready;

for (genvar I = 0; I < NUM_ELEMENTS; I++) begin
    assign out_valid[I] = out[I].valid;
    assign out_ready[I] = out[I].ready;

    always_ff @(posedge clk) begin
        if(!rst_n) begin
            out[I].valid <= 1'b0;     
        end else begin
            out[I].data  <= n_out[I].data;
            out[I].keep  <= n_out[I].keep;
            out[I].last  <= n_out[I].last;
            out[I].valid <= n_out[I].valid;
        end
    end

    always_comb begin
        n_out[I].data  = out[I].data;
        n_out[I].keep  = out[I].keep;
        n_out[I].last  = out[I].last;
        n_out[I].valid = 1'b0;

        if (in.ready) begin
            n_out[I].data  = in.data[I];
            n_out[I].keep  = in.keep[I];
            n_out[I].last  = in.last;
            n_out[I].valid = in.valid;
        end else if (!out[I].ready) begin // Not all output streams are ready => We need to stall and keep only the valid signals of the lanes that are not ready
            n_out[I].valid = out[I].valid;
        end
    end
end

endmodule
