`timescale 1ns / 1ps

module DictionaryBank #(
    parameter type value_t,
    parameter type id_t
) (
    input logic clk,
    input logic rst_n,

    data_i.s in_value, // #(value_t)
    data_i.s in_id,    // #(serial_id_t)

    data_i.m out // #(serial_value_t)
);

typedef enum integer {WRITE, READ, FLUSH} state_t;

state_t state;

id_t  write_addr;
logic write_enable;

assign in_value.ready = state == WRITE ? 1'b1 : 1'b0;
assign in_id.ready    = state == READ  ? out.ready : 1'b0;

assign write_enable = state == WRITE ? in_value.valid : 1'b0;

ReadyRAM #(
    .DATA_WIDTH($bits(value_t)),
    .ADDR_WIDTH($bits(id_t)),
    .STYLE("ultra")
) inst_value_uram (
    .clk(clk),

    .write_addr(write_addr),
    .write_data(in_value.data),
    .write_enable(write_enable),

    .read_addr(in_id.data.id),
    .read_data(out.data.value),
    .read_ready(out.ready)
);

always_ff @(posedge clk) begin
    if(!rst_n) begin
        state      <= WRITE;
        write_addr <= '0;
        out.valid  <= 1'b0;
    end else begin
        case (state)
        WRITE: begin
            if (in_value.valid) begin
                if (in_value.last) begin
                    state      <= READ;
                    write_addr <= '0;
                end else begin
                    write_addr <= write_addr + 1;
                end
            end
        end
        READ: begin
            if (out.ready) begin
                out.data.serial <= in_id.data.serial;
                out.keep        <= in_id.keep;
                out.last        <= in_id.last;

                // Filter dummy last elements added by the pre crossbar
                out.valid <= in_id.valid && in_id.keep;

                if (in_id.valid && in_id.last) begin
                    state <= FLUSH;
                end
            end
        end
        FLUSH: begin
            if (!out.valid || out.ready) begin
                out.valid <= 1'b0;
                state     <= WRITE;
            end
        end endcase
    end
end

endmodule
