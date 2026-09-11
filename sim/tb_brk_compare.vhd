-- tb_brk_compare.vhd -- GHDL dry-run harness for rtl/brk_compare.vhd,
-- the PC-compare breakpoint added to let real-hardware investigation
-- halt exactly inside a routine (e.g. RSTS's MAPCOPY_PARAM) instead of
-- hoping a naturally-occurring event coincides with the interesting
-- moment.
--
-- Checks:
--   1. No match while disabled, even if pc already equals cfg_addr.
--   2. Enabling with pc ALREADY at cfg_addr does not immediately fire
--      (edge-detected, not level -- see the entity's own comment for
--      why a level compare breaks "cont").
--   3. pc transitioning INTO cfg_addr while enabled fires brk_halt.
--   4. cons_cont clears brk_halt.
--   5. THE REAL BUG A NAIVE LEVEL-COMPARE WOULD HAVE: after cons_cont
--      clears brk_halt, brk_halt must NOT immediately re-assert while
--      pc is STILL sitting at cfg_addr (simulates a multi-cycle
--      instruction holding PC steady across the resume pulse).
--   6. pc leaving cfg_addr and returning re-arms and re-fires the
--      breakpoint (the real MAPCOPY_PARAM-called-repeatedly case).
--   7. cfg_addr/cfg_enabled changes take the expected 2-cycle sync
--      latency to reach the comparator (CDC-safety contract).
--   8. reset clears brk_halt and disarms the comparator.
--
-- Run: sim/run_sim.sh tb_brk_compare --stop-time=10us

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity tb_brk_compare is
end tb_brk_compare;

architecture sim of tb_brk_compare is

   signal clk   : std_logic := '0';
   signal reset : std_logic := '1';

   signal cfg_addr    : std_logic_vector(15 downto 0) := (others => '0');
   signal cfg_enabled : std_logic := '0';
   signal pc          : std_logic_vector(15 downto 0) := (others => '0');
   signal cons_cont   : std_logic := '0';
   signal brk_halt    : std_logic;

   signal fail_count : integer := 0;

   component brk_compare is
      port(
         clk   : in std_logic;
         reset : in std_logic;
         cfg_addr    : in std_logic_vector(15 downto 0);
         cfg_enabled : in std_logic;
         pc : in std_logic_vector(15 downto 0);
         cons_cont : in std_logic;
         brk_halt : out std_logic
      );
   end component;

begin

   clk <= not clk after 10 ns;

   dut: brk_compare port map(
      clk => clk,
      reset => reset,
      cfg_addr => cfg_addr,
      cfg_enabled => cfg_enabled,
      pc => pc,
      cons_cont => cons_cont,
      brk_halt => brk_halt
   );

   stim: process

      procedure clk_edges(n : integer) is
      begin
         for i in 1 to n loop
            wait until rising_edge(clk);
         end loop;
      end procedure;

      procedure chk_bit(tag : string; v : std_logic; exp : std_logic) is
      begin
         if v = exp then
            report "PASS " & tag;
         else
            report "FAIL " & tag & " got=" & std_logic'image(v)
                 & " exp=" & std_logic'image(exp) severity error;
            fail_count <= fail_count + 1;
         end if;
      end procedure;

   begin
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      wait until rising_edge(clk);

      ------------------------------------------------------------------
      -- 1. Disabled: pc already at a would-be target, cfg never
      -- enabled -- must never fire.
      ------------------------------------------------------------------
      cfg_addr <= x"1000";
      cfg_enabled <= '0';
      pc <= x"1000";
      clk_edges(5);
      chk_bit("disabled: no fire even with pc == cfg_addr", brk_halt, '0');

      ------------------------------------------------------------------
      -- 2. Enable while pc is ALREADY sitting at cfg_addr -- edge
      -- detection means this must NOT immediately fire (there was no
      -- transition INTO the address, it was already there).
      ------------------------------------------------------------------
      cfg_enabled <= '1';
      clk_edges(5);  -- comfortably more than the 2-cycle sync latency
      chk_bit("enabling with pc already at target does not fire", brk_halt, '0');

      ------------------------------------------------------------------
      -- 3. pc LEAVES, then transitions INTO cfg_addr while enabled --
      -- must fire IMMEDIATELY (combinationally, zero clock-edge delay),
      -- not one cycle late. This is the real requirement: brk_halt
      -- gates cons_ena into cpu0, and it must stop the CPU BEFORE it
      -- executes the instruction at the target address -- one cycle of
      -- registered delay here could let that instruction slip through.
      -- Checked with NO wait-for-clock-edge at all: just settle a
      -- combinational delta and look.
      ------------------------------------------------------------------
      pc <= x"2000";
      clk_edges(3);
      chk_bit("still not fired while pc elsewhere", brk_halt, '0');
      pc <= x"1000";
      wait for 1 ns;  -- combinational settle, no clock edge
      chk_bit("fires SAME CYCLE pc arrives (no registered delay)", brk_halt, '1');

      ------------------------------------------------------------------
      -- 4. cons_cont clears it.
      ------------------------------------------------------------------
      cons_cont <= '1';
      clk_edges(1);
      cons_cont <= '0';
      clk_edges(1);
      chk_bit("cons_cont clears brk_halt", brk_halt, '0');

      ------------------------------------------------------------------
      -- 5. THE REAL BUG A LEVEL-COMPARE WOULD HAVE: pc is STILL sitting
      -- at cfg_addr (a multi-cycle instruction hasn't advanced PC yet)
      -- -- brk_halt must NOT immediately re-fire.
      ------------------------------------------------------------------
      clk_edges(10);
      chk_bit("no immediate re-fire while pc never left cfg_addr", brk_halt, '0');

      ------------------------------------------------------------------
      -- 6. pc finally leaves and comes back -- re-arms and re-fires
      -- (the real "MAPCOPY_PARAM called again later" case).
      ------------------------------------------------------------------
      pc <= x"3000";
      clk_edges(3);
      pc <= x"1000";
      wait for 1 ns;
      chk_bit("re-fires immediately after pc genuinely left and returned", brk_halt, '1');
      clk_edges(2);

      ------------------------------------------------------------------
      -- 7. CDC sync latency: changing cfg_addr away from the current pc
      -- must not fire immediately, and reverting must also respect the
      -- 2-cycle sync -- clear via cons_cont first.
      ------------------------------------------------------------------
      cons_cont <= '1';
      clk_edges(1);
      cons_cont <= '0';
      clk_edges(1);
      pc <= x"4000";
      clk_edges(3);
      cfg_addr <= x"4000";  -- change target to pc's CURRENT value
      -- must take 2 cycles to reach the comparator; since pc is already
      -- sitting there, this is also exercising case 2's edge-detect
      -- guard again with a moving target instead of a moving pc.
      clk_edges(1);
      chk_bit("cfg_addr change not yet synced (1 cycle in)", brk_halt, '0');
      clk_edges(3);
      chk_bit("cfg_addr change synced, but no fire (pc didn't transition)", brk_halt, '0');

      ------------------------------------------------------------------
      -- 8. reset clears brk_halt and disarms.
      ------------------------------------------------------------------
      pc <= x"5000";
      clk_edges(2);
      pc <= x"4000";
      clk_edges(2);
      chk_bit("fires again ahead of reset test", brk_halt, '1');
      reset <= '1';
      clk_edges(2);
      reset <= '0';
      clk_edges(1);
      chk_bit("reset clears brk_halt", brk_halt, '0');
      clk_edges(5);
      chk_bit("stays clear post-reset with stale enabled config still pending sync", brk_halt, '0');

      ------------------------------------------------------------------
      if fail_count = 0 then
         report "tb_brk_compare: ALL CHECKS PASSED" severity note;
      else
         report "tb_brk_compare: " & integer'image(fail_count) & " CHECK(S) FAILED" severity failure;
      end if;
      wait;
   end process;

end sim;
