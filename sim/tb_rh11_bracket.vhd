-- deps: mister_blkdev.vhd rh11.vhd
--
-- tb_rh11_bracket.vhd -- GHDL harness: the RH70/RH11 status must bracket a
-- transaction, so that software can never start a second one before the
-- first has ended.
--
-- An RP06 on rh11 + mister_blkdev against a behavioural hps_io disk slot with
-- random latency (20 ns .. 30 us) and random word gaps; every block's data is
-- a function of its LBN, so the whole pack exists. A loop of reads issued
-- with RSTS/E V10.1 INIT's exact register sequence (from a SIMH trace of
-- INIT loading its overlays: AS, DCLR+GO, DT, PACK+GO, DC, OF, DA, DS, DS,
-- CS1, DS, then BA, WC, READ+GO) with random LBN, length (1..13 blocks) and
-- buffer, finished either by polling CS1.RDY (as INIT does) or DS.DRY, and
-- the next transfer started at once. Checks, per transfer:
--   * when software sees ready: no DMA and no hps request in flight
--   * RMR never set (no register write refused)
--   * hps was asked for exactly the transfer's LBNs, in order
--   * every word landed at the right address
-- And: a GO to a non-existent unit (CS2 unit 1) must not leave the
-- controller busy for the real drive.
--
-- Run:  sim/run_tb_rh11_bracket.sh
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.MATH_REAL.ALL;

entity tb_rh11_bracket is
   generic(RH70 : integer range 0 to 1 := 1; NXFER : integer := 60; SEED : integer := 1);
end tb_rh11_bracket;

architecture sim of tb_rh11_bracket is

   constant RH_BASE : std_logic_vector(17 downto 0) := o"776700";
   constant RMCS1 : std_logic_vector(4 downto 0) := "00000";
   constant RMWC  : std_logic_vector(4 downto 0) := "00001";
   constant RMBA  : std_logic_vector(4 downto 0) := "00010";
   constant RMDA  : std_logic_vector(4 downto 0) := "00011";
   constant RMCS2 : std_logic_vector(4 downto 0) := "00100";
   constant RMDS  : std_logic_vector(4 downto 0) := "00101";
   constant RMER1 : std_logic_vector(4 downto 0) := "00110";
   constant RMAS  : std_logic_vector(4 downto 0) := "00111";
   constant RMDT  : std_logic_vector(4 downto 0) := "01011";
   constant RMOF  : std_logic_vector(4 downto 0) := "01101";
   constant RMDC  : std_logic_vector(4 downto 0) := "01110";

   function orig(lba, w : integer) return std_logic_vector is
   begin
      return conv_std_logic_vector(((lba mod 4096) * 256 + w) * 13 + lba / 4096 + 16#0BEE#, 16);
   end function;

   signal clk     : std_logic := '0';
   signal nclk    : std_logic := '1';
   signal clk_sys : std_logic := '0';
   signal reset   : std_logic := '1';

   signal b_addr  : std_logic_vector(17 downto 0) := (others => '0');
   signal b_dato  : std_logic_vector(15 downto 0) := (others => '0');
   signal b_dati  : std_logic_vector(15 downto 0);
   signal b_cdati : std_logic := '0';
   signal b_cdato : std_logic := '0';

   signal m_addr  : std_logic_vector(17 downto 0);
   signal m_dato, m_dati : std_logic_vector(15 downto 0);
   signal m_cdati, m_cdato : std_logic;
   signal x_addr  : std_logic_vector(21 downto 0);
   signal x_dato, x_dati : std_logic_vector(15 downto 0);
   signal x_cdati, x_cdato : std_logic;
   signal npr, npg : std_logic;

   signal sd_lba : std_logic_vector(31 downto 0);
   signal sd_rd, sd_wr : std_logic;
   signal sd_ack : std_logic := '0';
   signal sd_buff_addr : std_logic_vector(7 downto 0) := (others => '0');
   signal sd_buff_dout : std_logic_vector(15 downto 0) := (others => '0');
   signal sd_buff_din : std_logic_vector(15 downto 0);
   signal sd_buff_wr : std_logic := '0';

   type mem_t is array(0 to 32767) of std_logic_vector(15 downto 0);
   signal mem : mem_t := (others => x"0000");

   type lbalog_t is array(0 to 4095) of integer;
   signal lbalog : lbalog_t;
   signal nreq : integer := 0;

   signal fail_count : integer := 0;
   signal pass_count : integer := 0;

begin

   clk     <= not clk after 70 ns;
   nclk    <= not clk;
   clk_sys <= not clk_sys after 5 ns;
   npg     <= npr;

   dut: entity work.rh11 port map(
      base_addr => RH_BASE, ivec => o"254", br => open, bg => '0', int_vector => open,
      npr => npr, npg => npg, bus_addr_match => open,
      bus_addr => b_addr, bus_dati => b_dati, bus_dato => b_dato,
      bus_control_dati => b_cdati, bus_control_dato => b_cdato, bus_control_datob => '0',
      bus_master_addr => m_addr, bus_master_dati => m_dati, bus_master_dato => m_dato,
      bus_master_control_dati => m_cdati, bus_master_control_dato => m_cdato, bus_master_nxm => '0',
      rh70_bus_master_addr => x_addr, rh70_bus_master_dati => x_dati, rh70_bus_master_dato => x_dato,
      rh70_bus_master_control_dati => x_cdati, rh70_bus_master_control_dato => x_cdato, rh70_bus_master_nxm => '0',
      sd_lba => sd_lba, sd_rd => sd_rd, sd_wr => sd_wr, sd_ack => sd_ack,
      sd_buff_addr => sd_buff_addr, sd_buff_dout => sd_buff_dout, sd_buff_din => sd_buff_din, sd_buff_wr => sd_buff_wr,
      clk_sys => clk_sys, have_rh => 1, img_mounted => 1, have_rh70 => RH70, rh_type => 6,
      reset => reset, clk50mhz => clk_sys, nclk => nclk, clk => clk
   );

   m_dati <= mem(conv_integer(m_addr(15 downto 1)));
   x_dati <= mem(conv_integer(x_addr(15 downto 1)));
   process(clk)
   begin
      if rising_edge(clk) then
         if m_cdato = '1' and RH70 = 0 then mem(conv_integer(m_addr(15 downto 1))) <= m_dato; end if;
         if x_cdato = '1' and RH70 = 1 then mem(conv_integer(x_addr(15 downto 1))) <= x_dato; end if;
      end if;
   end process;

   -- behavioural hps_io disk slot: random latency and word gaps
   hps: process
      variable s1, s2 : positive := 7;
      variable r : real;
      variable blk, lat, gap : integer;
   begin
      s1 := SEED * 7919 + 1; s2 := SEED * 104729 + 3;
      loop
         wait until rising_edge(clk_sys);
         assert sd_wr = '0' report "unexpected sd_wr" severity error;
         if sd_rd = '1' then
            blk := conv_integer(sd_lba);
            lbalog(nreq mod 4096) <= blk; nreq <= nreq + 1;
            uniform(s1, s2, r);
            if r < 0.5 then lat := 2 + integer(r * 200.0);              -- fast (page cache)
            elsif r < 0.9 then lat := 200 + integer(r * 2000.0);
            else lat := 1000 + integer(r * 2000.0); end if;              -- up to ~30 us
            for i in 1 to lat loop wait until rising_edge(clk_sys); end loop;
            sd_buff_addr <= (others => '0');
            sd_ack <= '1';
            wait until rising_edge(clk_sys);
            wait until rising_edge(clk_sys);
            uniform(s1, s2, r); gap := integer(r * 6.0);
            for w in 0 to 255 loop
               sd_buff_addr <= conv_std_logic_vector(w, 8);
               sd_buff_dout <= orig(blk, w);
               sd_buff_wr <= '1';
               wait until rising_edge(clk_sys);
               sd_buff_wr <= '0';
               for g in 1 to gap loop wait until rising_edge(clk_sys); end loop;
            end loop;
            sd_ack <= '0';
            wait until rising_edge(clk_sys);
         end if;
      end loop;
   end process;

   stim: process
      variable s1, s2 : positive := 11;
      variable r : real;
      variable v : std_logic_vector(15 downto 0);
      variable lba, nblk, wa, cyl, trk, sec, n0, polls, bad : integer;
      variable busy_at_ready : boolean;

      procedure cyc(n : integer) is
      begin
         for i in 1 to n loop wait until rising_edge(clk); end loop;
      end procedure;

      -- one CPU bus cycle per call, then the rest of the instruction (~2 cpu clocks)
      procedure reg_write(off : std_logic_vector(4 downto 0); d : std_logic_vector(15 downto 0)) is
      begin
         wait until rising_edge(nclk);
         b_addr <= RH_BASE(17 downto 6) & off & '0'; b_dato <= d; b_cdato <= '1';
         wait until rising_edge(nclk);
         b_cdato <= '0'; b_addr <= (others => '0');
         cyc(2);
      end procedure;

      procedure reg_read(off : std_logic_vector(4 downto 0); r : out std_logic_vector(15 downto 0)) is
      begin
         wait until rising_edge(nclk);
         b_addr <= RH_BASE(17 downto 6) & off & '0'; b_cdati <= '1';
         wait until rising_edge(nclk);
         wait until rising_edge(nclk);
         r := b_dati;
         b_cdati <= '0'; b_addr <= (others => '0');
      end procedure;

      procedure ok(tag : string; cond : boolean) is
      begin
         if cond then pass_count <= pass_count + 1;
         else report "FAIL " & tag severity error; fail_count <= fail_count + 1; end if;
         wait for 0 ns;
      end procedure;

      -- INIT's sequence for one overlay read (SIMH trace), then wait for completion
      procedure init_read(lba, nblk, wa : integer; use_dry : boolean; tag : string) is
         variable v : std_logic_vector(15 downto 0);
         variable cyl, trk, sec, n0, polls, bad : integer;
         variable busy : boolean;
      begin
         cyl := lba / 418; trk := (lba mod 418) / 22; sec := lba mod 22;
         n0 := nreq;
         reg_write(RMAS, x"0000");
         reg_write(RMCS1, x"0009");                                    -- drive clear + GO
         reg_read(RMDT, v);
         reg_write(RMCS1, x"0013");                                    -- pack acknowledge + GO
         reg_write(RMDC, conv_std_logic_vector(cyl, 16));
         reg_write(RMOF, x"1000");
         reg_write(RMDA, conv_std_logic_vector(trk * 256 + sec, 16));
         reg_read(RMDS, v); reg_read(RMDS, v); reg_read(RMCS1, v); reg_read(RMDS, v);
         reg_write(RMBA, conv_std_logic_vector(wa * 2, 16));
         reg_write(RMWC, conv_std_logic_vector(65536 - nblk * 256, 16));
         reg_write(RMCS1, x"0039");                                    -- read + GO
         polls := 0;
         loop
            if use_dry then reg_read(RMDS, v); exit when v(7) = '1';
            else reg_read(RMCS1, v); exit when v(7) = '1'; end if;
            polls := polls + 1;
            assert polls < 2000000 report "TIMEOUT " & tag severity failure;
         end loop;
         busy := npr = '1' or sd_rd = '1' or sd_ack = '1' or x_cdato = '1' or m_cdato = '1';
         ok(tag & ": ready only when idle (no DMA / hps request in flight)", not busy);
         cyc(4);                                                       -- let a late DMA finish, so the checks below see it
         wait until npr = '0' and sd_rd = '0' and sd_ack = '0' for 1 ms;
         cyc(4);
         reg_read(RMER1, v);
         ok(tag & ": no register write refused (RMR)", v(2) = '0');
         reg_write(RMCS1, x"0009");                                    -- (INIT clears it again next time anyway)
         ok(tag & ": hps asked for " & integer'image(nblk) & " blocks", nreq - n0 = nblk);
         bad := 0;
         for k in 0 to nblk - 1 loop
            if nreq - n0 = nblk and lbalog((n0 + k) mod 4096) /= lba + k then bad := bad + 1; end if;
         end loop;
         ok(tag & ": the right LBNs, in order", bad = 0);
         bad := 0;
         for k in 0 to nblk * 256 - 1 loop
            if mem(wa + k) /= orig(lba + k / 256, k mod 256) then bad := bad + 1; end if;
         end loop;
         ok(tag & ": every word at the right address (" & integer'image(bad) & " wrong)", bad = 0);
      end procedure;

   begin
      s1 := SEED * 31 + 5; s2 := SEED * 17 + 9;
      reset <= '1'; cyc(10); reset <= '0'; cyc(600);

      -- a GO to a non-existent unit must not leave the real drive busy
      reg_write(RMCS2, x"0001");
      reg_write(RMCS1, x"0013");                                       -- pack acknowledge + GO to unit 1
      reg_read(RMCS2, v);
      ok("unit 1: non-existent drive (NED)", v(12) = '1');
      reg_write(RMCS2, x"0000");
      init_read(460, 13, 1024, false, "after GO to unit 1");

      for i in 1 to NXFER loop
         uniform(s1, s2, r); lba := integer(r * 2000.0);
         uniform(s1, s2, r); nblk := 1 + integer(r * 12.0);
         uniform(s1, s2, r); wa := integer(r * real(32768 - 13 * 256 - 1));
         init_read(lba, nblk, wa, (i mod 3) = 0,
                   "xfer " & integer'image(i) & " lba " & integer'image(lba) & " n " & integer'image(nblk)
                   & " " & boolean'image((i mod 3) = 0));
      end loop;

      report "tb_rh11_bracket: RH70=" & integer'image(RH70) & " SEED=" & integer'image(SEED) & ": "
           & integer'image(pass_count) & " checks passed, " & integer'image(fail_count) & " failed";
      if fail_count = 0 then report "tb_rh11_bracket: ALL CHECKS PASSED";
      else report "tb_rh11_bracket: FAILURES" severity error; end if;
      std.env.stop;
      wait;
   end process;

end sim;
