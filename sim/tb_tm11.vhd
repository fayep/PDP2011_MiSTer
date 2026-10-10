-- deps: sdspi.vhd tm11.vhd
--
-- tb_tm11.vhd -- GHDL dry-run harness for rtl/tm11.vhd
--
-- Substitutes a behavioural mock for sdspi (this file is analysed after the
-- real rtl/sdspi.vhd, so tm11's `sd1 : sdspi` binds to the mock -- GHDL emits
-- a "was also defined" warning, which is expected here).  The mock serves
-- 512-byte blocks out of an in-memory synthetic .tap image.
--
-- A tiny Unibus BFM writes MTBRC/MTCMA/MTC and reads MTS/MTC/MTBRC; a memory
-- model captures NPR writes into dma_mem.  Checks: record read + DMA payload,
-- MTBRC residual, tape mark -> EOF, record-length error, rewind -> BOT,
-- space forward / reverse.
--
-- Run:  sim/run_sim.sh tb_tm11 --stop-time=2ms
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

------------------------------------------------------------------------------
-- mock sdspi
------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity sdspi is
   port(
      sdcard_cs : out std_logic;
      sdcard_mosi : out std_logic;
      sdcard_sclk : out std_logic;
      sdcard_miso : in std_logic := '0';
      sdcard_debug : out std_logic_vector(3 downto 0);

      sdcard_addr : in std_logic_vector(23 downto 0);

      sdcard_idle : out std_logic;
      sdcard_read_start : in std_logic;
      sdcard_read_ack : in std_logic;
      sdcard_read_done : out std_logic;
      sdcard_write_start : in std_logic;
      sdcard_write_ack : in std_logic;
      sdcard_write_done : out std_logic;
      sdcard_error : out std_logic;

      sdcard_xfer_addr : in integer range 0 to 255;
      sdcard_xfer_read : in std_logic;
      sdcard_xfer_out : out std_logic_vector(15 downto 0);
      sdcard_xfer_write : in std_logic;
      sdcard_xfer_in : in std_logic_vector(15 downto 0);

      enable : in integer range 0 to 1 := 0;
      controller_clk : in std_logic;
      reset : in std_logic;
      clk50mhz : in std_logic
   );
end sdspi;

architecture mock of sdspi is

   type mem_t is array(0 to 2047) of std_logic_vector(15 downto 0);

   function make_tap return mem_t is
      variable m : mem_t := (others => x"0000");
   begin
      -- record A : length 4, payload bytes 11 22 33 44   (bytes 0..11)
      m(0) := x"0004"; m(1) := x"0000";
      m(2) := x"2211"; m(3) := x"4433";
      m(4) := x"0004"; m(5) := x"0000";
      -- record B : length 8, payload A0 A1 .. A7          (bytes 12..27)
      m(6) := x"0008"; m(7) := x"0000";
      m(8) := x"A1A0"; m(9) := x"A3A2"; m(10) := x"A5A4"; m(11) := x"A7A6";
      m(12) := x"0008"; m(13) := x"0000";
      -- tape mark 1                                        (bytes 28..31)
      m(14) := x"0000"; m(15) := x"0000";
      -- record C : length 6, payload 01 11 02 33 55 00     (bytes 32..45)
      m(16) := x"0006"; m(17) := x"0000";
      m(18) := x"1101"; m(19) := x"3302"; m(20) := x"0055";
      m(21) := x"0006"; m(22) := x"0000";
      -- tape mark 2                                        (bytes 46..49)
      m(23) := x"0000"; m(24) := x"0000";
      -- end of medium                                      (bytes 50..)
      m(25) := x"FFFF"; m(26) := x"FFFF";
      return m;
   end function;

   signal tap : mem_t := make_tap;
   signal blk : mem_t := (others => x"0000");
   signal rdone : std_logic := '0';
   signal delay : integer range 0 to 15 := 0;

begin

   sdcard_cs <= '1';
   sdcard_mosi <= '0';
   sdcard_sclk <= '0';
   sdcard_debug <= "0000";
   sdcard_idle <= '1';
   sdcard_write_done <= '0';
   sdcard_error <= '0';
   sdcard_read_done <= rdone;

   process(controller_clk)
      variable base : integer;
   begin
      if rising_edge(controller_clk) then
         sdcard_xfer_out <= blk(sdcard_xfer_addr);

         if reset = '1' then
            rdone <= '0';
            delay <= 0;
         else
            if rdone = '0' and sdcard_read_start = '1' and delay = 0 then
               delay <= 4;
            elsif delay > 1 then
               delay <= delay - 1;
            elsif delay = 1 then
               base := conv_integer(sdcard_addr) * 256;
               for i in 0 to 255 loop
                  if (base + i) <= 2047 then
                     blk(i) <= tap(base + i);
                  else
                     blk(i) <= x"0000";
                  end if;
               end loop;
               delay <= 0;
               rdone <= '1';
            end if;

            if rdone = '1' and sdcard_read_ack = '1' then
               rdone <= '0';
            end if;
         end if;
      end if;
   end process;

end mock;

------------------------------------------------------------------------------
-- testbench
------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity tb_tm11 is
end tb_tm11;

architecture sim of tb_tm11 is

   component tm11 is
      port(
         base_addr : in std_logic_vector(17 downto 0);
         ivec : in std_logic_vector(8 downto 0);
         br : out std_logic;
         bg : in std_logic;
         int_vector : out std_logic_vector(8 downto 0);
         npr : out std_logic;
         npg : in std_logic;
         bus_addr_match : out std_logic;
         bus_addr : in std_logic_vector(17 downto 0);
         bus_dati : out std_logic_vector(15 downto 0);
         bus_dato : in std_logic_vector(15 downto 0);
         bus_control_dati : in std_logic;
         bus_control_dato : in std_logic;
         bus_control_datob : in std_logic;
         bus_master_addr : out std_logic_vector(17 downto 0);
         bus_master_dati : in std_logic_vector(15 downto 0);
         bus_master_dato : out std_logic_vector(15 downto 0);
         bus_master_control_dati : out std_logic;
         bus_master_control_dato : out std_logic;
         bus_master_nxm : in std_logic;
         sdcard_cs : out std_logic;
         sdcard_mosi : out std_logic;
         sdcard_sclk : out std_logic;
         sdcard_miso : in std_logic;
         sdcard_debug : out std_logic_vector(3 downto 0);
         have_tm : in integer range 0 to 1;
         media_change : in std_logic := '0';
         reset : in std_logic;
         clk50mhz : in std_logic;
         nclk : in std_logic;
         clk : in std_logic
      );
   end component;

   constant TM_BASE : std_logic_vector(17 downto 0) := o"772520";

   constant MTS   : std_logic_vector(2 downto 0) := "000";
   constant MTC   : std_logic_vector(2 downto 0) := "001";
   constant MTBRC : std_logic_vector(2 downto 0) := "010";
   constant MTCMA : std_logic_vector(2 downto 0) := "011";

   -- function codes shifted into MTC bits 3:1, plus GO
   constant GO_READ   : std_logic_vector(15 downto 0) := x"0003";  -- fnc 001
   constant GO_SPACEF : std_logic_vector(15 downto 0) := x"0009";  -- fnc 100
   constant GO_SPACER : std_logic_vector(15 downto 0) := x"000B";  -- fnc 101
   constant GO_REWIND : std_logic_vector(15 downto 0) := x"000F";  -- fnc 111

   signal clk    : std_logic := '0';
   signal nclk   : std_logic := '1';
   signal clk50  : std_logic := '0';
   signal reset  : std_logic := '1';
   signal media_change : std_logic := '0';

   signal b_addr  : std_logic_vector(17 downto 0) := (others => '0');
   signal b_dato  : std_logic_vector(15 downto 0) := (others => '0');
   signal b_dati  : std_logic_vector(15 downto 0);
   signal b_cdati : std_logic := '0';
   signal b_cdato : std_logic := '0';

   signal m_addr  : std_logic_vector(17 downto 0);
   signal m_dato  : std_logic_vector(15 downto 0);
   signal m_cdati : std_logic;
   signal m_cdato : std_logic;
   signal npr, npg : std_logic;
   signal irq_br  : std_logic;
   signal irq_vec : std_logic_vector(8 downto 0);

   type dma_t is array(0 to 65535) of std_logic_vector(15 downto 0);
   signal dma_mem : dma_t := (others => x"0000");

   signal fail_count : integer := 0;

begin

   clk    <= not clk    after 10 ns;
   nclk   <= not nclk   after 10 ns;
   clk50  <= not clk50  after 10 ns;
   npg    <= npr;

   dut: tm11 port map(
      base_addr => o"772520",
      ivec => o"224",
      br => irq_br,
      bg => '0',
      int_vector => irq_vec,
      npr => npr,
      npg => npg,
      bus_addr_match => open,
      bus_addr => b_addr,
      bus_dati => b_dati,
      bus_dato => b_dato,
      bus_control_dati => b_cdati,
      bus_control_dato => b_cdato,
      bus_control_datob => '0',
      bus_master_addr => m_addr,
      bus_master_dati => (others => '0'),
      bus_master_dato => m_dato,
      bus_master_control_dati => m_cdati,
      bus_master_control_dato => m_cdato,
      bus_master_nxm => '0',
      sdcard_cs => open,
      sdcard_mosi => open,
      sdcard_sclk => open,
      sdcard_miso => '0',
      sdcard_debug => open,
      have_tm => 1,
      media_change => media_change,
      reset => reset,
      clk50mhz => clk50,
      nclk => nclk,
      clk => clk
   );

   -- NPR memory model
   process(clk)
   begin
      if rising_edge(clk) then
         if m_cdato = '1' then
            dma_mem(conv_integer(m_addr(16 downto 1))) <= m_dato;
         end if;
      end if;
   end process;

   stim: process

      procedure clk_edges(n : integer) is
      begin
         for i in 1 to n loop
            wait until rising_edge(clk);
         end loop;
      end procedure;

      procedure reg_write(off : std_logic_vector(2 downto 0); d : std_logic_vector(15 downto 0)) is
      begin
         wait until rising_edge(nclk);
         b_addr  <= TM_BASE(17 downto 4) & off & '0';
         b_dato  <= d;
         b_cdato <= '1';
         wait until rising_edge(nclk);
         b_cdato <= '0';
         b_addr  <= (others => '0');
      end procedure;

      procedure reg_read(off : std_logic_vector(2 downto 0); r : out std_logic_vector(15 downto 0)) is
      begin
         wait until rising_edge(nclk);
         b_addr  <= TM_BASE(17 downto 4) & off & '0';
         b_cdati <= '1';
         wait until rising_edge(nclk);
         wait until rising_edge(nclk);
         r := b_dati;
         b_cdati <= '0';
         b_addr  <= (others => '0');
      end procedure;

      procedure wait_ready(what : string) is
         variable v : std_logic_vector(15 downto 0);
         variable n : integer := 0;
      begin
         loop
            reg_read(MTC, v);
            exit when v(7) = '1';            -- CU RDY / DONE
            n := n + 1;
            if n > 4000 then
               report "TIMEOUT waiting for RDY after " & what severity failure;
               exit;
            end if;
         end loop;
      end procedure;

      procedure chk16(tag : string; got, exp : std_logic_vector(15 downto 0)) is
      begin
         if got = exp then
            report "PASS " & tag;
         else
            report "FAIL " & tag & " got=" & integer'image(conv_integer(got))
                 & " exp=" & integer'image(conv_integer(exp)) severity error;
            fail_count <= fail_count + 1;
         end if;
      end procedure;

      procedure chk_bit(tag : string; v : std_logic_vector(15 downto 0); b : integer; exp : std_logic) is
      begin
         if v(b) = exp then
            report "PASS " & tag;
         else
            report "FAIL " & tag & " bit" & integer'image(b) & "=" & std_logic'image(v(b))
                 & " exp=" & std_logic'image(exp) severity error;
            fail_count <= fail_count + 1;
         end if;
      end procedure;

      variable v : std_logic_vector(15 downto 0);

   begin
      reset <= '1';
      clk_edges(8);
      reset <= '0';
      clk_edges(8);

      -- power-up status
      reg_read(MTS, v);
      chk_bit("powerup MTS TUR", v, 0, '1');
      chk_bit("powerup MTS BOT", v, 5, '1');
      chk_bit("powerup MTS WLK", v, 2, '1');
      reg_read(MTC, v);
      chk_bit("powerup MTC RDY", v, 7, '1');

      ---------------------------------------------------------------------
      -- read record A (4 bytes) into 0x1000
      ---------------------------------------------------------------------
      reg_write(MTBRC, x"FFFC");            -- -4
      reg_write(MTCMA, x"1000");
      reg_write(MTC,   GO_READ);
      wait_ready("read A");
      chk16("read A word0", dma_mem(16#0800#), x"2211");   -- 0x1000/2
      chk16("read A word1", dma_mem(16#0801#), x"4433");
      reg_read(MTBRC, v); chk16("read A MTBRC residual", v, x"0000");
      reg_read(MTS, v);
      chk_bit("read A no EOF", v, 14, '0');
      chk_bit("read A no RLE", v, 9, '0');

      ---------------------------------------------------------------------
      -- read record B (8 bytes) into 0x2000
      ---------------------------------------------------------------------
      reg_write(MTBRC, x"FFF8");            -- -8
      reg_write(MTCMA, x"2000");
      reg_write(MTC,   GO_READ);
      wait_ready("read B");
      chk16("read B w0", dma_mem(16#1000#), x"A1A0");
      chk16("read B w1", dma_mem(16#1001#), x"A3A2");
      chk16("read B w2", dma_mem(16#1002#), x"A5A4");
      chk16("read B w3", dma_mem(16#1003#), x"A7A6");
      reg_read(MTBRC, v); chk16("read B MTBRC residual", v, x"0000");

      ---------------------------------------------------------------------
      -- read at tape mark -> EOF, no transfer
      ---------------------------------------------------------------------
      reg_write(MTBRC, x"FFF0");
      reg_write(MTCMA, x"3000");
      reg_write(MTC,   GO_READ);
      wait_ready("read tapemark");
      reg_read(MTS, v);
      chk_bit("tapemark EOF", v, 14, '1');
      chk16("tapemark no DMA", dma_mem(16#1800#), x"0000");

      ---------------------------------------------------------------------
      -- rewind -> BOT
      ---------------------------------------------------------------------
      reg_write(MTC, GO_REWIND);
      wait_ready("rewind");
      reg_read(MTS, v);
      chk_bit("rewind BOT", v, 5, '1');

      ---------------------------------------------------------------------
      -- record-length error: ask for only 2 bytes of the 4-byte record A
      ---------------------------------------------------------------------
      reg_write(MTBRC, x"FFFE");            -- -2
      reg_write(MTCMA, x"4000");
      reg_write(MTC,   GO_READ);
      wait_ready("RLE read");
      chk16("RLE partial word", dma_mem(16#2000#), x"2211");
      reg_read(MTS, v);
      chk_bit("RLE set", v, 9, '1');
      reg_read(MTBRC, v); chk16("RLE MTBRC residual", v, x"0000");

      ---------------------------------------------------------------------
      -- space forward one record from BOT, then read -> should get record B
      ---------------------------------------------------------------------
      reg_write(MTC, GO_REWIND);
      wait_ready("rewind2");
      reg_write(MTBRC, x"FFFF");            -- -1 : one record
      reg_write(MTC,   GO_SPACEF);
      wait_ready("space fwd");
      reg_write(MTBRC, x"FFF8");
      reg_write(MTCMA, x"5000");
      reg_write(MTC,   GO_READ);
      wait_ready("read after spacef");
      chk16("spacef then read = B w0", dma_mem(16#2800#), x"A1A0");

      ---------------------------------------------------------------------
      -- space reverse one record, then read -> record B again
      ---------------------------------------------------------------------
      reg_write(MTBRC, x"FFFF");
      reg_write(MTC,   GO_SPACER);
      wait_ready("space rev");
      reg_write(MTBRC, x"FFF8");
      reg_write(MTCMA, x"6000");
      reg_write(MTC,   GO_READ);
      wait_ready("read after spacer");
      chk16("spacer then read = B w0", dma_mem(16#3000#), x"A1A0");
      chk16("spacer then read = B w3", dma_mem(16#3003#), x"A7A6");

      ---------------------------------------------------------------------
      -- media change (tape (un)mount) re-homes to BOT without a reset
      ---------------------------------------------------------------------
      media_change <= not media_change;
      clk_edges(12);
      reg_read(MTS, v);
      chk_bit("media change -> BOT", v, 5, '1');
      reg_write(MTBRC, x"FFFC");
      reg_write(MTCMA, x"7000");
      reg_write(MTC,   GO_READ);
      wait_ready("read after media change");
      chk16("media change then read = A w0", dma_mem(16#3800#), x"2211");
      chk16("media change then read = A w1", dma_mem(16#3801#), x"4433");

      ---------------------------------------------------------------------
      if fail_count = 0 then
         report "tb_tm11: ALL CHECKS PASSED" severity note;
      else
         report "tb_tm11: " & integer'image(fail_count) & " CHECK(S) FAILED" severity failure;
      end if;
      wait;
   end process;

end sim;
