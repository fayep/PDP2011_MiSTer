
--
-- tb_xu_deuna: black-box test of the DEUNA (xu.vhd + its firmware xubrt45)
-- on the frame port. The testbench is the guest: it only touches the
-- DEUNA's Unibus registers (774510-774516), serves its DMA from a guest
-- memory model and grants its interrupts, the way a driver would. Behind the
-- frame port sit xu_ddr_bridge, a DDR3 model and a model of Main's daemon.
-- The xu cpu's debug console is decoded and echoed (prefix "xu:").
-- Run: sh sim/run_tb_xu_deuna.sh
--

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_xu_deuna is
end tb_xu_deuna;

architecture sim of tb_xu_deuna is

constant BCLK_HZ : integer := 1000000;   -- bridge timers scaled: poll 1 us, dead 500 us

signal cpuclk : std_logic := '0';        -- 10 MHz
signal nclk : std_logic;
signal clk50 : std_logic := '0';
signal bclk : std_logic := '0';          -- 100 MHz
signal reset : std_logic := '1';       -- the xu's: bus init
signal breset : std_logic := '1';      -- the bridge's: power-up only, as in pdp2011.sv
signal done : boolean := false;

-- unibus, slave side of the xu
signal bus_addr : std_logic_vector(17 downto 0) := (others => '0');
signal bus_dati : std_logic_vector(15 downto 0);
signal bus_dato : std_logic_vector(15 downto 0) := (others => '0');
signal bus_control_dati, bus_control_dato, bus_control_datob : std_logic := '0';
signal bus_addr_match : std_logic;

-- unibus, master side
signal npr, br : std_logic;
signal npg, bg : std_logic := '0';
signal int_vector : std_logic_vector(8 downto 0);
signal bm_addr : std_logic_vector(17 downto 0);
signal bm_dati : std_logic_vector(15 downto 0) := (others => '0');
signal bm_dato : std_logic_vector(15 downto 0);
signal bm_dati_c, bm_dato_c : std_logic;

signal xu_tx : std_logic;
signal fp_i : std_logic_vector(99 downto 0);
signal fp_o : std_logic_vector(85 downto 0);

-- bridge
signal ddr_busy : std_logic := '0';
signal ddr_burstcnt : std_logic_vector(7 downto 0);
signal ddr_addr : std_logic_vector(28 downto 0);
signal ddr_dout : std_logic_vector(63 downto 0) := (others => '0');
signal ddr_dout_ready : std_logic := '0';
signal ddr_rd, ddr_we : std_logic;
signal ddr_din : std_logic_vector(63 downto 0);
signal ddr_be : std_logic_vector(7 downto 0);

-- guest memory: 64 KB
type gmem_t is array(0 to 32767) of std_logic_vector(15 downto 0);
shared variable gmem : gmem_t := (others => (others => '0'));

-- DDR3 window
type ddr_t is array(0 to 8191) of std_logic_vector(63 downto 0);
shared variable ddr : ddr_t := (others => (others => '0'));
constant BASEW : integer := 16#03FE0000#;
constant W_MAGIC : integer := 0;
constant W_TXWPTR : integer := 1;
constant W_TXRPTR : integer := 2;
constant W_RXWPTR : integer := 3;
constant W_RXRPTR : integer := 4;
constant W_GUEST : integer := 5;
constant W_HOST : integer := 6;
constant W_HEART : integer := 7;
constant W_TXSLOT : integer := 16#200#;
constant W_RXSLOT : integer := 16#A00#;

signal interrupts : integer := 0;
shared variable dma_writes : integer := 0;
signal errors : integer := 0;

-- guest memory layout (byte addresses)
constant PCB : integer := 8#1000#;
constant UDB : integer := 8#1100#;
constant TDR : integer := 8#2000#;       -- 4 entries x 4 words
constant RDR : integer := 8#2100#;       -- 4 entries x 4 words
constant TBUF : integer := 8#10000#;     -- 4 x 2048
constant RBUF : integer := 8#30000#;     -- 4 x 512 (receive buffers chain)
constant RSLEN : integer := 512;

begin

   cpuclk <= not cpuclk after 50 ns when not done;
   nclk <= not cpuclk;
   clk50 <= not clk50 after 10 ns when not done;
   bclk <= not bclk after 5 ns when not done;

   xu0: entity work.xu port map(
      base_addr => o"774510",
      ivec => o"120",
      br => br, bg => bg, int_vector => int_vector,
      npr => npr, npg => npg,
      bus_addr_match => bus_addr_match, bus_addr => bus_addr, bus_dati => bus_dati, bus_dato => bus_dato,
      bus_control_dati => bus_control_dati, bus_control_dato => bus_control_dato, bus_control_datob => bus_control_datob,
      bus_master_addr => bm_addr, bus_master_dati => bm_dati, bus_master_dato => bm_dato,
      bus_master_control_dati => bm_dati_c, bus_master_control_dato => bm_dato_c, bus_master_nxm => '0',
      xu_cs => open, xu_mosi => open, xu_sclk => open, xu_miso => '1',
      fp_bclk => bclk, fp_i => fp_i, fp_o => fp_o,
      have_xu => 1, have_xu_debug => 1,
      tx => xu_tx, ifetch => open, iwait => open,
      cpuclk => cpuclk, nclk => nclk, clk50mhz => clk50, reset => reset);

   br0: entity work.xu_ddr_bridge generic map(CLK_HZ => BCLK_HZ) port map(
      clk => bclk, reset => breset, enable => '1',
      b_tx_addr => fp_i(9 downto 0), b_tx_q => fp_o(15 downto 0),
      b_rx_addr => fp_i(19 downto 10), b_rx_d => fp_i(35 downto 20), b_rx_we => fp_i(36),
      tx_req_t => fp_o(16), tx_len => fp_o(27 downto 17), tx_ack_t => fp_i(37),
      rx_rdy_t => fp_i(38), rx_len => fp_i(49 downto 39), rx_rel_t => fp_o(28),
      pub_t => fp_o(29), guest_mac => fp_o(77 downto 30), guest_mode => fp_o(85 downto 78),
      host_mac => fp_i(97 downto 50), host_valid => fp_i(98),
      ddr_busy => ddr_busy, ddr_burstcnt => ddr_burstcnt, ddr_addr => ddr_addr, ddr_dout => ddr_dout,
      ddr_dout_ready => ddr_dout_ready, ddr_rd => ddr_rd, ddr_din => ddr_din, ddr_be => ddr_be, ddr_we => ddr_we);
   fp_i(99) <= '1';                    -- host networking selected

-- guest memory: reads combinational, writes on the falling edge of cpuclk

   bm_dati <= gmem(to_integer(unsigned(bm_addr(15 downto 1)))) when bm_dati_c = '1' and bm_addr(17 downto 16) = "00" else (others => '0');
   gm: process(cpuclk)
   begin
      if cpuclk = '0' and cpuclk'event then
         if bm_dato_c = '1' then
            assert bm_addr(17 downto 16) = "00" report "dma write above 64 KB" severity failure;
            gmem(to_integer(unsigned(bm_addr(15 downto 1)))) := bm_dato;
            dma_writes := dma_writes + 1;
         end if;
      end if;
   end process;

-- npr/npg and br/bg

   arb: process(cpuclk)
      variable ncnt : integer := 0;
   begin
      if cpuclk = '1' and cpuclk'event then
         if npr = '1' then
            if ncnt = 2 then npg <= '1'; else ncnt := ncnt + 1; end if;
         else
            npg <= '0'; ncnt := 0;
         end if;
         if br = '1' and bg = '0' then
            bg <= '1';
            interrupts <= interrupts + 1;
         elsif br = '0' and bg = '1' then
            assert int_vector = o"120" report "interrupt vector not 120" severity error;
            bg <= '0';
         end if;
      end if;
   end process;

-- xu debug console, 115200 baud

   con: process
      variable line : string(1 to 200);
      variable n : integer := 0;
      variable c : std_logic_vector(7 downto 0);
      constant BIT_T : time := 8681 ns;
   begin
      wait until xu_tx = '0';
      wait for BIT_T / 2;
      for i in 0 to 7 loop
         wait for BIT_T;
         c(i) := xu_tx;
      end loop;
      wait for BIT_T;
      if c = x"0A" then
         report "xu: " & line(1 to n);
         n := 0;
      elsif c /= x"0D" and n < 200 then
         n := n + 1;
         line(n) := character'val(to_integer(unsigned(c)));
      end if;
   end process;

-- DDR3 model, as in tb_xufp_bridge

   ddrm: process(bclk)
      variable lfsr : unsigned(15 downto 0) := x"ACE1";
      variable pend : integer := -1;
      variable paddr : integer := 0;
      variable a : integer;
   begin
      if bclk = '1' and bclk'event then
         lfsr := lfsr(14 downto 0) & (lfsr(15) xor lfsr(13) xor lfsr(12) xor lfsr(10));
         ddr_dout_ready <= '0';
         if pend > 0 then
            pend := pend - 1;
         elsif pend = 0 then
            ddr_dout <= ddr(paddr);
            ddr_dout_ready <= '1';
            pend := -1;
         end if;
         if ddr_busy = '0' and (ddr_rd = '1' or ddr_we = '1') then
            a := to_integer(unsigned(ddr_addr)) - BASEW;
            assert a >= 0 and a < 8192 report "ddr access outside the window" severity failure;
            if ddr_we = '1' then
               ddr(a) := ddr_din;
            else
               paddr := a;
               pend := 3 + to_integer(lfsr(1 downto 0));
            end if;
         end if;
         if lfsr(3 downto 2) = "00" then ddr_busy <= '1'; else ddr_busy <= '0'; end if;
      end if;
   end process;

   hb: process
   begin
      while not done loop
         ddr(W_HEART) := std_logic_vector(unsigned(ddr(W_HEART)) + 1);
         wait for 50 us;
      end loop;
      wait;
   end process;

   guest: process
      variable d : std_logic_vector(15 downto 0);
      variable q : std_logic_vector(63 downto 0);
      variable txp : integer := 0;      -- Main's TX read pointer
      variable rxp : integer := 0;      -- Main's RX write pointer

      procedure check(c : boolean; msg : string) is
      begin
         if not c then
            report "FAIL: " & msg severity error;
            errors <= errors + 1;
            wait for 0 ns;
         end if;
      end procedure;

      procedure wr(a : integer; v : std_logic_vector(15 downto 0); byte : std_logic := '0') is
      begin
         wait until cpuclk = '1';
         bus_addr <= std_logic_vector(to_unsigned(a, 18)); bus_dato <= v;
         bus_control_dato <= '1'; bus_control_datob <= byte;
         wait until cpuclk = '1';
         bus_control_dato <= '0'; bus_control_datob <= '0';
      end procedure;
      procedure rd(a : integer; v : out std_logic_vector(15 downto 0)) is
      begin
         wait until cpuclk = '1';
         bus_addr <= std_logic_vector(to_unsigned(a, 18)); bus_control_dati <= '1';
         wait until cpuclk = '1';
         wait until cpuclk = '0';
         v := bus_dati;
         bus_control_dati <= '0';
      end procedure;

      procedure pokew(a : integer; v : integer) is
      begin
         gmem(a / 2) := std_logic_vector(to_unsigned(v mod 65536, 16));
      end procedure;
      impure function peekw(a : integer) return integer is
      begin
         return to_integer(unsigned(gmem(a / 2)));
      end function;
      procedure pokeb(a : integer; v : integer) is
         variable w : std_logic_vector(15 downto 0) := gmem(a / 2);
      begin
         if a mod 2 = 0 then w(7 downto 0) := std_logic_vector(to_unsigned(v, 8));
         else w(15 downto 8) := std_logic_vector(to_unsigned(v, 8)); end if;
         gmem(a / 2) := w;
      end procedure;
      impure function peekb(a : integer) return integer is
         variable w : std_logic_vector(15 downto 0) := gmem(a / 2);
      begin
         if a mod 2 = 0 then return to_integer(unsigned(w(7 downto 0)));
         else return to_integer(unsigned(w(15 downto 8))); end if;
      end function;

      function pat(seed, i : integer) return integer is
      begin
         return (seed * 37 + i * 11 + i / 7) mod 256;
      end function;

-- port command, wait for DNI, clear it (byte write to the high byte)
      procedure port_cmd(cmd : integer; what : string) is
         variable v : std_logic_vector(15 downto 0);
         variable t : integer := 0;
      begin
         wr(8#774510#, std_logic_vector(to_unsigned(8#100# + cmd, 16)));
         loop
            rd(8#774510#, v);
            exit when v(11) = '1';
            t := t + 1;
            if t > 400000 then
               check(false, what & ": no DNI, pcsr0 " & to_hstring(v));
               return;
            end if;
            wait for 1 us;
         end loop;
         check(v(14) = '0', what & ": PCEI set, pcsr0 " & to_hstring(v));
         wr(8#774511#, x"0800", '1');
      end procedure;

      procedure pcb_cmd(fc : integer; what : string) is
      begin
         pokew(PCB, fc);
         port_cmd(2, what);
      end procedure;

-- wait for an interrupt bit in pcsr0 and clear it
      procedure wait_pcsr0(bitn : integer; what : string) is
         variable v : std_logic_vector(15 downto 0);
         variable t : integer := 0;
         variable m : std_logic_vector(15 downto 0) := (others => '0');
      begin
         loop
            rd(8#774510#, v);
            exit when v(bitn) = '1';
            t := t + 1;
            if t > 200000 then
               check(false, what & ": pcsr0 bit " & integer'image(bitn) & " never set, pcsr0 " & to_hstring(v));
               return;
            end if;
            wait for 1 us;
         end loop;
         m(bitn) := '1';
         wr(8#774511#, m, '1');
      end procedure;

      procedure wait_ddr(wi : integer; v : integer; what : string) is
         variable t : integer := 0;
      begin
         while to_integer(unsigned(ddr(wi)(31 downto 0))) /= v loop
            wait for 1 us;
            t := t + 1;
            if t > 200000 then
               check(false, what & " = " & integer'image(to_integer(unsigned(ddr(wi)(31 downto 0)))) & " want " & integer'image(v));
               return;
            end if;
         end loop;
      end procedure;

      impure function slot_byte(ws, i : integer) return integer is
         variable q : std_logic_vector(63 downto 0) := ddr(ws + 1 + i / 8);
      begin
         return to_integer(unsigned(q((i mod 8) * 8 + 7 downto (i mod 8) * 8)));
      end function;

-- give receive entry e back to the DEUNA
      procedure rx_own(e : integer) is
      begin
         pokew(RDR + e * 8 + 0, RSLEN);
         pokew(RDR + e * 8 + 2, RBUF + e * RSLEN);
         pokew(RDR + e * 8 + 4, 16#8000#);
         pokew(RDR + e * 8 + 6, 0);
      end procedure;

-- Main delivers a frame
      procedure inject(seed, len : integer) is
         variable q : std_logic_vector(63 downto 0);
         variable s : integer := W_RXSLOT + (rxp mod 8) * 256;
      begin
         for wd in 0 to (len + 7) / 8 - 1 loop
            q := (others => '0');
            for k in 0 to 7 loop
               if wd * 8 + k < len then q(k * 8 + 7 downto k * 8) := std_logic_vector(to_unsigned(pat(seed, wd * 8 + k), 8)); end if;
            end loop;
            ddr(s + 1 + wd) := q;
         end loop;
         ddr(s) := std_logic_vector(to_unsigned(len, 64));
         rxp := rxp + 1;
         ddr(W_RXWPTR) := std_logic_vector(to_unsigned(rxp, 64));
      end procedure;

      variable mac : integer;
      variable e, off, n, bad, mlen, w2, len : integer;

   begin
-- Main is up with its default address before the core starts
      ddr(W_HOST) := x"8000" & x"563412" & x"2B0008";        -- 08-00-2B-12-34-56
      wait for 1 us;
      reset <= '0';
      breset <= '0';

-- 1. firmware comes up: it publishes its address through the frame port, then pcsr1 says ready
--    (pcsr1 reads ready straight out of reset, before the firmware runs, so that alone proves nothing)
      for t in 0 to 2000 loop
         exit when ddr(W_GUEST)(63) = '1';
         wait for 50 us;
      end loop;
      for t in 0 to 2000 loop
         rd(8#774512#, d);
         exit when d(3 downto 0) = "0010";
         wait for 50 us;
      end loop;
      check(d(3 downto 0) = "0010", "pcsr1 state not ready: " & to_hstring(d));
      check(ddr(W_MAGIC) = x"3130305558504450", "bridge magic missing");
      check(ddr(W_GUEST) = x"8000" & x"563412" & x"2B0008", "guest word at start-up " & to_hstring(ddr(W_GUEST)));

-- 2. clear the start-up dni, interrupts on, get pcbb, read default physical address
      wr(8#774511#, x"0800", '1');
      wr(8#774510#, x"0040");
      wr(8#774514#, std_logic_vector(to_unsigned(PCB, 16)));
      wr(8#774516#, x"0000");
      port_cmd(1, "get pcbb");
      pcb_cmd(2, "read default physical address");
      check(peekw(PCB + 2) = 16#0008# and peekw(PCB + 4) = 16#122B# and peekw(PCB + 6) = 16#5634#,
         "default PA " & integer'image(peekw(PCB + 2)) & " " & integer'image(peekw(PCB + 4)) & " " & integer'image(peekw(PCB + 6)));

-- 3. write ring format
      pokew(PCB + 2, UDB); pokew(PCB + 4, 0);
      pokew(UDB + 0, TDR); pokew(UDB + 2, 4 * 256); pokew(UDB + 4, 4);
      pokew(UDB + 6, RDR); pokew(UDB + 8, 4 * 256); pokew(UDB + 10, 4);
      for k in 0 to 3 loop
         pokew(TDR + k * 8 + 4, 0);
         rx_own(k);
      end loop;
      pcb_cmd(9, "write ring format");
      pcb_cmd(8, "read ring format");
      check(peekw(UDB + 0) = TDR and peekw(UDB + 6) = RDR and peekw(UDB + 4) = 4 and peekw(UDB + 10) = 4, "ring format readback");

-- 4. write physical address, mode
      pokew(PCB + 2, 16#00AA#); pokew(PCB + 4, 16#0004#); pokew(PCB + 6, 16#0401#);   -- AA-00-04-00-01-04
      pcb_cmd(5, "write physical address");
      pokew(PCB + 2, 16#4000#);                                                       -- enal
      pcb_cmd(13, "write mode");
      wait for 30 us;
      check(ddr(W_GUEST) = x"8002" & x"040100" & x"0400AA", "guest word after fc5/fc15 " & to_hstring(ddr(W_GUEST)));
      pcb_cmd(4, "read physical address");
      check(peekw(PCB + 2) = 16#00AA# and peekw(PCB + 4) = 16#0004# and peekw(PCB + 6) = 16#0401#, "PA readback");

-- 5. start
      port_cmd(4, "start");
      rd(8#774512#, d);
      check(d(3 downto 0) = "0011", "pcsr1 state not running: " & to_hstring(d));

-- 6. transmit: one 60-byte frame, then a 1514-byte frame in two segments
      for i in 0 to 59 loop pokeb(TBUF + i, pat(1, i)); end loop;
      pokew(TDR + 0, 60); pokew(TDR + 2, TBUF); pokew(TDR + 4, 16#8000# + 16#0200# + 16#0100#);
      port_cmd(8, "polling demand (60)");
      wait_pcsr0(12, "txi (60)");
      check(peekw(TDR + 4) / 32768 = 0, "tx entry 0 still owned");
      txp := txp + 1;
      wait_ddr(W_TXWPTR, txp, "TX_WPTR after the 60-byte frame");
      n := W_TXSLOT + 0 * 256;
      check(to_integer(unsigned(ddr(n)(10 downto 0))) = 60, "tx frame length " & integer'image(to_integer(unsigned(ddr(n)(10 downto 0)))));
      bad := 0;
      for i in 0 to 59 loop
         if (i < 6 or i >= 12) and slot_byte(n, i) /= pat(1, i) then bad := bad + 1; end if;   -- source checked below
      end loop;
      check(bad = 0, "tx 60: " & integer'image(bad) & " bytes differ");
      check(slot_byte(n, 6) = 16#AA# and slot_byte(n, 7) = 0 and slot_byte(n, 8) = 4 and slot_byte(n, 9) = 0
         and slot_byte(n, 10) = 1 and slot_byte(n, 11) = 4, "tx source address is not ours");

      for i in 0 to 1513 loop pokeb(TBUF + 2048 + i, pat(2, i)); end loop;
      pokew(TDR + 8, 1000); pokew(TDR + 10, TBUF + 2048); pokew(TDR + 12, 16#8000# + 16#0200#);
      pokew(TDR + 16, 514); pokew(TDR + 18, TBUF + 2048 + 1000); pokew(TDR + 20, 16#8000# + 16#0100#);
      port_cmd(8, "polling demand (1514 chained)");
      wait_pcsr0(12, "txi (1514)");
      txp := txp + 1;
      wait_ddr(W_TXWPTR, txp, "TX_WPTR after the 1514-byte frame");
      n := W_TXSLOT + 1 * 256;
      check(to_integer(unsigned(ddr(n)(10 downto 0))) = 1514, "tx chained length " & integer'image(to_integer(unsigned(ddr(n)(10 downto 0)))));
      bad := 0;
      for i in 0 to 1513 loop
         if (i < 6 or i >= 12) and slot_byte(n, i) /= pat(2, i) then bad := bad + 1; end if;
      end loop;
      check(bad = 0, "tx 1514: " & integer'image(bad) & " bytes differ");
      check(peekw(TDR + 12) / 32768 = 0 and peekw(TDR + 20) / 32768 = 0, "chained tx entries still owned");
      ddr(W_TXRPTR) := std_logic_vector(to_unsigned(txp, 64));

-- 7. receive: 64 bytes into one buffer, then 1514 bytes chained over four 512-byte buffers
      inject(11, 64);
      wait_pcsr0(13, "rxi (64)");
      w2 := peekw(RDR + 4);
      mlen := peekw(RDR + 6) mod 4096;
      check(w2 / 32768 = 0, "rx entry 0 still owned");
      check((w2 / 512) mod 2 = 1 and (w2 / 256) mod 2 = 1, "rx entry 0 not stp+enp: " & integer'image(w2));
      check(mlen = 68, "rx mlen " & integer'image(mlen) & " want 68 (64 + crc)");
      bad := 0;
      for i in 0 to 63 loop
         if peekb(RBUF + i) /= pat(11, i) then bad := bad + 1; end if;
      end loop;
      check(bad = 0, "rx 64: " & integer'image(bad) & " bytes differ");
      wait_ddr(W_RXRPTR, 1, "RX_RPTR after one frame");
      rx_own(0);

      inject(12, 1514);
      wait_pcsr0(13, "rxi (1514)");
      bad := 0;
      for k in 0 to 2 loop
         e := 1 + k;
         check(peekw(RDR + e * 8 + 4) / 32768 = 0, "rx entry " & integer'image(e) & " still owned");
      end loop;
      for i in 0 to 1513 loop
         e := 1 + i / RSLEN;
         off := i mod RSLEN;
         if peekb(RBUF + e * RSLEN + off) /= pat(12, i) then bad := bad + 1; end if;
      end loop;
      check(bad = 0, "rx 1514 chained: " & integer'image(bad) & " bytes differ");
      check((peekw(RDR + 1 * 8 + 4) / 512) mod 2 = 1, "first chained rx buffer not stp");
      check((peekw(RDR + 3 * 8 + 4) / 256) mod 2 = 1, "last chained rx buffer (entry 3) not enp");
      mlen := peekw(RDR + 3 * 8 + 6) mod 4096;
      check(mlen = 1518, "rx chained mlen " & integer'image(mlen) & " want 1518");

-- 8. no receive buffer: the frame waits in the frame port until one is given back
      pokew(RDR + 0 * 8 + 4, 0);                   -- the next entry (0) is the host's
      inject(13, 100);
      wait for 2 ms;
      check(to_integer(unsigned(ddr(W_RXRPTR)(31 downto 0))) = 3, "frame taken with no buffer owned: RX_RPTR " & integer'image(to_integer(unsigned(ddr(W_RXRPTR)(31 downto 0)))));
      rx_own(0);
      port_cmd(8, "polling demand (rx buffer back)");
      wait_pcsr0(13, "rxi (after buffer returned)");
      bad := 0;
      for i in 0 to 99 loop
         if peekb(RBUF + 0 * RSLEN + i) /= pat(13, i) then bad := bad + 1; end if;
      end loop;
      check(bad = 0, "rx after buffer returned: " & integer'image(bad) & " bytes differ");

-- 9. bus init (RESET) while running: the DEUNA stops, nothing more is written to guest
--    memory while the LAN keeps delivering, and the firmware comes back up
      for k in 0 to 3 loop rx_own(k); end loop;
      wait until cpuclk = '1';
      reset <= '1';
      wait for 2 us;
      wait until cpuclk = '1';
      reset <= '0';
      for k in 0 to 3 loop
         pokew(RDR + k * 8 + 6, 16#1234#);         -- marker: a receive would overwrite it
      end loop;
      dma_writes := 0;
      inject(14, 80); inject(15, 90);
      wait for 3 ms;
      check(dma_writes = 0, "dma into guest memory after bus init: " & integer'image(dma_writes) & " writes");
      for k in 0 to 3 loop
         check(peekw(RDR + k * 8 + 6) = 16#1234#, "rx entry " & integer'image(k) & " written after bus init");
      end loop;
      ddr(W_GUEST) := (others => '0');
      for t in 0 to 2000 loop
         exit when ddr(W_GUEST)(63) = '1';
         wait for 50 us;
      end loop;
      check(ddr(W_GUEST)(63) = '1', "firmware did not come back after bus init");
      for t in 0 to 200 loop
         rd(8#774512#, d);
         exit when d(3 downto 0) = "0010";
         wait for 50 us;
      end loop;
      check(d(3 downto 0) = "0010", "pcsr1 after bus init not ready: " & to_hstring(d));

      check(interrupts > 0, "no interrupts granted");
      report "interrupts granted: " & integer'image(interrupts);
      if errors = 0 then
         report "PASS tb_xu_deuna";
      else
         report "FAIL tb_xu_deuna: " & integer'image(errors) & " errors";
      end if;
      done <= true;
      wait;
   end process;

end sim;
