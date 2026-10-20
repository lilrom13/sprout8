-- =============================================================================
-- tb_cpu : full CPU (cpu core + mem_io), the system-level testbench.
--
--  1. C1 reset state.
--  2. Appendix B programs B.1-B.3, with results and exact cycle counts.
--  3. Appendix C conformance tests C2-C16.
--  4. Halt quiescence: after HLT nothing is written, read or changed.
--  5. Random-program stress: random 240-byte memory images run in lockstep
--     with the golden model (sprout8_iss_pkg). PC, SP, A-D, Z/C/N, halted,
--     illegal and LEDS are compared after EVERY instruction, and all of RAM
--     after each run. The first divergence names the instruction.
--
-- Programs are written as hex strings in the same form as the ISA manual:
-- "1000 1405 7100" (two-byte instructions), "@20" sets the load address.
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;
use work.sprout8_pkg.all;
use work.sprout8_iss_pkg.all;
use work.tb_pkg.all;

entity tb_cpu is
  generic (
    N_RANDOM   : natural := 300;      -- random programs in the stress test
    RAND_SEED  : positive := 2026
  );
end entity tb_cpu;

architecture sim of tb_cpu is
  signal clk        : std_logic := '0';
  signal rst        : std_logic := '1';
  signal mem_rst    : std_logic := '1';   -- memory has its own reset so the
                                          -- testbench can load it while the CPU is held in reset
  signal done       : boolean := false;

  -- cpu <-> memory
  signal c_addr, c_wdata, m_rdata : byte_t;
  signal c_we, c_re               : std_logic;
  -- testbench backdoor on the same memory port (used while the CPU is in reset)
  signal tb_own                   : std_logic := '1';
  signal tb_addr, tb_wdata        : byte_t := x"00";
  signal tb_we                    : std_logic := '0';
  signal m_addr, m_wdata          : byte_t;
  signal m_we, m_re               : std_logic;

  signal halted, illegal          : std_logic;
  signal dbg_pc, dbg_sp           : byte_t;
  signal dbg_a, dbg_b, dbg_c, dbg_d, dbg_ir0 : byte_t;
  signal dbg_z, dbg_cf, dbg_n, dbg_retire     : std_logic;

  -- devices
  signal leds, switches           : byte_t := x"00";
  signal tty_out_data, tty_in_data : byte_t;
  signal tty_out_valid, tty_in_ack : std_logic;
  signal tty_in_valid             : std_logic;

  -- keyboard model: a queue of keys, one consumed per tty_in_ack
  signal kb_keys   : string(1 to 16) := (others => ' ');
  signal kb_len    : natural := 0;
  signal kb_idx    : natural := 1;
  signal kb_clear  : boolean := false;
  -- terminal capture
  signal tty_buf   : string(1 to 64) := (others => ' ');
  signal tty_len   : natural := 0;
  signal tty_clear : boolean := false;
  -- bus monitor for the halt-quiescence check
  signal bus_activity : natural := 0;

  shared variable ck : checker_t;
begin
  clk <= not clk after CLK_PERIOD / 2 when not done;

  -- ---------------- DUT ------------------------------------------------------
  u_cpu : entity work.cpu
    port map (clk => clk, rst => rst, mem_addr => c_addr, mem_wdata => c_wdata,
              mem_rdata => m_rdata, mem_we => c_we, mem_re => c_re,
              halted => halted, illegal => illegal,
              dbg_pc => dbg_pc, dbg_sp => dbg_sp, dbg_a => dbg_a, dbg_b => dbg_b,
              dbg_c => dbg_c, dbg_d => dbg_d, dbg_z => dbg_z, dbg_cf => dbg_cf,
              dbg_n => dbg_n, dbg_ir0 => dbg_ir0, dbg_retire => dbg_retire);

  m_addr  <= tb_addr  when tb_own = '1' else c_addr;
  m_wdata <= tb_wdata when tb_own = '1' else c_wdata;
  m_we    <= tb_we    when tb_own = '1' else c_we;
  m_re    <= '0'      when tb_own = '1' else c_re;

  u_mem : entity work.mem_io
    generic map (INIT_FILE => "")
    port map (clk => clk, rst => mem_rst, addr => m_addr, wdata => m_wdata, we => m_we,
              re => m_re, rdata => m_rdata, leds => leds, switches => switches,
              tty_out_data => tty_out_data, tty_out_valid => tty_out_valid,
              tty_in_data => tty_in_data, tty_in_valid => tty_in_valid,
              tty_in_ack => tty_in_ack);

  -- ---------------- keyboard and terminal models ----------------------------
  tty_in_valid <= '1' when kb_idx <= kb_len else '0';
  tty_in_data  <= std_logic_vector(to_unsigned(character'pos(kb_keys(kb_idx)), 8))
                  when kb_idx <= kb_len else x"00";

  keyboard : process (clk)
  begin
    if rising_edge(clk) then
      if kb_clear then
        kb_idx <= 1;
      elsif tty_in_ack = '1' then
        kb_idx <= kb_idx + 1;
      end if;
    end if;
  end process;

  tty_capture : process (clk)
  begin
    if rising_edge(clk) then
      if tty_clear then
        tty_len <= 0;
      elsif tty_out_valid = '1' and tty_len < tty_buf'length then
        tty_buf(tty_len + 1) <= character'val(to_integer(unsigned(tty_out_data)));
        tty_len <= tty_len + 1;
      end if;
    end if;
  end process;

  bus_mon : process (clk)
  begin
    if rising_edge(clk) then
      if c_we = '1' or c_re = '1' then
        bus_activity <= bus_activity + 1;
      end if;
    end if;
  end process;

  -- ---------------- test sequencer -------------------------------------------
  main : process
    variable iss     : iss_t;
    variable s1, s2  : positive := RAND_SEED;
    variable rnd     : real;
    variable cycles  : natural;
    variable n_instr : natural := 0;
    type hist_t is array (0 to 15) of natural;
    variable ophit   : hist_t := (others => 0);
    variable diverged : boolean;

    procedure tick is begin wait until rising_edge(clk); wait for 1 ns; end procedure;

    impure function rand(max : natural) return natural is
    begin
      uniform(s1, s2, rnd);
      return natural(floor(rnd * real(max + 1))) mod (max + 1);
    end function;

    function hexval(ch : character) return integer is
    begin
      case ch is
        when '0' to '9' => return character'pos(ch) - character'pos('0');
        when 'A' to 'F' => return character'pos(ch) - character'pos('A') + 10;
        when 'a' to 'f' => return character'pos(ch) - character'pos('a') + 10;
        when others     => return -1;
      end case;
    end function;

    -- write one byte through the backdoor and mirror it into the golden model
    procedure poke(a, v : natural) is
    begin
      tb_addr <= std_logic_vector(to_unsigned(a, 8));
      tb_wdata <= std_logic_vector(to_unsigned(v, 8));
      tb_we <= '1'; tick; tb_we <= '0';
      if a < 16#F0# then iss.mem(a) := v; end if;
    end procedure;

    -- put the CPU in reset, clear RAM, load a program string
    procedure load(prog : string) is
      variable a, hi, lo : integer := 0;
      variable i : integer;
    begin
      rst <= '1'; mem_rst <= '1'; tb_own <= '1'; kb_clear <= true; tty_clear <= true;
      tick; tick;
      mem_rst <= '0'; kb_clear <= false; tty_clear <= false;
      for x in 0 to 16#EF# loop poke(x, 0); end loop;
      i := prog'left;
      a := 0;
      while i <= prog'right loop
        if prog(i) = '@' then
          a := hexval(prog(i + 1)) * 16 + hexval(prog(i + 2));
          i := i + 3;
        elsif hexval(prog(i)) >= 0 then
          hi := hexval(prog(i)); lo := hexval(prog(i + 1));
          poke(a, hi * 16 + lo);
          a := (a + 1) mod 256;
          i := i + 2;
        else
          i := i + 1;
        end if;
      end loop;
      iss_reset(iss);
      iss.switches := to_integer(unsigned(switches));
    end procedure;

    -- compare the DUT's architectural state with the golden model
    procedure compare(tag : string) is
      function b(v : natural) return byte_t is
      begin
        return std_logic_vector(to_unsigned(v, 8));
      end function;
    begin
      if dbg_pc /= b(iss.pc) or dbg_sp /= b(iss.sp) or dbg_a /= b(iss.r(0)) or
         dbg_b /= b(iss.r(1)) or dbg_c /= b(iss.r(2)) or dbg_d /= b(iss.r(3)) or
         dbg_z /= iss.z or dbg_cf /= iss.c or dbg_n /= iss.n or
         (halted = '1') /= iss.halted or (illegal = '1') /= iss.illegal or
         leds /= b(iss.leds) then
        ck.fail(tag & ": state differs from golden model after instruction " & hex(b(iss.last_op)) &
                LF & "      DUT: PC=" & hex(dbg_pc) & " SP=" & hex(dbg_sp) & " A=" & hex(dbg_a) &
                " B=" & hex(dbg_b) & " C=" & hex(dbg_c) & " D=" & hex(dbg_d) &
                " ZCN=" & std_logic'image(dbg_z) & std_logic'image(dbg_cf) & std_logic'image(dbg_n) &
                " halted=" & std_logic'image(halted) & " LEDS=" & hex(leds) &
                LF & "      ISS: PC=" & hex(b(iss.pc)) & " SP=" & hex(b(iss.sp)) & " A=" & hex(b(iss.r(0))) &
                " B=" & hex(b(iss.r(1))) & " C=" & hex(b(iss.r(2))) & " D=" & hex(b(iss.r(3))) &
                " ZCN=" & std_logic'image(iss.z) & std_logic'image(iss.c) & std_logic'image(iss.n) &
                " halted=" & boolean'image(iss.halted) & " LEDS=" & hex(b(iss.leds)));
        diverged := true;
      else
        ck.pass;
      end if;
    end procedure;

    -- release reset and run until halted or max_cycles; optionally in lockstep
    procedure run(max_cycles : natural; lockstep : boolean; tag : string) is
      variable retired, was_halted : boolean;
    begin
      tb_own <= '0'; rst <= '0';
      cycles := 0;
      diverged := false;
      wait for 1 ns;
      while cycles < max_cycles and halted = '0' loop
        wait until rising_edge(clk);
        retired    := dbg_retire = '1';           -- values just before the edge
        was_halted := halted = '1';
        wait for 1 ns;
        if not was_halted then cycles := cycles + 1; end if;
        if retired then
          n_instr := n_instr + 1;
          ophit(to_integer(unsigned(dbg_ir0(7 downto 4)))) := ophit(to_integer(unsigned(dbg_ir0(7 downto 4)))) + 1;
          if lockstep and not diverged then
            iss_step(iss);
            compare(tag);
          end if;
        end if;
      end loop;
    end procedure;

    -- after a run: read back all RAM through the backdoor and compare with the model
    procedure compare_ram(tag : string) is
      variable bad : natural := 0;
    begin
      tb_own <= '1';
      for a in 0 to 16#EF# loop
        tb_addr <= std_logic_vector(to_unsigned(a, 8));
        wait for 1 ns;
        if m_rdata /= std_logic_vector(to_unsigned(iss.mem(a), 8)) then
          bad := bad + 1;
          if bad <= 3 then
            ck.fail(tag & ": RAM[" & hex(tb_addr) & "] = " & hex(m_rdata) & ", golden model has " &
                    hex(std_logic_vector(to_unsigned(iss.mem(a), 8))));
          end if;
        end if;
      end loop;
      if bad = 0 then ck.pass; end if;
    end procedure;

    procedure expect_reg(got : byte_t; exp : byte_t; msg : string) is
    begin
      check_eq(ck, got, exp, msg);
    end procedure;

    variable act0 : natural;
  begin
    -- ======================= C1: reset state ===================================
    load("0100");
    expect_reg(dbg_pc, x"00", "C1 PC"); expect_reg(dbg_sp, x"F0", "C1 SP");
    expect_reg(dbg_a, x"00", "C1 A");   expect_reg(dbg_b, x"00", "C1 B");
    expect_reg(dbg_c, x"00", "C1 C");   expect_reg(dbg_d, x"00", "C1 D");
    check_eq(ck, dbg_z & dbg_cf & dbg_n, "000", "C1 flags");
    check_eq(ck, halted, '0', "C1 not halted");

    -- ======================= Appendix B programs ===============================
    -- B.1 sum to LEDs
    load("1000 1405 7100 D500 E804 30F0 0100");
    run(1000, true, "B.1");
    check_eq(ck, leds, x"0F", "B.1 LEDS");
    check_eq(ck, cycles, 96, "B.1 cycle count");
    compare_ram("B.1");

    -- B.2 print a string with a pointer and a subroutine
    load("1C20 1400 4300 C100 E410 F212 DC00 E004 0100 30F2 0200 @20 48492100");
    run(1000, true, "B.2");
    check_eq(ck, tty_buf(1 to tty_len), "HI!", "B.2 terminal output");
    check_eq(ck, cycles, 172, "B.2 cycle count");
    expect_reg(dbg_sp, x"F0", "B.2 SP back at 0xF0");
    compare_ram("B.2");

    -- B.3 echo the keyboard (never halts; no lockstep because keys are external)
    load("1401 20F3 9100 E402 20F4 30F2 E002");
    kb_keys(1 to 3) <= "ok!"; kb_len <= 3;
    run(600, false, "B.3");
    check_eq(ck, tty_buf(1 to tty_len), "ok!", "B.3 echoed text");
    check_eq(ck, kb_idx, 4, "B.3 every key consumed exactly once");
    check_eq(ck, halted, '0', "B.3 keeps running");
    kb_len <= 0;

    -- ======================= Appendix C conformance ============================
    load("10FF 1401 7100 0100");                                   -- C2
    run(200, true, "C2");
    expect_reg(dbg_a, x"00", "C2 A"); check_eq(ck, dbg_z & dbg_cf & dbg_n, "110", "C2 ZCN");

    load("1003 1405 C100 0100");                                   -- C3
    run(200, true, "C3");
    expect_reg(dbg_a, x"03", "C3 A unchanged"); check_eq(ck, dbg_z & dbg_cf & dbg_n, "011", "C3 ZCN");

    load("10FF 1401 7100 A100 0100");                              -- C4
    run(200, true, "C4");
    expect_reg(dbg_a, x"01", "C4 A"); check_eq(ck, dbg_z & dbg_cf & dbg_n, "000", "C4 ZCN");

    load("1081 D300 0100");                                        -- C5
    run(200, true, "C5");
    expect_reg(dbg_a, x"40", "C5 A"); check_eq(ck, dbg_z & dbg_cf & dbg_n, "010", "C5 ZCN");

    load("10FF 1401 7100 1007 6400 3080 0100");                    -- C6
    run(200, true, "C6");
    check_eq(ck, dbg_z & dbg_cf, "11", "C6 flags preserved by LDI/MOV/ST");

    load("E0FE");                                                  -- C7
    run(10, true, "C7");
    expect_reg(dbg_pc, x"00", "C7 PC wraps through 0xFE/0xFF to 0x00");

    load("F100F100F100F100F100F100F100F100F100F100F100F100F100F100F100F100 F000 0100");  -- C8
    run(400, true, "C8");
    expect_reg(dbg_sp, x"FF", "C8 SP after 16 pops and a push");

    load("1001 1402 F000 F400 F100 F500 0100");                    -- C9
    run(200, true, "C9");
    expect_reg(dbg_a, x"02", "C9 A"); expect_reg(dbg_b, x"01", "C9 B");
    expect_reg(dbg_sp, x"F0", "C9 SP");

    load("E010 @10 F214 0100 0200");                               -- C10
    run(200, true, "C10");
    compare_ram("C10");
    tb_own <= '1'; tb_addr <= x"EF"; wait for 1 ns;
    check_eq(ck, m_rdata, x"12", "C10 return address on the stack");
    expect_reg(dbg_sp, x"F0", "C10 SP");

    load("1040 4000 0100 @40 99");                                 -- C11
    run(200, true, "C11");
    expect_reg(dbg_a, x"99", "C11 LDR A,[A]");

    load("132A 0100");                                             -- C12
    run(200, true, "C12");
    expect_reg(dbg_a, x"2A", "C12 SBZ field ignored");

    load("1005 FF00 1007");                                        -- C13
    run(200, true, "C13");
    check_eq(ck, halted, '1', "C13 halted"); check_eq(ck, illegal, '1', "C13 illegal flagged");
    expect_reg(dbg_a, x"05", "C13 A unchanged"); expect_reg(dbg_pc, x"04", "C13 PC");
    compare_ram("C13");

    load("1077 30F5 24F5 0100");                                   -- C14
    run(200, true, "C14");
    expect_reg(dbg_b, x"00", "C14 reserved port reads 0x00");
    compare_ram("C14");

    load("105A 30F0 24F0 0100");                                   -- C15
    run(200, true, "C15");
    expect_reg(dbg_b, x"5A", "C15 LEDS readback");

    load("20F4 24F4 0100");                                        -- C16
    kb_keys(1) <= 'k'; kb_len <= 1;
    run(200, false, "C16");
    expect_reg(dbg_a, x"6B", "C16 first TTY_IN read returns the key");
    expect_reg(dbg_b, x"00", "C16 second read returns 0x00");
    kb_len <= 0;

    -- ======================= halt quiescence ====================================
    load("1033 3020 0100");
    run(200, true, "halt");
    act0 := bus_activity;
    for k in 1 to 20 loop tick; end loop;
    check_eq(ck, bus_activity, act0, "no memory reads or writes while halted");
    expect_reg(dbg_pc, x"06", "PC frozen while halted");
    expect_reg(dbg_a, x"33", "registers frozen while halted");

    -- ======================= random lockstep stress ============================
    for p in 1 to N_RANDOM loop
      switches <= std_logic_vector(to_unsigned(rand(255), 8));
      rst <= '1'; mem_rst <= '1'; tb_own <= '1'; tick; tick; mem_rst <= '0';
      for x in 0 to 16#EF# loop poke(x, rand(255)); end loop;
      iss_reset(iss);
      iss.switches := to_integer(unsigned(switches));
      run(4000, true, "random program " & integer'image(p));
      if not diverged then compare_ram("random program " & integer'image(p)); end if;
    end loop;

    -- opcode coverage over everything executed above
    report "retired " & integer'image(n_instr) & " instructions in total";
    for o in 0 to 15 loop
      check(ck, ophit(o) > 0, "opcode " & integer'image(o) & " was never executed");
    end loop;

    done <= true;
    end_test(ck, "tb_cpu");
    wait;
  end process;

end architecture sim;
