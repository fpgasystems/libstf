`timescale 1ns / 1ps

`include "libstf_macros.svh"

module DictionaryBank #(
    parameter type value_t,
    parameter type id_t, // RAM address, i.e., the id field of in_id
    parameter int DEPTH = 2 ** $bits(id_t) // Number of values, ids from 0 to DEPTH - 1
) (
    input logic clk,
    input logic rst_n,

    data_i.s in_value, // #(value_t)
    data_i.s in_id,    // #(serial_id_t)

    data_i.m out // #(serial_value_t)
);

`RESET_RESYNC // Reset pipelining

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
    .DEPTH(DEPTH),
    .STYLE("ultra"),
    .PACK(1)
) inst_value_uram (
    .clk(clk),

    .write_addr(write_addr),
    .write_data(in_value.data),
    .write_enable(write_enable),

    .read_addr(in_id.data.id),
    .read_data(out.data.value),
    .read_ready(out.ready)
);

`ifndef SYNTHESIS
assert property (@(posedge clk) disable iff (!reset_synced) !(state == WRITE && in_value.valid) || write_addr < DEPTH)
else $fatal(1, "DictionaryBank holds at most %0d values", DEPTH);

assert property (@(posedge clk) disable iff (!reset_synced) !(state == READ && in_id.valid && in_id.keep) || in_id.data.id < DEPTH)
else $fatal(1, "DictionaryBank read of id %0d beyond its %0d values", in_id.data.id, DEPTH);
`endif

always_ff @(posedge clk) begin
    if(!reset_synced) begin
        state      <= WRITE;
        write_addr <= '0;

        out.data.serial <= 'X;
        out.keep        <= 'X;
        out.last        <= 'X;
        out.valid       <= 1'b0;
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
