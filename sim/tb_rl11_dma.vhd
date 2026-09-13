-- deps: rl11.vhd
--
-- tb_rl11_dma.vhd -- does an RL11 READ/WRITE land the right words at the
-- right memory addresses under the packed-sector addressing, over the
-- real native hps_io sd_* transport (Phase 3 of the disk-transport plan,
-- same pattern as tb_rh11_dma.vhd/tb_rk11_dma.vhd's Phase 1/2 rewrites)?
--
-- Real RL02 sectors are 128 (16-bit) words -- RL02 Technical
-- Description ("16 bit words per sector: 128"; "this track contains 40
-- sectors of 128 words each") -- half of a 512-byte SD block. sd_addr
-- packs two real sectors per SD block (index>>1) instead of every real
-- sector wasting/padding a whole block. This drives the real rl11.vhd
-- with a behavioural hps_io that serves an identifiable pattern -- word
-- K of SD block B = (B+1)*010000 + K -- over rl11's real native sd_*
-- ports and checks:
--   * reading real sector 0 (even -> block 0, first half) gets
--     the FIRST 128 words of block 0
--   * reading real sector 1 (odd -> block 0, second half) gets
--     the SECOND 128 words of the SAME block 0 -- not block 1
--   * a single READ spanning sectors 0+1 (256 words, one command)
--     gets both halves correctly and in order
--   * writing the ODD real sector lands in the second half of the SAME
--     SD block, without disturbing the EVEN sibling sector (the
--     historical 830a839 bug class)
--
-- Uses cylinder 0 / head 0 throughout, matching dnca/dnhs's reset
-- default, so no seek is needed before issuing the read command.
--
-- The hps_io mock runs on its own clk_100 clock (genuinely different from
-- clk/cpuclk) specifically to exercise the real Gray-coded CDC bridge in
-- rl11.vhd, not just its combinational logic on one shared clock.
--
-- Run:  sim/run_sim.sh tb_rl11_dma --stop-time=4ms

------------------------------------------------------------------------
-- the testbench proper
------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_rl11_dma is
end tb_rl11_dma;

architecture sim of tb_rl11_dma is
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

   type mem_t is array(0 to 65535) of integer;
   shared variable mem : mem_t := (others => -1);
   signal wr_count : integer := 0;

   -- backing store for "block 0" only (all this testbench's scenarios use)
   -- so a write's effect on both halves of the block can be checked by a
   -- later read -- initialized with the same identifiable pattern the old
   -- mock computed on the fly.
   type block_mem_t is array(0 to 255) of integer;
   function init_block0 return block_mem_t is
      variable m : block_mem_t;
   begin
      for k in 0 to 255 loop
         m(k) := 8#10000# + k;
      end loop;
      return m;
   end function;
   shared variable block0 : block_mem_t := init_block0;

   constant A_RLCS : std_logic_vector(17 downto 0) := o"774400";
   constant A_RLBA : std_logic_vector(17 downto 0) := o"774402";
   constant A_RLDA : std_logic_vector(17 downto 0) := o"774404";
   constant A_RLMP : std_logic_vector(17 downto 0) := o"774406";

   constant BA0 : integer := 8#4000#;    -- word address for DMA target

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

   dut : entity work.rl11
      port map(
         base_addr => o"774400", ivec => o"160",
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
         have_rl=>1, img_mounted=>1,
         -- Walking/alternating-bit pattern, not zero: this DMA test
         -- never checks trace_disk_par5/6 itself, but tying the input
         -- to zero would make a "stuck at zero" bug on that path
         -- indistinguishable from correct behavior if this test is
         -- ever extended to check it (see tb_mmu_rl11_par_stamp.vhd
         -- for the real end-to-end check of that path).
         trace_kdpar5=>x"AAAA", trace_kdpar6=>x"5555",
         trace_kipar5=>x"3333", trace_kipar6=>x"CCCC",
         reset=>reset, clk50mhz=>clk50, nclk=>nclk, clk=>clk
      );

   npg <= npr;

   -- behavioural hps_io: on sd_rd, ack after a short delay then stream
   -- 256 words of block 0's persistent backing store (or a synthetic
   -- pattern for any other block -- this test never touches one) via
   -- sd_buff_addr/sd_buff_dout/sd_buff_wr. On sd_wr, ack then walk
   -- sd_buff_addr 0..255 capturing sd_buff_din into block0 -- sd_buff_din
   -- is a REGISTERED read on rl11.vhd's own clk_100mhz side (one cycle
   -- of latency behind sd_buff_addr), so capture is one cycle behind the
   -- address drive throughout, with one extra cycle at the end to catch
   -- word 255. All on clk_100 (genuinely separate from rl11's own
   -- clk/cpuclk) to actually exercise the Gray-coded CDC bridge.
   process(clk_100)
      variable cur_block : integer := 0;
      variable phase : integer := 0;  -- 0=idle,1=acking,2=streaming,3=flush,4=drop
      variable addr : integer := 0;
      variable prev_addr : integer := 0;
      variable ack_delay : integer := 0;
      variable is_write : boolean := false;
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
                     is_write := false;
                     report "hps_io mock: read block " & integer'image(cur_block);
                     ack_delay := 5;
                     phase := 1;
                  elsif sd_wr = '1' then
                     cur_block := to_integer(unsigned(sd_lba));
                     is_write := true;
                     report "hps_io mock: write block " & integer'image(cur_block);
                     ack_delay := 5;
                     phase := 1;
                  end if;

               when 1 =>
                  if ack_delay > 0 then
                     ack_delay := ack_delay - 1;
                  else
                     sd_ack <= '1';
                     addr := 0;
                     prev_addr := 0;
                     sd_buff_addr <= std_logic_vector(to_unsigned(0, 9));
                     phase := 2;
                  end if;

               when 2 =>
                  if is_write then
                     -- capture the PREVIOUS address's now-valid sd_buff_din
                     -- (addr 0 has no valid data yet on the very first
                     -- cycle here, since sd_buff_addr=0 was only just
                     -- driven last cycle -- captured on the addr=1 pass
                     -- instead, matching the one-cycle registered lag)
                     if addr > 0 then
                        if cur_block = 0 then
                           block0(prev_addr) := to_integer(unsigned(sd_buff_din));
                        end if;
                        report "hps_io mock: write word addr=" & integer'image(prev_addr) &
                           " data=" & integer'image(to_integer(unsigned(sd_buff_din)));
                     end if;
                     prev_addr := addr;
                     if addr = 255 then
                        phase := 3;   -- one more capture needed for word 255
                     else
                        addr := addr + 1;
                        sd_buff_addr <= std_logic_vector(to_unsigned(addr, 9));
                     end if;
                  else
                     sd_buff_addr <= std_logic_vector(to_unsigned(addr, 9));
                     if cur_block = 0 then
                        sd_buff_dout <= std_logic_vector(to_unsigned(block0(addr), 16));
                     else
                        sd_buff_dout <= std_logic_vector(to_unsigned(
                           ((cur_block + 1) * 8#10000#) + addr, 16));
                     end if;
                     sd_buff_wr <= '1';
                     if addr = 255 then
                        phase := 3;
                     else
                        addr := addr + 1;
                     end if;
                  end if;

               when 3 =>
                  if is_write then
                     if cur_block = 0 then
                        block0(255) := to_integer(unsigned(sd_buff_din));
                     end if;
                     report "hps_io mock: write word addr=255 data=" &
                        integer'image(to_integer(unsigned(sd_buff_din)));
                  end if;
                  sd_buff_wr <= '0';
                  phase := 4;

               when 4 =>
                  sd_ack <= '0';
                  phase := 0;

               when others =>
                  phase := 0;
            end case;
         end if;
      end if;
   end process;

   process(clk)
      variable wa : integer;
   begin
      if rising_edge(clk) then
         if bm_cdato = '1' then
            wa := to_integer(unsigned(bm_addr(16 downto 1)));
            if wa >= 0 and wa <= 65535 then
               mem(wa) := to_integer(unsigned(bm_dato));
               wr_count <= wr_count + 1;
            end if;
         end if;
      end if;
   end process;

   -- host-memory source for an RL11 DMA WRITE (disk controller reads FROM
   -- host memory here, the mirror of the process above which handles DMA
   -- READs writing INTO host memory). Sensitive to bm_addr only (not clk)
   -- so it behaves as a combinational/async-read memory, matching the
   -- timing the DUT expects (bus_master_dati must already be valid the
   -- same cycle bus_master_addr becomes the new address). A shared
   -- variable can only be read from within a process, not a concurrent
   -- signal assignment, hence this process instead of a bare <= .
   -- mem(-1) sentinel (never explicitly written) reads back as 0 rather
   -- than erroring.
   process(bm_addr)
      variable wa : integer;
   begin
      wa := to_integer(unsigned(bm_addr(16 downto 1)));
      if mem(wa) >= 0 then
         bm_dati <= std_logic_vector(to_unsigned(mem(wa), 16));
      else
         bm_dati <= (others => '0');
      end if;
   end process;

   stim : process
      type scenario_t is record
         sector : integer;
         wc     : integer;
         name   : string(1 to 40);
      end record;
      type scenario_arr is array(0 to 2) of scenario_t;
      constant scenarios : scenario_arr := (
         (0, 128, "even sector 0 -> block 0 first half     "),
         (1, 128, "odd sector 1 -> block 0 second half     "),
         (0, 256, "spanning sectors 0+1 in one command     ")
      );
      variable cs1 : std_logic_vector(15 downto 0);
      variable i, want, got, bad, blk, base, sector, wc : integer;
      variable ok_all : boolean := true;
   begin
      wait until reset = '0';
      for k in 1 to 60 loop wait until rising_edge(clk); end loop;

      for s in scenarios'range loop
         sector := scenarios(s).sector;
         wc     := scenarios(s).wc;

         -- cyl 0, head 0 (matches dnca/dnhs's reset default -- no seek needed)
         bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLDA,
                std_logic_vector(to_unsigned(sector, 16)));
         bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLBA,
                std_logic_vector(to_unsigned(BA0*2, 16)));
         bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLMP,
                std_logic_vector(to_unsigned(8192 - wc, 16)));   -- 13-bit negated word count
         bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLCS, x"000D"); -- ds=00, fc=110 (read), go=1

         i := 0;
         loop
            bus_rd(bus_addr, bus_control_dati, A_RLCS, cs1);
            exit when cs1(7) = '1';
            i := i + 1;
            if i > 3000 then
               report "tb_rl11_dma [" & scenarios(s).name & "]: FAIL - read never completed (RLCS=" &
                  integer'image(to_integer(unsigned(cs1))) & ")" severity failure;
            end if;
         end loop;
         for k in 1 to 20 loop wait until rising_edge(clk); end loop;

         blk  := sector / 2;
         base := (sector mod 2) * 128;
         bad := 0;
         for i in 0 to wc-1 loop
            want := (blk + 1) * 8#10000# + base + i;
            got  := mem(BA0 + i);
            if got /= want then
               bad := bad + 1;
               if bad <= 6 then
                  report "  [" & scenarios(s).name & "] word " & integer'image(i) & " @ " &
                     integer'image(BA0+i) & " : got " & integer'image(got) &
                     " want " & integer'image(want) severity warning;
               end if;
            end if;
         end loop;

         if bad = 0 then
            report "tb_rl11_dma [" & scenarios(s).name & "]: PASS - all " & integer'image(wc) &
                   " words correct" severity note;
         else
            report "tb_rl11_dma [" & scenarios(s).name & "]: FAIL - " & integer'image(bad) & " of " &
                   integer'image(wc) & " words wrong" severity error;
            ok_all := false;
         end if;

         wait until rising_edge(clk);
      end loop;

      -- Write-path regression test: writing the ODD real sector (1) must
      -- land in the SECOND half (words 128-255) of shared SD block 0, and
      -- must NOT disturb the EVEN sector (0) sharing that block. Before
      -- the busmaster_write1 fix, every write started at address 0
      -- regardless of sd_half, so writing sector 1 corrupted sector 0's
      -- data instead, leaving sector 1 itself with stale/unwritten words.
      for i in 0 to 127 loop
         mem(BA0 + i) := 8#22000# + i;      -- pattern to write into sector 1
      end loop;
      wait until rising_edge(clk);

      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLDA,
             std_logic_vector(to_unsigned(1, 16)));           -- sector 1 (odd)
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLBA,
             std_logic_vector(to_unsigned(BA0*2, 16)));
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLMP,
             std_logic_vector(to_unsigned(8192 - 128, 16)));
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLCS, x"000B"); -- ds=00, fc=101 (write), go=1

      i := 0;
      loop
         bus_rd(bus_addr, bus_control_dati, A_RLCS, cs1);
         exit when cs1(7) = '1';
         i := i + 1;
         if i > 3000 then
            report "tb_rl11_dma [write sector 1]: FAIL - write never completed (RLCS=" &
               integer'image(to_integer(unsigned(cs1))) & ")" severity failure;
         end if;
      end loop;
      for k in 1 to 20 loop wait until rising_edge(clk); end loop;

      -- read sector 1 back (into a fresh area) -- must see the just-written pattern
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLDA,
             std_logic_vector(to_unsigned(1, 16)));
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLBA,
             std_logic_vector(to_unsigned((BA0+300)*2, 16)));
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLMP,
             std_logic_vector(to_unsigned(8192 - 128, 16)));
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLCS, x"000D");
      i := 0;
      loop
         bus_rd(bus_addr, bus_control_dati, A_RLCS, cs1);
         exit when cs1(7) = '1';
         i := i + 1;
         if i > 3000 then
            report "tb_rl11_dma [write sector 1]: FAIL - verify read never completed" severity failure;
         end if;
      end loop;
      for k in 1 to 20 loop wait until rising_edge(clk); end loop;

      bad := 0;
      for i in 0 to 127 loop
         want := 8#22000# + i;
         got  := mem(BA0 + 300 + i);
         if got /= want then
            bad := bad + 1;
            if bad <= 6 then
               report "  [write sector 1, readback] word " & integer'image(i) &
                  " : got " & integer'image(got) & " want " & integer'image(want) severity warning;
            end if;
         end if;
      end loop;
      if bad = 0 then
         report "tb_rl11_dma [write sector 1, readback]: PASS - all 128 words correct" severity note;
      else
         report "tb_rl11_dma [write sector 1, readback]: FAIL - " & integer'image(bad) &
                " of 128 words wrong" severity error;
         ok_all := false;
      end if;

      -- read sector 0 back (the EVEN sibling sector) -- must be UNCHANGED,
      -- still the original block0 init pattern, not corrupted by the
      -- sector-1 write above
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLDA,
             std_logic_vector(to_unsigned(0, 16)));
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLBA,
             std_logic_vector(to_unsigned((BA0+300)*2, 16)));
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLMP,
             std_logic_vector(to_unsigned(8192 - 128, 16)));
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLCS, x"000D");
      i := 0;
      loop
         bus_rd(bus_addr, bus_control_dati, A_RLCS, cs1);
         exit when cs1(7) = '1';
         i := i + 1;
         if i > 3000 then
            report "tb_rl11_dma [sector 0 unaffected]: FAIL - verify read never completed" severity failure;
         end if;
      end loop;
      for k in 1 to 20 loop wait until rising_edge(clk); end loop;

      bad := 0;
      for i in 0 to 127 loop
         want := 8#10000# + i;      -- original block0 init pattern, first half
         got  := mem(BA0 + 300 + i);
         if got /= want then
            bad := bad + 1;
            if bad <= 6 then
               report "  [sector 0 unaffected] word " & integer'image(i) &
                  " : got " & integer'image(got) & " want " & integer'image(want) severity warning;
            end if;
         end if;
      end loop;
      if bad = 0 then
         report "tb_rl11_dma [sector 0 unaffected]: PASS - even sibling sector untouched by odd-sector write" severity note;
      else
         report "tb_rl11_dma [sector 0 unaffected]: FAIL - " & integer'image(bad) &
                " of 128 words corrupted by the sector-1 write" severity error;
         ok_all := false;
      end if;

      -- Even-sector write regression: writing sector 0 (sd_half='0')
      -- starts busmaster_write1's sdcard_xfer_addr at 255, not 127 --
      -- the FIRST increment in busmaster_write (255+1) overflows
      -- "integer range 0 to 255" without the "mod 256" fix (found via
      -- this exact scenario, previously untested -- the sibling-sector
      -- write test above only ever exercised the ODD (start-at-127,
      -- never-overflows) case). Real hardware never saw this (binary
      -- wraparound is free there), but it's the same bug class as
      -- tb_rh11_write.vhd found in rh11.vhd's write path.
      for i in 0 to 127 loop
         mem(BA0 + i) := 8#33000# + i;
      end loop;
      wait until rising_edge(clk);

      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLDA,
             std_logic_vector(to_unsigned(0, 16)));           -- sector 0 (even)
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLBA,
             std_logic_vector(to_unsigned(BA0*2, 16)));
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLMP,
             std_logic_vector(to_unsigned(8192 - 128, 16)));
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLCS, x"000B"); -- ds=00, fc=101 (write), go=1

      i := 0;
      loop
         bus_rd(bus_addr, bus_control_dati, A_RLCS, cs1);
         exit when cs1(7) = '1';
         i := i + 1;
         if i > 3000 then
            report "tb_rl11_dma [write sector 0]: FAIL - write never completed (RLCS=" &
               integer'image(to_integer(unsigned(cs1))) & ")" severity failure;
         end if;
      end loop;
      for k in 1 to 20 loop wait until rising_edge(clk); end loop;

      -- read sector 0 back -- must see the just-written pattern
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLDA,
             std_logic_vector(to_unsigned(0, 16)));
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLBA,
             std_logic_vector(to_unsigned((BA0+300)*2, 16)));
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLMP,
             std_logic_vector(to_unsigned(8192 - 128, 16)));
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLCS, x"000D");
      i := 0;
      loop
         bus_rd(bus_addr, bus_control_dati, A_RLCS, cs1);
         exit when cs1(7) = '1';
         i := i + 1;
         if i > 3000 then
            report "tb_rl11_dma [write sector 0]: FAIL - verify read never completed" severity failure;
         end if;
      end loop;
      for k in 1 to 20 loop wait until rising_edge(clk); end loop;

      bad := 0;
      for i in 0 to 127 loop
         want := 8#33000# + i;
         got  := mem(BA0 + 300 + i);
         if got /= want then
            bad := bad + 1;
            if bad <= 6 then
               report "  [write sector 0, readback] word " & integer'image(i) &
                  " : got " & integer'image(got) & " want " & integer'image(want) severity warning;
            end if;
         end if;
      end loop;
      if bad = 0 then
         report "tb_rl11_dma [write sector 0, readback]: PASS - all 128 words correct" severity note;
      else
         report "tb_rl11_dma [write sector 0, readback]: FAIL - " & integer'image(bad) &
                " of 128 words wrong" severity error;
         ok_all := false;
      end if;

      if ok_all then
         report "tb_rl11_dma: ALL SCENARIOS PASSED" severity note;
      else
         report "tb_rl11_dma: SOME SCENARIOS FAILED" severity error;
      end if;

      sim_done <= true;
      wait;
   end process;

   guard : process
   begin
      wait for 4 ms;
      assert sim_done report "tb_rl11_dma: TIMEOUT" severity failure;
      std.env.stop;
   end process;
end sim;
