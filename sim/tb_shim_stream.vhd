--
-- tb_shim_real_master.vhd -- faithful GHDL testbench: instantiates the
-- REAL rtl/xubl.vhd (unmodified) as the SPI bus-master, driven exactly
-- the way roms/xubrt45.mac's real "xubl:" stub routine programs it
-- (write xf/rt/rl/xl via the regular bus interface, xl last -- triggers
-- run), against a simple RAM model on its bus_master_* DMA interface,
-- feeding it the exact same byte patterns chkeudast/initenc really send.
-- This replaces tb_shim.vhd's hand-bit-banged sender/receiver, which
-- needed a suspicious manual "extra edge" to pass -- this test checks
-- whether that was masking a real one-cycle CS/first-bit framing bug in
-- xu_enc424j600_shim.vhd's CS-edge-detection logic (see conversation,
-- 2026-08-27: xubl.vhd asserts cs and the first real data bit on the
-- SAME edge, but the shim spends that first edge only on state reset,
-- not sampling -- a hypothesis, not yet confirmed).
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_shim_stream is
end tb_shim_stream;

architecture sim of tb_shim_stream is

   signal cpuclk : std_logic := '0';
   signal nclk : std_logic;
   signal clk50mhz_sig : std_logic := '0';
   signal reset : std_logic := '1';
   signal sim_done : boolean := false;

   -- xubl0 <-> shim SPI pins
   signal xu_cs, xu_mosi, xu_sclk, xu_miso : std_logic;

   -- xubl0 regular bus interface (the "CPU" side, programs xf/xl/rt/rl)
   constant BASE_ADDR : std_logic_vector(17 downto 0) := "000000000000010000";
   signal bus_addr : std_logic_vector(17 downto 0) := (others => '0');
   signal bus_dato : std_logic_vector(15 downto 0) := (others => '0');
   signal bus_control_dato : std_logic := '0';
   signal bus_dati : std_logic_vector(15 downto 0);
   signal bus_control_dati : std_logic := '0';
   signal bus_control_datob : std_logic := '0';
   signal bus_addr_match : std_logic;

   -- xubl0 DMA master interface (the "memory" side)
   signal npr, npg : std_logic := '0';
   signal bus_master_addr : std_logic_vector(17 downto 0);
   signal bus_master_dati : std_logic_vector(15 downto 0);
   signal bus_master_dato : std_logic_vector(15 downto 0);
   signal bus_master_control_dati : std_logic;
   signal bus_master_control_dato : std_logic;
   signal bus_master_nxm : std_logic := '0';

   -- shim <-> mailbox
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

   -- "main memory" the real xu embedded CPU would DMA to/from --
   -- word-addressed (index = byte address / 2), 64 words is plenty
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

   cpuclk <= not cpuclk after 50 ns when not sim_done else '0';  -- 10MHz, matches cpuclk's documented rate
   nclk <= not cpuclk;
   clk50mhz_sig <= not clk50mhz_sig after 10 ns when not sim_done else '0';
   reset <= '1', '0' after 500 ns;
   npg <= '1';  -- constant grant -- no bus arbitration contention in this test

   ----------------------------------------------------------------------
   -- "main memory" model for xubl0's DMA master interface -- combinational
   -- read (zero wait state, matching xubl.vhd's own back-to-back word
   -- fetch assumption), registered write.
   ----------------------------------------------------------------------
   bus_master_dati <= mem(conv_integer(bus_master_addr(6 downto 1)));

   -- single driver for mem -- both DMA write-back and testbench preload
   -- go through this one process to avoid an unintended second driver
   -- (a real testbench bug found this session: a separate preload
   -- process racing this one produced std_logic resolution 'X's on
   -- every bit where the two drivers' held values disagreed).
   process(cpuclk)
      variable idx : integer;
   begin
      if cpuclk'event and cpuclk = '1' then
         if preload_valid = '1' then
            mem(preload_idx) <= preload_data;
         elsif bus_master_control_dato = '1' then
            idx := conv_integer(bus_master_addr(6 downto 1));
            mem(idx) <= bus_master_dato;
         end if;
      end if;
   end process;

   ----------------------------------------------------------------------
   -- DDR3 mailbox RAM model (same as tb_shim.vhd)
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

   ----------------------------------------------------------------------
   -- DUTs: real xubl.vhd (unmodified) as master, real shim as slave
   ----------------------------------------------------------------------
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
   -- main test sequence -- programs xubl0 exactly as roms/xubrt45.mac's
   -- real "xubl:" stub does (mov 0(r5),@#177000 [xf]; 4(r5),@#177004
   -- [rt]; 6(r5),@#177006 [rl]; 2(r5),@#177002 [xl, LAST -- triggers run]),
   -- using the real chkeudast + initenc 20$/30$ byte patterns.
   ----------------------------------------------------------------------
   process
      variable l : line;
      variable idx : integer;
   begin
      wait until reset = '0';
      wait for 500 ns;

      ------------------------------------------------------------------
      -- WGPDATA: real firmware pattern (roms/xubrt45.mac ~line 993:
      -- movb #b0sel,buf; movb #wgpdata,buf+1; <packet bytes...>; xubl
      -- buf,<bitcount>) -- b0sel prefix + wgpdata opcode + N data bytes,
      -- all in one continuous transmit, no receive phase. Sends 4 data
      -- bytes (0x11,0x22,0x33,0x44) starting at reg_egpwrpt's reset
      -- value (0x0000).
      ------------------------------------------------------------------
      preload(0, x"2AC0", preload_idx, preload_data, preload_valid, cpuclk);  -- wgpdata(0x2A)<<8 | b0sel(0xC0)
      preload(1, x"2211", preload_idx, preload_data, preload_valid, cpuclk);  -- data[1]=0x22, data[0]=0x11
      preload(2, x"4433", preload_idx, preload_data, preload_valid, cpuclk);  -- data[3]=0x44, data[2]=0x33
      wait for 20 ns;

      prog_write("000", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 0
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);  -- rt = 0 (unused, no recv)
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);  -- rl = 0 (no recv)
      prog_write("001", x"0030", bus_addr, bus_dato, bus_control_dato, nclk);  -- xl = 48 bits (6 bytes), triggers run

      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 2000 ns;  -- let the mailbox sequencer fully drain the last write

      write(l, string'("WGPDATA ddr_ram(0): 0x"));
      hwrite(l, ddr_ram(0));
      write(l, string'(" (expected 0x0000000044332211)"));
      writeline(output, l);
      if ddr_ram(0) = x"0000000044332211" then
         write(l, string'("PASS wgpdata-write (real xubl.vhd master)"));
      else
         write(l, string'("FAIL wgpdata-write (real xubl.vhd master)"));
      end if;
      writeline(output, l);

      ------------------------------------------------------------------
      -- reidled (rcru,eidled) sanity check -- confirm the shim still
      -- decodes ordinary RCRU/WCRU correctly after adding streaming I/O
      -- (regression check, not new functionality).
      ------------------------------------------------------------------
      preload(20, x"7420", preload_idx, preload_data, preload_valid, cpuclk);  -- eidled(0x74)<<8 | rcru(0x20)
      preload(24, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);  -- poison
      wait for 20 ns;

      prog_write("000", x"0028", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("010", x"0030", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);

      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      write(l, string'("reidled regression readback: 0x"));
      hwrite(l, mem(24));
      write(l, string'(" (expected 0x2620)"));
      writeline(output, l);
      if mem(24) = x"2620" then
         write(l, string'("PASS reidled-regression (real xubl.vhd master)"));
      else
         write(l, string'("FAIL reidled-regression (real xubl.vhd master)"));
      end if;
      writeline(output, l);

      ------------------------------------------------------------------
      -- RRXDATA: real firmware pattern (roms/xubrt45.mac's rnpp/rpkth/
      -- rdata: ".byte b0sel,rrxdata", sent via xubl <tmpl>,20,<dest>,NN).
      -- Reuses the WGPDATA path just proven above to seed real DDR3
      -- content (0x11,0x22,0x33,0x44 at byte offset 0) rather than a
      -- testbench backdoor -- tests the real, integrated write->read
      -- round trip through the same underlying storage.
      ------------------------------------------------------------------
      preload(40, x"2AC0", preload_idx, preload_data, preload_valid, cpuclk);  -- wgpdata(0x2A)<<8 | b0sel(0xC0)
      preload(41, x"2211", preload_idx, preload_data, preload_valid, cpuclk);
      preload(42, x"4433", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"0050", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 40 (byte addr 80)
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0030", bus_addr, bus_dato, bus_control_dato, nclk);  -- 48 bits (6 bytes)
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 2000 ns;

      -- werxrdpt: point the RX read pointer at byte offset 0 (where the
      -- WGPDATA write above just landed, since egpwrpt also defaults to
      -- 0 -- same underlying DDR3 storage, no region enforcement at the
      -- RTL level, matching real hardware where region separation is a
      -- firmware convention, not a physical one).
      preload(44, x"8A22", preload_idx, preload_data, preload_valid, cpuclk);  -- erxrdpt(0x8A)<<8 | wcru(0x22)
      preload(45, x"0000", preload_idx, preload_data, preload_valid, cpuclk);  -- value = 0x0000
      wait for 20 ns;
      prog_write("000", x"0058", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 44 (byte addr 88)
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);  -- 32 bits (4 bytes: wcru+addr+2 data)
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      -- rdata: b0sel,rrxdata -- read back 4 bytes, expect 0x11,0x22,0x33,0x44
      preload(50, x"2CC0", preload_idx, preload_data, preload_valid, cpuclk);  -- rrxdata(0x2C)<<8 | b0sel(0xC0)
      preload(60, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);  -- poison
      preload(61, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"0064", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 50 (byte addr 100)
      prog_write("010", x"0078", bus_addr, bus_dato, bus_control_dato, nclk);  -- rt = word addr 60 (byte addr 120)
      prog_write("011", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);  -- rl = 32 bits (4 bytes)
      prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);  -- xl = 16 bits (b0sel+rrxdata)
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      write(l, string'("RRXDATA readback: 0x"));
      hwrite(l, mem(60));
      hwrite(l, mem(61));
      write(l, string'(" (expected 0x22114433)"));
      writeline(output, l);
      if mem(60) = x"2211" and mem(61) = x"4433" then
         write(l, string'("PASS rrxdata-read (real xubl.vhd master)"));
      else
         write(l, string'("FAIL rrxdata-read (real xubl.vhd master)"));
      end if;
      writeline(output, l);

      wait for 500 ns;
      sim_done <= true;
      wait;
   end process;

end sim;
