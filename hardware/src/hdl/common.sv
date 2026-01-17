`timescale 1ns / 1ps

package libstf;

import lynxTypes::*;

// -- Constants ------------------------------------------------------------------------------------

// This value describes the maximum size in bytes of one memory transfer.
// Each transfer of this size will get a acknowledgement.
// The memory allocated for the output by the host should be a multiple of
// this size. Otherwise, the 'overhang' will go unused.
// The overwrite value is used on tests to trigger specific conditions.
// For the synthesis, the default value will be used.
`ifdef TRANSFER_SIZE_BYTES_OVERWRITE
    localparam integer TRANSFER_SIZE_BYTES = `TRANSFER_SIZE_BYTES_OVERWRITE;
`else
    // This value is used as it allowed peak performance in the perf_fpga example.
    // See: https://github.com/fpgasystems/Coyote/tree/tutorial/examples/07_perf_fpga
    //      (Section Expected results)
    localparam integer TRANSFER_SIZE_BYTES = 65536;
`endif

// The maximum size per host allocation that is supported by the design. (2**28 - 1 = 256 MiB - 1 byte)
// This limitation comes from the 32 bits we have available for interrupt values.
// See output_writer for more info.
localparam integer MAXIMUM_HOST_ALLOCATION_LEN_BIT    = 28;
localparam integer MAXIMUM_HOST_ALLOCATION_SIZE_BYTES = 2 ** MAXIMUM_HOST_ALLOCATION_LEN_BIT - 1;
localparam integer BUFFER_SIZE_BITS                   = 28 - $clog2(TRANSFER_SIZE_BYTES);

localparam MEM_CONFIG_ID    = 0;
localparam STREAM_CONFIG_ID = 1;

// -- Typedef --------------------------------------------------------------------------------------
typedef logic[7:0]  data8_t;
typedef logic[15:0] data16_t;
typedef logic[31:0] data32_t;
typedef logic[63:0] data64_t;

typedef enum logic[2:0] {
    BYTE_T,
    INT32_T,
    INT64_T,
    FLOAT_T,
    DOUBLE_T
} type_t;

// MemConfig
typedef logic[VADDR_BITS - 1:0]       vaddress_t; // Cannot be vaddr_t because of conflict with Coyote sim
typedef logic[BUFFER_SIZE_BITS - 1:0] buffer_size_t;

typedef struct packed {
    vaddress_t    vaddr;
    buffer_size_t size;
} buffer_t;

// StreamConfig
typedef data8_t select_t;

typedef struct packed {
    type_t   data_type;
    select_t select;
} stream_conf_t;

// Constant function to return the bit width of type_t types
function automatic int GET_TYPE_WIDTH(type_t data_type);
    case (data_type)
        BYTE_T: begin
            return 8;
        end
        INT32_T, FLOAT_T: begin
            return 32;
        end
        INT64_T, DOUBLE_T: begin
            return 64;
        end
        default: begin
            return 0;
        end
    endcase
endfunction

endpackage
