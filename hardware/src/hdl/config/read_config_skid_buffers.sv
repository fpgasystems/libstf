`timescale 1ns / 1ps

import libstf::*;

`include "libstf_macros.svh"

/**
 * Inserts DEPTH register (skid-buffer) stages into a read_config_i link, on both the request
 * channel and the response channel.
 */
module ReadConfigSkidBuffers #(
    parameter integer DEPTH = 1
) (
    input logic clk,
    input logic rst_n,

    read_config_i.s in,
    read_config_i.m out
);

`ASSERT_ELAB(DEPTH >= 0)

if (DEPTH == 0) begin : gen_passthrough
    assign out.read_addr  = in.read_addr;
    assign out.read_valid = in.read_valid;
    assign in.read_ready  = out.read_ready;

    assign in.resp_data   = out.resp_data;
    assign in.resp_error  = out.resp_error;
    assign in.resp_valid  = out.resp_valid;
    assign out.resp_ready = in.resp_ready;
end else begin : gen_skid_buffers
    // -- Request channel (in -> out) --------------------------------------------------------------
    typedef logic[AXI_ADDR_BITS - 1:0] req_t;

    ready_valid_i #(req_t) req_stage[DEPTH + 1](clk, rst_n);

    assign req_stage[0].data      = in.read_addr;
    assign req_stage[0].valid     = in.read_valid;
    assign in.read_ready          = req_stage[0].ready;

    assign out.read_addr          = req_stage[DEPTH].data;
    assign out.read_valid         = req_stage[DEPTH].valid;
    assign req_stage[DEPTH].ready = out.read_ready;

    // -- Response channel (out -> in) -------------------------------------------------------------
    typedef struct packed {
        logic[AXIL_DATA_BITS - 1:0] data;
        logic                       error;
    } resp_t;

    ready_valid_i #(resp_t) resp_stage[DEPTH + 1](clk, rst_n);

    assign resp_stage[0].data.data  = out.resp_data;
    assign resp_stage[0].data.error = out.resp_error;
    assign resp_stage[0].valid      = out.resp_valid;
    assign out.resp_ready           = resp_stage[0].ready;

    assign in.resp_data             = resp_stage[DEPTH].data.data;
    assign in.resp_error            = resp_stage[DEPTH].data.error;
    assign in.resp_valid            = resp_stage[DEPTH].valid;
    assign resp_stage[DEPTH].ready  = in.resp_ready;

    for (genvar S = 0; S < DEPTH; S++) begin : gen_stages
        SkidBuffer #(req_t) inst_req_skid (
            .clk(clk),
            .rst_n(rst_n),

            .in(req_stage[S]),
            .out(req_stage[S + 1])
        );

        SkidBuffer #(resp_t) inst_resp_skid (
            .clk(clk),
            .rst_n(rst_n),

            .in(resp_stage[S]),
            .out(resp_stage[S + 1])
        );
    end
end

endmodule
