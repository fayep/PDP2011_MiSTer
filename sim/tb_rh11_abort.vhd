-- deps: mister_blkdev.vhd rh11.vhd
--
-- tb_rh11_abort.vhd -- RH70/RH11 on mister_blkdev: a transfer abandoned by a
-- controller clear (CS2.CLR) while its hps_io block is still in flight.
--
-- RSTS/E V10.1 DSKINT on the MiSTer timed out a 16-sector SATT.SYS write
-- (one slow hps_io block write), printed "DB0 Error", then did what INIT
-- always does: CS2 CLR, drive clear, pack ack, and the same WRITE again.
-- The old controller kept the abandoned block's state (write_start /
-- sdcard_read_start, the busmaster) through the clear, and counted the
-- abandoned block's completion as the retry's first sector: the retry
-- wrote memory sector k+1 to disk sector k (SATT blocks 170345-170359 on
-- the MiSTer's disk are SIMH's 170346-170360), and a read retried after a
-- clear could put the abandoned block's data into the new buffer.
--
-- Checks: write abandoned mid-transfer then retried lands every sector in
-- its own block; a read abandoned mid-transfer followed by a different
-- read delivers the new data only; a write abandoned and followed by a read
-- neither hangs nor writes anything to a block it was not given.
--
-- Run:  ghdl -a --std=08 -fsynopsys -frelaxed rtl/mister_blkdev.vhd rtl/rh11.vhd sim/tb_rh11_abort.vhd
--       ghdl -e --std=08 -fsynopsys -frelaxed tb_rh11_abort
--       ghdl -r --std=08 -fsynopsys -frelaxed tb_rh11_abort -gRH70=1 --stop-time=2000ms --ieee-asserts=disable
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity tb_rh11_abort is
   generic(RH70 : integer range 0 to 1 := 1);
end tb_rh11_abort;

architecture sim of tb_rh11_abort is

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

   signal slow_blk : integer := -1;                              -- this block's hps request is held off
   signal slow_cyc : integer := 0;                               -- ... for this many clk_sys cycles
   signal hps_busy_blk : integer := -1;                          -- block the hps model is working on
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
            hps_busy_blk <= blk;
            for i in 1 to 37 loop wait until rising_edge(clk_sys); end loop;
            if blk = slow_blk then
               for i in 1 to slow_cyc loop wait until rising_edge(clk_sys); end loop;
            end if;
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
            hps_busy_blk <= -1;
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
            report "ok   " & tag;
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
            if n > 20000 then
               ok(tag & ": controller ready again (no hang)", false);
               return;
            end if;
         end loop;
      end procedure;

      procedure start(go : std_logic_vector(15 downto 0); sector : integer; wc : integer; wa : integer) is
      begin
         reg_write(RMDC, x"0000");
         reg_write(RMDA, conv_std_logic_vector(sector, 16));
         reg_write(RMBA, conv_std_logic_vector(wa * 2, 16));
         reg_write(RMWC, conv_std_logic_vector(65536 - wc, 16));
         reg_write(RMCS1, go);
      end procedure;

      -- what INIT does after its transfer timeout: controller clear, drive clear, pack ack
      procedure abandon is
      begin
         reg_write(RMCS2, x"0020");                                   -- CLR
         reg_write(RMCS2, x"0000");
         reg_write(RMCS1, x"0009");                                   -- drive clear
         reg_write(RMCS1, GO_PACKACK);
         cyc(50);
      end procedure;

      procedure fill(wa : integer; n : integer; base : integer) is
      begin
         for i in 0 to n - 1 loop
            memw(wa + i, conv_std_logic_vector(base + i, 16));
         end loop;
      end procedure;

      procedure check_block(tag : string; b : integer; expect_orig : boolean; base : integer) is
         variable bad : integer := 0;
         variable e : std_logic_vector(15 downto 0);
      begin
         for w in 0 to 255 loop
            if expect_orig then e := orig(b, w); else e := conv_std_logic_vector(base + w, 16); end if;
            if image(b)(w) /= e then bad := bad + 1; end if;
         end loop;
         ok(tag & " (block " & integer'image(b) & ", " & integer'image(bad) & " words wrong)", bad = 0);
      end procedure;

      procedure check_mem(tag : string; wa : integer; b : integer) is
         variable bad : integer := 0;
      begin
         for w in 0 to 255 loop
            if mem(wa + w) /= image(b)(w) then bad := bad + 1; end if;
         end loop;
         ok(tag & " (" & integer'image(bad) & " words wrong)", bad = 0);
      end procedure;

      procedure check_mem_const(tag : string; wa : integer; n : integer; d : std_logic_vector(15 downto 0)) is
         variable bad : integer := 0;
      begin
         for w in 0 to n - 1 loop
            if mem(wa + w) /= d then bad := bad + 1; end if;
         end loop;
         ok(tag & " (" & integer'image(bad) & " words changed)", bad = 0);
      end procedure;

      variable v  : std_logic_vector(15 downto 0);
   begin
      wait until img_init_done;
      cyc(5);
      reset <= '0';
      cyc(200);
      report "tb_rh11_abort: RH70=" & integer'image(RH70);

      reg_write(RMCS2, x"0000");
      reg_write(RMCS1, GO_PACKACK);
      wait_rdy("pack acknowledge");

      -- 1. INIT's case: 4-sector write to sectors 8-11, the second block's
      --    hps write is slow, the program gives up, clears, writes again
      fill(8#10000#, 1024, 16#4000#);
      fill(8#10000# + 1024, 256, 16#5000#);                          -- what lies past the buffer
      slow_blk <= 9; slow_cyc <= 400000;
      start(GO_WRITE, 8, 1024, 8#10000#);
      wait until hps_busy_blk = 9;
      cyc(100);
      abandon;
      slow_blk <= -1;
      start(GO_WRITE, 8, 1024, 8#10000#);
      wait_rdy("write retried after clear");
      for k in 0 to 3 loop
         check_block("write retried after clear: sector " & integer'image(8 + k), 8 + k, false, 16#4000# + 256 * k);
      end loop;
      check_block("write retried after clear: sector 12 untouched", 12, true, 0);

      -- 2. read of sectors 0-3 abandoned while block 1 is in flight, then a
      --    read of sectors 5-6 to another buffer
      for i in 0 to 2047 loop memw(8#20000# + i, x"aaaa"); end loop;
      slow_blk <= 1; slow_cyc <= 400000;
      start(GO_READ, 0, 1024, 8#20000#);
      wait until hps_busy_blk = 1;
      cyc(100);
      abandon;
      slow_blk <= -1;
      start(GO_READ, 5, 512, 8#20000# + 1024);
      wait_rdy("other read after an abandoned read");
      check_mem("read after abandoned read: sector 5", 8#20000# + 1024, 5);
      check_mem("read after abandoned read: sector 6", 8#20000# + 1280, 6);
      check_mem_const("read after abandoned read: nothing past the new buffer", 8#20000# + 1536, 512, x"aaaa");
      check_mem_const("abandoned read: nothing of it lands after the clear (old buffer sectors 1-3)", 8#20000# + 256, 768, x"aaaa");

      -- 3. write of sectors 13-14 abandoned while block 14 is in flight, then a read
      fill(8#30000#, 512, 16#2000#);
      slow_blk <= 14; slow_cyc <= 400000;
      start(GO_WRITE, 13, 512, 8#30000#);
      wait until hps_busy_blk = 14;
      cyc(100);
      abandon;
      slow_blk <= -1;
      for i in 0 to 511 loop memw(8#40000# + i, x"5555"); end loop;
      start(GO_READ, 2, 256, 8#40000#);
      wait_rdy("read after an abandoned write");
      check_mem("read after abandoned write: data", 8#40000#, 2);
      check_mem_const("read after abandoned write: nothing past the buffer", 8#40000# + 256, 256, x"5555");
      check_block("abandoned write: block 0 untouched", 0, true, 0);
      check_block("abandoned write: block 2 untouched", 2, true, 0);
      check_block("abandoned write: block 15 untouched", 15, true, 0);

      -- 4. write check does not store into memory
      for i in 0 to 255 loop memw(8#50000# + i, x"3c3c"); end loop;
      start(x"0029", 3, 256, 8#50000#);                              -- write check data + GO
      wait_rdy("write check");
      check_mem_const("write check: memory not overwritten", 8#50000#, 256, x"3c3c");

      cyc(10);
      report "tb_rh11_abort: RH70=" & integer'image(RH70) & ": " & integer'image(pass_count) & " checks passed, "
           & integer'image(fail_count) & " failed";
      if fail_count = 0 then
         report "tb_rh11_abort: ALL CHECKS PASSED";
      else
         report "tb_rh11_abort: FAILURES" severity error;
      end if;
      std.env.stop;
      wait;
   end process;

end sim;
