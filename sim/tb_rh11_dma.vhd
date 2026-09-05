-- deps: sdspi.vhd rh11.vhd
--
-- tb_rh11_dma.vhd -- does an RH70 multi-sector READ DATA land the right
-- words at the right memory addresses?
--
-- RSTS/E V10.1 hangs polling for a disk read that "finished" (CS1 RDY set,
-- WC=0, no error) but the data never arrived in memory (checked on hardware:
-- the DMA target was all zeros).  This drives the real rh11.vhd (have_rh70=1,
-- RP06) with a behavioural sdspi that serves an identifiable pattern -
-- word K of RP block B = (B+1)*04000 + K - and a bus-master memory model
-- that records every rh70 DMA write.  After a 2-sector (512-word) READ:
--   * every word BA+2*i must hold block/offset for logical word i
--   * sector 2 must NOT overwrite sector 1 (work_bar must advance)
--   * nothing outside [BA, BA+2*512) is written
--   * the block numbers rh11 asked sdspi for are N, N+1
--
-- Run:  sim/run_sim.sh tb_rh11_dma --stop-time=4ms

------------------------------------------------------------------------
-- behavioural sdspi (bound in place of the real one: -- deps: analyses
-- sdspi.vhd first, this file last, so rh11's sd1 binds here)
------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sdspi is
   port(
      sdcard_cs : out std_logic;
      sdcard_mosi : out std_logic;
      sdcard_sclk : out std_logic;
      sdcard_miso : in std_logic := '0';
      sdcard_debug : out std_logic_vector(3 downto 0);
      sdcard_addr : in std_logic_vector(23 downto 0);
      sdcard_idle : out std_logic;
      sdcard_read_start : in std_logic;
      sdcard_read_ack : in std_logic;
      sdcard_read_done : out std_logic;
      sdcard_write_start : in std_logic;
      sdcard_write_ack : in std_logic;
      sdcard_write_done : out std_logic;
      sdcard_error : out std_logic;
      sdcard_xfer_addr : in integer range 0 to 255;
      sdcard_xfer_read : in std_logic;
      sdcard_xfer_out : out std_logic_vector(15 downto 0);
      sdcard_xfer_write : in std_logic;
      sdcard_xfer_in : in std_logic_vector(15 downto 0);
      enable : in integer range 0 to 1 := 0;
      controller_clk : in std_logic;
      reset : in std_logic;
      clk50mhz : in std_logic
   );
end sdspi;

architecture mock of sdspi is
   signal cur_block : integer := 0;
   signal busy      : boolean := false;
   signal cnt       : integer := 0;
begin
   sdcard_cs <= '1'; sdcard_mosi <= '0'; sdcard_sclk <= '0';
   sdcard_debug <= "0000"; sdcard_error <= '0';
   sdcard_write_done <= '0';
   sdcard_idle <= '0' when busy else '1';

   process(controller_clk)
   begin
      if rising_edge(controller_clk) then
         -- real sdspi.vhd:155 registers xfer_out one controller_clk after
         -- xfer_addr; the rh11 busmaster_read1 pipeline stage compensates
         -- for exactly this latency, so the mock must match it.
         sdcard_xfer_out <= std_logic_vector(to_unsigned(
              ((cur_block + 1) * 8#4000#) + sdcard_xfer_addr, 16));
         if reset = '1' then
            busy <= false; cnt <= 0; sdcard_read_done <= '0';
         else
            if not busy then
               sdcard_read_done <= '0';
               if sdcard_read_start = '1' then
                  cur_block <= to_integer(unsigned(sdcard_addr));
                  report "sdspi: read block " & integer'image(to_integer(unsigned(sdcard_addr)));
                  busy <= true; cnt <= 0;
               end if;
            else
               cnt <= cnt + 1;
               if cnt = 20 then
                  sdcard_read_done <= '1';          -- data ready
               end if;
               if cnt >= 20 and sdcard_read_ack = '1' then
                  sdcard_read_done <= '0';
                  busy <= false;
               end if;
            end if;
         end if;
      end if;
   end process;
end mock;

------------------------------------------------------------------------
-- the testbench proper
------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_rh11_dma is
end tb_rh11_dma;

architecture sim of tb_rh11_dma is
   signal clk, nclk, clk50, reset : std_logic := '0';
   signal sim_done : boolean := false;

   signal bus_addr        : std_logic_vector(17 downto 0) := (others => '0');
   signal bus_dato        : std_logic_vector(15 downto 0) := (others => '0');
   signal bus_dati        : std_logic_vector(15 downto 0);
   signal bus_addr_match  : std_logic;
   signal bus_control_dati, bus_control_dato, bus_control_datob : std_logic := '0';

   signal br, bg, npr, npg : std_logic := '0';
   signal int_vector : std_logic_vector(8 downto 0);

   signal bm_addr  : std_logic_vector(17 downto 0);
   signal bm_dato  : std_logic_vector(15 downto 0);
   signal bm_cdati, bm_cdato : std_logic;
   signal bm_nxm : std_logic := '0';
   signal rh70_addr : std_logic_vector(21 downto 0);
   signal rh70_dato : std_logic_vector(15 downto 0);
   signal rh70_cdati, rh70_cdato : std_logic;
   signal rh70_dati : std_logic_vector(15 downto 0) := (others => '0');
   signal rh70_nxm : std_logic := '0';

   signal sd_cs, sd_mosi, sd_sclk : std_logic;
   signal sd_dbg : std_logic_vector(3 downto 0);

   -- 128 KW memory model (22-bit word addr, we only use low range)
   type mem_t is array(0 to 262143) of integer;
   signal mem : mem_t := (others => -1);          -- -1 == never written
   signal wr_lo, wr_hi : integer := -1;
   signal wr_count : integer := 0;

   constant A_CS1 : std_logic_vector(17 downto 0) := o"776700";
   constant A_WC  : std_logic_vector(17 downto 0) := o"776702";
   constant A_BA  : std_logic_vector(17 downto 0) := o"776704";
   constant A_DA  : std_logic_vector(17 downto 0) := o"776706";
   constant A_DC  : std_logic_vector(17 downto 0) := o"776734";
   constant A_BAE : std_logic_vector(17 downto 0) := o"776750";

   constant BA0   : integer := 8#20000#;          -- word 0o10000, byte 0o20000
   constant NW    : integer := 512;               -- 2 RP06 sectors

   signal fail : integer := 0;

   procedure bus_wr(signal a:out std_logic_vector(17 downto 0);
                    signal d:out std_logic_vector(15 downto 0);
                    signal c:out std_logic;
                    addr:std_logic_vector(17 downto 0);
                    data:std_logic_vector(15 downto 0)) is
   begin
      wait until rising_edge(clk);
      a<=addr; d<=data; c<='1';
      wait until rising_edge(clk);
      c<='0';
      wait until rising_edge(clk);
   end procedure;

   procedure bus_rd(signal a:out std_logic_vector(17 downto 0);
                    signal c:out std_logic;
                    addr:std_logic_vector(17 downto 0);
                    result:out std_logic_vector(15 downto 0)) is
   begin
      wait until rising_edge(clk);
      a<=addr; c<='1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      result:=bus_dati;
      c<='0';
      wait until rising_edge(clk);
   end procedure;
begin
   clk   <= not clk   after 50 ns when not sim_done else '0';
   nclk  <= not clk;
   clk50 <= not clk50 after 10 ns when not sim_done else '0';
   reset <= '1', '0' after 700 ns;

   dut : entity work.rh11
      port map(
         base_addr => o"776700", ivec => o"254",
         br=>br, bg=>bg, int_vector=>int_vector, npr=>npr, npg=>npg,
         bus_addr_match=>bus_addr_match, bus_addr=>bus_addr,
         bus_dati=>bus_dati, bus_dato=>bus_dato,
         bus_control_dati=>bus_control_dati, bus_control_dato=>bus_control_dato,
         bus_control_datob=>bus_control_datob,
         bus_master_addr=>bm_addr, bus_master_dato=>bm_dato,
         bus_master_control_dati=>bm_cdati, bus_master_control_dato=>bm_cdato,
         bus_master_nxm=>bm_nxm,
         rh70_bus_master_addr=>rh70_addr, rh70_bus_master_dati=>rh70_dati,
         rh70_bus_master_dato=>rh70_dato,
         rh70_bus_master_control_dati=>rh70_cdati,
         rh70_bus_master_control_dato=>rh70_cdato,
         rh70_bus_master_nxm=>rh70_nxm,
         sdcard_cs=>sd_cs, sdcard_mosi=>sd_mosi, sdcard_sclk=>sd_sclk,
         sdcard_miso=>'0', sdcard_debug=>sd_dbg,
         have_rh=>1, have_rh70=>1, rh_type=>6,
         reset=>reset, clk50mhz=>clk50, nclk=>nclk, clk=>clk
      );

   -- grant NPR immediately whenever requested
   npg <= npr;

   -- bus-master memory: capture every rh70 DMA write
   process(clk)
      variable wa : integer;
   begin
      if rising_edge(clk) then
         if rh70_cdato = '1' then
            wa := to_integer(unsigned(rh70_addr(21 downto 1)));
            if wa >= 0 and wa <= 262143 then
               mem(wa) <= to_integer(unsigned(rh70_dato));
               wr_count <= wr_count + 1;
               if wr_lo = -1 or wa < wr_lo then wr_lo <= wa; end if;
               if wa > wr_hi then wr_hi <= wa; end if;
            end if;
         end if;
      end if;
   end process;

   stim : process
      variable cs1 : std_logic_vector(15 downto 0);
      variable i, want, got, bad : integer;
   begin
      wait until reset = '0';
      for k in 1 to 60 loop wait until rising_edge(clk); end loop;

      -- pack acknowledge (fnc 01001 + GO = 0o23) so VV is set / drive ready
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_CS1, x"0013");
      for k in 1 to 40 loop wait until rising_edge(clk); end loop;

      -- program the transfer: block 0, BA0, BAE 0, WC = -512
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_DC,  x"0000");
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_DA,  x"0000");
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_BAE, x"0000");
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_BA,
             std_logic_vector(to_unsigned(BA0*2, 16)));         -- byte address
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_WC,
             std_logic_vector(to_unsigned(65536 - NW, 16)));    -- -512
      -- READ DATA + GO : fnc "11100" & GO = 0o71
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_CS1, x"0039");

      -- wait for RDY (CS1 bit 7), up to ~30000 clk
      i := 0;
      loop
         bus_rd(bus_addr, bus_control_dati, A_CS1, cs1);
         exit when cs1(7) = '1';
         i := i + 1;
         if i > 3000 then
            report "tb_rh11_dma: FAIL - read never completed (CS1=" &
               integer'image(to_integer(unsigned(cs1))) & ")" severity failure;
         end if;
      end loop;
      for k in 1 to 40 loop wait until rising_edge(clk); end loop;

      report "read done.  CS1=" & integer'image(to_integer(unsigned(cs1))) &
             "  DMA writes=" & integer'image(wr_count) &
             "  addr range word " & integer'image(wr_lo) & ".." & integer'image(wr_hi);

      -- check every word
      bad := 0;
      for i in 0 to NW-1 loop
         -- logical word i is in RP block (i/256), offset (i mod 256)
         want := ((i/256) + 1) * 8#4000# + (i mod 256);
         got  := mem(BA0 + i);
         if got /= want then
            bad := bad + 1;
            if bad <= 6 then
               report "  word " & integer'image(i) & " @ " &
                  integer'image(BA0+i) & " : got " & integer'image(got) &
                  " want " & integer'image(want) severity warning;
            end if;
         end if;
      end loop;

      if bad = 0 then
         report "tb_rh11_dma: PASS - all " & integer'image(NW) &
                " words landed correctly" severity note;
      else
         report "tb_rh11_dma: FAIL - " & integer'image(bad) & " of " &
                integer'image(NW) & " words wrong" severity error;
         null;
      end if;

      -- writes must be confined to [BA0, BA0+NW)
      if wr_lo /= BA0 or wr_hi /= BA0 + NW - 1 then
         report "tb_rh11_dma: FAIL - DMA touched word " & integer'image(wr_lo) &
                ".." & integer'image(wr_hi) & ", expected " &
                integer'image(BA0) & ".." & integer'image(BA0+NW-1)
                severity error;
         null;
      end if;
      if wr_count /= NW then
         report "tb_rh11_dma: NOTE - " & integer'image(wr_count) &
                " DMA writes for " & integer'image(NW) & " words (overwrite?)"
                severity warning;
      end if;

      sim_done <= true;
      wait;
   end process;

   guard : process
   begin
      wait for 4 ms;
      assert sim_done report "tb_rh11_dma: TIMEOUT" severity failure;
      std.env.stop;
   end process;
end sim;
