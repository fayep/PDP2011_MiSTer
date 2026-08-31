--
-- tb_xu_pcsr0_start.vhd -- fast, standalone GHDL testbench for the real
-- question this session couldn't answer from real-hardware logs alone:
-- does a main-UNIBUS write of "CMD_START | PCSR0_INTE" (exactly what
-- 2.11BSD's real if_de.c deinit() does, traced from strings pulled off
-- the disk image) ever reach xu.vhd's pcsrsrv dispatch and get serviced
-- by c0100 (the START handler)?
--
-- Drives cpuclk/nclk/clk50mhz directly (no mister_top, no DRAM_FSM) --
-- avoids the stall tb_mister_top hit, which turned out to be a testbench
-- setup artifact, not a real bug (Faye's call, confirmed).
--
-- Replays the exact main-bus write sequence 2.11BSD's deinit() performs,
-- against the real xu.vhd + real xu_enc424j600_shim.vhd + real
-- xu_ddr_mailbox.vhd + real xubrt45 firmware ROM, with a trivial
-- always-ready DDR3 model (same approach tb_mister_top used).
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_xu_pcsr0_start is
end tb_xu_pcsr0_start;

architecture sim of tb_xu_pcsr0_start is

   signal cpuclk : std_logic := '0';
   signal nclk : std_logic;
   signal clk50mhz : std_logic := '0';
   signal reset : std_logic := '1';
   signal sim_done : boolean := false;

   -- main-bus (CPU-facing) side of xu0
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

   -- DDR3 mailbox <-> shim interface
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

   -- PCSR0 command constants (real DEUNA/DELUA encoding, bits 0-3)
   constant CMD_GETPCBB : std_logic_vector(15 downto 0) := x"0001";
   constant CMD_GETCMD  : std_logic_vector(15 downto 0) := x"0002";
   constant CMD_START   : std_logic_vector(15 downto 0) := x"0004";
   constant PCSR0_INTE  : std_logic_vector(15 downto 0) := x"0040";

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

   process
   begin
      wait for 10 ms;
      report "TIMEOUT: simulation ran 10ms without finishing (relying on --stop-time to end it)" severity note;
      wait;
   end process;

   ----------------------------------------------------------------------
   -- trivial single-cycle-latency DDRAM_* model (same as tb_mister_top)
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
      bus_master_dati => (others => '0'),
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

   ----------------------------------------------------------------------
   -- real DDR3 mailbox + ENC424J600 shim, same wiring as unibus.vhd
   ----------------------------------------------------------------------
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
   -- UART decoder on xu's own debug tx (115200, 8N1) -- prints each byte
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
   -- main sequence: replay 2.11BSD's real deinit() write sequence onto
   -- the main UNIBUS side of xu0, exactly as traced from if_de.c strings
   -- pulled off the disk image this session.
   ----------------------------------------------------------------------
   process
      variable l : line;
   begin
      wait until reset = '0';
      wait for 3 ms;  -- let initenc/chkeudast settle (real hardware: <<1s)
      report "=== driving GETPCBB ===";
      bus_write(bus_addr, bus_dato, bus_control_dato, o"774510", CMD_GETPCBB);
      wait for 200 us;

      report "=== driving GETCMD (fc11: write ring format) ===";
      bus_write(bus_addr, bus_dato, bus_control_dato, o"774510", CMD_GETCMD);
      wait for 200 us;

      report "=== driving GETCMD (fc15: write mode bits) ===";
      bus_write(bus_addr, bus_dato, bus_control_dato, o"774510", CMD_GETCMD);
      wait for 200 us;

      report "=== driving PCSR0_INTE alone (matches deinit()'s own first write) ===";
      bus_write(bus_addr, bus_dato, bus_control_dato, o"774510", PCSR0_INTE);
      wait for 50 us;

      report "=== driving CMD_START | PCSR0_INTE (the real write in question) ===";
      bus_write(bus_addr, bus_dato, bus_control_dato, o"774510", CMD_START or PCSR0_INTE);

      wait for 2 ms;
      report "=== sequence complete, waiting for tail activity ===";
      wait for 2 ms;
      sim_done <= true;
      wait;
   end process;

end sim;
