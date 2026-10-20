-- =============================================================================
-- Sprout-8 golden model: an instruction-set simulator written directly from
-- the ISA manual (chapters 3-6). It knows nothing about steps, buses or
-- control signals; it only applies each instruction's pseudocode.
-- tb_cpu runs it in lockstep with the RTL and compares architectural state
-- after every instruction.
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sprout8_pkg.all;

package sprout8_iss_pkg is

  type nat_regs_t is array (0 to 3) of natural range 0 to 255;
  type nat_mem_t  is array (0 to 255) of natural range 0 to 255;

  type iss_t is record
    mem      : nat_mem_t;            -- only 0x00-0xEF is RAM
    r        : nat_regs_t;           -- A, B, C, D
    pc, sp   : natural range 0 to 255;
    z, c, n  : std_logic;
    halted   : boolean;
    illegal  : boolean;
    leds     : natural range 0 to 255;
    switches : natural range 0 to 255;
    last_op  : natural range 0 to 255; -- byte 0 of the last executed instruction
  end record;

  procedure iss_reset(variable s : inout iss_t);   -- keeps memory and switches
  procedure iss_step(variable s : inout iss_t);
  impure function iss_read(s : iss_t; a : natural) return natural;

end package sprout8_iss_pkg;

package body sprout8_iss_pkg is

  procedure iss_reset(variable s : inout iss_t) is
  begin
    s.r := (others => 0);
    s.pc := 0; s.sp := 16#F0#;
    s.z := '0'; s.c := '0'; s.n := '0';
    s.halted := false; s.illegal := false;
    s.leds := 0;
  end procedure;

  -- reads have no side effects here: lockstep tests never queue keys
  impure function iss_read(s : iss_t; a : natural) return natural is
  begin
    if a < 16#F0# then return s.mem(a);
    elsif a = 16#F0# then return s.leds;
    elsif a = 16#F1# then return s.switches;
    else return 0;                     -- TTY_OUT, TTY_STATUS/TTY_IN (no key), reserved
    end if;
  end function;

  procedure write_mem(variable s : inout iss_t; a, v : natural) is
  begin
    if a < 16#F0# then s.mem(a) := v;
    elsif a = 16#F0# then s.leds := v;
    end if;                            -- TTY_OUT and others: no architectural state
  end procedure;

  procedure set_zn(variable s : inout iss_t; v : natural) is
  begin
    if v = 0 then s.z := '1'; else s.z := '0'; end if;
    if v >= 128 then s.n := '1'; else s.n := '0'; end if;
  end procedure;

  function bitop(x, y : natural; kind : natural) return natural is
    variable ux : unsigned(7 downto 0) := to_unsigned(x, 8);
    variable uy : unsigned(7 downto 0) := to_unsigned(y, 8);
  begin
    case kind is
      when 0      => return to_integer(ux and uy);
      when 1      => return to_integer(ux or uy);
      when others => return to_integer(ux xor uy);
    end case;
  end function;

  procedure iss_step(variable s : inout iss_t) is
    variable b0, b1, op, rd, rs, v, t : natural;
  begin
    if s.halted then return; end if;
    b0 := iss_read(s, s.pc);
    b1 := iss_read(s, (s.pc + 1) mod 256);
    s.pc := (s.pc + 2) mod 256;                     -- PC = address of next instruction
    s.last_op := b0;
    op := b0 / 16; rd := (b0 / 4) mod 4; rs := b0 mod 4;

    case op is
      when 16#0# =>                                  -- system group
        case rs is
          when 0 => null;                            -- NOP
          when 1 => s.halted := true;                -- HLT
          when 2 => s.pc := iss_read(s, s.sp); s.sp := (s.sp + 1) mod 256;   -- RET
          when others => s.halted := true; s.illegal := true;               -- reserved
        end case;
      when 16#1# => s.r(rd) := b1;                                          -- LDI
      when 16#2# => s.r(rd) := iss_read(s, b1);                             -- LD
      when 16#3# => write_mem(s, b1, s.r(rd));                              -- ST
      when 16#4# => s.r(rd) := iss_read(s, s.r(rs));                        -- LDR
      when 16#5# => write_mem(s, s.r(rs), s.r(rd));                         -- STR
      when 16#6# => s.r(rd) := s.r(rs);                                     -- MOV
      when 16#7# =>                                                         -- ADD
        t := s.r(rd) + s.r(rs);
        if t > 255 then s.c := '1'; else s.c := '0'; end if;
        s.r(rd) := t mod 256; set_zn(s, s.r(rd));
      when 16#8# | 16#C# =>                                                 -- SUB, CMP
        if s.r(rd) < s.r(rs) then s.c := '1'; else s.c := '0'; end if;
        v := (s.r(rd) + 256 - s.r(rs)) mod 256;
        set_zn(s, v);
        if op = 16#8# then s.r(rd) := v; end if;
      when 16#9# | 16#A# | 16#B# =>                                         -- AND, OR, XOR
        s.r(rd) := bitop(s.r(rd), s.r(rs), op - 16#9#);
        s.c := '0'; set_zn(s, s.r(rd));
      when 16#D# =>                                                         -- unary
        v := s.r(rd);
        case rs is
          when 0 => if v = 255 then s.c := '1'; else s.c := '0'; end if; v := (v + 1) mod 256;   -- INC
          when 1 => if v = 0   then s.c := '1'; else s.c := '0'; end if; v := (v + 255) mod 256; -- DEC
          when 2 => if v >= 128 then s.c := '1'; else s.c := '0'; end if; v := (v * 2) mod 256;  -- SHL
          when others => if v mod 2 = 1 then s.c := '1'; else s.c := '0'; end if; v := v / 2;    -- SHR
        end case;
        s.r(rd) := v; set_zn(s, v);
      when 16#E# =>                                                         -- jumps
        if rd = 0 or (rd = 1 and s.z = '1') or (rd = 2 and s.z = '0') or (rd = 3 and s.c = '1') then
          s.pc := b1;
        end if;
      when others =>                                                        -- stack group
        case rs is
          when 0 => s.sp := (s.sp + 255) mod 256; write_mem(s, s.sp, s.r(rd));        -- PUSH
          when 1 => s.r(rd) := iss_read(s, s.sp); s.sp := (s.sp + 1) mod 256;         -- POP
          when 2 => s.sp := (s.sp + 255) mod 256; write_mem(s, s.sp, s.pc); s.pc := b1; -- CALL
          when others => s.halted := true; s.illegal := true;                         -- reserved
        end case;
    end case;
  end procedure;

end package body sprout8_iss_pkg;
