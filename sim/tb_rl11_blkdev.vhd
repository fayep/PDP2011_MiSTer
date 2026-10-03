-- deps: mister_blkdev.vhd rl11.vhd
--
-- tb_rl11_blkdev.vhd -- GHDL harness for rtl/rl11.vhd on rtl/mister_blkdev.vhd
--
-- rl11 talks to a behavioural hps_io disk slot (sd_rd/sd_wr -> sd_ack ->
-- word-by-word sd_buff_* traffic with gaps, like the real one) that serves
-- an in-memory image of 512-byte blocks. Clocks are deliberately unrelated:
-- cpuclk 140 ns (clk/nclk), clk_sys 10 ns, so the handshake synchronisers
-- are exercised.
--
-- Two real RL sectors (128 words) share one SD block: sector s lives in
-- block s/2, half s mod 2. The checks are about that sharing: a write must
-- change only its own half, keep the other sector in the block, and
-- zero-fill the rest of its own sector on a short write (as a real RL11
-- and SIMH's pdp11_rl.c do).
--
-- Run:  ghdl -a --std=08 -fsynopsys -frelaxed rtl/mister_blkdev.vhd rtl/rl11.vhd sim/tb_rl11_blkdev.vhd
--       ghdl -e --std=08 -fsynopsys -frelaxed tb_rl11_blkdev
--       ghdl -r --std=08 -fsynopsys -frelaxed tb_rl11_blkdev --stop-time=200ms
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity tb_rl11_blkdev is
end tb_rl11_blkdev;

architecture sim of tb_rl11_blkdev is

   constant RL_BASE : std_logic_vector(17 downto 0) := o"774400";
   constant RLCS : std_logic_vector(1 downto 0) := "00";
   constant RLBA : std_logic_vector(1 downto 0) := "01";
   constant RLDA : std_logic_vector(1 downto 0) := "10";
   constant RLMP : std_logic_vector(1 downto 0) := "11";
   constant FC_WRITE : std_logic_vector(15 downto 0) := x"000A";   -- function 5, CRDY=0 (go)
   constant FC_READ  : std_logic_vector(15 downto 0) := x"000C";   -- function 6

   constant NBLK : integer := 16;
   type block_t is array(0 to 255) of std_logic_vector(15 downto 0);
   type image_t is array(0 to NBLK-1) of block_t;

   function orig(b, w : integer) return std_logic_vector is          -- initial image contents
   begin
      return conv_std_logic_vector((b * 256 + w) * 7 + 16#1234#, 16);
   end function;

   signal clk    : std_logic := '0';
   signal nclk   : std_logic := '1';
   signal clk_sys : std_logic := '0';
   signal reset  : std_logic := '1';
   signal img    : integer range 0 to 1 := 1;                   -- image mounted (drive online)

   signal b_addr  : std_logic_vector(17 downto 0) := (others => '0');
   signal b_dato  : std_logic_vector(15 downto 0) := (others => '0');
   signal b_dati  : std_logic_vector(15 downto 0);
   signal b_cdati : std_logic := '0';
   signal b_cdato : std_logic := '0';

   signal m_addr  : std_logic_vector(17 downto 0);
   signal m_dato  : std_logic_vector(15 downto 0);
   signal m_dati  : std_logic_vector(15 downto 0);
   signal m_cdati : std_logic;
   signal m_cdato : std_logic;
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

   signal image : image_t;
   signal img_init_done : boolean := false;
   signal sd_reads, sd_writes : integer := 0;

   -- testbench writes into memory (for disk writes), merged into mem by its process
   signal tb_mem_we : std_logic := '0';
   signal tb_mem_addr : integer range 0 to 32767 := 0;
   signal tb_mem_data : std_logic_vector(15 downto 0) := (others => '0');

   signal fail_count : integer := 0;
   signal pass_count : integer := 0;

begin

   clk     <= not clk after 70 ns;                  -- cpuclk, 140 ns
   nclk    <= not clk;
   clk_sys <= not clk_sys after 5 ns;               -- hps_io / clk_100mhz
   npg     <= npr;

   dut: entity work.rl11 port map(
      base_addr => RL_BASE,
      ivec => o"160",
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
      have_rl => 1,
      img_mounted => img,
      reset => reset,
      clk50mhz => clk_sys,
      nclk => nclk,
      clk => clk
   );

   -- Unibus memory for NPR: DMA writes land here, DMA reads are served combinationally
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
            for i in 1 to 37 loop wait until rising_edge(clk_sys); end loop;   -- HPS latency
            sd_buff_addr <= (others => '0');
            sd_ack <= '1';
            wait until rising_edge(clk_sys);
            wait until rising_edge(clk_sys);
            assert sd_rd = '0' and sd_wr = '0' report "request still high after sd_ack" severity error;
            if not is_wr then                                     -- HPS -> FPGA
               sd_reads <= sd_reads + 1;
               for w in 0 to 255 loop
                  sd_buff_addr <= conv_std_logic_vector(w, 8);
                  sd_buff_dout <= image(blk)(w);
                  sd_buff_wr <= '1';
                  wait until rising_edge(clk_sys);
                  sd_buff_wr <= '0';
                  for g in 1 to 3 loop wait until rising_edge(clk_sys); end loop;
               end loop;
            else                                                  -- FPGA -> HPS
               sd_writes <= sd_writes + 1;
               for w in 0 to 255 loop
                  sd_buff_addr <= conv_std_logic_vector(w, 8);
                  for g in 1 to 4 loop wait until rising_edge(clk_sys); end loop;   -- registered din
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

      procedure reg_write(off : std_logic_vector(1 downto 0); d : std_logic_vector(15 downto 0)) is
      begin
         wait until rising_edge(nclk);
         b_addr  <= RL_BASE(17 downto 3) & off & '0';
         b_dato  <= d;
         b_cdato <= '1';
         wait until rising_edge(nclk);
         b_cdato <= '0';
         b_addr  <= (others => '0');
      end procedure;

      procedure reg_read(off : std_logic_vector(1 downto 0); r : out std_logic_vector(15 downto 0)) is
      begin
         wait until rising_edge(nclk);
         b_addr  <= RL_BASE(17 downto 3) & off & '0';
         b_cdati <= '1';
         wait until rising_edge(nclk);
         wait until rising_edge(nclk);
         r := b_dati;
         b_cdati <= '0';
         b_addr  <= (others => '0');
      end procedure;

      procedure memw(byteaddr : integer; d : std_logic_vector(15 downto 0)) is
      begin
         wait until falling_edge(clk);
         tb_mem_addr <= byteaddr / 2;
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

      -- run one RL command: sector address, word count, memory byte address
      procedure rl_cmd(fc : std_logic_vector(15 downto 0); sector : integer; wc : integer; ba : integer; tag : string) is
         variable v : std_logic_vector(15 downto 0);
         variable n : integer := 0;
      begin
         reg_write(RLBA, conv_std_logic_vector(ba, 16));
         reg_write(RLDA, conv_std_logic_vector(sector, 16));        -- cylinder 0, head 0
         reg_write(RLMP, conv_std_logic_vector(65536 - wc, 16));    -- -wc
         reg_write(RLCS, fc);
         loop
            cyc(20);
            reg_read(RLCS, v);
            exit when v(7) = '1';
            n := n + 1;
            if n > 3000 then
               report "TIMEOUT " & tag & " RLCS=" & integer'image(conv_integer(v)) & " sd_reads=" & integer'image(sd_reads)
                    & " sd_writes=" & integer'image(sd_writes) & " sd_rd=" & std_logic'image(sd_rd) & " sd_ack=" & std_logic'image(sd_ack)
                    severity failure;
            end if;
         end loop;
         ok(tag & ": RLCS error clear", v(15) = '0');
      end procedure;

      variable blk, half : integer;
      variable good : boolean;
      variable v  : std_logic_vector(15 downto 0);
      variable n0 : integer;

      procedure check_block(tag : string; b : integer; lo, hi : integer; expect_orig : boolean; base : integer) is
         -- words lo..hi of block b: original data, or base+i written from memory, checked word by word
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

      procedure fill(ba : integer; nwords : integer; base : integer) is
      begin
         for i in 0 to nwords - 1 loop
            memw(ba + 2 * i, conv_std_logic_vector(base + i, 16));
         end loop;
      end procedure;

      procedure check_mem(tag : string; ba : integer; b : integer; lo, hi : integer) is
         variable bad : integer := 0;
      begin
         for w in lo to hi loop
            if mem(ba / 2 + (w - lo)) /= image(b)(w) then bad := bad + 1; end if;
         end loop;
         ok(tag & " (" & integer'image(bad) & " wrong)", bad = 0);
      end procedure;

   begin
      wait until img_init_done;
      cyc(5);
      reset <= '0';
      cyc(50);

      -- reads: an even and an odd sector, each from its half of block 0
      rl_cmd(FC_READ, 0, 128, 8#10000#, "read sector 0");
      check_mem("read sector 0 = block 0 words 0..127", 8#10000#, 0, 0, 127);
      rl_cmd(FC_READ, 1, 128, 8#20000#, "read sector 1");
      check_mem("read sector 1 = block 0 words 128..255", 8#20000#, 0, 128, 255);

      -- single odd sector write: block 0's even half (sector 0) must survive
      fill(8#30000#, 128, 16#7000#);
      rl_cmd(FC_WRITE, 1, 128, 8#30000#, "write sector 1");
      check_block("write sector 1: its own half", 0, 128, 255, false, 16#7000#);
      check_block("write sector 1: sector 0 kept", 0, 0, 127, true, 0);

      -- single even sector write: block 1's odd half (sector 3) must survive
      fill(8#30000#, 128, 16#5000#);
      rl_cmd(FC_WRITE, 2, 128, 8#30000#, "write sector 2");
      check_block("write sector 2: its own half", 1, 0, 127, false, 16#5000#);
      check_block("write sector 2: sector 3 kept", 1, 128, 255, true, 0);

      -- short writes: rest of the target sector zero, other sector kept
      fill(8#30000#, 8, 16#6100#);
      rl_cmd(FC_WRITE, 5, 8, 8#30000#, "short write sector 5 (8 words)");
      check_block("short write sector 5: data", 2, 128, 135, false, 16#6100#);
      check_zero("short write sector 5: rest of sector", 2, 136, 255);
      check_block("short write sector 5: sector 4 kept", 2, 0, 127, true, 0);

      fill(8#30000#, 3, 16#6200#);
      rl_cmd(FC_WRITE, 6, 3, 8#30000#, "short write sector 6 (3 words)");
      check_block("short write sector 6: data", 3, 0, 2, false, 16#6200#);
      check_zero("short write sector 6: rest of sector", 3, 3, 127);
      check_block("short write sector 6: sector 7 kept", 3, 128, 255, true, 0);

      -- multi-sector writes, from an even and from an odd sector
      fill(8#40000#, 384, 16#3000#);
      rl_cmd(FC_WRITE, 8, 384, 8#40000#, "write sectors 8-10");
      check_block("write 8-10: sectors 8,9", 4, 0, 255, false, 16#3000#);
      check_block("write 8-10: sector 10", 5, 0, 127, false, 16#3000# + 256);
      check_block("write 8-10: sector 11 kept", 5, 128, 255, true, 0);

      fill(8#40000#, 256, 16#4000#);
      rl_cmd(FC_WRITE, 13, 256, 8#40000#, "write sectors 13-14");
      check_block("write 13-14: sector 12 kept", 6, 0, 127, true, 0);
      check_block("write 13-14: sector 13", 6, 128, 255, false, 16#4000#);
      check_block("write 13-14: sector 14", 7, 0, 127, false, 16#4000# + 128);
      check_block("write 13-14: sector 15 kept", 7, 128, 255, true, 0);

      -- round trip through the controller: read back what was written
      rl_cmd(FC_READ, 1, 128, 8#50000#, "read back sector 1");
      check_mem("read back sector 1", 8#50000#, 0, 128, 255);
      rl_cmd(FC_READ, 13, 256, 8#60000#, "read back sectors 13-14");
      check_mem("read back sector 13", 8#60000#, 6, 128, 255);
      check_mem("read back sector 14", 8#60000# + 256, 7, 0, 127);

      -- No image mounted: the controller is still there, the drive is not
      -- ready, Get Status still works and reports the load state, a read ends
      -- at once with OPI and no disk activity, and after the image is mounted
      -- again a read works.
      img <= 0;
      cyc(10);
      reg_read(RLCS, v);
      ok("offline: RLCS DRDY clear", v(0) = '0');
      reg_write(RLDA, x"0003");                                      -- get status: marker + GS
      reg_write(RLCS, x"0004");                                      -- function 2, go
      for i in 1 to 200 loop
         cyc(10);
         reg_read(RLCS, v);
         exit when v(7) = '1';
      end loop;
      ok("offline: get status completes without error", v(7) = '1' and v(15) = '0');
      reg_read(RLMP, v);
      ok("offline: get status reports load state", v(4 downto 0) = "00000");
      n0 := sd_reads;
      reg_write(RLBA, conv_std_logic_vector(8#50000#, 16));
      reg_write(RLDA, x"0001");
      reg_write(RLMP, conv_std_logic_vector(65536 - 128, 16));
      reg_write(RLCS, FC_READ);
      for i in 1 to 200 loop
         cyc(10);
         reg_read(RLCS, v);
         exit when v(7) = '1';
      end loop;
      ok("offline: read completes (CRDY)", v(7) = '1');
      ok("offline: read ends with ERR + OPI", v(15) = '1' and v(12 downto 10) = "001");
      ok("offline: no disk transfer started", sd_reads = n0);
      img <= 1;
      cyc(10);
      reg_read(RLCS, v);
      ok("remounted: RLCS DRDY set", v(0) = '1');
      rl_cmd(FC_READ, 1, 128, 8#50000#, "remounted: read sector 1");
      check_mem("remounted: data", 8#50000#, 0, 128, 255);

      cyc(10);
      report "tb_rl11_blkdev: " & integer'image(pass_count) & " checks passed, " & integer'image(fail_count)
           & " failed; hps_io saw " & integer'image(sd_reads) & " block reads, " & integer'image(sd_writes) & " block writes";
      if fail_count = 0 then
         report "tb_rl11_blkdev: ALL CHECKS PASSED";
      else
         report "tb_rl11_blkdev: FAILURES" severity error;
      end if;
      std.env.stop;
      wait;
   end process;

end sim;
