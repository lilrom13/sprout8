-- =============================================================================
-- sprout8_pkg : shared types and constants of the Sprout-8 reference design.
-- Module specification, section 2 (docs/spec/sprout8-module-spec.md).
-- Every RTL file and every testbench uses this package; a Logisim export is
-- tested against the same definitions.
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;

package sprout8_pkg is

  -- ---------------- basic types --------------------------------------------
  subtype byte_t   is std_logic_vector(7 downto 0);
  subtype regsel_t is std_logic_vector(1 downto 0);       -- 00 = A ... 11 = D
  type    regs_t   is array (0 to 3) of byte_t;            -- register file contents

  -- ---------------- reset values and I/O ports (ISA 3.3, 4.3) ---------------
  constant RESET_PC : byte_t := x"00";
  constant RESET_SP : byte_t := x"F0";

  constant PORT_LEDS       : byte_t := x"F0";
  constant PORT_SWITCHES   : byte_t := x"F1";
  constant PORT_TTY_OUT    : byte_t := x"F2";
  constant PORT_TTY_STATUS : byte_t := x"F3";
  constant PORT_TTY_IN     : byte_t := x"F4";

  -- ---------------- ALU operation (spec 2.2; tb_alu drives it as 0..7) -----
  subtype aluop_t is std_logic_vector(2 downto 0);
  constant ALU_ADD  : aluop_t := "000";
  constant ALU_SUB  : aluop_t := "001";
  constant ALU_AND  : aluop_t := "010";
  constant ALU_OR   : aluop_t := "011";
  constant ALU_XOR  : aluop_t := "100";
  constant ALU_SHL  : aluop_t := "101";
  constant ALU_SHR  : aluop_t := "110";
  constant ALU_PASB : aluop_t := "111";

  -- ---------------- bus source (spec 2.3, in code order 0..7) --------------
  type bus_src_t is (BUS_NONE, BUS_PC, BUS_SP, BUS_IR1, BUS_MEM, BUS_RD, BUS_RS, BUS_ALU);

  -- ---------------- control word (spec 2.4) --------------------------------
  type ctrl_t is record
    bus_src    : bus_src_t;
    mar_load   : std_logic;
    ir0_load   : std_logic;
    ir1_load   : std_logic;
    reg_we     : std_logic;
    pc_load    : std_logic;
    mem_write  : std_logic;
    mem_read   : std_logic;
    pc_inc     : std_logic;
    sp_inc     : std_logic;
    sp_dec     : std_logic;
    flags_load : std_logic;
    alu_op     : aluop_t;
    alu_b_one  : std_logic;
    step_reset : std_logic;
  end record ctrl_t;

  constant CTRL_NOP : ctrl_t := (
    bus_src => BUS_NONE, alu_op => ALU_ADD, others => '0');

end package sprout8_pkg;
