-- tb_rh11_attn.vhd -- GHDL harness for the RH11/RH70 attention-summary fix
--
-- Regression test for commit "rh11: SC reflects ATA; fix ATA clear-on-write
-- semantics" (the RSTS/E V10.1 "hang after 4 devices disabled" fix).
--
-- Drives a minimal Unibus BFM against the real rh11.vhd (have_rh=1,
-- have_rh70=1, RP06), sdspi tied off.  Checks:
--   * after a SEEK completes, drive ATA (DS bit 15) is set
--   * and CS1 bit 15 (SC, Special Condition) is set          <- fix 1
--   * writing RMAS with 0x0000 does NOT clear ATA            <- fix 2
--   * a CS1 poke with GO=0 does NOT clear ATA                <- fix 3
--   * writing RMAS with bit0=1 DOES clear ATA (and SC drops) <- fix 2
--
-- Old behaviour: SC never reflected ATA (stuck 0), and any RMAS write or
-- CS1 poke cleared ATA -- both make this testbench FAIL.
--
-- Run:  sim/run_sim.sh tb_rh11_attn --stop-time=2ms

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_rh11_attn is
end tb_rh11_attn;

architecture sim of tb_rh11_attn is

   signal clk      : std_logic := '0';
   signal nclk     : std_logic;
   signal clk50    : std_logic := '0';
   signal reset    : std_logic := '1';
   signal sim_done : boolean := false;

   signal bus_addr        : std_logic_vector(17 downto 0) := (others => '0');
   signal bus_dato        : std_logic_vector(15 downto 0) := (others => '0');
   signal bus_dati        : std_logic_vector(15 downto 0);
   signal bus_addr_match  : std_logic;
   signal bus_control_dati  : std_logic := '0';
   signal bus_control_dato  : std_logic := '0';
   signal bus_control_datob : std_logic := '0';

   signal br, bg, npr, npg : std_logic := '0';
   signal int_vector : std_logic_vector(8 downto 0);

   signal bm_addr  : std_logic_vector(17 downto 0);
   signal bm_dato  : std_logic_vector(15 downto 0);
   signal bm_cdati, bm_cdato : std_logic;
   signal rh70_bm_addr : std_logic_vector(21 downto 0);
   signal rh70_bm_dato : std_logic_vector(15 downto 0);
   signal rh70_bm_cdati, rh70_bm_cdato : std_logic;

   signal sd_cs, sd_mosi, sd_sclk : std_logic;
   signal sd_dbg : std_logic_vector(3 downto 0);

   -- RP register offsets from base 776700 (bus_addr(5:1))
   constant A_CS1 : std_logic_vector(17 downto 0) := o"776700";
   constant A_DA  : std_logic_vector(17 downto 0) := o"776706";
   constant A_DS  : std_logic_vector(17 downto 0) := o"776712";
   constant A_AS  : std_logic_vector(17 downto 0) := o"776716";
   constant A_DC  : std_logic_vector(17 downto 0) := o"776734";

   -- CS1: bit0 GO, bits5:1 function, bit6 IE
   constant F_SEEK   : std_logic_vector(15 downto 0) := x"0005"; -- fnc "00010" + GO
   constant F_RECAL  : std_logic_vector(15 downto 0) := x"0007"; -- fnc "00011" + GO
   constant CS1_IE   : std_logic_vector(15 downto 0) := x"0040"; -- IE, GO=0

   signal fail_count : integer := 0;

   function oct(v : std_logic_vector) return string is
      variable u : unsigned(v'length + 2 downto 0) := (others => '0');
      variable r : string(1 to (v'length + 2) / 3);
   begin
      u(v'length - 1 downto 0) := unsigned(v);
      for i in r'reverse_range loop
         r(i) := character'val(character'pos('0') + to_integer(u(2 downto 0)));
         u := shift_right(u, 3);
      end loop;
      return r;
   end function;

   procedure tick(n : integer) is
   begin
      for i in 1 to n loop
         wait until clk'event and clk = '1';
      end loop;
   end procedure;

   procedure bus_wr(signal a : out std_logic_vector(17 downto 0);
                    signal d : out std_logic_vector(15 downto 0);
                    signal c : out std_logic;
                    addr : std_logic_vector(17 downto 0);
                    data : std_logic_vector(15 downto 0)) is
   begin
      wait until clk'event and clk = '1';
      a <= addr; d <= data; c <= '1';
      wait until clk'event and clk = '1';
      c <= '0';
      wait until clk'event and clk = '1';
   end procedure;

   procedure bus_rd(signal a : out std_logic_vector(17 downto 0);
                    signal c : out std_logic;
                    addr : std_logic_vector(17 downto 0);
                    result : out std_logic_vector(15 downto 0)) is
   begin
      wait until clk'event and clk = '1';
      a <= addr; c <= '1';
      wait until clk'event and clk = '1';
      wait until clk'event and clk = '1';
      result := bus_dati;
      c <= '0';
      wait until clk'event and clk = '1';
   end procedure;

begin

   clk   <= not clk   after 50 ns when not sim_done else '0';
   nclk  <= not clk;
   clk50 <= not clk50 after 10 ns when not sim_done else '0';
   reset <= '1', '0' after 700 ns;

   dut : entity work.rh11
      port map(
         base_addr => o"776700",
         ivec      => o"254",
         br => br, bg => bg,
         int_vector => int_vector,
         npr => npr, npg => npg,
         bus_addr_match => bus_addr_match,
         bus_addr => bus_addr,
         bus_dati => bus_dati,
         bus_dato => bus_dato,
         bus_control_dati => bus_control_dati,
         bus_control_dato => bus_control_dato,
         bus_control_datob => bus_control_datob,
         bus_master_addr => bm_addr,
         bus_master_dato => bm_dato,
         bus_master_control_dati => bm_cdati,
         bus_master_control_dato => bm_cdato,
         rh70_bus_master_addr => rh70_bm_addr,
         rh70_bus_master_dato => rh70_bm_dato,
         rh70_bus_master_control_dati => rh70_bm_cdati,
         rh70_bus_master_control_dato => rh70_bm_cdato,
         sdcard_cs => sd_cs, sdcard_mosi => sd_mosi, sdcard_sclk => sd_sclk,
         sdcard_miso => '0', sdcard_debug => sd_dbg,
         have_rh => 1, have_rh70 => 1, rh_type => 6,
         reset => reset, clk50mhz => clk50, nclk => nclk, clk => clk
      );

   stim : process
      variable cs1, ds, as : std_logic_vector(15 downto 0);

      procedure check(cond : boolean; msg : string) is
      begin
         if cond then
            report "PASS: " & msg severity note;
         else
            report "FAIL: " & msg severity error;
            fail_count <= fail_count + 1;
         end if;
      end procedure;
   begin
      wait until reset = '0';
      tick(50);

      -- drive should be idle+ready, no attention
      bus_rd(bus_addr, bus_control_dati, A_DS, ds);
      report "DS after reset = " & oct(ds);
      check(ds(15) = '0', "ATA clear after reset");
      check(ds(7)  = '1', "DRY set after reset");
      check(ds(6)  = '1', "VV set after reset");

      bus_rd(bus_addr, bus_control_dati, A_CS1, cs1);
      report "CS1 after reset = " & oct(cs1);
      check(cs1(7)  = '1', "RDY set after reset");
      check(cs1(15) = '0', "SC clear after reset");

      -- ---- issue a SEEK to cylinder 0 ----
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_DC, x"0000");
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_CS1, F_SEEK);
      tick(200);

      bus_rd(bus_addr, bus_control_dati, A_DS, ds);
      report "DS after seek = " & oct(ds);
      check(ds(15) = '1', "ATA set after SEEK completes");

      bus_rd(bus_addr, bus_control_dati, A_CS1, cs1);
      report "CS1 after seek = " & oct(cs1);
      check(cs1(15) = '1', "CS1 bit 15 (SC) reflects ATA          [fix 1]");
      check(cs1(0)  = '0', "GO clear after SEEK completes");

      bus_rd(bus_addr, bus_control_dati, A_AS, as);
      check(as(0) = '1', "RMAS bit 0 reflects drive-0 attention");

      -- ---- RMAS write-0 must NOT clear ATA ----
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_AS, x"0000");
      tick(10);
      bus_rd(bus_addr, bus_control_dati, A_DS, ds);
      check(ds(15) = '1', "ATA survives RMAS write of 0x0000      [fix 2]");

      -- ---- CS1 poke with GO=0 must NOT clear ATA ----
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_CS1, CS1_IE);
      tick(10);
      bus_rd(bus_addr, bus_control_dati, A_DS, ds);
      check(ds(15) = '1', "ATA survives CS1 poke with GO=0        [fix 3]");

      -- ---- RMAS write-1 DOES clear ATA, and SC drops ----
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_AS, x"0001");
      tick(10);
      bus_rd(bus_addr, bus_control_dati, A_DS, ds);
      check(ds(15) = '0', "ATA cleared by RMAS write of 0x0001    [fix 2]");
      bus_rd(bus_addr, bus_control_dati, A_CS1, cs1);
      check(cs1(15) = '0', "SC drops once ATA is cleared          [fix 1]");

      -- ---- a second positioning command still works ----
      bus_wr(bus_addr, bus_dato, bus_control_dato, A_CS1, F_RECAL);
      tick(200);
      bus_rd(bus_addr, bus_control_dati, A_DS, ds);
      check(ds(15) = '1', "ATA set again after RECALIBRATE");

      if fail_count = 0 then
         report "tb_rh11_attn: ALL CHECKS PASSED" severity note;
      else
         report "tb_rh11_attn: " & integer'image(fail_count) & " CHECK(S) FAILED" severity error;
      end if;

      sim_done <= true;
      wait;
   end process;

   guard : process
   begin
      wait for 2 ms;
      assert sim_done report "tb_rh11_attn: TIMEOUT" severity failure;
      std.env.stop;
   end process;

end sim;
