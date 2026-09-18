-- tb_rh11_int_owed_race.vhd -- GHDL harness reproducing the residual
-- interrupt-FSM race in rh11.vhd's int_owed/interrupt_trigger design
-- (notes/rsts-v10-rh70-hang.md, "Why RL02 hangs the same way" / defect A).
--
-- Background: commit e5186d9 (already in this tree) replaced the original
-- "catch the 1-cycle rdyset/ataset pulse" design with a level-latched
-- int_owed flip-flop, set on completion (rmcs1_rdyset/rmds_ataset) OR on
-- IE being armed while the controller is already ready/attention-pending,
-- cleared only when the interrupt is actually granted (i_wait exit).  That
-- fix closes the WIDE-window version of the bug (any "poke IE=1 on an
-- already-ready controller" done well clear of an in-flight interrupt now
-- correctly re-interrupts -- see Phase 1 below).
--
-- But interrupt_trigger itself -- the "one interrupt in flight" guard --
-- is still only ever cleared in the i_idle state's else-branch (taken when
-- int_owed=0), NOT on the i_wait -> i_idle grant transition itself.  If a
-- new completion/rearm event's int_owed-setting edge coincides with EXACTLY
-- the same nclk edge as a grant (bg deasserting, i_wait -> i_idle), the
-- general int_owed-setting block (textually after the interrupt_state case,
-- so its assignment wins for that edge) re-latches int_owed <= '1' in the
-- very same cycle the case tried to clear it, while interrupt_trigger --
-- untouched by the i_wait branch -- is still '1' from the in-flight
-- interrupt.  The i_idle state can then NEVER reach the else-branch that
-- would clear interrupt_trigger (that branch requires int_owed = '0', which
-- int_owed will now never be again), so BOTH int_owed and interrupt_trigger
-- latch permanently at '1' and every future completion is silently eaten --
-- a real deadlock, not just one dropped interrupt.
--
-- Phase 1 (baseline, non-racing): SEEK completes with IE=1 -> interrupt #1
-- delivered and granted; IE is cleared, then re-armed on the already-ready
-- controller well clear of any grant -- expect interrupt #2 to fire
-- cleanly.  Proves the e5186d9 fix itself still works for the case it was
-- built for (no regression).
--
-- Phase 2 (the race): same setup, but the IE-rearm write is timed so its
-- int_owed-latching edge lands on the EXACT same nclk edge as interrupt
-- #1's grant (bg deassert).  Expect: on unfixed rh11.vhd, NO interrupt #3
-- ever fires (permanent lockup, proven by waiting far longer than the
-- normal grant latency and never seeing br pulse again).  On fixed
-- rh11.vhd (interrupt_trigger cleared unconditionally alongside int_owed
-- on the i_wait -> i_idle transition), interrupt #3 DOES fire.
--
-- This testbench encodes the CORRECT (fixed) behaviour and so is expected
-- to FAIL on the pre-fix tree and PASS after the fix -- same convention as
-- tb_rh11_attn.vhd.
--
-- Run:  sim/run_sim.sh tb_rh11_int_owed_race --stop-time=5ms

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_rh11_int_owed_race is
end tb_rh11_int_owed_race;

architecture sim of tb_rh11_int_owed_race is

   signal clk      : std_logic := '0';
   signal nclk     : std_logic;
   signal clk50    : std_logic := '0';
   signal clk_100  : std_logic := '0';
   signal reset    : std_logic := '1';
   signal sim_done : boolean := false;

   signal bus_addr        : std_logic_vector(17 downto 0) := (others => '0');
   signal bus_dato        : std_logic_vector(15 downto 0) := (others => '0');
   signal bus_dati        : std_logic_vector(15 downto 0);
   signal bus_addr_match  : std_logic;
   signal bus_control_dati  : std_logic := '0';
   signal bus_control_dato  : std_logic := '0';
   signal bus_control_datob : std_logic := '0';

   -- bg is driven entirely by this testbench (no CPU model) so the exact
   -- grant/deassert edge can be engineered to coincide with a register
   -- write, cycle-for-cycle.
   signal br  : std_logic;
   signal bg  : std_logic := '0';
   signal npr, npg : std_logic := '0';
   signal int_vector : std_logic_vector(8 downto 0);

   signal bm_addr  : std_logic_vector(17 downto 0);
   signal bm_dato  : std_logic_vector(15 downto 0);
   signal bm_cdati, bm_cdato : std_logic;
   signal rh70_bm_addr : std_logic_vector(21 downto 0);
   signal rh70_bm_dato : std_logic_vector(15 downto 0);
   signal rh70_bm_cdati, rh70_bm_cdato : std_logic;

   signal sd_lba : std_logic_vector(31 downto 0);
   signal sd_rd, sd_wr : std_logic;
   signal sd_buff_din : std_logic_vector(15 downto 0);

   constant A_CS1 : std_logic_vector(17 downto 0) := o"776700";
   constant A_DC  : std_logic_vector(17 downto 0) := o"776734";
   constant A_AS  : std_logic_vector(17 downto 0) := o"776716";

   -- CS1: bit0 GO, bits5:1 function, bit6 IE, bit7 (write) rdyset (unused here)
   constant F_SEEK_IE : std_logic_vector(15 downto 0) := x"0045"; -- IE=1, fnc=SEEK(00010), GO=1
   constant CS1_IE     : std_logic_vector(15 downto 0) := x"0040"; -- IE=1, GO=0
   constant CS1_NOIE   : std_logic_vector(15 downto 0) := x"0000"; -- IE=0, GO=0

   signal interrupt_count : integer := 0;

   -- debug probes into the DUT's internal interrupt-FSM state, used only
   -- to tune/verify the exact-cycle race timing below.

   procedure tick(n : integer) is
   begin
      for i in 1 to n loop
         wait until clk'event and clk = '1';
      end loop;
   end procedure;

   procedure nclk_tick(n : integer) is
   begin
      for i in 1 to n loop
         wait until nclk'event and nclk = '1';
      end loop;
   end procedure;

   procedure bus_wr(signal a : out std_logic_vector(17 downto 0);
                    signal d : out std_logic_vector(15 downto 0);
                    signal c : out std_logic;
                    addr : std_logic_vector(17 downto 0);
                    data : std_logic_vector(15 downto 0)) is
   begin
      wait until clk'event and clk = '1';
      a <= addr; d <= data; c <= '1';
      wait until clk'event and clk = '1';
      c <= '0';
      wait until clk'event and clk = '1';
   end procedure;

begin

   clk     <= not clk     after 50 ns when not sim_done else '0';
   nclk    <= not clk;
   clk50   <= not clk50   after 10 ns when not sim_done else '0';
   clk_100 <= not clk_100 after 5 ns  when not sim_done else '0';
   reset   <= '1', '0' after 700 ns;

   dut : entity work.rh11
      port map(
         base_addr => o"776700",
         ivec      => o"254",
         br => br, bg => bg,
         int_vector => int_vector,
         npr => npr, npg => npg,
         bus_addr_match => bus_addr_match,
         bus_addr => bus_addr,
         bus_dati => bus_dati,
         bus_dato => bus_dato,
         bus_control_dati => bus_control_dati,
         bus_control_dato => bus_control_dato,
         bus_control_datob => bus_control_datob,
         bus_master_addr => bm_addr,
         bus_master_dato => bm_dato,
         bus_master_control_dati => bm_cdati,
         bus_master_control_dato => bm_cdato,
         rh70_bus_master_addr => rh70_bm_addr,
         rh70_bus_master_dato => rh70_bm_dato,
         rh70_bus_master_control_dati => rh70_bm_cdati,
         rh70_bus_master_control_dato => rh70_bm_cdato,
         sd_lba => sd_lba, sd_rd => sd_rd, sd_wr => sd_wr, sd_ack => '0',
         sd_buff_addr => (others => '0'), sd_buff_dout => (others => '0'),
         sd_buff_din => sd_buff_din, sd_buff_wr => '0',
         clk_100mhz => clk_100,
         have_rh => 1, have_rh70 => 1, rh_type => 6,
         trace_kdpar5 => x"AAAA", trace_kdpar6 => x"5555",
         trace_kipar5 => x"3333", trace_kipar6 => x"CCCC",
         reset => reset, clk50mhz => clk50, nclk => nclk, clk => clk
      );

   -- interrupt counter: counts br 0->1 edges, independent of the stim
   -- process's own bookkeeping, so it can't lie to itself.
   count_ints : process(nclk)
      variable br_d : std_logic := '0';
   begin
      if nclk'event and nclk = '1' then
         if br = '1' and br_d = '0' then
            interrupt_count <= interrupt_count + 1;
         end if;
         br_d := br;
      end if;
   end process;

   stim : process
      variable fail_count : integer := 0;

      procedure check(cond : boolean; msg : string) is
      begin
         if cond then
            report "PASS: " & msg severity note;
         else
            report "FAIL: " & msg severity error;
            fail_count := fail_count + 1;
         end if;
      end procedure;

      -- Grant an in-flight interrupt the ordinary way: assert bg some
      -- cycles after br, hold through the i_req->i_wait handshake, then
      -- drop bg well clear of any other activity (non-racing deassert).
      procedure grant_cleanly is
      begin
         wait until br = '1';
         nclk_tick(2);
         bg <= '1';
         wait until br = '0';       -- i_req -> i_wait
         nclk_tick(5);
         bg <= '0';                 -- ordinary, non-coincident deassert
         nclk_tick(5);
      end procedure;

   begin
      wait until reset = '0';
      tick(50);

      -- start from a known quiescent IE=0 state
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_CS1, CS1_NOIE);
      tick(20);

      report "=== Phase 1: baseline rearm-while-ready (non-racing) ===" severity note;

      bus_wr(bus_addr, bus_dato, bus_control_dato, A_DC, x"0000");
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_CS1, F_SEEK_IE);

      grant_cleanly;
      check(interrupt_count = 1, "interrupt #1 (SEEK completion, IE already set) delivered");

      -- ack ATA (write-1-to-clear RMAS) so SC drops and a later SEEK's GO
      -- bit isn't refused (CS1's "if rmcs1_sc = '0' then rmcs1_go <= ..."
      -- gate) -- real driver behaviour, not part of what's under test here.
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_AS, x"0001");
      tick(5);

      -- clear IE, let it fully settle, then rearm well clear of any grant
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_CS1, CS1_NOIE);
      tick(20);
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_CS1, CS1_IE);

      grant_cleanly;
      check(interrupt_count = 2, "interrupt #2 (IE rearmed on already-ready ctrl, non-racing) delivered [e5186d9 regression check]");

      report "=== Phase 2: rearm coincident with a grant edge (the residual race) ===" severity note;

      -- Set up interrupt #3 (an ordinary SEEK completion) and grant it
      -- normally first -- this one is NOT the race, just scaffolding to
      -- get the FSM into i_wait so its OWN grant edge can be raced.
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_CS1, CS1_NOIE);
      tick(20);
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_DC, x"0000");
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_CS1, F_SEEK_IE);

      wait until br = '1';
      nclk_tick(2);
      bg <= '1';
      wait until br = '0';          -- i_req -> i_wait for interrupt #3
      nclk_tick(5);

      check(interrupt_count = 3, "interrupt #3 (scaffolding SEEK completion) delivered normally");

      -- Get IE back to a fully-settled '0' (rmcs1_ie = rmcs1_ie_d = '0')
      -- well before the coincident write, without disturbing bg (still
      -- held high -- interrupt #3 is still in i_wait, not yet granted).
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_CS1, CS1_NOIE);
      tick(15);

      -- THE RACE: engineer the coincidence so a fresh "IE armed on an
      -- already-ready controller" edge -- which should produce interrupt
      -- #4 -- lands on the EXACT same nclk edge as interrupt #3's own
      -- grant (bg deassert, i_wait -> i_idle). The write below commits
      -- IE=1 at edge E(n-1); rmcs1_ie_d catches up to '1' only at edge
      -- E(n)+1, so at edge E(n) itself rmcs1_ie='1' (current) and
      -- rmcs1_ie_d='0' (current) -- exactly the edge-detect condition --
      -- landing on the SAME edge E(n) that bg is dropped for #3's grant.
      wait until nclk'event and nclk = '1';               -- reference edge R
      bus_addr <= A_CS1; bus_dato <= CS1_IE; bus_control_dato <= '1';
      wait until nclk'event and nclk = '1';                -- edge E(n-1): rmcs1_ie commits to '1'
      bg <= '0';                                           -- "current" for E(n): the coincident drop
      wait until nclk'event and nclk = '1';                -- edge E(n): THE RACE
      bus_control_dato <= '0';
      nclk_tick(3);
      bg <= '0';

      -- Give the (fixed) design a completely ordinary amount of time to
      -- deliver interrupt #4 (the rearm that raced #3's grant), then
      -- grant it if it appears.
      nclk_tick(30);
      if br = '1' then
         bg <= '1';
         wait until br = '0';
         nclk_tick(5);
         bg <= '0';
      end if;
      nclk_tick(20);

      check(interrupt_count = 4, "interrupt #4 (IE rearm racing interrupt #3's own grant edge) delivered -- NOT permanently eaten");

      -- ack ATA (still set from interrupt #3's SEEK, never cleared above)
      -- so this next SEEK's GO bit is actually accepted.
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_AS, x"0001");
      tick(5);

      -- Prove it isn't just late: a genuinely new, unrelated completion
      -- afterwards must still be able to interrupt too (interrupt #5),
      -- i.e. the controller isn't permanently wedged even if #4 above
      -- were missed.
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_DC, x"0001");
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_CS1, F_SEEK_IE);
      nclk_tick(30);
      if br = '1' then
         bg <= '1';
         wait until br = '0';
         nclk_tick(5);
         bg <= '0';
      end if;
      nclk_tick(20);
      check(interrupt_count = 5, "interrupt #5, a later unrelated completion, still interrupts (controller not permanently wedged)");

      if fail_count = 0 then
         report "tb_rh11_int_owed_race: ALL CHECKS PASSED" severity note;
      else
         report "tb_rh11_int_owed_race: " & integer'image(fail_count) & " CHECK(S) FAILED" severity error;
      end if;

      sim_done <= true;
      wait;
   end process;

   guard : process
   begin
      wait for 5 ms;
      assert sim_done report "tb_rh11_int_owed_race: TIMEOUT" severity failure;
      std.env.stop;
   end process;

end sim;
