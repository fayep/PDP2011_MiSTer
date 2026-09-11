-- deps: tracecap_pkg.vhd tracecap.vhd
--
-- tb_tracecap.vhd -- GHDL dry-run harness for rtl/tracecap.vhd
--
-- No mocks needed: tracecap.vhd only depends on tracecap_pkg.vhd, so this
-- drives the generic {src_valid, src_kind_v, src_id_v, src_a_v, src_b_v,
-- src_c_v} entity boundary directly with synthetic events -- the same
-- flat-vector shape pdp2011.sv packs real RL11/RH11/MMU taps into.
--
-- Uses a small DEPTH_LOG2=4 (16 entries) generic override so the
-- wraparound/overflow path can be exercised in a handful of events
-- instead of the real 2048-entry default -- the ring-buffer logic is
-- depth-independent, so this covers the same code path.
--
-- Checks: single-source capture (kind/id/a/b/c round-trip through the
-- flat-vector packing), fixed-priority arbitration when two sources
-- fire on the same clock edge (lower index wins, higher index's event
-- for that cycle is genuinely lost -- not queued), wr_ptr advances by
-- exactly one per accepted event even when N sources request the same
-- cycle, a MULTI-CYCLE-HELD source pulse (the real bug this session
-- found on hardware: rl11.vhd/rh11.vhd/mmu.vhd's trigger pulses live in
-- the nclk domain, far slower than tracecap's own clk, so a raw level
-- sampled directly produced a dozen-plus duplicate entries per real
-- event) still produces EXACTLY ONE captured event, ring wraparound
-- sets the sticky `overflowed` flag and the oldest entry is genuinely
-- overwritten, and reset clears wr_ptr/overflowed.
--
-- Event pulses now go through a 2-flop synchronizer + rising-edge
-- detector inside the DUT (see tracecap.vhd), adding a few cycles of
-- latency between asserting a source and its event actually landing --
-- this testbench waits generously (settle_after_event = 6 cycles,
-- comfortably more than the 3-cycle synchronizer chain needs) rather
-- than hand-deriving the exact minimum, and that margin was itself
-- verified empirically against a real GHDL run before being trusted.
--
-- Run:  sim/run_sim.sh tb_tracecap --stop-time=10us
-- (the free-running clock process never stops on its own -- every
-- testbench in this tree needs an explicit --stop-time bound)
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use work.tracecap_pkg.all;

entity tb_tracecap is
end tb_tracecap;

architecture sim of tb_tracecap is

   constant DEPTH_LOG2 : integer := 4;   -- 16 entries, see header
   constant DEPTH      : integer := 2**DEPTH_LOG2;

   signal clk   : std_logic := '0';
   signal reset : std_logic := '1';

   signal src_valid  : std_logic_vector(TRACE_NUM_SOURCES-1 downto 0) := (others => '0');
   signal src_kind_v : std_logic_vector(TRACE_NUM_SOURCES*TRACE_KIND_WIDTH-1 downto 0) := (others => '0');
   signal src_id_v   : std_logic_vector(TRACE_NUM_SOURCES*TRACE_SRC_WIDTH-1 downto 0) := (others => '0');
   signal src_a_v    : std_logic_vector(TRACE_NUM_SOURCES*TRACE_A_WIDTH-1 downto 0) := (others => '0');
   signal src_b_v    : std_logic_vector(TRACE_NUM_SOURCES*TRACE_B_WIDTH-1 downto 0) := (others => '0');
   signal src_c_v    : std_logic_vector(TRACE_NUM_SOURCES*TRACE_C_WIDTH-1 downto 0) := (others => '0');
   signal src_d_v    : std_logic_vector(TRACE_NUM_SOURCES*TRACE_D_WIDTH-1 downto 0) := (others => '0');

   signal overflowed : std_logic;
   signal wr_ptr     : std_logic_vector(DEPTH_LOG2-1 downto 0);

   signal rd_addr : std_logic_vector(DEPTH_LOG2-1 downto 0) := (others => '0');
   signal rd_kind : trace_kind_t;
   signal rd_id   : trace_src_t;
   signal rd_a    : trace_a_t;
   signal rd_b    : trace_b_t;
   signal rd_c    : trace_c_t;
   signal rd_d    : trace_d_t;

   signal fail_count : integer := 0;

   -- Packs one source's fields into the flat vectors at index `i`,
   -- leaving every other source untouched -- mirrors pdp2011.sv's own
   -- per-source slice convention (index 0 in the low bits).
   procedure set_source(
      i : integer;
      valid : std_logic;
      kind  : trace_kind_t;
      id    : trace_src_t;
      a     : trace_a_t;
      b     : trace_b_t;
      c     : trace_c_t;
      d     : trace_d_t;
      signal sv : out std_logic_vector;
      signal kv : out std_logic_vector;
      signal iv : out std_logic_vector;
      signal av : out std_logic_vector;
      signal bv : out std_logic_vector;
      signal cv : out std_logic_vector;
      signal dv : out std_logic_vector
   ) is
   begin
      sv(i) <= valid;
      kv((i+1)*TRACE_KIND_WIDTH-1 downto i*TRACE_KIND_WIDTH) <= kind;
      iv((i+1)*TRACE_SRC_WIDTH-1 downto i*TRACE_SRC_WIDTH) <= id;
      av((i+1)*TRACE_A_WIDTH-1 downto i*TRACE_A_WIDTH) <= a;
      bv((i+1)*TRACE_B_WIDTH-1 downto i*TRACE_B_WIDTH) <= b;
      cv((i+1)*TRACE_C_WIDTH-1 downto i*TRACE_C_WIDTH) <= c;
      dv((i+1)*TRACE_D_WIDTH-1 downto i*TRACE_D_WIDTH) <= d;
   end procedure;

begin

   clk <= not clk after 10 ns;

   dut: entity work.tracecap
      generic map(
         DEPTH_LOG2 => DEPTH_LOG2
      )
      port map(
         clk => clk,
         reset => reset,

         src_valid => src_valid,
         src_kind_v => src_kind_v,
         src_id_v => src_id_v,
         src_a_v => src_a_v,
         src_b_v => src_b_v,
         src_c_v => src_c_v,
         src_d_v => src_d_v,

         overflowed => overflowed,

         rd_addr => rd_addr,
         rd_kind => rd_kind,
         rd_id => rd_id,
         rd_a => rd_a,
         rd_b => rd_b,
         rd_c => rd_c,
         rd_d => rd_d,
         wr_ptr => wr_ptr
      );

   stim: process

      procedure clk_edges(n : integer) is
      begin
         for i in 1 to n loop
            wait until rising_edge(clk);
         end loop;
      end procedure;

      procedure clear_sources is
      begin
         src_valid <= (others => '0');
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

      -- Asserts source `i` for `hold_cycles` clk edges (simulating a
      -- real nclk-domain pulse, which can be many clk cycles wide),
      -- clears it, then waits long enough for the synchronizer +
      -- edge-detector to land the single resulting event.
      procedure fire_event(
         i : integer;
         hold_cycles : integer;
         kind : trace_kind_t;
         id   : trace_src_t;
         a    : trace_a_t;
         b    : trace_b_t;
         c    : trace_c_t;
         d    : trace_d_t := (trace_d_t'range => '0')
      ) is
      begin
         set_source(i, '1', kind, id, a, b, c, d,
                    src_valid, src_kind_v, src_id_v, src_a_v, src_b_v, src_c_v, src_d_v);
         clk_edges(hold_cycles);
         clear_sources;
         clk_edges(6);  -- settle_after_event, see header comment
      end procedure;

   begin
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      reset <= '0';
      wait until rising_edge(clk);

      ------------------------------------------------------------------
      -- reset clears wr_ptr and overflowed
      ------------------------------------------------------------------
      chk16("post-reset wr_ptr=0", wr_ptr, conv_std_logic_vector(0, DEPTH_LOG2));
      chk_bit("post-reset overflowed=0", overflowed, '0');

      ------------------------------------------------------------------
      -- single-source capture: source 0 (RL-shaped) fires one event,
      -- held for just 1 cycle (the "clean" case)
      ------------------------------------------------------------------
      fire_event(0, 1, TRACE_KIND_DISK, "0000",
                 conv_std_logic_vector(16#0004#, TRACE_A_WIDTH),
                 conv_std_logic_vector(16#1000#, TRACE_B_WIDTH),
                 conv_std_logic_vector(16#0200#, TRACE_C_WIDTH),
                 conv_std_logic_vector(16#06D4EC01#, TRACE_D_WIDTH));

      chk16("event0 wr_ptr advanced to 1", wr_ptr, conv_std_logic_vector(1, DEPTH_LOG2));
      rd_addr <= conv_std_logic_vector(0, DEPTH_LOG2);
      wait for 1 ns;  -- combinational read
      chk16("event0 kind", rd_kind, TRACE_KIND_DISK);
      chk16("event0 id", rd_id, "0000");
      chk16("event0 a (LBN)", rd_a, conv_std_logic_vector(16#0004#, TRACE_A_WIDTH));
      chk16("event0 b (dest)", rd_b, conv_std_logic_vector(16#1000#, TRACE_B_WIDTH));
      chk16("event0 c (wc)", rd_c, conv_std_logic_vector(16#0200#, TRACE_C_WIDTH));
      chk16("event0 d (KDPAR5/6 snapshot)", rd_d, conv_std_logic_vector(16#06D4EC01#, TRACE_D_WIDTH));

      ------------------------------------------------------------------
      -- THE REAL BUG: a source held for MANY cycles (simulating the
      -- real nclk-domain pulse width vs tracecap's clk) must still
      -- produce EXACTLY ONE event, not one per cycle it's held.
      ------------------------------------------------------------------
      fire_event(1, 14, TRACE_KIND_DISK, "0001",
                 conv_std_logic_vector(16#0099#, TRACE_A_WIDTH),
                 conv_std_logic_vector(16#3324#, TRACE_B_WIDTH),
                 conv_std_logic_vector(16#0000#, TRACE_C_WIDTH));

      chk16("14-cycle-held pulse: exactly ONE event (wr_ptr=2)", wr_ptr,
            conv_std_logic_vector(2, DEPTH_LOG2));
      rd_addr <= conv_std_logic_vector(1, DEPTH_LOG2);
      wait for 1 ns;
      chk16("held-pulse event a", rd_a, conv_std_logic_vector(16#0099#, TRACE_A_WIDTH));
      chk16("held-pulse event b", rd_b, conv_std_logic_vector(16#3324#, TRACE_B_WIDTH));

      ------------------------------------------------------------------
      -- simultaneous sources: 0 and 2 (MMU-shaped) fire the SAME cycle --
      -- fixed priority means source 0 wins, source 2's event for this
      -- cycle is genuinely dropped (not queued for the next cycle)
      ------------------------------------------------------------------
      set_source(0, '1', TRACE_KIND_DISK, "0001",
                 conv_std_logic_vector(16#0010#, TRACE_A_WIDTH),
                 conv_std_logic_vector(16#2000#, TRACE_B_WIDTH),
                 conv_std_logic_vector(16#0040#, TRACE_C_WIDTH),
                 conv_std_logic_vector(0, TRACE_D_WIDTH),
                 src_valid, src_kind_v, src_id_v, src_a_v, src_b_v, src_c_v, src_d_v);
      set_source(2, '1', TRACE_KIND_PARW, "0010",
                 conv_std_logic_vector(16#0005#, TRACE_A_WIDTH),
                 conv_std_logic_vector(16#0510#, TRACE_B_WIDTH),
                 conv_std_logic_vector(16#0000#, TRACE_C_WIDTH),
                 conv_std_logic_vector(0, TRACE_D_WIDTH),
                 src_valid, src_kind_v, src_id_v, src_a_v, src_b_v, src_c_v, src_d_v);
      clk_edges(1);
      clear_sources;
      clk_edges(6);

      chk16("tie: wr_ptr advanced by exactly one", wr_ptr, conv_std_logic_vector(3, DEPTH_LOG2));
      rd_addr <= conv_std_logic_vector(2, DEPTH_LOG2);
      wait for 1 ns;
      chk16("tie: source 0 won (kind=disk)", rd_kind, TRACE_KIND_DISK);
      chk16("tie: source 0 won (id=1, not mmu's 2)", rd_id, "0001");
      chk16("tie: source 0 won (a=0010, not mmu's 0005)", rd_a, conv_std_logic_vector(16#0010#, TRACE_A_WIDTH));

      -- source 2's event was dropped, not queued: fire ONLY source 2 next
      -- and confirm it lands as a fresh, independent event, not silently
      -- replayed from the lost cycle above.
      fire_event(2, 1, TRACE_KIND_PARW, "0010",
                 conv_std_logic_vector(16#0005#, TRACE_A_WIDTH),
                 conv_std_logic_vector(16#0510#, TRACE_B_WIDTH),
                 conv_std_logic_vector(16#0000#, TRACE_C_WIDTH));

      chk16("post-tie mmu event: wr_ptr=4", wr_ptr, conv_std_logic_vector(4, DEPTH_LOG2));
      rd_addr <= conv_std_logic_vector(3, DEPTH_LOG2);
      wait for 1 ns;
      chk16("post-tie mmu event kind", rd_kind, TRACE_KIND_PARW);
      chk16("post-tie mmu event id", rd_id, "0010");

      ------------------------------------------------------------------
      -- ring wraparound: fill the remaining slots, then one more --
      -- overflowed must set, and slot 0 (event0 from above) must be
      -- overwritten by the wraparound write.
      ------------------------------------------------------------------
      for n in 4 to DEPTH-1 loop
         fire_event(1, 1, TRACE_KIND_DISK, "0001",
                    conv_std_logic_vector(n, TRACE_A_WIDTH),
                    conv_std_logic_vector(0, TRACE_B_WIDTH),
                    conv_std_logic_vector(0, TRACE_C_WIDTH));
      end loop;

      chk_bit("just before wraparound: overflowed still 0", overflowed, '0');
      chk16("just before wraparound: wr_ptr=0 (about to wrap)", wr_ptr, conv_std_logic_vector(0, DEPTH_LOG2));

      -- one more event: this is the write that actually wraps
      fire_event(1, 1, TRACE_KIND_DISK, "0001",
                 conv_std_logic_vector(16#7777#, TRACE_A_WIDTH),
                 conv_std_logic_vector(0, TRACE_B_WIDTH),
                 conv_std_logic_vector(0, TRACE_C_WIDTH));

      chk_bit("after wraparound: overflowed=1 (sticky)", overflowed, '1');
      rd_addr <= conv_std_logic_vector(0, DEPTH_LOG2);
      wait for 1 ns;
      chk16("slot 0 overwritten by wraparound write", rd_a, conv_std_logic_vector(16#7777#, TRACE_A_WIDTH));

      -- overflowed stays set even with no further events (sticky, not
      -- a one-cycle pulse)
      clk_edges(3);
      chk_bit("overflowed remains sticky", overflowed, '1');

      ------------------------------------------------------------------
      if fail_count = 0 then
         report "tb_tracecap: ALL CHECKS PASSED" severity note;
      else
         report "tb_tracecap: " & integer'image(fail_count) & " CHECK(S) FAILED" severity failure;
      end if;
      wait;
   end process;

end sim;
