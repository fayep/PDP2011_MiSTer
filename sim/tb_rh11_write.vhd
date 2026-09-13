-- deps: rh11.vhd
--
-- tb_rh11_write.vhd -- does an RH70 multi-sector WRITE DATA land the
-- right words at the right blocks over the real native hps_io sd_*
-- transport?
--
-- Phase 1's own tb_rh11_dma.vhd only ever tested READ transfers -- the
-- WRITE path (busmaster_write/writen/write_wait, sdcard_write_start/
-- sdcard_xfer_write) had never been exercised against the new sd_*
-- bridge at all. Written after a real-hardware report (Faye, 2026-09-12:
-- "CPU executed halt instruction while booting our 'gold standard (but
-- not resilvered)' 211bsd rp disk after xp0a was marked clean and
-- before rxp0c was") raised the possibility that real disk writes made
-- during an earlier successful boot/login session (which necessarily
-- writes -- utmp/wtmp, syslog, cron accounting, superblock clean flags)
-- silently corrupted the on-disk image, making a LATER boot's fsck read
-- back bad data and crash. This test drives a real 2-block WRITE DATA
-- and checks the words the mock hps_io actually received, byte for
-- byte, in order, confined to the right two blocks.
--
-- The hps_io mock runs on its own clk_100 clock (genuinely different
-- from clk/cpuclk) to actually exercise the real Gray-coded CDC bridge,
-- not just its combinational logic on one shared clock -- same
-- methodology as tb_rh11_dma.vhd/tb_rl11_dma.vhd.
--
-- Run:  sim/run_sim.sh tb_rh11_write --stop-time=4ms

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_rh11_write is
end tb_rh11_write;

architecture sim of tb_rh11_write is
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
   signal bm_dato  : std_logic_vector(15 downto 0);
   signal bm_cdati, bm_cdato : std_logic;
   signal bm_nxm : std_logic := '0';
   signal rh70_addr : std_logic_vector(21 downto 0);
   signal rh70_dato : std_logic_vector(15 downto 0);
   signal rh70_cdati, rh70_cdato : std_logic;
   signal rh70_dati : std_logic_vector(15 downto 0) := (others => '0');
   signal rh70_nxm : std_logic := '0';

   -- native hps_io sd_* interface
   signal sd_lba : std_logic_vector(31 downto 0);
   signal sd_rd, sd_wr, sd_ack : std_logic := '0';
   signal sd_buff_addr : std_logic_vector(8 downto 0) := (others => '0');
   signal sd_buff_dout : std_logic_vector(15 downto 0) := (others => '0');
   signal sd_buff_din : std_logic_vector(15 downto 0);
   signal sd_buff_wr : std_logic := '0';

   -- 128 KW memory model (22-bit word addr, source for the DMA write)
   type mem_t is array(0 to 262143) of integer;
   signal mem : mem_t := (others => 0);

   -- captured disk-block backing store: 2 blocks x 256 words, what the
   -- mock actually received via sd_wr for each block number
   type block_mem_t is array(0 to 255) of integer;
   type disk_t is array(0 to 3) of block_mem_t;
   signal disk : disk_t := (others => (others => -1));   -- -1 = never written
   signal disk_write_seen : std_logic_vector(0 to 3) := (others => '0');

   constant A_CS1 : std_logic_vector(17 downto 0) := o"776700";
   constant A_WC  : std_logic_vector(17 downto 0) := o"776702";
   constant A_BA  : std_logic_vector(17 downto 0) := o"776704";
   constant A_DA  : std_logic_vector(17 downto 0) := o"776706";
   constant A_DC  : std_logic_vector(17 downto 0) := o"776734";
   constant A_BAE : std_logic_vector(17 downto 0) := o"776750";

   constant BA0   : integer := 8#20000#;          -- word 0o10000, byte 0o20000
   constant NW    : integer := 512;               -- 2 RP06 sectors

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
         sd_lba=>sd_lba, sd_rd=>sd_rd, sd_wr=>sd_wr, sd_ack=>sd_ack,
         sd_buff_addr=>sd_buff_addr, sd_buff_dout=>sd_buff_dout,
         sd_buff_din=>sd_buff_din, sd_buff_wr=>sd_buff_wr,
         clk_100mhz=>clk_100,
         have_rh=>1, have_rh70=>1, rh_type=>6,
         trace_kdpar5=>x"AAAA", trace_kdpar6=>x"5555",
         trace_kipar5=>x"3333", trace_kipar6=>x"CCCC",
         reset=>reset, clk50mhz=>clk50, nclk=>nclk, clk=>clk
      );

   npg <= npr;

   -- host-memory source for the DMA WRITE (disk controller reads FROM
   -- host memory here). Combinational/async-read, matching the timing
   -- the DUT expects (rh70_bus_master_dati must already be valid the
   -- same cycle rh70_bus_master_addr becomes the new address).
   process(rh70_addr)
      variable wa : integer;
   begin
      wa := to_integer(unsigned(rh70_addr(21 downto 1)));
      if wa >= 0 and wa <= 262143 then
         rh70_dati <= std_logic_vector(to_unsigned(mem(wa), 16));
      else
         rh70_dati <= (others => '0');
      end if;
   end process;

   -- behavioural hps_io: on sd_wr, ack after a short delay then capture
   -- 256 words from the controller via sd_buff_addr/sd_buff_din into the
   -- matching disk() block -- sd_buff_din is a REGISTERED read on
   -- rh11.vhd's own clk_100mhz side (one cycle of latency behind
   -- sd_buff_addr), so capture is one cycle behind the address drive
   -- throughout, with one extra cycle at the end to catch word 255.
   -- Same technique as tb_rl11_dma.vhd's write-mock.
   process(clk_100)
      variable cur_block : integer := 0;
      variable phase : integer := 0;  -- 0=idle,1=acking,2=streaming,3=flush,4=drop
      variable addr : integer := 0;
      variable prev_addr : integer := 0;
      variable ack_delay : integer := 0;
   begin
      if rising_edge(clk_100) then
         if reset = '1' then
            phase := 0; sd_ack <= '0';
         else
            case phase is
               when 0 =>
                  sd_ack <= '0';
                  if sd_wr = '1' then
                     cur_block := to_integer(unsigned(sd_lba));
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
                  if addr > 0 then
                     if cur_block >= 0 and cur_block <= 3 then
                        disk(cur_block)(prev_addr) <= to_integer(unsigned(sd_buff_din));
                     end if;
                  end if;
                  prev_addr := addr;
                  if addr = 255 then
                     phase := 3;
                  else
                     addr := addr + 1;
                     sd_buff_addr <= std_logic_vector(to_unsigned(addr, 9));
                  end if;

               when 3 =>
                  if cur_block >= 0 and cur_block <= 3 then
                     disk(cur_block)(255) <= to_integer(unsigned(sd_buff_din));
                     disk_write_seen(cur_block) <= '1';
                  end if;
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

   stim : process
      variable cs1 : std_logic_vector(15 downto 0);
      variable i, want, got, bad, blk, off : integer;
   begin
      wait until reset = '0';
      for k in 1 to 60 loop wait until rising_edge(clk); end loop;

      -- pack acknowledge so VV is set / drive ready
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_CS1, x"0013");
      for k in 1 to 40 loop wait until rising_edge(clk); end loop;

      -- fill source memory with an identifiable pattern
      for i in 0 to NW-1 loop
         mem(BA0 + i) <= 8#30000# + i;
      end loop;
      wait until rising_edge(clk);

      -- program the transfer: block 0, BA0, BAE 0, WC = -512
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_DC,  x"0000");
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_DA,  x"0000");
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_BAE, x"0000");
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_BA,
             std_logic_vector(to_unsigned(BA0*2, 16)));         -- byte address
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_WC,
             std_logic_vector(to_unsigned(65536 - NW, 16)));    -- -512
      -- WRITE DATA + GO : fnc "11000" & GO = 0o61
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_CS1, x"0031");

      -- wait for RDY (CS1 bit 7), up to ~30000 clk
      i := 0;
      loop
         bus_rd(bus_addr, bus_control_dati, A_CS1, cs1);
         exit when cs1(7) = '1';
         i := i + 1;
         if i > 3000 then
            report "tb_rh11_write: FAIL - write never completed (CS1=" &
               integer'image(to_integer(unsigned(cs1))) & ")" severity failure;
         end if;
      end loop;
      for k in 1 to 40 loop wait until rising_edge(clk); end loop;

      report "write done.  CS1=" & integer'image(to_integer(unsigned(cs1)));

      if disk_write_seen(0) /= '1' or disk_write_seen(1) /= '1' then
         report "tb_rh11_write: FAIL - expected sd_wr on blocks 0 and 1, seen=" &
            std_logic'image(disk_write_seen(0)) & "/" & std_logic'image(disk_write_seen(1))
            severity error;
      end if;

      -- check every word landed in the right block/offset
      bad := 0;
      for i in 0 to NW-1 loop
         blk := i / 256;
         off := i mod 256;
         want := 8#30000# + i;
         got  := disk(blk)(off);
         if got /= want then
            bad := bad + 1;
            if bad <= 6 then
               report "  word " & integer'image(i) & " (block " & integer'image(blk) &
                  " offset " & integer'image(off) & ") : got " & integer'image(got) &
                  " want " & integer'image(want) severity warning;
            end if;
         end if;
      end loop;

      -- blocks 2/3 must never have been touched
      if disk_write_seen(2) = '1' or disk_write_seen(3) = '1' then
         report "tb_rh11_write: FAIL - sd_wr seen on a block beyond the 2-block transfer"
            severity error;
         bad := bad + 1;
      end if;

      if bad = 0 then
         report "tb_rh11_write: PASS - all " & integer'image(NW) &
                " words landed correctly, confined to blocks 0-1" severity note;
      else
         report "tb_rh11_write: FAIL - " & integer'image(bad) & " problems found" severity error;
      end if;

      sim_done <= true;
      wait;
   end process;

   guard : process
   begin
      wait for 4 ms;
      assert sim_done report "tb_rh11_write: TIMEOUT" severity failure;
      std.env.stop;
   end process;
end sim;
