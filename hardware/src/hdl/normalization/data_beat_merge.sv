`timescale 1ns / 1ps

import lynxTypes::*;

`include "libstf_macros.svh"

/**
 * Cross-beat merge / output register stage used by the `DataNormalizer`. This module holds an 
 * output register that merges the wrapped bytes of the former data beat into the following data 
 * beat so that every emitted data beat (except the last) is fully packed.
 */
module DataBeatMerge #(
    parameter type data_t,
    parameter NUM_ELEMENTS
) (
    input logic clk,
    input logic rst_n,

    ndata_i.s in, // #(data_t, NUM_ELEMENTS)
    ndata_i.m out // #(data_t, NUM_ELEMENTS)
);

ndata_i #(data_t, NUM_ELEMENTS) register(clk, rst_n);

logic emit;
logic[NUM_ELEMENTS - 1:0] register_and_shifted_keep, register_or_shifted_keep;

always_ff @(posedge clk) begin
    if (!rst_n) begin
        register.valid <= 0;
        out.valid      <= 0;
    end else begin
        if (!out.valid || out.ready) begin // TODO Add to condition: new data does not overflow register (but then out needs to be handled differently too)
            for (int i = 0; i < NUM_ELEMENTS; i++) begin
                if (register.valid && register.keep[i]) begin
                    out.data[i] <= register.data[i];
                    if (emit) begin
                        register.data[i] <= in.data[i];
                    end
                end else begin
                    out.data[i]      <= in.data[i];
                    register.data[i] <= in.data[i];
                end
            end

            if (in.valid) begin // Only if valid data is coming out of the shifter, the output stage can be updated
                if (register.valid && register.last) begin // There is some data left from the last stream that we have to flush
                    out.keep       <= register.keep;
                    out.last       <= 1;
                    out.valid      <= 1;
                    register.valid <= 0;
                end else begin
                    if (emit) begin // The output register would be full
                        out.keep  <= -1;
                        out.valid <= 1;

                        if (in.last) begin // Handle tlast
                            if (register_and_shifted_keep == 0) begin // All remaining data leaves this cycle, so this is last anyway
                                out.last <= 1;
                            end else begin // Set flag so that next cycle will write output register
                                out.last      <= 0;
                                register.last <= 1;
                            end
                        end else begin
                            register.last <= 0;
                            out.last      <= 0;
                        end

                        register.keep  <= register_and_shifted_keep;
                        register.valid <= |register_and_shifted_keep;
                    end else begin
                        if (in.last) begin // If this is the last transfer, transmit output register and pipeline output directly
                            out.keep  <= register_or_shifted_keep;
                            out.last  <= 1;
                            out.valid <= 1;

                            register.valid <= 0;
                        end else begin
                            out.valid <= 0; // this cannot be valid anymore

                            register.keep  <= register_or_shifted_keep;
                            register.last  <= 0;
                            register.valid <= |register_or_shifted_keep;
                        end
                    end
                end
            end else begin
                if (register.valid && (&register.keep || register.last)) begin
                    out.keep  <= register.keep;
                    out.last  <= register.last;
                    out.valid <= 1;

                    register.last  <= 0;
                    register.valid <= 0;
                end else begin
                    out.valid <= 0;
                end
            end
        end
    end
end

// Assign ready to silence assertion that ready cannot be undefined. Needs to be high so we do not
// get in trouble with with stable assertion of the interface.
assign register.ready = 1'b1;

assign emit = register.valid && in.valid && &(register.keep | in.keep);
assign register_and_shifted_keep = register.valid ? register.keep & in.keep : in.keep;
assign register_or_shifted_keep = register.valid ? register.keep | in.keep : in.keep;

assign in.ready = (!out.valid || out.ready) && !(register.valid && register.last);

endmodule
