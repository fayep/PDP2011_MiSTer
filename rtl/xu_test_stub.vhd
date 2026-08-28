--
-- xu_test_stub.vhd -- Phase 1 ONLY. Deleted before Phase 2.
--
-- Stands in for the not-yet-built SPI decode (xu_enc424j600_shim.vhd),
-- exercising xu_ddr_mailbox.vhd's real req_* interface with a fixed test
-- sequence against the real offset table
-- (/Users/faye/.claude/plans/keen-sauteeing-dolphin.md):
--
--   1. write a known 8-byte pattern into the TX buffer at 0x0000
--   2. write ETXST=0x0000 (0x6018), ETXLEN=8 (0x6020)
--   3. write TXRTS_REQ=1 (0x6008) -- sole writer, per the offset table's
--      ownership fix
--   4. loop reading TXRTS_DONE (0x6010) until it reads 1
--   5. write TXRTS_REQ=0, completing the two-field handshake
--   6. assert dbg_pass
--
-- Runs entirely in the cpuclk domain (matching xubl.vhd's own domain, per
-- the plan's clocking discussion). Follows the CDC's requester-side rule
-- explicitly: never raise req_valid again until req_ack has been seen and
-- req_valid dropped, completing the previous handshake first.
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity xu_test_stub is
   port(
      reset : in std_logic;
      cpuclk : in std_logic;

      req_valid : out std_logic;
      req_addr : out std_logic_vector(15 downto 0);
      req_wdata : out std_logic_vector(63 downto 0);
      req_be : out std_logic_vector(7 downto 0);
      req_rw : out std_logic;
      req_ack : in std_logic;
      resp_valid : in std_logic;
      resp_rdata : in std_logic_vector(63 downto 0);

      dbg_pass : out std_logic;
      dbg_step : out std_logic_vector(3 downto 0)  -- last completed step, for probing
   );
end xu_test_stub;

architecture implementation of xu_test_stub is

   constant ADDR_TX_BUF    : std_logic_vector(15 downto 0) := x"0000";
   constant ADDR_TXRTS_REQ : std_logic_vector(15 downto 0) := x"6008";
   constant ADDR_TXRTS_DONE: std_logic_vector(15 downto 0) := x"6010";
   constant ADDR_ETXST     : std_logic_vector(15 downto 0) := x"6018";
   constant ADDR_ETXLEN    : std_logic_vector(15 downto 0) := x"6020";

   constant TEST_PATTERN : std_logic_vector(63 downto 0) := x"DEADBEEFCAFEBABE";

   -- Bounded retry on the TXRTS_DONE poll, matching chkeudast's own real
   -- 10-retry discipline (roms/xubrt45.mac) -- without this the stub polls
   -- the DDR3 mailbox every cpuclk cycle forever whenever nothing (no
   -- xu_ddr_probe.c) is running to service it, which is real, sustained
   -- DDRAM_WE/RD traffic for the entire time the core runs, not a
   -- harmless idle loop.
   constant MAX_RETRIES : integer := 10;
   signal retry_count : integer range 0 to MAX_RETRIES := 0;

   -- sequencer step: which request is being issued
   type step_type is (
      st_wr_pattern, st_wr_etxst, st_wr_etxlen, st_wr_txrts_req,
      st_rd_txrts_done, st_wr_txrts_req_clear, st_done, st_timeout
   );
   signal step : step_type := st_wr_pattern;

   -- per-request handshake phase, per the requester-side CDC rule: issue,
   -- wait for ack, then drop req_valid and wait for ack to drop too, before
   -- moving to the next step.
   type phase_type is (ph_issue, ph_wait_ack, ph_wait_ack_drop);
   signal phase : phase_type := ph_issue;

   signal req_valid_i : std_logic := '0';
   signal req_addr_i : std_logic_vector(15 downto 0) := (others => '0');
   signal req_wdata_i : std_logic_vector(63 downto 0) := (others => '0');
   signal req_be_i : std_logic_vector(7 downto 0) := (others => '0');
   signal req_rw_i : std_logic := '0';

   signal dbg_pass_i : std_logic := '0';

begin

   req_valid <= req_valid_i;
   req_addr <= req_addr_i;
   req_wdata <= req_wdata_i;
   req_be <= req_be_i;
   req_rw <= req_rw_i;
   dbg_pass <= dbg_pass_i;

   process(cpuclk, reset)
   begin
      if reset = '1' then
         step <= st_wr_pattern;
         phase <= ph_issue;
         retry_count <= 0;
         req_valid_i <= '0';
         req_addr_i <= (others => '0');
         req_wdata_i <= (others => '0');
         req_be_i <= (others => '0');
         req_rw_i <= '0';
         dbg_pass_i <= '0';
         dbg_step <= (others => '0');
      elsif cpuclk'event and cpuclk = '1' then

         case phase is

            when ph_issue =>
               req_valid_i <= '1';
               case step is
                  when st_wr_pattern =>
                     req_addr_i <= ADDR_TX_BUF;
                     req_wdata_i <= TEST_PATTERN;
                     req_be_i <= x"FF";
                     req_rw_i <= '1';
                  when st_wr_etxst =>
                     req_addr_i <= ADDR_ETXST;
                     req_wdata_i <= (others => '0');  -- ETXST = 0x0000
                     req_be_i <= x"FF";
                     req_rw_i <= '1';
                  when st_wr_etxlen =>
                     req_addr_i <= ADDR_ETXLEN;
                     req_wdata_i <= x"0000000000000008";  -- ETXLEN = 8
                     req_be_i <= x"FF";
                     req_rw_i <= '1';
                  when st_wr_txrts_req =>
                     req_addr_i <= ADDR_TXRTS_REQ;
                     req_wdata_i <= x"0000000000000001";
                     req_be_i <= x"FF";
                     req_rw_i <= '1';
                  when st_rd_txrts_done =>
                     req_addr_i <= ADDR_TXRTS_DONE;
                     req_be_i <= x"FF";
                     req_rw_i <= '0';
                  when st_wr_txrts_req_clear =>
                     req_addr_i <= ADDR_TXRTS_REQ;
                     req_wdata_i <= (others => '0');
                     req_be_i <= x"FF";
                     req_rw_i <= '1';
                  when st_done | st_timeout =>
                     req_valid_i <= '0';
               end case;
               if step = st_timeout then
                  -- gave up already; no request in flight, nothing to wait on
                  null;
               elsif req_ack = '1' then
                  phase <= ph_wait_ack_drop;
                  -- for the read step, latch whether it succeeded before
                  -- dropping req_valid (resp_rdata is only valid while
                  -- resp_valid/req_ack are held).
                  if step = st_rd_txrts_done then
                     if resp_rdata(0) = '1' then
                        step <= st_wr_txrts_req_clear;
                     elsif retry_count = MAX_RETRIES - 1 then
                        step <= st_timeout;
                     else
                        retry_count <= retry_count + 1;
                        -- else: stay on st_rd_txrts_done, poll again next round
                     end if;
                  else
                     case step is
                        when st_wr_pattern         => step <= st_wr_etxst;
                        when st_wr_etxst           => step <= st_wr_etxlen;
                        when st_wr_etxlen          => step <= st_wr_txrts_req;
                        when st_wr_txrts_req       => retry_count <= 0;
                                                       step <= st_rd_txrts_done;
                        when st_wr_txrts_req_clear => step <= st_done;
                        when others                => null;
                     end case;
                  end if;
               end if;

            when ph_wait_ack_drop =>
               req_valid_i <= '0';
               if req_ack = '0' then
                  if step = st_done then
                     dbg_pass_i <= '1';
                  else
                     phase <= ph_issue;
                  end if;
               end if;

            when ph_wait_ack =>
               null; -- unused, reserved

         end case;

         case step is
            when st_wr_pattern         => dbg_step <= "0001";
            when st_wr_etxst           => dbg_step <= "0010";
            when st_wr_etxlen          => dbg_step <= "0011";
            when st_wr_txrts_req       => dbg_step <= "0100";
            when st_rd_txrts_done      => dbg_step <= "0101";
            when st_wr_txrts_req_clear => dbg_step <= "0110";
            when st_done               => dbg_step <= "0111";
            when st_timeout            => dbg_step <= "1000";
         end case;

      end if;
   end process;

end implementation;
