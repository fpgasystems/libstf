library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

-- FIFO that reduces an input to smaller chunks as output
entity MultiInsertFIFO is
    generic (
        DEPTH:               natural; --a power of two except 1
        WIDTH:               natural;
        FACTOR:              natural;
        RESET_RESYNC_LEVELS: natural := 2
    );
    port (
        i_clk:   in std_logic;
        i_rst_n: in std_logic;

        i_data:  in  std_logic_vector(FACTOR * WIDTH - 1 downto 0);
        i_valid: in  std_logic;
        o_ready: out std_logic;

        o_data:  out std_logic_vector(WIDTH - 1 downto 0);
        o_valid: out std_logic;
        i_ready: in  std_logic;

        o_filling_level: out std_logic_vector(natural(ceil(log2(real(DEPTH)))) downto 0)
    );
end MultiInsertFIFO;

architecture Behavioral of MultiInsertFIFO is

constant SWITCH_WIDTH: natural := natural(ceil(log2(real(FACTOR))));

signal s_switch, s_next_switch: unsigned(SWITCH_WIDTH - 1 downto 0);

signal s_data: std_logic_vector(FACTOR * WIDTH - 1 downto 0);
signal s_valid, s_ready: std_logic;

begin

inst_fifo: entity work.FIFO generic map (
	DEPTH               => DEPTH,
	WIDTH               => FACTOR * WIDTH,
	RESET_RESYNC_LEVELS => RESET_RESYNC_LEVELS
) port map (
	i_clk   => i_clk,
	i_rst_n => i_rst_n,

	i_data  => i_data,
    i_valid => i_valid,
    o_ready => o_ready,

    o_data  => s_data,
    o_valid => s_valid,
    i_ready => s_ready,

    o_filling_level => o_filling_level
);

process (i_clk) begin
	if rising_edge(i_clk) then
		if i_rst_n = '0' then
		    s_switch <= (others => '0');
		else
			s_switch <= s_next_switch;
		end if;
	end if;
end process;

process (i_data, i_valid, i_ready, s_switch, s_next_switch, s_data, s_valid, s_ready) begin
    s_next_switch <= s_switch;

	if i_ready = '1' and s_valid = '1' then
		s_next_switch <= s_switch + 1;
	end if;
end process;

s_ready <= '1' when i_ready = '1' and s_switch = (s_switch'range => '1') else '0';

o_data  <= s_data((to_integer(s_switch) + 1) * WIDTH - 1 downto to_integer(s_switch) * WIDTH);
o_valid <= s_valid;

end Behavioral;
