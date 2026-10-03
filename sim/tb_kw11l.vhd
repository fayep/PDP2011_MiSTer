-- deps: kw11l.vhd
--
-- tb_kw11l.vhd -- GHDL harness for rtl/kw11l.vhd (KW11-L line clock, LKS 777546)
--
-- Checks the 11/70 behaviour of the monitor bit and the interrupt:
--   - each tick sets bit 7; it stays set after the interrupt is granted and
--     until the program writes it 0 (writes can clear it, not set it)
--   - exactly one interrupt per tick while IE is on, none with IE off
--   - turning IE off cancels a request not yet granted
-- kw11l_hz = 800 so a tick comes every 1.25 ms of simulated time.
--
-- Run:  ghdl -a --std=08 -fsynopsys -frelaxed rtl/kw11l.vhd sim/tb_kw11l.vhd
--       ghdl -e --std=08 -fsynopsys -frelaxed tb_kw11l
--       ghdl -r --std=08 -fsynopsys -frelaxed tb_kw11l --stop-time=40ms
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity tb_kw11l is
end tb_kw11l;

architecture sim of tb_kw11l is

   constant LKS : std_logic_vector(17 downto 0) := o"777546";

   signal clk     : std_logic := '0';
   signal clk50   : std_logic := '0';
   signal reset   : std_logic := '1';
   signal b_addr  : std_logic_vector(17 downto 0) := (others => '0');
   signal b_dato  : std_logic_vector(15 downto 0) := (others => '0');
   signal b_dati  : std_logic_vector(15 downto 0);
   signal b_cdati : std_logic := '0';
   signal b_cdato : std_logic := '0';
   signal br, bg  : std_logic := '0';
   signal grants  : integer := 0;
   signal grant_enable : boolean := true;
   signal fail_count, pass_count : integer := 0;

begin

   clk   <= not clk after 70 ns;
   clk50 <= not clk50 after 10 ns;

   dut: entity work.kw11l port map(
      base_addr => LKS,
      ivec => o"100",
      br => br,
      bg => bg,
      int_vector => open,
      bus_addr_match => open,
      bus_addr => b_addr,
      bus_dati => b_dati,
      bus_dato => b_dato,
      bus_control_dati => b_cdati,
      bus_control_dato => b_cdato,
      bus_control_datob => '0',
      have_kw11l => 1,
      kw11l_hz => 800,
      reset => reset,
      clk50mhz => clk50,
      clk => clk
   );

   -- the CPU: grant a request after a few cycles (unless held off), count grants
   process
   begin
      wait until rising_edge(clk);
      if br = '1' and grant_enable then
         for i in 1 to 4 loop wait until rising_edge(clk); end loop;
         if grant_enable then
            bg <= '1';
            wait until rising_edge(clk) and br = '0';
            wait until rising_edge(clk);
            bg <= '0';
            grants <= grants + 1;
         end if;
      end if;
   end process;

   stim: process
      procedure wr(d : std_logic_vector(15 downto 0)) is
      begin
         wait until rising_edge(clk);
         b_addr <= LKS; b_dato <= d; b_cdato <= '1';
         wait until rising_edge(clk);
         b_cdato <= '0';
      end procedure;
      procedure rd(r : out std_logic_vector(15 downto 0)) is
      begin
         wait until rising_edge(clk);
         b_addr <= LKS; b_cdati <= '1';
         wait until rising_edge(clk);
         wait until rising_edge(clk);
         r := b_dati; b_cdati <= '0';
      end procedure;
      procedure ok(tag : string; cond : boolean) is
      begin
         if cond then pass_count <= pass_count + 1;
         else report "FAIL " & tag severity error; fail_count <= fail_count + 1; end if;
         wait for 0 ns;
      end procedure;
      variable v : std_logic_vector(15 downto 0);
      variable g0 : integer;
   begin
      wait for 1 us;
      reset <= '0';
      wait for 1 us;

      -- IE off: ticks set bit 7, no interrupts
      wr(x"0000");
      rd(v); ok("bit 7 clear after writing 0", v(7) = '0');
      g0 := grants;
      wait for 3 ms;                                      -- two ticks
      rd(v); ok("IE off: tick sets bit 7", v(7) = '1');
      ok("IE off: no interrupts", grants = g0);

      -- writing 1 to bit 7 must not set it
      wr(x"0000");
      wr(x"0080");
      rd(v); ok("writing 1 to bit 7 does not set it", v(7) = '0');

      -- IE on: one interrupt per tick, bit 7 still set after the grant
      wr(x"0040");
      g0 := grants;
      wait for 1.3 ms;                                     -- one tick
      rd(v); ok("after a granted tick bit 7 still set (300)", v(7) = '1' and v(6) = '1');
      ok("one tick -> exactly one interrupt", grants = g0 + 1);
      wait for 2.5 ms;                                     -- two more ticks
      ok("three ticks -> three interrupts", grants = g0 + 3);
      wr(x"0040");                                         -- clear bit 7, keep IE
      rd(v); ok("program clears bit 7 (100)", v = x"0040");

      -- IE turned off before the grant cancels the request
      grant_enable <= false;
      wait for 1.3 ms;                                     -- a tick: request pending, not granted
      ok("request pending while grants held", br = '1');
      wr(x"0000");                                         -- IE off
      wait for 2 us;
      ok("IE off drops the pending request", br = '0');
      g0 := grants;
      grant_enable <= true;
      wait for 3 ms;
      ok("no interrupt after IE went off", grants = g0);

      report "tb_kw11l: " & integer'image(pass_count) & " checks passed, " & integer'image(fail_count) & " failed";
      if fail_count = 0 then report "tb_kw11l: ALL CHECKS PASSED"; else report "tb_kw11l: FAILURES" severity error; end if;
      std.env.stop;
      wait;
   end process;

end sim;
