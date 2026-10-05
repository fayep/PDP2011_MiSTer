
--
-- tb_xufp_bridge: xufp (xu frame port) + xu_ddr_bridge against a DDR3 model
-- (random busy, a few cycles of read latency) and a model of Main's daemon
-- writing the arm-owned words directly. The xu side is driven as the xu cpu /
-- xubm would: register and buffer accesses on the local buses.
-- Run: sh sim/run_tb_xufp_bridge.sh
--

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_xufp_bridge is
end tb_xufp_bridge;

architecture sim of tb_xufp_bridge is

constant CLK_HZ : integer := 1000000;   -- scaled: poll = 100 cycles, dead = 50000 cycles

signal clk : std_logic := '0';     -- xu nclk
signal bclk : std_logic := '0';    -- bridge clock
signal reset : std_logic := '1';
signal enable : std_logic := '0';

signal mem_addr, reg_addr : std_logic_vector(17 downto 0) := (others => '0');
signal mem_dati, reg_dati : std_logic_vector(15 downto 0);
signal mem_dato, reg_dato : std_logic_vector(15 downto 0) := (others => '0');
signal mem_dati_c, mem_dato_c, mem_datob : std_logic := '0';
signal reg_dati_c, reg_dato_c, reg_datob : std_logic := '0';
signal mem_match, reg_match : std_logic;

signal b_tx_addr, b_rx_addr : std_logic_vector(9 downto 0);
signal b_tx_q, b_rx_d : std_logic_vector(15 downto 0);
signal b_rx_we : std_logic;
signal tx_req_t, tx_ack_t, rx_rdy_t, rx_rel_t, pub_t, host_valid : std_logic;
signal tx_len, rx_len : std_logic_vector(10 downto 0);
signal guest_mac, host_mac : std_logic_vector(47 downto 0);
signal guest_mode : std_logic_vector(7 downto 0);

signal ddr_busy : std_logic := '0';
signal ddr_burstcnt : std_logic_vector(7 downto 0);
signal ddr_addr : std_logic_vector(28 downto 0);
signal ddr_dout : std_logic_vector(63 downto 0) := (others => '0');
signal ddr_dout_ready : std_logic := '0';
signal ddr_rd, ddr_we : std_logic;
signal ddr_din : std_logic_vector(63 downto 0);
signal ddr_be : std_logic_vector(7 downto 0);

-- the DDR3 window, 64 KB as 64-bit words, shared by the ddr model and the Main model
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

signal hb_on : boolean := true;
signal done : boolean := false;
signal errors : integer := 0;

begin

   clk <= not clk after 41 ns when not done;     -- ~12 MHz
   bclk <= not bclk after 5 ns when not done;    -- 100 MHz

   fp: entity work.xufp port map(
      mem_addr_match => mem_match, mem_addr => mem_addr, mem_dati => mem_dati, mem_dato => mem_dato,
      mem_control_dati => mem_dati_c, mem_control_dato => mem_dato_c, mem_control_datob => mem_datob,
      reg_addr_match => reg_match, reg_addr => reg_addr, reg_dati => reg_dati, reg_dato => reg_dato,
      reg_control_dati => reg_dati_c, reg_control_dato => reg_dato_c, reg_control_datob => reg_datob,
      bclk => bclk, b_tx_addr => b_tx_addr, b_tx_q => b_tx_q, b_rx_addr => b_rx_addr, b_rx_d => b_rx_d, b_rx_we => b_rx_we,
      tx_req_t => tx_req_t, tx_len => tx_len, tx_ack_t => tx_ack_t, rx_rdy_t => rx_rdy_t, rx_len => rx_len,
      rx_rel_t => rx_rel_t, pub_t => pub_t, guest_mac => guest_mac, guest_mode => guest_mode,
      host_mac => host_mac, host_valid => host_valid, fport_en => enable,
      reset => reset, clk => clk);

   br: entity work.xu_ddr_bridge generic map(CLK_HZ => CLK_HZ) port map(
      clk => bclk, reset => reset, enable => enable,
      b_tx_addr => b_tx_addr, b_tx_q => b_tx_q, b_rx_addr => b_rx_addr, b_rx_d => b_rx_d, b_rx_we => b_rx_we,
      tx_req_t => tx_req_t, tx_len => tx_len, tx_ack_t => tx_ack_t, rx_rdy_t => rx_rdy_t, rx_len => rx_len,
      rx_rel_t => rx_rel_t, pub_t => pub_t, guest_mac => guest_mac, guest_mode => guest_mode,
      host_mac => host_mac, host_valid => host_valid,
      ddr_busy => ddr_busy, ddr_burstcnt => ddr_burstcnt, ddr_addr => ddr_addr, ddr_dout => ddr_dout,
      ddr_dout_ready => ddr_dout_ready, ddr_rd => ddr_rd, ddr_din => ddr_din, ddr_be => ddr_be, ddr_we => ddr_we);

-- DDR3 model: busy on a pseudo-random pattern, reads answer 3-6 cycles later

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
            assert ddr_burstcnt = x"01" report "burst count not 1" severity failure;
            if ddr_we = '1' then
               assert ddr_be = x"FF" report "partial write" severity failure;
               ddr(a) := ddr_din;
            else
               assert pend = -1 report "second read while one is pending" severity failure;
               paddr := a;
               pend := 3 + to_integer(lfsr(1 downto 0));
            end if;
         end if;
         if lfsr(3 downto 2) = "00" then ddr_busy <= '1'; else ddr_busy <= '0'; end if;
      end if;
   end process;

-- Main's heartbeat

   hb: process
   begin
      wait for 20 us;
      while not done loop
         if hb_on then
            ddr(W_HEART) := std_logic_vector(unsigned(ddr(W_HEART)) + 1);
         end if;
         wait for 50 us;
      end loop;
      wait;
   end process;

   stim: process
      variable d : std_logic_vector(15 downto 0);
      variable q : std_logic_vector(63 downto 0);
      variable n : integer;

      procedure check(c : boolean; msg : string) is
      begin
         if not c then
            report "FAIL: " & msg severity error;
            errors <= errors + 1;
            wait for 0 ns;
         end if;
      end procedure;

-- one xu bus cycle: address and control for a clock, then data (dati is registered)
      procedure regw(a : integer; v : std_logic_vector(15 downto 0)) is
      begin
         wait until clk = '0';
         reg_addr <= std_logic_vector(to_unsigned(a, 18)); reg_dato <= v; reg_dato_c <= '1'; reg_datob <= '0';
         wait until clk = '1'; wait until clk = '0';
         reg_dato_c <= '0';
      end procedure;
      procedure regr(a : integer; v : out std_logic_vector(15 downto 0)) is
      begin
         wait until clk = '0';
         reg_addr <= std_logic_vector(to_unsigned(a, 18)); reg_dati_c <= '1';
         wait until clk = '1'; wait until clk = '0';
         reg_dati_c <= '0';
         v := reg_dati;
      end procedure;
      procedure memw(a : integer; v : std_logic_vector(15 downto 0); byte : std_logic) is
      begin
         wait until clk = '0';
         mem_addr <= std_logic_vector(to_unsigned(a, 18)); mem_dato <= v; mem_dato_c <= '1'; mem_datob <= byte;
         wait until clk = '1'; wait until clk = '0';
         mem_dato_c <= '0';
      end procedure;
      procedure memr(a : integer; v : out std_logic_vector(15 downto 0)) is
      begin
         wait until clk = '0';
         mem_addr <= std_logic_vector(to_unsigned(a, 18)); mem_dati_c <= '1';
         wait until clk = '1'; wait until clk = '0';
         mem_dati_c <= '0';
         v := mem_dati;
      end procedure;

      function pat(seed, i : integer) return std_logic_vector is
      begin
         return std_logic_vector(to_unsigned((seed * 37 + i * 11 + i / 7) mod 256, 8));
      end function;

-- the guest side of a transmit: fill the tx buffer, write txlen, wait for txbusy to drop
      procedure send(seed, len : integer; expect_done : boolean := true) is
         variable v : std_logic_vector(15 downto 0);
         variable t : integer := 0;
      begin
         for i in 0 to len / 2 - 1 loop
            memw(8#020000# + 2 * i, pat(seed, 2 * i + 1) & pat(seed, 2 * i), '0');
         end loop;
         if len mod 2 = 1 then
            memw(8#020000# + len - 1, x"00" & pat(seed, len - 1), '1');
         end if;
         regw(8#777204#, std_logic_vector(to_unsigned(len, 16)));
         if expect_done then
            loop
               regr(8#777200#, v);
               exit when v(1) = '0';
               t := t + 1;
               if t > 20000 then
                  check(false, "txbusy stuck, frame seed " & integer'image(seed));
                  exit;
               end if;
            end loop;
         end if;
      end procedure;

-- Main's side: check slot of tx pointer p holds frame (seed, len)
      procedure check_tx_slot(p, seed, len : integer) is
         variable q : std_logic_vector(63 downto 0);
         variable b : std_logic_vector(7 downto 0);
         variable s : integer := W_TXSLOT + (p mod 8) * 256;
         variable bad : integer := 0;
      begin
         q := ddr(s);
         check(to_integer(unsigned(q(10 downto 0))) = len,
            "tx slot " & integer'image(p) & " length " & integer'image(to_integer(unsigned(q(10 downto 0)))) & " want " & integer'image(len));
         for i in 0 to len - 1 loop
            q := ddr(s + 1 + i / 8);
            b := q((i mod 8) * 8 + 7 downto (i mod 8) * 8);
            if b /= pat(seed, i) then bad := bad + 1; end if;
         end loop;
         check(bad = 0, "tx slot " & integer'image(p) & ": " & integer'image(bad) & " bytes differ");
      end procedure;

-- Main's side: put frame (seed, len) in rx slot p and publish RX_WPTR = p + 1
      procedure inject(p, seed, len : integer) is
         variable q : std_logic_vector(63 downto 0);
         variable s : integer := W_RXSLOT + (p mod 8) * 256;
      begin
         for wd in 0 to (len + 7) / 8 - 1 loop
            q := (others => '0');
            for k in 0 to 7 loop
               if wd * 8 + k < len then q(k * 8 + 7 downto k * 8) := pat(seed, wd * 8 + k); end if;
            end loop;
            ddr(s + 1 + wd) := q;
         end loop;
         ddr(s) := std_logic_vector(to_unsigned(len, 64));
         ddr(W_RXWPTR) := std_logic_vector(to_unsigned(p + 1, 64));
      end procedure;

-- the guest side of a receive: wait for rxrdy, check length and bytes, release
      procedure receive(seed, len : integer) is
         variable v : std_logic_vector(15 downto 0);
         variable t : integer := 0;
         variable bad : integer := 0;
      begin
         loop
            regr(8#777200#, v);
            exit when v(0) = '1';
            t := t + 1;
            if t > 20000 then
               check(false, "rxrdy never set, frame seed " & integer'image(seed));
               return;
            end if;
         end loop;
         regr(8#777202#, v);
         check(to_integer(unsigned(v)) = len, "rxlen " & integer'image(to_integer(unsigned(v))) & " want " & integer'image(len));
         for i in 0 to (len + 1) / 2 - 1 loop
            memr(8#024000# + 2 * i, v);
            if v(7 downto 0) /= pat(seed, 2 * i) then bad := bad + 1; end if;
            if 2 * i + 1 < len and v(15 downto 8) /= pat(seed, 2 * i + 1) then bad := bad + 1; end if;
         end loop;
         check(bad = 0, "rx frame seed " & integer'image(seed) & ": " & integer'image(bad) & " bytes differ");
         regw(8#777200#, x"0001");
         regr(8#777200#, v);
         check(v(0) = '0', "rxrdy still set after release");
      end procedure;

      procedure wait_ddr(wi : integer; v : integer; what : string) is
         variable t : integer := 0;
      begin
         while to_integer(unsigned(ddr(wi)(31 downto 0))) /= v loop
            wait for 1 us;
            t := t + 1;
            if t > 5000 then
               check(false, what & " = " & integer'image(to_integer(unsigned(ddr(wi)(31 downto 0)))) & " want " & integer'image(v));
               return;
            end if;
         end loop;
      end procedure;

   begin
-- Main is up first, with stale pointers the bridge must adopt
      ddr(W_TXRPTR) := std_logic_vector(to_unsigned(5, 64));
      ddr(W_RXWPTR) := std_logic_vector(to_unsigned(3, 64));
      ddr(W_HOST) := x"8000" & x"563412" & x"2B0008";      -- 08-00-2B-12-34-56
      wait for 1 us;
      reset <= '0';
      wait for 2 us;

-- 1. disabled: no ddr traffic, fport bit clear
      regr(8#777200#, d);
      check(d(15) = '0', "fport set while disabled");
      check(ddr(W_MAGIC) = x"0000000000000000", "magic written while disabled");

-- 2. enable: magic, adopted pointers, host mac, fallback before that
      regr(8#777206#, d);
      check(d = x"0008", "fallback mac word 0 " & to_hstring(d));
      enable <= '1';
      wait for 200 us;
      check(ddr(W_MAGIC) = x"3130305558504450", "magic " & to_hstring(ddr(W_MAGIC)));
      check(to_integer(unsigned(ddr(W_TXWPTR))) = 5, "TX_WPTR not adopted from TX_RPTR");
      check(to_integer(unsigned(ddr(W_RXRPTR))) = 3, "RX_RPTR not adopted from RX_WPTR");
      regr(8#777200#, d);
      check(d(15) = '1' and d(2) = '1' and d(1) = '0' and d(0) = '0', "csr after enable " & to_hstring(d));
      regr(8#777206#, d); check(d = x"0008", "host mac word 0 " & to_hstring(d));
      regr(8#777210#, d); check(d = x"122B", "host mac word 1 " & to_hstring(d));
      regr(8#777212#, d); check(d = x"5634", "host mac word 2 " & to_hstring(d));
      check(ddr(W_GUEST)(63) = '0', "guest valid before any mac");

-- 3. guest mac and mode published
      regw(8#777214#, x"00AA");
      regw(8#777216#, x"042B");
      regw(8#777220#, x"0201");
      regw(8#777222#, x"0003");
      wait for 50 us;
      check(ddr(W_GUEST) = x"8003" & x"020104" & x"2B00AA", "guest word " & to_hstring(ddr(W_GUEST)));
      regr(8#777216#, d); check(d = x"042B", "guest mac readback " & to_hstring(d));

-- 4. transmit: odd and even lengths, minimum and maximum
      send(1, 61);  check_tx_slot(5, 1, 61);
      check(to_integer(unsigned(ddr(W_TXWPTR))) = 6, "TX_WPTR after one frame");
      send(2, 60);  check_tx_slot(6, 2, 60);
      send(3, 1514); check_tx_slot(7, 3, 1514);
      send(4, 64);  check_tx_slot(8, 4, 64);             -- wraps to slot 0
      check(to_integer(unsigned(ddr(W_TXWPTR))) = 9, "TX_WPTR after four frames");

-- 5. receive: odd, maximum, back to back through the ring wrap
      inject(3, 11, 99);    receive(11, 99);
      wait_ddr(W_RXRPTR, 4, "RX_RPTR after one frame");
      inject(4, 12, 1514);  receive(12, 1514);
      for k in 5 to 12 loop
         inject(k, 20 + k, 60 + k);
      end loop;
      for k in 5 to 12 loop
         receive(20 + k, 60 + k);
      end loop;
      wait_ddr(W_RXRPTR, 13, "RX_RPTR after the ring wrap");

-- 6. tx ring full with Main alive: the frame waits, then goes when Main takes one
      ddr(W_TXRPTR) := std_logic_vector(to_unsigned(9, 64));
      for k in 0 to 7 loop
         send(40 + k, 100 + k);
      end loop;
      check(to_integer(unsigned(ddr(W_TXWPTR))) = 17, "TX_WPTR with ring just full");
      send(50, 70, false);
      wait for 300 us;
      regr(8#777200#, d);
      check(d(1) = '1', "frame sent into a full ring (txbusy dropped)");
      check(to_integer(unsigned(ddr(W_TXWPTR))) = 17, "TX_WPTR moved with ring full");
      ddr(W_TXRPTR) := std_logic_vector(to_unsigned(10, 64));
      wait_ddr(W_TXWPTR, 18, "TX_WPTR after Main took a frame");
      check_tx_slot(17, 50, 70);
      check_tx_slot(16, 47, 107);

-- 7. Main gone: hostup drops after the heartbeat stops, a full ring drops frames
      hb_on <= false;
      wait for 2 ms;
      regr(8#777200#, d);
      check(d(2) = '0', "hostup still set with no heartbeat");
      regr(8#777206#, d); check(d = x"0008", "mac word 0 after Main gone " & to_hstring(d));
      regr(8#777210#, d); check(d = x"002B", "fallback mac word 1 after Main gone " & to_hstring(d));
      send(60, 80);
      check(to_integer(unsigned(ddr(W_TXWPTR))) = 18, "TX_WPTR moved with nobody listening");

-- 8. Main back
      hb_on <= true;
      ddr(W_TXRPTR) := std_logic_vector(to_unsigned(18, 64));
      wait for 3 ms;
      regr(8#777200#, d);
      check(d(2) = '1', "hostup not back with the heartbeat");
      send(61, 90); check_tx_slot(18, 61, 90);
      inject(13, 70, 128); receive(70, 128);

-- 9. disable and re-enable: the bridge adopts the pointers again
      enable <= '0';
      wait for 20 us;
      ddr(W_RXWPTR) := std_logic_vector(to_unsigned(30, 64));
      ddr(W_TXRPTR) := std_logic_vector(to_unsigned(19, 64));
      enable <= '1';
      wait for 200 us;
      check(to_integer(unsigned(ddr(W_RXRPTR))) = 30, "RX_RPTR not re-adopted");
      inject(30, 80, 200); receive(80, 200);
      send(81, 300); check_tx_slot(19, 81, 300);

      if errors = 0 then
         report "PASS tb_xufp_bridge";
      else
         report "FAIL tb_xufp_bridge: " & integer'image(errors) & " errors";
      end if;
      done <= true;
      wait;
   end process;

end sim;
