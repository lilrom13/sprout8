-- =============================================================================
-- tb_pc : program counter. Reset to 0x00, increment, full 256-step wrap,
-- load, load-over-increment priority, hold. Spec: 3.3, 4.2 rule 1.
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sprout8_pkg.all;
use work.tb_pkg.all;

entity tb_pc is
end entity tb_pc;

architecture sim of tb_pc is
  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal inc  : std_logic := '0';
  signal load : std_logic := '0';
  signal d, q : byte_t := x"00";
  signal done : boolean := false;
  shared variable ck : checker_t;
begin
  clk <= not clk after CLK_PERIOD / 2 when not done;

  dut : entity work.pc port map (clk => clk, rst => rst, inc => inc, load => load, d => d, q => q);

  stim : process
    procedure tick is begin wait until rising_edge(clk); wait for 1 ns; end procedure;
  begin
    rst <= '1'; inc <= '1'; load <= '1'; d <= x"AA"; tick;
    check_eq(ck, q, RESET_PC, "reset value (reset beats load and inc)");
    rst <= '0'; load <= '0'; inc <= '0';

    tick; tick;
    check_eq(ck, q, x"00", "hold when inc = load = 0");

    -- 256 increments: visits every value and wraps 0xFF -> 0x00
    inc <= '1';
    for i in 1 to 256 loop
      tick;
      check_eq(ck, q, std_logic_vector(to_unsigned(i mod 256, 8)), "increment " & integer'image(i));
    end loop;
    inc <= '0';

    -- load any value
    for v in 0 to 255 loop
      load <= '1'; d <= std_logic_vector(to_unsigned(v, 8)); tick;
      check_eq(ck, q, d, "load");
    end loop;

    -- load has priority over increment
    load <= '1'; inc <= '1'; d <= x"40"; tick;
    check_eq(ck, q, x"40", "load beats inc");
    load <= '0';
    tick;
    check_eq(ck, q, x"41", "inc after load");

    -- wrap from an explicitly loaded 0xFF (spec C7)
    load <= '1'; inc <= '0'; d <= x"FF"; tick; load <= '0'; inc <= '1'; tick;
    check_eq(ck, q, x"00", "0xFF + 1 wraps to 0x00");
    inc <= '0';

    done <= true;
    end_test(ck, "tb_pc");
    wait;
  end process;
end architecture sim;
