--
-- tb_xu_header_unit.vhd -- minimal firmware "unit test" harness. Drives
-- roms/xubrt45.mac's TEMPORARY test hook at PCSR0 command 3 (c0011,
-- "self-test", normally an unused stub -- see its own comment), which
-- reproduces pktin's exact 3-transaction header-read sequence
-- (werxrdpt/rnpp/rpkth) against a fixed test address, with zero
-- running/rcurr/ring-init dependency. Dispatched directly from
-- pcsrsrv via p0cmd=3 -- the same top-level mechanism already proven
-- for commands 1/2/4 in every other testbench this session -- so this
-- needs none of the host-memory-DMA modeling that blocked
-- tb_xu_erxrdpt_cache.vhd's own attempt to reach pktin naturally.
--
-- Injects one real-format header (matching support/xu/xu.cpp's
-- xu_rx_enqueue() layout exactly: next_ptr[2 LE] + framelen[2 LE] +
-- RSV[4]=0) directly into the DDR3 mailbox backing store at the test
-- address (0x4800, matching XU_BUF_RX_OFF), then drives PCSR0 cmd=3 and
-- checks the UART trace: "TEST flen:" should show the injected
-- framelen's bytes exactly, not garbage.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_xu_header_unit is
end tb_xu_header_unit;

architecture sim of tb_xu_header_unit is

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

   constant CMD_SELFTEST : std_logic_vector(15 downto 0) := x"0003";

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

   bus_dati <= (others => '0');

   process
   begin
      wait for 60 ms;
      report "TIMEOUT: simulation ran 60ms without finishing (relying on --stop-time to end it)" severity note;
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
      bus_master_dati => x"8000",  -- matches every other proven-working testbench this session
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
   -- main sequence: inject one real-format header at the test address,
   -- then dispatch PCSR0 cmd=3 directly -- no ring-init needed at all.
   ----------------------------------------------------------------------
   process
      constant TEST_START   : integer := 16#4800#;
      constant TEST_FRAMELEN : integer := 1234;  -- deliberately not round, easy to spot
      variable next_ptr : integer;
      variable widx, blane : integer;
   begin
      wait until reset = '0';

      report "=== injecting one real-format header at 0x4800, framelen=1234 ===";
      next_ptr := TEST_START + 8 + TEST_FRAMELEN;  -- real content beyond header not needed for this test
      widx := (TEST_START + 0) / 8; blane := (TEST_START + 0) mod 8;
      ram(widx)(blane*8+7 downto blane*8) <= conv_std_logic_vector(next_ptr mod 256, 8);
      widx := (TEST_START + 1) / 8; blane := (TEST_START + 1) mod 8;
      ram(widx)(blane*8+7 downto blane*8) <= conv_std_logic_vector((next_ptr / 256) mod 256, 8);
      widx := (TEST_START + 2) / 8; blane := (TEST_START + 2) mod 8;
      ram(widx)(blane*8+7 downto blane*8) <= conv_std_logic_vector(TEST_FRAMELEN mod 256, 8);
      widx := (TEST_START + 3) / 8; blane := (TEST_START + 3) mod 8;
      ram(widx)(blane*8+7 downto blane*8) <= conv_std_logic_vector((TEST_FRAMELEN / 256) mod 256, 8);
      for k in 4 to 7 loop
         widx := (TEST_START + k) / 8; blane := (TEST_START + k) mod 8;
         ram(widx)(blane*8+7 downto blane*8) <= x"00";
      end loop;

      -- No command dispatch needed at all -- the test now runs
      -- automatically right after the real boot sequence completes
      -- (init/waitabit/banner/initenc all still real and intact,
      -- inserted right after initenc), so there's zero timing-collision
      -- risk. That real sequence takes ~5.65ms+ before it even starts
      -- printing (confirmed elsewhere this session) -- give it real
      -- margin.
      wait for 20 ms;
      report "=== sequence complete ===";
      sim_done <= true;
      wait;
   end process;

end sim;
