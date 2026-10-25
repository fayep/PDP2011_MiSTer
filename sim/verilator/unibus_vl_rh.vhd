-- unibus_vl_rh: unibus_vl plus the RH70 (RP06) and its hps_io disk slot, for sim/verilator/rhbench.cpp.
-- The disk slot's clk_sd is the CPU clock here: mister_blkdev synchronises both ways, so the bridge
-- works the same, and the harness can play Main's part (pick up rd/wr, ack, stream the block) on
-- the same cycle count. Same fixed configuration as unibus_vl otherwise.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity unibus_vl_rh is
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
      rh_sd_lba     : out std_logic_vector(31 downto 0);
      rh_sd_rd      : out std_logic;
      rh_sd_wr      : out std_logic;
      rh_sd_ack     : in  std_logic;
      rh_sd_buff_din : out std_logic_vector(15 downto 0);
      sd_buff_addr  : in  std_logic_vector(7 downto 0);
      sd_buff_dout  : in  std_logic_vector(15 downto 0);
      sd_buff_wr    : in  std_logic;
      rh_type_v     : in  std_logic_vector(3 downto 0);   -- RH70 drive type (rh11's rh_type, 1..8)
      clk           : in  std_logic;
      clk50mhz      : in  std_logic;
      reset         : in  std_logic
   );
end unibus_vl_rh;

architecture rtl of unibus_vl_rh is
begin
   u : entity work.unibus
      port map(
         modelcode => 70, have_kl11 => 1, kl0_bps => 230400, have_kw11l => 1, kw11l_hz => 60,
         have_rh => 1, have_rk => 0, have_rl => 0, have_tm => 0, rh_type => to_integer(unsigned(rh_type_v)),
         init_r7 => init_r7, init_psw => x"00e0", cons_sw => cons_sw,
         addr => addr, dati => dati, dato => dato,
         control_dati => control_dati, control_dato => control_dato, control_datob => control_datob,
         addr_match => addr_match, cons_run => cons_run, tx0 => tx0, rx0 => rx0,
         rh_sd_lba => rh_sd_lba, rh_sd_rd => rh_sd_rd, rh_sd_wr => rh_sd_wr, rh_sd_ack => rh_sd_ack,
         rh_sd_buff_din => rh_sd_buff_din, sd_buff_addr => sd_buff_addr, sd_buff_dout => sd_buff_dout,
         sd_buff_wr => sd_buff_wr, clk_sd => clk,
         clk => clk, clk50mhz => clk50mhz, reset => reset);
end rtl;
