-- deps: mister_blkdev.vhd rk11.vhd
--
-- tb_rk11_blkdev.vhd -- GHDL harness for rtl/rh11.vhd on rtl/mister_blkdev.vhd
--
-- An RK05 on rk11 against a behavioural hps_io disk slot (sd_rd/sd_wr ->
-- sd_ack -> word-by-word sd_buff_* traffic with gaps) serving an in-memory
-- image. cpuclk 140 ns (clk/nclk) and clk_sys 10 ns are unrelated, so the
-- handshake synchronisers are exercised.
--
-- One RK05 sector is 256 words, one 512-byte block: drive 0, cylinder 0,
-- surface 0, sector s = block s. Checks: reads, full / short / multi-sector
-- writes (a short write zero-fills the rest of its sector), neighbouring
-- blocks untouched, read-back through the controller.
--
-- Run:  ghdl -a --std=08 -fsynopsys -frelaxed rtl/mister_blkdev.vhd rtl/rh11.vhd sim/tb_rk11_blkdev.vhd
--       ghdl -e --std=08 -fsynopsys -frelaxed tb_rk11_blkdev
--       ghdl -r --std=08 -fsynopsys -frelaxed tb_rk11_blkdev --stop-time=500ms --ieee-asserts=disable
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity tb_rk11_blkdev is
end tb_rk11_blkdev;

architecture sim of tb_rk11_blkdev is

   constant RK_BASE : std_logic_vector(17 downto 0) := o"777400";
   constant RKCS : std_logic_vector(2 downto 0) := "010";
   constant RKWC : std_logic_vector(2 downto 0) := "011";
   constant RKBA : std_logic_vector(2 downto 0) := "100";
   constant RKDA : std_logic_vector(2 downto 0) := "101";
   constant GO_WRITE : std_logic_vector(15 downto 0) := x"0003";      -- function 1 + GO
   constant GO_READ  : std_logic_vector(15 downto 0) := x"0005";      -- function 2 + GO

   constant NBLK : integer := 600;
   type block_t is array(0 to 255) of std_logic_vector(15 downto 0);
   type image_t is array(0 to NBLK-1) of block_t;

   function orig(b, w : integer) return std_logic_vector is
   begin
      return conv_std_logic_vector((b * 256 + w) * 11 + 16#05A5#, 16);
   end function;

   signal clk     : std_logic := '0';
   signal nclk    : std_logic := '1';
   signal clk_sys : std_logic := '0';
   signal reset   : std_logic := '1';
   signal img     : integer range 0 to 1 := 1;                  -- image mounted (drive online)

   signal b_addr  : std_logic_vector(17 downto 0) := (others => '0');
   signal b_dato  : std_logic_vector(15 downto 0) := (others => '0');
   signal b_dati  : std_logic_vector(15 downto 0);
   signal b_cdati : std_logic := '0';
   signal b_cdato : std_logic := '0';

   signal m_addr  : std_logic_vector(17 downto 0);
   signal m_dato, m_dati : std_logic_vector(15 downto 0);
   signal m_cdati, m_cdato : std_logic;
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
   signal tb_mem_we : std_logic := '0';
   signal tb_mem_addr : integer range 0 to 32767 := 0;
   signal tb_mem_data : std_logic_vector(15 downto 0) := (others => '0');

   signal image : image_t;
   signal img_init_done : boolean := false;
   signal sd_reads, sd_writes : integer := 0;

   signal fail_count : integer := 0;
   signal pass_count : integer := 0;

begin

   clk     <= not clk after 70 ns;
   nclk    <= not clk;
   clk_sys <= not clk_sys after 5 ns;
   npg     <= npr;

   dut: entity work.rk11 port map(
      base_addr => RK_BASE,
      ivec => o"220",
      br => open,
      bg => '0',
      int_vector => open,
      npr => npr,
      npg => npg,
      bus_addr_match => open,
      bus_addr => b_addr,
      bus_dati => b_dati,
      bus_dato => b_dato,
      bus_control_dati => b_cdati,
      bus_control_dato => b_cdato,
      bus_control_datob => '0',
      bus_master_addr => m_addr,
      bus_master_dati => m_dati,
      bus_master_dato => m_dato,
      bus_master_control_dati => m_cdati,
      bus_master_control_dato => m_cdato,
      bus_master_nxm => '0',
      sd_lba => sd_lba,
      sd_rd => sd_rd,
      sd_wr => sd_wr,
      sd_ack => sd_ack,
      sd_buff_addr => sd_buff_addr,
      sd_buff_dout => sd_buff_dout,
      sd_buff_din => sd_buff_din,
      sd_buff_wr => sd_buff_wr,
      clk_sys => clk_sys,
      have_rk => 1,
      img_mounted => img,
      have_rk_num => 1,
      reset => reset,
      clk50mhz => clk_sys,
      nclk => nclk,
      clk => clk
   );

   -- Unibus memory for NPR
   m_dati <= mem(conv_integer(m_addr(15 downto 1)));
   process(clk)
   begin
      if rising_edge(clk) then
         if m_cdato = '1' then
            mem(conv_integer(m_addr(15 downto 1))) <= m_dato;
         end if;
         if tb_mem_we = '1' then
            mem(tb_mem_addr) <= tb_mem_data;
         end if;
      end if;
   end process;

   -- behavioural hps_io disk slot (owns the image)
   hps: process
      variable blk : integer;
      variable is_wr : boolean;
   begin
      for b in 0 to NBLK-1 loop
         for w in 0 to 255 loop
            image(b)(w) <= orig(b, w);
         end loop;
      end loop;
      img_init_done <= true;
      loop
         wait until rising_edge(clk_sys);
         assert not (sd_rd = '1' and sd_wr = '1') report "sd_rd and sd_wr together" severity error;
         if sd_rd = '1' or sd_wr = '1' then
            blk := conv_integer(sd_lba);
            is_wr := sd_wr = '1';
            assert blk < NBLK report "sd_lba out of range" severity failure;
            for i in 1 to 37 loop wait until rising_edge(clk_sys); end loop;
            sd_buff_addr <= (others => '0');
            sd_ack <= '1';
            wait until rising_edge(clk_sys);
            wait until rising_edge(clk_sys);
            assert sd_rd = '0' and sd_wr = '0' report "request still high after sd_ack" severity error;
            if not is_wr then
               sd_reads <= sd_reads + 1;
               for w in 0 to 255 loop
                  sd_buff_addr <= conv_std_logic_vector(w, 8);
                  sd_buff_dout <= image(blk)(w);
                  sd_buff_wr <= '1';
                  wait until rising_edge(clk_sys);
                  sd_buff_wr <= '0';
                  for g in 1 to 3 loop wait until rising_edge(clk_sys); end loop;
               end loop;
            else
               sd_writes <= sd_writes + 1;
               for w in 0 to 255 loop
                  sd_buff_addr <= conv_std_logic_vector(w, 8);
                  for g in 1 to 4 loop wait until rising_edge(clk_sys); end loop;
                  image(blk)(w) <= sd_buff_din;
               end loop;
            end if;
            sd_ack <= '0';
            wait until rising_edge(clk_sys);
         end if;
      end loop;
   end process;

   stim: process

      procedure cyc(n : integer) is
      begin
         for i in 1 to n loop wait until rising_edge(clk); end loop;
      end procedure;

      procedure reg_write(off : std_logic_vector(2 downto 0); d : std_logic_vector(15 downto 0)) is
      begin
         wait until rising_edge(nclk);
         b_addr  <= RK_BASE(17 downto 4) & off & '0';
         b_dato  <= d;
         b_cdato <= '1';
         wait until rising_edge(nclk);
         b_cdato <= '0';
         b_addr  <= (others => '0');
         cyc(2);
      end procedure;

      procedure reg_read(off : std_logic_vector(2 downto 0); r : out std_logic_vector(15 downto 0)) is
      begin
         wait until rising_edge(nclk);
         b_addr  <= RK_BASE(17 downto 4) & off & '0';
         b_cdati <= '1';
         wait until rising_edge(nclk);
         wait until rising_edge(nclk);
         r := b_dati;
         b_cdati <= '0';
         b_addr  <= (others => '0');
      end procedure;

      procedure memw(wordaddr : integer; d : std_logic_vector(15 downto 0)) is
      begin
         wait until falling_edge(clk);
         tb_mem_addr <= wordaddr;
         tb_mem_data <= d;
         tb_mem_we <= '1';
         wait until falling_edge(clk);
         tb_mem_we <= '0';
      end procedure;

      procedure ok(tag : string; cond : boolean) is
      begin
         if cond then
            pass_count <= pass_count + 1;
         else
            report "FAIL " & tag severity error;
            fail_count <= fail_count + 1;
         end if;
         wait for 0 ns;
      end procedure;

      procedure wait_rdy(tag : string) is
         variable v : std_logic_vector(15 downto 0);
         variable n : integer := 0;
      begin
         loop
            cyc(20);
            reg_read(RKCS, v);
            exit when v(7) = '1';
            n := n + 1;
            if n > 4000 then
               report "TIMEOUT " & tag & " RKCS=" & integer'image(conv_integer(v)) & " sd_reads=" & integer'image(sd_reads)
                    & " sd_writes=" & integer'image(sd_writes) severity failure;
            end if;
         end loop;
         ok(tag & ": RKCS ERR clear", v(15) = '0');
      end procedure;

      -- one transfer: cylinder 0, track 0, starting sector, word count, memory word address
      procedure rh_cmd(go : std_logic_vector(15 downto 0); sector : integer; wc : integer; wa : integer; tag : string) is
      begin
         reg_write(RKDA, conv_std_logic_vector(sector, 16));          -- drive 0, cylinder 0, surface 0
         reg_write(RKBA, conv_std_logic_vector(wa * 2, 16));
         reg_write(RKWC, conv_std_logic_vector(65536 - wc, 16));
         reg_write(RKCS, go);
         wait_rdy(tag);
      end procedure;

      procedure fill(wa : integer; n : integer; base : integer) is
      begin
         for i in 0 to n - 1 loop
            memw(wa + i, conv_std_logic_vector(base + i, 16));
         end loop;
      end procedure;

      procedure check_block(tag : string; b : integer; lo, hi : integer; expect_orig : boolean; base : integer) is
         variable bad : integer := 0;
         variable e : std_logic_vector(15 downto 0);
      begin
         for w in lo to hi loop
            if expect_orig then e := orig(b, w); else e := conv_std_logic_vector(base + (w - lo), 16); end if;
            if image(b)(w) /= e then bad := bad + 1; end if;
         end loop;
         ok(tag & " (block " & integer'image(b) & " words " & integer'image(lo) & ".." & integer'image(hi) & ", "
            & integer'image(bad) & " wrong)", bad = 0);
      end procedure;

      procedure check_zero(tag : string; b : integer; lo, hi : integer) is
         variable bad : integer := 0;
      begin
         for w in lo to hi loop
            if image(b)(w) /= x"0000" then bad := bad + 1; end if;
         end loop;
         ok(tag & " (block " & integer'image(b) & " words " & integer'image(lo) & ".." & integer'image(hi) & " zero, "
            & integer'image(bad) & " wrong)", bad = 0);
      end procedure;

      procedure check_guard(tag : string; wa : integer; n : integer) is
         variable bad : integer := 0;
      begin
         for i in 0 to n - 1 loop
            if mem(wa + i) /= x"DEAD" then bad := bad + 1; end if;
         end loop;
         ok(tag & " (" & integer'image(bad) & " of " & integer'image(n) & " guard words overwritten)", bad = 0);
      end procedure;

      procedure check_mem(tag : string; wa : integer; b : integer; lo, hi : integer) is
         variable bad : integer := 0;
      begin
         for w in lo to hi loop
            if mem(wa + (w - lo)) /= image(b)(w) then bad := bad + 1; end if;
         end loop;
         ok(tag & " (" & integer'image(bad) & " wrong)", bad = 0);
      end procedure;

      variable v  : std_logic_vector(15 downto 0);
      variable n0 : integer;
   begin
      wait until img_init_done;
      cyc(5);
      reset <= '0';
      cyc(200);
      rh_cmd(GO_READ, 0, 256, 8#10000#, "read sector 0");
      check_mem("read sector 0", 8#10000#, 0, 0, 255);
      rh_cmd(GO_READ, 1, 512, 8#20000#, "read sectors 1-2");
      check_mem("read sector 1", 8#20000#, 1, 0, 255);
      check_mem("read sector 2", 8#20000# + 256, 2, 0, 255);

      fill(8#30000#, 256, 16#7000#);
      rh_cmd(GO_WRITE, 3, 256, 8#30000#, "write sector 3");
      check_block("write sector 3", 3, 0, 255, false, 16#7000#);
      check_block("write sector 3: sector 2 untouched", 2, 0, 255, true, 0);
      check_block("write sector 3: sector 4 untouched", 4, 0, 255, true, 0);

      fill(8#30000#, 10, 16#6100#);
      rh_cmd(GO_WRITE, 4, 10, 8#30000#, "short write sector 4 (10 words)");
      check_block("short write sector 4: data", 4, 0, 9, false, 16#6100#);
      check_zero("short write sector 4: rest of sector", 4, 10, 255);

      fill(8#40000#, 600, 16#3000#);
      rh_cmd(GO_WRITE, 5, 600, 8#40000#, "write sectors 5-7 (600 words)");
      check_block("write 5-7: sector 5", 5, 0, 255, false, 16#3000#);
      check_block("write 5-7: sector 6", 6, 0, 255, false, 16#3000# + 256);
      check_block("write 5-7: sector 7 data", 7, 0, 87, false, 16#3000# + 512);
      check_zero("write 5-7: sector 7 rest", 7, 88, 255);
      check_block("write 5-7: sector 8 untouched", 8, 0, 255, true, 0);

      rh_cmd(GO_READ, 5, 768, 8#50000#, "read back sectors 5-7");
      check_mem("read back sector 5", 8#50000#, 5, 0, 255);
      check_mem("read back sector 6", 8#50000# + 256, 6, 0, 255);
      check_mem("read back sector 7", 8#50000# + 512, 7, 0, 255);

      -- partial-sector reads (word counts RT-11 really uses): exactly wc words land,
      -- nothing beyond them is touched
      for k in 0 to 2 loop
         for i in 0 to 5000 loop
            memw(8#60000# + i, x"DEAD");
         end loop;
         if k = 0 then
            rh_cmd(GO_READ, 1, 134, 8#60000#, "partial read 134 words");
            check_mem("partial read 134: data", 8#60000#, 1, 0, 133);
            check_guard("partial read 134: nothing past the end", 8#60000# + 134, 400);
         elsif k = 1 then
            rh_cmd(GO_READ, 2, 223, 8#60000#, "partial read 223 words");
            check_mem("partial read 223: data", 8#60000#, 2, 0, 222);
            check_guard("partial read 223: nothing past the end", 8#60000# + 223, 400);
         else
            rh_cmd(GO_READ, 0, 4502, 8#60000#, "read 4502 words (17.59 sectors)");
            check_mem("read 4502: sector 0", 8#60000#, 0, 0, 255);
            check_mem("read 4502: last partial sector", 8#60000# + 17 * 256, 17, 0, 4502 - 17 * 256 - 1);
            check_guard("read 4502: nothing past the end", 8#60000# + 4502, 400);
         end if;
      end loop;

      -- RT-11 loading DIR.SAV: 4502 words from cylinder 22, surface 1, sector 10
      -- (RKDA 001332 = block 550). After two sectors the transfer runs off the end
      -- of cylinder 22 and must continue at cylinder 23, surface 0, sector 0.
      for i in 0 to 5000 loop
         memw(8#60000# + i, x"DEAD");
      end loop;
      reg_write(RKDA, x"02DA");                                      -- 001332 octal
      reg_write(RKBA, conv_std_logic_vector(8#60000# * 2, 16));
      reg_write(RKWC, conv_std_logic_vector(65536 - 4502, 16));
      reg_write(RKCS, GO_READ);
      wait_rdy("read 4502 words from block 550 (crosses into cylinder 23)");
      for k in 0 to 16 loop
         check_mem("cylinder-crossing read: block " & integer'image(550 + k), 8#60000# + k * 256, 550 + k, 0, 255);
      end loop;
      check_mem("cylinder-crossing read: block 567 (partial)", 8#60000# + 17 * 256, 567, 0, 4502 - 17 * 256 - 1);
      check_guard("cylinder-crossing read: nothing past the end", 8#60000# + 4502, 400);

      -- No image mounted: the controller is still there, the drive is not
      -- ready, a drive function ends at once with DRE (no disk activity), a
      -- control reset still works and clears it, and after the image is
      -- mounted again a read works.
      img <= 0;
      cyc(10);
      reg_write(RKDA, x"0000");
      reg_read("000", v);
      ok("offline: RKDS DRY clear", v(7) = '0');
      ok("offline: RKDS RWS RDY clear", v(6) = '0');
      n0 := sd_reads;
      reg_write(RKCS, GO_READ);
      for i in 1 to 200 loop
         cyc(10);
         reg_read(RKCS, v);
         exit when v(7) = '1';
      end loop;
      ok("offline: read completes (RDY)", v(7) = '1');
      ok("offline: read sets ERR and HE", v(15) = '1' and v(14) = '1');
      reg_read("001", v);
      ok("offline: RKER DRE", v(15) = '1' and v(7) = '0');
      ok("offline: no disk transfer started", sd_reads = n0);
      reg_write(RKCS, x"0001");                                      -- control reset
      for i in 1 to 200 loop
         cyc(10);
         reg_read(RKCS, v);
         exit when v(7) = '1';
      end loop;
      reg_read("001", v);
      ok("offline: control reset works and clears DRE", v = x"0000");
      img <= 1;
      cyc(10);
      reg_read("000", v);
      ok("remounted: RKDS DRY set", v(7) = '1');
      rh_cmd(GO_READ, 0, 256, 8#60000#, "remounted: read sector 0");
      check_mem("remounted: data", 8#60000#, 0, 0, 255);

      cyc(10);
      report "tb_rk11_blkdev: " & integer'image(pass_count) & " checks passed, "
           & integer'image(fail_count) & " failed; hps_io saw " & integer'image(sd_reads) & " block reads, "
           & integer'image(sd_writes) & " block writes";
      if fail_count = 0 then
         report "tb_rk11_blkdev: ALL CHECKS PASSED";
      else
         report "tb_rk11_blkdev: FAILURES" severity error;
      end if;
      std.env.stop;
      wait;
   end process;

end sim;
