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

ndata_i #(data_t, NUM_ELEMENTS) compactor_out();
ndata_i #(data_t, NUM_ELEMENTS) shifter_out();
ndata_i #(data_t, NUM_ELEMENTS) register();

logic emit;
logic[NUM_ELEMENTS - 1:0] register_and_shifted_keep, register_or_shifted_keep;

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

always_ff @(posedge clk) begin
    if (!rst_n) begin
        register.valid <= 0;
        out.valid      <= 0;
    end else begin
        if (out.ready) begin // TODO Add to condition: or !out.valid or new data does not overflow register (but then out needs to be handled differently too)
            for (int i = 0; i < NUM_ELEMENTS; i++) begin
                if (register.valid && register.keep[i]) begin
                    out.data[i] <= register.data[i];
                    if (emit) begin
                        register.data[i] <= shifter_out.data[i];
                    end
                end else begin
                    out.data[i]      <= shifter_out.data[i];
                    register.data[i] <= shifter_out.data[i];
                end
            end

            if (shifter_out.valid) begin // Only if valid data is coming out of the shifter, the output stage can be updated
                if (register.valid && register.last) begin // There is some data left from the last stream that we have to flush
                    out.keep       <= register.keep;
                    out.last       <= 1;
                    out.valid      <= 1;
                    register.valid <= 0;
                end else begin
                    if (emit) begin // The output register would be full
                        out.keep  <= -1;
                        out.valid <= 1;

                        if (shifter_out.last) begin // Handle tlast
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
                        if (shifter_out.last) begin // If this is the last transfer, transmit output register and pipeline output directly
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

assign emit = register.valid && shifter_out.valid && &(register.keep | shifter_out.keep);
assign register_and_shifted_keep = register.valid ? register.keep & shifter_out.keep : shifter_out.keep;
assign register_or_shifted_keep = register.valid ? register.keep | shifter_out.keep : shifter_out.keep;

assign shifter_out.ready = out.ready && !(register.valid && register.last);

endmodule
