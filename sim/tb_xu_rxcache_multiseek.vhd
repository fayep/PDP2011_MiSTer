--
-- tb_xu_rxcache_multiseek.vhd -- stress test for pktin()'s REAL outer
-- loop pattern (2026-08-31, built after real hardware showed 305 Ierrs
-- out of 321 Ipkts on a getfr()-instrumented build): pktin re-seeks
-- ERXRDPT (werxrdpt) once per FRAME, then does a fresh 2-byte RRXDATA
-- read (dnpp, rl=16) followed by a fresh 6-byte RRXDATA read (dpkth,
-- rl=48) -- both distinct, previously-untested-in-repetition transaction
-- shapes. tb_xu_rxcache_twobank.vhd proved ONE such seek+dnpp+dpkth
-- sequence correct; tb_xu_rxcache_longstream.vhd proved a long
-- *unseeked* streaming read correct. Neither tested MANY repeated
-- seek+dnpp+dpkth cycles to DIFFERENT addresses in a row, which is what
-- pktin actually does once per real frame. Real hardware evidence
-- (2026-08-31): getfr's own flen dumps showed wildly invalid values
-- (0x3029, 0x3c22, 0x6f63 -- 12000+ decimal, impossible for a real
-- Ethernet frame) specifically on the header read path, not the long
-- payload copy -- this test targets exactly that.
--
-- 20 simulated frames, each ~48 bytes apart (typical small-frame
-- spacing), seeking to a NEW, non-contiguous address each time (unlike
-- getfr's own within-frame reads, which never re-seek). DDR3 seeded with
-- the same 0x00..0xFF ramp as tb_xu_rxcache_longstream.vhd so any
-- corruption is immediately visible.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_xu_rxcache_multiseek is
end tb_xu_rxcache_multiseek;

architecture sim of tb_xu_rxcache_multiseek is

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
   -- tb_xu_rxcache_twobank.vhd's own comment for why a second driver in
   -- the stimulus process would resolve to 'X'). 150 words * 8 bytes =
   -- 1200 bytes, byte value = (word*8 + lane) mod 256, starting at
   -- byte 0x4800 (word 0x900).
   signal ddr_ram : ddr_ram_type := (
      16#900# => x"0706050403020100",
      16#901# => x"0F0E0D0C0B0A0908",
      16#902# => x"1716151413121110",
      16#903# => x"1F1E1D1C1B1A1918",
      16#904# => x"2726252423222120",
      16#905# => x"2F2E2D2C2B2A2928",
      16#906# => x"3736353433323130",
      16#907# => x"3F3E3D3C3B3A3938",
      16#908# => x"4746454443424140",
      16#909# => x"4F4E4D4C4B4A4948",
      16#90A# => x"5756555453525150",
      16#90B# => x"5F5E5D5C5B5A5958",
      16#90C# => x"6766656463626160",
      16#90D# => x"6F6E6D6C6B6A6968",
      16#90E# => x"7776757473727170",
      16#90F# => x"7F7E7D7C7B7A7978",
      16#910# => x"8786858483828180",
      16#911# => x"8F8E8D8C8B8A8988",
      16#912# => x"9796959493929190",
      16#913# => x"9F9E9D9C9B9A9998",
      16#914# => x"A7A6A5A4A3A2A1A0",
      16#915# => x"AFAEADACABAAA9A8",
      16#916# => x"B7B6B5B4B3B2B1B0",
      16#917# => x"BFBEBDBCBBBAB9B8",
      16#918# => x"C7C6C5C4C3C2C1C0",
      16#919# => x"CFCECDCCCBCAC9C8",
      16#91A# => x"D7D6D5D4D3D2D1D0",
      16#91B# => x"DFDEDDDCDBDAD9D8",
      16#91C# => x"E7E6E5E4E3E2E1E0",
      16#91D# => x"EFEEEDECEBEAE9E8",
      16#91E# => x"F7F6F5F4F3F2F1F0",
      16#91F# => x"FFFEFDFCFBFAF9F8",
      16#920# => x"0706050403020100",
      16#921# => x"0F0E0D0C0B0A0908",
      16#922# => x"1716151413121110",
      16#923# => x"1F1E1D1C1B1A1918",
      16#924# => x"2726252423222120",
      16#925# => x"2F2E2D2C2B2A2928",
      16#926# => x"3736353433323130",
      16#927# => x"3F3E3D3C3B3A3938",
      16#928# => x"4746454443424140",
      16#929# => x"4F4E4D4C4B4A4948",
      16#92A# => x"5756555453525150",
      16#92B# => x"5F5E5D5C5B5A5958",
      16#92C# => x"6766656463626160",
      16#92D# => x"6F6E6D6C6B6A6968",
      16#92E# => x"7776757473727170",
      16#92F# => x"7F7E7D7C7B7A7978",
      16#930# => x"8786858483828180",
      16#931# => x"8F8E8D8C8B8A8988",
      16#932# => x"9796959493929190",
      16#933# => x"9F9E9D9C9B9A9998",
      16#934# => x"A7A6A5A4A3A2A1A0",
      16#935# => x"AFAEADACABAAA9A8",
      16#936# => x"B7B6B5B4B3B2B1B0",
      16#937# => x"BFBEBDBCBBBAB9B8",
      16#938# => x"C7C6C5C4C3C2C1C0",
      16#939# => x"CFCECDCCCBCAC9C8",
      16#93A# => x"D7D6D5D4D3D2D1D0",
      16#93B# => x"DFDEDDDCDBDAD9D8",
      16#93C# => x"E7E6E5E4E3E2E1E0",
      16#93D# => x"EFEEEDECEBEAE9E8",
      16#93E# => x"F7F6F5F4F3F2F1F0",
      16#93F# => x"FFFEFDFCFBFAF9F8",
      16#940# => x"0706050403020100",
      16#941# => x"0F0E0D0C0B0A0908",
      16#942# => x"1716151413121110",
      16#943# => x"1F1E1D1C1B1A1918",
      16#944# => x"2726252423222120",
      16#945# => x"2F2E2D2C2B2A2928",
      16#946# => x"3736353433323130",
      16#947# => x"3F3E3D3C3B3A3938",
      16#948# => x"4746454443424140",
      16#949# => x"4F4E4D4C4B4A4948",
      16#94A# => x"5756555453525150",
      16#94B# => x"5F5E5D5C5B5A5958",
      16#94C# => x"6766656463626160",
      16#94D# => x"6F6E6D6C6B6A6968",
      16#94E# => x"7776757473727170",
      16#94F# => x"7F7E7D7C7B7A7978",
      16#950# => x"8786858483828180",
      16#951# => x"8F8E8D8C8B8A8988",
      16#952# => x"9796959493929190",
      16#953# => x"9F9E9D9C9B9A9998",
      16#954# => x"A7A6A5A4A3A2A1A0",
      16#955# => x"AFAEADACABAAA9A8",
      16#956# => x"B7B6B5B4B3B2B1B0",
      16#957# => x"BFBEBDBCBBBAB9B8",
      16#958# => x"C7C6C5C4C3C2C1C0",
      16#959# => x"CFCECDCCCBCAC9C8",
      16#95A# => x"D7D6D5D4D3D2D1D0",
      16#95B# => x"DFDEDDDCDBDAD9D8",
      16#95C# => x"E7E6E5E4E3E2E1E0",
      16#95D# => x"EFEEEDECEBEAE9E8",
      16#95E# => x"F7F6F5F4F3F2F1F0",
      16#95F# => x"FFFEFDFCFBFAF9F8",
      16#960# => x"0706050403020100",
      16#961# => x"0F0E0D0C0B0A0908",
      16#962# => x"1716151413121110",
      16#963# => x"1F1E1D1C1B1A1918",
      16#964# => x"2726252423222120",
      16#965# => x"2F2E2D2C2B2A2928",
      16#966# => x"3736353433323130",
      16#967# => x"3F3E3D3C3B3A3938",
      16#968# => x"4746454443424140",
      16#969# => x"4F4E4D4C4B4A4948",
      16#96A# => x"5756555453525150",
      16#96B# => x"5F5E5D5C5B5A5958",
      16#96C# => x"6766656463626160",
      16#96D# => x"6F6E6D6C6B6A6968",
      16#96E# => x"7776757473727170",
      16#96F# => x"7F7E7D7C7B7A7978",
      16#970# => x"8786858483828180",
      16#971# => x"8F8E8D8C8B8A8988",
      16#972# => x"9796959493929190",
      16#973# => x"9F9E9D9C9B9A9998",
      16#974# => x"A7A6A5A4A3A2A1A0",
      16#975# => x"AFAEADACABAAA9A8",
      16#976# => x"B7B6B5B4B3B2B1B0",
      16#977# => x"BFBEBDBCBBBAB9B8",
      16#978# => x"C7C6C5C4C3C2C1C0",
      16#979# => x"CFCECDCCCBCAC9C8",
      16#97A# => x"D7D6D5D4D3D2D1D0",
      16#97B# => x"DFDEDDDCDBDAD9D8",
      16#97C# => x"E7E6E5E4E3E2E1E0",
      16#97D# => x"EFEEEDECEBEAE9E8",
      16#97E# => x"F7F6F5F4F3F2F1F0",
      16#97F# => x"FFFEFDFCFBFAF9F8",
      16#980# => x"0706050403020100",
      16#981# => x"0F0E0D0C0B0A0908",
      16#982# => x"1716151413121110",
      16#983# => x"1F1E1D1C1B1A1918",
      16#984# => x"2726252423222120",
      16#985# => x"2F2E2D2C2B2A2928",
      16#986# => x"3736353433323130",
      16#987# => x"3F3E3D3C3B3A3938",
      16#988# => x"4746454443424140",
      16#989# => x"4F4E4D4C4B4A4948",
      16#98A# => x"5756555453525150",
      16#98B# => x"5F5E5D5C5B5A5958",
      16#98C# => x"6766656463626160",
      16#98D# => x"6F6E6D6C6B6A6968",
      16#98E# => x"7776757473727170",
      16#98F# => x"7F7E7D7C7B7A7978",
      16#990# => x"8786858483828180",
      16#991# => x"8F8E8D8C8B8A8988",
      16#992# => x"9796959493929190",
      16#993# => x"9F9E9D9C9B9A9998",
      16#994# => x"A7A6A5A4A3A2A1A0",
      16#995# => x"AFAEADACABAAA9A8",
      others => (others => '0'));

   -- mem: plenty of room for opcode preloads (indices 0..99) and result
   -- storage (indices 200..200+600-1 = 200..799, 10 words per
   -- iteration * 60 iterations = 600 words).
   type mem_type is array(0 to 1023) of std_logic_vector(15 downto 0);
   signal mem : mem_type := (others => (others => '0'));
   signal preload_idx : integer range 0 to 1023 := 0;
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

   -- expected word for global byte position `pos` (LSB=byte at pos,
   -- MSB=byte at pos+1), matching this codebase's established "mem word
   -- low byte = first byte transmitted" convention.
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

   bus_master_dati <= mem(conv_integer(bus_master_addr(10 downto 1)));

   process(cpuclk)
      variable idx : integer;
   begin
      if cpuclk'event and cpuclk = '1' then
         if preload_valid = '1' then
            mem(preload_idx) <= preload_data;
         elsif bus_master_control_dato = '1' then
            idx := conv_integer(bus_master_addr(10 downto 1));
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

      constant N_FRAMES : integer := 20;
      constant FRAME_SPACING : integer := 48;  -- bytes between simulated frames' seek positions
      constant OPCODE_BASE : integer := 0;      -- mem indices for opcode preloads (2 per frame)
      constant RESULT_BASE : integer := 100;    -- mem indices for dnpp(1 word)+dpkth(3 words) results, 4 per frame

   begin
      wait until reset = '0';
      wait for 500 ns;

      ------------------------------------------------------------------
      -- werxtail: set ERXTAIL well past the whole seeked region
      -- (0x4800 + 20*48 + 8 = 0x4B88), matching real firmware always
      -- setting ERXTAIL before enabling RXEN.
      ------------------------------------------------------------------
      preload(0, x"0622", preload_idx, preload_data, preload_valid, cpuclk);
      preload(1, x"4B88", preload_idx, preload_data, preload_valid, cpuclk);
      wait for 20 ns;
      prog_write("000", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
      prog_write("001", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);
      wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
      wait for 500 ns;

      ------------------------------------------------------------------
      -- pktin's real per-frame pattern, repeated N_FRAMES times, each at
      -- a NEW, non-contiguous seek position (unlike getfr's own within-
      -- frame reads): werxrdpt (seek) -> fresh 2-byte RRXDATA (dnpp,
      -- rl=16) -> fresh 6-byte RRXDATA (dpkth, rl=48), continuing from
      -- wherever dnpp's read left reg_erxrdpt (no re-seek between dnpp
      -- and dpkth, matching real pktin exactly).
      ------------------------------------------------------------------
      for i in 0 to N_FRAMES - 1 loop
         -- werxrdpt: seek to this "frame"'s position
         preload(OPCODE_BASE + i * 2, x"8A22", preload_idx, preload_data, preload_valid, cpuclk);
         preload(OPCODE_BASE + i * 2 + 1, conv_std_logic_vector(16#4800# + i * FRAME_SPACING, 16),
                 preload_idx, preload_data, preload_valid, cpuclk);
         wait for 20 ns;
         prog_write("000", conv_std_logic_vector((OPCODE_BASE + i * 2) * 2, 16), bus_addr, bus_dato, bus_control_dato, nclk);
         prog_write("010", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
         prog_write("011", x"0000", bus_addr, bus_dato, bus_control_dato, nclk);
         prog_write("001", x"0020", bus_addr, bus_dato, bus_control_dato, nclk);
         wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
         wait for 500 ns;

         -- dnpp: fresh CS-session, 2 bytes
         preload(400 + i, x"2CC0", preload_idx, preload_data, preload_valid, cpuclk);
         wait for 20 ns;
         prog_write("000", conv_std_logic_vector((400 + i) * 2, 16), bus_addr, bus_dato, bus_control_dato, nclk);
         prog_write("010", conv_std_logic_vector((RESULT_BASE + i * 4) * 2, 16), bus_addr, bus_dato, bus_control_dato, nclk);
         prog_write("011", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);  -- rl = 16 bits = 2 bytes
         prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);  -- xl = 16 bits (b0sel+rrxdata)
         wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
         wait for 500 ns;

         -- dpkth: fresh CS-session, 6 bytes, continuing from dnpp's erxrdpt
         preload(420 + i, x"2CC0", preload_idx, preload_data, preload_valid, cpuclk);
         wait for 20 ns;
         prog_write("000", conv_std_logic_vector((420 + i) * 2, 16), bus_addr, bus_dato, bus_control_dato, nclk);
         prog_write("010", conv_std_logic_vector((RESULT_BASE + i * 4 + 1) * 2, 16), bus_addr, bus_dato, bus_control_dato, nclk);
         prog_write("011", x"0030", bus_addr, bus_dato, bus_control_dato, nclk);  -- rl = 48 bits = 6 bytes
         prog_write("001", x"0010", bus_addr, bus_dato, bus_control_dato, nclk);  -- xl = 16 bits (b0sel+rrxdata)
         wait until xu_cs = '0' for 20 us; wait until xu_cs = '1' for 20 us;
         wait for 500 ns;
      end loop;

      ------------------------------------------------------------------
      -- Verify dnpp (1 word = bytes 0-1) and dpkth (3 words = bytes
      -- 2-7) of every simulated frame against the known ramp, anchored
      -- at this frame's own seek position (i*FRAME_SPACING).
      ------------------------------------------------------------------
      for i in 0 to N_FRAMES - 1 loop
         check(i * FRAME_SPACING, mem(RESULT_BASE + i * 4));
         check(i * FRAME_SPACING + 2, mem(RESULT_BASE + i * 4 + 1));
         check(i * FRAME_SPACING + 4, mem(RESULT_BASE + i * 4 + 2));
         check(i * FRAME_SPACING + 6, mem(RESULT_BASE + i * 4 + 3));
      end loop;

      write(l, string'("=== ") & integer'image(pass_count) & string'(" PASS, ")
             & integer'image(fail_count) & string'(" FAIL"));
      if fail_count > 0 then
         write(l, string'(" (first fail at byte pos ") & integer'image(first_fail_pos) & string'(")"));
      end if;
      write(l, string'(" ==="));
      writeline(output, l);

      wait for 500 ns;
      sim_done <= true;
      wait;
   end process;

end sim;
