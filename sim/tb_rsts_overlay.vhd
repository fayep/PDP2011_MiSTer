-- tb_rsts_overlay.vhd -- real CPU + real kw11l + real rh11: does a POLLED
-- RH70 multi-sector read survive being preempted by the line clock?
--
-- The RSTS/E V10.1 wedge: the monitor faults in an overlay from RSTS.SIL
-- with a polled RH70 read (CS1 IE = 0) at priority 5, and the line clock
-- (BR6) preempts the poll loop repeatedly.  tb_rh11_dma proved the DMA
-- datapath alone is fine (BFM driver, no CPU, no clock).  This puts the
-- whole unibus in the loop: cpu.vhd + mmu.vhd + kw11l.vhd + rh11.vhd,
-- zero-wait RAM for physical 0..0177777, and a behavioural sdspi that
-- serves an identifiable pattern after a long delay so the clock ticks
-- while the program is spinning on CS1.
--
-- Program: sim/tb_rsts_overlay.mac  (macro11 -> mac2mem.py -> .mem)
--   result(0500) = 1   every sector's poll saw RDY, program finished
--   result       = 77  RH raised SC / error
--   result       = 0   still spinning when the harness budget ran out
--                      -> HANG reproduced; count(0502) sectors done,
--                         last(0506) = the CS1 value the poll kept seeing
--
-- Run:  sim/run_sim.sh tb_rsts_overlay --ieee-asserts=disable
--
-- This file defines its own behavioural `entity sdspi` (below) to shadow
-- the real rtl/sdspi.vhd, so it needs the explicit-deps form of
-- run_sim.sh (auto-import via `ghdl -m` would fight the mock) -- see
-- run_sim.sh's own header comment. Full transitive closure of what
-- `dut : entity work.unibus` (below) needs to elaborate, real sdspi.vhd
-- included so this file's own mock architecture is the last one
-- analysed and wins the default binding:
-- deps: cpuregs.vhd fpuregs.vhd cpu.vhd mmu.vhd cr.vhd csdr.vhd xubm.vhd xubl.vhd xubrt45.vhd xu.vhd m9312h47.vhd m9312l47.vhd kl11.vhd kw11l.vhd sdspi.vhd rh11.vhd rk11.vhd rl11.vhd dr11c.vhd mncad.vhd mnckw.vhd mncaa.vhd mncdi.vhd mncdo.vhd unibus.vhd

------------------------------------------------------------------------
-- behavioural sdspi (bound in place of the real one: run_sim.sh analyses
-- rtl/sdspi.vhd first and this file last, so rh11's sd1 binds here)
------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

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
   -- long enough that the ~125us line-clock tick fires while the CPU is
   -- spinning on CS1 for this sector
   constant READ_DELAY : integer := 8000;
   signal cur_block : integer := 0;
   signal busy      : boolean := false;
   signal cnt       : integer := 0;
begin
   sdcard_cs <= '1'; sdcard_mosi <= '0'; sdcard_sclk <= '0';
   sdcard_debug <= "0000"; sdcard_error <= '0';
   sdcard_write_done <= '0';
   sdcard_idle <= '0' when busy else '1';

   process(controller_clk)
   begin
      if rising_edge(controller_clk) then
         -- real sdspi registers xfer_out one controller_clk after xfer_addr
         sdcard_xfer_out <= std_logic_vector(to_unsigned(
              ((cur_block + 1) * 8#4000#) + sdcard_xfer_addr, 16));
         if reset = '1' then
            busy <= false; cnt <= 0; sdcard_read_done <= '0';
         else
            if not busy then
               sdcard_read_done <= '0';
               if sdcard_read_start = '1' then
                  cur_block <= to_integer(unsigned(sdcard_addr));
                  busy <= true; cnt <= 0;
               end if;
            else
               cnt <= cnt + 1;
               if cnt = READ_DELAY then
                  sdcard_read_done <= '1';
               end if;
               if cnt >= READ_DELAY and sdcard_read_ack = '1' then
                  sdcard_read_done <= '0';
                  busy <= false;
               end if;
            end if;
         end if;
      end if;
   end process;
end mock;

------------------------------------------------------------------------
-- the testbench proper
------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;

entity tb_rsts_overlay is
   generic (
      mem    : string  := "tb_rsts_overlay.mem";
      trace  : boolean := false;
      budget : integer := 400000        -- cpu-clock cycles before "HANG"
   );
end tb_rsts_overlay;

architecture sim of tb_rsts_overlay is

   signal clk        : std_logic := '0';
   signal clk50      : std_logic := '0';
   signal reset      : std_logic := '1';

   signal addr       : std_logic_vector(21 downto 0);
   signal dati       : std_logic_vector(15 downto 0) := (others => '0');
   signal dato       : std_logic_vector(15 downto 0);
   signal control_dati  : std_logic;
   signal control_dato  : std_logic;
   signal control_datob : std_logic;
   signal addr_match : std_logic;

   signal cons_run   : std_logic;
   signal dbg_r7     : std_logic_vector(15 downto 0);
   signal dbg_psw    : std_logic_vector(15 downto 0);
   signal dbg_ir     : std_logic_vector(15 downto 0);

   -- 0..32767 = low 64K (program + result cells, BAE=0); 32768..65535 =
   -- physical 65536..131071 bytes (BAE=1), used by phase 5 to check the
   -- DMA target the real hang actually used (BAE=1|BA=131000, i.e.
   -- physical bit 16 set)
   type ram_t is array(0 to 65535) of std_logic_vector(15 downto 0);

   impure function load_mem return ram_t is
      variable m : ram_t := (others => (others => '0'));
      file     fh : text;
      variable st : file_open_status;
      variable ln : line;
      variable widx, d : integer;
      variable good : boolean;
   begin
      file_open(st, fh, mem, read_mode);
      assert st = open_ok report "cannot open " & mem severity failure;
      while not endfile(fh) loop
         readline(fh, ln);
         read(ln, widx, good); next when not good;
         read(ln, d, good);    next when not good;
         m(widx) := std_logic_vector(to_unsigned(d, 16));
      end loop;
      file_close(fh);
      return m;
   end function;

   function oct(v : std_logic_vector) return string is
      variable u : unsigned(v'length + 2 downto 0) := (others => '0');
      variable r : string(1 to (v'length + 2) / 3);
      variable d : integer;
   begin
      u(v'length - 1 downto 0) := unsigned(v);
      for i in r'reverse_range loop
         d := to_integer(u(2 downto 0));
         r(i) := character'val(character'pos('0') + d);
         u := shift_right(u, 3);
      end loop;
      return r;
   end function;

   signal ram      : ram_t := load_mem;

begin

   clk   <= not clk   after 10 ns;      -- ~50 MHz cpu clock
   clk50 <= not clk50 after 1 ns;       -- fast peripheral clock so the
                                        -- kw11l divider reaches its limit
                                        -- (and the clock ticks) within a
                                        -- realistic sim window
   reset <= '1', '0' after 205 ns;

   dut : entity work.unibus
      port map(
         modelcode    => 70,
         have_kl11    => 0,
         have_kw11l   => 1,
         kw11l_hz     => 800,           -- fastest divider setting
         have_rh      => 1,
         rh_type      => 6,             -- RP06
         init_r7      => x"0200",       -- o'001000'
         init_psw     => x"00e0",       -- o'000340' kernel pri 7

         addr         => addr,
         dati         => dati,
         dato         => dato,
         control_dati => control_dati,
         control_dato => control_dato,
         control_datob=> control_datob,
         addr_match   => addr_match,

         cons_run     => cons_run,
         -- dbg_r7/dbg_psw/dbg_ir (front-panel debug ports) don't exist
         -- on this branch's unibus.vhd -- left unconnected; the report
         -- line below that reads them stays a best-effort debug print.

         clk          => clk,
         clk50mhz     => clk50,
         reset        => reset
      );

   -- zero-wait-state RAM, physical 0..0377777 (BAE 0 and 1; below the I/O page)
   addr_match <= '1' when addr(21 downto 13) /= "111111111"
                     and unsigned(addr) < 131072
                 else '0';

   dati <= ram(to_integer(unsigned(addr(16 downto 1))))
           when addr_match = '1'
           else (others => '0');

   process(clk)
   begin
      if rising_edge(clk) then
         if addr_match = '1' and control_dato = '1' then
            if control_datob = '0' then
               ram(to_integer(unsigned(addr(16 downto 1)))) <= dato;
            elsif addr(0) = '0' then
               ram(to_integer(unsigned(addr(16 downto 1))))(7 downto 0) <= dato(7 downto 0);
            else
               ram(to_integer(unsigned(addr(16 downto 1))))(15 downto 8) <= dato(15 downto 8);
            end if;
         end if;
      end if;
   end process;

   tracegen : if trace generate
      process
      begin
         wait until reset = '0';
         loop
            wait until rising_edge(clk);
            if control_dati = '1' or control_dato = '1' then
               report "bus a=" & oct(addr) & " di=" & oct(dati) &
                  " do=" & oct(dato) &
                  " rd=" & std_logic'image(control_dati)(2) &
                  " wr=" & std_logic'image(control_dato)(2) &
                  " r7=" & oct(dbg_r7) & " psw=" & oct(dbg_psw);
            end if;
         end loop;
      end process;
   end generate;

   -- result watcher
   process
      variable res, cnt, tks, lst : std_logic_vector(15 downto 0);
      variable i : integer := 0;
   begin
      wait until reset = '0';
      loop
         wait until rising_edge(clk);
         i := i + 1;
         res := ram(8#500# / 2);
         exit when res /= x"0000";
         exit when i >= budget;
      end loop;

      res := ram(8#500# / 2);
      cnt := ram(8#502# / 2);
      tks := ram(8#504# / 2);
      lst := ram(8#506# / 2);

      report LF &
         "scenario     = " & mem              & LF &
         "cpu cycles   = " & integer'image(i) & LF &
         "result(500)  = " & oct(res)          & LF &
         "count(502)   = " & oct(cnt) & "  (" & integer'image(to_integer(unsigned(cnt))) & " sectors)" & LF &
         "ticks(504)   = " & oct(tks) & "  (" & integer'image(to_integer(unsigned(tks))) & " clock ints)" & LF &
         "last(506)    = " & oct(lst) & "  (last CS1 seen in poll)";

      if res = x"0001" then
         report mem & ": PASS - every polled sector read completed with the clock preempting" severity note;
      elsif res = x"003f" then
         report mem & ": FAIL - RH raised SC/error (CS1 " & oct(lst) & ")" severity error;
      else
         report mem & ": HANG - poll never saw RDY; " &
                integer'image(to_integer(unsigned(cnt))) & " sectors done, CS1 stuck at " & oct(lst) severity error;
      end if;
      wait;
   end process;

end sim;
