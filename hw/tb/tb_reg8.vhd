-- =============================================================================
-- tb_reg8 : the generic 8-bit register used as the MAR. Checks the reset value
-- generic, load gating, every value, and hold. Two instances with different
-- RESET_VALUE generics are tested.
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sprout8_pkg.all;
use work.tb_pkg.all;

entity tb_reg8 is
end entity tb_reg8;

architecture sim of tb_reg8 is
  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal load : std_logic := '0';
  signal d    : byte_t := x"00";
  signal q0, q1 : byte_t;
  signal done : boolean := false;
  shared variable ck : checker_t;
begin
  clk <= not clk after CLK_PERIOD / 2 when not done;

  mar : entity work.reg8 generic map (RESET_VALUE => x"00")
    port map (clk => clk, rst => rst, load => load, d => d, q => q0);
  other : entity work.reg8 generic map (RESET_VALUE => x"A5")
    port map (clk => clk, rst => rst, load => load, d => d, q => q1);

  stim : process
    procedure tick is begin wait until rising_edge(clk); wait for 1 ns; end procedure;
  begin
    rst <= '1'; load <= '1'; d <= x"3C"; tick;
    check_eq(ck, q0, x"00", "MAR reset value");
    check_eq(ck, q1, x"A5", "RESET_VALUE generic honoured");
    rst <= '0'; load <= '0';

    for v in 0 to 255 loop
      d <= std_logic_vector(to_unsigned(v, 8)); load <= '1'; tick;
      check_eq(ck, q0, d, "load value");
      d <= not d; load <= '0'; tick;
      check_eq(ck, q0, std_logic_vector(to_unsigned(v, 8)), "hold when load = 0");
    end loop;

    done <= true;
    end_test(ck, "tb_reg8");
    wait;
  end process;
end architecture sim;
