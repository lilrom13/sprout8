-- =============================================================================
-- tb_control : control unit (step counter + decoder).
--
-- For all 256 values of byte 0, under all four Z/C flag combinations, the
-- bench runs one instruction and compares the control word at every step with
-- an expected micro-operation table written directly from spec section 7.2.
-- It also checks:
--   * fetch steps T0-T3 do not depend on the opcode (IR0 holds junk there)
--   * the cycle count of every instruction (spec 7.2, Appendix B)
--   * the step output counts 0,1,2,... and returns to 0 after the last step
--   * HLT and the reserved encodings halt; nothing is driven while halted;
--     only reset leaves the halted state; illegal is flagged (spec 5.4)
-- and reports opcode x step coverage.
--
-- Control words are rendered as text, e.g. "b:MEM ir0 memr pc+", so a
-- mismatch prints the expected and actual micro-ops side by side.
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.sprout8_pkg.all;
use work.tb_pkg.all;

entity tb_control is
end entity tb_control;

architecture sim of tb_control is
  signal clk     : std_logic := '0';
  signal rst     : std_logic := '1';
  signal ir0     : byte_t := x"00";
  signal z, c    : std_logic := '0';
  signal ctrl    : ctrl_t;
  signal step    : unsigned(2 downto 0);
  signal halted  : std_logic;
  signal illegal : std_logic;
  signal done    : boolean := false;
  shared variable ck : checker_t;

  -- ---------------- rendering a control word as text -----------------------
  function src_name(s : bus_src_t) return string is
  begin
    case s is
      when BUS_NONE => return "-";
      when BUS_PC   => return "PC";
      when BUS_SP   => return "SP";
      when BUS_IR1  => return "IR1";
      when BUS_MEM  => return "MEM";
      when BUS_RD   => return "RD";
      when BUS_RS   => return "RS";
      when BUS_ALU  => return "ALU";
    end case;
  end function;

  function alu_name(o : aluop_t) return string is
  begin
    case o is
      when ALU_ADD => return "ADD";
      when ALU_SUB => return "SUB";
      when ALU_AND => return "AND";
      when ALU_OR  => return "OR";
      when ALU_XOR => return "XOR";
      when ALU_SHL => return "SHL";
      when ALU_SHR => return "SHR";
      when others  => return "PASB";
    end case;
  end function;

  function tok(b : std_logic; s : string) return string is
  begin
    if b = '1' then return " " & s; else return ""; end if;
  end function;

  -- canonical order: b:<src> mar ir0 ir1 reg pcl memw memr pc+ sp+ sp- fl alu:<op> one end
  function render(w : ctrl_t) return string is
  begin
    if w.flags_load = '1' or w.bus_src = BUS_ALU then
      return "b:" & src_name(w.bus_src) & tok(w.mar_load, "mar") & tok(w.ir0_load, "ir0") &
             tok(w.ir1_load, "ir1") & tok(w.reg_we, "reg") & tok(w.pc_load, "pcl") &
             tok(w.mem_write, "memw") & tok(w.mem_read, "memr") & tok(w.pc_inc, "pc+") &
             tok(w.sp_inc, "sp+") & tok(w.sp_dec, "sp-") & tok(w.flags_load, "fl") &
             " alu:" & alu_name(w.alu_op) & tok(w.alu_b_one, "one") & tok(w.step_reset, "end");
    else
      return "b:" & src_name(w.bus_src) & tok(w.mar_load, "mar") & tok(w.ir0_load, "ir0") &
             tok(w.ir1_load, "ir1") & tok(w.reg_we, "reg") & tok(w.pc_load, "pcl") &
             tok(w.mem_write, "memw") & tok(w.mem_read, "memr") & tok(w.pc_inc, "pc+") &
             tok(w.sp_inc, "sp+") & tok(w.sp_dec, "sp-") & tok(w.flags_load, "fl") &
             tok(w.alu_b_one, "one") & tok(w.step_reset, "end");
    end if;
  end function;

  -- ---------------- expected micro-operations, from spec 7.2 ---------------
  constant FETCH : string := "b:PC mar|b:MEM ir0 memr pc+|b:PC mar|b:MEM ir1 memr pc+";

  function alu3(op : string) return string is
  begin
    return "b:ALU reg fl alu:" & op & " end";
  end function;

  function expected_exec(b0 : natural; zf, cf : std_logic) return string is
    constant op : natural := b0 / 16;
    constant rd : natural := (b0 / 4) mod 4;
    constant rs : natural := b0 mod 4;
  begin
    case op is
      when 16#0# =>
        case rs is
          when 0 => return "b:- end";                                  -- NOP
          when 1 => return "b:- end";                                  -- HLT
          when 2 => return "b:SP mar|b:MEM pcl memr|b:- sp+ end";      -- RET
          when others => return "b:- end";                             -- reserved
        end case;
      when 16#1# => return "b:IR1 reg end";                            -- LDI
      when 16#2# => return "b:IR1 mar|b:MEM reg memr end";             -- LD
      when 16#3# => return "b:IR1 mar|b:RD memw end";                  -- ST
      when 16#4# => return "b:RS mar|b:MEM reg memr end";              -- LDR
      when 16#5# => return "b:RS mar|b:RD memw end";                   -- STR
      when 16#6# => return "b:RS reg end";                             -- MOV
      when 16#7# => return alu3("ADD");
      when 16#8# => return alu3("SUB");
      when 16#9# => return alu3("AND");
      when 16#A# => return alu3("OR");
      when 16#B# => return alu3("XOR");
      when 16#C# => return "b:- fl alu:SUB end";                       -- CMP
      when 16#D# =>
        case rs is
          when 0 => return "b:ALU reg fl alu:ADD one end";             -- INC
          when 1 => return "b:ALU reg fl alu:SUB one end";             -- DEC
          when 2 => return alu3("SHL");
          when others => return alu3("SHR");
        end case;
      when 16#E# =>                                                    -- jumps
        if rd = 0 or (rd = 1 and zf = '1') or (rd = 2 and zf = '0') or (rd = 3 and cf = '1') then
          return "b:IR1 pcl end";
        else
          return "b:- end";
        end if;
      when others =>                                                   -- stack group
        case rs is
          when 0 => return "b:- sp-|b:SP mar|b:RD memw end";           -- PUSH
          when 1 => return "b:SP mar|b:MEM reg memr|b:- sp+ end";      -- POP
          when 2 => return "b:- sp-|b:SP mar|b:PC memw|b:IR1 pcl end"; -- CALL
          when others => return "b:- end";                             -- reserved
        end case;
    end case;
  end function;

  function count_steps(s : string) return natural is
    variable n : natural := 1;
  begin
    for i in s'range loop
      if s(i) = '|' then n := n + 1; end if;
    end loop;
    return n;
  end function;

  function expected_cycles(b0 : natural; zf, cf : std_logic) return natural is
  begin
    return 4 + count_steps(expected_exec(b0, zf, cf));
  end function;

  -- HLT is 0x01, 0x05, 0x09, 0x0D (rd field is SBZ and ignored)
  function is_hlt(b0 : natural) return boolean is
  begin
    return b0 < 16#10# and b0 mod 4 = 1;
  end function;

  -- reserved encodings (spec 5.3): system rs = 11 and stack rs = 11
  function is_illegal(b0 : natural) return boolean is
  begin
    return (b0 < 16#10# or b0 >= 16#F0#) and b0 mod 4 = 3;
  end function;

  function to_sl(b : boolean) return std_logic is
  begin
    if b then return '1'; else return '0'; end if;
  end function;

  type cov_t is array (0 to 15, 0 to 7) of natural;
begin
  clk <= not clk after CLK_PERIOD / 2 when not done;

  dut : entity work.control
    port map (clk => clk, rst => rst, ir0 => ir0, z => z, c => c, ctrl => ctrl,
              step => step, halted => halted, illegal => illegal);

  stim : process
    variable cov      : cov_t := (others => (others => 0));
    variable n_cov    : natural := 0;
    variable cycles   : natural;
    variable got_all  : boolean;
    variable fl       : std_logic_vector(1 downto 0);
    variable b0v      : byte_t;
    variable exp_full : line;
    variable got_full : line;
    variable halt_exp : boolean;
    variable frozen   : unsigned(2 downto 0);

    procedure tick is begin wait until rising_edge(clk); wait for 1 ns; end procedure;

    procedure append(variable l : inout line; s : string) is
      variable old : line;
    begin
      if l = null then
        l := new string'(s);
      else
        old := l;
        l := new string'(old.all & "|" & s);
        deallocate(old);
      end if;
    end procedure;
  begin
    for b0 in 0 to 255 loop
      for f in 0 to 3 loop
        fl  := std_logic_vector(to_unsigned(f, 2));
        b0v := std_logic_vector(to_unsigned(b0, 8));
        z <= fl(1); c <= fl(0);

        -- reset, with junk in IR0 so the fetch steps cannot depend on it
        rst <= '1'; ir0 <= not b0v; tick; rst <= '0';
        deallocate(got_full);
        cycles  := 0;
        got_all := false;

        for k in 0 to 9 loop
          if k = 2 then ir0 <= b0v; wait for 1 ns; end if;   -- IR0 is loaded at the end of T1
          check(ck, to_integer(step) = k,
                "step output at cycle " & integer'image(k) & " of " & hex(b0v));
          append(got_full, render(ctrl));
          cov(b0 / 16, k mod 8) := cov(b0 / 16, k mod 8) + 1;
          cycles := cycles + 1;
          if ctrl.step_reset = '1' then
            got_all := true;
            tick;
            exit;
          end if;
          tick;
        end loop;

        deallocate(exp_full);
        exp_full := new string'(FETCH & "|" & expected_exec(b0, fl(1), fl(0)));
        check(ck, got_all, "instruction " & hex(b0v) & " never reached its last step");
        check_eq(ck, got_full.all, exp_full.all,
                 "micro-ops of byte0 " & hex(b0v) & " with Z,C = " & std_logic'image(fl(1)) & std_logic'image(fl(0)));
        check(ck, cycles = expected_cycles(b0, fl(1), fl(0)),
              "cycle count of " & hex(b0v) & ": got " & integer'image(cycles) &
              ", expected " & integer'image(expected_cycles(b0, fl(1), fl(0))));

        halt_exp := is_hlt(b0) or is_illegal(b0);
        check_eq(ck, illegal, to_sl(is_illegal(b0)), "illegal flag after " & hex(b0v));
        if halt_exp then
          check_eq(ck, halted, '1', "halted after " & hex(b0v));
          -- while halted: nothing is driven and the step counter is frozen
          frozen := step;
          for k in 1 to 3 loop
            check_eq(ck, render(ctrl), "b:-", "control word while halted after " & hex(b0v));
            check(ck, step = frozen, "step frozen while halted after " & hex(b0v));
            tick;
          end loop;
        else
          check_eq(ck, halted, '0', "not halted after " & hex(b0v));
          check(ck, step = "000", "step back to T0 after " & hex(b0v));
        end if;
      end loop;
    end loop;

    -- reset is the only way out of the halted state
    rst <= '1'; ir0 <= x"01"; tick; rst <= '0';
    for k in 0 to 4 loop tick; end loop;                       -- execute HLT
    check_eq(ck, halted, '1', "HLT halts");
    check_eq(ck, illegal, '0', "HLT is not illegal");
    rst <= '1'; tick; rst <= '0';
    check_eq(ck, halted, '0', "reset clears halted");
    check_eq(ck, illegal, '0', "reset clears illegal");
    check(ck, step = "000", "reset returns to T0");

    -- coverage summary
    for o in 0 to 15 loop
      for s in 0 to 7 loop
        if cov(o, s) > 0 then n_cov := n_cov + 1; end if;
      end loop;
    end loop;
    report "coverage: " & integer'image(n_cov) & " (opcode, step) pairs exercised";
    check(ck, cov(16#F#, 7) > 0, "CALL step T7 covered");
    check(ck, cov(16#0#, 6) > 0, "RET step T6 covered");

    done <= true;
    end_test(ck, "tb_control");
    wait;
  end process;

end architecture sim;
