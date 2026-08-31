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

entity tb_shim_real_master_loop is
end tb_shim_real_master_loop;

architecture sim of tb_shim_real_master_loop is

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
      variable readback : std_logic_vector(15 downto 0);
   begin
      wait until reset = '0';
      wait for 500 ns;

      for iter in 0 to 9 loop
      report "=== ITERATION " & integer'image(iter) & " starting at t=" & time'image(now) & " ===";

      ------------------------------------------------------------------
      -- chkeudast: weudast (wcru,eudast,0,0 then patched word1=0x2552)
      -- at mem word 0-1, xl=40 octal=32 bits=4 bytes, rt/rl=0 (no recv)
      ------------------------------------------------------------------
      preload(0, x"3622", preload_idx, preload_data, preload_valid, cpuclk);  -- eudast(0x36)<<8 | wcru(0x22)
      preload(1, x"2552", preload_idx, preload_data, preload_valid, cpuclk);  -- chkeudast's real test pattern (22522 octal)
      wait for 20 ns;

      prog_write("000", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 0
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);  -- rt = 0 (unused, no recv)
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);  -- rl = 0 (no recv)
      prog_write("001", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);  -- xl = 32 bits, triggers run

      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      ------------------------------------------------------------------
      -- reudast (rcru,eudast) at mem word 2, xl=20 octal=16 bits=2 bytes,
      -- rt = word addr 6 (mem(6)), rl=20 octal=16 bits=2 bytes
      ------------------------------------------------------------------
      preload(2, x"3620", preload_idx, preload_data, preload_valid, cpuclk);  -- eudast(0x36)<<8 | rcru(0x20)
      preload(6, x"0000", preload_idx, preload_data, preload_valid, cpuclk);  -- clear response slot first (matches "clr ceudast")
      wait for 20 ns;

      prog_write("000", x"0004", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 2 (byte addr 4)
      prog_write("010", x"000C", bus_addr, bus_dato, bus_control_dato, nclk);  -- rt = word addr 6 (byte addr 12)
      prog_write("011", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);  -- rl = 16 bits
      prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);  -- xl = 16 bits, triggers run

      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      readback := mem(6);
      write(l, string'("[iter ") & integer'image(iter) & "] chkeudast RCRU readback: 0x");
      hwrite(l, readback);
      write(l, string'(" (expected 0x2552)"));
      writeline(output, l);
      if readback = x"2552" then
         write(l, string'("[iter ") & integer'image(iter) & "] PASS chkeudast (real xubl.vhd master)");
      else
         write(l, string'("[iter ") & integer'image(iter) & "] FAIL chkeudast (real xubl.vhd master)");
      end if;
      writeline(output, l);

      ------------------------------------------------------------------
      -- qecon2 (bfsu,econ2,020,0) at mem word 8-9, xl=40 octal=32 bits
      ------------------------------------------------------------------
      preload(8, x"6E24", preload_idx, preload_data, preload_valid, cpuclk);  -- econ2(0x6E)<<8 | bfsu(0x24)
      preload(9, x"0010", preload_idx, preload_data, preload_valid, cpuclk);  -- mask: bit4 set (ETHRST), matches "020,0"
      wait for 20 ns;

      prog_write("000", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 8 (byte addr 16)
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);  -- rt = 0 (unused)
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);  -- rl = 0 (no recv)
      prog_write("001", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);  -- xl = 32 bits, triggers run

      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 2000 ns;  -- "waitabit" real firmware delay equivalent

      ------------------------------------------------------------------
      -- reudast again -- real firmware (30$) expects 0x0000 back
      ------------------------------------------------------------------
      preload(10, x"3620", preload_idx, preload_data, preload_valid, cpuclk);  -- eudast(0x36)<<8 | rcru(0x20)
      preload(14, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);  -- poison the response slot so we know it was overwritten
      wait for 20 ns;

      prog_write("000", x"0014", bus_addr, bus_dato, bus_control_dato, nclk);  -- xf = word addr 10 (byte addr 20)
      prog_write("010", x"001C", bus_addr, bus_dato, bus_control_dato, nclk);  -- rt = word addr 14 (byte addr 28)
      prog_write("011", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);  -- rl = 16 bits
      prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);  -- xl = 16 bits, triggers run

      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      readback := mem(14);
      write(l, string'("[iter ") & integer'image(iter) & "] initenc 30$ RCRU EUDAST readback after ECON2/ETHRST: 0x");
      hwrite(l, readback);
      write(l, string'(" (expected 0x0000)"));
      writeline(output, l);
      if readback = x"0000" then
         write(l, string'("[iter ") & integer'image(iter) & "] PASS ethrst-clear (real xubl.vhd master)");
      else
         write(l, string'("[iter ") & integer'image(iter) & "] FAIL ethrst-clear (real xubl.vhd master)");
      end if;
      writeline(output, l);

      wait for 500 ns;
      end loop;

      sim_done <= true;
      wait;
   end process;

end sim;
