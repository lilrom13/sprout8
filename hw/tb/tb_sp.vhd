-- =============================================================================
-- tb_sp : stack pointer. Reset to 0xF0, decrement/increment, wrap in both
-- directions, hold, inc+dec together. Spec: 3.3, 4.2 rule 1, 6.4, C8.
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sprout8_pkg.all;
use work.tb_pkg.all;

entity tb_sp is
end entity tb_sp;

architecture sim of tb_sp is
  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal inc  : std_logic := '0';
  signal dec  : std_logic := '0';
  signal q    : byte_t;
  signal done : boolean := false;
  shared variable ck : checker_t;
begin
  clk <= not clk after CLK_PERIOD / 2 when not done;

  dut : entity work.sp port map (clk => clk, rst => rst, inc => inc, dec => dec, q => q);

  stim : process
    variable expect : natural;
    procedure tick is begin wait until rising_edge(clk); wait for 1 ns; end procedure;
  begin
    rst <= '1'; dec <= '1'; tick;
    check_eq(ck, q, x"F0", "reset value 0xF0 (reset beats dec)");
    rst <= '0'; dec <= '0';

    tick; tick;
    check_eq(ck, q, x"F0", "hold");

    -- first push target: 0xF0 - 1 = 0xEF (top of RAM)
    dec <= '1'; tick; dec <= '0';
    check_eq(ck, q, x"EF", "first decrement gives 0xEF");

    -- 256 decrements wrap through 0x00 -> 0xFF
    expect := 16#EF#;
    dec <= '1';
    for i in 1 to 256 loop
      tick;
      expect := (expect + 255) mod 256;
      check_eq(ck, q, std_logic_vector(to_unsigned(expect, 8)), "decrement " & integer'image(i));
    end loop;
    dec <= '0';

    -- back to reset, then 16 increments reach 0x00 (spec C8)
    rst <= '1'; tick; rst <= '0';
    inc <= '1';
    for i in 1 to 16 loop tick; end loop;
    inc <= '0';
    check_eq(ck, q, x"00", "0xF0 + 16 wraps to 0x00");
    dec <= '1'; tick; dec <= '0';
    check_eq(ck, q, x"FF", "0x00 - 1 wraps to 0xFF");

    -- inc and dec together: no change
    inc <= '1'; dec <= '1'; tick; tick;
    check_eq(ck, q, x"FF", "inc and dec together hold");
    inc <= '0'; dec <= '0';

    done <= true;
    end_test(ck, "tb_sp");
    wait;
  end process;
end architecture sim;
