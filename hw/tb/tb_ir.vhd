-- =============================================================================
-- tb_ir : instruction register. Both halves load independently, reset clears
-- them, and the opcode / rd / rs fields decode correctly for all 256 values
-- of byte 0. Spec: 5.1.
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sprout8_pkg.all;
use work.tb_pkg.all;

entity tb_ir is
end entity tb_ir;

architecture sim of tb_ir is
  signal clk    : std_logic := '0';
  signal rst    : std_logic := '1';
  signal load0  : std_logic := '0';
  signal load1  : std_logic := '0';
  signal d      : byte_t := x"00";
  signal ir0    : byte_t;
  signal ir1    : byte_t;
  signal opcode : std_logic_vector(3 downto 0);
  signal rd, rs : regsel_t;
  signal done   : boolean := false;
  shared variable ck : checker_t;
begin
  clk <= not clk after CLK_PERIOD / 2 when not done;

  dut : entity work.ir
    port map (clk => clk, rst => rst, load0 => load0, load1 => load1, d => d,
              ir0 => ir0, ir1 => ir1, opcode => opcode, rd => rd, rs => rs);

  stim : process
    variable v : natural;
    procedure tick is begin wait until rising_edge(clk); wait for 1 ns; end procedure;
  begin
    rst <= '1'; load0 <= '1'; load1 <= '1'; d <= x"FF"; tick;
    check_eq(ck, ir0, x"00", "reset clears byte 0");
    check_eq(ck, ir1, x"00", "reset clears byte 1");
    rst <= '0'; load0 <= '0'; load1 <= '0';

    -- byte 0: every value, with field decode; byte 1 must not change
    load1 <= '1'; d <= x"5A"; tick; load1 <= '0';
    for i in 0 to 255 loop
      d <= std_logic_vector(to_unsigned(i, 8)); load0 <= '1'; tick;
      check_eq(ck, ir0, d, "byte 0 load");
      check_eq(ck, opcode, std_logic_vector(to_unsigned(i / 16, 4)), "opcode field of " & hex(d));
      check_eq(ck, rd, std_logic_vector(to_unsigned((i / 4) mod 4, 2)), "rd field of " & hex(d));
      check_eq(ck, rs, std_logic_vector(to_unsigned(i mod 4, 2)), "rs field of " & hex(d));
      check_eq(ck, ir1, x"5A", "byte 1 unchanged by load0");
    end loop;
    load0 <= '0';

    -- byte 1: every value; byte 0 must not change
    v := to_integer(unsigned(ir0));
    for i in 0 to 255 loop
      d <= std_logic_vector(to_unsigned(i, 8)); load1 <= '1'; tick;
      check_eq(ck, ir1, d, "byte 1 load");
      check_eq(ck, ir0, std_logic_vector(to_unsigned(v, 8)), "byte 0 unchanged by load1");
    end loop;
    load1 <= '0';

    -- hold
    d <= x"00"; tick; tick;
    check_eq(ck, ir1, x"FF", "hold when neither load is set");

    done <= true;
    end_test(ck, "tb_ir");
    wait;
  end process;
end architecture sim;
