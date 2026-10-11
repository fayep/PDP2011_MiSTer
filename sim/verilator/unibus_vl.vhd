-- unibus_vl: unibus with tb_xxdp's fixed configuration, for GHDL synthesis -> Verilator.
-- The configuration values are unibus ports, not generics; tying them to constants here lets
-- synthesis prune the absent devices instead of leaving them as run-time inputs.
-- 11/70, console KL11 (230400 bps) + KW11-L (60 Hz), no disks. init_r7 and cons_sw stay ports
-- (the harness sets the start address and console switches per diagnostic).
library ieee;
use ieee.std_logic_1164.all;

entity unibus_vl is
   port(
      addr          : out std_logic_vector(21 downto 0);
      dati          : in  std_logic_vector(15 downto 0);
      dato          : out std_logic_vector(15 downto 0);
      control_dati  : out std_logic;
      control_dato  : out std_logic;
      control_datob : out std_logic;
      addr_match    : in  std_logic;
      init_r7       : in  std_logic_vector(15 downto 0);
      cons_sw       : in  std_logic_vector(21 downto 0);
      cons_run      : out std_logic;
      tx0           : out std_logic;
      rx0           : in  std_logic;
      clk           : in  std_logic;
      clk50mhz      : in  std_logic;
      reset         : in  std_logic
   );
end unibus_vl;

architecture rtl of unibus_vl is
begin
   u : entity work.unibus
      port map(
         modelcode => 70, have_kl11 => 1, kl0_bps => 230400, have_kw11l => 1, kw11l_hz => 60,
         have_rh => 0, have_rk => 0, have_rl => 0, have_tm => 0,
         init_r7 => init_r7, init_psw => x"00e0", cons_sw => cons_sw,
         addr => addr, dati => dati, dato => dato,
         control_dati => control_dati, control_dato => control_dato, control_datob => control_datob,
         addr_match => addr_match, cons_run => cons_run, tx0 => tx0, rx0 => rx0,
         clk => clk, clk50mhz => clk50mhz, reset => reset);
end rtl;
