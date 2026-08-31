--
-- tb_xu_erxrdpt_cache.vhd -- regression test for the stale RX word cache
-- bug fixed in xu_enc424j600_shim.vhd (commit c5e2086, 2026-08-30):
-- WCRU to ADDR_ERXRDPT (firmware's werxrdpt, issued once per frame in
-- pktin) now clears rx_cur_valid/rx_nxt_valid/rx_nxt_pending, forcing a
-- genuine fresh DDR3 fetch instead of risking a stale cached word (most
-- often the tail end of the *previous* frame's own payload, from the
-- shim's speculative prefetch-past-frame-boundary logic) being served
-- back to firmware as the new frame's header.
--
-- Real hardware evidence that found this bug: firmware's own "DBG pktin
-- hdr:" trace showed recognizable broadcast-MAC + EtherType-0x0800 bytes
-- (payload content) where the header's small next_ptr/framelen values
-- should have been.
--
-- Built on tb_xu_rxen_throttle.vhd's proven harness and technique
-- (real xu.vhd + real xu_enc424j600_shim.vhd + real xu_ddr_mailbox.vhd +
-- real xubrt45 ROM; bus_master_dati held at the real "own" bit so pktin
-- always finds a buffer and actually runs; DDR3 mailbox backing store
-- poked directly to simulate the daemon). New here: instead of just
-- bumping ERXHEAD, THREE distinct, real-format frames (8-byte header +
-- payload, matching support/xu/xu.cpp's xu_rx_enqueue() exactly) are
-- written directly into the RX buffer back-to-back, at addresses that
-- span multiple 8-byte DDR3 words -- the exact condition the fixed bug
-- depended on (a new frame's header landing on a word position the
-- cache had stale data for).
--
-- No VCD, no external names -- pass/fail is judged from the existing
-- UART decoder process's plain stdout trace (the same "DBG pktin hdr:"/
-- "DBG pktin flen:" text lines already used to diagnose this on real
-- hardware), checked externally after the run. Expect three flen
-- prints, in order, matching the three injected framelens below (60,
-- 200, 1066 decimal = 3c 00 / c8 00 / 2a 04 in the byte order this
-- firmware prints) -- not garbage, not repeats.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_xu_erxrdpt_cache is
end tb_xu_erxrdpt_cache;

architecture sim of tb_xu_erxrdpt_cache is

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

   -- ERXHEAD (0x6030) >> 3 = 0xC06 -- see tb_xu_rxen_throttle.vhd's own
   -- comment for the WINDOW_WORD_BASE arithmetic this relies on.
   constant ERXHEAD_RAM_IDX : integer := 16#C06#;
   -- MAC_VALID (0x6048) >> 3 = 0xC09. The shim's background poll checks
   -- "mac_valid_local = '0'" ahead of ERXHEAD in its priority chain (real,
   -- intentional design -- see xu_enc424j600_shim.vhd's own comment at
   -- that branch) and polls MAC_VALID forever until it sees a real '1'
   -- there, never reaching ERXHEAD at all otherwise. Real hardware always
   -- has this published by the daemon shortly after boot; this testbench
   -- must do the same or nothing downstream of it ever polls.
   constant MAC_VALID_RAM_IDX : integer := 16#C09#;

   constant CMD_GETPCBB : std_logic_vector(15 downto 0) := x"0001";
   constant CMD_GETCMD  : std_logic_vector(15 downto 0) := x"0002";
   constant CMD_START   : std_logic_vector(15 downto 0) := x"0004";
   constant PCSR0_INTE  : std_logic_vector(15 downto 0) := x"0040";

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

   -- Pure function: bytes-needed for one real-format RX frame (8-byte
   -- header, even-padded), matching xu_rx_enqueue()'s own "need"
   -- computation exactly.
   function frame_need(framelen : integer) return integer is
      variable need : integer;
   begin
      need := 8 + framelen;
      if (need mod 2) /= 0 then need := need + 1; end if;
      return need;
   end function;

begin

   cpuclk <= not cpuclk after 50 ns when not sim_done else '0';  -- ~10MHz
   nclk <= not cpuclk;
   clk50mhz <= not clk50mhz after 10 ns when not sim_done else '0';

   reset <= '1', '0' after 500 ns;

   bus_dati <= (others => '0');

   process
   begin
      wait for 300 ms;
      report "TIMEOUT: simulation ran 300ms without finishing (relying on --stop-time to end it)" severity note;
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
      bus_master_dati => x"8000",  -- real "own" bit (100000 octal) always set
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
   -- main sequence: bring the device up, then inject three real-format
   -- frames spanning several 8-byte DDR3 words, and bump ERXHEAD to 3.
   ----------------------------------------------------------------------
   process
      variable start, framelen, need, next_ptr, fill : integer;
      variable widx, blane : integer;
   begin
      wait until reset = '0';
      report "=== publishing MAC_VALID=1 (unblocks the shim's background poll priority chain) ===";
      ram(MAC_VALID_RAM_IDX)(15 downto 0) <= x"0001";
      wait for 3 ms;
      report "=== driving GETPCBB ===";
      bus_write(bus_addr, bus_dato, bus_control_dato, o"774510", CMD_GETPCBB);
      wait for 200 us;

      report "=== driving GETCMD (fc11: write ring format) ===";
      bus_write(bus_addr, bus_dato, bus_control_dato, o"774510", CMD_GETCMD);
      wait for 200 us;

      report "=== driving GETCMD (fc15: write mode bits) ===";
      bus_write(bus_addr, bus_dato, bus_control_dato, o"774510", CMD_GETCMD);
      wait for 200 us;

      report "=== driving PCSR0_INTE alone ===";
      bus_write(bus_addr, bus_dato, bus_control_dato, o"774510", PCSR0_INTE);
      wait for 50 us;

      report "=== driving CMD_START | PCSR0_INTE ===";
      bus_write(bus_addr, bus_dato, bus_control_dato, o"774510", CMD_START or PCSR0_INTE);
      wait for 2 ms;

      report "=== injecting 3 real-format frames: 60, 200, 1066 bytes ===";
      start := 16#4800#;
      for f in 0 to 2 loop
         if f = 0 then framelen := 60; fill := 16#AA#;
         elsif f = 1 then framelen := 200; fill := 16#BB#;
         else framelen := 1066; fill := 16#CC#;
         end if;

         need := 8 + framelen;
         if (need mod 2) /= 0 then need := need + 1; end if;
         next_ptr := start + need;

         widx := (start + 0) / 8; blane := (start + 0) mod 8;
         ram(widx)(blane*8+7 downto blane*8) <= conv_std_logic_vector(next_ptr mod 256, 8);
         widx := (start + 1) / 8; blane := (start + 1) mod 8;
         ram(widx)(blane*8+7 downto blane*8) <= conv_std_logic_vector((next_ptr / 256) mod 256, 8);
         widx := (start + 2) / 8; blane := (start + 2) mod 8;
         ram(widx)(blane*8+7 downto blane*8) <= conv_std_logic_vector(framelen mod 256, 8);
         widx := (start + 3) / 8; blane := (start + 3) mod 8;
         ram(widx)(blane*8+7 downto blane*8) <= conv_std_logic_vector((framelen / 256) mod 256, 8);
         for k in 4 to 7 loop
            widx := (start + k) / 8; blane := (start + k) mod 8;
            ram(widx)(blane*8+7 downto blane*8) <= x"00";
         end loop;
         for i in 0 to framelen - 1 loop
            widx := (start + 8 + i) / 8; blane := (start + 8 + i) mod 8;
            ram(widx)(blane*8+7 downto blane*8) <= conv_std_logic_vector(fill, 8);
         end loop;

         start := next_ptr;
      end loop;

      report "=== bumping ERXHEAD to 3 ===";
      ram(ERXHEAD_RAM_IDX)(15 downto 0) <= x"0003";

      wait for 250 ms;
      report "=== sequence complete ===";
      sim_done <= true;
      wait;
   end process;

end sim;
