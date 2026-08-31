--
-- tb_xubl_race.vhd -- reproduces getfr's real firing pattern (roms/
-- xubrt45.mac: "jsr pc,xubl" to fill xu's local buf via RRXDATA, then
-- IMMEDIATELY, no completion wait, trigger a busmaster DMA of that same
-- buf out to real host memory) against the REAL, unmodified xubl.vhd and
-- xubm.vhd, replicating xu.vhd's own exact local-bus priority mux
-- (localunibus_busmaster_* <= ...xubl... when cpu_npg='1' and
-- xubl_npr='1' else ...xubm...) and shared grant (cpu_npr <= xubl_npr or
-- xubm_npr). FIX constant selects the buggy (localbus_npg <= cpu_npg) vs
-- fixed (localbus_npg <= cpu_npg and not xubl_npr) wiring -- see
-- rtl/xu.vhd's xubm0 instantiation, 2026-08-29.
--
-- "Local unibus memory" is modeled directly as a RAM array standing in
-- for the nested unibus.vhd instance xu.vhd's own embedded CPU actually
-- runs on -- xubl0/xubm0 only need a plain busmaster memory port, not the
-- CPU itself, to exercise this specific arbitration race.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;
use IEEE.STD_LOGIC_TEXTIO.ALL;
use STD.TEXTIO.ALL;

entity tb_xubl_race is
end tb_xubl_race;

architecture sim of tb_xubl_race is

   constant FIX : boolean := true;  -- flip to false to reproduce the bug

   signal cpuclk : std_logic := '0';
   signal nclk : std_logic;
   signal reset : std_logic := '1';
   signal sim_done : boolean := false;

   -- xubl0's own regular-bus register interface
   constant XUBL_BASE : std_logic_vector(17 downto 0) := "000000000000010000";
   signal xubl_addr : std_logic_vector(17 downto 0) := (others => '0');
   signal xubl_dato_reg : std_logic_vector(15 downto 0) := (others => '0');
   signal xubl_ctl_dato : std_logic := '0';

   -- xubm0's own regular-bus register interface
   constant XUBM_BASE : std_logic_vector(17 downto 0) := "000000000000100000";
   signal xubm_addr : std_logic_vector(17 downto 0) := (others => '0');
   signal xubm_dato_reg : std_logic_vector(15 downto 0) := (others => '0');
   signal xubm_ctl_dato : std_logic := '0';
   signal xubm_ctl_datob : std_logic := '0';

   -- SPI pins (xubl0 <-> fake chip, direct testbench drive, no real shim
   -- needed -- this test is about bus arbitration, not SPI decode)
   signal xu_cs, xu_mosi, xu_sclk, xu_miso : std_logic := '0';

   -- xubl0's local-bus-master signals (into the shared local RAM, via the
   -- same priority mux xu.vhd itself implements)
   signal xubl_npr : std_logic;
   signal xubl_localbus_npg : std_logic := '0';
   signal xubl_bm_addr : std_logic_vector(17 downto 0);
   signal xubl_bm_dato : std_logic_vector(15 downto 0);
   signal xubl_bm_ctl_dati : std_logic;
   signal xubl_bm_ctl_dato : std_logic;

   -- xubm0's OUTER (real-host-facing) busmaster signals
   signal xubm_outer_npr, xubm_outer_npg : std_logic := '0';
   signal xubm_outer_addr : std_logic_vector(17 downto 0);
   signal xubm_outer_dati : std_logic_vector(15 downto 0) := (others => '0');
   signal xubm_outer_dato : std_logic_vector(15 downto 0);
   signal xubm_outer_ctl_dati : std_logic;
   signal xubm_outer_ctl_dato : std_logic;

   -- xubm0's INNER (local-bus-facing) busmaster signals
   signal xubm_npr : std_logic;
   signal xubm_inner_addr : std_logic_vector(17 downto 0);
   signal xubm_inner_dato : std_logic_vector(15 downto 0);
   signal xubm_inner_ctl_dati : std_logic;
   signal xubm_inner_ctl_dato : std_logic;
   signal xubm_localbus_npg : std_logic := '0';

   -- shared local-bus grant, matching xu.vhd's cpu_npr/cpu_npg exactly
   signal cpu_npr, cpu_npg : std_logic := '0';

   type local_bus_owner_type is (owner_none, owner_xubl, owner_xubm);
   signal local_bus_owner : local_bus_owner_type := owner_none;

   -- muxed local-bus signals actually reaching "local unibus memory"
   signal local_mux_addr : std_logic_vector(17 downto 0);
   signal local_mux_dato : std_logic_vector(15 downto 0);
   signal local_mux_ctl_dati : std_logic;
   signal local_mux_ctl_dato : std_logic;
   signal local_mux_dati : std_logic_vector(15 downto 0);

   -- "local unibus memory" (xu's own buf/rdre RAM) and "host memory" --
   -- 64 words each is plenty
   type ram_type is array(0 to 63) of std_logic_vector(15 downto 0);
   signal local_ram : ram_type := (others => (others => '0'));
   -- preloaded with a known pattern at word addr 20 (matching xmitld's
   -- real usage: xubm0 copies a host packet buffer into local buf) --
   -- backdoor init, no testbench-side write process needed.
   signal host_ram : ram_type := (
      20 => x"1111", 21 => x"2222", 22 => x"3333", 23 => x"4444",
      24 => x"5555", 25 => x"6666", 26 => x"7777", 27 => x"8888",
      others => (others => '0'));

   procedure prog_write(addr_bits : in std_logic_vector(2 downto 0);
                         base : in std_logic_vector(17 downto 0);
                         data : in std_logic_vector(15 downto 0);
                         signal a : out std_logic_vector(17 downto 0);
                         signal d : out std_logic_vector(15 downto 0);
                         signal ctl : out std_logic;
                         signal clk : in std_logic) is
   begin
      a <= base(17 downto 4) & addr_bits & '0';
      d <= data;
      wait until clk'event and clk = '1';
      ctl <= '1';
      wait until clk'event and clk = '1';
      ctl <= '0';
   end procedure;

   -- xubm.vhd's own register selector is 2 bits (bus_addr(2 downto 1)),
   -- one narrower than xubl's 3-bit one -- separate procedure.
   procedure prog_write2(addr_bits : in std_logic_vector(1 downto 0);
                          base : in std_logic_vector(17 downto 0);
                          data : in std_logic_vector(15 downto 0);
                          signal a : out std_logic_vector(17 downto 0);
                          signal d : out std_logic_vector(15 downto 0);
                          signal ctl : out std_logic;
                          signal clk : in std_logic) is
   begin
      a <= base(17 downto 3) & addr_bits & '0';
      d <= data;
      wait until clk'event and clk = '1';
      ctl <= '1';
      wait until clk'event and clk = '1';
      ctl <= '0';
   end procedure;

begin

   process(cpuclk)
      variable l : line;
   begin
      if cpuclk'event and cpuclk = '1' and not sim_done then
         write(l, string'("t="));
         write(l, now);
         write(l, string'(" xubl_npr=")); write(l, std_logic'image(xubl_npr));
         write(l, string'(" xubm_npr=")); write(l, std_logic'image(xubm_npr));
         write(l, string'(" cpu_npg=")); write(l, std_logic'image(cpu_npg));
         write(l, string'(" outer_npg=")); write(l, std_logic'image(xubm_outer_npg));
         write(l, string'(" local_wr=")); write(l, std_logic'image(local_mux_ctl_dato));
         write(l, string'(" outer_wr=")); write(l, std_logic'image(xubm_outer_ctl_dato));
         writeline(output, l);
      end if;
   end process;

   process(cpuclk)
      variable l : line;
   begin
      if cpuclk'event and cpuclk = '1' and not sim_done then
         write(l, string'("t="));
         write(l, now);
         write(l, string'(" xubl_npr=")); write(l, std_logic'image(xubl_npr));
         write(l, string'(" xubm_npr=")); write(l, std_logic'image(xubm_npr));
         write(l, string'(" cpu_npg=")); write(l, std_logic'image(cpu_npg));
         write(l, string'(" owner=")); write(l, local_bus_owner_type'image(local_bus_owner));
         write(l, string'(" local_wr=")); write(l, std_logic'image(local_mux_ctl_dato));
         writeline(output, l);
      end if;
   end process;

   cpuclk <= not cpuclk after 50 ns when not sim_done else '0';  -- 10MHz
   nclk <= not cpuclk;
   reset <= '1', '0' after 500 ns;

   ----------------------------------------------------------------------
   -- xubl0: real, unmodified. rt/rl point at local_ram (via the "local
   -- bus" side, exactly xu.vhd's wiring: xubl0's bus_master_* IS the
   -- local-bus side -- xubl only ever DMAs to/from xu's own local
   -- memory, never the real host bus directly).
   ----------------------------------------------------------------------
   xubl0: entity work.xubl
   port map(
      base_addr => XUBL_BASE,
      npr => xubl_npr,
      npg => xubl_localbus_npg,
      bus_addr_match => open,
      bus_addr => xubl_addr,
      bus_dati => open,
      bus_dato => xubl_dato_reg,
      bus_control_dati => '0',
      bus_control_dato => xubl_ctl_dato,
      bus_control_datob => '0',
      bus_master_addr => xubl_bm_addr,
      bus_master_dati => local_mux_dati,
      bus_master_dato => xubl_bm_dato,
      bus_master_control_dati => xubl_bm_ctl_dati,
      bus_master_control_dato => xubl_bm_ctl_dato,
      bus_master_nxm => '0',
      xu_cs => xu_cs,
      xu_mosi => xu_mosi,
      xu_sclk => xu_sclk,
      xu_miso => xu_miso,
      reset => reset,
      xublclk => cpuclk,
      clk => nclk
   );

   -- Real latched arbiter, matching rtl/xu.vhd exactly (the two
   -- independent "and not <other's raw npr>" masks this test originally
   -- used to prove the fix deadlocked once applied symmetrically -- see
   -- xu.vhd's local_bus_owner_type declaration comment for the full
   -- history). FIX=false reproduces the ORIGINAL bug this test targets
   -- (xubl unmasked, free to barge in); FIX=true is the real fix.
   process(nclk, reset)
   begin
      if reset = '1' then
         local_bus_owner <= owner_none;
      elsif nclk = '1' and nclk'event then
         case local_bus_owner is
            when owner_none =>
               if xubl_npr = '1' then
                  local_bus_owner <= owner_xubl;
               elsif xubm_npr = '1' then
                  local_bus_owner <= owner_xubm;
               end if;
            when owner_xubl =>
               if xubl_npr = '0' then
                  local_bus_owner <= owner_none;
               end if;
            when owner_xubm =>
               if xubm_npr = '0' then
                  local_bus_owner <= owner_none;
               end if;
         end case;
      end if;
   end process;

   process(cpu_npg, local_bus_owner)
   begin
      if FIX then
         if local_bus_owner = owner_xubl then
            xubl_localbus_npg <= cpu_npg;
         else
            xubl_localbus_npg <= '0';
         end if;
      else
         xubl_localbus_npg <= cpu_npg;
      end if;
   end process;
   xubm_localbus_npg <= cpu_npg when local_bus_owner = owner_xubm else '0';

   xubm0: entity work.xubm
   port map(
      base_addr => XUBM_BASE,
      bus_addr_match => open,
      bus_addr => xubm_addr,
      bus_dati => open,
      bus_dato => xubm_dato_reg,
      bus_control_dati => '0',
      bus_control_dato => xubm_ctl_dato,
      bus_control_datob => xubm_ctl_datob,
      npr => xubm_outer_npr,
      npg => xubm_outer_npg,
      bus_master_addr => xubm_outer_addr,
      bus_master_dati => xubm_outer_dati,
      bus_master_dato => xubm_outer_dato,
      bus_master_control_dati => xubm_outer_ctl_dati,
      bus_master_control_dato => xubm_outer_ctl_dato,
      bus_master_nxm => '0',
      localbus_npr => xubm_npr,
      localbus_npg => xubm_localbus_npg,
      localbus_master_addr => xubm_inner_addr,
      localbus_master_dati => local_mux_dati,
      localbus_master_dato => xubm_inner_dato,
      localbus_master_control_dati => xubm_inner_ctl_dati,
      localbus_master_control_dato => xubm_inner_ctl_dato,
      localbus_master_nxm => '0',
      reset => reset,
      xubmclk => cpuclk,
      clk => nclk
   );

   -- outer (real-host-facing) grant: always available immediately, no
   -- other master contending -- irrelevant to the bug under test.
   process(cpuclk)
   begin
      if cpuclk'event and cpuclk = '1' then
         xubm_outer_npg <= xubm_outer_npr;
      end if;
   end process;

   -- shared local-bus grant, matching xu.vhd's cpu_npr/cpu_npg exactly:
   -- cpu_npr <= xubl_npr or xubm_npr; a real DMA-grant arbiter holds the
   -- grant for as long as npr stays asserted.
   cpu_npr <= xubl_npr or xubm_npr;
   process(cpuclk)
   begin
      if cpuclk'event and cpuclk = '1' then
         cpu_npg <= cpu_npr;
      end if;
   end process;

   -- xu.vhd's own mux, updated to route on the latched local_bus_owner
   -- arbiter (see xu.vhd's own comment at this mux -- the raw-priority
   -- version was the actual remaining bug this test caught: xubm0's data
   -- movement is gated on its OWN outer npg, not localbus_npg, so a mux
   -- still keyed on raw npr would swap to xubl mid-transfer regardless
   -- of the grant fix).
   local_mux_addr <= xubl_bm_addr when local_bus_owner = owner_xubl
      else xubm_inner_addr when local_bus_owner = owner_xubm
      else (others => '0');
   local_mux_dato <= xubl_bm_dato when local_bus_owner = owner_xubl
      else xubm_inner_dato when local_bus_owner = owner_xubm
      else (others => '0');
   local_mux_ctl_dati <= xubl_bm_ctl_dati when local_bus_owner = owner_xubl
      else xubm_inner_ctl_dati when local_bus_owner = owner_xubm
      else '0';
   local_mux_ctl_dato <= xubl_bm_ctl_dato when local_bus_owner = owner_xubl
      else xubm_inner_ctl_dato when local_bus_owner = owner_xubm
      else '0';

   -- "local unibus memory" -- combinational read (matches xubl.vhd's own
   -- back-to-back word-fetch assumption), registered write.
   local_mux_dati <= local_ram(conv_integer(local_mux_addr(6 downto 1)));
   process(cpuclk)
   begin
      if cpuclk'event and cpuclk = '1' then
         if local_mux_ctl_dato = '1' then
            local_ram(conv_integer(local_mux_addr(6 downto 1))) <= local_mux_dato;
         end if;
      end if;
   end process;

   -- "host memory" (xubm0's OUTER bus_master_* side)
   xubm_outer_dati <= host_ram(conv_integer(xubm_outer_addr(6 downto 1)));
   process(cpuclk)
   begin
      if cpuclk'event and cpuclk = '1' then
         if xubm_outer_ctl_dato = '1' then
            host_ram(conv_integer(xubm_outer_addr(6 downto 1))) <= xubm_outer_dato;
         end if;
      end if;
   end process;

   -- fake SPI chip: on CS falling edge, start shifting out a fixed 8-word
   -- test pattern (0x1111, 0x2222, ..., 0x8888), MSB-first per byte,
   -- matching Mode 0,0 (same convention as the real shim -- but here just
   -- a dumb pattern generator, since this test is about bus arbitration,
   -- not SPI decode correctness).
   process(cpuclk)
      variable pattern : ram_type := (
         0 => x"1111", 1 => x"2222", 2 => x"3333", 3 => x"4444",
         4 => x"5555", 5 => x"6666", 6 => x"7777", 7 => x"8888",
         others => (others => '0'));
      variable byte_idx : integer := 0;
      variable bit_idx : integer := 7;
      variable cur_byte : std_logic_vector(7 downto 0);
   begin
      if cpuclk'event and cpuclk = '1' then
         if xu_cs = '1' then
            byte_idx := 0;
            bit_idx := 7;
         else
            cur_byte := pattern(byte_idx / 2)(7 downto 0) when (byte_idx mod 2) = 0
                        else pattern(byte_idx / 2)(15 downto 8);
            xu_miso <= cur_byte(bit_idx);
            if bit_idx = 0 then
               bit_idx := 7;
               byte_idx := byte_idx + 1;
            else
               bit_idx := bit_idx - 1;
            end if;
         end if;
      end if;
   end process;

   ----------------------------------------------------------------------
   -- main test sequence: xmitld's real pattern -- trigger xubm0 to DMA
   -- 8 words from host_ram (word addr 20, a "host packet buffer") into
   -- local_ram (word addr 0, xu's own "buf"), then IMMEDIATELY (no
   -- completion wait, matching xmitld's own real firmware timing) trigger
   -- xubl0 to start an unrelated xmit-only SPI transfer reading from a
   -- different local_ram address -- exactly the scenario that would let
   -- xubl barge in via the mux's unconditional priority and interrupt
   -- xubm0's still-in-flight host->local copy.
   ----------------------------------------------------------------------
   process
      variable l : line;
      variable ok : boolean;
   begin
      wait until reset = '0';
      wait for 500 ns;

      -- xubm0: bm (host source) = word addr 20, xu (local dest) = word
      -- addr 0, dr=0 (host -> local), ln=16 (8 words after the /2
      -- internal scaling, see xubm.vhd's cmd_wait: ln<=xubm_ln(7:1)).
      prog_write2("00", XUBM_BASE, x"0028", xubm_addr, xubm_dato_reg, xubm_ctl_dato, nclk);  -- bm lo = word addr 20 (byte 40)
      prog_write2("01", XUBM_BASE, x"0000", xubm_addr, xubm_dato_reg, xubm_ctl_dato, nclk);  -- bm hi = 0
      prog_write2("10", XUBM_BASE, x"0000", xubm_addr, xubm_dato_reg, xubm_ctl_dato, nclk);  -- xu (local dst) = word addr 0
      xubm_ctl_datob <= '0';
      prog_write2("11", XUBM_BASE, x"0010", xubm_addr, xubm_dato_reg, xubm_ctl_dato, nclk);  -- dr=0, ln=16 (8 words), TRIGGERS run

      -- xmitld's real pattern: IMMEDIATELY (same handful of cycles real
      -- firmware takes between the busmaster trigger and the following
      -- xubl WGPDATA call) trigger xubl -- unrelated xmit-only transfer,
      -- reading from local_ram word addr 30 (well clear of the region
      -- xubm0 is still writing), rl=0 (no receive phase).
      prog_write("000", XUBL_BASE, x"003C", xubl_addr, xubl_dato_reg, xubl_ctl_dato, nclk);  -- xf = word addr 30 (byte 60)
      prog_write("010", XUBL_BASE, x"0000", xubl_addr, xubl_dato_reg, xubl_ctl_dato, nclk);  -- rt = 0 (unused)
      prog_write("011", XUBL_BASE, x"0000", xubl_addr, xubl_dato_reg, xubl_ctl_dato, nclk);  -- rl = 0 (no recv)
      prog_write("001", XUBL_BASE, x"0010", xubl_addr, xubl_dato_reg, xubl_ctl_dato, nclk);  -- xl = 16 bits, TRIGGERS run

      -- let both engines fully finish
      wait for 30000 ns;

      write(l, string'("local_ram(0..7) after race (should match host_ram(20..27)): "));
      for i in 0 to 7 loop
         hwrite(l, local_ram(i));
         write(l, string'(" "));
      end loop;
      writeline(output, l);

      ok := true;
      for i in 0 to 7 loop
         if local_ram(i) /= host_ram(20 + i) then
            ok := false;
         end if;
      end loop;

      if ok then
         write(l, string'("PASS xubl-race local_ram matches host_ram (FIX="));
      else
         write(l, string'("FAIL xubl-race local_ram does NOT match host_ram -- xubl barged in and corrupted xubm's in-flight DMA (FIX="));
      end if;
      write(l, boolean'image(FIX));
      write(l, string'(")"));
      writeline(output, l);

      wait for 500 ns;
      sim_done <= true;
      wait;
   end process;

end sim;
