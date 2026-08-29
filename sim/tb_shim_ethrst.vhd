--
-- tb_shim.vhd -- focused GHDL testbench for just xu_enc424j600_shim.vhd +
-- xu_ddr_mailbox.vhd, replicating chkeudast's exact real WCRU-write /
-- RCRU-read sequence (roms/xubrt45.mac) by directly bit-banging the SPI
-- pins the same way xubl.vhd's real shift engine does (MSB-first per
-- byte, sampled/driven on cpuclk edges). Targets the real bug: EUDAST
-- reads back 00 00 on real hardware regardless of what was written.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_shim_ethrst is
end tb_shim_ethrst;

architecture sim of tb_shim_ethrst is

   signal cpuclk : std_logic := '0';
   signal clk50mhz_sig : std_logic := '0';
   signal reset : std_logic := '1';
   signal sim_done : boolean := false;

   signal xu_cs : std_logic := '1';
   signal xu_mosi : std_logic := '0';
   signal xu_sclk : std_logic := '0';  -- unused by the shim, sampled as data only
   signal xu_miso : std_logic;

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

   -- opcodes/addresses, same values the real firmware sends (verified
   -- against roms/xubrt45.mac and roms/xubrt45.lst this session)
   constant OP_RCRU  : std_logic_vector(7 downto 0) := x"20";
   constant OP_WCRU  : std_logic_vector(7 downto 0) := x"22";
   constant OP_BFSU  : std_logic_vector(7 downto 0) := x"24";
   constant ADDR_EUDAST : std_logic_vector(7 downto 0) := x"36";
   constant ADDR_ECON2  : std_logic_vector(7 downto 0) := x"6E";

   -- sends one bit per cpuclk rising edge (matching xubl.vhd's real
   -- process(cpuclk) shift timing established this session)
   procedure spi_send_byte(b : in std_logic_vector(7 downto 0);
                            signal mosi : out std_logic;
                            signal clk : in std_logic) is
      variable l : line;
   begin
      for i in 7 downto 0 loop
         mosi <= b(i);
         wait until clk'event and clk = '1';
      end loop;
      write(l, string'("  sent byte: 0x"));
      hwrite(l, b);
      writeline(output, l);
   end procedure;

   procedure spi_recv_byte(variable b : out std_logic_vector(7 downto 0);
                            signal miso : in std_logic;
                            signal clk : in std_logic) is
      variable l : line;
      variable got : std_logic_vector(7 downto 0);
   begin
      for i in 7 downto 0 loop
         wait until clk'event and clk = '0';  -- real master samples on cpuclk falling edge (SCLK rising)
         got(i) := miso;
         report "DBG recv sampling bit i=" & integer'image(i) & " val=" & std_logic'image(miso)
              & " at t=" & time'image(now);
      end loop;
      b := got;
      write(l, string'("  recv byte: 0x"));
      hwrite(l, got);
      writeline(output, l);
   end procedure;

begin

   cpuclk <= not cpuclk after 50 ns when not sim_done else '0';  -- 10MHz, matching cpuclk's real documented rate
   clk50mhz_sig <= not clk50mhz_sig after 10 ns when not sim_done else '0';
   reset <= '1', '0' after 500 ns;

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
   -- main test sequence: chkeudast's real WCRU write then RCRU read
   ----------------------------------------------------------------------
   process
      variable rx : std_logic_vector(7 downto 0);
      variable readback : std_logic_vector(15 downto 0);
      variable l : line;
   begin
      xu_cs <= '1';
      wait until reset = '0';
      wait for 200 ns;

      -- WCRU eudast, 0x2552 (22522 octal, chkeudast's real test pattern)
      -- byte order LSB then MSB, per the datasheet templates
      xu_cs <= '0';
      wait until cpuclk'event and cpuclk = '1';
      spi_send_byte(OP_WCRU, xu_mosi, cpuclk);
      spi_send_byte(ADDR_EUDAST, xu_mosi, cpuclk);
      spi_send_byte(x"52", xu_mosi, cpuclk);  -- LSB
      spi_send_byte(x"25", xu_mosi, cpuclk);  -- MSB
      wait until cpuclk'event and cpuclk = '1';
      xu_cs <= '1';
      wait for 500 ns;

      -- RCRU eudast, expect 0x2552 back (LSB then MSB)
      xu_cs <= '0';
      wait until cpuclk'event and cpuclk = '1';
      spi_send_byte(OP_RCRU, xu_mosi, cpuclk);
      spi_send_byte(ADDR_EUDAST, xu_mosi, cpuclk);
      -- one extra rising edge: the shim needs this edge to transition into
      -- s_data_out and compute the first real output byte (bc=0) before
      -- any falling-edge sample is meaningful -- without this the first
      -- recv_byte call catches a stale/transitional value half a cycle
      -- too early.
      wait until cpuclk'event and cpuclk = '1';
      spi_recv_byte(rx, xu_miso, cpuclk);
      readback(7 downto 0) := rx;
      spi_recv_byte(rx, xu_miso, cpuclk);
      readback(15 downto 8) := rx;
      wait until cpuclk'event and cpuclk = '1';
      xu_cs <= '1';

      write(l, string'("RCRU EUDAST readback: 0x"));
      hwrite(l, readback);
      write(l, string'(" (expected 0x2552)"));
      writeline(output, l);

      if readback = x"2552" then
         write(l, string'("PASS chkeudast"));
      else
         write(l, string'("FAIL chkeudast"));
      end if;
      writeline(output, l);

      ----------------------------------------------------------------
      -- Now replicate the REAL failing step from roms/xubrt45.mac
      -- (initenc, label 20$/30$): BFSU econ2, mask=0x0010 (ETHRST,
      -- firmware's real "qecon2" pattern), wait, then RCRU eudast
      -- again -- real firmware expects 0x0000 back.
      ----------------------------------------------------------------
      wait for 500 ns;
      xu_cs <= '0';
      wait until cpuclk'event and cpuclk = '1';
      spi_send_byte(OP_BFSU, xu_mosi, cpuclk);
      spi_send_byte(ADDR_ECON2, xu_mosi, cpuclk);
      spi_send_byte(x"10", xu_mosi, cpuclk);  -- LSB: bit4 set (ETHRST)
      spi_send_byte(x"00", xu_mosi, cpuclk);  -- MSB
      wait until cpuclk'event and cpuclk = '1';
      xu_cs <= '1';
      wait for 500 ns;  -- "waitabit" real firmware delay equivalent

      xu_cs <= '0';
      wait until cpuclk'event and cpuclk = '1';
      spi_send_byte(OP_RCRU, xu_mosi, cpuclk);
      spi_send_byte(ADDR_EUDAST, xu_mosi, cpuclk);
      wait until cpuclk'event and cpuclk = '1';
      spi_recv_byte(rx, xu_miso, cpuclk);
      readback(7 downto 0) := rx;
      spi_recv_byte(rx, xu_miso, cpuclk);
      readback(15 downto 8) := rx;
      wait until cpuclk'event and cpuclk = '1';
      xu_cs <= '1';

      write(l, string'("RCRU EUDAST readback after ECON2/ETHRST: 0x"));
      hwrite(l, readback);
      write(l, string'(" (expected 0x0000)"));
      writeline(output, l);

      if readback = x"0000" then
         write(l, string'("PASS ethrst-clear"));
      else
         write(l, string'("FAIL ethrst-clear"));
      end if;
      writeline(output, l);

      wait for 500 ns;
      sim_done <= true;
      wait;
   end process;

end sim;
