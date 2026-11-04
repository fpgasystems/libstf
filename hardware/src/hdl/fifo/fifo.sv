`timescale 1ns / 1ps

// The old module name `FIFO` was clashing with another module in Coyote so the module was renamed
// to `MehdiFIFO` after Dr. Mehdi Moghaddamfar who implemented it originally.
module MehdiFIFO #(
    parameter int DEPTH, //a power of two except 1
    parameter int WIDTH,
    parameter STYLE = "block"
) (
    input logic i_clk,
    input logic i_rst_n,

    input  logic[WIDTH - 1:0] i_data,
    input  logic              i_valid,
    output logic              i_ready,

    output logic[WIDTH - 1:0] o_data,
    output logic              o_valid,
    input  logic              o_ready,

    output logic[$clog2(DEPTH):0] o_filling_level
);

localparam int ADDRESS_WIDTH = $clog2(DEPTH);

(* ram_style = STYLE *) logic[WIDTH - 1:0] s_memory[DEPTH - 1:0];

logic s_write_en;

logic[ADDRESS_WIDTH - 1:0] s_write_ptr, s_next_write_ptr, s_write_ptr_succ;
logic[ADDRESS_WIDTH - 1:0] s_read_ptr,  s_state_read_ptr, s_next_state_read_ptr, s_read_ptr_succ;

logic      s_full, s_next_full, s_empty, s_next_empty;
logic[1:0] s_operation;

// for the case that when being empty, an element is written, it takes two cycles
// till the read can perform so this is there to make sure it all goes smoothly
// the s_write_after_empty = '1' during that one cycle that represents this
// particular case (cycle after the write into an empty buffer).
logic s_write_after_empty, s_next_write_after_empty;

logic[$clog2(DEPTH):0] s_filling_level, s_next_filling_level, s_filling_level_succ, s_filling_level_pred;

// memory logic
assign s_write_en = i_valid & (~s_full);

always_ff @(posedge i_clk)
begin
	// if (i_rst_n == 1'b0) begin
		// s_memory <= '{default: '0}; //not very suitable for M20Ks
	// end else begin
		if (s_write_en == 1'b1) begin
			s_memory[s_write_ptr] <= i_data;
		end
		o_data <= s_memory[s_read_ptr];
	// end
end

// next state registers
always_ff @(posedge i_clk)
begin
	if (i_rst_n == 1'b0) begin
		s_state_read_ptr <= '0;
		s_write_ptr      <= '0;
		s_empty          <= 1'b1;
		s_full           <= 1'b0;

		s_filling_level <= '0;
	end else begin
		s_state_read_ptr <= s_next_state_read_ptr;
		s_write_ptr      <= s_next_write_ptr;
		s_empty          <= s_next_empty;
		s_full           <= s_next_full;

		s_filling_level <= s_next_filling_level;
	end

	s_write_after_empty <= s_next_write_after_empty;
end

// next state logic
assign s_write_ptr_succ     = s_write_ptr + 1'b1;
assign s_read_ptr_succ      = s_state_read_ptr + 1'b1;
assign s_filling_level_succ = s_filling_level + 1'b1;
assign s_filling_level_pred = s_filling_level - 1'b1;

assign s_operation = {i_valid, o_ready}; // someone want to write to fifo || someone is reading from fifo

always_comb begin
	s_next_write_ptr = s_write_ptr;

	s_next_full  = s_full;
	s_next_empty = s_empty;

	s_next_write_after_empty = 1'b0;
	s_next_state_read_ptr    = s_state_read_ptr;
	s_read_ptr               = s_state_read_ptr;

	s_next_filling_level = s_filling_level;

	case (s_operation)
        2'b00: begin
            //no one reading or trying to write, nothing should happen
        end
        2'b01: begin
            //someone is trying to read from the fifo
            if ((s_empty == 1'b0) && (s_write_after_empty == 1'b0)) begin
                s_next_state_read_ptr = s_read_ptr_succ;
                s_read_ptr            = s_read_ptr_succ;
                s_next_full           = 1'b0;
                if (s_write_ptr == s_read_ptr_succ) begin
                     s_next_empty = 1'b1;
                end
                s_next_filling_level = s_filling_level_pred;
            end
        end
        2'b10: begin
            //someone is trying to write to the fifo
            if (s_full == 1'b0) begin
                s_next_write_ptr = s_write_ptr_succ;
                if (s_empty == 1'b1) begin
                    s_next_write_after_empty = 1'b1;
                end
                s_next_empty = 1'b0;
                if (s_filling_level == ($clog2(DEPTH) + 1)'(DEPTH - 1)) begin
                    s_next_full = 1'b1;
                end
                s_next_filling_level = s_filling_level_succ;
            end
        end
        2'b11: begin
            if (s_empty == 1'b1) begin
                s_next_write_ptr         = s_write_ptr_succ;
                s_next_write_after_empty = 1'b1;
                s_next_empty             = 1'b0;
                s_next_filling_level     = s_filling_level_succ;
            end else if (s_full == 1'b1) begin
                s_next_state_read_ptr = s_read_ptr_succ;
                s_read_ptr            = s_read_ptr_succ;
                s_next_full           = 1'b0;
                s_next_filling_level  = s_filling_level_pred;
            end else begin
                if (s_write_after_empty == 1'b0) begin
                    s_next_state_read_ptr = s_read_ptr_succ;
                    s_read_ptr            = s_read_ptr_succ;

                    //case where there is only 1 element in there and we do a read/write
                    if (s_read_ptr_succ == s_write_ptr) begin
                        s_next_write_after_empty = 1'b1;
                    end
                end else begin
                    s_next_filling_level = s_filling_level_succ;
                end

                s_next_write_ptr = s_write_ptr_succ;
            end
        end
        default: begin
            // Unknown states like 'x'
        end
	endcase
end

// output signals
assign o_valid = (~s_empty) & (~s_write_after_empty);

// either we are not full, or we are but we are reading-writing
assign i_ready = (~s_full) & i_rst_n;

assign o_filling_level = s_filling_level;

endmodule
