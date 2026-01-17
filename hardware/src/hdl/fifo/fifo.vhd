library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity FIFO is
    generic (
        DEPTH: natural; --a power of two except 1
        WIDTH: natural;
        STYLE: string := "block"
    );
    port (
        i_clk:   in std_logic;
        i_rst_n: in std_logic;

        i_data:  in  std_logic_vector(WIDTH - 1 downto 0);
        i_valid: in  std_logic;
        i_ready: out std_logic;

        o_data:  out std_logic_vector(WIDTH - 1 downto 0);
        o_valid: out std_logic;
        o_ready: in  std_logic;

        o_filling_level: out std_logic_vector(natural(ceil(log2(real(DEPTH)))) downto 0)
    );
end FIFO;

architecture Behavioral of FIFO is

type memory_t is array (DEPTH - 1 downto 0) of std_logic_vector(WIDTH - 1 downto 0);

constant ADDRESS_WIDTH: natural := natural(ceil(log2(real(DEPTH))));

signal s_memory:   memory_t;
attribute ram_style : string;
attribute ram_style of s_memory : signal is STYLE;

signal s_write_en: std_logic;

signal s_write_ptr, s_next_write_ptr, s_write_ptr_succ:                       std_logic_vector(ADDRESS_WIDTH - 1 downto 0);
signal s_read_ptr,  s_state_read_ptr, s_next_state_read_ptr, s_read_ptr_succ: std_logic_vector(ADDRESS_WIDTH - 1 downto 0);

signal s_full, s_next_full, s_empty, s_next_empty: std_logic;
signal s_operation:                                std_logic_vector(1 downto 0);

-- for the case that when being empty, an element is written, it takes two cycles
-- till the read can perform so this is there to make sure it all goes smoothly
-- the s_write_after_empty = '1' during that one cycle that represents this
-- particular case (cycle after the write into an empty buffer).
signal s_write_after_empty, s_next_write_after_empty: std_logic;

signal s_filling_level, s_next_filling_level, s_filling_level_succ, s_filling_level_pred: std_logic_vector(natural(ceil(log2(real(DEPTH)))) downto 0);

begin

-- memory logic
s_write_en <= i_valid and (not s_full);

process (i_clk)
begin 
	if rising_edge(i_clk) then
		-- if i_rst_n = '0' then
			-- s_memory <= (others => (others => '0')); --not very suitable for M20Ks
		-- else 
			if (s_write_en = '1') then
				s_memory(to_integer(unsigned(s_write_ptr))) <= i_data;
			end if; 
			o_data <= s_memory(to_integer(unsigned(s_read_ptr)));
		-- end if; 
	end if; 
end process;  

-- next state registers
process (i_clk)
begin 
	if rising_edge(i_clk) then
		if i_rst_n = '0' then
			s_state_read_ptr <= (others => '0');
			s_write_ptr      <= (others => '0');
			s_empty          <= '1';
			s_full           <= '0';
			
			s_filling_level <= (others => '0');
		else 
			s_state_read_ptr <= s_next_state_read_ptr;
			s_write_ptr      <= s_next_write_ptr;
			s_empty          <= s_next_empty;
			s_full           <= s_next_full;

			s_filling_level <= s_next_filling_level;
		end if;

		s_write_after_empty <= s_next_write_after_empty;
	end if;
end process;

-- next state logic
s_write_ptr_succ     <= std_logic_vector(unsigned(s_write_ptr) + 1);
s_read_ptr_succ      <= std_logic_vector(unsigned(s_state_read_ptr) + 1);
s_filling_level_succ <= std_logic_vector(unsigned(s_filling_level) + 1);
s_filling_level_pred <= std_logic_vector(unsigned(s_filling_level) - 1);

s_operation <= i_valid & o_ready; -- someone want to write to fifo || someone is reading from fifo

process(s_write_ptr_succ, s_read_ptr_succ, s_operation, s_empty, s_full, s_read_ptr, s_write_ptr, s_write_after_empty, s_state_read_ptr, s_filling_level, s_filling_level_succ, s_filling_level_pred) begin
	s_next_write_ptr <= s_write_ptr;
	
	s_next_full  <= s_full;
	s_next_empty <= s_empty;
	
	s_next_write_after_empty <= '0';
	s_next_state_read_ptr    <= s_state_read_ptr;
	s_read_ptr               <= s_state_read_ptr;

	s_next_filling_level <= s_filling_level;

	case s_operation is
        when "00" =>
            --no one reading or trying to write, nothing should happen
        when "01" =>
            --someone is trying to read from the fifo
            if ((s_empty = '0') and (s_write_after_empty = '0')) then
                s_next_state_read_ptr <= s_read_ptr_succ;
                s_read_ptr            <= s_read_ptr_succ;
                s_next_full           <= '0';
                if (s_write_ptr = s_read_ptr_succ) then
                     s_next_empty <= '1';
                end if;
                s_next_filling_level <= s_filling_level_pred;
            end if;
        when "10" =>
            --someone is trying to write to the fifo
            if (s_full = '0') then
                s_next_write_ptr <= s_write_ptr_succ;
                if (s_empty = '1') then
                    s_next_write_after_empty <= '1';
                end if;
                s_next_empty <= '0';
                if s_filling_level = std_logic_vector(to_unsigned(DEPTH - 1, s_filling_level'length)) then
                    s_next_full <= '1';
                end if;
                s_next_filling_level <= s_filling_level_succ;
            end if;
        when "11" =>
            if (s_empty = '1') then
                s_next_write_ptr         <= s_write_ptr_succ;
                s_next_write_after_empty <= '1';
                s_next_empty             <= '0';
                s_next_filling_level     <= s_filling_level_succ;
            elsif (s_full = '1') then
                s_next_state_read_ptr <= s_read_ptr_succ;
                s_read_ptr            <= s_read_ptr_succ;
                s_next_full           <= '0';
                s_next_filling_level  <= s_filling_level_pred;
            else
                if (s_write_after_empty = '0') then
                    s_next_state_read_ptr <= s_read_ptr_succ;
                    s_read_ptr            <= s_read_ptr_succ;

                    --case where there is only 1 element in there and we do a read/write
                    if (s_read_ptr_succ = s_write_ptr) then
                        s_next_write_after_empty <= '1';
                    end if;
                else
                    s_next_filling_level <= s_filling_level_succ;
                end if;

                s_next_write_ptr <= s_write_ptr_succ;
            end if;
        when others =>
            -- Unknown states like 'x'
            null;
	end case; 
end process;

-- output signals
o_valid <= (not s_empty) and (not s_write_after_empty);

-- either we are not full, or we are but we are reading-writing
i_ready <= (not s_full) and i_rst_n;

o_filling_level <= s_filling_level;

end Behavioral;
