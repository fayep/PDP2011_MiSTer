-- deps: cpuregs.vhd fpuregs.vhd cpu.vhd mmu.vhd mmu_trace_watch.vhd cr.vhd csdr.vhd xubm.vhd xubl.vhd xubrt45.vhd xu.vhd m9312h47.vhd m9312l47.vhd kl11.vhd kw11l.vhd sdspi.vhd rh11.vhd rk11.vhd rl11.vhd tm11.vhd dr11c.vhd mncad.vhd mnckw.vhd mncaa.vhd mncdi.vhd mncdo.vhd brk_compare.vhd unibus.vhd
--
-- tb_boot_probe.vhd -- does the REAL M9312 boot ROM actually reach rpgo
-- when RH70 is the only controller with media mounted (RK/RL/TM present
-- on the bus per the static have_x=1 scheme, but empty)?
--
-- Every other testbench in this tree (tb_rsts_overlay, tb_tm11, ...)
-- pokes a hand-written test program directly into RAM and starts the
-- CPU there -- none of them ever let the CPU boot from its real reset
-- vector through m9312h47.vhd's device-probe chain. This one does: it
-- watches dbg_r7 (live PC) directly, since instruction fetches from the
-- ROM and CSR polls to rk/rh are internally decoded inside unibus.vhd
-- and never touch the external addr/dati path (that's only for plain
-- RAM) -- an external bus tracer sees nothing during the whole probe.
--
-- init_r7 intentionally starts just past boot:'s settle loop (see
-- roms/m9312h47.mac -- ~100*65536 instructions, added so the ARM/HPS
-- mount handshake has landed before the probe runs) rather than at the
-- true reset vector 173000: the settle loop's own control flow was
-- verified separately (a temporary trimmed-constant run reached the
-- same fallthrough/found result below), and running the real ~6.5M-
-- instruction version here on every regression pass would make this
-- test impractically slow for what it actually needs to check.
--
-- Expected-good: mt/rk/rl (bit-test probes) each fall through, rh's
-- probe succeeds (RMDS DRY high), and PC proceeds into the "rp" banner
-- print / rpgo -- proving the RTL media-status logic itself is correct
-- regardless of the separate ARM-side mount-timing race (see the
-- "boot ROM: settle before probing" commit).
--
-- Run: sim/run_sim.sh tb_boot_probe --stop-time=200us

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_boot_probe is
   generic (
      budget : integer := 6000        -- cpu-clock cycles before giving up
   );
end tb_boot_probe;

architecture sim of tb_boot_probe is

   signal clk        : std_logic := '0';
   signal clk50      : std_logic := '0';
   signal reset      : std_logic := '1';

   signal addr       : std_logic_vector(21 downto 0);
   signal dati       : std_logic_vector(15 downto 0) := (others => '0');
   signal dato       : std_logic_vector(15 downto 0);
   signal control_dati  : std_logic;
   signal control_dato  : std_logic;
   signal control_datob : std_logic;
   signal addr_match : std_logic;
   signal cons_run   : std_logic;
   signal dbg_r7     : std_logic_vector(15 downto 0);
   signal dbg_psw    : std_logic_vector(15 downto 0);
   signal dbg_ir     : std_logic_vector(15 downto 0);

   type ram_t is array(0 to 65535) of std_logic_vector(15 downto 0);
   signal ram : ram_t := (others => (others => '0'));

   function oct(v : std_logic_vector) return string is
      variable u : unsigned(v'length + 2 downto 0) := (others => '0');
      variable r : string(1 to (v'length + 2) / 3);
      variable d : integer;
   begin
      u(v'length - 1 downto 0) := unsigned(v);
      for i in r'reverse_range loop
         d := to_integer(u(2 downto 0));
         r(i) := character'val(character'pos('0') + d);
         u := shift_right(u, 3);
      end loop;
      return r;
   end function;

begin

   clk   <= not clk   after 10 ns;
   clk50 <= not clk50 after 1 ns;
   reset <= '1', '0' after 205 ns;

   dut : entity work.unibus
      port map(
         modelcode    => 70,
         have_kl11    => 0,
         have_kw11l   => 1,
         kw11l_hz     => 800,

         have_rh      => 1,
         rh_type      => 6,
         rh_img_mounted => 1,             -- only RH has media

         have_rk      => 1,
         rk_img_mounted => 0,             -- present, empty

         have_rl      => 1,
         rl_img_mounted => 0,             -- present, empty

         have_tm      => 1,
         tm_img_mounted => 0,             -- present, empty

         init_r7      => x"f616",         -- o'173026' = boot:, just past the settle loop
         init_psw     => x"00e0",

         addr         => addr,
         dati         => dati,
         dato         => dato,
         control_dati => control_dati,
         control_dato => control_dato,
         control_datob=> control_datob,
         addr_match   => addr_match,

         cons_run     => cons_run,
         dbg_r7       => dbg_r7,
         dbg_psw      => dbg_psw,
         dbg_ir       => dbg_ir,

         clk          => clk,
         clk50mhz     => clk50,
         reset        => reset
      );

   -- zero-wait-state RAM below the I/O page
   addr_match <= '1' when addr(21 downto 13) /= "111111111"
                     and unsigned(addr) < 131072
                 else '0';

   dati <= ram(to_integer(unsigned(addr(16 downto 1))))
           when addr_match = '1'
           else (others => '0');

   process(clk)
   begin
      if rising_edge(clk) then
         if addr_match = '1' and control_dato = '1' then
            if control_datob = '0' then
               ram(to_integer(unsigned(addr(16 downto 1)))) <= dato;
            elsif addr(0) = '0' then
               ram(to_integer(unsigned(addr(16 downto 1))))(7 downto 0) <= dato(7 downto 0);
            else
               ram(to_integer(unsigned(addr(16 downto 1))))(15 downto 8) <= dato(15 downto 8);
            end if;
         end if;
      end if;
   end process;

   -- PC tracer: instruction fetches from the M9312 ROM and CSR polls to
   -- rk/rh are internally decoded inside unibus.vhd and never touch the
   -- external addr/dati/addr_match path (that's only for genuine plain
   -- RAM) -- so watch dbg_r7 (live PC) directly instead.
   process
      variable last_r7 : std_logic_vector(15 downto 0) := (others => '1');
      variable i : integer := 0;
   begin
      wait until reset = '0';
      loop
         wait until rising_edge(clk);
         i := i + 1;
         if dbg_r7 /= last_r7 then
            report "t=" & integer'image(i) & " pc=" & oct(dbg_r7) &
               " ir=" & oct(dbg_ir) & " psw=" & oct(dbg_psw);
            last_r7 := dbg_r7;
         end if;
         exit when i >= budget;
      end loop;
      report "budget exhausted at t=" & integer'image(i) & ", last pc=" & oct(last_r7) severity note;
      wait;
   end process;

end sim;
