-- deps: mister_blkdev.vhd rh11.vhd
--
-- tb_rh11_blkdev.vhd -- GHDL harness for rtl/rh11.vhd on rtl/mister_blkdev.vhd
--
-- An RP06 on rh11 against a behavioural hps_io disk slot (sd_rd/sd_wr ->
-- sd_ack -> word-by-word sd_buff_* traffic with gaps) serving an in-memory
-- image. cpuclk 140 ns (clk/nclk) and clk_sys 10 ns are unrelated, so the
-- handshake synchronisers are exercised. Generic RH70 selects the 11/70's
-- RH70 (22-bit rh70_bus_master_* DMA) or a Unibus RH11 (bus_master_*).
--
-- One RP sector is 256 words, one 512-byte block, at cylinder 0 track 0
-- sector s = block s. Checks: reads, full / short / multi-sector writes
-- (a short write zero-fills the rest of its sector), neighbouring blocks
-- untouched, read-back through the controller.
--
-- Run:  ghdl -a --std=08 -fsynopsys -frelaxed rtl/mister_blkdev.vhd rtl/rh11.vhd sim/tb_rh11_blkdev.vhd
--       ghdl -e --std=08 -fsynopsys -frelaxed tb_rh11_blkdev
--       ghdl -r --std=08 -fsynopsys -frelaxed tb_rh11_blkdev -gRH70=1 --stop-time=500ms --ieee-asserts=disable
--       (and -gRH70=0 for the Unibus RH11)
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity tb_rh11_blkdev is
   generic(RH70 : integer range 0 to 1 := 1);
end tb_rh11_blkdev;

architecture sim of tb_rh11_blkdev is

   constant RH_BASE : std_logic_vector(17 downto 0) := o"776700";
   constant RMCS1 : std_logic_vector(4 downto 0) := "00000";
   constant RMWC  : std_logic_vector(4 downto 0) := "00001";
   constant RMBA  : std_logic_vector(4 downto 0) := "00010";
   constant RMDA  : std_logic_vector(4 downto 0) := "00011";
   constant RMCS2 : std_logic_vector(4 downto 0) := "00100";
   constant RMDC  : std_logic_vector(4 downto 0) := "01110";
   constant GO_PACKACK : std_logic_vector(15 downto 0) := x"0013";   -- function 01001 + GO
   constant GO_WRITE   : std_logic_vector(15 downto 0) := x"0031";   -- function 11000 + GO
   constant GO_READ    : std_logic_vector(15 downto 0) := x"0039";   -- function 11100 + GO

   constant NBLK : integer := 16;
   type block_t is array(0 to 255) of std_logic_vector(15 downto 0);
   type image_t is array(0 to NBLK-1) of block_t;

   function orig(b, w : integer) return std_logic_vector is
   begin
      return conv_std_logic_vector((b * 256 + w) * 13 + 16#0BEE#, 16);
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

   signal m_addr  : std_logic_vector(17 downto 0);                      -- Unibus RH11 DMA
   signal m_dato, m_dati : std_logic_vector(15 downto 0);
   signal m_cdati, m_cdato : std_logic;
   signal x_addr  : std_logic_vector(21 downto 0);                      -- RH70 DMA
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

   dut: entity work.rh11 port map(
      base_addr => RH_BASE,
      ivec => o"254",
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
      rh70_bus_master_addr => x_addr,
      rh70_bus_master_dati => x_dati,
      rh70_bus_master_dato => x_dato,
      rh70_bus_master_control_dati => x_cdati,
      rh70_bus_master_control_dato => x_cdato,
      rh70_bus_master_nxm => '0',
      sd_lba => sd_lba,
      sd_rd => sd_rd,
      sd_wr => sd_wr,
      sd_ack => sd_ack,
      sd_buff_addr => sd_buff_addr,
      sd_buff_dout => sd_buff_dout,
      sd_buff_din => sd_buff_din,
      sd_buff_wr => sd_buff_wr,
      clk_sys => clk_sys,
      have_rh => 1,
      img_mounted => img,
      have_rh70 => RH70,
      rh_type => 6,
      reset => reset,
      clk50mhz => clk_sys,
      nclk => nclk,
      clk => clk
   );

   -- memory for both DMA ports (only the one for the selected mode is used)
   m_dati <= mem(conv_integer(m_addr(15 downto 1)));
   x_dati <= mem(conv_integer(x_addr(15 downto 1)));
   process(clk)
   begin
      if rising_edge(clk) then
         if m_cdato = '1' and RH70 = 0 then
            mem(conv_integer(m_addr(15 downto 1))) <= m_dato;
         end if;
         if x_cdato = '1' and RH70 = 1 then
            mem(conv_integer(x_addr(15 downto 1))) <= x_dato;
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

      procedure reg_write(off : std_logic_vector(4 downto 0); d : std_logic_vector(15 downto 0)) is
      begin
         wait until rising_edge(nclk);
         b_addr  <= RH_BASE(17 downto 6) & off & '0';
         b_dato  <= d;
         b_cdato <= '1';
         wait until rising_edge(nclk);
         b_cdato <= '0';
         b_addr  <= (others => '0');
         cyc(2);
      end procedure;

      procedure reg_read(off : std_logic_vector(4 downto 0); r : out std_logic_vector(15 downto 0)) is
      begin
         wait until rising_edge(nclk);
         b_addr  <= RH_BASE(17 downto 6) & off & '0';
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
            reg_read(RMCS1, v);
            exit when v(7) = '1';
            n := n + 1;
            if n > 4000 then
               report "TIMEOUT " & tag & " RMCS1=" & integer'image(conv_integer(v)) & " sd_reads=" & integer'image(sd_reads)
                    & " sd_writes=" & integer'image(sd_writes) severity failure;
            end if;
         end loop;
         ok(tag & ": RMCS1 SC/TRE clear", v(15) = '0' and v(14) = '0');
      end procedure;

      -- one transfer: cylinder 0, track 0, starting sector, word count, memory word address
      procedure rh_cmd(go : std_logic_vector(15 downto 0); sector : integer; wc : integer; wa : integer; tag : string) is
      begin
         reg_write(RMDC, x"0000");
         reg_write(RMDA, conv_std_logic_vector(sector, 16));
         reg_write(RMBA, conv_std_logic_vector(wa * 2, 16));
         reg_write(RMWC, conv_std_logic_vector(65536 - wc, 16));
         reg_write(RMCS1, go);
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
      report "tb_rh11_blkdev: RH70=" & integer'image(RH70);

      reg_write(RMCS2, x"0000");                                      -- unit 0
      reg_write(RMCS1, GO_PACKACK);
      wait_rdy("pack acknowledge");

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

      -- No image mounted: the controller is still there, the drive shows no
      -- medium (MOL) and no volume valid, a read is refused with UNS and
      -- attention and no disk activity, drive clear clears it, pack acknowledge
      -- cannot validate an empty drive, and after the image is mounted again
      -- MOL and VV are back and a read works.
      img <= 0;
      cyc(10);
      reg_read("00101", v);
      ok("offline: RMDS MOL clear", v(12) = '0');
      ok("offline: RMDS VV clear", v(6) = '0');
      n0 := sd_reads;
      reg_write(RMDC, x"0000");
      reg_write(RMDA, x"0005");
      reg_write(RMBA, conv_std_logic_vector(8#50000# * 2, 16));
      reg_write(RMWC, conv_std_logic_vector(65536 - 256, 16));
      reg_write(RMCS1, GO_READ);
      cyc(200);
      reg_read("00110", v);
      ok("offline: read refused with RMER1 UNS", v(14) = '1');
      reg_read("00101", v);
      ok("offline: RMDS ERR and ATA", v(14) = '1' and v(15) = '1');
      reg_read(RMCS1, v);
      ok("offline: GO clear, controller ready", v(0) = '0' and v(7) = '1');
      ok("offline: no disk transfer started", sd_reads = n0);
      reg_write(RMCS1, x"0009");                                     -- drive clear
      cyc(200);
      reg_read("00110", v);
      ok("offline: drive clear clears RMER1", v = x"0000");
      reg_write(RMCS1, GO_PACKACK);
      cyc(200);
      reg_read("00101", v);
      ok("offline: pack acknowledge cannot set VV", v(6) = '0');
      reg_write(RMCS1, x"0009");                                     -- drive clear
      cyc(200);
      img <= 1;
      cyc(10);
      reg_read("00101", v);
      ok("remounted: RMDS MOL and VV set", v(12) = '1' and v(6) = '1');
      rh_cmd(GO_READ, 5, 256, 8#50000#, "remounted: read sector 5");
      check_mem("remounted: data", 8#50000#, 5, 0, 255);

      cyc(10);
      report "tb_rh11_blkdev: RH70=" & integer'image(RH70) & ": " & integer'image(pass_count) & " checks passed, "
           & integer'image(fail_count) & " failed; hps_io saw " & integer'image(sd_reads) & " block reads, "
           & integer'image(sd_writes) & " block writes";
      if fail_count = 0 then
         report "tb_rh11_blkdev: ALL CHECKS PASSED";
      else
         report "tb_rh11_blkdev: FAILURES" severity error;
      end if;
      std.env.stop;
      wait;
   end process;

end sim;
