-- =============================================================================
-- tb_regfile : register file A-D.
-- Covers reset values, every write/read port combination, write-enable gating,
-- read-during-write timing, reset priority, and a long random sequence checked
-- against a model. Spec: 3.1, 3.3.
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.sprout8_pkg.all;
use work.tb_pkg.all;

entity tb_regfile is
end entity tb_regfile;

architecture sim of tb_regfile is
  signal clk      : std_logic := '0';
  signal rst      : std_logic := '1';
  signal we       : std_logic := '0';
  signal waddr    : regsel_t := "00";
  signal wdata    : byte_t := x"00";
  signal raddr_a  : regsel_t := "00";
  signal raddr_b  : regsel_t := "00";
  signal rdata_a  : byte_t;
  signal rdata_b  : byte_t;
  signal contents : regs_t;
  signal done     : boolean := false;
  shared variable ck : checker_t;

  function sel(i : natural) return regsel_t is
  begin
    return std_logic_vector(to_unsigned(i, 2));
  end function;
  type names_t is array (0 to 3) of character;
  constant RN : names_t := ('A', 'B', 'C', 'D');
begin

  clk <= not clk after CLK_PERIOD / 2 when not done;

  dut : entity work.regfile
    port map (clk => clk, rst => rst, we => we, waddr => waddr, wdata => wdata,
              raddr_a => raddr_a, raddr_b => raddr_b, rdata_a => rdata_a,
              rdata_b => rdata_b, contents => contents);

  stim : process
    variable model : regs_t := (others => x"00");
    variable s1, s2 : positive := 7;
    variable rnd   : real;
    variable wi, ai, bi : natural;
    variable wv    : byte_t;

    impure function rand(max : natural) return natural is
    begin
      uniform(s1, s2, rnd);
      return natural(floor(rnd * real(max + 1))) mod (max + 1);
    end function;

    procedure tick is
    begin
      wait until rising_edge(clk);
      wait for 1 ns;
    end procedure;
  begin
    -- reset
    rst <= '1'; tick; tick;
    rst <= '0';
    for i in 0 to 3 loop
      raddr_a <= sel(i); raddr_b <= sel(i); wait for 1 ns;
      check_eq(ck, rdata_a, x"00", "reset value port A, reg " & RN(i));
      check_eq(ck, rdata_b, x"00", "reset value port B, reg " & RN(i));
    end loop;

    -- each register gets a distinct value; both ports read every register
    for i in 0 to 3 loop
      we <= '1'; waddr <= sel(i); wdata <= std_logic_vector(to_unsigned(16#11# * (i + 1), 8)); tick;
    end loop;
    we <= '0';
    for i in 0 to 3 loop
      for j in 0 to 3 loop
        raddr_a <= sel(i); raddr_b <= sel(j); wait for 1 ns;
        check_eq(ck, rdata_a, std_logic_vector(to_unsigned(16#11# * (i + 1), 8)), "port A reads " & RN(i));
        check_eq(ck, rdata_b, std_logic_vector(to_unsigned(16#11# * (j + 1), 8)), "port B reads " & RN(j));
      end loop;
      check_eq(ck, contents(i), std_logic_vector(to_unsigned(16#11# * (i + 1), 8)), "contents output " & RN(i));
    end loop;

    -- write enable low: nothing changes
    we <= '0'; waddr <= "10"; wdata <= x"EE"; tick;
    raddr_a <= "10"; wait for 1 ns;
    check_eq(ck, rdata_a, x"33", "we=0 must not write");

    -- a write changes only its own register
    we <= '1'; waddr <= "01"; wdata <= x"5A"; tick; we <= '0';
    check_eq(ck, contents(0), x"11", "write B leaves A");
    check_eq(ck, contents(1), x"5A", "write B");
    check_eq(ck, contents(2), x"33", "write B leaves C");
    check_eq(ck, contents(3), x"44", "write B leaves D");

    -- read-during-write: before the edge the old value is read, after it the new one
    raddr_a <= "11"; we <= '1'; waddr <= "11"; wdata <= x"C3";
    wait until falling_edge(clk);
    check_eq(ck, rdata_a, x"44", "read during write returns old value before the edge");
    wait until rising_edge(clk); wait for 1 ns;
    check_eq(ck, rdata_a, x"C3", "new value visible after the edge");
    we <= '0';

    -- reset has priority over a write in the same cycle
    rst <= '1'; we <= '1'; waddr <= "00"; wdata <= x"99"; tick;
    rst <= '0'; we <= '0';
    for i in 0 to 3 loop
      check_eq(ck, contents(i), x"00", "reset beats write, reg " & RN(i));
    end loop;

    -- random sequence against a model (2,000 cycles)
    model := (others => x"00");
    for k in 1 to 2000 loop
      wi := rand(3); ai := rand(3); bi := rand(3);
      wv := std_logic_vector(to_unsigned(rand(255), 8));
      if rand(1) = 1 then
        we <= '1'; model(wi) := wv;
      else
        we <= '0';
      end if;
      waddr <= sel(wi); wdata <= wv; raddr_a <= sel(ai); raddr_b <= sel(bi);
      tick;
      check_eq(ck, rdata_a, model(ai), "random step " & integer'image(k) & " port A");
      check_eq(ck, rdata_b, model(bi), "random step " & integer'image(k) & " port B");
    end loop;
    we <= '0';

    done <= true;
    end_test(ck, "tb_regfile");
    wait;
  end process;

end architecture sim;
