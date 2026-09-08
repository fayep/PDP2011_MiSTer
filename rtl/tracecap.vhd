--
-- Generic, device-independent event-trace capture: a ring-buffer memory
-- fed by up to TRACE_NUM_SOURCES independent event producers (disk-
-- transfer completions, MMU PAR writes, or anything added later), each
-- presenting the SAME generic {valid,kind,src,a,b,c} shape defined in
-- tracecap_pkg. This module has zero knowledge of what RL11, RH11, or
-- the MMU actually are.
--
-- Pure passive observation: every input here is an already-computed
-- signal from elsewhere: nothing in this module feeds back into, or can
-- alter the timing of, the logic it watches. This is the real advantage
-- real hardware has over the SIMH-side reconstruction this mirrors
-- (pdp11dis/diskmem.py) -- there, ANY software instrumentation (a
-- breakpoint, even one with an instantaneous auto-continuing action)
-- measurably changed real RSTS boot behavior (see
-- notes/rsts-init-disasm.md's "11 vs 22 hits" finding); a parallel
-- hardware tap that only reads already-latched state cannot do that.
--
-- Read-out is via a separate, purely combinational read port, meant to
-- be walked sequentially by tracecap_dbg.sv (EXT_BUS command 0x51),
-- mirroring how panel_dbg.sv (command 0x50) already streams live CPU
-- state to the ARM side over the same SPI/UIO bridge -- deliberately
-- NOT mapped into the PDP-11's own physical address space (Faye: "keep
-- this somewhat isolated from the PDP, like a BMC or Supervisor
-- board"). Combinational read means no BRAM-latency pipelining is
-- needed on the reader side; at DEPTH=16384 entries x 68 bits (~1.1
-- Mbit) this still infers cleanly as block RAM, which is the right
-- tradeoff for something only ever read out slowly, over SPI, well
-- after the events it holds were captured.
--
-- Depth is 16384 events, wrapping (oldest silently overwritten) on
-- overflow. The original DEPTH_LOG2=11 (2048) sizing was based on
-- notes/rsts-init-disasm.md's SIMH full-boot event-count estimate
-- (~1083) -- real hardware filled that in well under a full boot
-- (confirmed directly: a real capture read back count=2048, wrap=1,
-- i.e. already full), since it has none of SIMH's artificial seek/
-- rotation delays slowing PAR writes and disk completions down to a
-- SIMH-realistic pace. 16384 is a first bigger step, not a
-- rigorously-derived number -- if real captures still wrap before
-- covering the window of interest, it can go higher again for
-- whatever BRAM budget the target device has to spare.
--
-- Entity ports are FLAT std_logic_vectors (one source's fields
-- concatenated after another), not the tracecap_pkg array types --
-- this instantiates from pdp2011.sv (SystemVerilog), and a plain wire
-- bus is what reliably binds across that language boundary; the
-- array types are only used internally, for the arbitration logic's
-- own readability. Source index 0 occupies the low bits of each flat
-- vector, source 1 the next slice up, and so on.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use work.tracecap_pkg.all;

entity tracecap is
   generic (
      DEPTH_LOG2 : integer := 14  -- 16384 entries
   );
   port (
      clk : in std_logic;
      reset : in std_logic;

      -- One input per source; index order fixed at the instantiation
      -- site (see pdp2011.sv). Unused indices' src_valid tied to '0'.
      src_valid   : in std_logic_vector(TRACE_NUM_SOURCES-1 downto 0);
      src_kind_v  : in std_logic_vector(TRACE_NUM_SOURCES*TRACE_KIND_WIDTH-1 downto 0);
      src_id_v    : in std_logic_vector(TRACE_NUM_SOURCES*TRACE_SRC_WIDTH-1 downto 0);
      src_a_v     : in std_logic_vector(TRACE_NUM_SOURCES*TRACE_A_WIDTH-1 downto 0);
      src_b_v     : in std_logic_vector(TRACE_NUM_SOURCES*TRACE_B_WIDTH-1 downto 0);
      src_c_v     : in std_logic_vector(TRACE_NUM_SOURCES*TRACE_C_WIDTH-1 downto 0);

      overflowed : out std_logic;  -- sticky: the ring buffer has wrapped at least once

      -- read-out port, driven by tracecap_dbg.sv; combinational read,
      -- see header comment.
      rd_addr : in std_logic_vector(DEPTH_LOG2-1 downto 0);
      rd_kind : out trace_kind_t;
      rd_id   : out trace_src_t;
      rd_a    : out trace_a_t;
      rd_b    : out trace_b_t;
      rd_c    : out trace_c_t;
      wr_ptr  : out std_logic_vector(DEPTH_LOG2-1 downto 0)
   );
end entity tracecap;

architecture rtl of tracecap is
   constant DEPTH : integer := 2**DEPTH_LOG2;

   type mem_kind_t is array (0 to DEPTH-1) of trace_kind_t;
   type mem_id_t   is array (0 to DEPTH-1) of trace_src_t;
   type mem_a_t    is array (0 to DEPTH-1) of trace_a_t;
   type mem_b_t    is array (0 to DEPTH-1) of trace_b_t;
   type mem_c_t    is array (0 to DEPTH-1) of trace_c_t;

   signal mem_kind : mem_kind_t;
   signal mem_id   : mem_id_t;
   signal mem_a    : mem_a_t;
   signal mem_b    : mem_b_t;
   signal mem_c    : mem_c_t;

   signal src_kind : trace_kind_array;
   signal src_id   : trace_src_array;
   signal src_a    : trace_a_array;
   signal src_b    : trace_b_array;
   signal src_c    : trace_c_array;

   signal wptr    : std_logic_vector(DEPTH_LOG2-1 downto 0) := (others => '0');
   signal wrapped : std_logic := '0';
   signal filled_once : std_logic := '0';  -- true once every slot has been written at least once

   -- Real event pulses (trace_disk_valid/trace_par_valid) are generated
   -- in rl11.vhd/rh11.vhd/mmu.vhd's OWN clock domain (nclk, the
   -- throttled CPU instruction clock), not this module's `clk`
   -- (clk_100mhz). nclk is far slower, so a single nclk-wide pulse
   -- holds '1' across MANY clk cycles -- sampling src_valid directly,
   -- as an earlier version of this module did, captured the SAME real
   -- event as a dozen-plus duplicate entries (confirmed on real
   -- hardware: bursts of 12-14 identical a/b values in a row). A
   -- 2-flop synchronizer (CDC-safe) plus rising-edge detection turns
   -- each foreign-clock-domain level, of whatever width, into exactly
   -- one clean pulse here, regardless of the nclk:clk ratio.
   type sync_t is array (0 to TRACE_NUM_SOURCES-1) of std_logic_vector(2 downto 0);
   signal valid_sync : sync_t := (others => (others => '0'));
   signal valid_pulse : std_logic_vector(TRACE_NUM_SOURCES-1 downto 0);

   -- Fixed-priority arbiter across sources: index 0 wins ties. Real
   -- events are sparse relative to clk (the SPI-clock analysis in
   -- notes/rsts-init-disasm.md puts even a tight worst-case burst in
   -- the low thousands/sec, vs a clk in the tens of MHz), so two
   -- sources firing on the exact same clock edge is a real but narrow
   -- case; the lower-priority one loses that single cycle's event
   -- rather than being queued. A per-source input FIFO would close
   -- this gap if it ever matters in practice -- not done here, flagged
   -- rather than silently assumed away.
   function first_set(v : std_logic_vector) return integer is
   begin
      for i in v'reverse_range loop
         if v(i) = '1' then
            return i;
         end if;
      end loop;
      return -1;
   end function;

   signal sel : integer range -1 to TRACE_NUM_SOURCES-1;
begin

   -- Unpack the flat entity-boundary vectors into per-source array
   -- elements, once, for the arbitration/capture logic below.
   unpack: for i in 0 to TRACE_NUM_SOURCES-1 generate
      src_kind(i) <= src_kind_v((i+1)*TRACE_KIND_WIDTH-1 downto i*TRACE_KIND_WIDTH);
      src_id(i)   <= src_id_v((i+1)*TRACE_SRC_WIDTH-1 downto i*TRACE_SRC_WIDTH);
      src_a(i)    <= src_a_v((i+1)*TRACE_A_WIDTH-1 downto i*TRACE_A_WIDTH);
      src_b(i)    <= src_b_v((i+1)*TRACE_B_WIDTH-1 downto i*TRACE_B_WIDTH);
      src_c(i)    <= src_c_v((i+1)*TRACE_C_WIDTH-1 downto i*TRACE_C_WIDTH);
   end generate;

   sel <= first_set(valid_pulse);

   sync_and_edge_detect: for i in 0 to TRACE_NUM_SOURCES-1 generate
      valid_pulse(i) <= valid_sync(i)(1) and not valid_sync(i)(2);
   end generate;

   process(clk)
   begin
      if rising_edge(clk) then
         if reset = '1' then
            valid_sync <= (others => (others => '0'));
            wptr <= (others => '0');
            wrapped <= '0';
            filled_once <= '0';
         else
            for i in 0 to TRACE_NUM_SOURCES-1 loop
               valid_sync(i) <= valid_sync(i)(1 downto 0) & src_valid(i);
            end loop;

            if sel >= 0 then
               mem_kind(conv_integer(wptr)) <= src_kind(sel);
               mem_id(conv_integer(wptr))   <= src_id(sel);
               mem_a(conv_integer(wptr))    <= src_a(sel);
               mem_b(conv_integer(wptr))    <= src_b(sel);
               mem_c(conv_integer(wptr))    <= src_c(sel);
               -- `wrapped` means "some earlier event's slot has genuinely
               -- been overwritten", which is only true once the ring was
               -- ALREADY full (filled_once) before THIS write -- setting
               -- it on the write that merely fills the last fresh slot
               -- (wptr=DEPTH-1) would be one write too early, since that
               -- write doesn't overwrite anything yet.
               if filled_once = '1' then
                  wrapped <= '1';
               end if;
               if wptr = conv_std_logic_vector(DEPTH-1, DEPTH_LOG2) then
                  filled_once <= '1';
               end if;
               wptr <= wptr + 1;
            end if;
         end if;
      end if;
   end process;

   overflowed <= wrapped;
   wr_ptr <= wptr;

   rd_kind <= mem_kind(conv_integer(rd_addr));
   rd_id   <= mem_id(conv_integer(rd_addr));
   rd_a    <= mem_a(conv_integer(rd_addr));
   rd_b    <= mem_b(conv_integer(rd_addr));
   rd_c    <= mem_c(conv_integer(rd_addr));

end architecture rtl;
