library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity ReadyShiftRegister is
    generic (
        WIDTH:  natural := 1;
        LEVELS: natural := 1
    );
    port (
        i_clk:   in std_logic;
        i_rst_n: in std_logic;

        i_data:  in  std_logic_vector(WIDTH - 1 downto 0);
        o_ready: out std_logic;

        o_data:  out std_logic_vector(WIDTH - 1 downto 0);
        i_ready: in  std_logic
    );
end ReadyShiftRegister;

architecture Behavioral of ReadyShiftRegister is

type shift_reg_t is array(LEVELS - 1 downto 0) of std_logic_vector(WIDTH - 1 downto 0);
signal s_shift_reg, s_next_shift_reg: shift_reg_t;

begin

process(i_clk) begin
	if rising_edge(i_clk) then
	    if i_rst_n = '0' then
	        for i in 0 to LEVELS - 1 loop
	            s_shift_reg(i) <= (others => '0');
	        end loop;
	    else
	        s_shift_reg <= s_next_shift_reg;
	    end if;
	end if;
end process;

process(i_data, i_ready, s_shift_reg, s_next_shift_reg) begin
    s_next_shift_reg <= s_shift_reg;

    if i_ready = '1' then
        s_next_shift_reg(LEVELS - 1) <= i_data;
        for i in 0 to LEVELS - 2 loop
            s_next_shift_reg(i) <= s_shift_reg(i + 1);
        end loop;
    end if;
end process;

o_ready <= i_ready;

o_data <= s_shift_reg(0);

end Behavioral;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity ShiftRegister is
    generic (
        WIDTH:  natural := 1;
        LEVELS: natural := 1
    );
    port (
        i_clk:   in std_logic;
        i_rst_n: in std_logic;

        i_data: in  std_logic_vector(WIDTH - 1 downto 0);
        o_data: out std_logic_vector(WIDTH - 1 downto 0)
    );
end ShiftRegister;

architecture Behavioral of ShiftRegister is begin

inst_shift_reg: entity work.ReadyShiftRegister generic map (
    WIDTH  => WIDTH,
    LEVELS => LEVELS
) port map (
   i_clk   => i_clk,
   i_rst_n => i_rst_n,

   i_data  => i_data,
   o_ready => open,

   o_data  => o_data,
   i_ready => '1'
);

end Behavioral;

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

entity ResetResync is
    generic (
        LEVELS: natural := 1
    );
    port (
        i_clk:   in std_logic;

        i_data: in  std_logic;
        o_data: out std_logic
    );
end ResetResync;

architecture Behavioral of ResetResync is begin

inst_shift_reg: entity work.ShiftRegister generic map (
    WIDTH  => 1,
    LEVELS => LEVELS
) port map (
   i_clk   => i_clk,
   i_rst_n => '1',

   i_data(0) => i_data,
   o_data(0) => o_data
);

end Behavioral;
