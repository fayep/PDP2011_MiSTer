-- deps: cpuregs.vhd fpuregs.vhd cpu.vhd mmu.vhd mmu_trace_watch.vhd cr.vhd csdr.vhd xubm.vhd xubl.vhd xubrt45.vhd xu.vhd m9312h47.vhd m9312l47.vhd kl11.vhd kw11l.vhd sdspi.vhd rh11.vhd rk11.vhd rl11.vhd tm11.vhd dr11c.vhd mncad.vhd mnckw.vhd mncaa.vhd mncdi.vhd mncdo.vhd brk_compare.vhd unibus.vhd
--
-- EKBEE1 TESTNO 53: CLR (R1) through NR page 5 alias of KIPAR4 must
-- abort and not store (KIPAR4 stays 1000). Dest is DATO-only (rs_dw);
-- gate PAR/PDR/MMR writes on mmu_mmuabort.
-- EKBEE1 TESTNO 55: ACF 1 write aborts (MMR0 bit 13, 020011 not 030011);
-- ACF 1 read sets sticky bit 12 with TENB off; TENB then vector 250.
-- Handler at 20000 so live 6:1 is page 1 (011003). INT REG skip so
-- reading 177572 is not page 7. Freeze is 15:13 only. No 4→1 mux.
--
-- Run: sim/run_sim.sh tb_acf_trap --ieee-asserts=disable --stop-time=2ms

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;

entity tb_acf_trap is
   generic (
      mem    : string  := "tb_acf_trap.mem";
      budget : integer := 200000
   );
end tb_acf_trap;

architecture sim of tb_acf_trap is

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

   signal ram : ram_t := load_mem;

begin

   clk   <= not clk   after 10 ns;
   clk50 <= not clk50 after 10 ns;
   reset <= '1', '0' after 205 ns;

   dut : entity work.unibus
      port map(
         modelcode    => 70,
         have_kl11    => 0,
         have_kw11l   => 0,
         have_rh      => 0,
         have_rk      => 0,
         have_rl      => 0,
         have_tm      => 0,
         init_r7      => x"0200",
         init_psw     => x"00e0",

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

         clk          => clk,
         clk50mhz     => clk50,
         reset        => reset
      );

   addr_match <= '1' when addr(21 downto 18) /= "1111"
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

   process
      variable res : std_logic_vector(15 downto 0);
      variable i : integer := 0;
   begin
      wait until reset = '0';
      loop
         wait until rising_edge(clk);
         i := i + 1;
         res := ram(8#500# / 2);
         exit when cons_run = '0' and i > 100;
         exit when i >= budget;
      end loop;

      res := ram(8#500# / 2);
      report "tb_acf_trap cycles=" & integer'image(i) &
         " result=" & oct(res) &
         " snap=" & oct(ram(8#510# / 2)) &
         " mmr0r=" & oct(ram(8#512# / 2)) &
         " abtsnap=" & oct(ram(8#514# / 2)) &
         " got250=" & oct(ram(8#506# / 2)) &
         " pc=" & oct(dbg_r7) &
         " run=" & std_logic'image(cons_run);
      if res = x"0001" then
         report "tb_acf_trap: PASS";
      else
         report "tb_acf_trap: FAIL result=" & oct(res) severity error;
      end if;
      wait;
   end process;

end sim;
