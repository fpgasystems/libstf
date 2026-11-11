`timescale 1ns / 1ps

/**
 * WARNING: For now, this register does not apply back pressure to the GlobalConfig. So values may
 * be lost.
 */
module ConfigWriteReadyRegister #(
    parameter int ADDR,
    parameter type data_t
) (
    input logic clk,
    input logic rst_n,

    write_config_i.s write_config,
    ready_valid_i.m  out // #(data_t)
);

always_ff @(posedge clk) begin
    if (!rst_n) begin
        out.data  <= 'X;
        out.valid <= 1'b0;
    end else begin
        if (write_config.valid && write_config.addr == ADDR) begin
            out.data  <= data_t'(write_config.data);
            out.valid <= 1'b1;
        end else if (out.ready) begin
            out.valid <= 1'b0;
        end
    end
end

endmodule
