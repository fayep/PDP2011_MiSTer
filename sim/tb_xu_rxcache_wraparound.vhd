--
-- tb_xu_rxcache_wraparound.vhd -- targets the RX ring's real physical
-- wraparound boundary (2026-08-31): RX_BUF_END=0x6000 wraps to
-- RX_BUF_START=0x4800 (rtl/xu_enc424j600_shim.vhd's rx_next_addr/
-- rx_next_word_addr). Every sim test built earlier today
-- (tb_xu_rxcache_twobank/longstream/multiseek) stayed in a small region
-- near 0x4800, nowhere near this boundary -- real hardware evidence
-- (2026-08-31) showed pktin's dnpp landing at 0x5fa8 then 0x5ff0, right
-- at the edge, immediately before the ring got permanently stuck. This
-- is the first test to actually cross 0x5FF8->0x6000->0x4800 mid-stream,
-- matching getfr's real 20-byte-chunk access pattern (roms/xubrt45.mac).
--
-- Seek to 0x5FE8 (24 bytes before the physical end), then read 60 bytes
-- in 3 fresh-CS-session 20-byte chunks -- the second chunk (logical
-- bytes 20-39) straddles the wrap exactly (real addresses 0x5FFC..0x6000
-- then 0x4800..0x4818), matching getfr's real chunking. Content seeded
-- with a 0..255 ramp indexed by LOGICAL position from the seek point
-- (not real address, since real address itself wraps), so any
-- corruption at or after the wrap is immediately visible.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_xu_rxcache_wraparound is
end tb_xu_rxcache_wraparound;

architecture sim of tb_xu_rxcache_wraparound is

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
   -- Seeded directly in the declaration (single driver -- see
   -- tb_xu_rxcache_twobank.vhd's own comment). Words spanning the real
   -- physical wraparound: 0xBFD/0xBFE/0xBFF = bytes 0x5FE8-0x5FFF (the
   -- last 24 bytes before RX_BUF_END), then 0x900-0x904 = bytes
   -- 0x4800-0x4827 (the first 40 bytes after RX_BUF_START). Byte value
   -- = logical position (0-based from 0x5FE8) mod 256 -- NOT real
   -- address, since real address itself wraps here.
   signal ddr_ram : ddr_ram_type := (
      16#BFD# => x"0706050403020100",  -- byte 0x5FE8: logical 0-7
      16#BFE# => x"0F0E0D0C0B0A0908",  -- byte 0x5FF0: logical 8-15
      16#BFF# => x"1716151413121110",  -- byte 0x5FF8: logical 16-23
      16#900# => x"1F1E1D1C1B1A1918",  -- byte 0x4800: logical 24-31 (post-wrap)
      16#901# => x"2726252423222120",  -- byte 0x4808: logical 32-39
      16#902# => x"2F2E2D2C2B2A2928",  -- byte 0x4810: logical 40-47
      16#903# => x"3736353433323130",  -- byte 0x4818: logical 48-55
      16#904# => x"3F3E3D3C3B3A3938",  -- byte 0x4820: logical 56-63
      others => (others => '0'));

   type mem_type is array(0 to 255) of std_logic_vector(15 downto 0);
   signal mem : mem_type := (others => (others => '0'));
   signal preload_idx : integer range 0 to 255 := 0;
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

   -- expected word for LOGICAL byte position `pos` (0-based from the
   -- seek point 0x5FE8), matching this codebase's "mem word low byte =
   -- first byte transmitted" convention.
   function ramp_word(pos : integer) return std_logic_vector is
      variable b0, b1 : integer;
   begin
      b0 := pos mod 256;
      b1 := (pos + 1) mod 256;
      return conv_std_logic_vector(b1 * 256 + b0, 16);
   end function;

begin

   cpuclk <= not cpuclk after 50 ns when not sim_done else '0';
   nclk <= not cpuclk;
   clk50mhz_sig <= not clk50mhz_sig after 10 ns when not sim_done else '0';
   reset <= '1', '0' after 500 ns;
   npg <= '1';

   bus_master_dati <= mem(conv_integer(bus_master_addr(8 downto 1)));

   process(cpuclk)
      variable idx : integer;
   begin
      if cpuclk'event and cpuclk = '1' then
         if preload_valid = '1' then
            mem(preload_idx) <= preload_data;
         elsif bus_master_control_dato = '1' then
            idx := conv_integer(bus_master_addr(8 downto 1));
            mem(idx) <= bus_master_dato;
         end if;
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
      variable pass_count, fail_count : integer := 0;
      variable first_fail_pos : integer := -1;

      procedure check(pos : integer; got : std_logic_vector) is
         variable expected : std_logic_vector(15 downto 0);
      begin
         expected := ramp_word(pos);
         if got = expected then
            pass_count := pass_count + 1;
         else
            fail_count := fail_count + 1;
            if first_fail_pos = -1 then
               first_fail_pos := pos;
            end if;
            write(l, string'("FAIL pos=") & integer'image(pos));
            write(l, string'(" got 0x"));
            hwrite(l, got);
            write(l, string'(" expected 0x"));
            hwrite(l, expected);
            writeline(output, l);
         end if;
      end procedure;

      constant N_CHUNKS : integer := 3;  -- 3*20 = 60 bytes, crosses the wrap in chunk 1
      constant OPCODE_BASE : integer := 0;
      constant RESULT_BASE : integer := 100;

   begin
      wait until reset = '0';
      wait for 500 ns;

      ------------------------------------------------------------------
      -- werxtail: 0x4830 -- past the whole 64-byte seeded post-wrap
      -- region (0x4800-0x4827), matching real firmware always setting
      -- ERXTAIL before enabling RXEN. Forward distance from 0x5FE8 to
      -- 0x4830 (wrapping) = 0x18 + 0x30 = 0x48 = 72 bytes, comfortably
      -- past our 60-byte read.
      ------------------------------------------------------------------
      preload(0, x"0622", preload_idx, preload_data, preload_valid, cpuclk);
      preload(1, x"4830", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      ------------------------------------------------------------------
      -- werxrdpt: seek to 0x5FE8, 24 bytes before the physical end.
      ------------------------------------------------------------------
      preload(4, x"8A22", preload_idx, preload_data, preload_valid, cpuclk);
      preload(5, x"5FE8", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"0008", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 1000 ns;  -- let the initial fetch and readahead land

      ------------------------------------------------------------------
      -- getfr's real access pattern: 3 fresh CS-sessions, 20 bytes each,
      -- continuing from wherever reg_erxrdpt was left -- chunk 1 (bytes
      -- 20-39) straddles the real physical wraparound.
      ------------------------------------------------------------------
      for i in 0 to N_CHUNKS - 1 loop
         preload(OPCODE_BASE + i, x"2CC0", preload_idx, preload_data, preload_valid, cpuclk);
         wait for 20 ns;
         prog_write("000", conv_std_logic_vector((OPCODE_BASE + i) * 2, 16), bus_addr, bus_dato, bus_control_dato, nclk);
         prog_write("010", conv_std_logic_vector((RESULT_BASE + i * 10) * 2, 16), bus_addr, bus_dato, bus_control_dato, nclk);
         prog_write("011", x"00A0", bus_addr, bus_dato, bus_control_dato, nclk);  -- rl = 160 bits = 20 bytes
         prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);  -- xl = 16 bits (b0sel+rrxdata)
         wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
         wait for 500 ns;
      end loop;

      ------------------------------------------------------------------
      -- Verify every byte against the logical-position ramp.
      ------------------------------------------------------------------
      for i in 0 to N_CHUNKS - 1 loop
         for w in 0 to 9 loop
            check(i * 20 + w * 2, mem(RESULT_BASE + i * 10 + w));
         end loop;
      end loop;

      write(l, string'("=== ") & integer'image(pass_count) & string'(" PASS, ")
             & integer'image(fail_count) & string'(" FAIL"));
      if fail_count > 0 then
         write(l, string'(" (first fail at logical pos ") & integer'image(first_fail_pos) & string'(")"));
      end if;
      write(l, string'(" ==="));
      writeline(output, l);

      wait for 500 ns;
      sim_done <= true;
      wait;
   end process;

end sim;
