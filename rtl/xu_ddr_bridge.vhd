
--
-- xu_ddr_bridge: moves ethernet frames between xufp (the xu frame port) and
-- the DDR3 rings that MiSTer Main (support/pdp2011/xu_net.cpp) serves.
-- See notes/xu-frames-plan.md. Byte offsets from ARM physical 0x1FF00000:
--
--    0x0000 MAGIC "PDPXU001"   fpga      0x0028 GUEST  fpga: b63 valid,
--    0x0008 TX_WPTR            fpga             b55:48 mode, b47:0 mac
--    0x0010 TX_RPTR            arm       0x0030 HOST   arm: b63 valid, b47:0 mac
--    0x0018 RX_WPTR            arm       0x0038 HEARTBEAT arm, +1 per poll
--    0x0020 RX_RPTR            fpga
--    0x1000 TX slots 8 x 2048 (fpga)     0x5000 RX slots 8 x 2048 (arm)
--
-- slot: u64 header, bits 10:0 = length; frame byte i at byte offset 8+i.
-- Pointers are free-running counters, slot = pointer mod 8. Every word has
-- one writer. At start the bridge adopts the arm's pointers (TX_WPTR :=
-- TX_RPTR, RX_RPTR := RX_WPTR), so stale frames on either side are dropped.
--

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity xu_ddr_bridge is
   generic(
      CLK_HZ : integer := 100000000
   );
   port(
      clk : in std_logic;
      reset : in std_logic;
      enable : in std_logic;

-- xufp, bridge side
      b_tx_addr : out std_logic_vector(9 downto 0);
      b_tx_q : in std_logic_vector(15 downto 0);
      b_rx_addr : out std_logic_vector(9 downto 0);
      b_rx_d : out std_logic_vector(15 downto 0);
      b_rx_we : out std_logic;
      tx_req_t : in std_logic;
      tx_len : in std_logic_vector(10 downto 0);
      tx_ack_t : out std_logic;
      rx_rdy_t : out std_logic;
      rx_len : out std_logic_vector(10 downto 0);
      rx_rel_t : in std_logic;
      pub_t : in std_logic;
      guest_mac : in std_logic_vector(47 downto 0);
      guest_mode : in std_logic_vector(7 downto 0);
      host_mac : out std_logic_vector(47 downto 0);
      host_valid : out std_logic;

-- DDRAM
      ddr_busy : in std_logic;
      ddr_burstcnt : out std_logic_vector(7 downto 0);
      ddr_addr : out std_logic_vector(28 downto 0);
      ddr_dout : in std_logic_vector(63 downto 0);
      ddr_dout_ready : in std_logic;
      ddr_rd : out std_logic;
      ddr_din : out std_logic_vector(63 downto 0);
      ddr_be : out std_logic_vector(7 downto 0);
      ddr_we : out std_logic
   );
end xu_ddr_bridge;

architecture implementation of xu_ddr_bridge is

constant BASE : unsigned(28 downto 0) := to_unsigned(16#03FE0000#, 29);
constant A_MAGIC : unsigned(28 downto 0) := BASE + 0;
constant A_TXWPTR : unsigned(28 downto 0) := BASE + 1;
constant A_TXRPTR : unsigned(28 downto 0) := BASE + 2;
constant A_RXWPTR : unsigned(28 downto 0) := BASE + 3;
constant A_RXRPTR : unsigned(28 downto 0) := BASE + 4;
constant A_GUEST : unsigned(28 downto 0) := BASE + 5;
constant A_HOST : unsigned(28 downto 0) := BASE + 6;
constant A_HEART : unsigned(28 downto 0) := BASE + 7;
constant A_TXSLOT : unsigned(28 downto 0) := BASE + 16#200#;   -- byte 0x1000
constant A_RXSLOT : unsigned(28 downto 0) := BASE + 16#A00#;   -- byte 0x5000
constant MAGIC : std_logic_vector(63 downto 0) := x"3130305558504450";   -- "PDPXU001"
constant MAXLEN : unsigned(10 downto 0) := to_unsigned(2040, 11);

constant POLL : integer := CLK_HZ / 10000;        -- 100 us
constant RETRY : integer := CLK_HZ / 50000;       -- 20 us
constant DEAD : integer := CLK_HZ / 20;           -- 50 ms without a heartbeat

type state_t is (
   s_off, s_init0, s_init1, s_init2, s_init3, s_init4,
   s_idle, s_guest,
   s_txchk, s_txrd0, s_txrd1, s_txrd2, s_txwr, s_txhdr, s_txptr,
   s_poll0, s_poll1, s_poll2, s_poll3, s_rxhdr, s_rxrd, s_rxwr, s_rxptr,
   s_mem, s_memwait
);
signal state : state_t := s_off;
signal ret : state_t := s_off;

-- synchronisers (names matched by the sdc: *xufp_s1*)
signal xufp_s1_txreq, xufp_s2_txreq : std_logic := '0';
signal xufp_s1_rxrel, xufp_s2_rxrel : std_logic := '0';
signal xufp_s1_pub, xufp_s2_pub : std_logic := '0';
signal xufp_s1_en, xufp_s2_en : std_logic := '0';

signal txack : std_logic := '0';
signal rxrdy : std_logic := '0';
signal pub_seen : std_logic := '0';
signal rxlen_r : std_logic_vector(10 downto 0) := (others => '0');
signal hmac : std_logic_vector(47 downto 0) := (others => '0');
signal hvalid : std_logic := '0';

signal tx_wptr : unsigned(31 downto 0) := (others => '0');
signal rx_rptr : unsigned(31 downto 0) := (others => '0');
signal heart_last : std_logic_vector(31 downto 0) := (others => '0');
signal alive_cnt : integer range 0 to DEAD := DEAD;
signal poll_cnt : integer range 0 to POLL := 0;
signal retry_cnt : integer range 0 to RETRY := 0;

-- the frame being moved
signal len : unsigned(10 downto 0) := (others => '0');
signal nw : unsigned(8 downto 0) := (others => '0');      -- 64-bit words
signal w : unsigned(8 downto 0) := (others => '0');
signal h : unsigned(1 downto 0) := (others => '0');
signal slot : unsigned(28 downto 0) := (others => '0');
signal dw : std_logic_vector(63 downto 0) := (others => '0');

-- one ddr access
signal m_we : std_logic := '0';
signal m_addr : unsigned(28 downto 0) := (others => '0');
signal m_wdata : std_logic_vector(63 downto 0) := (others => '0');
signal m_rdata : std_logic_vector(63 downto 0) := (others => '0');
signal rd_r : std_logic := '0';
signal we_r : std_logic := '0';

begin

   tx_ack_t <= txack;
   rx_rdy_t <= rxrdy;
   rx_len <= rxlen_r;
   host_mac <= hmac;
   host_valid <= hvalid;

   ddr_burstcnt <= x"01";
   ddr_be <= x"FF";
   ddr_addr <= std_logic_vector(m_addr);
   ddr_din <= m_wdata;
   ddr_rd <= rd_r;
   ddr_we <= we_r;

   process(clk)
      procedure mem(we : std_logic; a : unsigned(28 downto 0); d : std_logic_vector(63 downto 0); r : state_t) is
      begin
         m_we <= we;
         m_addr <= a;
         m_wdata <= d;
         ret <= r;
         state <= s_mem;
      end procedure;

      function words(l : unsigned(10 downto 0)) return unsigned is
      begin
         return resize(shift_right(resize(l, 12) + 7, 3), 9);
      end function;
   begin
      if clk = '1' and clk'event then
         xufp_s1_txreq <= tx_req_t; xufp_s2_txreq <= xufp_s1_txreq;
         xufp_s1_rxrel <= rx_rel_t; xufp_s2_rxrel <= xufp_s1_rxrel;
         xufp_s1_pub <= pub_t;      xufp_s2_pub <= xufp_s1_pub;
         xufp_s1_en <= enable;      xufp_s2_en <= xufp_s1_en;

         b_rx_we <= '0';
         if poll_cnt /= 0 then poll_cnt <= poll_cnt - 1; end if;
         if retry_cnt /= 0 then retry_cnt <= retry_cnt - 1; end if;
         if alive_cnt /= DEAD then alive_cnt <= alive_cnt + 1; end if;

         if reset = '1' or xufp_s2_en = '0' then
            txack <= xufp_s2_txreq;
            rxrdy <= xufp_s2_rxrel;
            pub_seen <= not xufp_s2_pub;            -- publish once at start
            hvalid <= '0';
            alive_cnt <= DEAD;
            rd_r <= '0';
            we_r <= '0';
            state <= s_off;
         else
            case state is
               when s_off =>
                  mem('0', A_TXRPTR, (others => '0'), s_init0);

               when s_init0 =>                                          -- adopt the arm's pointers
                  tx_wptr <= unsigned(m_rdata(31 downto 0));
                  mem('1', A_TXWPTR, x"00000000" & m_rdata(31 downto 0), s_init1);
               when s_init1 =>
                  mem('0', A_RXWPTR, (others => '0'), s_init2);
               when s_init2 =>
                  rx_rptr <= unsigned(m_rdata(31 downto 0));
                  mem('1', A_RXRPTR, x"00000000" & m_rdata(31 downto 0), s_init3);
               when s_init3 =>
                  mem('1', A_MAGIC, MAGIC, s_init4);
               when s_init4 =>
                  state <= s_idle;

               when s_idle =>
                  if pub_seen /= xufp_s2_pub then
                     pub_seen <= xufp_s2_pub;
                     state <= s_guest;
                  elsif txack /= xufp_s2_txreq and retry_cnt = 0 then
                     mem('0', A_TXRPTR, (others => '0'), s_txchk);
                  elsif poll_cnt = 0 then
                     poll_cnt <= POLL;
                     mem('0', A_HEART, (others => '0'), s_poll0);
                  end if;

               when s_guest =>
                  if guest_mac /= x"000000000000" then
                     mem('1', A_GUEST, x"80" & guest_mode & guest_mac, s_idle);
                  else
                     mem('1', A_GUEST, x"00" & guest_mode & guest_mac, s_idle);
                  end if;

-- transmit: copy the tx buffer into slot TX_WPTR, then the header, then the pointer

               when s_txchk =>
                  if tx_wptr - unsigned(m_rdata(31 downto 0)) < 8 then
                     if unsigned(tx_len) > MAXLEN then len <= MAXLEN; else len <= unsigned(tx_len); end if;
                     if unsigned(tx_len) > MAXLEN then nw <= words(MAXLEN); else nw <= words(unsigned(tx_len)); end if;
                     slot <= A_TXSLOT + shift_left(resize(tx_wptr(2 downto 0), 29), 8);
                     w <= (others => '0');
                     h <= "00";
                     state <= s_txrd0;
                  elsif hvalid = '0' then
                     txack <= not txack;                                  -- nobody listening: drop it
                     state <= s_idle;
                  else
                     retry_cnt <= RETRY;                                   -- ring full: try again soon
                     state <= s_idle;
                  end if;
               when s_txrd0 =>
                  if w = nw then
                     mem('1', slot, std_logic_vector(resize(len, 64)), s_txhdr);
                  else
                     b_tx_addr <= std_logic_vector(w(7 downto 0)) & std_logic_vector(h);
                     state <= s_txrd1;
                  end if;
               when s_txrd1 =>
                  state <= s_txrd2;
               when s_txrd2 =>
                  dw(to_integer(h)*16+15 downto to_integer(h)*16) <= b_tx_q;
                  h <= h + 1;
                  if h = "11" then
                     state <= s_txwr;
                  else
                     state <= s_txrd0;
                  end if;
               when s_txwr =>
                  w <= w + 1;
                  mem('1', slot + 1 + resize(w, 29), dw, s_txrd0);
               when s_txhdr =>
                  tx_wptr <= tx_wptr + 1;
                  mem('1', A_TXWPTR, x"00000000" & std_logic_vector(tx_wptr + 1), s_txptr);
               when s_txptr =>
                  txack <= not txack;
                  state <= s_idle;

-- poll: heartbeat, host mac, then a received frame if the rx buffer is free

               when s_poll0 =>
                  if m_rdata(31 downto 0) /= heart_last then
                     heart_last <= m_rdata(31 downto 0);
                     alive_cnt <= 0;
                  end if;
                  mem('0', A_HOST, (others => '0'), s_poll1);
               when s_poll1 =>
                  hmac <= m_rdata(47 downto 0);
                  if m_rdata(63) = '1' and alive_cnt /= DEAD then hvalid <= '1'; else hvalid <= '0'; end if;
                  if rxrdy = xufp_s2_rxrel then
                     mem('0', A_RXWPTR, (others => '0'), s_poll2);
                  else
                     state <= s_idle;
                  end if;
               when s_poll2 =>
                  if unsigned(m_rdata(31 downto 0)) /= rx_rptr then
                     slot <= A_RXSLOT + shift_left(resize(rx_rptr(2 downto 0), 29), 8);
                     mem('0', A_RXSLOT + shift_left(resize(rx_rptr(2 downto 0), 29), 8), (others => '0'), s_poll3);
                  else
                     state <= s_idle;
                  end if;
               when s_poll3 =>
                  if unsigned(m_rdata(10 downto 0)) > MAXLEN then len <= MAXLEN; else len <= unsigned(m_rdata(10 downto 0)); end if;
                  if unsigned(m_rdata(10 downto 0)) > MAXLEN then nw <= words(MAXLEN); else nw <= words(unsigned(m_rdata(10 downto 0))); end if;
                  w <= (others => '0');
                  state <= s_rxhdr;
               when s_rxhdr =>
                  if w = nw then
                     state <= s_rxptr;
                  else
                     mem('0', slot + 1 + resize(w, 29), (others => '0'), s_rxrd);
                  end if;
               when s_rxrd =>
                  dw <= m_rdata;
                  h <= "00";
                  state <= s_rxwr;
               when s_rxwr =>
                  b_rx_addr <= std_logic_vector(w(7 downto 0)) & std_logic_vector(h);
                  b_rx_d <= dw(to_integer(h)*16+15 downto to_integer(h)*16);
                  b_rx_we <= '1';
                  h <= h + 1;
                  if h = "11" then
                     w <= w + 1;
                     state <= s_rxhdr;
                  end if;
               when s_rxptr =>
                  rxlen_r <= std_logic_vector(len);
                  rxrdy <= not rxrdy;
                  rx_rptr <= rx_rptr + 1;
                  mem('1', A_RXRPTR, x"00000000" & std_logic_vector(rx_rptr + 1), s_idle);

-- one ddr access: hold the command until the controller takes it

               when s_mem =>
                  rd_r <= not m_we;
                  we_r <= m_we;
                  state <= s_memwait;
               when s_memwait =>
                  if ddr_busy = '0' and (rd_r = '1' or we_r = '1') then
                     rd_r <= '0';
                     we_r <= '0';
                     if we_r = '1' then
                        state <= ret;
                     end if;
                  elsif rd_r = '0' and we_r = '0' and ddr_dout_ready = '1' then
                     m_rdata <= ddr_dout;
                     state <= ret;
                  end if;

               when others =>
                  state <= s_idle;
            end case;
         end if;
      end if;
   end process;

end implementation;
