-- deps: mister_blkdev.vhd tm11.vhd
--
-- tb_ts11.vhd -- the tape drive in TS11 mode (rtl/tm11.vhd, ts_mode = '1').
--
-- Same synthetic .tap and hps_io slot model as tb_tm11. The TS11 is driven the way its
-- drivers do: command packets in memory, their address written to TSDB, completion by
-- TSSR SSR, results in the message packet the controller DMAs back. Expected values follow
-- SIMH pdp11_ts.c. Checks: reset state, NBA before set characteristics, write
-- characteristics (+CVC), read short/long record and tape mark, rewind, skip tape mark,
-- space reverse (record, into a tape mark), reverse at BOT, write (write lock), read
-- reverse (not implemented: illegal), TSSR-write reset, interrupt request.
--
-- Run: sim/run_sim.sh tb_ts11 --ieee-asserts=disable --stop-time=20ms
--
------------------------------------------------------------------------------
-- testbench
------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity tb_ts11 is
end tb_ts11;

architecture sim of tb_ts11 is

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
         sd_lba : out std_logic_vector(31 downto 0);
         sd_rd : out std_logic;
         sd_wr : out std_logic;
         sd_ack : in std_logic;
         sd_buff_addr : in std_logic_vector(7 downto 0);
         sd_buff_dout : in std_logic_vector(15 downto 0);
         sd_buff_din : out std_logic_vector(15 downto 0);
         sd_buff_wr : in std_logic;
         clk_sys : in std_logic;
         have_tm : in integer range 0 to 1;
         ts_mode : in std_logic := '0';
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
   signal m_dati : std_logic_vector(15 downto 0);
   signal st_we : std_logic := '0';                          -- stimulus preloads memory through these
   signal st_waddr : integer range 0 to 65535 := 0;
   signal st_wdata : std_logic_vector(15 downto 0) := (others => '0');

   signal fail_count : integer := 0;

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
   constant tap : mem_t := make_tap;

   signal clk_sys : std_logic := '0';
   signal sd_lba : std_logic_vector(31 downto 0);
   signal sd_rd, sd_wr : std_logic;
   signal sd_ack : std_logic := '0';
   signal sd_buff_addr : std_logic_vector(7 downto 0) := (others => '0');
   signal sd_buff_dout : std_logic_vector(15 downto 0) := (others => '0');
   signal sd_buff_din : std_logic_vector(15 downto 0);
   signal sd_buff_wr : std_logic := '0';

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
      bus_master_dati => m_dati,
      bus_master_dato => m_dato,
      bus_master_control_dati => m_cdati,
      bus_master_control_dato => m_cdato,
      bus_master_nxm => '0',
      sd_lba => sd_lba,
      sd_rd => sd_rd,
      sd_wr => sd_wr,
      sd_ack => sd_ack,
      sd_buff_addr => sd_buff_addr,
      sd_buff_dout => sd_buff_dout,
      sd_buff_din => sd_buff_din,
      sd_buff_wr => sd_buff_wr,
      clk_sys => clk_sys,
      have_tm => 1,
      ts_mode => '1',
      media_change => media_change,
      reset => reset,
      clk50mhz => clk50,
      nclk => nclk,
      clk => clk
   );

   clk_sys <= not clk_sys after 7 ns;

   -- behavioural hps_io disk slot: read-only, serves the synthetic .tap
   hps: process
      variable base : integer;
   begin
      wait until rising_edge(clk_sys);
      assert sd_wr = '0' report "tm11 issued a block write" severity error;
      if sd_rd = '1' then
         base := conv_integer(sd_lba) * 256;
         for i in 1 to 37 loop wait until rising_edge(clk_sys); end loop;
         sd_ack <= '1';
         wait until rising_edge(clk_sys);
         for w in 0 to 255 loop
            sd_buff_addr <= conv_std_logic_vector(w, 8);
            if base + w <= 2047 then sd_buff_dout <= tap(base + w); else sd_buff_dout <= x"0000"; end if;
            sd_buff_wr <= '1';
            wait until rising_edge(clk_sys);
            sd_buff_wr <= '0';
            for g in 1 to 3 loop wait until rising_edge(clk_sys); end loop;
         end loop;
         sd_ack <= '0';
         wait until rising_edge(clk_sys);
      end if;
   end process;

   -- memory: NPR reads (combinational, as the engine samples the cycle after asserting
   -- dati), NPR writes, and stimulus preloads
   m_dati <= dma_mem(conv_integer(m_addr(16 downto 1)));
   process(clk)
   begin
      if rising_edge(clk) then
         if m_cdato = '1' then
            dma_mem(conv_integer(m_addr(16 downto 1))) <= m_dato;
         elsif st_we = '1' then
            dma_mem(st_waddr) <= st_wdata;
         end if;
      end if;
   end process;

   stim: process

      constant TSDB : std_logic_vector(2 downto 0) := "000";
      constant TSSR : std_logic_vector(2 downto 0) := "001";
      constant PKT  : integer := 8#1000#;                      -- byte addresses
      constant CHR  : integer := 8#2000#;
      constant MSG  : integer := 8#3000#;
      constant BUF  : integer := 8#4000#;
      variable r : std_logic_vector(15 downto 0);

      procedure clk_edges(n : integer) is
      begin
         for i in 1 to n loop
            wait until rising_edge(clk);
         end loop;
      end procedure;

      procedure poke(byteaddr : integer; d : std_logic_vector(15 downto 0)) is
      begin
         wait until rising_edge(clk);
         st_waddr <= byteaddr / 2; st_wdata <= d; st_we <= '1';
         wait until rising_edge(clk);
         st_we <= '0';
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

      procedure check(what : string; got, want : std_logic_vector(15 downto 0)) is
      begin
         if got /= want then
            report "FAIL " & what & ": got " & integer'image(conv_integer(got)) & " want " & integer'image(conv_integer(want)) severity error;
            fail_count <= fail_count + 1;
            wait for 0 ns;
         end if;
      end procedure;

      -- write a command packet at PKT, start it, wait for SSR; returns TSSR
      procedure ts_cmd(hdr, adl, adh, lnt : std_logic_vector(15 downto 0); sr : out std_logic_vector(15 downto 0)) is
         variable t : std_logic_vector(15 downto 0);
      begin
         poke(PKT, hdr); poke(PKT + 2, adl); poke(PKT + 4, adh); poke(PKT + 6, lnt);
         reg_write(TSDB, conv_std_logic_vector(PKT, 16));
         for i in 1 to 400000 loop
            reg_read(TSSR, t);
            exit when t(7) = '1';
         end loop;
         sr := t;
      end procedure;

      procedure msg_check(what : string; hdr, rfc, xs0 : std_logic_vector(15 downto 0)) is
      begin
         check(what & " msg hdr", dma_mem(MSG / 2), hdr);
         check(what & " msg rfc", dma_mem(MSG / 2 + 2), rfc);
         check(what & " msg xs0", dma_mem(MSG / 2 + 3), xs0);
      end procedure;

   begin
      reset <= '1';
      clk_edges(20);
      reset <= '0';
      clk_edges(20);

      -- 1. after reset: SSR and NBA
      reg_read(TSSR, r);
      check("reset TSSR", r, 16o"002200");

      -- 2. a command before write characteristics: NBA -> TC3, no message
      ts_cmd(16o"100017", x"0000", x"0000", x"0000", r);           -- ACK | GSTA
      check("GSTA with NBA TSSR", r, 16o"102206");                  -- SC NBA SSR TC3

      -- 3. write characteristics, clearing volume check: message buffer at MSG, 16 bytes
      poke(CHR, conv_std_logic_vector(MSG, 16)); poke(CHR + 2, x"0000"); poke(CHR + 4, x"0010"); poke(CHR + 6, x"0000");
      ts_cmd(16o"140004", conv_std_logic_vector(CHR, 16), x"0000", x"0008", r);   -- ACK CVC WCHR
      check("WCHR TSSR", r, 16o"000200");                           -- SSR, TC0, NBA clear
      msg_check("WCHR", 16o"100020", x"0000", 16o"000116");           -- ACK|CEND; ONL PET WLK BOT
      check("WCHR msg length", dma_mem(MSG / 2 + 1), x"000C");
      check("WCHR msg xs2", dma_mem(MSG / 2 + 5), 16o"000201");

      -- 4. read 512 bytes: record A is 4 bytes -> record length short, TC2
      ts_cmd(16o"100001", conv_std_logic_vector(BUF, 16), x"0000", conv_std_logic_vector(512, 16), r);
      check("read A TSSR", r, 16o"100204");                         -- SC SSR TC2
      msg_check("read A", 16o"100020", conv_std_logic_vector(508, 16), 16o"040314");
      check("read A data 0", dma_mem(BUF / 2), x"2211");
      check("read A data 1", dma_mem(BUF / 2 + 1), x"4433");

      -- 5. read 4 bytes: record B is 8 -> record length long, TC2, residual 0
      ts_cmd(16o"100001", conv_std_logic_vector(BUF + 8#100#, 16), x"0000", x"0004", r);
      check("read B TSSR", r, 16o"100204");
      msg_check("read B", 16o"100020", x"0000", 16o"010314");
      check("read B data 0", dma_mem((BUF + 8#100#) / 2), x"A1A0");
      check("read B data 1", dma_mem((BUF + 8#100#) / 2 + 1), x"A3A2");

      -- 6. read: tape mark -> TMK RLS, TC2, residual = the request
      ts_cmd(16o"100001", conv_std_logic_vector(BUF, 16), x"0000", x"0064", r);
      check("read TM TSSR", r, 16o"100204");
      msg_check("read TM", 16o"100020", x"0064", 16o"140314");

      -- 7. rewind (position, mode 4): BOT
      ts_cmd(16o"102010", x"0000", x"0000", x"0000", r);
      check("rewind TSSR", r, 16o"000200");
      msg_check("rewind", 16o"100020", x"0000", 16o"000316");

      -- 8. skip 1 tape mark forward (position, mode 2), then read record C (6 bytes)
      ts_cmd(16o"101010", x"0001", x"0000", x"0000", r);
      check("skip TM TSSR", r, 16o"000200");
      msg_check("skip TM", 16o"100020", x"0000", 16o"000314");
      ts_cmd(16o"100001", conv_std_logic_vector(BUF + 8#200#, 16), x"0000", x"0006", r);
      check("read C TSSR", r, 16o"000200");
      msg_check("read C", 16o"100020", x"0000", 16o"000314");
      check("read C data 0", dma_mem((BUF + 8#200#) / 2), x"1101");
      check("read C data 2", dma_mem((BUF + 8#200#) / 2 + 2), x"0055");

      -- 9. space reverse 1 record (over C), then 1 more: the tape mark
      ts_cmd(16o"100410", x"0001", x"0000", x"0000", r);
      check("space rev C TSSR", r, 16o"000200");
      msg_check("space rev C", 16o"100020", x"0000", 16o"000314");
      ts_cmd(16o"100410", x"0001", x"0000", x"0000", r);
      check("space rev TM TSSR", r, 16o"100204");
      msg_check("space rev TM", 16o"100020", x"0000", 16o"140314");

      -- 10. rewind, then space reverse at BOT: function reject, NEF
      ts_cmd(16o"102010", x"0000", x"0000", x"0000", r);
      ts_cmd(16o"100410", x"0001", x"0000", x"0000", r);
      check("rev at BOT TSSR", r, 16o"100206");                     -- SC SSR TC3
      msg_check("rev at BOT", 16o"101021", x"0000", 16o"002116");     -- ACK MNEF CFAIL; NEF ONL PET WLK BOT

      -- 11. write: write locked
      ts_cmd(16o"100005", conv_std_logic_vector(BUF, 16), x"0000", x"0010", r);
      check("write TSSR", r, 16o"100206");
      msg_check("write", 16o"101021", x"0000", 16o"006116");          -- WLE NEF ...

      -- 12. read reverse at BOT: reverse-at-BOT reject first (SIMH checks it before dispatch)
      ts_cmd(16o"100401", conv_std_logic_vector(BUF, 16), x"0000", x"0010", r);
      check("read rev at BOT TSSR", r, 16o"100206");
      msg_check("read rev at BOT", 16o"101021", x"0000", 16o"002116");
      --     away from BOT: not implemented, illegal command
      ts_cmd(16o"100010", x"0001", x"0000", x"0000", r);             -- space forward 1
      ts_cmd(16o"100401", conv_std_logic_vector(BUF, 16), x"0000", x"0010", r);
      check("read rev TSSR", r, 16o"100206");
      msg_check("read rev", 16o"100421", x"0000", 16o"001114");       -- ACK MILL CFAIL; ILC ONL PET WLK

      -- 13. interrupt request when the packet has IE
      ts_cmd(16o"100217", x"0000", x"0000", x"0000", r);           -- ACK IE GSTA
      clk_edges(10);
      if irq_br /= '1' then
         report "FAIL IE: no interrupt request" severity error;
         fail_count <= fail_count + 1;
         wait for 0 ns;
      end if;

      -- 14. TSSR write: subsystem reset -> SSR NBA again
      reg_write(TSSR, x"0000");
      clk_edges(200);
      reg_read(TSSR, r);
      check("TSSR reset", r, 16o"002200");

      if fail_count = 0 then
         report "tb_ts11: PASS" severity note;
      else
         report "tb_ts11: FAIL, " & integer'image(fail_count) & " checks" severity error;
      end if;
      std.env.stop;
      wait;
   end process;

end sim;
