-- brk_compare.vhd -- PC-compare breakpoint: halts the CPU the instant its
-- PC (R7) reaches a configured address, so real-hardware investigation
-- can stop exactly inside a routine (e.g. RSTS's MAPCOPY_PARAM) instead
-- of hoping a naturally-occurring event lands near the interesting
-- moment. Motivated directly by this session's tracecap PAR5/6-stamp
-- investigation: peek confirms KDPAR5/6 are non-zero at some point in
-- boot, but a full disk-event trace shows every event's stamped value
-- as zero -- with no way to halt AT a known point in the routine that
-- sets them, there was no way to build a small, controlled test case on
-- real hardware, only "hope a disk event coincides."
--
-- Runs entirely in the CPU's own clock domain (cpuclk, same as cpu.vhd
-- and this signal's source, dbg_r7 -- see unibus.vhd's cpu0 port map,
-- "clk => clk" where unibus's own clk = mister_top's cpuclk) so
-- comparing against `pc` needs NO synchronizer at all: it's the exact
-- same register, same domain, zero-cycle-old value, not a CDC crossing.
--
-- The only real crossing is the OTHER direction: cfg_addr/cfg_enabled
-- are set by the ARM side over EXT_BUS, which lives in clk_100mhz. That
-- is a config value that changes rarely (set once per debug session,
-- not every cycle) -- exactly the case a plain 2-flop-per-bit
-- synchronizer is right for, the same pattern already established and
-- accepted in this codebase for other ARM-set config crossing into
-- cpuclk (see the device-flag CDC sync for have_rk/rl/rh/tm).
--
-- Halt integration deliberately mirrors a NORMAL manual halt, not a
-- separate invisible mechanism -- direct lesson from this session's
-- removed RH70-idle watchdog, which halted via its own ad hoc signal
-- that a normal "cont" couldn't clear the same way. Here: hitting the
-- breakpoint sets `brk_halt`, which the caller ANDs into cons_ena
-- (cons_ena_eff <= cons_ena and not brk_halt) exactly like a real halt
-- -- and a normal cons_cont pulse (the SAME pulse a manual "cont"/"run"
-- ODT command already generates) clears it, no special unhalt command
-- needed.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity brk_compare is
   port(
      clk   : in std_logic;  -- cpuclk domain
      reset : in std_logic;

      -- ARM-set config, clk_100mhz domain -- synchronized internally.
      cfg_addr    : in std_logic_vector(15 downto 0);
      cfg_enabled : in std_logic;

      -- CPU's live PC, SAME clock domain as this entity -- no sync.
      pc : in std_logic_vector(15 downto 0);

      -- the real cons_cont pulse (same one a manual "cont"/"run"
      -- generates) -- clears a latched hit, same as clearing a manual
      -- halt.
      cons_cont : in std_logic;

      -- '1' once the breakpoint has fired, latched until cons_cont.
      -- Caller: cons_ena_eff <= cons_ena and not brk_halt.
      brk_halt : out std_logic
   );
end entity brk_compare;

architecture rtl of brk_compare is
   -- 2-flop synchronizer for the ARM-set config (rarely changing,
   -- crossing from clk_100mhz into cpuclk).
   signal cfg_addr_s1, cfg_addr_s2       : std_logic_vector(15 downto 0) := (others => '0');
   signal cfg_enabled_s1, cfg_enabled_s2 : std_logic := '0';

   -- One-cycle shadow of pc: since pc_d's own update ("pc_d <= pc")
   -- captures pc's value from BEFORE this edge while pc itself (a
   -- register elsewhere, e.g. cpu.vhd's PC) already presents its NEW
   -- value starting this same edge, "pc /= pc_d" becomes true starting
   -- the SAME cycle pc changes -- not one cycle later. This is what
   -- lets real_arrival below be immediate (see its own comment).
   signal pc_d : std_logic_vector(15 downto 0) := (others => '0');

   -- Purely combinational, and REQUIRES a genuine pc transition this
   -- cycle (pc /= pc_d), not just pc happening to equal cfg_addr_s2.
   -- That distinction is the whole point: brk_halt gates cons_ena into
   -- cpu0, and must stop the CPU before it executes the instruction at
   -- the target address -- so it has to fire the SAME cycle pc arrives
   -- (a registered "hit <= match" would let that instruction slip
   -- through one cycle late). But a plain level/match on pc=cfg_addr_s2
   -- would ALSO spuriously fire on a config-only change (enabling the
   -- breakpoint, or retargeting cfg_addr) while pc happens to already
   -- be sitting on that value with no real arrival at all -- requiring
   -- pc itself to have just moved rules that out, since neither kind of
   -- config change touches pc/pc_d.
   signal real_arrival : std_logic;

   -- Registered sustain latch: real_arrival is only true for the exact
   -- cycle of arrival (pc_d catches up to pc the very next cycle even
   -- if pc then holds steady, e.g. because the CPU is now halted) --
   -- `hit` keeps brk_halt asserted for the rest of the halt, cleared by
   -- cons_cont (the same pulse a normal "cont"/"run" generates).
   signal hit : std_logic := '0';
begin

   real_arrival <= '1' when (pc /= pc_d and cfg_enabled_s2 = '1' and pc = cfg_addr_s2) else '0';

   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            cfg_addr_s1    <= (others => '0');
            cfg_addr_s2    <= (others => '0');
            cfg_enabled_s1 <= '0';
            cfg_enabled_s2 <= '0';
            pc_d           <= (others => '0');
            hit            <= '0';
         else
            cfg_addr_s1    <= cfg_addr;
            cfg_addr_s2    <= cfg_addr_s1;
            cfg_enabled_s1 <= cfg_enabled;
            cfg_enabled_s2 <= cfg_enabled_s1;
            pc_d           <= pc;

            if cons_cont = '1' then
               hit <= '0';
            elsif real_arrival = '1' then
               hit <= '1';
            end if;
         end if;
      end if;
   end process;

   brk_halt <= hit or real_arrival;

end architecture rtl;
