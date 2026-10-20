-- =============================================================================
-- tb_alu : exhaustive test of the ALU against an integer reference model.
-- Every op x every A x every B = 8 x 256 x 256 = 524,288 cases.
-- Spec: 3.2 (flags), 6.2 (arithmetic and logic).
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sprout8_pkg.all;
use work.tb_pkg.all;

entity tb_alu is
end entity tb_alu;

architecture sim of tb_alu is
  signal a, b, y : byte_t := x"00";
  signal op      : aluop_t := ALU_ADD;
  signal z, c, n : std_logic;
  shared variable ck : checker_t;

  -- Reference model, written with integers straight from the spec,
  -- deliberately independent of the RTL coding style.
  procedure model(opv : aluop_t; ai, bi : natural;
                  variable ry : out natural; variable rc : out std_logic) is
  begin
    rc := '0';
    case opv is
      when ALU_ADD => ry := (ai + bi) mod 256;  if ai + bi > 255 then rc := '1'; end if;
      when ALU_SUB => ry := (ai - bi + 256) mod 256; if ai < bi then rc := '1'; end if;
      when ALU_AND => ry := to_integer(to_unsigned(ai, 8) and to_unsigned(bi, 8));
      when ALU_OR  => ry := to_integer(to_unsigned(ai, 8) or  to_unsigned(bi, 8));
      when ALU_XOR => ry := to_integer(to_unsigned(ai, 8) xor to_unsigned(bi, 8));
      when ALU_SHL => ry := (ai * 2) mod 256; if ai >= 128 then rc := '1'; end if;
      when ALU_SHR => ry := ai / 2;           if ai mod 2 = 1 then rc := '1'; end if;
      when others  => ry := bi;
    end case;
  end procedure;

begin

  dut : entity work.alu port map (a => a, b => b, op => op, y => y, z => z, c => c, n => n);

  stim : process
    variable ey   : natural;
    variable ec   : std_logic;
    variable ez   : std_logic;
    variable en   : std_logic;
    variable errs_before : natural;
    type name_t is array (0 to 7) of string(1 to 4);
    constant NAMES : name_t := ("ADD ", "SUB ", "AND ", "OR  ", "XOR ", "SHL ", "SHR ", "PASB");
  begin
    -- 1) directed edge cases from the spec (Appendix C, C2-C5)
    op <= ALU_ADD; a <= x"FF"; b <= x"01"; wait for 1 ns;
    check_eq(ck, y, x"00", "C2 ADD FF+01 result"); check_eq(ck, z, '1', "C2 Z");
    check_eq(ck, c, '1', "C2 C");                  check_eq(ck, n, '0', "C2 N");

    op <= ALU_SUB; a <= x"03"; b <= x"05"; wait for 1 ns;
    check_eq(ck, y, x"FE", "C3 SUB 03-05 result"); check_eq(ck, z, '0', "C3 Z");
    check_eq(ck, c, '1', "C3 borrow");             check_eq(ck, n, '1', "C3 N");

    op <= ALU_SUB; a <= x"05"; b <= x"05"; wait for 1 ns;
    check_eq(ck, z, '1', "SUB equal sets Z"); check_eq(ck, c, '0', "SUB equal: no borrow");

    op <= ALU_OR; a <= x"00"; b <= x"01"; wait for 1 ns;
    check_eq(ck, y, x"01", "C4 OR result"); check_eq(ck, c, '0', "C4 logic clears C");

    op <= ALU_SHR; a <= x"81"; b <= x"00"; wait for 1 ns;
    check_eq(ck, y, x"40", "C5 SHR 81"); check_eq(ck, c, '1', "C5 SHR carry = old bit 0");

    op <= ALU_SHL; a <= x"80"; wait for 1 ns;
    check_eq(ck, y, x"00", "SHL 80"); check_eq(ck, c, '1', "SHL carry = old bit 7");
    check_eq(ck, z, '1', "SHL 80 gives zero");

    -- INC / DEC are ADD / SUB with B = 1 (the CPU forces B)
    op <= ALU_ADD; a <= x"FF"; b <= x"01"; wait for 1 ns;
    check_eq(ck, c, '1', "INC FF sets C");
    op <= ALU_SUB; a <= x"00"; b <= x"01"; wait for 1 ns;
    check_eq(ck, y, x"FF", "DEC 00 wraps"); check_eq(ck, c, '1', "DEC 00 sets C");
    check_eq(ck, n, '1', "DEC 00 sets N");

    -- 2) exhaustive sweep
    for o in 0 to 7 loop
      errs_before := ck.errors;
      op <= std_logic_vector(to_unsigned(o, 3));
      for ai in 0 to 255 loop
        for bi in 0 to 255 loop
          a <= std_logic_vector(to_unsigned(ai, 8));
          b <= std_logic_vector(to_unsigned(bi, 8));
          wait for 1 ns;
          model(std_logic_vector(to_unsigned(o, 3)), ai, bi, ey, ec);
          if ey = 0   then ez := '1'; else ez := '0'; end if;
          if ey >= 128 then en := '1'; else en := '0'; end if;
          if y /= std_logic_vector(to_unsigned(ey, 8)) or c /= ec or z /= ez or n /= en then
            ck.fail(NAMES(o) & " a=" & hex(a) & " b=" & hex(b) &
                    " got y=" & hex(y) & " zcn=" & std_logic'image(z) & std_logic'image(c) & std_logic'image(n) &
                    " expected y=" & hex(std_logic_vector(to_unsigned(ey, 8))) &
                    " zcn=" & std_logic'image(ez) & std_logic'image(ec) & std_logic'image(en));
          else
            ck.pass;
          end if;
        end loop;
      end loop;
      report "  " & NAMES(o) & " sweep done, " & integer'image(ck.errors - errs_before) & " mismatches";
    end loop;

    end_test(ck, "tb_alu");
    wait;
  end process;

end architecture sim;
