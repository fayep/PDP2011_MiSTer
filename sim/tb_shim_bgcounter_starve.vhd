--
-- tb_shim_bgcounter_starve.vhd -- reproduces xmitxx's real ECON1 spin
-- loop (roms/xubrt45.mac: "recon1: .byte rcru,econ1" -- a plain RCRU
-- read, no B0SEL prefix -- issued back-to-back with zero delay while
-- waiting for TXRTS to clear) against the REAL, unmodified xubl.vhd and
-- xu_enc424j600_shim.vhd, to verify the background TXRTS_DONE poll still
-- gets a turn under continuous, tight foreground SPI traffic. Real
-- hardware bug found 2026-08-29: bg_counter used to be reset to 0 on
-- EVERY foreground mailbox request, including the speculative RRXDATA-
-- priming fetch that fires on the first bit of every SPI transaction
-- regardless of actual opcode -- so a plain RCRU loop with no gaps kept
-- resetting the timer before it could ever reach BG_POLL_PERIOD,
-- permanently starving the TXRTS_DONE poll. FIX constant selects the
-- buggy (bg_counter reset every fg request) vs fixed (bg_counter only
-- reset by an actual background poll) behavior.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_shim_bgcounter_starve is
end tb_shim_bgcounter_starve;

architecture sim of tb_shim_bgcounter_starve is

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

   type ddr_ram_type is array(0 to 8191) of std_logic_vector(63 downto 0);
   signal ddr_ram : ddr_ram_type := (others => (others => '0'));

   -- single driver for ddr_ram, shared by the mailbox RAM model and the
   -- fake-daemon TXRTS_DONE write below (a real testbench bug found
   -- earlier this session: two separate processes racing to drive the
   -- same signal produces std_logic resolution 'X's).
   signal daemon_write_idx : integer range 0 to 8191 := 0;
   signal daemon_write_data : std_logic_vector(63 downto 0) := (others => '0');
   signal daemon_write_valid : std_logic := '0';

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
   clk50mhz_sig <= not clk50mhz_sig after 10 ns when not sim_done else '0';
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

   -- DDR3 mailbox RAM model, plain fast (1-cycle) response -- this test
   -- is about starvation, not latency.
   process(DDRAM_CLK)
      variable idx : integer;
   begin
      if DDRAM_CLK'event and DDRAM_CLK = '1' then
         DDRAM_BUSY <= '0';
         DDRAM_DOUT_READY <= '0';
         if daemon_write_valid = '1' then
            ddr_ram(daemon_write_idx) <= daemon_write_data;
         elsif DDRAM_WE = '1' then
            idx := conv_integer(DDRAM_ADDR(12 downto 0));
            for b in 0 to 7 loop
               if DDRAM_BE(b) = '1' then
                  ddr_ram(idx)(b*8+7 downto b*8) <= DDRAM_DIN(b*8+7 downto b*8);
               end if;
            end loop;
         elsif DDRAM_RD = '1' then
            idx := conv_integer(DDRAM_ADDR(12 downto 0));
            DDRAM_DOUT(63 downto 0) <= ddr_ram(idx);
            DDRAM_DOUT_READY <= '1';
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

   -- fake daemon: watches TXRTS_REQ (DDR offset 0x6008), and once set,
   -- waits a short real delay (modeling actual send latency) then writes
   -- TXRTS_DONE (0x6010) = 1. Matches xu_poll_tx()'s real handshake.
   process
      variable req_word : std_logic_vector(63 downto 0);
   begin
      wait until reset = '0';
      loop
         wait for 100 ns;
         req_word := ddr_ram(3073);  -- 0x6008 >> 3
         if req_word(0) = '1' then
            wait for 2000 ns;  -- simulated send latency
            daemon_write_idx <= 3074;  -- 0x6010 >> 3
            daemon_write_data <= x"0000000000000001";
            wait until DDRAM_CLK'event and DDRAM_CLK = '1';
            daemon_write_valid <= '1';
            wait until DDRAM_CLK'event and DDRAM_CLK = '1';
            daemon_write_valid <= '0';
            wait for 2000 ns;
            exit;
         end if;
         if sim_done then
            exit;
         end if;
      end loop;
      wait;
   end process;

   ----------------------------------------------------------------------
   -- main test sequence: set RXEN, set TXRTS (via BFSU, matching
   -- tecon1's real template), then hammer plain RCRU reads of ECON1
   -- (matching recon1's real template, no B0SEL) back-to-back with zero
   -- delay -- exactly xmitxx's real spin loop -- until TXRTS clears or a
   -- generous timeout elapses.
   ----------------------------------------------------------------------
   process
      variable l : line;
      variable iters : integer := 0;
      variable econ1 : std_logic_vector(7 downto 0);
   begin
      wait until reset = '0';
      wait for 500 ns;

      -- tecon1: bfsu,econ1,2,0 -- set TXRTS (bit 1). Word = (byte_sent_second<<8)|byte_sent_first.
      preload(0, x"1e24", preload_idx, preload_data, preload_valid, cpuclk);  -- econ1_addr(0x1e)<<8 | bfsu(0x24)
      preload(1, x"0002", preload_idx, preload_data, preload_valid, cpuclk);  -- data hi=0x00, data lo=0x02 (TXRTS mask)
      wait for 20 ns;
      prog_write("000", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);  -- 32 bits (opcode+addr+2 data)
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      -- recon1 spin loop: rcru,econ1 (16 bits: opcode+addr), read 2 bytes
      -- back, zero delay between iterations.
      preload(10, x"1e20", preload_idx, preload_data, preload_valid, cpuclk);  -- rcru(0x20)<<8 | econ1_addr(0x1e)
      wait for 20 ns;
      loop
         iters := iters + 1;
         prog_write("000", x"0014", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 10 (byte 20)
         prog_write("010", x"001E", bus_addr, bus_dato, bus_control_dato, nclk);  -- rt = word addr 15 (byte 30)
         prog_write("011", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);  -- rl = 32 bits (2 bytes -- rounds to word)
         prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);  -- xl = 16 bits
         wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;

         econ1 := mem(15)(7 downto 0);
         exit when econ1(1) = '0';
         exit when iters > 10000;
      end loop;

      write(l, string'("recon1 spin loop: iters="));
      write(l, iters);
      write(l, string'(" final econ1="));
      hwrite(l, mem(15));
      writeline(output, l);

      if econ1(1) = '0' then
         write(l, string'("PASS bg-counter-starve TXRTS cleared, background poll not starved"));
      else
         write(l, string'("FAIL bg-counter-starve TXRTS never cleared -- background poll starved"));
      end if;
      writeline(output, l);

      wait for 500 ns;
      sim_done <= true;
      wait;
   end process;

end sim;
