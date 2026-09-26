-- deps: cpuregs.vhd fpuregs.vhd cpu.vhd mmu.vhd mmu_trace_watch.vhd cr.vhd csdr.vhd xubm.vhd xubl.vhd xubrt45.vhd xu.vhd m9312h47.vhd m9312l47.vhd kl11.vhd kw11l.vhd sdspi.vhd rh11.vhd rk11.vhd rl11.vhd tm11.vhd dr11c.vhd mncad.vhd mnckw.vhd mncaa.vhd mncdi.vhd mncdo.vhd brk_compare.vhd unibus.vhd
--
-- tb_xxdp.vhd -- one parameterized GHDL harness for XXDP/MAINDEC abs
-- images.  RAM image is a mac2mem-style .mem (produced by abs2mem.py).
-- No disk: have_rh/rk/rl/tm = 0.  modelcode = 70.  KL11 console is
-- decoded from tx0 (internal CSR writes never appear on the RAM bus).
--
-- Generics (ghdl -gNAME=...):
--   mem            .mem path, relative to sim/
--   init_pc        start R7, integer (default 8#200#)
--   cons_sw        22-bit switch register as integer (default 0)
--   budget         cpu-clock cycles before TIMEOUT
--   pass_match     substring that means PASS (empty = ignore)
--   fail_match     substring that means FAIL (empty = ignore)
--   fail_match2    second FAIL substring
--   uart_bit_cycles  clk50mhz cycles per KL11 bit; 216 at 230400 baud
--
-- Run via sim/run_xxdp.sh so a third MAINDEC is a catalog line, not a
-- new VHDL file.  Direct: sim/run_sim.sh tb_xxdp -gmem=...
--
-- Pass/fail: see sim/xxdp.tab and docs/xxdp-cpu-mem-tb.md.
-- HALT/FAIL/TIMEOUT reports include r0 (MAINDEC test number).

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;

entity tb_xxdp is
   generic (
      mem             : string  := "build/xxdp.mem";
      init_pc         : integer := 8#200#;
      cons_sw         : integer := 0;
      budget          : integer := 30000000;
      pass_match      : string  := "";
      fail_match      : string  := "";
      fail_match2     : string  := "";
      uart_bit_cycles : integer := 216
   );
end tb_xxdp;

architecture sim of tb_xxdp is

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
   signal dbg_r0     : std_logic_vector(15 downto 0);
   signal tx0        : std_logic := '1';

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
         if widx >= 0 and widx <= 65535 then
            m(widx) := std_logic_vector(to_unsigned(d mod 65536, 16));
         end if;
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

   function cons_dump(hay : string; n : integer) return string is
   begin
      if n <= 0 then
         return "(none)";
      end if;
      return hay(1 to n);
   end function;

   function contains(hay : string; n : integer; needle : string) return boolean is
   begin
      if needle'length = 0 then
         return false;
      end if;
      if n < needle'length then
         return false;
      end if;
      for i in 1 to n - needle'length + 1 loop
         if hay(i to i + needle'length - 1) = needle then
            return true;
         end if;
      end loop;
      return false;
   end function;

   signal ram : ram_t := load_mem;

   signal uart_char : std_logic_vector(7 downto 0) := (others => '0');
   signal uart_valid : std_logic := '0';

begin

   clk   <= not clk   after 10 ns;
   clk50 <= not clk50 after 10 ns;
   reset <= '1', '0' after 205 ns;

   dut : entity work.unibus
      port map(
         modelcode    => 70,
         have_kl11    => 1,
         kl0_bps      => 230400,
         have_kw11l   => 1,
         kw11l_hz     => 60,
         have_rh      => 0,
         have_rk      => 0,
         have_rl      => 0,
         have_tm      => 0,
         init_r7      => std_logic_vector(to_unsigned(init_pc, 16)),
         init_psw     => x"00e0",
         cons_sw      => std_logic_vector(to_unsigned(cons_sw, 22)),

         addr         => addr,
         dati         => dati,
         dato         => dato,
         control_dati => control_dati,
         control_dato => control_dato,
         control_datob=> control_datob,
         addr_match   => addr_match,

         cons_run     => cons_run,
         dbg_r7       => dbg_r7,
         dbg_psw      => dbg_psw,
         dbg_ir       => dbg_ir,
         dbg_r0       => dbg_r0,
         tx0          => tx0,
         rx0          => '1',

         clk          => clk,
         clk50mhz     => clk50,
         reset        => reset
      );

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

   -- KL11 UART: idle high, start 0, 8 data LSB first, stop 1.  Sample
   -- in the middle of each bit on clk50mhz (the KL11's baud clock).
   uart_rx : process
      variable acc : std_logic_vector(7 downto 0);
      variable i, b : integer;
   begin
      uart_valid <= '0';
      wait until reset = '0';
      loop
         wait until falling_edge(tx0);
         for i in 1 to (uart_bit_cycles * 3) / 2 loop
            wait until rising_edge(clk50);
         end loop;
         acc := (others => '0');
         for b in 0 to 7 loop
            acc(b) := tx0;
            if b /= 7 then
               for i in 1 to uart_bit_cycles loop
                  wait until rising_edge(clk50);
               end loop;
            end if;
         end loop;
         uart_char <= acc;
         uart_valid <= '1';
         wait until rising_edge(clk);
         wait until rising_edge(clk);
         wait until rising_edge(clk);
         wait until rising_edge(clk);
         uart_valid <= '0';
      end loop;
   end process;

   score : process
      variable cons : string(1 to 512) := (others => ' ');
      variable ncons : integer := 0;
      variable i : integer := 0;
      variable saw_run : boolean := false;
      variable uart_seen : std_logic := '0';
      variable ch : character;
      variable done : boolean := false;
   begin
      wait until reset = '0';
      loop
         wait until rising_edge(clk);
         i := i + 1;

         if uart_valid = '1' and uart_seen = '0' then
            uart_seen := '1';
            ch := character'val(to_integer(unsigned(uart_char)));
            if ncons < cons'length then
               ncons := ncons + 1;
               cons(ncons) := ch;
            else
               cons(1 to cons'length - 1) := cons(2 to cons'length);
               cons(cons'length) := ch;
            end if;
            if ch = character'val(13) or ch = character'val(10) then
               report "KL11: " & cons_dump(cons, ncons);
            end if;
            if contains(cons, ncons, pass_match) then
               report "tb_xxdp PASS mem=" & mem & " cycles=" & integer'image(i)
                  & " console=" & cons_dump(cons, ncons) severity note;
               done := true;
               exit;
            end if;
            if contains(cons, ncons, fail_match)
               or contains(cons, ncons, fail_match2) then
               report "tb_xxdp FAIL mem=" & mem & " cycles=" & integer'image(i)
                  & " pc=" & oct(dbg_r7) & " ir=" & oct(dbg_ir)
                  & " r0=" & oct(dbg_r0)
                  & " console=" & cons_dump(cons, ncons) severity error;
               done := true;
               exit;
            end if;
         elsif uart_valid = '0' then
            uart_seen := '0';
         end if;

         if cons_run = '1' then
            saw_run := true;
         elsif saw_run and cons_run = '0' then
            report "tb_xxdp HALT mem=" & mem & " cycles=" & integer'image(i)
               & " pc=" & oct(dbg_r7) & " ir=" & oct(dbg_ir)
               & " psw=" & oct(dbg_psw) & " r0=" & oct(dbg_r0)
               & " console=" & cons_dump(cons, ncons) severity error;
            done := true;
            exit;
         end if;

         exit when i >= budget;
      end loop;

      if not done then
         report "tb_xxdp TIMEOUT mem=" & mem & " cycles=" & integer'image(i)
            & " pc=" & oct(dbg_r7) & " ir=" & oct(dbg_ir)
            & " r0=" & oct(dbg_r0)
            & " console=" & cons_dump(cons, ncons) severity error;
      end if;
      wait;
   end process;

end sim;
