--
-- tb_xu_rxcache_twobank.vhd -- GHDL testbench for the two-bank RX cache
-- redesign (2026-08-30), built while the real Quartus build for the same
-- change runs in parallel. Reuses tb_shim_stream.vhd's proven real-master
-- infrastructure (real xubl.vhd, real shim, real mailbox, a DDR3 RAM
-- model) rather than hand-bit-banging SPI.
--
-- Directly exercises the exact scenario that broke the old single-buffer
-- design on real hardware: two separate CS-sessions reading the SAME
-- already-cached 8-byte word (pktin's dnpp then dpkth), followed by a
-- third session crossing into a SECOND word (exercising the bank flip +
-- readahead landing in time). Two distinct, byte-identifiable patterns
-- are preloaded at consecutive RX-ring words so a wrong byte anywhere is
-- immediately visible.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_xu_rxcache_twobank is
end tb_xu_rxcache_twobank;

architecture sim of tb_xu_rxcache_twobank is

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
   -- Seeded directly in the declaration, not via a second signal driver
   -- in the stimulus process -- ddr_ram is also driven by the DDRAM_CLK
   -- process below, and two drivers disagreeing on the same signal
   -- resolves to 'X', not "whichever wrote last" (same class of bug
   -- tb_shim_stream.vhd's own mem-array comment already flags).
   -- W0 (0x900, byte 0x4800): 01 02 03 04 05 06 07 08
   -- W1 (0x901, byte 0x4808): 11 12 13 14 15 16 17 18
   signal ddr_ram : ddr_ram_type := (
      16#900# => x"0807060504030201",
      16#901# => x"1817161514131211",
      others => (others => '0'));

   type mem_type is array(0 to 127) of std_logic_vector(15 downto 0);
   signal mem : mem_type := (others => (others => '0'));
   signal preload_idx : integer range 0 to 127 := 0;
   signal preload_data : std_logic_vector(15 downto 0) := (others => '0');
   signal preload_valid : std_logic := '0';

   -- word address (mailbox's own DDRAM_ADDR(12:0) indexing) for RX ring
   -- byte address 0x4800: WINDOW_WORD_BASE (0x3FE0000) is an exact
   -- multiple of 8192, so this is just 0x4800>>3 = 0x900.
   constant W0 : integer := 16#900#;  -- byte 0x4800
   constant W1 : integer := 16#901#;  -- byte 0x4808

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

   bus_master_dati <= mem(conv_integer(bus_master_addr(7 downto 1)));

   process(cpuclk)
      variable idx : integer;
   begin
      if cpuclk'event and cpuclk = '1' then
         if preload_valid = '1' then
            mem(preload_idx) <= preload_data;
         elsif bus_master_control_dato = '1' then
            idx := conv_integer(bus_master_addr(7 downto 1));
            mem(idx) <= bus_master_dato;
         end if;
      end if;
   end process;

   -- Independent bit counter -- zero dependency on the shim's own
   -- bit_count, purely counts real xu_sclk rising edges while xu_cs is
   -- low, reporting the total the instant xu_cs deasserts. Answers
   -- directly: does xubl.vhd itself clock more bits than requested, or
   -- is the discrepancy somewhere else (e.g. in the shim's own CS-edge
   -- detection)?
   process(cpuclk)
      variable n : integer := 0;
      variable prev_cs : std_logic := '1';
   begin
      if cpuclk'event and cpuclk = '1' then
         if xu_cs = '0' then
            n := n + 1;
         end if;
         if prev_cs /= xu_cs then
            report "CS-EDGE xu_cs: " & std_logic'image(prev_cs) & " -> " & std_logic'image(xu_cs)
               & " (n so far=" & integer'image(n) & ")";
         end if;
         if prev_cs = '0' and xu_cs = '1' then
            report "REAL-BITCOUNT transaction clocked " & integer'image(n) & " real cpuclk cycles (bits)";
            n := 0;
         end if;
         prev_cs := xu_cs;
      end if;
   end process;

   -- DDR3 mailbox RAM model, pre-seeded directly (no WGPDATA round trip
   -- needed here -- we want known content at specific RX-ring addresses
   -- before the shim ever touches them).
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
      variable pass_count, fail_count : integer := 0;

      procedure check(name : string; got : std_logic_vector; expected : std_logic_vector) is
      begin
         write(l, name & string'(": got 0x"));
         hwrite(l, got);
         write(l, string'(" expected 0x"));
         hwrite(l, expected);
         if got = expected then
            write(l, string'(" PASS"));
            pass_count := pass_count + 1;
         else
            write(l, string'(" FAIL"));
            fail_count := fail_count + 1;
         end if;
         writeline(output, l);
      end procedure;

   begin
      wait until reset = '0';
      wait for 500 ns;

      -- ddr_ram(W0)/(W1) already seeded via the signal declaration above.

      ------------------------------------------------------------------
      -- werxtail: set ERXTAIL ahead of both test words (0x4820), so the
      -- readahead bound (rx_fwd_dist against reg_erxtail) permits both
      -- fetches -- matches real firmware always setting ERXTAIL before
      -- enabling RXEN.
      ------------------------------------------------------------------
      preload(0, x"0622", preload_idx, preload_data, preload_valid, cpuclk);  -- erxtail(0x06)<<8 | wcru(0x22)
      preload(1, x"4820", preload_idx, preload_data, preload_valid, cpuclk);  -- value = 0x4820
      wait for 20 ns;
      prog_write("000", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);  -- 32 bits
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      ------------------------------------------------------------------
      -- werxrdpt: seek to 0x4800 -- neither bank holds it yet, so this
      -- marks the current bank pending and the continuous dispatcher
      -- issues the fetch.
      ------------------------------------------------------------------
      preload(4, x"8A22", preload_idx, preload_data, preload_valid, cpuclk);  -- erxrdpt(0x8A)<<8 | wcru(0x22)
      preload(5, x"4800", preload_idx, preload_data, preload_valid, cpuclk);  -- value = 0x4800
      wait for 20 ns;
      prog_write("000", x"0008", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 1000 ns;  -- let the fetch actually land

      ------------------------------------------------------------------
      -- Transaction A: b0sel,rrxdata -- read 2 bytes (matches pktin's
      -- dnpp read). Expect 01 02.
      ------------------------------------------------------------------
      preload(8, x"2CC0", preload_idx, preload_data, preload_valid, cpuclk);
      preload(16, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("010", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 200 ns;
      check("txn A (dnpp-like, offset 0-1)", mem(16), x"0201");

      ------------------------------------------------------------------
      -- Transaction B: FRESH CS-session, same word, moments later --
      -- exactly the scenario that broke the old design (dnpp correct,
      -- dpkth read back zero). Read 6 bytes. Expect 03 04 05 06 07 08.
      ------------------------------------------------------------------
      preload(20, x"2CC0", preload_idx, preload_data, preload_valid, cpuclk);
      preload(24, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      preload(25, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      preload(26, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"0028", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("010", x"0030", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0030", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 200 ns;
      check("txn B (dpkth-like, offset 2-3)", mem(24), x"0403");
      check("txn B (dpkth-like, offset 4-5)", mem(25), x"0605");
      check("txn B (dpkth-like, offset 6-7)", mem(26), x"0807");

      ------------------------------------------------------------------
      -- Transaction C: fresh CS-session, crosses into the SECOND word
      -- (0x4808) -- exercises the bank flip and whether readahead landed
      -- bank B in time. Read 8 bytes. Expect 11 12 13 14 15 16 17 18.
      ------------------------------------------------------------------
      preload(28, x"2CC0", preload_idx, preload_data, preload_valid, cpuclk);
      preload(34, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      preload(35, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      preload(36, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      preload(37, x"FFFF", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"0038", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("010", x"0044", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0040", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 200 ns;
      check("txn C (word1, offset 0-1)", mem(34), x"1211");
      check("txn C (word1, offset 2-3)", mem(35), x"1413");
      check("txn C (word1, offset 4-5)", mem(36), x"1615");
      check("txn C (word1, offset 6-7)", mem(37), x"1817");

      write(l, string'("=== ") & integer'image(pass_count) & string'(" PASS, ")
              & integer'image(fail_count) & string'(" FAIL ==="));
      writeline(output, l);

      wait for 500 ns;
      sim_done <= true;
      wait;
   end process;

end sim;
