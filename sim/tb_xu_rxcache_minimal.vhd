--
-- tb_xu_rxcache_minimal.vhd -- smallest possible repro for the two-bank
-- RX cache timing anomaly (2026-08-30): tb_xu_rxcache_twobank.vhd's
-- txn A (RRXDATA, xl=16/rl=16, identical bit-shape to tb_shim_stream.vhd's
-- already-proven-correct reidled RCRU regression) clocked 66 real cpuclk
-- cycles instead of ~32-34. This strips everything down to exactly
-- tb_shim_stream.vhd's own working pattern (WGPDATA seed -> WCRU
-- ERXRDPT -> single RRXDATA read of matching size), to isolate whether
-- the anomaly needs the rest of tb_xu_rxcache_twobank.vhd's sequence
-- (ERXTAIL WCRU first, specific RX-ring addresses) or shows up even here.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_xu_rxcache_minimal is
end tb_xu_rxcache_minimal;

architecture sim of tb_xu_rxcache_minimal is

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

   cpuclk <= not cpuclk after 50 ns when not sim_done else '0';
   nclk <= not cpuclk;
   clk50mhz_sig <= not clk50mhz_sig after 10 ns when not sim_done else '0';
   reset <= '1', '0' after 500 ns;
   npg <= '1';

   bus_master_dati <= mem(conv_integer(bus_master_addr(6 downto 1)));

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

   process(cpuclk)
      variable n : integer := 0;
      variable prev_cs : std_logic := '1';
   begin
      if cpuclk'event and cpuclk = '1' then
         if xu_cs = '0' then
            n := n + 1;
         end if;
         if prev_cs = '0' and xu_cs = '1' then
            report "REAL-BITCOUNT transaction clocked " & integer'image(n) & " real cpuclk cycles (bits)";
            n := 0;
         end if;
         prev_cs := xu_cs;
      end if;
   end process;


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

   process
      variable l : line;
   begin
      wait until reset = '0';
      wait for 500 ns;

      ------------------------------------------------------------------
      -- WGPDATA: seed 4 bytes at egpwrpt's reset value (0x0000) --
      -- exactly tb_shim_stream.vhd's own proven pattern.
      ------------------------------------------------------------------
      preload(0, x"2AC0", preload_idx, preload_data, preload_valid, cpuclk);
      preload(1, x"2211", preload_idx, preload_data, preload_valid, cpuclk);
      preload(2, x"4433", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0030", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 2000 ns;

      ------------------------------------------------------------------
      -- werxrdpt: point ERXRDPT at byte offset 0 -- same underlying
      -- storage as the WGPDATA write above (no region enforcement at
      -- RTL level).
      ------------------------------------------------------------------
      preload(4, x"8A22", preload_idx, preload_data, preload_valid, cpuclk);
      preload(5, x"0000", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"0008", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      ------------------------------------------------------------------
      -- rdata: b0sel,rrxdata -- read 2 bytes (xl=16, rl=16, identical
      -- shape to tb_shim_stream.vhd's own passing reidled RCRU test).
      -- Expect 0x11, 0x22.
      ------------------------------------------------------------------
      preload(8, x"2CC0", preload_idx, preload_data, preload_valid, cpuclk);
      preload(16, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("010", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      write(l, string'("RRXDATA readback: 0x"));
      hwrite(l, mem(16));
      write(l, string'(" (expected 0x2211)"));
      writeline(output, l);
      if mem(16) = x"2211" then
         write(l, string'("PASS minimal-rrxdata-read"));
      else
         write(l, string'("FAIL minimal-rrxdata-read"));
      end if;
      writeline(output, l);

      ------------------------------------------------------------------
      -- txn B: fresh CS-session, same word, read next 2 bytes
      -- (offset 2-3, expect 0x33, 0x44) -- mirrors tb_xu_rxcache_twobank's
      -- failing txn B shape (fresh CS-session against a word already
      -- partially consumed by a prior transaction).
      ------------------------------------------------------------------
      wait for 500 ns;
      preload(20, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("010", x"0028", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      write(l, string'("txn B readback: 0x"));
      hwrite(l, mem(20));
      write(l, string'(" (expected 0x4433)"));
      writeline(output, l);
      if mem(20) = x"4433" then
         write(l, string'("PASS minimal-txnB"));
      else
         write(l, string'("FAIL minimal-txnB"));
      end if;
      writeline(output, l);

      wait for 500 ns;
      sim_done <= true;
      wait;
   end process;

end sim;
