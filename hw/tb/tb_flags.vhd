-- =============================================================================
-- tb_flags : Z/C/N flags register. Reset, load gating, hold, all 8 patterns.
-- Spec: 3.2 (flags change only when an ALU instruction writes them), 3.3.
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sprout8_pkg.all;
use work.tb_pkg.all;

entity tb_flags is
end entity tb_flags;

architecture sim of tb_flags is
  signal clk  : std_logic := '0';
  signal rst  : std_logic := '1';
  signal load : std_logic := '0';
  signal zi, ci, ni : std_logic := '0';
  signal z, c, n    : std_logic;
  signal done : boolean := false;
  shared variable ck : checker_t;
begin
  clk <= not clk after CLK_PERIOD / 2 when not done;

  dut : entity work.flags
    port map (clk => clk, rst => rst, load => load, z_in => zi, c_in => ci, n_in => ni,
              z => z, c => c, n => n);

  stim : process
    variable p : std_logic_vector(2 downto 0);
    procedure tick is begin wait until rising_edge(clk); wait for 1 ns; end procedure;
  begin
    -- reset with inputs high: flags must still clear
    zi <= '1'; ci <= '1'; ni <= '1'; load <= '1'; rst <= '1'; tick;
    check_eq(ck, z & c & n, "000", "reset clears Z C N (and beats load)");
    rst <= '0'; load <= '0';

    -- every pattern loads, then holds while load = 0 and inputs change
    for i in 0 to 7 loop
      p := std_logic_vector(to_unsigned(i, 3));
      zi <= p(2); ci <= p(1); ni <= p(0); load <= '1'; tick;
      check_eq(ck, z & c & n, p, "load pattern " & integer'image(i));
      load <= '0'; zi <= not p(2); ci <= not p(1); ni <= not p(0); tick; tick;
      check_eq(ck, z & c & n, p, "hold pattern " & integer'image(i) & " while load = 0");
    end loop;

    -- the flag outputs must not change between clock edges
    zi <= '1'; ci <= '0'; ni <= '1'; load <= '1';
    wait until falling_edge(clk);
    check_eq(ck, z & c & n, "111", "no change before the edge (pattern 7 still held)");
    tick;
    check_eq(ck, z & c & n, "101", "change after the edge");

    done <= true;
    end_test(ck, "tb_flags");
    wait;
  end process;
end architecture sim;
