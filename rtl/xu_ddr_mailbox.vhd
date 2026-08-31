--
-- xu_ddr_mailbox.vhd -- DDR3 mailbox for XU native networking.
--
-- Bridges a cpuclk-domain request/response interface (used in Phase 1 by
-- xu_test_stub.vhd, and in Phase 2 by xu_enc424j600_shim.vhd -- same
-- interface, no changes needed here between phases) onto DDRAM_* (ram1),
-- clocked by clk50mhz. ram1 has no other master on this core -- no
-- arbiter needed.
--
-- CDC: level-held 2-FF synchronizer, ported from a2065_ddr3_mailbox.v's
-- real, shipping pattern (MiSTer-devel Minimig-AGA_MiSTer). req_ack/
-- resp_valid are held (not pulsed) until the requester withdraws
-- req_valid -- this is what makes the handshake independent of the ratio
-- between cpuclk (irregular, DRAM-FSM-gated) and clk50mhz (clean 50MHz).
-- One request in flight at a time: the REQUESTER is responsible for never
-- raising req_valid again until it has seen req_ack and dropped req_valid,
-- completing the previous handshake first.
--
-- req_addr is a byte offset within the 64KB window at physical
-- 0x1FF00000 (word address 0x03FE0000 on ram1's 64-bit, word-addressed
-- port). No lane repacking -- the port is naturally 64-bit/8-byte-enabled,
-- so req_wdata/req_be map directly onto DDRAM_DIN[63:0]/DDRAM_BE.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity xu_ddr_mailbox is
   port(
      reset : in std_logic;

      -- cpuclk-domain request/response interface
      cpuclk : in std_logic;
      req_valid : in std_logic;
      req_addr : in std_logic_vector(15 downto 0);  -- byte offset in window
      req_wdata : in std_logic_vector(63 downto 0);
      req_be : in std_logic_vector(7 downto 0);
      req_rw : in std_logic;                        -- '1' = write, '0' = read
      req_ack : out std_logic;
      resp_valid : out std_logic;
      resp_rdata : out std_logic_vector(63 downto 0);

      -- clk50mhz-domain DDRAM (ram1) interface, pdp2011.sv port convention
      clk50mhz : in std_logic;
      DDRAM_CLK : out std_logic;
      DDRAM_BUSY : in std_logic;
      DDRAM_BURSTCNT : out std_logic_vector(7 downto 0);
      DDRAM_ADDR : out std_logic_vector(28 downto 0);
      DDRAM_DOUT : in std_logic_vector(126 downto 0);
      DDRAM_DOUT_READY : in std_logic;
      DDRAM_RD : out std_logic;
      DDRAM_DIN : out std_logic_vector(126 downto 0);
      DDRAM_BE : out std_logic_vector(7 downto 0);
      DDRAM_WE : out std_logic
   );
end xu_ddr_mailbox;

architecture implementation of xu_ddr_mailbox is

   -- 0x1FF00000 >> 3, matches ao486/A2065's documented convention
   constant WINDOW_WORD_BASE : std_logic_vector(28 downto 0) := '0' & x"3FE0000";

   signal req_valid_meta : std_logic := '0';
   signal req_valid_sync : std_logic := '0';

   type state_type is (s_idle, s_write_cmd, s_read_cmd);
   signal state : state_type := s_idle;

   signal req_ack_i : std_logic := '0';
   signal resp_valid_i : std_logic := '0';
   signal resp_rdata_i : std_logic_vector(63 downto 0) := (others => '0');

begin

   DDRAM_CLK <= clk50mhz;
   req_ack <= req_ack_i;
   resp_valid <= resp_valid_i;
   resp_rdata <= resp_rdata_i;

   -- word address = WINDOW_WORD_BASE + (byte offset >> 3); low 3 bits of
   -- req_addr select the byte lane via req_be, not the word address.
   -- req_addr/wdata/be are cpuclk-domain; ram1 samples them on clk50mhz.
   -- req_valid's 2-FF delay is what makes them stable at command time.
   DDRAM_ADDR <= WINDOW_WORD_BASE + ("000000000000" & req_addr(15 downto 3));
   DDRAM_BURSTCNT <= x"01";
   -- Only [63:0] of DDRAM_DIN is real -- sys_top.v only wires a 64-bit net
   -- to DDRAM_DIN/DDRAM_DOUT despite the 127-bit port declaration.
   DDRAM_DIN <= (126 downto 64 => '0') & req_wdata;
   DDRAM_BE <= req_be;

   process(clk50mhz, reset)
   begin
      if reset = '1' then
         req_valid_meta <= '0';
         req_valid_sync <= '0';
         state <= s_idle;
         req_ack_i <= '0';
         resp_valid_i <= '0';
         resp_rdata_i <= (others => '0');
         DDRAM_WE <= '0';
         DDRAM_RD <= '0';
      elsif clk50mhz'event and clk50mhz = '1' then

         -- 2-FF synchronizer for the request level (cpuclk -> clk50mhz)
         req_valid_meta <= req_valid;
         req_valid_sync <= req_valid_meta;

         -- Held, not pulsed: ack/resp_valid drop only once the requester
         -- withdraws req_valid, completing the handshake on its own terms.
         if req_valid_sync = '0' then
            req_ack_i <= '0';
            resp_valid_i <= '0';
         end if;

         case state is

            when s_idle =>
               DDRAM_WE <= '0';
               DDRAM_RD <= '0';
               if req_valid_sync = '1' and req_ack_i = '0' then
                  if req_rw = '1' then
                     DDRAM_WE <= '1';
                     state <= s_write_cmd;
                  else
                     DDRAM_RD <= '1';
                     state <= s_read_cmd;
                  end if;
               end if;

            when s_write_cmd =>
               -- DDRAM_WE stays '1' (set above, held by default) until
               -- accepted; same-cycle waitrequest check, standard Avalon-MM.
               if DDRAM_BUSY = '0' then
                  DDRAM_WE <= '0';
                  req_ack_i <= '1';
                  resp_valid_i <= '1';
                  state <= s_idle;
               end if;

            when s_read_cmd =>
               -- REAL BUG fixed here (found via tb_shim_stream.vhd,
               -- 2026-08-28 -- the first test ever to exercise a real
               -- mailbox READ; every earlier passing test only exercised
               -- writes, which don't depend on DDRAM_DOUT_READY at all).
               -- The old two-state design (deassert DDRAM_RD once
               -- DDRAM_BUSY='0', THEN move to a separate state to check
               -- DDRAM_DOUT_READY) missed the ready pulse whenever it
               -- arrived the same cycle DDRAM_BUSY first read '0' --
               -- confirmed: DDRAM_DOUT_READY pulsed high while state was
               -- still s_read_cmd, then dropped again by the time state
               -- reached s_read_data, and the read hung forever. Fixed by
               -- checking DDRAM_DOUT_READY every cycle from here, not
               -- gated behind a separate later state -- correct
               -- regardless of exactly which cycle it arrives on relative
               -- to DDRAM_BUSY (this core has no documented guarantee of
               -- their exact relative timing on the real f2sdram hard IP
               -- either, so don't assume one).
               if DDRAM_BUSY = '0' then
                  DDRAM_RD <= '0';
               end if;
               if DDRAM_DOUT_READY = '1' then
                  resp_rdata_i <= DDRAM_DOUT(63 downto 0);
                  req_ack_i <= '1';
                  resp_valid_i <= '1';
                  state <= s_idle;
               end if;

         end case;
      end if;
   end process;

end implementation;
