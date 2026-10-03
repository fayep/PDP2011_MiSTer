-- deps: cpuregs.vhd fpuregs.vhd cpu.vhd mmu.vhd cr.vhd csdr.vhd xubm.vhd xubl.vhd xu.vhd kl11.vhd kw11l.vhd mister_blkdev.vhd rh11.vhd rk11.vhd rl11.vhd tm11.vhd dr11c.vhd mncad.vhd mnckw.vhd mncaa.vhd mncdi.vhd mncdo.vhd unibus.vhd
--
-- tb_rsts101_init.vhd -- the whole unibus (cpu, mmu, rh70 on mister_blkdev,
-- kw11l, kl11) resumed from a SIMH snapshot of RSTS/E V10.1 INIT, to see
-- what the core does on its way to "Starting SYSGEN.SIL" (where the
-- MiSTer took "Unexpected trap through the vector at 000010",
-- PC=113250 PS=034350).
--
-- Inputs (made by fable/sim/mkinputs.py from the SIMH snapshot):
--   memfile  : "<word index> <value>"  physical memory at the snapshot
--   stubfile : "<word index> <value>"  a stub at 117000 that loads both
--              register sets, KSP, the kernel PARs/PDRs, MMR3, MMR0, PSW
--              and jumps to the snapshot PC; served from a ROM overlay
--              until the first instruction fetch outside it
--   diskfile : "<lbn> w0..w255"        the RP06 blocks INIT reads
--
-- Memory: 0..16777777 like mister_top's dram_match, read data registered
-- on the falling cpu clock edge (as dram_c12 captures it), writes on the
-- falling edge (as dram_c8 issues them).  hps_io: behavioural disk slot
-- for the RH, with a configurable request latency.
--
-- Reports: console output, every write to the watched word, the
-- instruction word fetched there, the first CPU read of vector 10/4.
--
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;
use STD.TEXTIO.ALL;

entity tb_rsts101_init is
   generic (
      memfile   : string  := "p_mem.txt";
      stubfile  : string  := "p_stub.txt";
      diskfile  : string  := "p_disk.txt";
      pclog     : string  := "";              -- if set, every ifetch "time pa word" goes here
      stub_pc   : integer := 8#117000#;
      watch_pa  : integer := 8#113246#;      -- physical word to watch
      hps_lat   : integer := 30000;          -- clk_sd cycles from sd_rd to sd_ack (10 ns each)
      hps_gap   : integer := 3;              -- clk_sd cycles between buffer words
      stop_ms   : integer := 4000;           -- hard time limit
      clk50_half_ns : integer := 10;         -- clk50mhz half period; slower + kw_hz 800 = faster sim
      clk_sd_half_ns : integer := 5;         -- hps_io clock half period
      kw_hz     : integer := 60;
      kl_bps    : integer := 19200
   );
end tb_rsts101_init;

architecture sim of tb_rsts101_init is

   constant MEMW : integer := 2 * 1024 * 1024 - 64 * 1024;       -- words below 17000000 (dram_match)
   type ram_t is array(0 to MEMW - 1) of natural range 0 to 65535;
   type stub_t is array(0 to 255) of natural range 0 to 65535;
   constant NBLK : integer := 1024;
   type blk_t is array(0 to 255) of natural range 0 to 65535;
   type img_t is array(0 to NBLK - 1) of blk_t;
   type lbns_t is array(0 to NBLK - 1) of integer;

   shared variable ram : ram_t;
   shared variable stub : stub_t;
   shared variable img : img_t;
   shared variable lbns : lbns_t;
   shared variable nimg : integer := 0;

   signal loaded     : boolean := false;
   signal clk        : std_logic := '0';
   signal clk50      : std_logic := '0';
   signal clk_sd     : std_logic := '0';
   signal reset      : std_logic := '1';

   signal addr       : std_logic_vector(21 downto 0);
   signal dati       : std_logic_vector(15 downto 0) := (others => '0');
   signal dato       : std_logic_vector(15 downto 0);
   signal control_dati  : std_logic;
   signal control_dato  : std_logic;
   signal control_datob : std_logic;
   signal addr_match : std_logic;
   signal ifetch     : std_logic;
   signal cons_pause : std_logic;
   signal cpu_addr_v : std_logic_vector(15 downto 0);

   signal rh_sd_lba  : std_logic_vector(31 downto 0);
   signal rh_sd_rd, rh_sd_wr : std_logic;
   signal rh_sd_ack  : std_logic := '0';
   signal rh_sd_buff_din : std_logic_vector(15 downto 0);
   signal sd_buff_addr : std_logic_vector(7 downto 0) := (others => '0');
   signal sd_buff_dout : std_logic_vector(15 downto 0) := (others => '0');
   signal sd_buff_wr : std_logic := '0';

   signal stub_active : boolean := true;
   signal done : boolean := false;

   function oct(v : natural; n : integer := 6) return string is
      variable r : string(1 to n);
      variable x : natural := v;
   begin
      for i in n downto 1 loop
         r(i) := character'val(character'pos('0') + (x mod 8));
         x := x / 8;
      end loop;
      return r;
   end function;

   function u(v : std_logic_vector) return natural is
   begin
      return to_integer(unsigned(v));
   end function;

begin

   clk    <= not clk    after 70 ns when not done;      -- cpuclk 140 ns, as on the MiSTer
   clk50  <= not clk50  after clk50_half_ns * 1 ns when not done;
   clk_sd <= not clk_sd after clk_sd_half_ns * 1 ns when not done;

   load : process
      file fh : text;
      variable st : file_open_status;
      variable ln : line;
      variable a, d, n : integer;
      variable good : boolean;
   begin
      for i in 0 to MEMW - 1 loop ram(i) := 0; end loop;
      file_open(st, fh, memfile, read_mode);
      assert st = open_ok report "cannot open " & memfile severity failure;
      while not endfile(fh) loop
         readline(fh, ln); read(ln, a, good); next when not good; read(ln, d); ram(a) := d;
      end loop;
      file_close(fh);
      file_open(st, fh, stubfile, read_mode);
      assert st = open_ok report "cannot open " & stubfile severity failure;
      while not endfile(fh) loop
         readline(fh, ln); read(ln, a, good); next when not good; read(ln, d);
         stub(a - stub_pc / 2) := d;
      end loop;
      file_close(fh);
      file_open(st, fh, diskfile, read_mode);
      assert st = open_ok report "cannot open " & diskfile severity failure;
      n := 0;
      while not endfile(fh) loop
         readline(fh, ln); read(ln, a, good); next when not good;
         lbns(n) := a;
         for w in 0 to 255 loop read(ln, d); img(n)(w) := d; end loop;
         n := n + 1;
      end loop;
      file_close(fh);
      nimg := n;
      report "loaded memory, stub, " & integer'image(n) & " disk blocks";
      loaded <= true;
      wait;
   end process;

   process
   begin
      wait until loaded;
      for i in 1 to 20 loop wait until rising_edge(clk); end loop;
      reset <= '0';
      wait;
   end process;

   dut : entity work.unibus
      port map(
         modelcode    => 70,
         have_kl11    => 4,
         kl0_bps      => kl_bps,
         kl0_rtscts   => 0,
         kl1_bps      => 19200,
         kl2_bps      => 9600,
         kl3_bps      => 9600,
         have_kw11l   => 1,
         kw11l_hz     => kw_hz,
         have_rh      => 1,
         rh_type      => 6,
         rh_img_mounted => 1,
         rh_sd_lba    => rh_sd_lba,
         rh_sd_rd     => rh_sd_rd,
         rh_sd_wr     => rh_sd_wr,
         rh_sd_ack    => rh_sd_ack,
         rh_sd_buff_din => rh_sd_buff_din,
         sd_buff_addr => sd_buff_addr,
         sd_buff_dout => sd_buff_dout,
         sd_buff_wr   => sd_buff_wr,
         clk_sd       => clk_sd,
         have_rk      => 1,
         rk_img_mounted => 0,
         have_rl      => 1,
         rl_img_mounted => 0,
         have_tm      => 1,
         tm_img_mounted => 0,
         have_xu      => 0,
         init_r7      => std_logic_vector(to_unsigned(stub_pc, 16)),
         init_psw     => x"00e0",

         addr         => addr,
         dati         => dati,
         dato         => dato,
         control_dati => control_dati,
         control_dato => control_dato,
         control_datob=> control_datob,
         addr_match   => addr_match,
         ifetch       => ifetch,
         cpu_addr_v   => cpu_addr_v,
         cons_pause   => cons_pause,

         clk          => clk,
         clk50mhz     => clk50,
         reset        => reset
      );

   addr_match <= '1' when addr(21 downto 18) /= "1111" else '0';

   -- memory: like mister_top, the cycle's address/control are acted on in the
   -- second half of the cpu clock (write at dram_c8, read data captured at
   -- dram_c12), i.e. by the falling edge here
   mem : process(clk)
      variable wa : integer;
      variable v : natural;
      variable pa : integer;
   begin
      if falling_edge(clk) and reset = '0' then
         pa := u(addr);
         wa := pa / 2;
         if addr_match = '1' and control_dati = '1' then
            if stub_active and pa >= stub_pc and pa < stub_pc + 512 then
               dati <= std_logic_vector(to_unsigned(stub(wa - stub_pc / 2), 16));
            else
               dati <= std_logic_vector(to_unsigned(ram(wa), 16));
            end if;
         end if;
         if addr_match = '1' and control_dato = '1' then
            v := ram(wa);
            if control_datob = '0' then
               v := u(dato);
            elsif addr(0) = '0' then
               v := (v / 256) * 256 + (u(dato) mod 256);
            else
               v := (u(dato) / 256) * 256 + (v mod 256);
            end if;
            if wa = watch_pa / 2 then
               report "WRITE watched " & oct(watch_pa) & " <= " & oct(v) & " (was " & oct(ram(wa)) &
                  ") byte=" & std_logic'image(control_datob) & " dma=" & std_logic'image(cons_pause) &
                  " cpu_va=" & oct(u(cpu_addr_v));
            end if;
            ram(wa) := v;
         end if;
      end if;
   end process;

   -- behavioural hps_io slot for the RH
   hps : process
      variable blk, idx : integer;
      variable is_wr : boolean;
      variable nrd, nwr : integer := 0;
   begin
      wait until loaded;
      loop
         wait until rising_edge(clk_sd);
         if rh_sd_rd = '1' or rh_sd_wr = '1' then
            blk := u(rh_sd_lba);
            is_wr := rh_sd_wr = '1';
            idx := -1;
            for i in 0 to nimg - 1 loop
               if lbns(i) = blk then idx := i; end if;
            end loop;
            for i in 1 to hps_lat loop wait until rising_edge(clk_sd); end loop;
            sd_buff_addr <= (others => '0');
            rh_sd_ack <= '1';
            wait until rising_edge(clk_sd);
            wait until rising_edge(clk_sd);
            if not is_wr then
               nrd := nrd + 1;
               if idx < 0 then
                  report "HPS read of block " & integer'image(blk) & " not in the image subset" severity warning;
               end if;
               for w in 0 to 255 loop
                  sd_buff_addr <= std_logic_vector(to_unsigned(w, 8));
                  if idx >= 0 then
                     sd_buff_dout <= std_logic_vector(to_unsigned(img(idx)(w), 16));
                  else
                     sd_buff_dout <= (others => '0');
                  end if;
                  sd_buff_wr <= '1';
                  wait until rising_edge(clk_sd);
                  sd_buff_wr <= '0';
                  for g in 1 to hps_gap loop wait until rising_edge(clk_sd); end loop;
               end loop;
            else
               nwr := nwr + 1;
               report "HPS write of block " & integer'image(blk);
               for w in 0 to 255 loop
                  sd_buff_addr <= std_logic_vector(to_unsigned(w, 8));
                  for g in 1 to hps_gap + 1 loop wait until rising_edge(clk_sd); end loop;
                  if idx >= 0 then img(idx)(w) := u(rh_sd_buff_din); end if;
               end loop;
            end if;
            rh_sd_ack <= '0';
            wait until rising_edge(clk_sd);
         end if;
      end loop;
   end process;

   -- watchers (rising edge: the CPU latches the registered dati here)
   watch : process(clk)
      file pf : text;
      variable ln : line;
      variable opened : boolean := false;
      variable pa : integer;
      variable con : line;
      variable nfetch : natural := 0;
      variable vec_seen : boolean := false;
   begin
      if rising_edge(clk) and reset = '0' then
         if pclog'length > 0 and not opened then
            file_open(pf, pclog, write_mode); opened := true;
         end if;
         -- ifetch is high in the decode cycle: the instruction word is in dati,
         -- the bus still carries its address
         pa := u(addr);
         if ifetch = '1' and cons_pause = '0' then
            nfetch := nfetch + 1;
            if stub_active and (pa < stub_pc or pa >= stub_pc + 512) then
               stub_active <= false;
               report "stub done, first fetch at " & oct(pa, 8);
            end if;
            if pclog'length > 0 then
               write(ln, oct(pa, 8) & " " & oct(u(dati)) & " " & oct(u(cpu_addr_v)));
               writeline(pf, ln);
            end if;
            if pa = watch_pa then
               report "IFETCH " & oct(pa) & " = " & oct(u(dati)) & " after " & integer'image(nfetch) & " fetches";
            end if;
         end if;
         if control_dato = '1' and pa = 8#17777566# then
            if u(dato) mod 128 = 10 then
               report "CONSOLE: " & con.all;
               deallocate(con);
            elsif u(dato) mod 128 >= 32 then
               write(con, character'val(u(dato) mod 128));
            end if;
         end if;
         if control_dati = '1' and cons_pause = '0' and (pa = 8#10# or pa = 8#4#) and not stub_active then
            report "CPU reads vector " & oct(pa, 3) & " at fetch " & integer'image(nfetch) severity warning;
            vec_seen := true;
         end if;
      end if;
   end process;

   stopper : process
   begin
      wait for stop_ms * 1 ms;
      report "time limit" severity note;
      done <= true;
      wait;
   end process;

end sim;
