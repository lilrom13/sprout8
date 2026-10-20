-- =============================================================================
-- Sprout-8 testbench utilities: checks, error counting, pass/fail summary.
-- A failing testbench ends with "severity failure", so GHDL exits non-zero and
-- scripts / CI can detect it. A passing one ends with std.env.finish.
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sprout8_pkg.all;

package tb_pkg is

  constant CLK_PERIOD : time := 10 ns;

  -- error/check counter shared by all processes of one testbench
  type checker_t is protected
    procedure pass;
    procedure fail(msg : string);
    impure function errors return natural;
    impure function checks return natural;
  end protected checker_t;

  procedure check(variable ck : inout checker_t; cond : boolean; msg : string);
  procedure check_eq(variable ck : inout checker_t; got, exp : std_logic_vector; msg : string);
  procedure check_eq(variable ck : inout checker_t; got, exp : std_logic; msg : string);
  procedure check_eq(variable ck : inout checker_t; got, exp : string; msg : string);
  procedure check_eq(variable ck : inout checker_t; got, exp : integer; msg : string);

  -- print the summary and end the simulation (failure => non-zero exit code)
  procedure end_test(variable ck : inout checker_t; name : string);

  function hex(v : std_logic_vector) return string;

end package tb_pkg;

package body tb_pkg is

  type checker_t is protected body
    variable n_err   : natural := 0;
    variable n_check : natural := 0;
    constant MAX_PRINT : natural := 25;

    procedure pass is
    begin
      n_check := n_check + 1;
    end procedure;

    procedure fail(msg : string) is
    begin
      n_check := n_check + 1;
      n_err   := n_err + 1;
      if n_err <= MAX_PRINT then
        report "CHECK FAILED: " & msg severity error;
      elsif n_err = MAX_PRINT + 1 then
        report "(further failures not printed)" severity error;
      end if;
    end procedure;

    impure function errors return natural is
    begin
      return n_err;
    end function;

    impure function checks return natural is
    begin
      return n_check;
    end function;
  end protected body checker_t;

  function hex(v : std_logic_vector) return string is
  begin
    return "0x" & to_hstring(v);
  end function;

  procedure check(variable ck : inout checker_t; cond : boolean; msg : string) is
  begin
    if cond then ck.pass; else ck.fail(msg); end if;
  end procedure;

  procedure check_eq(variable ck : inout checker_t; got, exp : std_logic_vector; msg : string) is
  begin
    if got = exp then
      ck.pass;
    else
      ck.fail(msg & ": got " & hex(got) & ", expected " & hex(exp));
    end if;
  end procedure;

  procedure check_eq(variable ck : inout checker_t; got, exp : std_logic; msg : string) is
  begin
    if got = exp then
      ck.pass;
    else
      ck.fail(msg & ": got " & std_logic'image(got) & ", expected " & std_logic'image(exp));
    end if;
  end procedure;

  procedure check_eq(variable ck : inout checker_t; got, exp : string; msg : string) is
  begin
    if got = exp then
      ck.pass;
    else
      ck.fail(msg & LF & "      got:      " & got & LF & "      expected: " & exp);
    end if;
  end procedure;

  procedure check_eq(variable ck : inout checker_t; got, exp : integer; msg : string) is
  begin
    if got = exp then
      ck.pass;
    else
      ck.fail(msg & ": got " & integer'image(got) & ", expected " & integer'image(exp));
    end if;
  end procedure;

  procedure end_test(variable ck : inout checker_t; name : string) is
  begin
    if ck.errors = 0 then
      report name & ": PASS (" & integer'image(ck.checks) & " checks)" severity note;
      std.env.finish;
    else
      report name & ": FAIL (" & integer'image(ck.errors) & " of " &
             integer'image(ck.checks) & " checks failed)" severity failure;
    end if;
  end procedure;

end package body tb_pkg;
