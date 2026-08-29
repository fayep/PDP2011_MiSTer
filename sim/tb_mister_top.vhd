--
-- tb_mister_top.vhd -- GHDL testbench instantiating mister_top plus the
-- XU DDR3 mailbox + ENC424J600 shim pair, mirroring pdp2011.sv's real
-- wiring, to exercise XU's real initenc/chkeudast sequence and decode its
-- debug UART (xu_debug_tx, routed onto tx1 when serial_console='0') in
-- simulation instead of on real hardware. See
-- /Users/faye/.claude/plans/keen-sauteeing-dolphin.md.
--
-- DDRAM_* (the mailbox's clk50mhz-side Avalon-MM port) is modeled here
-- with a trivial always-ready single-cycle-latency memory, not real DDR3
-- timing -- sufficient to test the shim's register logic and CDC
-- handshake correctness, not real hardware timing margins.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_mister_top is
end tb_mister_top;

architecture sim of tb_mister_top is

   signal clk_100 : std_logic := '0';
   signal clk_50 : std_logic := '0';
   signal reset : std_logic := '1';

   signal tx1 : std_logic;
   signal xu_cs, xu_mosi, xu_sclk, xu_miso : std_logic;

   -- DDR3 mailbox <-> shim interface
   signal req_valid, req_ack, resp_valid, req_rw : std_logic;
   signal req_addr : std_logic_vector(15 downto 0);
   signal req_wdata, resp_rdata : std_logic_vector(63 downto 0);
   signal req_be : std_logic_vector(7 downto 0);

   -- trivial DDRAM_* model
   signal DDRAM_CLK, DDRAM_BUSY, DDRAM_RD, DDRAM_WE, DDRAM_DOUT_READY : std_logic := '0';
   signal DDRAM_BURSTCNT, DDRAM_BE : std_logic_vector(7 downto 0);
   signal DDRAM_ADDR : std_logic_vector(28 downto 0);
   signal DDRAM_DIN, DDRAM_DOUT : std_logic_vector(126 downto 0);

   type ram_type is array(0 to 8191) of std_logic_vector(63 downto 0);
   signal ram : ram_type := (others => (others => '0'));

   signal sim_done : boolean := false;

begin

   clk_100 <= not clk_100 after 5 ns when not sim_done else '0';
   clk_50  <= not clk_50  after 10 ns when not sim_done else '0';

   reset <= '1', '0' after 200 ns;

   process
   begin
      wait for 30 ms;
      report "TIMEOUT: simulation ran 30ms without finishing" severity note;
      sim_done <= true;
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
   -- device under test
   ----------------------------------------------------------------------
   dut: entity work.mister_top
   port map(
      clk_100 => clk_100,
      clk_50  => clk_50,
      reset   => reset,

      modelcode => 70,
      serial_console => '0',   -- Virtual VT100 -- routes xu_debug_tx onto tx1
      have_rk => 0,
      have_rl => 0,
      have_rh => 0,
      have_xu => 1,

      vttype => 100,
      have_act => 1,
      vga_cursor_block => '0',
      vga_cursor_blink => '0',
      teste => '0',
      testf => '0',

      rx1 => '1',
      tx1 => tx1,
      rts1 => open,
      cts1 => '0',

      rk_sdcard_cs => open,
      rk_sdcard_mosi => open,
      rk_sdcard_sclk => open,
      rk_sdcard_miso => '1',
      rk_sdcard_debug => open,

      rl_sdcard_cs => open,
      rl_sdcard_mosi => open,
      rl_sdcard_sclk => open,
      rl_sdcard_miso => '1',
      rl_sdcard_debug => open,

      rh_sdcard_cs => open,
      rh_sdcard_mosi => open,
      rh_sdcard_sclk => open,
      rh_sdcard_miso => '1',
      rh_sdcard_debug => open,

      xu_cs => xu_cs,
      xu_mosi => xu_mosi,
      xu_sclk => xu_sclk,
      xu_miso => xu_miso,

      vga_hsync => open,
      vga_vsync => open,
      vga_hblank => open,
      vga_vblank => open,
      ce_pix => open,
      vga_fb => open,
      vga_ht => open,
      ps2k_c => '1',
      ps2k_d => '1',

      dram_addr => open,
      dram_dq => open,
      dram_ba_1 => open,
      dram_ba_0 => open,
      dram_udqm => open,
      dram_ldqm => open,
      dram_ras_n => open,
      dram_cas_n => open,
      dram_cke => open,
      dram_clk => open,
      dram_we_n => open,
      dram_cs_n => open,

      greenled => open
   );

   ----------------------------------------------------------------------
   -- XU DDR3 mailbox + ENC424J600 shim, same wiring as pdp2011.sv
   ----------------------------------------------------------------------
   mailbox: entity work.xu_ddr_mailbox
   port map(
      reset => reset,
      cpuclk => clk_100,   -- placeholder: mister_top's internal cpuclk isn't
                            -- exposed; real hardware uses its own irregular
                            -- cpuclk -- see caveat in report at bottom
      req_valid => req_valid,
      req_addr => req_addr,
      req_wdata => req_wdata,
      req_be => req_be,
      req_rw => req_rw,
      req_ack => req_ack,
      resp_valid => resp_valid,
      resp_rdata => resp_rdata,

      clk50mhz => clk_50,
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
      cpuclk => clk_100,

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
   -- tx1 UART decoder, 115200 baud (xu_debug_tx's real rate), 8N1.
   -- Prints each received byte as it arrives.
   ----------------------------------------------------------------------
   process
      constant BIT_PERIOD : time := 8680 ns;  -- 1/115200s
      variable l : line;
      variable byte : std_logic_vector(7 downto 0);
      variable c : character;
   begin
      wait until tx1 = '0' and not sim_done;  -- start bit
      wait for BIT_PERIOD / 2;
      assert tx1 = '0' report "bad start bit" severity warning;
      for i in 0 to 7 loop
         wait for BIT_PERIOD;
         byte(i) := tx1;
      end loop;
      wait for BIT_PERIOD;  -- stop bit
      if byte >= x"20" and byte <= x"7E" then
         c := character'val(conv_integer(byte));
         write(l, string'("tx1 byte: 0x"));
         hwrite(l, byte);
         write(l, string'(" '") & c & "'");
      else
         write(l, string'("tx1 byte: 0x"));
         hwrite(l, byte);
      end if;
      writeline(output, l);
   end process;

end sim;
