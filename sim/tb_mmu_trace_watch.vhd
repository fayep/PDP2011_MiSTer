-- tb_mmu_trace_watch.vhd -- GHDL dry-run harness for
-- rtl/mmu_trace_watch.vhd, the isolated bus-watching replacement for
-- the trace_kdpar5/6/trace_kipar5/6 ports this session originally (and
-- wrongly) added directly to mmu.vhd's own entity/write-decode.
--
-- Drives cpu_addr/cpu_dataout/cpu_wr/cpu_dw8 directly (the same signals
-- unibus.vhd already has and already feeds to mmu0) -- no mmu.vhd
-- instance needed at all, proving the whole point: this module is
-- fully independent of the device it watches.
--
-- Checks:
--   1. Write to KIPAR5 (172352) updates trace_kipar5, leaves the other
--      three untouched.
--   2. Write to KIPAR6 (172354) updates trace_kipar6 only.
--   3. Write to KDPAR5 (172372) updates trace_kdpar5 only.
--   4. Write to KDPAR6 (172374) updates trace_kdpar6 only.
--   5. Byte write updates only the touched half (matches mmu.vhd's own
--      mmu_dato byte-select convention).
--   6. An address one word off in either direction (172350, 172356,
--      172370, 172376) does not affect any of the four -- catches an
--      off-by-one in the octal literals, the exact class of bug that
--      motivated writing this file's own reference addresses out
--      explicitly rather than computing them.
--   7. cpu_wr='0' (a read, or an idle bus) never updates anything, even
--      with a matching address and settled data.
--   8. reset clears all four to zero.
--
-- Run: sim/run_sim.sh tb_mmu_trace_watch --stop-time=10us

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity tb_mmu_trace_watch is
end tb_mmu_trace_watch;

architecture sim of tb_mmu_trace_watch is

   signal clk   : std_logic := '0';
   signal reset : std_logic := '1';

   signal cpu_addr    : std_logic_vector(15 downto 0) := (others => '0');
   signal cpu_dataout : std_logic_vector(15 downto 0) := (others => '0');
   signal cpu_wr      : std_logic := '0';
   signal cpu_dw8     : std_logic := '0';

   signal trace_kdpar5 : std_logic_vector(15 downto 0);
   signal trace_kdpar6 : std_logic_vector(15 downto 0);
   signal trace_kipar5 : std_logic_vector(15 downto 0);
   signal trace_kipar6 : std_logic_vector(15 downto 0);

   signal fail_count : integer := 0;

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

begin

   clk <= not clk after 10 ns;

   dut: mmu_trace_watch port map(
      clk => clk,
      reset => reset,
      cpu_addr => cpu_addr,
      cpu_dataout => cpu_dataout,
      cpu_wr => cpu_wr,
      cpu_dw8 => cpu_dw8,
      trace_kdpar5 => trace_kdpar5,
      trace_kdpar6 => trace_kdpar6,
      trace_kipar5 => trace_kipar5,
      trace_kipar6 => trace_kipar6
   );

   stim: process

      procedure clk_edges(n : integer) is
      begin
         for i in 1 to n loop
            wait until rising_edge(clk);
         end loop;
      end procedure;

      procedure chk16(tag : string; got, exp : std_logic_vector) is
      begin
         if got = exp then
            report "PASS " & tag;
         else
            report "FAIL " & tag & " got=" & integer'image(conv_integer(got))
                 & " exp=" & integer'image(conv_integer(exp)) severity error;
            fail_count <= fail_count + 1;
         end if;
      end procedure;

      procedure do_write(addr : integer; data : integer; dw8 : std_logic := '0') is
      begin
         cpu_addr    <= conv_std_logic_vector(addr, 16);
         cpu_dataout <= conv_std_logic_vector(data, 16);
         cpu_dw8     <= dw8;
         cpu_wr      <= '1';
         wait until rising_edge(clk);
         cpu_wr <= '0';
         cpu_dw8 <= '0';
         wait until rising_edge(clk);
      end procedure;

   begin
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      wait until rising_edge(clk);

      ------------------------------------------------------------------
      -- 0. all zero post-reset
      ------------------------------------------------------------------
      chk16("post-reset trace_kdpar5=0", trace_kdpar5, conv_std_logic_vector(0, 16));
      chk16("post-reset trace_kdpar6=0", trace_kdpar6, conv_std_logic_vector(0, 16));
      chk16("post-reset trace_kipar5=0", trace_kipar5, conv_std_logic_vector(0, 16));
      chk16("post-reset trace_kipar6=0", trace_kipar6, conv_std_logic_vector(0, 16));

      ------------------------------------------------------------------
      -- 1. KIPAR5 (172352) -- the pair that actually matters
      ------------------------------------------------------------------
      do_write(8#172352#, 16#3333#);
      chk16("KIPAR5 write updates trace_kipar5", trace_kipar5, conv_std_logic_vector(16#3333#, 16));
      chk16("KIPAR5 write leaves trace_kdpar5 untouched", trace_kdpar5, conv_std_logic_vector(0, 16));
      chk16("KIPAR5 write leaves trace_kdpar6 untouched", trace_kdpar6, conv_std_logic_vector(0, 16));
      chk16("KIPAR5 write leaves trace_kipar6 untouched", trace_kipar6, conv_std_logic_vector(0, 16));
      clk_edges(2);

      ------------------------------------------------------------------
      -- 2. KIPAR6 (172354)
      ------------------------------------------------------------------
      do_write(8#172354#, 16#CCCC#);
      chk16("KIPAR6 write updates trace_kipar6", trace_kipar6, conv_std_logic_vector(16#CCCC#, 16));
      chk16("KIPAR6 write leaves trace_kipar5 untouched", trace_kipar5, conv_std_logic_vector(16#3333#, 16));
      clk_edges(2);

      ------------------------------------------------------------------
      -- 3. KDPAR5 (172372)
      ------------------------------------------------------------------
      do_write(8#172372#, 16#AAAA#);
      chk16("KDPAR5 write updates trace_kdpar5", trace_kdpar5, conv_std_logic_vector(16#AAAA#, 16));
      chk16("KDPAR5 write leaves trace_kipar5 untouched", trace_kipar5, conv_std_logic_vector(16#3333#, 16));
      clk_edges(2);

      ------------------------------------------------------------------
      -- 4. KDPAR6 (172374)
      ------------------------------------------------------------------
      do_write(8#172374#, 16#5555#);
      chk16("KDPAR6 write updates trace_kdpar6", trace_kdpar6, conv_std_logic_vector(16#5555#, 16));
      chk16("KDPAR6 write leaves trace_kdpar5 untouched", trace_kdpar5, conv_std_logic_vector(16#AAAA#, 16));
      clk_edges(2);

      ------------------------------------------------------------------
      -- 5. byte write -- only the touched half changes (odd address ->
      -- high byte, matching mmu.vhd's own byte-select convention)
      ------------------------------------------------------------------
      do_write(8#172353#, 16#00FF#, '1');  -- odd address -> high byte of KIPAR5
      chk16("byte write to odd KIPAR5 address updates only high byte", trace_kipar5, conv_std_logic_vector(16#FF33#, 16));
      clk_edges(2);

      ------------------------------------------------------------------
      -- 6. off-by-one addresses -- must not touch anything
      ------------------------------------------------------------------
      do_write(8#172350#, 16#7777#);
      chk16("172350 (one word below KIPAR5) does not affect trace_kipar5", trace_kipar5, conv_std_logic_vector(16#FF33#, 16));
      clk_edges(2);
      do_write(8#172356#, 16#7777#);
      chk16("172356 (one word above KIPAR6) does not affect trace_kipar6", trace_kipar6, conv_std_logic_vector(16#CCCC#, 16));
      clk_edges(2);
      do_write(8#172370#, 16#7777#);
      chk16("172370 (one word below KDPAR5) does not affect trace_kdpar5", trace_kdpar5, conv_std_logic_vector(16#AAAA#, 16));
      clk_edges(2);
      do_write(8#172376#, 16#7777#);
      chk16("172376 (one word above KDPAR6) does not affect trace_kdpar6", trace_kdpar6, conv_std_logic_vector(16#5555#, 16));
      clk_edges(2);

      ------------------------------------------------------------------
      -- 7. cpu_wr=0 never updates, even with a matching address
      ------------------------------------------------------------------
      cpu_addr <= conv_std_logic_vector(8#172352#, 16);
      cpu_dataout <= conv_std_logic_vector(16#1234#, 16);
      cpu_wr <= '0';
      clk_edges(3);
      chk16("cpu_wr=0 does not update trace_kipar5 despite matching address", trace_kipar5, conv_std_logic_vector(16#FF33#, 16));

      ------------------------------------------------------------------
      -- 8. reset clears all four
      ------------------------------------------------------------------
      reset <= '1';
      clk_edges(2);
      reset <= '0';
      clk_edges(1);
      chk16("reset clears trace_kdpar5", trace_kdpar5, conv_std_logic_vector(0, 16));
      chk16("reset clears trace_kdpar6", trace_kdpar6, conv_std_logic_vector(0, 16));
      chk16("reset clears trace_kipar5", trace_kipar5, conv_std_logic_vector(0, 16));
      chk16("reset clears trace_kipar6", trace_kipar6, conv_std_logic_vector(0, 16));

      ------------------------------------------------------------------
      if fail_count = 0 then
         report "tb_mmu_trace_watch: ALL CHECKS PASSED" severity note;
      else
         report "tb_mmu_trace_watch: " & integer'image(fail_count) & " CHECK(S) FAILED" severity failure;
      end if;
      wait;
   end process;

end sim;
