-- deps: sdspi.vhd rl11.vhd
--
-- tb_rl11_dma.vhd -- does an RL11 READ land the right words at the right
-- memory addresses under the packed-sector addressing?
--
-- Real RL02 sectors are 128 (16-bit) words -- RL02 Technical
-- Description ("16 bit words per sector: 128"; "this track contains 40
-- sectors of 128 words each") -- half of a 512-byte SD block. sd_addr
-- packs two real sectors per SD block (index>>1) instead of every real
-- sector wasting/padding a whole block. This drives the real rl11.vhd
-- with a behavioural sdspi that serves an identifiable pattern -- word
-- K of SD block B = (B+1)*010000 + K -- and checks:
--   * reading real sector 0 (even -> block 0, first half) gets
--     the FIRST 128 words of block 0
--   * reading real sector 1 (odd -> block 0, second half) gets
--     the SECOND 128 words of the SAME block 0 -- not block 1
--   * a single READ spanning sectors 0+1 (256 words, one command)
--     gets both halves correctly and in order
--
-- Uses cylinder 0 / head 0 throughout, matching dnca/dnhs's reset
-- default, so no seek is needed before issuing the read command.
--
-- Run:  sim/run_sim.sh tb_rl11_dma --stop-time=4ms

------------------------------------------------------------------------
-- behavioural sdspi (bound in place of the real one)
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
         sdcard_xfer_out <= std_logic_vector(to_unsigned(
              ((cur_block + 1) * 8#10000#) + sdcard_xfer_addr, 16));
         if reset = '1' then
            busy <= false; cnt <= 0; sdcard_read_done <= '0';
         else
            if not busy then
               sdcard_read_done <= '0';
               if sdcard_read_start = '1' then
                  cur_block <= to_integer(unsigned(sdcard_addr));
                  report "sdspi: read block " & integer'image(to_integer(unsigned(sdcard_addr)));
                  busy <= true; cnt <= 0;
               end if;
            else
               cnt <= cnt + 1;
               if cnt = 20 then
                  sdcard_read_done <= '1';
               end if;
               if cnt >= 20 and sdcard_read_ack = '1' then
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

entity tb_rl11_dma is
end tb_rl11_dma;

architecture sim of tb_rl11_dma is
   signal clk, clk50, reset : std_logic := '0';
   signal sim_done : boolean := false;

   signal bus_addr        : std_logic_vector(17 downto 0) := (others => '0');
   signal bus_dato        : std_logic_vector(15 downto 0) := (others => '0');
   signal bus_dati        : std_logic_vector(15 downto 0);
   signal bus_addr_match  : std_logic;
   signal bus_control_dati, bus_control_dato, bus_control_datob : std_logic := '0';

   signal br, bg, npr, npg : std_logic := '0';
   signal int_vector : std_logic_vector(8 downto 0);

   signal bm_addr  : std_logic_vector(17 downto 0);
   signal bm_dati  : std_logic_vector(15 downto 0) := (others => '0');
   signal bm_dato  : std_logic_vector(15 downto 0);
   signal bm_cdati, bm_cdato : std_logic;
   signal bm_nxm : std_logic := '0';

   signal sd_cs, sd_mosi, sd_sclk : std_logic;
   signal sd_dbg : std_logic_vector(3 downto 0);

   type mem_t is array(0 to 65535) of integer;
   signal mem : mem_t := (others => -1);
   signal wr_count : integer := 0;

   constant A_RLCS : std_logic_vector(17 downto 0) := o"774400";
   constant A_RLBA : std_logic_vector(17 downto 0) := o"774402";
   constant A_RLDA : std_logic_vector(17 downto 0) := o"774404";
   constant A_RLMP : std_logic_vector(17 downto 0) := o"774406";

   constant BA0 : integer := 8#4000#;    -- word address for DMA target

   procedure bus_wr(signal a:out std_logic_vector(17 downto 0);
                    signal d:out std_logic_vector(15 downto 0);
                    signal c:out std_logic;
                    addr:std_logic_vector(17 downto 0);
                    data:std_logic_vector(15 downto 0)) is
   begin
      wait until rising_edge(clk);
      a<=addr; d<=data; c<='1';
      wait until rising_edge(clk);
      c<='0';
      wait until rising_edge(clk);
   end procedure;

   procedure bus_rd(signal a:out std_logic_vector(17 downto 0);
                    signal c:out std_logic;
                    addr:std_logic_vector(17 downto 0);
                    result:out std_logic_vector(15 downto 0)) is
   begin
      wait until rising_edge(clk);
      a<=addr; c<='1';
      wait until rising_edge(clk);
      wait until rising_edge(clk);
      result:=bus_dati;
      c<='0';
      wait until rising_edge(clk);
   end procedure;

begin
   clk   <= not clk   after 50 ns when not sim_done else '0';
   clk50 <= not clk50 after 10 ns when not sim_done else '0';
   reset <= '1', '0' after 700 ns;

   dut : entity work.rl11
      port map(
         base_addr => o"774400", ivec => o"160",
         br=>br, bg=>bg, int_vector=>int_vector, npr=>npr, npg=>npg,
         bus_addr_match=>bus_addr_match, bus_addr=>bus_addr,
         bus_dati=>bus_dati, bus_dato=>bus_dato,
         bus_control_dati=>bus_control_dati, bus_control_dato=>bus_control_dato,
         bus_control_datob=>bus_control_datob,
         bus_master_addr=>bm_addr, bus_master_dati=>bm_dati, bus_master_dato=>bm_dato,
         bus_master_control_dati=>bm_cdati, bus_master_control_dato=>bm_cdato,
         bus_master_nxm=>bm_nxm,
         sdcard_cs=>sd_cs, sdcard_mosi=>sd_mosi, sdcard_sclk=>sd_sclk,
         sdcard_miso=>'0', sdcard_debug=>sd_dbg,
         have_rl=>1, img_mounted=>1,
         reset=>reset, clk50mhz=>clk50, nclk=>clk, clk=>clk
      );

   npg <= npr;

   process(clk)
      variable wa : integer;
   begin
      if rising_edge(clk) then
         if bm_cdato = '1' then
            wa := to_integer(unsigned(bm_addr(16 downto 1)));
            if wa >= 0 and wa <= 65535 then
               mem(wa) <= to_integer(unsigned(bm_dato));
               wr_count <= wr_count + 1;
            end if;
         end if;
      end if;
   end process;

   stim : process
      type scenario_t is record
         sector : integer;
         wc     : integer;
         name   : string(1 to 40);
      end record;
      type scenario_arr is array(0 to 2) of scenario_t;
      constant scenarios : scenario_arr := (
         (0, 128, "even sector 0 -> block 0 first half     "),
         (1, 128, "odd sector 1 -> block 0 second half     "),
         (0, 256, "spanning sectors 0+1 in one command     ")
      );
      variable cs1 : std_logic_vector(15 downto 0);
      variable i, want, got, bad, blk, base, sector, wc : integer;
      variable ok_all : boolean := true;
   begin
      wait until reset = '0';
      for k in 1 to 60 loop wait until rising_edge(clk); end loop;

      for s in scenarios'range loop
         sector := scenarios(s).sector;
         wc     := scenarios(s).wc;

         -- cyl 0, head 0 (matches dnca/dnhs's reset default -- no seek needed)
         bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLDA,
                std_logic_vector(to_unsigned(sector, 16)));
         bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLBA,
                std_logic_vector(to_unsigned(BA0*2, 16)));
         bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLMP,
                std_logic_vector(to_unsigned(8192 - wc, 16)));   -- 13-bit negated word count
         bus_wr(bus_addr, bus_dato, bus_control_dato, A_RLCS, x"000D"); -- ds=00, fc=110 (read), go=1

         i := 0;
         loop
            bus_rd(bus_addr, bus_control_dati, A_RLCS, cs1);
            exit when cs1(7) = '1';
            i := i + 1;
            if i > 3000 then
               report "tb_rl11_dma [" & scenarios(s).name & "]: FAIL - read never completed (RLCS=" &
                  integer'image(to_integer(unsigned(cs1))) & ")" severity failure;
            end if;
         end loop;
         for k in 1 to 20 loop wait until rising_edge(clk); end loop;

         blk  := sector / 2;
         base := (sector mod 2) * 128;
         bad := 0;
         for i in 0 to wc-1 loop
            want := (blk + 1) * 8#10000# + base + i;
            got  := mem(BA0 + i);
            if got /= want then
               bad := bad + 1;
               if bad <= 6 then
                  report "  [" & scenarios(s).name & "] word " & integer'image(i) & " @ " &
                     integer'image(BA0+i) & " : got " & integer'image(got) &
                     " want " & integer'image(want) severity warning;
               end if;
            end if;
         end loop;

         if bad = 0 then
            report "tb_rl11_dma [" & scenarios(s).name & "]: PASS - all " & integer'image(wc) &
                   " words correct" severity note;
         else
            report "tb_rl11_dma [" & scenarios(s).name & "]: FAIL - " & integer'image(bad) & " of " &
                   integer'image(wc) & " words wrong" severity error;
            ok_all := false;
         end if;

         wait until rising_edge(clk);
      end loop;

      if ok_all then
         report "tb_rl11_dma: ALL SCENARIOS PASSED" severity note;
      else
         report "tb_rl11_dma: SOME SCENARIOS FAILED" severity error;
      end if;

      sim_done <= true;
      wait;
   end process;

   guard : process
   begin
      wait for 4 ms;
      assert sim_done report "tb_rl11_dma: TIMEOUT" severity failure;
      std.env.stop;
   end process;
end sim;
