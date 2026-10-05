
--
-- xufp: frame port for the xu (DEUNA) cpu - the host-networking replacement
-- for the encx24j600 on the spi bus. See notes/xu-frames-plan.md.
--
-- Two 2 KB frame buffers sit in the xu cpu's local memory, so xubm can dma
-- whole segments between guest memory and a buffer:
--    020000-023777  tx buffer (xu cpu / xubm write, bridge reads)
--    024000-027777  rx buffer (bridge writes, xu cpu / xubm read)
-- and a few registers in the xu cpu's local i/o page:
--    777200  csr    r: bit0 rxrdy, bit1 txbusy, bit2 hostup, bit15 fport
--                   w: bit0=1 releases the rx frame
--    777202  rxlen  bytes in the rx buffer
--    777204  txlen  write = transmit that many bytes from the tx buffer
--    777206  default mac, 3 words, wire order low byte first (read only)
--    777214  guest mac, 3 words (any write here or to mode publishes)
--    777222  mode   bit0 promiscuous, bit1 all-multicast
--
-- The b_* side runs on bclk (the ddr3 bridge clock). Control crosses as
-- toggles, synchronised in the receiving domain; lengths and macs are held
-- stable while their toggle is outstanding. Each signal has one writer.
--

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_unsigned.all;

entity xufp is
   port(
-- xu local memory bus (the buffers)
      mem_addr_match : out std_logic;
      mem_addr : in std_logic_vector(17 downto 0);
      mem_dati : out std_logic_vector(15 downto 0);
      mem_dato : in std_logic_vector(15 downto 0);
      mem_control_dati : in std_logic;
      mem_control_dato : in std_logic;
      mem_control_datob : in std_logic;

-- xu local i/o page (the registers)
      reg_addr_match : out std_logic;
      reg_addr : in std_logic_vector(17 downto 0);
      reg_dati : out std_logic_vector(15 downto 0);
      reg_dato : in std_logic_vector(15 downto 0);
      reg_control_dati : in std_logic;
      reg_control_dato : in std_logic;
      reg_control_datob : in std_logic;

-- bridge side, bclk domain
      bclk : in std_logic;
      b_tx_addr : in std_logic_vector(9 downto 0);
      b_tx_q : out std_logic_vector(15 downto 0);
      b_rx_addr : in std_logic_vector(9 downto 0);
      b_rx_d : in std_logic_vector(15 downto 0);
      b_rx_we : in std_logic;

-- handshakes and quasi-static values
      tx_req_t : out std_logic;                          -- xu -> bridge
      tx_len : out std_logic_vector(10 downto 0);
      tx_ack_t : in std_logic;                           -- bridge -> xu
      rx_rdy_t : in std_logic;                           -- bridge -> xu
      rx_len : in std_logic_vector(10 downto 0);
      rx_rel_t : out std_logic;                          -- xu -> bridge
      pub_t : out std_logic;                             -- xu -> bridge
      guest_mac : out std_logic_vector(47 downto 0);
      guest_mode : out std_logic_vector(7 downto 0);
      host_mac : in std_logic_vector(47 downto 0);
      host_valid : in std_logic;
      fport_en : in std_logic;

      reset : in std_logic;
      clk : in std_logic
   );
end xufp;

architecture implementation of xufp is

constant mem_base : std_logic_vector(17 downto 12) := "000010";     -- 020000
constant reg_base : std_logic_vector(17 downto 5) := o"7772" & "0"; -- 777200
constant fallback_mac : std_logic_vector(47 downto 0) := x"010000" & x"2B0008";  -- 08-00-2B-00-00-01

type byte_ram is array(0 to 1023) of std_logic_vector(7 downto 0);
signal tx_e : byte_ram := (others => (others => '0'));
signal tx_o : byte_ram := (others => (others => '0'));
signal rx_e : byte_ram := (others => (others => '0'));
signal rx_o : byte_ram := (others => (others => '0'));

signal mem_match : std_logic;
signal reg_match : std_logic;
signal tx_qa : std_logic_vector(15 downto 0);
signal rx_qa : std_logic_vector(15 downto 0);
signal sel_rx : std_logic := '0';

-- synchronisers into clk (names matched by the sdc: *xufp_s1*)
signal xufp_s1_txack, xufp_s2_txack : std_logic := '0';
signal xufp_s1_rxrdy, xufp_s2_rxrdy : std_logic := '0';
signal xufp_s1_hostv, xufp_s2_hostv : std_logic := '0';
signal xufp_s1_fpen, xufp_s2_fpen : std_logic := '0';

signal txreq : std_logic := '0';
signal rxrel : std_logic := '0';
signal pub : std_logic := '0';
signal txlen_r : std_logic_vector(10 downto 0) := (others => '0');
signal gmac : std_logic_vector(47 downto 0) := (others => '0');
signal gmode : std_logic_vector(7 downto 0) := (others => '0');

signal txbusy : std_logic;
signal rxrdy : std_logic;
signal dmac : std_logic_vector(47 downto 0);

begin

   mem_match <= '1' when mem_addr(17 downto 12) = mem_base else '0';
   mem_addr_match <= mem_match;
   reg_match <= '1' when reg_addr(17 downto 5) = reg_base else '0';
   reg_addr_match <= reg_match;

   tx_req_t <= txreq;
   tx_len <= txlen_r;
   rx_rel_t <= rxrel;
   pub_t <= pub;
   guest_mac <= gmac;
   guest_mode <= gmode;

   txbusy <= txreq xor xufp_s2_txack;
   rxrdy <= xufp_s2_rxrdy xor rxrel;
   dmac <= host_mac when xufp_s2_hostv = '1' else fallback_mac;

-- tx buffer: port a read/write on clk, port b read on bclk

   process(clk)
   begin
      if clk = '1' and clk'event then
         if mem_match = '1' and mem_addr(11) = '0' and mem_control_dato = '1' then
            if mem_control_datob = '0' or mem_addr(0) = '0' then
               tx_e(conv_integer(mem_addr(10 downto 1))) <= mem_dato(7 downto 0);
            end if;
            if mem_control_datob = '0' or mem_addr(0) = '1' then
               tx_o(conv_integer(mem_addr(10 downto 1))) <= mem_dato(15 downto 8);
            end if;
         end if;
         tx_qa <= tx_o(conv_integer(mem_addr(10 downto 1))) & tx_e(conv_integer(mem_addr(10 downto 1)));
         rx_qa <= rx_o(conv_integer(mem_addr(10 downto 1))) & rx_e(conv_integer(mem_addr(10 downto 1)));
         sel_rx <= mem_addr(11);
      end if;
   end process;

   mem_dati <= rx_qa when sel_rx = '1' else tx_qa;

-- bridge side of both buffers

   process(bclk)
   begin
      if bclk = '1' and bclk'event then
         b_tx_q <= tx_o(conv_integer(b_tx_addr)) & tx_e(conv_integer(b_tx_addr));
         if b_rx_we = '1' then
            rx_e(conv_integer(b_rx_addr)) <= b_rx_d(7 downto 0);
            rx_o(conv_integer(b_rx_addr)) <= b_rx_d(15 downto 8);
         end if;
      end if;
   end process;

-- registers

   process(clk)
   begin
      if clk = '1' and clk'event then
         xufp_s1_txack <= tx_ack_t;  xufp_s2_txack <= xufp_s1_txack;
         xufp_s1_rxrdy <= rx_rdy_t;  xufp_s2_rxrdy <= xufp_s1_rxrdy;
         xufp_s1_hostv <= host_valid; xufp_s2_hostv <= xufp_s1_hostv;
         xufp_s1_fpen <= fport_en;   xufp_s2_fpen <= xufp_s1_fpen;

         if reset = '1' then
-- equalise the toggles rather than clearing them, so a reset on this side
-- leaves nothing outstanding whatever state the bridge is in
            txreq <= xufp_s2_txack;
            rxrel <= xufp_s2_rxrdy;
            gmac <= (others => '0');
            gmode <= (others => '0');
         else
            if reg_match = '1' and reg_control_dati = '1' then
               case reg_addr(4 downto 1) is
                  when "0000" => reg_dati <= xufp_s2_fpen & "000000000000" & xufp_s2_hostv & txbusy & rxrdy;
                  when "0001" => reg_dati <= "00000" & rx_len;
                  when "0010" => reg_dati <= "00000" & txlen_r;
                  when "0011" => reg_dati <= dmac(15 downto 0);
                  when "0100" => reg_dati <= dmac(31 downto 16);
                  when "0101" => reg_dati <= dmac(47 downto 32);
                  when "0110" => reg_dati <= gmac(15 downto 0);
                  when "0111" => reg_dati <= gmac(31 downto 16);
                  when "1000" => reg_dati <= gmac(47 downto 32);
                  when "1001" => reg_dati <= x"00" & gmode;
                  when others => reg_dati <= (others => '0');
               end case;
            end if;

            if reg_match = '1' and reg_control_dato = '1' then
               case reg_addr(4 downto 1) is
                  when "0000" =>
                     if (reg_control_datob = '0' or reg_addr(0) = '0') and reg_dato(0) = '1' and rxrdy = '1' then
                        rxrel <= not rxrel;
                     end if;
                  when "0010" =>
                     if txbusy = '0' then
                        txlen_r <= reg_dato(10 downto 0);
                        txreq <= not txreq;
                     end if;
                  when "0110" | "0111" | "1000" | "1001" =>
                     if reg_control_datob = '0' or reg_addr(0) = '0' then
                        case reg_addr(4 downto 1) is
                           when "0110" => gmac(7 downto 0) <= reg_dato(7 downto 0);
                           when "0111" => gmac(23 downto 16) <= reg_dato(7 downto 0);
                           when "1000" => gmac(39 downto 32) <= reg_dato(7 downto 0);
                           when others => gmode <= reg_dato(7 downto 0);
                        end case;
                     end if;
                     if reg_control_datob = '0' or reg_addr(0) = '1' then
                        case reg_addr(4 downto 1) is
                           when "0110" => gmac(15 downto 8) <= reg_dato(15 downto 8);
                           when "0111" => gmac(31 downto 24) <= reg_dato(15 downto 8);
                           when "1000" => gmac(47 downto 40) <= reg_dato(15 downto 8);
                           when others => null;
                        end case;
                     end if;
                     pub <= not pub;
                  when others =>
                     null;
               end case;
            end if;
         end if;
      end if;
   end process;

end implementation;
