-- deps: mister_blkdev.vhd rh11.vhd
--
-- tb_rh11_reboot.vhd -- GHDL harness: an RH70/RH11 transfer cut off by a bus INIT
-- (the RESET instruction), then INIT's reads, as when RSTS/E V10.1 reboots after
-- SHUTUP: the shutdown writes the disks right up to the restart, the restart
-- issues INIT, and INIT reads the pack label (LBN 1) and its code. On the MiSTer
-- that reboot fails intermittently with a trap through 10 or 4, a HALT, or
-- "Pack cluster size is not 1, 2, 4, ..." -- all wrong data after a disk read.
--
-- The hps_io disk slot here behaves like Main: it LATCHES a request (LBA, read
-- or write) when it sees sd_rd / sd_wr at a poll, and later serves that request
-- with sd_ack whether or not the core still asserts it. The other benches' HPS
-- serves only what is asserted, so they cannot see a request that the core
-- withdrew (reset) after Main had already taken it.
--
-- The disk is a generation per LBN (data = f(lbn, generation)); writes carry
-- the generation the software meant, so a write stored at the wrong LBN or with
-- another transfer's data is caught when it happens. Each iteration:
--   1. a WRITE (as the dismount) or READ of 1..4 blocks, INIT's register sequence
--   2. a bus INIT at a random moment: before Main polls, latched-but-not-acked,
--      during the block transfer, during the DMA, or after completion
--   3. INIT's reads after the restart: LBN 1 and random blocks
-- Checks:
--   * every word read after the restart equals the disk's current content
--   * no DMA from the cut-off transfer after INIT (no bus master write before
--     the next GO)
--   * every block Main writes holds the data written for that LBN
--
-- Run:  sim/run_tb_rh11_reboot.sh

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.MATH_REAL.ALL;

entity tb_rh11_reboot is
   generic(RH70 : integer range 0 to 1 := 1; NITER : integer := 200; SEED : integer := 1);
end tb_rh11_reboot;

architecture sim of tb_rh11_reboot is

   constant RH_BASE : std_logic_vector(17 downto 0) := o"776700";
   constant RMCS1 : std_logic_vector(4 downto 0) := "00000";
   constant RMWC  : std_logic_vector(4 downto 0) := "00001";
   constant RMBA  : std_logic_vector(4 downto 0) := "00010";
   constant RMDA  : std_logic_vector(4 downto 0) := "00011";
   constant RMCS2 : std_logic_vector(4 downto 0) := "00100";
   constant RMDS  : std_logic_vector(4 downto 0) := "00101";
   constant RMAS  : std_logic_vector(4 downto 0) := "00111";
   constant RMDT  : std_logic_vector(4 downto 0) := "01011";
   constant RMOF  : std_logic_vector(4 downto 0) := "01101";
   constant RMDC  : std_logic_vector(4 downto 0) := "01110";

   constant NLBN : integer := 1024;

   -- block content: a function of (lbn, generation, word)
   function blk(lbn, gen, w : integer) return std_logic_vector is
   begin
      return conv_std_logic_vector((lbn * 977 + gen * 7919 + w * 31 + 16#0BEE#) mod 65536, 16);
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

   type gen_t is array(0 to NLBN - 1) of integer;
   signal disk_gen : gen_t := (others => 0);          -- the disk: generation stored per LBN (Main side)
   signal want_gen : gen_t := (others => 0);          -- generation the software last wrote per LBN

   signal hps_phase : integer := 0;                   -- 0 idle, 1 latched (not acked), 2 acked/transfer
   signal stray_dma : integer := 0;                   -- bus master writes while counting is armed
   signal count_stray : boolean := false;
   signal reset_end : time := 0 ns;
   signal bad_write : integer := 0;                   -- blocks Main stored with data not meant for that LBN

   -- buffer fills are done by the memory's own process (one driver for mem)
   signal fill_go : boolean := false;
   signal fill_wa, fill_n, fill_lbn, fill_gen : integer := 0;
   signal fill_data : boolean := false;                   -- true: blk(lbn+k/256, gen, k mod 256); false: x"DEAD"
   signal fill_init : boolean := false;                   -- true: INIT's own contents, x"5A00" + k

   signal fail_count : integer := 0;
   signal pass_count : integer := 0;

begin

   clk     <= not clk after 70 ns;
   nclk    <= not clk;
   clk_sys <= not clk_sys after 5 ns;
   -- arbiter like unibus.vhd: grant registered one clock after the request, dropped one clock
   -- after the request goes; not reset by the bus INIT
   process(clk) begin if rising_edge(clk) then npg <= npr; end if; end process;

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
   process(clk, fill_go)
   begin
      if fill_go'event then
         for k in 0 to fill_n - 1 loop
            if fill_init then mem(fill_wa + k) <= conv_std_logic_vector(16#5A00# + k, 16);
            elsif fill_data then mem(fill_wa + k) <= blk(fill_lbn + k / 256, fill_gen, k mod 256);
            else mem(fill_wa + k) <= x"DEAD"; end if;
         end loop;
      end if;
      if rising_edge(clk) then
         if m_cdato = '1' and npg = '1' and RH70 = 0 then mem(conv_integer(m_addr(15 downto 1))) <= m_dato; end if;
         if x_cdato = '1' and npg = '1' and RH70 = 1 then mem(conv_integer(x_addr(15 downto 1))) <= x_dato; end if;
         if count_stray and npg = '1' and ((m_cdato = '1' and RH70 = 0) or (x_cdato = '1' and RH70 = 1)) then
            stray_dma <= stray_dma + 1;
            if stray_dma < 4 then
               if RH70 = 1 then
                  report "stray DMA write after INIT: addr " & integer'image(conv_integer(x_addr)) & " (" & integer'image(conv_integer(x_addr(15 downto 1))) & " w) data " & integer'image(conv_integer(x_dato)) & " at " & time'image(now - reset_end) & " after INIT ended" severity note;
               else
                  report "stray DMA write after INIT: addr " & integer'image(conv_integer(m_addr)) & " data " & integer'image(conv_integer(m_dato)) & " at " & time'image(now - reset_end) & " after INIT ended" severity note;
               end if;
            end if;
         end if;
      end if;
   end process;

   -- Main-like hps_io disk slot: polls, latches a request, serves it later regardless.
   hps: process
      variable s1, s2 : positive := 7;
      variable r : real;
      variable lbn, poll, lat, gap, nbad : integer;
      variable is_wr : boolean;
      variable got : std_logic_vector(15 downto 0);
   begin
      s1 := SEED * 7919 + 1; s2 := SEED * 104729 + 3;
      loop
         -- Main polls the core's disk status now and then (1 .. ~10 us apart)
         uniform(s1, s2, r); poll := 100 + integer(r * 900.0);
         for i in 1 to poll loop wait until rising_edge(clk_sys); end loop;
         if sd_rd = '1' or sd_wr = '1' then
            lbn := conv_integer(sd_lba); is_wr := sd_wr = '1';     -- latched: served even if withdrawn
            hps_phase <= 1;
            uniform(s1, s2, r);
            if r < 0.5 then lat := 2 + integer(r * 400.0);
            elsif r < 0.9 then lat := 200 + integer(r * 3000.0);
            else lat := 1000 + integer(r * 3000.0); end if;
            for i in 1 to lat loop wait until rising_edge(clk_sys); end loop;
            hps_phase <= 2;
            sd_buff_addr <= (others => '0');
            sd_ack <= '1';
            wait until rising_edge(clk_sys);
            wait until rising_edge(clk_sys);
            uniform(s1, s2, r); gap := integer(r * 6.0);
            nbad := 0;
            for w in 0 to 255 loop
               sd_buff_addr <= conv_std_logic_vector(w, 8);
               if not is_wr then
                  if lbn < NLBN then sd_buff_dout <= blk(lbn, disk_gen(lbn), w); end if;
                  sd_buff_wr <= '1';
               end if;
               wait until rising_edge(clk_sys);
               sd_buff_wr <= '0';
               if is_wr then
                  wait until rising_edge(clk_sys);                      -- sd_buff_din is registered
                  got := sd_buff_din;
                  if lbn < NLBN and got /= blk(lbn, want_gen(lbn), w) then nbad := nbad + 1; end if;
               end if;
               for g in 1 to gap loop wait until rising_edge(clk_sys); end loop;
            end loop;
            if is_wr and lbn < NLBN then
               disk_gen(lbn) <= want_gen(lbn);
               if nbad /= 0 then
                  bad_write <= bad_write + 1;
                  report "Main stored LBN " & integer'image(lbn) & " with " & integer'image(nbad)
                       & " words not written for it" severity warning;
               end if;
            end if;
            sd_ack <= '0';
            hps_phase <= 0;
            wait until rising_edge(clk_sys);
         end if;
      end loop;
   end process;

   stim: process
      variable s1, s2 : positive := 11;
      variable r : real;
      variable v : std_logic_vector(15 downto 0);
      variable lbn, nblk, wa, gen, mode, waitc, bad, rlbn, rn, base_bad, base_stray : integer;
      variable is_write : boolean;
      variable where : string(1 to 12);

      procedure cyc(n : integer) is
      begin
         for i in 1 to n loop wait until rising_edge(clk); end loop;
      end procedure;

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

      procedure fill(wa, n, lbn, gen : integer; data : boolean; init_pat : boolean := false) is
      begin
         fill_wa <= wa; fill_n <= n; fill_lbn <= lbn; fill_gen <= gen; fill_data <= data; fill_init <= init_pat;
         wait for 0 ns;
         fill_go <= not fill_go;
         wait for 0 ns; wait for 0 ns;
      end procedure;

      procedure ok(tag : string; cond : boolean) is
      begin
         if cond then pass_count <= pass_count + 1;
         else report "FAIL " & tag severity error; fail_count <= fail_count + 1; end if;
         wait for 0 ns;
      end procedure;

      -- INIT's register sequence up to (and including) the function + GO
      procedure start_xfer(lbn, nblk, wa : integer; fn : std_logic_vector(15 downto 0)) is
         variable v : std_logic_vector(15 downto 0);
         variable cyl, trk, sec : integer;
      begin
         cyl := lbn / 418; trk := (lbn mod 418) / 22; sec := lbn mod 22;
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
         count_stray <= false;
         reg_write(RMCS1, fn);
      end procedure;

      procedure wait_ready(tag : string) is
         variable v : std_logic_vector(15 downto 0);
         variable polls : integer;
      begin
         polls := 0;
         loop
            reg_read(RMCS1, v); exit when v(7) = '1';
            polls := polls + 1;
            assert polls < 2000000 report "TIMEOUT " & tag severity failure;
         end loop;
         wait until npr = '0' and sd_rd = '0' and sd_wr = '0' and sd_ack = '0' for 2 ms;
         cyc(4);
      end procedure;

      -- INIT reads after the restart: data must be exactly what the disk holds
      procedure check_read(lbn, nblk, wa : integer; tag : string) is
         variable bad : integer;
      begin
         fill(wa, nblk * 256, 0, 0, false);
         start_xfer(lbn, nblk, wa, x"0039");                           -- read + GO
         wait_ready(tag);
         bad := 0;
         for k in 0 to nblk * 256 - 1 loop
            if mem(wa + k) /= blk(lbn + k / 256, disk_gen(lbn + k / 256), k mod 256) then bad := bad + 1; end if;
         end loop;
         ok(tag & ": read after INIT returns the disk's data (" & integer'image(bad) & " words wrong)", bad = 0);
      end procedure;

   begin
      s1 := SEED * 31 + 5; s2 := SEED * 17 + 9;
      reset <= '1'; cyc(10); reset <= '0'; cyc(600);
      gen := 0;

      for it in 1 to NITER loop
         -- 1. a transfer, as the shutdown's last I/O (mostly writes) or a read
         uniform(s1, s2, r); is_write := r < 0.7;
         uniform(s1, s2, r); lbn := 16 + integer(r * real(NLBN - 64));
         uniform(s1, s2, r); nblk := 1 + integer(r * 3.0);
         uniform(s1, s2, r); wa := 4096 + integer(r * 8000.0);
         gen := gen + 1;
         if is_write then
            for b in 0 to nblk - 1 loop want_gen(lbn + b) <= gen; end loop;
            fill(wa, nblk * 256, lbn, gen, true);
            start_xfer(lbn, nblk, wa, x"0031");                        -- write + GO
         else
            start_xfer(lbn, nblk, wa, x"0039");                        -- read + GO
         end if;

         -- 2. a bus INIT at a random moment of that transfer
         uniform(s1, s2, r); mode := integer(r * 5.0) mod 5;
         case mode is
            when 0 => where := "immediately "; cyc(1);
            when 1 => where := "Main latched";                        -- request taken, not yet acked
                      wait until hps_phase = 1 for 3 ms; cyc(1);
            when 2 => where := "block xfer  ";
                      wait until hps_phase = 2 for 3 ms;
                      uniform(s1, s2, r); wait for r * 3 us;
            when 3 => where := "during DMA  ";
                      wait until npr = '1' for 3 ms;
                      uniform(s1, s2, r); cyc(integer(r * 200.0));
            when others => where := "after ready "; wait_ready("pre-INIT");
         end case;
         uniform(s1, s2, r); waitc := 1 + integer(r * 30.0);
         reset <= '1'; cyc(waitc); reset <= '0'; reset_end <= now;
         report "iter " & integer'image(it) & ": INIT for " & integer'image(waitc) & " cpu cycles (" & where & "), xfer lbn " & integer'image(lbn) & " n " & integer'image(nblk) & " buffer word " & integer'image(wa) & " " & boolean'image(is_write) severity note;
         count_stray <= true;                                          -- no DMA may follow until the next GO
         base_stray := stray_dma; base_bad := bad_write;

         -- the restart: a little time, as the reboot's code runs; INIT then reuses the memory the
         -- cut-off transfer was using (its own code/data); later DMA must not touch it
         uniform(s1, s2, r); cyc(20 + integer(r * 400.0));
         fill(wa, nblk * 256, 0, 0, false, true);
         ok("iter " & integer'image(it) & " (" & where & "): no DMA after INIT before the next GO",
            stray_dma = base_stray);
         check_read(1, 1, 16384, "iter " & integer'image(it) & " (" & where & ") pack label LBN 1");
         uniform(s1, s2, r); rlbn := integer(r * real(NLBN - 8));
         uniform(s1, s2, r); rn := 1 + integer(r * 4.0);
         check_read(rlbn, rn, 20000, "iter " & integer'image(it) & " (" & where & ") LBN " & integer'image(rlbn));
         -- the cut-off transfer's blocks themselves
         check_read(lbn, nblk, 24000, "iter " & integer'image(it) & " (" & where & ") the cut-off LBNs");
         bad := 0;
         for k in 0 to nblk * 256 - 1 loop
            if mem(wa + k) /= conv_std_logic_vector(16#5A00# + k, 16) then bad := bad + 1; end if;
         end loop;
         ok("iter " & integer'image(it) & " (" & where & "): memory INIT reused after the cut-off transfer is intact ("
            & integer'image(bad) & " words overwritten)", bad = 0);
         wait until hps_phase = 0 for 3 ms;
         ok("iter " & integer'image(it) & " (" & where & "): Main stored only the right data at the right LBN",
            bad_write = base_bad);
      end loop;

      report "tb_rh11_reboot: RH70=" & integer'image(RH70) & " SEED=" & integer'image(SEED) & ": "
           & integer'image(pass_count) & " checks passed, " & integer'image(fail_count) & " failed";
      if fail_count = 0 then report "tb_rh11_reboot: ALL CHECKS PASSED";
      else report "tb_rh11_reboot: FAILURES" severity error; end if;
      std.env.stop;
      wait;
   end process;

end sim;
