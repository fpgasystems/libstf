`timescale 1ns / 1ps

module ConfigWriteRegister #(
    parameter integer ADDR,
    parameter type    data_t
) (
    input logic clk,

    write_config_i.s write_config,
    output data_t    data
);

always_ff @(posedge clk) begin
    if (write_config.valid && write_config.addr == ADDR) begin
        data <= data_t'(write_config.data);
    end
end

endmodule
