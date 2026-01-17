`timescale 1ns / 1ps

import libstf::*;

`include "libstf_macros.svh"

interface write_config_i (
    input logic clk,
    input logic rst_n
);
    logic[AXI_ADDR_BITS - 1:0]  addr;
    logic[AXIL_DATA_BITS - 1:0] data;
    logic                       valid;

    // Tie off unused master signals
    task tie_off_m();
        valid = 1'b0;
    endtask

    modport m (
        import tie_off_m,
        output addr, data, valid
    );

    modport s (
        input  addr, data, valid
    );

`ifndef SYNTHESIS
    `STF_ASSERT_NOT_UNDEFINED(valid);
`endif
endinterface

interface read_config_i (
    input logic clk,
    input logic rst_n
);
    logic[AXI_ADDR_BITS - 1:0] read_addr;
    logic                      read_valid;
    logic                      read_ready;

    logic[AXIL_DATA_BITS - 1:0] resp_data;
    logic                       resp_error; // Asserted if we could not read the config register
    logic                       resp_valid;
    logic                       resp_ready;

    // Tie off unused master signals
    task tie_off_m();
        read_valid  = 1'b0;
        resp_ready  = 1'b1;
    endtask

    // Tie off unused slave signals
    task tie_off_s();
        read_ready = 1'b1;
        resp_valid = 1'b0;
    endtask

    modport m (
        import tie_off_m,
        input  read_ready, resp_data, resp_error, resp_valid,
        output read_addr, read_valid, resp_ready
    );

    modport s (
        import tie_off_s,
        input  read_addr, read_valid, resp_ready,
        output read_ready, resp_data, resp_error, resp_valid
    );

`ifndef SYNTHESIS
    `STF_ASSERT_STABLE(read_addr, read_valid, read_ready);
    `STF_ASSERT_NOT_UNDEFINED(read_valid);
    `STF_ASSERT_NOT_UNDEFINED(read_ready);

    `STF_ASSERT_STABLE(resp_data, resp_valid, resp_ready);
    `STF_ASSERT_STABLE(resp_error, resp_valid, resp_ready);
    `STF_ASSERT_NOT_UNDEFINED(resp_valid);
    `STF_ASSERT_NOT_UNDEFINED(resp_ready);
`endif
endinterface

/**
 * Interface that bundles all stream configuration information.
 */
interface stream_config_i (
    input logic clk,
    input logic rst_n
);
    `READY_VALID_SIGNALS(select_t, select)
    `READY_VALID_SIGNALS(type_t,   data_type)

    modport m (
        output select_data, select_valid, data_type_data, data_type_valid,
        input select_ready, data_type_ready
    );

    modport s (
        output select_ready, data_type_ready,
        input select_data, select_valid, data_type_data, data_type_valid
    );

`ifndef SYNTHESIS
    `STF_ASSERT_STABLE(select_data, select_valid, select_ready);
    `STF_ASSERT_NOT_UNDEFINED(select_valid);
    `STF_ASSERT_NOT_UNDEFINED(select_ready);

    `STF_ASSERT_STABLE(data_type_data, data_type_valid, data_type_ready);
    `STF_ASSERT_NOT_UNDEFINED(data_type_valid);
    `STF_ASSERT_NOT_UNDEFINED(data_type_ready);
`endif
endinterface

/**
 * Interface that bundles all memory configuration information for the OutputWriter module.
 */
interface mem_config_i(
    input logic clk,
    input logic rst_n
);
    `READY_VALID_SIGNALS(buffer_t, buffer)

    logic flush_buffers;

    task tie_off_m();
        buffer_valid  = 1'b0;
        flush_buffers = 1'b0;
    endtask

    task tie_off_s();
        buffer_ready = 1'b1;
    endtask

    modport m (
        import tie_off_m,
        output buffer_data, buffer_valid, flush_buffers,
        input buffer_ready
    );

    modport s (
        import tie_off_s,
        output buffer_ready,
        input buffer_data, buffer_valid, flush_buffers
    );

`ifndef SYNTHESIS
    `STF_ASSERT_STABLE(buffer_data, buffer_valid, buffer_ready);
    `STF_ASSERT_NOT_UNDEFINED(buffer_valid);
    `STF_ASSERT_NOT_UNDEFINED(buffer_ready);

    `STF_ASSERT_NOT_UNDEFINED(flush_buffers);
`endif
endinterface
