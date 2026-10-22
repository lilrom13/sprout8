-- =============================================================================
-- reg8 adapter: gives the Logisim circuit the interface tb_reg8 expects.
-- Logisim subcircuits have no generics, so the drawn reg8 takes its reset value
-- on an 8-bit input pin (reset_value). This wrapper turns the RESET_VALUE generic
-- into a constant on that pin. The exported circuit is renamed reg8_logisim.
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use work.sprout8_pkg.all;

entity reg8 is
  generic (RESET_VALUE : byte_t := x"00");
  port (
    clk  : in  std_logic;
    rst  : in  std_logic;
    load : in  std_logic;
    d    : in  byte_t;
    q    : out byte_t
  );
end entity reg8;

architecture adapter of reg8 is
begin
  u : entity work.reg8_logisim
    port map (clk => clk, rst => rst, load => load, d => d,
              reset_value => RESET_VALUE, q => q);
end architecture adapter;
