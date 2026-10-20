-- =============================================================================
-- tb_mem_io : 240-byte RAM plus the memory-mapped I/O ports.
-- Covers: INIT_FILE loading, every RAM address, RAM not cleared by reset,
-- writes to the I/O range never reaching RAM, LEDS readback and reset,
-- SWITCHES, TTY_OUT strobe, TTY_STATUS, TTY_IN consume-on-read (and not on a
-- mere address match), reserved ports. Spec: chapter 4, C14-C16.
-- =============================================================================
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.sprout8_pkg.all;
use work.tb_pkg.all;

entity tb_mem_io is
  generic (
    INIT_FILE : string := "hw/tb/data/mem_init_test.hex"
  );
end entity tb_mem_io;

architecture sim of tb_mem_io is
  signal clk           : std_logic := '0';
  signal rst           : std_logic := '1';
  signal addr          : byte_t := x"00";
  signal wdata         : byte_t := x"00";
  signal we            : std_logic := '0';
  signal re            : std_logic := '0';
  signal rdata         : byte_t;
  signal leds          : byte_t;
  signal switches      : byte_t := x"00";
  signal tty_out_data  : byte_t;
  signal tty_out_valid : std_logic;
  signal tty_in_data   : byte_t := x"00";
  signal tty_in_valid  : std_logic := '0';
  signal tty_in_ack    : std_logic;
  signal done          : boolean := false;

  -- TTY_OUT monitor
  signal out_count     : natural := 0;
  signal out_last      : byte_t := x"00";
  -- TTY_IN model: a key is taken from the queue when ack is high at an edge
  signal ack_count     : natural := 0;

  shared variable ck : checker_t;
begin
  clk <= not clk after CLK_PERIOD / 2 when not done;

  dut : entity work.mem_io
    generic map (INIT_FILE => INIT_FILE)
    port map (clk => clk, rst => rst, addr => addr, wdata => wdata, we => we, re => re,
              rdata => rdata, leds => leds, switches => switches,
              tty_out_data => tty_out_data, tty_out_valid => tty_out_valid,
              tty_in_data => tty_in_data, tty_in_valid => tty_in_valid,
              tty_in_ack => tty_in_ack);

  monitor : process (clk)
  begin
    if rising_edge(clk) then
      if tty_out_valid = '1' then
        out_count <= out_count + 1;
        out_last  <= tty_out_data;
      end if;
      if tty_in_ack = '1' then
        ack_count <= ack_count + 1;
      end if;
    end if;
  end process;

  stim : process
    procedure tick is begin wait until rising_edge(clk); wait for 1 ns; end procedure;

    procedure write(a, v : byte_t) is
    begin
      addr <= a; wdata <= v; we <= '1'; tick; we <= '0';
    end procedure;

    procedure peek(a : byte_t; exp : byte_t; msg : string) is
    begin
      addr <= a; re <= '0'; wait for 1 ns;
      check_eq(ck, rdata, exp, msg);
    end procedure;
  begin
    -- ---------- INIT_FILE image (see tb/data/mem_init_test.hex) ------------
    peek(x"00", x"10", "init image byte 0x00");
    peek(x"01", x"2A", "init image byte 0x01");
    peek(x"02", x"01", "init image byte 0x02");
    peek(x"40", x"99", "init image after @40");
    peek(x"41", x"BE", "init image 0x41");
    peek(x"03", x"00", "unspecified bytes load as 0x00");
    peek(x"80", x"11", "init image four bytes on one line (1)");
    peek(x"83", x"44", "init image four bytes on one line (4)");

    rst <= '1'; tick; tick; rst <= '0';
    check_eq(ck, leds, x"00", "LEDS cleared by reset");
    peek(x"40", x"99", "RAM is NOT cleared by reset (spec 3.3)");

    -- ---------- every RAM address --------------------------------------------
    for a in 0 to 16#EF# loop
      write(std_logic_vector(to_unsigned(a, 8)), std_logic_vector(to_unsigned((a * 7 + 3) mod 256, 8)));
    end loop;
    for a in 0 to 16#EF# loop
      peek(std_logic_vector(to_unsigned(a, 8)), std_logic_vector(to_unsigned((a * 7 + 3) mod 256, 8)),
           "RAM readback");
    end loop;
    -- inverse pattern catches stuck bits and address aliasing
    for a in 0 to 16#EF# loop
      write(std_logic_vector(to_unsigned(a, 8)), not std_logic_vector(to_unsigned(a, 8)));
    end loop;
    for a in 0 to 16#EF# loop
      peek(std_logic_vector(to_unsigned(a, 8)), not std_logic_vector(to_unsigned(a, 8)), "RAM inverse readback");
    end loop;

    -- write enable low does nothing
    addr <= x"10"; wdata <= x"00"; we <= '0'; tick;
    peek(x"10", not x"10", "we = 0 must not write");

    -- ---------- I/O range never reaches RAM ----------------------------------
    for a in 16#F0# to 16#FF# loop
      write(std_logic_vector(to_unsigned(a, 8)), x"77");
    end loop;
    for a in 16#E0# to 16#EF# loop
      peek(std_logic_vector(to_unsigned(a, 8)), not std_logic_vector(to_unsigned(a, 8)),
           "I/O writes must not alias into RAM");
    end loop;
    check_eq(ck, out_count, 1, "the sweep above wrote TTY_OUT exactly once");

    -- ---------- LEDS ---------------------------------------------------------
    write(PORT_LEDS, x"5A");
    check_eq(ck, leds, x"5A", "LEDS output");
    peek(PORT_LEDS, x"5A", "C15 LEDS readback");

    -- ---------- SWITCHES -----------------------------------------------------
    for i in 0 to 255 loop
      switches <= std_logic_vector(to_unsigned(i, 8));
      peek(PORT_SWITCHES, std_logic_vector(to_unsigned(i, 8)), "SWITCHES read");
    end loop;
    write(PORT_SWITCHES, x"00");
    switches <= x"C3";
    peek(PORT_SWITCHES, x"C3", "writes to SWITCHES are ignored");

    -- ---------- TTY_OUT --------------------------------------------------------
    write(PORT_TTY_OUT, x"48");
    check_eq(ck, out_count, 2, "TTY_OUT strobe once per write");
    check_eq(ck, out_last, x"48", "TTY_OUT data");
    peek(PORT_TTY_OUT, x"00", "TTY_OUT reads 0x00");
    rst <= '1'; addr <= PORT_TTY_OUT; we <= '1'; tick; we <= '0'; rst <= '0';
    check_eq(ck, out_count, 2, "no TTY_OUT strobe while in reset");

    -- ---------- TTY_STATUS / TTY_IN ---------------------------------------------
    tty_in_valid <= '0';
    peek(PORT_TTY_STATUS, x"00", "TTY_STATUS with no key");
    peek(PORT_TTY_IN, x"00", "TTY_IN with no key reads 0x00");
    tty_in_valid <= '1'; tty_in_data <= x"6B";
    peek(PORT_TTY_STATUS, x"01", "TTY_STATUS with a key waiting");
    peek(PORT_TTY_IN, x"6B", "TTY_IN data visible");

    -- address match without the read strobe must NOT consume the key
    addr <= PORT_TTY_IN; re <= '0'; tick; tick;
    check_eq(ck, ack_count, 0, "no ack without the read strobe");
    -- reading TTY_STATUS with the strobe must not consume it either
    addr <= PORT_TTY_STATUS; re <= '1'; tick; re <= '0';
    check_eq(ck, ack_count, 0, "TTY_STATUS read does not consume the key");
    -- a strobed read of TTY_IN consumes exactly one key
    addr <= PORT_TTY_IN; re <= '1'; tick; re <= '0';
    check_eq(ck, ack_count, 1, "C16 strobed TTY_IN read consumes the key");
    tty_in_valid <= '0';
    addr <= PORT_TTY_IN; re <= '1'; wait for 1 ns;
    check_eq(ck, rdata, x"00", "C16 second read returns 0x00");
    tick; re <= '0';
    check_eq(ck, ack_count, 1, "no ack when no key is waiting");

    -- ---------- reserved ports ------------------------------------------------
    for a in 16#F5# to 16#FF# loop
      peek(std_logic_vector(to_unsigned(a, 8)), x"00", "C14 reserved port reads 0x00");
    end loop;

    done <= true;
    end_test(ck, "tb_mem_io");
    wait;
  end process;
end architecture sim;
