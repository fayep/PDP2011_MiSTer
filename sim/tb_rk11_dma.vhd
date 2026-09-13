-- deps: rk11.vhd
--
-- tb_rk11_dma.vhd -- does an RK11 multi-sector READ land the right words
-- at the right memory addresses over the native hps_io sd_* transport?
--
-- Phase 2 of the disk-transport plan (same pattern as tb_rh11_dma.vhd's
-- Phase 1 rewrite validation): drives the real rk11.vhd with a
-- behavioural hps_io that serves an identifiable pattern -- word K of RK
-- block B = (B+1)*04000 + K -- over rk11's real native sd_* ports and a
-- bus-master memory model that records every DMA write. After a 2-sector
-- (512-word) READ:
--   * every word BA+2*i must hold block/offset for logical word i
--   * sector 2 must NOT overwrite sector 1 (rkba must advance)
--   * nothing outside [BA, BA+2*512) is written
--
-- The hps_io mock runs on its own clk_100 clock (genuinely different from
-- clk/cpuclk) specifically to exercise the real Gray-coded CDC bridge in
-- rk11.vhd, not just its combinational logic on one shared clock.
--
-- Run:  sim/run_sim.sh tb_rk11_dma --stop-time=4ms

------------------------------------------------------------------------
-- the testbench proper
------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_rk11_dma is
end tb_rk11_dma;

architecture sim of tb_rk11_dma is
   signal clk, nclk, clk50, clk_100, reset : std_logic := '0';
   signal sim_done : boolean := false;

   signal bus_addr        : std_logic_vector(17 downto 0) := (others => '0');
   signal bus_dato        : std_logic_vector(15 downto 0) := (others => '0');
   signal bus_dati        : std_logic_vector(15 downto 0);
   signal bus_addr_match  : std_logic;
   signal bus_control_dati, bus_control_dato, bus_control_datob : std_logic := '0';

   signal br, bg, npr, npg : std_logic := '0';
   signal int_vector : std_logic_vector(8 downto 0);

   signal bm_addr  : std_logic_vector(17 downto 0);
   signal bm_dati  : std_logic_vector(15 downto 0) := (others => '0');
   signal bm_dato  : std_logic_vector(15 downto 0);
   signal bm_cdati, bm_cdato : std_logic;
   signal bm_nxm : std_logic := '0';

   -- native hps_io sd_* interface (replaces sd_cs/mosi/sclk/dbg)
   signal sd_lba : std_logic_vector(31 downto 0);
   signal sd_rd, sd_wr, sd_ack : std_logic := '0';
   signal sd_buff_addr : std_logic_vector(8 downto 0) := (others => '0');
   signal sd_buff_dout : std_logic_vector(15 downto 0) := (others => '0');
   signal sd_buff_din : std_logic_vector(15 downto 0);
   signal sd_buff_wr : std_logic := '0';

   -- 128 KW memory model (18-bit word addr, we only use low range)
   type mem_t is array(0 to 131071) of integer;
   signal mem : mem_t := (others => -1);          -- -1 == never written
   signal wr_lo, wr_hi : integer := -1;
   signal wr_count : integer := 0;

   constant A_RKCS : std_logic_vector(17 downto 0) := o"777404";
   constant A_RKWC : std_logic_vector(17 downto 0) := o"777406";
   constant A_RKBA : std_logic_vector(17 downto 0) := o"777410";
   constant A_RKDA : std_logic_vector(17 downto 0) := o"777412";

   constant BA0   : integer := 8#20000#;          -- word 0o10000, byte 0o20000
   constant NW    : integer := 512;               -- 2 RK sectors

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
   clk     <= not clk     after 50 ns when not sim_done else '0';
   nclk    <= not clk;
   clk50   <= not clk50   after 10 ns when not sim_done else '0';
   clk_100 <= not clk_100 after 5 ns  when not sim_done else '0';
   reset   <= '1', '0' after 700 ns;

   dut : entity work.rk11
      port map(
         base_addr => o"777400", ivec => o"220",
         br=>br, bg=>bg, int_vector=>int_vector, npr=>npr, npg=>npg,
         bus_addr_match=>bus_addr_match, bus_addr=>bus_addr,
         bus_dati=>bus_dati, bus_dato=>bus_dato,
         bus_control_dati=>bus_control_dati, bus_control_dato=>bus_control_dato,
         bus_control_datob=>bus_control_datob,
         bus_master_addr=>bm_addr, bus_master_dati=>bm_dati, bus_master_dato=>bm_dato,
         bus_master_control_dati=>bm_cdati, bus_master_control_dato=>bm_cdato,
         bus_master_nxm=>bm_nxm,
         sd_lba=>sd_lba, sd_rd=>sd_rd, sd_wr=>sd_wr, sd_ack=>sd_ack,
         sd_buff_addr=>sd_buff_addr, sd_buff_dout=>sd_buff_dout,
         sd_buff_din=>sd_buff_din, sd_buff_wr=>sd_buff_wr,
         clk_100mhz=>clk_100,
         have_rk=>1, have_rk_num=>8, img_mounted=>1,
         reset=>reset, clk50mhz=>clk50, nclk=>nclk, clk=>clk
      );

   -- grant NPR immediately whenever requested
   npg <= npr;

   -- behavioural hps_io: on sd_rd, ack after a short delay then stream
   -- 256 words of an identifiable pattern, via sd_buff_addr/sd_buff_dout/
   -- sd_buff_wr, all on clk_100 (genuinely separate from rk11's own
   -- clk/cpuclk) to actually exercise the Gray-coded CDC bridge rather
   -- than just its logic. Same phase-3 flush-wait fix as tb_rh11_dma.vhd
   -- (word 255's write only commits on the NEXT clk_100 edge -- do not
   -- drop sd_ack in the same cycle as the last sd_buff_wr pulse).
   process(clk_100)
      variable cur_block : integer := 0;
      variable phase : integer := 0;  -- 0=idle, 1=acking, 2=streaming, 3=flush-wait
      variable addr : integer := 0;
      variable ack_delay : integer := 0;
   begin
      if rising_edge(clk_100) then
         if reset = '1' then
            phase := 0; sd_ack <= '0'; sd_buff_wr <= '0';
         else
            case phase is
               when 0 =>
                  sd_ack <= '0';
                  if sd_rd = '1' then
                     cur_block := to_integer(unsigned(sd_lba));
                     report "hps_io mock: read block " & integer'image(cur_block);
                     ack_delay := 5;
                     phase := 1;
                  end if;

               when 1 =>
                  if ack_delay > 0 then
                     ack_delay := ack_delay - 1;
                  else
                     sd_ack <= '1';
                     addr := 0;
                     phase := 2;
                  end if;

               when 2 =>
                  sd_buff_addr <= std_logic_vector(to_unsigned(addr, 9));
                  sd_buff_dout <= std_logic_vector(to_unsigned(
                     ((cur_block + 1) * 8#4000#) + addr, 16));
                  sd_buff_wr <= '1';
                  if addr = 255 then
                     phase := 3;
                  else
                     addr := addr + 1;
                  end if;

               when 3 =>
                  sd_buff_wr <= '0';
                  sd_ack <= '0';
                  phase := 0;

               when others =>
                  phase := 0;
            end case;
         end if;
      end if;
   end process;

   -- bus-master memory: capture every DMA write
   process(clk)
      variable wa : integer;
   begin
      if rising_edge(clk) then
         if bm_cdato = '1' then
            wa := to_integer(unsigned(bm_addr(17 downto 1)));
            if wa >= 0 and wa <= 131071 then
               mem(wa) <= to_integer(unsigned(bm_dato));
               wr_count <= wr_count + 1;
               if wr_lo = -1 or wa < wr_lo then wr_lo <= wa; end if;
               if wa > wr_hi then wr_hi <= wa; end if;
            end if;
         end if;
      end if;
   end process;

   stim : process
      variable rkcs : std_logic_vector(15 downto 0);
      variable i, want, got, bad : integer;
   begin
      wait until reset = '0';
      for k in 1 to 60 loop wait until rising_edge(clk); end loop;

      -- program the transfer: drive 0, cyl 0, head 0, sector 0, BA0, WC = -512
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RKDA, x"0000");
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RKBA,
             std_logic_vector(to_unsigned(BA0*2, 16)));         -- byte address
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RKWC,
             std_logic_vector(to_unsigned(65536 - NW, 16)));    -- -512
      -- READ + GO : fu "010" & GO = 0o5
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RKCS, x"0005");

      -- wait for RDY (RKCS bit 7), up to ~30000 clk
      i := 0;
      loop
         bus_rd(bus_addr, bus_control_dati, A_RKCS, rkcs);
         exit when rkcs(7) = '1';
         i := i + 1;
         if i > 3000 then
            report "tb_rk11_dma: FAIL - read never completed (RKCS=" &
               integer'image(to_integer(unsigned(rkcs))) & ")" severity failure;
         end if;
      end loop;
      for k in 1 to 40 loop wait until rising_edge(clk); end loop;

      report "read done.  RKCS=" & integer'image(to_integer(unsigned(rkcs))) &
             "  DMA writes=" & integer'image(wr_count) &
             "  addr range word " & integer'image(wr_lo) & ".." & integer'image(wr_hi);

      -- check every word
      bad := 0;
      for i in 0 to NW-1 loop
         -- logical word i is in RK block (i/256), offset (i mod 256)
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
         report "tb_rk11_dma: PASS - all " & integer'image(NW) &
                " words landed correctly" severity note;
      else
         report "tb_rk11_dma: FAIL - " & integer'image(bad) & " of " &
                integer'image(NW) & " words wrong" severity error;
         null;
      end if;

      -- writes must be confined to [BA0, BA0+NW)
      if wr_lo /= BA0 or wr_hi /= BA0 + NW - 1 then
         report "tb_rk11_dma: FAIL - DMA touched word " & integer'image(wr_lo) &
                ".." & integer'image(wr_hi) & ", expected " &
                integer'image(BA0) & ".." & integer'image(BA0+NW-1)
                severity error;
         null;
      end if;
      if wr_count /= NW then
         report "tb_rk11_dma: NOTE - " & integer'image(wr_count) &
                " DMA writes for " & integer'image(NW) & " words (overwrite?)"
                severity warning;
      end if;

      sim_done <= true;
      wait;
   end process;

   guard : process
   begin
      wait for 4 ms;
      assert sim_done report "tb_rk11_dma: TIMEOUT" severity failure;
      std.env.stop;
   end process;
end sim;
