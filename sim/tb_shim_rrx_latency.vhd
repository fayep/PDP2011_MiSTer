--
-- tb_shim_rrx_latency.vhd -- stress test for the RRXDATA watchdog-hang fix
-- (rtl/xu_enc424j600_shim.vhd, 2026-08-29). The other testbenches
-- (tb_shim_stream, tb_shim_loopback) use a DDR3 RAM model with ~1-cycle
-- read latency, which is exactly why the original per-byte-round-trip
-- design's real hardware bug ("dog barks" watchdog reset right after
-- pcsr0 START) never showed up in simulation. This test adds a real,
-- deliberate multi-cycle read latency (60 clk50mhz cycles = 1200ns = 12
-- cpuclk cycles) -- longer than the OLD design's hard 8-cpuclk-cycle
-- per-byte deadline (would have corrupted byte1 onward), but well within
-- the NEW word-cache/double-buffer design's ~56-64-cycle per-word budget.
-- Reads 16 bytes via a single RRXDATA burst, spanning two 8-byte DDR3
-- words (exercises the nxt-buffer swap-on-exhaustion path), backdoor-
-- preloaded directly into ddr_ram (bypassing WGPDATA -- that path is
-- already covered by tb_shim_stream).
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_shim_rrx_latency is
end tb_shim_rrx_latency;

architecture sim of tb_shim_rrx_latency is

   signal cpuclk : std_logic := '0';
   signal nclk : std_logic;
   signal clk50mhz_sig : std_logic := '0';
   signal reset : std_logic := '1';
   signal sim_done : boolean := false;

   signal xu_cs, xu_mosi, xu_sclk, xu_miso : std_logic;

   constant BASE_ADDR : std_logic_vector(17 downto 0) := "000000000000010000";
   signal bus_addr : std_logic_vector(17 downto 0) := (others => '0');
   signal bus_dato : std_logic_vector(15 downto 0) := (others => '0');
   signal bus_control_dato : std_logic := '0';
   signal bus_dati : std_logic_vector(15 downto 0);
   signal bus_control_dati : std_logic := '0';
   signal bus_control_datob : std_logic := '0';
   signal bus_addr_match : std_logic;

   signal npr, npg : std_logic := '0';
   signal bus_master_addr : std_logic_vector(17 downto 0);
   signal bus_master_dati : std_logic_vector(15 downto 0);
   signal bus_master_dato : std_logic_vector(15 downto 0);
   signal bus_master_control_dati : std_logic;
   signal bus_master_control_dato : std_logic;
   signal bus_master_nxm : std_logic := '0';

   signal req_valid, req_ack, resp_valid, req_rw : std_logic;
   signal req_addr : std_logic_vector(15 downto 0);
   signal req_wdata, resp_rdata : std_logic_vector(63 downto 0);
   signal req_be : std_logic_vector(7 downto 0);

   signal DDRAM_CLK, DDRAM_BUSY, DDRAM_RD, DDRAM_WE, DDRAM_DOUT_READY : std_logic := '0';
   signal DDRAM_BURSTCNT, DDRAM_BE : std_logic_vector(7 downto 0);
   signal DDRAM_ADDR : std_logic_vector(28 downto 0);
   signal DDRAM_DIN, DDRAM_DOUT : std_logic_vector(126 downto 0);

   -- backdoor-preloaded: word0 = bytes 0x11,0x22,0x33,0x44,0,0,0,0
   --                     word1 = bytes 0x55,0x66,0x77,0x88,0x99,0xAA,0xBB,0xCC
   type ddr_ram_type is array(0 to 8191) of std_logic_vector(63 downto 0);
   signal ddr_ram : ddr_ram_type := (
      0 => x"0000000044332211",
      1 => x"CCBBAA9988776655",
      others => (others => '0'));

   type mem_type is array(0 to 63) of std_logic_vector(15 downto 0);
   signal mem : mem_type := (others => (others => '0'));
   signal preload_idx : integer range 0 to 63 := 0;
   signal preload_data : std_logic_vector(15 downto 0) := (others => '0');
   signal preload_valid : std_logic := '0';

   procedure prog_write(addr_bits : in std_logic_vector(2 downto 0);
                         data : in std_logic_vector(15 downto 0);
                         signal a : out std_logic_vector(17 downto 0);
                         signal d : out std_logic_vector(15 downto 0);
                         signal ctl : out std_logic;
                         signal clk : in std_logic) is
   begin
      a <= BASE_ADDR(17 downto 4) & addr_bits & '0';
      d <= data;
      wait until clk'event and clk = '1';
      ctl <= '1';
      wait until clk'event and clk = '1';
      ctl <= '0';
   end procedure;

   procedure preload(idx : in integer;
                      data : in std_logic_vector(15 downto 0);
                      signal p_idx : out integer;
                      signal p_data : out std_logic_vector(15 downto 0);
                      signal p_valid : out std_logic;
                      signal clk : in std_logic) is
   begin
      p_idx <= idx;
      p_data <= data;
      wait until clk'event and clk = '1';
      p_valid <= '1';
      wait until clk'event and clk = '1';
      p_valid <= '0';
   end procedure;

begin

   cpuclk <= not cpuclk after 50 ns when not sim_done else '0';  -- 10MHz
   nclk <= not cpuclk;
   clk50mhz_sig <= not clk50mhz_sig after 10 ns when not sim_done else '0';  -- 50MHz
   reset <= '1', '0' after 500 ns;
   npg <= '1';

   bus_master_dati <= mem(conv_integer(bus_master_addr(6 downto 1)));

   process(cpuclk)
   begin
      if cpuclk'event and cpuclk = '1' then
         if preload_valid = '1' then
            mem(preload_idx) <= preload_data;
         elsif bus_master_control_dato = '1' then
            mem(conv_integer(bus_master_addr(6 downto 1))) <= bus_master_dato;
         end if;
      end if;
   end process;

   ----------------------------------------------------------------------
   -- DDR3 mailbox RAM model, with a deliberate read latency: 60 clk50mhz
   -- cycles (1200ns = 12 cpuclk cycles) between DDRAM_RD and
   -- DDRAM_DOUT_READY. Writes stay instant (unused by this test).
   ----------------------------------------------------------------------
   process(DDRAM_CLK)
      variable idx : integer;
      variable delay_cnt : integer := 0;
      variable pending_read : boolean := false;
      constant READ_LATENCY : integer := 60;
   begin
      if DDRAM_CLK'event and DDRAM_CLK = '1' then
         DDRAM_BUSY <= '0';
         DDRAM_DOUT_READY <= '0';
         if DDRAM_WE = '1' then
            idx := conv_integer(DDRAM_ADDR(12 downto 0));
            for b in 0 to 7 loop
               if DDRAM_BE(b) = '1' then
                  ddr_ram(idx)(b*8+7 downto b*8) <= DDRAM_DIN(b*8+7 downto b*8);
               end if;
            end loop;
         elsif DDRAM_RD = '1' and not pending_read then
            idx := conv_integer(DDRAM_ADDR(12 downto 0));
            DDRAM_DOUT(63 downto 0) <= ddr_ram(idx);
            pending_read := true;
            delay_cnt := READ_LATENCY;
         elsif pending_read then
            if delay_cnt = 0 then
               DDRAM_DOUT_READY <= '1';
               pending_read := false;
            else
               delay_cnt := delay_cnt - 1;
            end if;
         end if;
      end if;
   end process;

   xubl0: entity work.xubl
   port map(
      base_addr => BASE_ADDR,
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
      bus_master_dati => bus_master_dati,
      bus_master_dato => bus_master_dato,
      bus_master_control_dati => bus_master_control_dati,
      bus_master_control_dato => bus_master_control_dato,
      bus_master_nxm => bus_master_nxm,
      xu_cs => xu_cs,
      xu_mosi => xu_mosi,
      xu_sclk => xu_sclk,
      xu_miso => xu_miso,
      reset => reset,
      xublclk => cpuclk,
      clk => nclk
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
      clk50mhz => clk50mhz_sig,
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

   ----------------------------------------------------------------------
   -- main test sequence
   ----------------------------------------------------------------------
   process
      variable l : line;
   begin
      wait until reset = '0';
      wait for 500 ns;

      ------------------------------------------------------------------
      -- werxrdpt: point the RX read pointer at byte offset 0
      ------------------------------------------------------------------
      preload(0, x"8A22", preload_idx, preload_data, preload_valid, cpuclk);  -- wcru(0x22), erxrdpt addr(0x8A)
      preload(1, x"0000", preload_idx, preload_data, preload_valid, cpuclk);  -- data lo/hi = 0
      wait for 20 ns;
      prog_write("000", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 0
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);  -- 32 bits (4 bytes)
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      ------------------------------------------------------------------
      -- rrxdata: b0sel,rrxdata -- read back 16 bytes (2 DDR3 words),
      -- through the deliberately slow mailbox above.
      ------------------------------------------------------------------
      preload(2, x"2CC0", preload_idx, preload_data, preload_valid, cpuclk);  -- rrxdata(0x2C)<<8 | b0sel(0xC0)
      wait for 20 ns;
      prog_write("000", x"0004", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 2 (byte addr 4)
      prog_write("010", x"0014", bus_addr, bus_dato, bus_control_dato, nclk);  -- rt = word addr 10 (byte addr 20)
      prog_write("011", x"0080", bus_addr, bus_dato, bus_control_dato, nclk);  -- rl = 128 bits (16 bytes)
      prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);  -- xl = 16 bits (b0sel+rrxdata)
      wait until xu_cs = '0' for 40 us; wait until xu_cs = '1' for 40 us;
      wait for 500 ns;

      write(l, string'("RRXDATA (slow mailbox) readback: "));
      for i in 10 to 17 loop
         hwrite(l, mem(i));
         write(l, string'(" "));
      end loop;
      writeline(output, l);

      if mem(10) = x"2211" and mem(11) = x"4433" and mem(12) = x"0000" and mem(13) = x"0000"
         and mem(14) = x"6655" and mem(15) = x"8877" and mem(16) = x"AA99" and mem(17) = x"CCBB"
      then
         write(l, string'("PASS rrxdata-slow-mailbox-16byte-cross-word"));
      else
         write(l, string'("FAIL rrxdata-slow-mailbox-16byte-cross-word"));
      end if;
      writeline(output, l);

      wait for 500 ns;
      sim_done <= true;
      wait;
   end process;

end sim;
