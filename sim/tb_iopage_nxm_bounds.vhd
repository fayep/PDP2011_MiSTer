-- deps: cpu.vhd cr.vhd csdr.vhd dr11c.vhd kl11.vhd kw11l.vhd mncaa.vhd
-- deps: mncad.vhd mncdi.vhd mncdo.vhd mnckw.vhd xu.vhd brk_compare.vhd
-- deps: mmu_trace_watch.vhd mmu.vhd rl11.vhd rk11.vhd rh11.vhd tm11.vhd
-- deps: unibus.vhd sdspi.vhd tb_iopage_nxm_bounds.vhd
--
-- tb_iopage_nxm_bounds.vhd -- regression for the 2026-09-11 fix to
-- rtl/mmu.vhd's bus_unibus_mapped, narrowing b406979's NXM-eligible
-- condition (addr_p(21:18)="1111", the whole top 256 KW) to exclude
-- the top 8 KW Unibus I/O page (addr_p(21:13)="111111111",
-- 0o17760000-0o17777777) -- which is always physically present on
-- real 11/70 hardware (device CSRs, the MMU PAR/PDR registers), unlike
-- the other 248 KW below it, which is genuinely absent Unibus space on
-- a real 1920 KW /70 and must still NXM (that's the actual bug
-- b406979 fixes -- see notes/rsts-v96-hang-kipar5-nonidentity.md).
--
-- This test drives real console LOAD+EXAMINE cycles (cons_sw/cons_load/
-- cons_exa, cons_adss_cons='1' for direct-physical addressing) at the
-- unibus entity and reads cons_adrserr directly -- no CPU program
-- execution, so results depend only on the address-decode logic.
--
-- IMPORTANT, discovered empirically this session (do not "simplify"
-- this test based on that Cannot use extra 12K writeup without
-- rereading it first): rtl/unibus.vhd's cer_ioabort is a priority
-- when/else chain with TWO independent branches --
--   branch 1 (pre-existing since the initial commit, untouched by
--     b406979 or this fix): aborts when NO REAL Unibus device claims
--     the address (unibus_addr_match='0'), for ANY address in the
--     whole conventional 16-bit-visible I/O page
--     (unibus_addr(17:13)="11111") -- this is CORRECT, expected real-
--     hardware behavir for a genuinely unimplemented device register,
--     and this fix does NOT touch it.
--   branch 2 (what this fix's bus_unibus_mapped narrowing affects):
--     addr_match='0' (not DRAM) and bus_unibus_mapped='1'.
-- Because it's a priority chain, branch 1 ALSO independently aborts
-- any address with no matching device REGARDLESS of this fix -- so an
-- UNCLAIMED I/O-page address (case 3 below) is expected to keep
-- aborting even after this fix, and that is NOT a test failure. What
-- this fix actually changes is scoped to whatever reaches branch 2
-- specifically; case 4 (a REAL Unibus device sitting in the I/O page,
-- exercised via the KIPAR4 test) is the one case that must never abort
-- via EITHER branch, before or after this fix -- included as a direct
-- check that this fix didn't regress real device/register access.
--
-- Run: sim/run_sim.sh tb_iopage_nxm_bounds --stop-time=200us

------------------------------------------------------------------------
-- behavioural sdspi (copied from tb_mmu_rl11_par_stamp.vhd -- read-only
-- backing store, not exercised by this test at all, present only so
-- rl11/rk11/rh11/tm11 elaborate cleanly with have_x=0)
------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sdspi is
   port(
      sdcard_cs : out std_logic;
      sdcard_mosi : out std_logic;
      sdcard_sclk : out std_logic;
      sdcard_miso : in std_logic := '0';
      sdcard_debug : out std_logic_vector(3 downto 0);
      sdcard_addr : in std_logic_vector(23 downto 0);
      sdcard_idle : out std_logic;
      sdcard_read_start : in std_logic;
      sdcard_read_ack : in std_logic;
      sdcard_read_done : out std_logic;
      sdcard_write_start : in std_logic;
      sdcard_write_ack : in std_logic;
      sdcard_write_done : out std_logic;
      sdcard_error : out std_logic;
      sdcard_xfer_addr : in integer range 0 to 255;
      sdcard_xfer_read : in std_logic;
      sdcard_xfer_out : out std_logic_vector(15 downto 0);
      sdcard_xfer_write : in std_logic;
      sdcard_xfer_in : in std_logic_vector(15 downto 0);
      enable : in integer range 0 to 1 := 0;
      controller_clk : in std_logic;
      reset : in std_logic;
      clk50mhz : in std_logic
   );
end sdspi;

architecture stub of sdspi is
begin
   sdcard_cs <= '1'; sdcard_mosi <= '0'; sdcard_sclk <= '0';
   sdcard_debug <= "0000"; sdcard_error <= '0'; sdcard_idle <= '1';
   sdcard_read_done <= '0'; sdcard_write_done <= '0';
   sdcard_xfer_out <= (others => '0');
end stub;

------------------------------------------------------------------------
-- m9312l/m9312h stubs -- the real boot-ROM entities are per-variant
-- generated files (roms/m9312l47.vhd etc, entity name matches the
-- filename, not the generic "m9312l"/"m9312h" unibus.vhd's component
-- declarations expect -- selected at the real build by a step outside
-- this repo's sim tooling). Not needed here: this test drives pure
-- console operations with cons_ena held '0' throughout, the CPU never
-- fetches an instruction, so boot-ROM content is irrelevant -- these
-- just need to never claim an address (bus_addr_match='0' always) so
-- they don't interfere with the real address-decode logic under test.
------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity m9312l is
   port(
      base_addr : in std_logic_vector(17 downto 0);
      bus_addr_match : out std_logic;
      bus_addr : in std_logic_vector(17 downto 0);
      bus_dati : out std_logic_vector(15 downto 0);
      bus_control_dati : in std_logic;
      clk : in std_logic
   );
end m9312l;

architecture stub of m9312l is
begin
   bus_addr_match <= '0';
   bus_dati <= (others => '0');
end stub;

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;

entity m9312h is
   port(
      base_addr : in std_logic_vector(17 downto 0);
      bus_addr_match : out std_logic;
      bus_addr : in std_logic_vector(17 downto 0);
      bus_dati : out std_logic_vector(15 downto 0);
      bus_control_dati : in std_logic;
      clk : in std_logic
   );
end m9312h;

architecture stub of m9312h is
begin
   bus_addr_match <= '0';
   bus_dati <= (others => '0');
end stub;

------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_iopage_nxm_bounds is
end tb_iopage_nxm_bounds;

architecture test of tb_iopage_nxm_bounds is

   signal clk        : std_logic := '0';
   signal clk50      : std_logic := '0';
   signal reset      : std_logic := '1';

   signal cons_ena    : std_logic := '0';   -- always halted: pure console-access test
   signal cons_load   : std_logic := '0';
   signal cons_exa    : std_logic := '0';
   signal cons_sw     : std_logic_vector(21 downto 0) := (others => '0');
   signal cons_adss_cons : std_logic := '1'; -- direct physical addressing, no translation
   signal cons_adrserr : std_logic;
   signal cons_run    : std_logic;

   signal addr        : std_logic_vector(21 downto 0);
   signal dato        : std_logic_vector(15 downto 0);
   signal control_dati, control_dato, control_datob : std_logic;
   signal ifetch, iwait : std_logic;

   signal test_failed : boolean := false;

   procedure check_addr(
      signal cons_sw_s   : out std_logic_vector(21 downto 0);
      signal cons_load_s : out std_logic;
      signal cons_exa_s  : out std_logic;
      signal clk_s       : in std_logic;
      addr_oct           : in string;
      addr_val           : in integer;
      expect_nxm         : in boolean;
      label_s            : in string;
      signal adrserr_s   : in std_logic;
      signal failed      : inout boolean
   ) is
   begin
      cons_sw_s <= std_logic_vector(to_unsigned(addr_val, 22));
      wait until rising_edge(clk_s);
      cons_load_s <= '1';
      wait until rising_edge(clk_s);
      cons_load_s <= '0';
      wait until rising_edge(clk_s);
      cons_exa_s <= '1';
      wait until rising_edge(clk_s);
      cons_exa_s <= '0';
      for i in 1 to 30 loop
         wait until rising_edge(clk_s);
      end loop;
      if (adrserr_s = '1') = expect_nxm then
         report "PASS " & label_s & " (" & addr_oct & "): cons_adrserr=" &
            std_logic'image(adrserr_s) & ", expected NXM=" & boolean'image(expect_nxm);
      else
         report "FAIL " & label_s & " (" & addr_oct & "): cons_adrserr=" &
            std_logic'image(adrserr_s) & ", expected NXM=" & boolean'image(expect_nxm)
            severity error;
         failed <= true;
      end if;
   end procedure;

begin

   dut: entity work.unibus
      port map(
         modelcode => 70,
         have_kl11 => 0,
         have_csdr => 0,
         have_kw11l => 0,
         have_fp => 0,
         cons_ena => cons_ena,
         cons_load => cons_load,
         cons_exa => cons_exa,
         cons_sw => cons_sw,
         cons_adss_cons => cons_adss_cons,
         cons_adrserr => cons_adrserr,
         cons_run => cons_run,
         addr => addr,
         dati => (others => '0'),
         dato => dato,
         control_dati => control_dati,
         control_dato => control_dato,
         control_datob => control_datob,
         addr_match => '0',            -- no DRAM in this test
         ifetch => ifetch,
         iwait => iwait,
         reset => reset,
         clk50mhz => clk50,
         clk => clk
      );

   clk    <= not clk    after 70 ns;
   clk50  <= not clk50  after 10 ns;

   reset <= '1', '0' after 500 ns;

   stim: process
   begin
      wait until reset = '0';
      for i in 1 to 50 loop
         wait until rising_edge(clk);
      end loop;

      -- case 1: genuinely absent extended Unibus window -- must NXM,
      -- both before and after this fix (this is the actual bug fix's
      -- target: b406979 must still catch this)
      check_addr(cons_sw, cons_load, cons_exa, clk,
         "17757776", 8#17757776#, true,
         "extended Unibus window (genuinely absent)",
         cons_adrserr, test_failed);

      -- case 2: same window, a different offset (catch an off-by-a-
      -- few-bits mistake in the boundary the other direction)
      check_addr(cons_sw, cons_load, cons_exa, clk,
         "17000000", 8#17000000#, true,
         "extended Unibus window, floor",
         cons_adrserr, test_failed);

      -- case 3: I/O page, unclaimed by any device on this minimal
      -- build -- EXPECTED to still abort, via unibus.vhd's unrelated,
      -- pre-existing branch 1 (see header comment) -- NOT a sign this
      -- fix did nothing; branch 1 was never in this fix's scope.
      check_addr(cons_sw, cons_load, cons_exa, clk,
         "17760000", 8#17760000#, true,
         "I/O page, unclaimed (branch 1 still aborts, expected)",
         cons_adrserr, test_failed);

      -- case 4: a REAL Unibus device inside the I/O page (KIPAR4) --
      -- must NEVER abort, before or after this fix. This is the
      -- concrete regression check: does the bus_unibus_mapped
      -- narrowing avoid introducing any NEW spurious abort on real,
      -- already-working I/O-page register access.
      check_addr(cons_sw, cons_load, cons_exa, clk,
         "17772350", 8#17772350#, false,
         "KIPAR4 (real device, must not regress)",
         cons_adrserr, test_failed);

      if test_failed then
         report "tb_iopage_nxm_bounds: SOME CHECKS FAILED" severity error;
      else
         report "tb_iopage_nxm_bounds: ALL CHECKS PASSED";
      end if;

      wait;
   end process;

end test;
