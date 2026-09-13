-- deps: mmu.vhd mmu_trace_watch.vhd rl11.vhd
--
-- tb_mmu_rl11_par_stamp.vhd -- integration test for the actual
-- end-to-end sequence RSTS's MAPCOPY_PARAM performs and that tracecap
-- is meant to observe: set a kernel PAR (via the CPU bus), do a real
-- disk READ+GO (via rl11.vhd), and confirm the captured event's
-- trace_disk_par5/6 / trace_disk_kipar5/6 fields reflect the PAR value
-- that was live AT THE MOMENT of the read -- then change the PAR and
-- confirm a SECOND read picks up the NEW value, not a stale one.
--
-- Architecture under test: mmu_trace_watch.vhd watches
-- cpu_addr/cpu_dataout/cpu_wr/cpu_dw8 from OUTSIDE mmu.vhd (mmu.vhd
-- itself has zero ports or logic for this -- see that file's own
-- header comment for why: tracing must be fully isolated from the
-- devices it observes, so a build without it leaves every device file
-- byte-for-byte its original, already-timing-proven self). This test
-- instantiates mmu.vhd, mmu_trace_watch.vhd, and rl11.vhd together,
-- wired exactly as unibus.vhd wires them for real.
--
-- Covers BOTH kernel D-space PAR5/6 (17772372/17772374, KDPAR5/6) and
-- kernel I-space PAR5/6 (17772352/17772354, KIPAR5/6) -- including a
-- cross-contamination check between the two pairs. KIPAR5/6 are the
-- ones that actually matter for RSTS's real overlay mechanism
-- (notes/rsts-init-disasm.md's MAPCOPY_PARAM family writes KIPAR5/6,
-- never KDPAR5/6) -- an earlier version of this whole feature (with the
-- shadow-register logic embedded directly in mmu.vhd's own
-- write-decode, before the mmu_trace_watch.vhd isolation refactor)
-- used the wrong address-bit comparison ("1101"/"1110", D-space)
-- instead of the right one ("0101"/"0110", I-space) -- exactly the kind
-- of mixup the cross-contamination checks below are meant to catch.
--
-- Every other testbench in this tree tests these pieces in isolation:
--   - tb_mmu_trace_watch.vhd drives cpu_addr/cpu_dataout/cpu_wr/cpu_dw8
--     directly and checks trace_kdpar5/6/kipar5/6, but doesn't
--     instantiate mmu.vhd, rl11.vhd, or trigger a disk read.
--   - tb_rl11_dma.vhd drives rl11.vhd's DMA path for real, but ties
--     trace_kdpar5/6 and trace_kipar5/6 to CONSTANT walking-bit
--     patterns just to satisfy elaboration -- it never feeds a real,
--     changing PAR value in.
--   - tb_tracecap.vhd feeds synthetic d values straight into
--     tracecap.vhd's entity boundary, bypassing everything upstream.
-- None of them ever wired mmu_trace_watch.vhd's outputs into rl11.vhd's
-- matching inputs the way unibus.vhd's real wiring does -- so a bug
-- specifically in that interaction had no testbench that could have
-- caught it.
--
-- Run: sim/run_sim.sh tb_mmu_rl11_par_stamp --stop-time=4ms

------------------------------------------------------------------------
-- the testbench proper
------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_mmu_rl11_par_stamp is
end tb_mmu_rl11_par_stamp;

architecture sim of tb_mmu_rl11_par_stamp is
   signal clk, clk50, reset : std_logic := '0';
   signal sim_done : boolean := false;
   signal fail_count : integer := 0;

   -- mmu.vhd side (cpu bus)
   signal cpu_addr_v  : std_logic_vector(15 downto 0) := (others => '0');
   signal cpu_datain  : std_logic_vector(15 downto 0);
   signal cpu_dataout : std_logic_vector(15 downto 0) := (others => '0');
   signal cpu_rd      : std_logic := '0';
   signal cpu_wr      : std_logic := '0';
   signal cpu_dw8     : std_logic := '0';
   signal cpu_cp      : std_logic := '0';

   signal mmutrap, ack_mmutrap, mmuabort, ack_mmuabort, mmuoddabort : std_logic := '0';
   signal sr0_ic : std_logic := '0';
   signal sr1_in, sr2_in : std_logic_vector(15 downto 0) := (others => '0');
   signal dstfreference, ifetch : std_logic := '0';
   signal sr3csmenable : std_logic;
   signal mmu_lma_c1, mmu_lma_c0 : std_logic;
   signal mmu_lma_eub : std_logic_vector(21 downto 0);
   signal bus_unibus_mapped : std_logic;
   signal mmu_bus_addr : std_logic_vector(21 downto 0);
   signal mmu_bus_dati : std_logic_vector(15 downto 0) := (others => '0');
   signal mmu_bus_dato : std_logic_vector(15 downto 0);
   signal mmu_bus_control_dati, mmu_bus_control_dato, mmu_bus_control_datob : std_logic;
   signal mmu_unibus_addr : std_logic_vector(17 downto 0);
   signal mmu_unibus_dati : std_logic_vector(15 downto 0) := (others => '0');
   signal mmu_unibus_dato : std_logic_vector(15 downto 0);
   signal mmu_unibus_control_dati, mmu_unibus_control_dato, mmu_unibus_control_datob : std_logic;
   signal mmu_unibus_busmaster_addr : std_logic_vector(17 downto 0) := (others => '0');
   signal mmu_unibus_busmaster_dati : std_logic_vector(15 downto 0);
   signal mmu_unibus_busmaster_dato : std_logic_vector(15 downto 0) := (others => '0');
   signal mmu_unibus_busmaster_control_dati : std_logic := '0';
   signal mmu_unibus_busmaster_control_dato : std_logic := '0';
   signal mmu_unibus_busmaster_control_datob : std_logic := '0';
   signal mmu_unibus_busmaster_control_npg : std_logic := '0';
   signal cons_map16, cons_map18, cons_map22, cons_id : std_logic;
   signal modelcode : integer range 0 to 255 := 70;  -- matches real deployed 11/70
   signal sr0out_debug : std_logic_vector(15 downto 0);
   signal have_odd_abort : integer range 0 to 255;
   signal psw : std_logic_vector(15 downto 0) := (others => '0');
   signal id : std_logic := '0';

   -- the wire under test: mmu's live KDPAR5/6 copies, fed straight into
   -- rl11 -- exactly unibus.vhd's real mmu_trace_kdpar5/6 signal.
   signal mmu_trace_kdpar5 : std_logic_vector(15 downto 0);
   signal mmu_trace_kdpar6 : std_logic_vector(15 downto 0);
   signal mmu_trace_kipar5 : std_logic_vector(15 downto 0);
   signal mmu_trace_kipar6 : std_logic_vector(15 downto 0);

   -- rl11.vhd side (UNIBUS)
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
   signal clk_100 : std_logic := '0';
   signal sd_lba : std_logic_vector(31 downto 0);
   signal sd_rd, sd_wr, sd_ack : std_logic := '0';
   signal sd_buff_addr : std_logic_vector(8 downto 0) := (others => '0');
   signal sd_buff_dout : std_logic_vector(15 downto 0) := (others => '0');
   signal sd_buff_din : std_logic_vector(15 downto 0);
   signal sd_buff_wr : std_logic := '0';

   signal trace_disk_valid : std_logic;
   signal trace_disk_dar   : std_logic_vector(15 downto 0);
   signal trace_disk_dest  : std_logic_vector(17 downto 0);
   signal trace_disk_wc    : std_logic_vector(12 downto 0);
   signal trace_disk_par5  : std_logic_vector(15 downto 0);
   signal trace_disk_par6  : std_logic_vector(15 downto 0);
   signal trace_disk_kipar5  : std_logic_vector(15 downto 0);
   signal trace_disk_kipar6  : std_logic_vector(15 downto 0);

   type mem_t is array(0 to 65535) of integer;
   shared variable mem : mem_t := (others => -1);

   constant A_RLCS : std_logic_vector(17 downto 0) := o"774400";
   constant A_RLBA : std_logic_vector(17 downto 0) := o"774402";
   constant A_RLDA : std_logic_vector(17 downto 0) := o"774404";
   constant A_RLMP : std_logic_vector(17 downto 0) := o"774406";
   constant BA0 : integer := 8#4000#;

   component mmu is
      port(
         cpu_addr_v : in std_logic_vector(15 downto 0);
         cpu_datain : out std_logic_vector(15 downto 0);
         cpu_dataout : in std_logic_vector(15 downto 0);
         cpu_rd : in std_logic;
         cpu_wr : in std_logic;
         cpu_dw8 : in std_logic;
         cpu_cp : in std_logic;
         mmutrap : out std_logic;
         ack_mmutrap : in std_logic;
         mmuabort : out std_logic;
         ack_mmuabort : in std_logic;
         mmuoddabort : out std_logic;
         sr0_ic : in std_logic;
         sr1_in : in std_logic_vector(15 downto 0);
         sr2_in : in std_logic_vector(15 downto 0);
         dstfreference : in std_logic;
         sr3csmenable : out std_logic;
         ifetch : in std_logic;
         mmu_lma_c1 : out std_logic;
         mmu_lma_c0 : out std_logic;
         mmu_lma_eub : out std_logic_vector(21 downto 0);
         bus_unibus_mapped : out std_logic;
         bus_addr : out std_logic_vector(21 downto 0);
         bus_dati : in std_logic_vector(15 downto 0);
         bus_dato : out std_logic_vector(15 downto 0);
         bus_control_dati : out std_logic;
         bus_control_dato : out std_logic;
         bus_control_datob : out std_logic;
         unibus_addr : out std_logic_vector(17 downto 0);
         unibus_dati : in std_logic_vector(15 downto 0);
         unibus_dato : out std_logic_vector(15 downto 0);
         unibus_control_dati : out std_logic;
         unibus_control_dato : out std_logic;
         unibus_control_datob : out std_logic;
         unibus_busmaster_addr : in std_logic_vector(17 downto 0);
         unibus_busmaster_dati : out std_logic_vector(15 downto 0);
         unibus_busmaster_dato : in std_logic_vector(15 downto 0);
         unibus_busmaster_control_dati : in std_logic;
         unibus_busmaster_control_dato : in std_logic;
         unibus_busmaster_control_datob : in std_logic;
         unibus_busmaster_control_npg : in std_logic;
         cons_exadep : in std_logic := '0';
         cons_consphy : in std_logic_vector(21 downto 0) := (others => '0');
         cons_adss_mode : in std_logic_vector(1 downto 0) := (others => '0');
         cons_adss_id : in std_logic := '0';
         cons_adss_cons : in std_logic := '0';
         cons_map16 : out std_logic;
         cons_map18 : out std_logic;
         cons_map22 : out std_logic;
         cons_id : out std_logic;
         modelcode : in integer range 0 to 255;
         sr0out_debug : out std_logic_vector(15 downto 0);
         have_odd_abort : out integer range 0 to 255;
         psw : in std_logic_vector(15 downto 0);
         id : in std_logic;
         reset : in std_logic;
         clk : in std_logic
      );
   end component;

   component mmu_trace_watch is
      port(
         clk   : in std_logic;
         reset : in std_logic;
         cpu_addr    : in std_logic_vector(15 downto 0);
         cpu_dataout : in std_logic_vector(15 downto 0);
         cpu_wr      : in std_logic;
         cpu_dw8     : in std_logic;
         trace_kdpar5 : out std_logic_vector(15 downto 0);
         trace_kdpar6 : out std_logic_vector(15 downto 0);
         trace_kipar5 : out std_logic_vector(15 downto 0);
         trace_kipar6 : out std_logic_vector(15 downto 0)
      );
   end component;

   procedure clk_edges(n : integer; signal c : in std_logic) is
   begin
      for i in 1 to n loop
         wait until rising_edge(c);
      end loop;
   end procedure;

   procedure mmu_write(addr : integer; data : integer;
                        signal a : out std_logic_vector(15 downto 0);
                        signal d : out std_logic_vector(15 downto 0);
                        signal w : out std_logic;
                        signal c : in std_logic) is
   begin
      a <= std_logic_vector(to_unsigned(addr, 16));
      d <= std_logic_vector(to_unsigned(data, 16));
      w <= '1';
      wait until rising_edge(c);
      w <= '0';
      wait until rising_edge(c);
   end procedure;

   procedure bus_wr(signal a:out std_logic_vector(17 downto 0);
                    signal d:out std_logic_vector(15 downto 0);
                    signal ctl:out std_logic;
                    addr:std_logic_vector(17 downto 0);
                    data:std_logic_vector(15 downto 0);
                    signal c : in std_logic) is
   begin
      wait until rising_edge(c);
      a<=addr; d<=data; ctl<='1';
      wait until rising_edge(c);
      ctl<='0';
      wait until rising_edge(c);
   end procedure;

   procedure bus_rd(signal a:out std_logic_vector(17 downto 0);
                    signal ctl:out std_logic;
                    addr:std_logic_vector(17 downto 0);
                    result:out std_logic_vector(15 downto 0);
                    signal c : in std_logic) is
   begin
      wait until rising_edge(c);
      a<=addr; ctl<='1';
      wait until rising_edge(c);
      wait until rising_edge(c);
      result:=bus_dati;
      ctl<='0';
      wait until rising_edge(c);
   end procedure;

begin
   clk     <= not clk     after 50 ns when not sim_done else '0';
   clk50   <= not clk50   after 10 ns when not sim_done else '0';
   clk_100 <= not clk_100 after 5 ns  when not sim_done else '0';
   reset   <= '1', '0' after 700 ns;

   -- behavioural hps_io: read-only identifiable pattern (writes not
   -- exercised here), same shape as tb_rh11_dma.vhd/tb_rk11_dma.vhd's
   -- mocks, on its own clk_100 clock to actually exercise the real
   -- Gray-coded CDC bridge in rl11.vhd.
   process(clk_100)
      variable phase : integer := 0;  -- 0=idle,1=acking,2=streaming,3=flush-wait
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
                  sd_buff_dout <= std_logic_vector(to_unsigned(8#10000# + addr, 16));
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

   mmu0 : mmu port map(
      cpu_addr_v => cpu_addr_v, cpu_datain => cpu_datain, cpu_dataout => cpu_dataout,
      cpu_rd => cpu_rd, cpu_wr => cpu_wr, cpu_dw8 => cpu_dw8, cpu_cp => cpu_cp,
      mmutrap => mmutrap, ack_mmutrap => ack_mmutrap, mmuabort => mmuabort, ack_mmuabort => ack_mmuabort,
      mmuoddabort => mmuoddabort,
      sr0_ic => sr0_ic, sr1_in => sr1_in, sr2_in => sr2_in, dstfreference => dstfreference,
      sr3csmenable => sr3csmenable, ifetch => ifetch,
      mmu_lma_c1 => mmu_lma_c1, mmu_lma_c0 => mmu_lma_c0, mmu_lma_eub => mmu_lma_eub,
      bus_unibus_mapped => bus_unibus_mapped,
      bus_addr => mmu_bus_addr, bus_dati => mmu_bus_dati, bus_dato => mmu_bus_dato,
      bus_control_dati => mmu_bus_control_dati, bus_control_dato => mmu_bus_control_dato,
      bus_control_datob => mmu_bus_control_datob,
      unibus_addr => mmu_unibus_addr, unibus_dati => mmu_unibus_dati, unibus_dato => mmu_unibus_dato,
      unibus_control_dati => mmu_unibus_control_dati, unibus_control_dato => mmu_unibus_control_dato,
      unibus_control_datob => mmu_unibus_control_datob,
      unibus_busmaster_addr => mmu_unibus_busmaster_addr,
      unibus_busmaster_dati => mmu_unibus_busmaster_dati,
      unibus_busmaster_dato => mmu_unibus_busmaster_dato,
      unibus_busmaster_control_dati => mmu_unibus_busmaster_control_dati,
      unibus_busmaster_control_dato => mmu_unibus_busmaster_control_dato,
      unibus_busmaster_control_datob => mmu_unibus_busmaster_control_datob,
      unibus_busmaster_control_npg => mmu_unibus_busmaster_control_npg,
      cons_map16 => cons_map16, cons_map18 => cons_map18, cons_map22 => cons_map22, cons_id => cons_id,
      modelcode => modelcode, sr0out_debug => sr0out_debug, have_odd_abort => have_odd_abort,
      psw => psw, id => id, reset => reset, clk => clk
   );

   -- Isolated bus-watching PAR5/6 tracer -- exactly unibus.vhd's real
   -- mmu_trace_watch0 wiring, watching the same cpu_addr_v/cpu_dataout/
   -- cpu_wr/cpu_dw8 signals already fed to mmu0 above.
   mmu_trace_watch0 : mmu_trace_watch port map(
      clk => clk,
      reset => reset,
      cpu_addr => cpu_addr_v,
      cpu_dataout => cpu_dataout,
      cpu_wr => cpu_wr,
      cpu_dw8 => cpu_dw8,
      trace_kdpar5 => mmu_trace_kdpar5,
      trace_kdpar6 => mmu_trace_kdpar6,
      trace_kipar5 => mmu_trace_kipar5,
      trace_kipar6 => mmu_trace_kipar6
   );

   rl0 : entity work.rl11
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
         -- THE wire under test: mmu0's live output straight into rl0's
         -- input, exactly as unibus.vhd wires mmu_trace_kdpar5/6 into
         -- rl0/rh0 for real.
         trace_kdpar5=>mmu_trace_kdpar5, trace_kdpar6=>mmu_trace_kdpar6,
         trace_disk_valid=>trace_disk_valid, trace_disk_dar=>trace_disk_dar,
         trace_disk_dest=>trace_disk_dest, trace_disk_wc=>trace_disk_wc,
         trace_disk_par5=>trace_disk_par5, trace_disk_par6=>trace_disk_par6,
         trace_kipar5=>mmu_trace_kipar5, trace_kipar6=>mmu_trace_kipar6,
         trace_disk_kipar5=>trace_disk_kipar5, trace_disk_kipar6=>trace_disk_kipar6,
         reset=>reset, clk50mhz=>clk50, nclk=>clk, clk=>clk
      );

   npg <= npr;

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
      variable cs1 : std_logic_vector(15 downto 0);
      variable i : integer;

      procedure chk16(tag : string; got, exp : std_logic_vector) is
      begin
         if got = exp then
            report "PASS " & tag;
         else
            report "FAIL " & tag & " got=" & integer'image(to_integer(unsigned(got)))
                 & " exp=" & integer'image(to_integer(unsigned(exp))) severity error;
            fail_count <= fail_count + 1;
         end if;
      end procedure;

      procedure do_one_read(sector : integer) is
      begin
         bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLDA,
                std_logic_vector(to_unsigned(sector, 16)), clk);
         bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLBA,
                std_logic_vector(to_unsigned(BA0*2, 16)), clk);
         bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLMP,
                std_logic_vector(to_unsigned(8192 - 128, 16)), clk);
         bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLCS, x"000D", clk); -- fc=110 read, go
         i := 0;
         loop
            bus_rd(bus_addr, bus_control_dati, A_RLCS, cs1, clk);
            exit when cs1(7) = '1';
            i := i + 1;
            if i > 3000 then
               report "tb_mmu_rl11_par_stamp: FAIL - read never completed" severity failure;
            end if;
         end loop;
         clk_edges(20, clk);
      end procedure;

   begin
      wait until reset = '0';
      clk_edges(10, clk);

      ------------------------------------------------------------------
      -- 1. Set KDPAR5/6 to a distinctive, known pattern (the
      -- "MAPCOPY_PARAM: set the page" step), THEN trigger a real disk
      -- READ+GO (the "do the read" step), and confirm the captured
      -- event's trace_disk_par5/6 reflect that pattern.
      ------------------------------------------------------------------
      -- Complementary alternating-bit patterns, deliberately NOT zero
      -- and deliberately DIFFERENT between PAR5/PAR6 (and swapped again
      -- on the second read below) so neither a stuck-at-0/1 bug NOR a
      -- par5<->par6 swap bug can hide behind a lucky value match --
      -- "zero will always match zero" is not a real test.
      mmu_write(8#17772372#, 16#AAAA#, cpu_addr_v, cpu_dataout, cpu_wr, clk);  -- KDPAR5 = 1010...
      mmu_write(8#17772374#, 16#5555#, cpu_addr_v, cpu_dataout, cpu_wr, clk);  -- KDPAR6 = 0101...
      clk_edges(5, clk);
      chk16("mmu trace_kdpar5 live value after write", mmu_trace_kdpar5, std_logic_vector(to_unsigned(16#AAAA#, 16)));
      chk16("mmu trace_kdpar6 live value after write", mmu_trace_kdpar6, std_logic_vector(to_unsigned(16#5555#, 16)));

      do_one_read(0);

      chk16("read#1: trace_disk_par5 == KDPAR5 at read time", trace_disk_par5, std_logic_vector(to_unsigned(16#AAAA#, 16)));
      chk16("read#1: trace_disk_par6 == KDPAR6 at read time", trace_disk_par6, std_logic_vector(to_unsigned(16#5555#, 16)));

      ------------------------------------------------------------------
      -- 2. "reset the page": rewrite KDPAR5/6 to the OPPOSITE pattern
      -- (swapped relative to read#1), then do a SECOND read, and
      -- confirm the stamped value tracks the NEW pattern -- not stale
      -- from read#1 (proves this is a live copy, not a latch-once), and
      -- the swap specifically would catch a par5<->par6 mixup that
      -- symmetric/repeated values could not.
      ------------------------------------------------------------------
      mmu_write(8#17772372#, 16#5555#, cpu_addr_v, cpu_dataout, cpu_wr, clk);  -- new KDPAR5 = 0101...
      mmu_write(8#17772374#, 16#AAAA#, cpu_addr_v, cpu_dataout, cpu_wr, clk);  -- new KDPAR6 = 1010...
      clk_edges(5, clk);

      do_one_read(1);

      chk16("read#2: trace_disk_par5 tracks NEW KDPAR5, not stale", trace_disk_par5, std_logic_vector(to_unsigned(16#5555#, 16)));
      chk16("read#2: trace_disk_par6 tracks NEW KDPAR6, not stale", trace_disk_par6, std_logic_vector(to_unsigned(16#AAAA#, 16)));

      ------------------------------------------------------------------
      -- 3. THE ACTUAL BUG THIS TESTBENCH SHOULD HAVE CAUGHT THE FIRST
      -- TIME: KIPAR5/6 (17772352/17772354, KERNEL I-SPACE) are the pair
      -- RSTS's real overlay-mapping mechanism uses (confirmed via
      -- notes/rsts-init-disasm.md's SIMH-breakpoint disassembly of
      -- MAPCOPY_PARAM) -- NOT KDPAR5/6 (17772372/17772374, D-space),
      -- which is what this whole feature originally (wrongly) tracked.
      -- Same complementary-pattern rigor as the KDPAR5/6 checks above,
      -- PLUS a cross-contamination check: writing KIPAR5/6 must not
      -- touch KDPAR5/6's already-established value, and vice versa --
      -- exactly the kind of mixup that caused the original bug (a wrong
      -- address-bit comparison "1101"/"1110" instead of "0101"/"0110").
      ------------------------------------------------------------------
      mmu_write(8#17772352#, 16#3333#, cpu_addr_v, cpu_dataout, cpu_wr, clk);  -- KIPAR5
      mmu_write(8#17772354#, 16#CCCC#, cpu_addr_v, cpu_dataout, cpu_wr, clk);  -- KIPAR6
      clk_edges(5, clk);
      chk16("mmu trace_kipar5 live value after write", mmu_trace_kipar5, std_logic_vector(to_unsigned(16#3333#, 16)));
      chk16("mmu trace_kipar6 live value after write", mmu_trace_kipar6, std_logic_vector(to_unsigned(16#CCCC#, 16)));
      chk16("KIPAR5/6 write did not disturb KDPAR5", mmu_trace_kdpar5, std_logic_vector(to_unsigned(16#5555#, 16)));
      chk16("KIPAR5/6 write did not disturb KDPAR6", mmu_trace_kdpar6, std_logic_vector(to_unsigned(16#AAAA#, 16)));

      do_one_read(0);

      chk16("read#3: trace_disk_kipar5 == KIPAR5 at read time", trace_disk_kipar5, std_logic_vector(to_unsigned(16#3333#, 16)));
      chk16("read#3: trace_disk_kipar6 == KIPAR6 at read time", trace_disk_kipar6, std_logic_vector(to_unsigned(16#CCCC#, 16)));
      chk16("read#3: trace_disk_par5 (D-space) still holds its own value, unaffected", trace_disk_par5, std_logic_vector(to_unsigned(16#5555#, 16)));
      chk16("read#3: trace_disk_par6 (D-space) still holds its own value, unaffected", trace_disk_par6, std_logic_vector(to_unsigned(16#AAAA#, 16)));

      -- rewrite KDPAR5/6 (D-space) again and confirm it doesn't disturb
      -- the just-established KIPAR5/6 (I-space) values -- the other
      -- direction of the same cross-contamination check.
      mmu_write(8#17772372#, 16#0F0F#, cpu_addr_v, cpu_dataout, cpu_wr, clk);
      mmu_write(8#17772374#, 16#F0F0#, cpu_addr_v, cpu_dataout, cpu_wr, clk);
      clk_edges(5, clk);
      chk16("KDPAR5/6 write did not disturb KIPAR5", mmu_trace_kipar5, std_logic_vector(to_unsigned(16#3333#, 16)));
      chk16("KDPAR5/6 write did not disturb KIPAR6", mmu_trace_kipar6, std_logic_vector(to_unsigned(16#CCCC#, 16)));

      ------------------------------------------------------------------
      if fail_count = 0 then
         report "tb_mmu_rl11_par_stamp: ALL CHECKS PASSED" severity note;
      else
         report "tb_mmu_rl11_par_stamp: " & integer'image(fail_count) & " CHECK(S) FAILED" severity failure;
      end if;

      sim_done <= true;
      wait;
   end process;

   guard : process
   begin
      wait for 4 ms;
      assert sim_done report "tb_mmu_rl11_par_stamp: TIMEOUT" severity failure;
      std.env.stop;
   end process;
end sim;
