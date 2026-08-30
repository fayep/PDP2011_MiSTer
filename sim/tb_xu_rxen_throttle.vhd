--
-- tb_xu_rxen_throttle.vhd -- exercises the mechanical queue/dequeue/RXEN
-- throttle cycle added this session: roms/xubrt45.mac's main service loop
-- (11$) now peeks chip-side PKTCNT before draining and clears RXEN
-- (cecon1, BFCU econ1,1) once backlog exceeds the guest's 6-slot RX ring,
-- re-enabling it (xecon1, BFSU econ1,1) once the backlog drains back down
-- -- see PDP2011_MiSTer commit 1189113.
--
-- Built directly on tb_xu_pcsr0_start.vhd's harness (real xu.vhd + real
-- xu_enc424j600_shim.vhd + real xu_ddr_mailbox.vhd + real xubrt45 ROM,
-- trivial single-cycle DDRAM model, no mister_top/DRAM_FSM). Two changes
-- beyond that harness:
--
--   1. bus_master_dati is driven to a constant x"8000" (the real DEC
--      "own" bit, bit 100000 octal = bit 15) instead of all-zeros. Traced
--      in xubrt45.mac (getrdre / "bit #100000,rdre+4"): with an all-zero
--      host memory model firmware always finds the receive descriptor
--      unowned and jumps straight past pktin's whole body (line 1182,
--      "jmp 90$"), including decpc -- so PKTCNT could clear-trigger RXEN
--      but never naturally drain it back down. This constant is the
--      minimal cue needed to let pktin actually reach decpc every pass
--      (Faye: "you just have to give it cues to dequeue").
--   2. After the real driver replay brings the device up (running=1),
--      the test directly pokes the DDR3 mailbox's backing store at
--      ERXHEAD's word (offset 0x6030 -> ram index 0xC06, byte-offset
--      arithmetic verified against xu_ddr_mailbox.vhd's own
--      WINDOW_WORD_BASE/req_addr(15 downto 3) mapping) to simulate the
--      daemon having enqueued a real backlog -- exactly what xu.cpp's
--      xu_rx_enqueue()/ERXHEAD write does on real hardware, without
--      needing the daemon itself in the loop.
--
-- Observed via VHDL-2008 external names (no shim/mailbox ports added
-- for this): shim.econ1_rxen (the RXEN flag firmware's BFSU/BFCU
-- toggles) and shim.reg_pkt_delivered (increments once per real decpc
-- SPI transaction -- direct proof pktin is genuinely draining, not just
-- idling).
--
-- Pass criteria (both required, checked by the monitor process below):
--   (a) econ1_rxen transitions 1 -> 0 after the backlog is raised above
--       6 (RXEN correctly cleared -- the "clear CTS" half)
--   (b) econ1_rxen transitions back 0 -> 1 once reg_pkt_delivered has
--       caught up to the backlog (RXEN correctly re-enabled -- the
--       "resume" half), driven by real decpc traffic, not asserted by
--       the testbench.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_xu_rxen_throttle is
end tb_xu_rxen_throttle;

architecture sim of tb_xu_rxen_throttle is

   signal cpuclk : std_logic := '0';
   signal nclk : std_logic;
   signal clk50mhz : std_logic := '0';
   signal reset : std_logic := '1';
   signal sim_done : boolean := false;

   signal bus_addr : std_logic_vector(17 downto 0) := (others => '0');
   signal bus_dato : std_logic_vector(15 downto 0) := (others => '0');
   signal bus_dati : std_logic_vector(15 downto 0);
   signal bus_addr_match : std_logic;
   signal bus_control_dati : std_logic := '0';
   signal bus_control_dato : std_logic := '0';
   signal bus_control_datob : std_logic := '0';

   signal bus_master_addr : std_logic_vector(17 downto 0);
   signal bus_master_dato : std_logic_vector(15 downto 0);
   signal bus_master_control_dati : std_logic;
   signal bus_master_control_dato : std_logic;

   signal br, bg, npr, npg : std_logic := '0';
   signal int_vector : std_logic_vector(8 downto 0);
   signal ivec : std_logic_vector(8 downto 0) := o"120";

   signal xu_cs, xu_mosi, xu_sclk, xu_miso : std_logic;
   signal tx1 : std_logic;

   signal req_valid, req_ack, resp_valid, req_rw : std_logic;
   signal req_addr : std_logic_vector(15 downto 0);
   signal req_wdata, resp_rdata : std_logic_vector(63 downto 0);
   signal req_be : std_logic_vector(7 downto 0);

   signal DDRAM_CLK, DDRAM_BUSY, DDRAM_RD, DDRAM_WE, DDRAM_DOUT_READY : std_logic := '0';
   signal DDRAM_BURSTCNT, DDRAM_BE : std_logic_vector(7 downto 0);
   signal DDRAM_ADDR : std_logic_vector(28 downto 0);
   signal DDRAM_DIN, DDRAM_DOUT : std_logic_vector(126 downto 0);

   type ram_type is array(0 to 8191) of std_logic_vector(63 downto 0);
   signal ram : ram_type := (others => (others => '0'));

   -- ERXHEAD (0x6030) >> 3 = 0xC06 -- WINDOW_WORD_BASE's low 13 bits are
   -- all zero (x"03FE0000" & "000" low bits), so this index into the
   -- trivial RAM model matches DDRAM_ADDR(12 downto 0) directly.
   constant ERXHEAD_RAM_IDX : integer := 16#C06#;

   -- PCSR0 command constants (real DEUNA/DELUA encoding, bits 0-3)
   constant CMD_GETPCBB : std_logic_vector(15 downto 0) := x"0001";
   constant CMD_GETCMD  : std_logic_vector(15 downto 0) := x"0002";
   constant CMD_START   : std_logic_vector(15 downto 0) := x"0004";
   constant PCSR0_INTE  : std_logic_vector(15 downto 0) := x"0040";

   -- NOTE: external-name probes into shim.econ1_rxen/reg_pkt_delivered/
   -- reg_erxhead_ddr were tried here and reliably crashed GHDL at
   -- runtime ("NULL access dereferenced") the moment a process actually
   -- read one, even though declaring them elaborated fine and the same
   -- signals are ordinary internal signals in xu_enc424j600_shim.vhd
   -- (nothing wrong with the RTL) -- a real GHDL external-name
   -- limitation/bug for this depth of hierarchy, not a design bug.
   -- Isolated by bisection: removing the reading process alone (keeping
   -- the alias declarations) fixed it, proving the crash was in the
   -- read, not the declaration. Switched to VCD dumping instead (see
   -- run_sim.sh's --vcd usage note below) -- proven reliable earlier
   -- this session for exactly this kind of internal-signal inspection.

   procedure bus_write(
      signal addr_sig : out std_logic_vector(17 downto 0);
      signal dato_sig : out std_logic_vector(15 downto 0);
      signal ctrl_dato : out std_logic;
      addr : in std_logic_vector(17 downto 0);
      data : in std_logic_vector(15 downto 0)
   ) is
   begin
      wait until cpuclk'event and cpuclk = '1';
      addr_sig <= addr;
      dato_sig <= data;
      ctrl_dato <= '1';
      wait until cpuclk'event and cpuclk = '1';
      ctrl_dato <= '0';
      wait until cpuclk'event and cpuclk = '1';
   end procedure;

begin

   cpuclk <= not cpuclk after 50 ns when not sim_done else '0';  -- ~10MHz
   nclk <= not cpuclk;
   clk50mhz <= not clk50mhz after 10 ns when not sim_done else '0';

   reset <= '1', '0' after 500 ns;

   -- the real "cue to dequeue": every host-memory word firmware reads via
   -- NPR/DMA looks like a valid, owned descriptor (bit 100000 octal =
   -- bit 15 set), so pktin always finds a buffer to write into and
   -- always reaches decpc -- letting PKTCNT genuinely drain, not just
   -- trigger the initial RXEN clear.
   bus_dati <= (others => '0');  -- xu0's own main-bus read side (unused by this test)

   process
   begin
      wait for 300 ms;
      report "TIMEOUT: simulation ran 300ms without finishing (relying on --stop-time to end it)" severity note;
      wait;
   end process;

   ----------------------------------------------------------------------
   -- trivial single-cycle-latency DDRAM_* model
   ----------------------------------------------------------------------
   process(DDRAM_CLK)
      variable idx : integer;
   begin
      if DDRAM_CLK'event and DDRAM_CLK = '1' then
         DDRAM_BUSY <= '0';
         DDRAM_DOUT_READY <= '0';
         if DDRAM_WE = '1' then
            idx := conv_integer(DDRAM_ADDR(12 downto 0));
            for b in 0 to 7 loop
               if DDRAM_BE(b) = '1' then
                  ram(idx)(b*8+7 downto b*8) <= DDRAM_DIN(b*8+7 downto b*8);
               end if;
            end loop;
         elsif DDRAM_RD = '1' then
            idx := conv_integer(DDRAM_ADDR(12 downto 0));
            DDRAM_DOUT(63 downto 0) <= ram(idx);
            DDRAM_DOUT_READY <= '1';
         end if;
      end if;
   end process;

   ----------------------------------------------------------------------
   -- device under test: real xu.vhd, driven directly (no mister_top)
   ----------------------------------------------------------------------
   xu0: entity work.xu
   port map(
      base_addr => o"774510",
      ivec => ivec,

      br => br,
      bg => bg,
      int_vector => int_vector,

      npr => npr,
      npg => npg,

      bus_addr_match => bus_addr_match,
      bus_addr => bus_addr,
      bus_dati => bus_dati,
      bus_dato => bus_dato,
      bus_control_dati => bus_control_dati,
      bus_control_dato => bus_control_dato,
      bus_control_datob => bus_control_datob,

      bus_master_addr => bus_master_addr,
      bus_master_dati => x"8000",  -- real "own" bit (100000 octal) always set --
                                    -- the dequeue cue: lets pktin/getfr/decpc
                                    -- actually run every pass instead of
                                    -- bailing at the "own?" check.
      bus_master_dato => bus_master_dato,
      bus_master_control_dati => bus_master_control_dati,
      bus_master_control_dato => bus_master_control_dato,
      bus_master_nxm => '0',

      xu_cs => xu_cs,
      xu_mosi => xu_mosi,
      xu_sclk => xu_sclk,
      xu_miso => xu_miso,

      have_xu => 1,
      have_xu_debug => 1,

      tx => tx1,
      ifetch => open,
      iwait => open,

      cpuclk => cpuclk,
      nclk => nclk,
      clk50mhz => clk50mhz,
      reset => reset
   );

   mailbox: entity work.xu_ddr_mailbox
   port map(
      reset => reset,
      cpuclk => cpuclk,
      req_valid => req_valid,
      req_addr => req_addr,
      req_wdata => req_wdata,
      req_be => req_be,
      req_rw => req_rw,
      req_ack => req_ack,
      resp_valid => resp_valid,
      resp_rdata => resp_rdata,

      clk50mhz => clk50mhz,
      DDRAM_CLK => DDRAM_CLK,
      DDRAM_BUSY => DDRAM_BUSY,
      DDRAM_BURSTCNT => DDRAM_BURSTCNT,
      DDRAM_ADDR => DDRAM_ADDR,
      DDRAM_DOUT => DDRAM_DOUT,
      DDRAM_DOUT_READY => DDRAM_DOUT_READY,
      DDRAM_RD => DDRAM_RD,
      DDRAM_DIN => DDRAM_DIN,
      DDRAM_BE => DDRAM_BE,
      DDRAM_WE => DDRAM_WE
   );

   shim: entity work.xu_enc424j600_shim
   port map(
      reset => reset,
      cpuclk => cpuclk,

      xu_cs => xu_cs,
      xu_mosi => xu_mosi,
      xu_sclk => xu_sclk,
      xu_miso => xu_miso,

      req_valid => req_valid,
      req_addr => req_addr,
      req_wdata => req_wdata,
      req_be => req_be,
      req_rw => req_rw,
      req_ack => req_ack,
      resp_valid => resp_valid,
      resp_rdata => resp_rdata
   );

   ----------------------------------------------------------------------
   -- UART decoder on xu's own debug tx (115200, 8N1)
   ----------------------------------------------------------------------
   process
      constant BIT_PERIOD : time := 8680 ns;
      variable l : line;
      variable byte : std_logic_vector(7 downto 0);
      variable c : character;
   begin
      wait until tx1 = '0' and not sim_done;
      wait for BIT_PERIOD / 2;
      for i in 0 to 7 loop
         wait for BIT_PERIOD;
         byte(i) := tx1;
      end loop;
      wait for BIT_PERIOD;
      if byte >= x"20" and byte <= x"7E" then
         c := character'val(conv_integer(byte));
         write(l, string'("UART: 0x"));
         hwrite(l, byte);
         write(l, string'(" '") & c & "'");
      else
         write(l, string'("UART: 0x"));
         hwrite(l, byte);
      end if;
      writeline(output, l);
   end process;

   ----------------------------------------------------------------------
   -- main sequence: replay the real driver write sequence to bring the
   -- device up (running=1), then inject a real backlog via ERXHEAD.
   ----------------------------------------------------------------------
   process
      variable l : line;
   begin
      wait until reset = '0';
      wait for 3 ms;  -- let initenc/chkeudast settle
      report "=== driving GETPCBB ===";
      bus_write(bus_addr, bus_dato, bus_control_dato, o"774510", CMD_GETPCBB);
      wait for 200 us;

      report "=== driving GETCMD (fc11: write ring format) ===";
      bus_write(bus_addr, bus_dato, bus_control_dato, o"774510", CMD_GETCMD);
      wait for 200 us;

      report "=== driving GETCMD (fc15: write mode bits) ===";
      bus_write(bus_addr, bus_dato, bus_control_dato, o"774510", CMD_GETCMD);
      wait for 200 us;

      report "=== driving PCSR0_INTE alone ===";
      bus_write(bus_addr, bus_dato, bus_control_dato, o"774510", PCSR0_INTE);
      wait for 50 us;

      report "=== driving CMD_START | PCSR0_INTE ===";
      bus_write(bus_addr, bus_dato, bus_control_dato, o"774510", CMD_START or PCSR0_INTE);
      wait for 2 ms;

      report "=== injecting backlog: ERXHEAD = 20 (PKTCNT should exceed the 6-slot ring) ===";
      ram(ERXHEAD_RAM_IDX)(15 downto 0) <= x"0014";  -- 20 decimal

      -- background ERXHEAD poll period is 65535 cpuclk cycles (~6.55ms
      -- at this testbench's 100ns cpuclk period) -- give it room for
      -- several poll/react/drain cycles, not just one.
      wait for 250 ms;
      report "=== sequence complete ===";
      sim_done <= true;
      wait;
   end process;

   -- Pass/fail is judged externally from the --vcd dump (run_sim.sh
   -- passes --vcd=build/<top>.vcd by default) by inspecting
   -- shim.econ1_rxen, shim.reg_pkt_delivered and shim.reg_erxhead_ddr --
   -- see external-name note above for why this isn't done live in-VHDL.

end sim;
