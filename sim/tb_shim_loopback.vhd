--
-- tb_shim_real_master.vhd -- faithful GHDL testbench: instantiates the
-- REAL rtl/xubl.vhd (unmodified) as the SPI bus-master, driven exactly
-- the way roms/xubrt45.mac's real "xubl:" stub routine programs it
-- (write xf/rt/rl/xl via the regular bus interface, xl last -- triggers
-- run), against a simple RAM model on its bus_master_* DMA interface,
-- feeding it the exact same byte patterns chkeudast/initenc really send.
-- This replaces tb_shim.vhd's hand-bit-banged sender/receiver, which
-- needed a suspicious manual "extra edge" to pass -- this test checks
-- whether that was masking a real one-cycle CS/first-bit framing bug in
-- xu_enc424j600_shim.vhd's CS-edge-detection logic (see conversation,
-- 2026-08-27: xubl.vhd asserts cs and the first real data bit on the
-- SAME edge, but the shim spends that first edge only on state reset,
-- not sampling -- a hypothesis, not yet confirmed).
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_shim_loopback is
end tb_shim_loopback;

architecture sim of tb_shim_loopback is

   signal cpuclk : std_logic := '0';
   signal nclk : std_logic;
   signal clk50mhz_sig : std_logic := '0';
   signal reset : std_logic := '1';
   signal sim_done : boolean := false;

   -- xubl0 <-> shim SPI pins
   signal xu_cs, xu_mosi, xu_sclk, xu_miso : std_logic;

   -- xubl0 regular bus interface (the "CPU" side, programs xf/xl/rt/rl)
   constant BASE_ADDR : std_logic_vector(17 downto 0) := "000000000000010000";
   signal bus_addr : std_logic_vector(17 downto 0) := (others => '0');
   signal bus_dato : std_logic_vector(15 downto 0) := (others => '0');
   signal bus_control_dato : std_logic := '0';
   signal bus_dati : std_logic_vector(15 downto 0);
   signal bus_control_dati : std_logic := '0';
   signal bus_control_datob : std_logic := '0';
   signal bus_addr_match : std_logic;

   -- xubl0 DMA master interface (the "memory" side)
   signal npr, npg : std_logic := '0';
   signal bus_master_addr : std_logic_vector(17 downto 0);
   signal bus_master_dati : std_logic_vector(15 downto 0);
   signal bus_master_dato : std_logic_vector(15 downto 0);
   signal bus_master_control_dati : std_logic;
   signal bus_master_control_dato : std_logic;
   signal bus_master_nxm : std_logic := '0';

   -- shim <-> mailbox
   signal req_valid, req_ack, resp_valid, req_rw : std_logic;
   signal req_addr : std_logic_vector(15 downto 0);
   signal req_wdata, resp_rdata : std_logic_vector(63 downto 0);
   signal req_be : std_logic_vector(7 downto 0);

   signal DDRAM_CLK, DDRAM_BUSY, DDRAM_RD, DDRAM_WE, DDRAM_DOUT_READY : std_logic := '0';
   signal DDRAM_BURSTCNT, DDRAM_BE : std_logic_vector(7 downto 0);
   signal DDRAM_ADDR : std_logic_vector(28 downto 0);
   signal DDRAM_DIN, DDRAM_DOUT : std_logic_vector(126 downto 0);

   type ddr_ram_type is array(0 to 8191) of std_logic_vector(63 downto 0);
   signal ddr_ram : ddr_ram_type := (others => (others => '0'));
   -- fake-daemon write path -- single driver, merged into the DDR3 model
   -- process below (same reasoning as mem's preload mechanism: a second
   -- driver on ddr_ram would reproduce the exact std_logic resolution 'X'
   -- bug found earlier this session).
   signal ddr_preload_idx : integer range 0 to 8191 := 0;
   signal ddr_preload_data : std_logic_vector(63 downto 0) := (others => '0');
   signal ddr_preload_valid : std_logic := '0';

   -- "main memory" the real xu embedded CPU would DMA to/from --
   -- word-addressed (index = byte address / 2), 64 words is plenty
   type mem_type is array(0 to 63) of std_logic_vector(15 downto 0);
   signal mem : mem_type := (others => (others => '0'));
   signal preload_idx : integer range 0 to 63 := 0;
   signal preload_data : std_logic_vector(15 downto 0) := (others => '0');
   signal preload_valid : std_logic := '0';

   procedure prog_write(addr_bits : in std_logic_vector(2 downto 0);
                         data : in std_logic_vector(15 downto 0);
                         signal a : out std_logic_vector(17 downto 0);
                         signal d : out std_logic_vector(15 downto 0);
                         signal ctl : out std_logic;
                         signal clk : in std_logic) is
   begin
      a <= BASE_ADDR(17 downto 4) & addr_bits & '0';
      d <= data;
      wait until clk'event and clk = '1';
      ctl <= '1';
      wait until clk'event and clk = '1';
      ctl <= '0';
   end procedure;

   procedure preload(idx : in integer;
                      data : in std_logic_vector(15 downto 0);
                      signal p_idx : out integer;
                      signal p_data : out std_logic_vector(15 downto 0);
                      signal p_valid : out std_logic;
                      signal clk : in std_logic) is
   begin
      p_idx <= idx;
      p_data <= data;
      wait until clk'event and clk = '1';
      p_valid <= '1';
      wait until clk'event and clk = '1';
      p_valid <= '0';
   end procedure;

   constant WORD_TXRTS_REQ  : integer := 3073;  -- 0x6008 >> 3
   constant WORD_TXRTS_DONE : integer := 3074;  -- 0x6010 >> 3
   constant WORD_MAC_ADDR   : integer := 3080;  -- 0x6040 >> 3
   constant WORD_MAC_VALID  : integer := 3081;  -- 0x6048 >> 3
   constant WORD_ERXHEAD    : integer := 3078;  -- 0x6030 >> 3
   constant WORD_TX_SRC     : integer := 0;     -- byte offset 0x0000
   constant WORD_RX_DST     : integer := 512;   -- byte offset 0x1000

   procedure ddr_write(idx : in integer;
                        data : in std_logic_vector(63 downto 0);
                        signal p_idx : out integer;
                        signal p_data : out std_logic_vector(63 downto 0);
                        signal p_valid : out std_logic;
                        signal clk : in std_logic) is
   begin
      p_idx <= idx;
      p_data <= data;
      wait until clk'event and clk = '1';
      p_valid <= '1';
      wait until clk'event and clk = '1';
      p_valid <= '0';
   end procedure;

begin

   cpuclk <= not cpuclk after 50 ns when not sim_done else '0';  -- 10MHz, matches cpuclk's documented rate
   nclk <= not cpuclk;
   clk50mhz_sig <= not clk50mhz_sig after 10 ns when not sim_done else '0';
   reset <= '1', '0' after 500 ns;
   npg <= '1';  -- constant grant -- no bus arbitration contention in this test

   ----------------------------------------------------------------------
   -- "main memory" model for xubl0's DMA master interface -- combinational
   -- read (zero wait state, matching xubl.vhd's own back-to-back word
   -- fetch assumption), registered write.
   ----------------------------------------------------------------------
   bus_master_dati <= mem(conv_integer(bus_master_addr(6 downto 1)));

   -- single driver for mem -- both DMA write-back and testbench preload
   -- go through this one process to avoid an unintended second driver
   -- (a real testbench bug found this session: a separate preload
   -- process racing this one produced std_logic resolution 'X's on
   -- every bit where the two drivers' held values disagreed).
   process(cpuclk)
      variable idx : integer;
   begin
      if cpuclk'event and cpuclk = '1' then
         if preload_valid = '1' then
            mem(preload_idx) <= preload_data;
         elsif bus_master_control_dato = '1' then
            idx := conv_integer(bus_master_addr(6 downto 1));
            mem(idx) <= bus_master_dato;
         end if;
      end if;
   end process;

   ----------------------------------------------------------------------
   -- DDR3 mailbox RAM model (same as tb_shim.vhd)
   ----------------------------------------------------------------------
   process(DDRAM_CLK)
      variable idx : integer;
   begin
      if DDRAM_CLK'event and DDRAM_CLK = '1' then
         DDRAM_BUSY <= '0';
         DDRAM_DOUT_READY <= '0';
         if ddr_preload_valid = '1' then
            ddr_ram(ddr_preload_idx) <= ddr_preload_data;
         elsif DDRAM_WE = '1' then
            idx := conv_integer(DDRAM_ADDR(12 downto 0));
            for b in 0 to 7 loop
               if DDRAM_BE(b) = '1' then
                  ddr_ram(idx)(b*8+7 downto b*8) <= DDRAM_DIN(b*8+7 downto b*8);
               end if;
            end loop;
         elsif DDRAM_RD = '1' then
            idx := conv_integer(DDRAM_ADDR(12 downto 0));
            DDRAM_DOUT(63 downto 0) <= ddr_ram(idx);
            DDRAM_DOUT_READY <= '1';
         end if;
      end if;
   end process;

   ----------------------------------------------------------------------
   -- fake daemon: simulation-only stand-in for Phase 3's real ARM-side
   -- daemon. Watches TXRTS_REQ; on seeing it, "transmits" by copying the
   -- TX buffer word-for-word to a fixed RX destination word (loopback --
   -- both this test's TX and RX addresses are deliberately chosen
   -- 8-byte-aligned so a single whole-word copy is byte-exact, avoiding
   -- needing a general byte-level copy loop in test code), advances
   -- ERXHEAD by 1 (one more frame enqueued), and sets TXRTS_DONE --
   -- exactly the real daemon's eventual job, per the offset table
   -- (DDR_TXRTS_REQ/DONE word indices: byte offset >> 3).
   ----------------------------------------------------------------------
   process
      variable l : line;
      variable erxhead_count : integer := 0;
   begin
      -- one-time MAC publish, mimicking xu_start(). Deliberately
      -- distinguishable from PLACEHOLDER_MAC (08:00:2B:11:22:33 vs
      -- PLACEHOLDER_MAC's AA bytes) so the shim's background MAC poll
      -- picking it up is unambiguous.
      wait until reset = '0';
      wait for 1000 ns;
      ddr_write(WORD_MAC_ADDR, x"0000332211" & x"2B0008", ddr_preload_idx, ddr_preload_data, ddr_preload_valid, clk50mhz_sig);
      ddr_write(WORD_MAC_VALID, x"0000000000000001", ddr_preload_idx, ddr_preload_data, ddr_preload_valid, clk50mhz_sig);

      loop
         wait until ddr_ram(WORD_TXRTS_REQ)(0) = '1';
         report "DBG fake-daemon saw TXRTS_REQ, looping back TX->RX at t=" & time'image(now);
         ddr_write(WORD_RX_DST, ddr_ram(WORD_TX_SRC), ddr_preload_idx, ddr_preload_data, ddr_preload_valid, clk50mhz_sig);
         erxhead_count := erxhead_count + 1;
         ddr_write(WORD_ERXHEAD, conv_std_logic_vector(erxhead_count, 64), ddr_preload_idx, ddr_preload_data, ddr_preload_valid, clk50mhz_sig);
         ddr_write(WORD_TXRTS_DONE, x"0000000000000001", ddr_preload_idx, ddr_preload_data, ddr_preload_valid, clk50mhz_sig);
         write(l, string'("DBG fake-daemon: erxhead now ") & integer'image(erxhead_count));
         writeline(output, l);
         wait until ddr_ram(WORD_TXRTS_REQ)(0) = '0';
         -- daemon clears TXRTS_DONE itself once it sees the shim withdraw
         -- TXRTS_REQ, completing the handshake -- see the offset table's
         -- own held-not-pulsed design.
         ddr_write(WORD_TXRTS_DONE, x"0000000000000000", ddr_preload_idx, ddr_preload_data, ddr_preload_valid, clk50mhz_sig);
      end loop;
   end process;

   ----------------------------------------------------------------------
   -- DUTs: real xubl.vhd (unmodified) as master, real shim as slave
   ----------------------------------------------------------------------
   xubl0: entity work.xubl
   port map(
      base_addr => BASE_ADDR,
      npr => npr,
      npg => npg,
      bus_addr_match => bus_addr_match,
      bus_addr => bus_addr,
      bus_dati => bus_dati,
      bus_dato => bus_dato,
      bus_control_dati => bus_control_dati,
      bus_control_dato => bus_control_dato,
      bus_control_datob => bus_control_datob,
      bus_master_addr => bus_master_addr,
      bus_master_dati => bus_master_dati,
      bus_master_dato => bus_master_dato,
      bus_master_control_dati => bus_master_control_dati,
      bus_master_control_dato => bus_master_control_dato,
      bus_master_nxm => bus_master_nxm,
      xu_cs => xu_cs,
      xu_mosi => xu_mosi,
      xu_sclk => xu_sclk,
      xu_miso => xu_miso,
      reset => reset,
      xublclk => cpuclk,
      clk => nclk
   );

   shim: entity work.xu_enc424j600_shim
   port map(
      reset => reset,
      cpuclk => cpuclk,
      xu_cs => xu_cs,
      xu_mosi => xu_mosi,
      xu_sclk => xu_sclk,
      xu_miso => xu_miso,
      req_valid => req_valid,
      req_addr => req_addr,
      req_wdata => req_wdata,
      req_be => req_be,
      req_rw => req_rw,
      req_ack => req_ack,
      resp_valid => resp_valid,
      resp_rdata => resp_rdata
   );

   mailbox: entity work.xu_ddr_mailbox
   port map(
      reset => reset,
      cpuclk => cpuclk,
      req_valid => req_valid,
      req_addr => req_addr,
      req_wdata => req_wdata,
      req_be => req_be,
      req_rw => req_rw,
      req_ack => req_ack,
      resp_valid => resp_valid,
      resp_rdata => resp_rdata,
      clk50mhz => clk50mhz_sig,
      DDRAM_CLK => DDRAM_CLK,
      DDRAM_BUSY => DDRAM_BUSY,
      DDRAM_BURSTCNT => DDRAM_BURSTCNT,
      DDRAM_ADDR => DDRAM_ADDR,
      DDRAM_DOUT => DDRAM_DOUT,
      DDRAM_DOUT_READY => DDRAM_DOUT_READY,
      DDRAM_RD => DDRAM_RD,
      DDRAM_DIN => DDRAM_DIN,
      DDRAM_BE => DDRAM_BE,
      DDRAM_WE => DDRAM_WE
   );

   ----------------------------------------------------------------------
   -- main test sequence -- programs xubl0 exactly as roms/xubrt45.mac's
   -- real "xubl:" stub does (mov 0(r5),@#177000 [xf]; 4(r5),@#177004
   -- [rt]; 6(r5),@#177006 [rl]; 2(r5),@#177002 [xl, LAST -- triggers run]),
   -- using the real chkeudast + initenc 20$/30$ byte patterns.
   ----------------------------------------------------------------------
   process
      variable l : line;
      variable idx : integer;
      variable readback : std_logic_vector(15 downto 0);
   begin
      wait until reset = '0';
      wait for 500 ns;

      ------------------------------------------------------------------
      -- xecon1: bfsu,econ1,1,0 -- enable RXEN (real firmware template,
      -- roms/xubrt45.mac; also enables this shim's own background
      -- ERXHEAD poll, gated on econ1_rxen).
      ------------------------------------------------------------------
      preload(0, x"1E24", preload_idx, preload_data, preload_valid, cpuclk);  -- econ1(0x1E)<<8 | bfsu(0x24)
      preload(1, x"0001", preload_idx, preload_data, preload_valid, cpuclk);  -- mask: bit0 (RXEN)
      wait for 20 ns;
      prog_write("000", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      ------------------------------------------------------------------
      -- WGPDATA: write 4 TX bytes (0x11,0x22,0x33,0x44) at egpwrpt's
      -- reset default (byte offset 0x0000) -- same pattern already
      -- proven in tb_shim_stream.vhd.
      ------------------------------------------------------------------
      preload(10, x"2AC0", preload_idx, preload_data, preload_valid, cpuclk);  -- wgpdata(0x2A)<<8 | b0sel(0xC0)
      preload(11, x"2211", preload_idx, preload_data, preload_valid, cpuclk);
      preload(12, x"4433", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"0014", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 10 (byte 20)
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0030", bus_addr, bus_dato, bus_control_dato, nclk);  -- 48 bits (6 bytes)
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      ------------------------------------------------------------------
      -- wetxst: wcru,etxst,0,0 (transmit start = byte offset 0)
      ------------------------------------------------------------------
      preload(15, x"0022", preload_idx, preload_data, preload_valid, cpuclk);  -- etxst(0x00)<<8 | wcru(0x22)
      preload(16, x"0000", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"001E", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 15 (byte 30)
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      ------------------------------------------------------------------
      -- wetxlen: wcru,etxlen,4,0 (transmit length = 4 bytes)
      ------------------------------------------------------------------
      preload(18, x"0222", preload_idx, preload_data, preload_valid, cpuclk);  -- etxlen(0x02)<<8 | wcru(0x22)
      preload(19, x"0004", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"0024", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 18 (byte 36)
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      ------------------------------------------------------------------
      -- tecon1: bfsu,econ1,2,0 -- set TXRTS, triggers the fake daemon's
      -- loopback (real firmware template, roms/xubrt45.mac line ~885).
      ------------------------------------------------------------------
      preload(20, x"1E24", preload_idx, preload_data, preload_valid, cpuclk);  -- econ1(0x1E)<<8 | bfsu(0x24)
      preload(21, x"0002", preload_idx, preload_data, preload_valid, cpuclk);  -- mask: bit1 (TXRTS)
      wait for 20 ns;
      prog_write("000", x"0028", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 20 (byte 40)
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;

      -- let the full round trip settle: fake daemon sees TXRTS_REQ, loops
      -- back TX->RX, sets TXRTS_DONE; shim's own background poll (gated
      -- by BG_POLL_PERIOD, throttled deliberately) has to see DONE and
      -- clear econ1_txrts before its SEPARATE ERXHEAD poll (gated on
      -- econ1_rxen, mutually exclusive priority with the TXRTS_DONE poll)
      -- ever gets a turn -- two full poll periods, worst case.
      -- MAC_VALID/MAC_ADDR polling now takes priority over ERXHEAD (real
      -- fix, 2026-08-28: see xu_enc424j600_shim.vhd's own comment), so
      -- both those poll periods complete before ERXHEAD polling even
      -- gets a turn -- budget for that, not just one period.
      wait for 40 ms;

      ------------------------------------------------------------------
      -- restat: rcru,estat -- expect PKTCNT<7:0>=1 (one frame enqueued
      -- by the fake daemon, nothing delivered/decremented yet).
      ------------------------------------------------------------------
      preload(30, x"1A20", preload_idx, preload_data, preload_valid, cpuclk);  -- estat(0x1A)<<8 | rcru(0x20)
      preload(34, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"003C", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 30 (byte 60)
      prog_write("010", x"0044", bus_addr, bus_dato, bus_control_dato, nclk);  -- rt = word addr 34 (byte 68)
      prog_write("011", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      write(l, string'("restat (before SETPKTDEC) readback: 0x"));
      hwrite(l, mem(34));
      write(l, string'(" (expected PKTCNT=1, i.e. low byte 0x01)"));
      writeline(output, l);
      if mem(34)(7 downto 0) = x"01" then
         write(l, string'("PASS pktcnt-after-loopback (real xubl.vhd master)"));
      else
         write(l, string'("FAIL pktcnt-after-loopback (real xubl.vhd master)"));
      end if;
      writeline(output, l);

      ------------------------------------------------------------------
      -- rdata: b0sel,rrxdata -- read back the looped-back frame, expect
      -- the same 4 bytes written via WGPDATA (0x11,0x22,0x33,0x44).
      ------------------------------------------------------------------
      preload(40, x"2CC0", preload_idx, preload_data, preload_valid, cpuclk);  -- rrxdata(0x2C)<<8 | b0sel(0xC0)
      preload(50, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      preload(51, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"0050", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 40 (byte 80)
      prog_write("010", x"0064", bus_addr, bus_dato, bus_control_dato, nclk);  -- rt = word addr 50 (byte 100)
      prog_write("011", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);  -- rl = 32 bits
      prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      write(l, string'("rdata (loopback) readback: 0x"));
      hwrite(l, mem(50));
      hwrite(l, mem(51));
      write(l, string'(" (expected 0x22114433)"));
      writeline(output, l);
      if mem(50) = x"2211" and mem(51) = x"4433" then
         write(l, string'("PASS loopback-rx-content (real xubl.vhd master)"));
      else
         write(l, string'("FAIL loopback-rx-content (real xubl.vhd master)"));
      end if;
      writeline(output, l);

      ------------------------------------------------------------------
      -- decpc: b0sel,setpktdec -- one frame delivered/processed
      ------------------------------------------------------------------
      preload(60, x"CCC0", preload_idx, preload_data, preload_valid, cpuclk);  -- setpktdec(0xCC)<<8 | b0sel(0xC0)
      wait for 20 ns;
      prog_write("000", x"0078", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 60 (byte 120)
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      ------------------------------------------------------------------
      -- restat again -- expect PKTCNT<7:0>=0 now
      ------------------------------------------------------------------
      preload(55, x"1A20", preload_idx, preload_data, preload_valid, cpuclk);  -- estat(0x1A)<<8 | rcru(0x20)
      preload(56, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"006E", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 55 (byte 110)
      prog_write("010", x"0070", bus_addr, bus_dato, bus_control_dato, nclk);  -- rt = word addr 56 (byte 112)
      prog_write("011", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      write(l, string'("restat (after SETPKTDEC) readback: 0x"));
      hwrite(l, mem(56));
      write(l, string'(" (expected PKTCNT=0)"));
      writeline(output, l);
      if mem(56)(7 downto 0) = x"00" then
         write(l, string'("PASS pktcnt-after-setpktdec (real xubl.vhd master)"));
      else
         write(l, string'("FAIL pktcnt-after-setpktdec (real xubl.vhd master)"));
      end if;
      writeline(output, l);

      ------------------------------------------------------------------
      -- rbia: rcru,maadr3 -- confirm the shim now presents the fake
      -- daemon's published MAC (08:00:2B:11:22:33) instead of the
      -- PLACEHOLDER_MAC fallback.
      ------------------------------------------------------------------
      preload(6, x"6020", preload_idx, preload_data, preload_valid, cpuclk);  -- maadr3(0x60)<<8 | rcru(0x20)
      preload(61, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      preload(62, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      preload(63, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"000C", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 6 (byte 12)
      prog_write("010", x"007A", bus_addr, bus_dato, bus_control_dato, nclk);  -- rt = word addr 61 (byte 122)
      prog_write("011", x"0030", bus_addr, bus_dato, bus_control_dato, nclk);  -- rl = 48 bits
      prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      write(l, string'("rbia (daemon-published MAC) readback: 0x"));
      hwrite(l, mem(61));
      hwrite(l, mem(62));
      hwrite(l, mem(63));
      write(l, string'(" (expected words 0x0008 0x112B 0x3322)"));
      writeline(output, l);
      if mem(61) = x"0008" and mem(62) = x"112B" and mem(63) = x"3322" then
         write(l, string'("PASS mac-publish (real xubl.vhd master)"));
      else
         write(l, string'("FAIL mac-publish (real xubl.vhd master)"));
      end if;
      writeline(output, l);

      wait for 500 ns;
      sim_done <= true;
      wait;
   end process;

end sim;
