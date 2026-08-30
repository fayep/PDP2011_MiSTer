--
-- xu_enc424j600_shim.vhd -- Phase 2: real SPI decoder standing in for a
-- physical ENC424J600 chip, replacing rtl/xu_test_stub.vhd. See
-- /Users/faye/.claude/plans/keen-sauteeing-dolphin.md.
--
-- Scope, per Faye's explicit direction: "enough support to recognize the
-- interface" -- i.e. make roms/xubrt45.mac's real initenc/chkeudast
-- sequence succeed (so BSD's de0 attach completes), not full RX/TX
-- packet streaming yet. Registers actually touched by that sequence
-- (verified directly against xubrt45.mac, not assumed):
--   EUDAST  (chkeudast: WCRU write, RCRU read back, must match exactly;
--            also cleared to 0 by ECON2's ETHRST bit -- a real, required
--            side effect, not cosmetic: initenc checks this after reset)
--   ESTAT   (bit 12, clkrdy, must read back set)
--   ECON2   (BFSU sets ETHRST, bit 4 -- 020 octal mask in qecon2)
--   ECON1   (BFSU sets RXEN, bit 0 -- xecon1; BFSU sets TXRTS, bit 1 --
--            tecon1; presented from local flags, not a stored DDR3 word,
--            per the offset table's ownership fix)
--   MAADR3..5 (RCRU at address 0x60, 6 bytes/3 words, auto-incrementing --
--            confirmed via roms/xubrt45.lst: "maadr3l" assembles to the
--            same address as "maadr3", 0140 octal -- old assembler's
--            6-significant-character symbol truncation)
--   ERXST, ERXTAIL (WCRU, single word each)
-- Every other enumerated register (EGPWRPT, ERXFCON, MACON1, EIDLED,
-- ERXRDPT) is a plain shim-local 16-bit store-and-echo with no special
-- behavior -- xud's own BPF filtering does real frame filtering at the
-- AF_PACKET level (Phase 3), so no functional effect is needed here.
--
-- MAC handling, intentionally simplified for this scope: presents the
-- hardcoded placeholder MAC always. Reading the real, daemon-published
-- MAC_ADDR/MAC_VALID from DDR3 is deferred to when Phase 3's daemon
-- actually exists to publish one -- until then MAC_VALID is always 0 in
-- DDR3 anyway, so the placeholder is the only value that could ever be
-- correct right now, and this keeps the DDR3 mailbox sequencer simple.
--
-- Clocking: cpuclk, same domain as xubl.vhd's own two processes (this is
-- not a new domain choice -- established this session: xu_sclk = nclk =
-- not(cpuclk), so clocking on cpuclk's rising edge automatically
-- implements correct SPI Mode 0,0 slave sampling with zero extra
-- synchronizer).
--
-- DDR3 crossing: uses xu_ddr_mailbox.vhd's req_* interface, same as
-- xu_test_stub.vhd did -- one request in flight at a time, this module
-- never raises req_valid again until the previous handshake fully
-- completes (drops req_valid, sees req_ack drop). Two request sources
-- share this one interface: foreground (SPI-driven register writes) and
-- a low-rate background poll of TXRTS_DONE, throttled by a free-running
-- counter -- NOT polled every cycle unconditionally, which is exactly
-- the bug just fixed in xu_test_stub.vhd (that hammered the mailbox
-- forever and kept the core from ever reaching disk boot). Single
-- process throughout (SPI shifter and mailbox sequencer share several
-- signals -- econ1_txrts, fg_pending -- and both run on cpuclk anyway,
-- so there is no reason to split them and every reason not to: VHDL
-- doesn't allow two processes to drive the same signal).
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity xu_enc424j600_shim is
   port(
      reset : in std_logic;
      cpuclk : in std_logic;

      -- real SPI pins, same 4 signals xubl.vhd already drives/samples
      xu_cs : in std_logic;
      xu_mosi : in std_logic;
      xu_sclk : in std_logic;  -- not used as a clock net -- sampled as data
      xu_miso : out std_logic;

      -- DDR3 mailbox request/response interface (xu_ddr_mailbox.vhd)
      req_valid : out std_logic;
      req_addr : out std_logic_vector(15 downto 0);
      req_wdata : out std_logic_vector(63 downto 0);
      req_be : out std_logic_vector(7 downto 0);
      req_rw : out std_logic;
      req_ack : in std_logic;
      resp_valid : in std_logic;
      resp_rdata : in std_logic_vector(63 downto 0)
   );
end xu_enc424j600_shim;

architecture implementation of xu_enc424j600_shim is

   -- opcodes (from roms/xubrt45.mac's own symbol table, octal -> hex,
   -- cross-checked against the datasheet's real firmware byte templates)
   constant OP_RCRU    : std_logic_vector(7 downto 0) := x"20";
   constant OP_WCRU    : std_logic_vector(7 downto 0) := x"22";
   constant OP_BFSU    : std_logic_vector(7 downto 0) := x"24";
   constant OP_BFCU    : std_logic_vector(7 downto 0) := x"26";
   constant OP_B0SEL   : std_logic_vector(7 downto 0) := x"C0";
   -- REAL BUG fixed here (found by checking roms/xubrt45.mac's actual
   -- symbol table before implementing, 2026-08-28): these two were x"1C"/
   -- x"1A" per the plan's own (unverified) text. The firmware's real
   -- values are wgpdata=052 octal, rrxdata=054 octal -- 0x2A/0x2C, not
   -- 0x1A/0x1C. Caught before ever building against the wrong opcodes.
   constant OP_WGPDATA   : std_logic_vector(7 downto 0) := x"2A";
   constant OP_RRXDATA   : std_logic_vector(7 downto 0) := x"2C";
   constant OP_SETPKTDEC : std_logic_vector(7 downto 0) := x"CC";

   -- register addresses (same source, same conversion)
   constant ADDR_ETXST    : std_logic_vector(7 downto 0) := x"00";
   constant ADDR_ETXLEN   : std_logic_vector(7 downto 0) := x"02";
   constant ADDR_ERXST    : std_logic_vector(7 downto 0) := x"04";
   constant ADDR_ERXTAIL  : std_logic_vector(7 downto 0) := x"06";
   constant ADDR_ESTAT    : std_logic_vector(7 downto 0) := x"1A";
   constant ADDR_ECON1    : std_logic_vector(7 downto 0) := x"1E";
   constant ADDR_ERXFCON  : std_logic_vector(7 downto 0) := x"34";
   constant ADDR_EUDAST   : std_logic_vector(7 downto 0) := x"36";
   constant ADDR_MACON1   : std_logic_vector(7 downto 0) := x"40";
   constant ADDR_MAADR3   : std_logic_vector(7 downto 0) := x"60";
   constant ADDR_ECON2    : std_logic_vector(7 downto 0) := x"6E";
   constant ADDR_EIDLED   : std_logic_vector(7 downto 0) := x"74";
   constant ADDR_EGPWRPT  : std_logic_vector(7 downto 0) := x"88";
   constant ADDR_ERXRDPT  : std_logic_vector(7 downto 0) := x"8A";

   -- DDR3 mailbox offsets (rtl/xu_ddr_mailbox.vhd's window, see the plan's
   -- offset table)
   constant DDR_RXEN        : std_logic_vector(15 downto 0) := x"6000";
   constant DDR_TXRTS_REQ   : std_logic_vector(15 downto 0) := x"6008";
   constant DDR_TXRTS_DONE  : std_logic_vector(15 downto 0) := x"6010";
   constant DDR_ETXST       : std_logic_vector(15 downto 0) := x"6018";
   constant DDR_ETXLEN      : std_logic_vector(15 downto 0) := x"6020";
   constant DDR_ERXST       : std_logic_vector(15 downto 0) := x"6028";
   constant DDR_ERXHEAD     : std_logic_vector(15 downto 0) := x"6030";
   constant DDR_ERXTAIL     : std_logic_vector(15 downto 0) := x"6038";
   constant DDR_MAC_ADDR    : std_logic_vector(15 downto 0) := x"6040";
   constant DDR_MAC_VALID   : std_logic_vector(15 downto 0) := x"6048";

   -- hardcoded placeholder MAC (real DEC OUI 08-00-2B, never the
   -- zero/garbage pattern) -- see MAC-handling note above.
   -- Bit layout is canonical MAC byte order, same convention as
   -- reg_mac_addr/xu.cpp's macword: bits(7:0)=canonical byte0(OUI0)=08,
   -- (15:8)=byte1=00, (23:16)=byte2=2B, (31:24)=byte3=AA, (39:32)=byte4=AA,
   -- (47:40)=byte5=AA. ADDR_MAADR3's byte-serving logic below reverses
   -- this into the real chip's actual wire order (DS39935C Table 3-7).
   constant PLACEHOLDER_MAC : std_logic_vector(47 downto 0) := x"AAAAAA2B0008";

   ----------------------------------------------------------------------
   -- SPI byte/word shift engine
   ----------------------------------------------------------------------
   type spi_state_type is (
      s_opcode, s_addr, s_data_in, s_data_out, s_stream_in, s_stream_out,
      s_ignore
   );
   signal spi_state : spi_state_type := s_opcode;

   signal shift_in : std_logic_vector(7 downto 0) := (others => '0');
   signal shift_out : std_logic_vector(7 downto 0) := (others => '0');
   signal bit_count : integer range 0 to 7 := 0;
   signal xu_miso_i : std_logic := '0';

   signal cur_opcode : std_logic_vector(7 downto 0) := (others => '0');
   signal cur_addr : std_logic_vector(7 downto 0) := (others => '0');
   -- byte index within the current RCRU response: 0/1 for ordinary 2-byte
   -- registers, 0..5 for MAADR3's 6-byte MAC read. REAL BUG fixed here
   -- (found via real firmware's MAC print, 2026-08-28): this used to be
   -- range 0 to 2 and select MAADR3 bytes at 16-bit strides (bytes 0,2,4
   -- only), silently repeating the 3rd byte for the remaining 3 requested
   -- bytes instead of serving all 6 real, distinct bytes.
   signal word_count : integer range 0 to 5 := 0;
   signal cur_word : std_logic_vector(15 downto 0) := (others => '0');

   ----------------------------------------------------------------------
   -- local register file (plain store-and-echo, no special behavior)
   ----------------------------------------------------------------------
   signal reg_erxfcon : std_logic_vector(15 downto 0) := (others => '0');
   signal reg_macon1  : std_logic_vector(15 downto 0) := (others => '0');
   -- real datasheet POR reset value (Register 8-2): LACFG<3:0>=0010,
   -- LBCFG<3:0>=0110, DEVID<2:0>=001 (ENC624J600 family), REVID<4:0>
   -- undocumented/varies by silicon lot, left 0 -- NOT all-zero, which
   -- firmware's periodic health check (roms/xubrt45.mac's "cannot read
   -- eidled" test, tst deidled/bne) treats as "communication lost"
   -- (real bug found on real hardware, 2026-08-28, after the cpuclk fix
   -- got far enough to reach this check for the first time).
   signal reg_eidled  : std_logic_vector(15 downto 0) := x"2620";
   signal reg_egpwrpt : std_logic_vector(15 downto 0) := (others => '0');
   signal reg_erxrdpt : std_logic_vector(15 downto 0) := (others => '0');
   signal reg_eudast  : std_logic_vector(15 downto 0) := (others => '0');

   -- econ1: presented from local flags, never a stored shared word
   signal econ1_rxen  : std_logic := '0';
   signal econ1_txrts : std_logic := '0';

   ----------------------------------------------------------------------
   -- RX packet-count tracking (ESTAT<7:0>, real firmware's primary RX
   -- gate -- roms/xubrt45.mac reads this FIRST, before anything else, to
   -- decide whether a frame is even waiting; see conversation, 2026-08-28).
   -- DDR_ERXHEAD is the daemon's own monotonic count of frames enqueued
   -- (not a byte pointer, despite the name mirroring the real chip's own
   -- ERXHEAD register -- see the plan's offset table). PKTCNT is derived
   -- locally, never stored as its own DDR3 field, avoiding the same
   -- two-writer hazard the offset table's other fields were designed
   -- around: reg_erxhead_ddr (background-polled mirror of the daemon's
   -- count) minus reg_pkt_delivered (incremented once per real firmware
   -- SETPKTDEC, i.e. once per frame firmware has finished processing).
   ----------------------------------------------------------------------
   signal reg_erxhead_ddr  : std_logic_vector(15 downto 0) := (others => '0');
   signal reg_pkt_delivered : std_logic_vector(15 downto 0) := (others => '0');

   ----------------------------------------------------------------------
   -- daemon-published MAC (Phase 3): presents PLACEHOLDER_MAC until the
   -- real daemon publishes one via MAC_VALID/MAC_ADDR, matching the real
   -- boot-ordering hazard fix already designed (XU's embedded CPU can
   -- read the MAC before the daemon has started -- the placeholder is
   -- always syntactically valid, never the zero/garbage pattern, so
   -- either ordering is safe). mac_addr_fetched latches once true --
   -- MAC_ADDR is write-once at daemon startup, no need to keep re-polling.
   ----------------------------------------------------------------------
   signal reg_mac_addr    : std_logic_vector(47 downto 0) := (others => '0');
   signal mac_valid_local : std_logic := '0';
   signal mac_addr_fetched : std_logic := '0';

   ----------------------------------------------------------------------
   -- mailbox request queue (foreground SPI ops + background TXRTS_DONE
   -- poll share the one mailbox port; one process, one driver, per the
   -- header note above)
   ----------------------------------------------------------------------
   type mbox_req_type is (mr_none, mr_rxen, mr_txrts_req_set, mr_txrts_req_clear,
                           mr_etxst, mr_etxlen, mr_erxst, mr_erxtail,
                           mr_txrts_done_poll, mr_stream_write, mr_stream_prefetch,
                           mr_erxhead_poll, mr_mac_valid_poll, mr_mac_addr_poll);
   signal fg_pending : mbox_req_type := mr_none;
   signal fg_wdata : std_logic_vector(63 downto 0) := (others => '0');

   type mbox_state_type is (m_idle, m_issue, m_wait_ack_drop);
   signal mbox_state : mbox_state_type := m_idle;
   signal mbox_active : mbox_req_type := mr_none;

   signal req_valid_i : std_logic := '0';
   signal req_addr_i : std_logic_vector(15 downto 0) := (others => '0');
   signal req_wdata_i : std_logic_vector(63 downto 0) := (others => '0');
   signal req_be_i : std_logic_vector(7 downto 0) := x"FF";
   signal req_rw_i : std_logic := '0';

   ----------------------------------------------------------------------
   -- RRXDATA/WGPDATA streaming buffer I/O (real ENC424J600 SPI protocol,
   -- Microchip DS39935C S4.0/S9.0): opcode-only, no address byte, byte
   -- count implied by CS duration. WGPDATA writes at reg_egpwrpt,
   -- auto-incrementing; RRXDATA reads at reg_erxrdpt, auto-incrementing.
   -- Both pointers are already-existing shim-local registers (settable
   -- via WCRU werxrdpt/wegpwr, matching real firmware -- see the file
   -- header's register list).
   ----------------------------------------------------------------------
   signal stream_write_addr : std_logic_vector(15 downto 0) := (others => '0');
   signal stream_write_data : std_logic_vector(7 downto 0) := (others => '0');

   -- RRXDATA: real bug fixed here (found 2026-08-29, real hardware --
   -- watchdog reset ["dog barks"] immediately after the driver issued
   -- pcsr0 START, first real exposure of this path to unscripted traffic
   -- timing). The old design issued one DDR3 mailbox round trip PER BYTE
   -- and only ever checked stream_byte_valid on the very first byte of a
   -- transaction -- every subsequent byte served/advanced unconditionally,
   -- with no check the round trip had actually landed. Since this is an
   -- SPI *slave* clocked by the real master's fixed-rate SCK (xubl.vhd),
   -- there is no way to insert a wait state: every byte has a hard 8-
   -- cpuclk-cycle deadline. A real DDR3 access via the HPS bridge can
   -- easily exceed that under contention (this was flagged, unverified,
   -- in the plan's own Phase 2 open items). Fix: the mailbox already
   -- returns a full 64-bit (8-byte) word per read -- cache the whole
   -- aligned word and serve all 8 bytes from it with zero further round
   -- trips, and double-buffer: as soon as the shim starts consuming a
   -- cached word (its first byte), kick off a background fetch of the
   -- NEXT aligned word into a second slot, so the round trip gets the
   -- full ~64-cycle word-time as its deadline instead of 8. rx_cur_* is
   -- what's actively being served; rx_nxt_* is the in-flight lookahead,
   -- swapped into rx_cur once exhausted (lane 7 served) if it landed in
   -- time. A miss (nxt not ready when needed) falls back to serving 0 and
   -- re-fetching -- the same fail-safe behavior the old code already had
   -- for its single, harder 8-cycle deadline, just now a rare edge case
   -- instead of the common one.
   signal rx_cur_data    : std_logic_vector(63 downto 0) := (others => '0');
   signal rx_cur_tag     : std_logic_vector(12 downto 0) := (others => '0');
   signal rx_cur_valid   : std_logic := '0';
   signal rx_nxt_data    : std_logic_vector(63 downto 0) := (others => '0');
   signal rx_nxt_tag     : std_logic_vector(12 downto 0) := (others => '0');
   signal rx_nxt_valid   : std_logic := '0';
   signal rx_nxt_pending : std_logic := '0';
   signal rx_fetch_addr   : std_logic_vector(15 downto 0) := (others => '0');
   signal rx_fetch_is_nxt : std_logic := '0';
   -- REAL BUG fixed here (found in simulation, tb_shim_rrx_latency.vhd,
   -- 2026-08-29, before ever reaching hardware): the generic priming
   -- fetch below was meant to fire once per CS-low transaction, but
   -- bit_count=0 actually recurs once per OPCODE BYTE within s_opcode --
   -- B0SEL and the real opcode that follows it (RRXDATA/WGPDATA/
   -- SETPKTDEC) are two separate bytes, each with their own bit_count=0.
   -- The redundant second fetch it caused was harmless in the old
   -- single-byte design (same address, no side effect beyond a wasted
   -- fetch) but is actively harmful now: with only one request in flight
   -- at a time, it can occupy the mailbox slot at exactly the moment the
   -- real word1 lookahead (rx_nxt) needs to be issued, starving the very
   -- prefetch this fix depends on. Latched: fires once per CS-low
   -- transaction, cleared by the xu_cs='1' branch above (same place
   -- spi_state/bit_count/word_count already reset).
   signal rx_primed : std_logic := '0';

   -- background poll throttle -- NOT every cycle (that was the bug).
   -- Free-running counter; poll only when it wraps and nothing
   -- foreground is pending.
   constant BG_POLL_PERIOD : integer := 65535;
   signal bg_counter : integer range 0 to BG_POLL_PERIOD := 0;

begin

   xu_miso <= xu_miso_i;
   req_valid <= req_valid_i;
   req_addr <= req_addr_i;
   req_wdata <= req_wdata_i;
   req_be <= req_be_i;
   req_rw <= req_rw_i;

   process(cpuclk, reset)
      variable estat_val : std_logic_vector(15 downto 0);
      variable in_byte : std_logic_vector(7 downto 0);
      variable out_byte : std_logic_vector(7 downto 0);
      variable cur_mac : std_logic_vector(47 downto 0);
   begin
      if reset = '1' then

         spi_state <= s_opcode;
         bit_count <= 0;
         word_count <= 0;
         xu_miso_i <= '0';
         shift_in <= (others => '0');
         shift_out <= (others => '0');
         cur_opcode <= (others => '0');
         cur_addr <= (others => '0');
         cur_word <= (others => '0');

         reg_erxfcon <= (others => '0');
         reg_macon1 <= (others => '0');
         reg_eidled <= x"2620";  -- real datasheet POR value, see signal comment above
         reg_egpwrpt <= (others => '0');
         reg_erxrdpt <= (others => '0');
         reg_eudast <= (others => '0');
         econ1_rxen <= '0';
         econ1_txrts <= '0';
         reg_erxhead_ddr <= (others => '0');
         reg_pkt_delivered <= (others => '0');
         reg_mac_addr <= (others => '0');
         mac_valid_local <= '0';
         mac_addr_fetched <= '0';

         fg_pending <= mr_none;
         fg_wdata <= (others => '0');
         mbox_state <= m_idle;
         mbox_active <= mr_none;
         req_valid_i <= '0';
         req_addr_i <= (others => '0');
         req_wdata_i <= (others => '0');
         req_be_i <= x"FF";
         req_rw_i <= '0';
         bg_counter <= 0;
         stream_write_addr <= (others => '0');
         stream_write_data <= (others => '0');
         rx_cur_data <= (others => '0');
         rx_cur_tag <= (others => '0');
         rx_cur_valid <= '0';
         rx_nxt_data <= (others => '0');
         rx_nxt_tag <= (others => '0');
         rx_nxt_valid <= '0';
         rx_nxt_pending <= '0';
         rx_fetch_addr <= (others => '0');
         rx_fetch_is_nxt <= '0';
         rx_primed <= '0';

      elsif cpuclk'event and cpuclk = '1' then

         ----------------------------------------------------------------
         -- SPI shift engine
         ----------------------------------------------------------------
         if xu_cs = '1' then
            spi_state <= s_opcode;
            bit_count <= 0;
            word_count <= 0;
            rx_primed <= '0';
         else
            -- REAL BUG fixed here (found via tb_shim_real_master.vhd,
            -- 2026-08-27): a previous separate branch here (cs_prev='1'
            -- and xu_cs='0') spent the first cycle of every transaction
            -- purely on state reset without sampling xu_mosi. But
            -- xubl.vhd (the real master) asserts cs and the first real
            -- data bit on the SAME edge -- there is no settling cycle.
            -- That branch caused the shim to permanently sample one bit
            -- late for the rest of every transaction (confirmed: it
            -- captured the true opcode byte rotated left by one bit,
            -- e.g. 0x22 -> 0x44). No separate reset is actually needed
            -- here: spi_state/bit_count/word_count are already correctly
            -- primed to s_opcode/0/0 by the xu_cs='1' branch above,
            -- continuously, throughout the preceding idle-high period --
            -- so falling straight into real sampling on the very first
            -- low cycle is already correct.

            in_byte := shift_in(6 downto 0) & xu_mosi;
            shift_in <= in_byte;

            case spi_state is

               when s_opcode =>
                  xu_miso_i <= '0';
                  if bit_count = 7 then
                     cur_opcode <= in_byte;
                     bit_count <= 0;
                     if in_byte = OP_B0SEL then
                        -- REAL BUG fixed here (found by reading real
                        -- firmware usage before implementing streaming
                        -- I/O, 2026-08-28): B0SEL is never sent standalone
                        -- in practice -- every real RRXDATA/WGPDATA/
                        -- SETPKTDEC call sends B0SEL as a one-byte prefix
                        -- immediately followed by the real opcode, all
                        -- within the same CS-low transaction (confirmed:
                        -- roms/xubrt45.mac's rpkth/rnpp/rdata/decpc
                        -- templates are all ".byte b0sel,<realop>", sent
                        -- as one contiguous xubl transmit). Treating it as
                        -- "consume rest of transaction" (the old code)
                        -- would silently eat the real opcode that always
                        -- follows it. Stay in s_opcode instead -- bit_count
                        -- is already 0 from the assignment above, ready
                        -- for the next opcode byte.
                        spi_state <= s_opcode;
                     elsif in_byte = OP_RCRU or in_byte = OP_WCRU
                        or in_byte = OP_BFSU or in_byte = OP_BFCU then
                        spi_state <= s_addr;
                     elsif in_byte = OP_WGPDATA then
                        spi_state <= s_stream_in;
                     elsif in_byte = OP_RRXDATA then
                        -- same zero-turnaround-latency requirement as the
                        -- RCRU fix above -- pre-drive the first response
                        -- bit now, served from the word cache (see
                        -- rx_cur_data's declaration comment), since
                        -- RRXDATA has no address byte to hide the DDR3
                        -- round-trip in.
                        spi_state <= s_stream_out;
                        bit_count <= 1;
                        if rx_cur_valid = '1' and rx_cur_tag = reg_erxrdpt(15 downto 3) then
                           case reg_erxrdpt(2 downto 0) is
                              when "000" => out_byte := rx_cur_data(7 downto 0);
                              when "001" => out_byte := rx_cur_data(15 downto 8);
                              when "010" => out_byte := rx_cur_data(23 downto 16);
                              when "011" => out_byte := rx_cur_data(31 downto 24);
                              when "100" => out_byte := rx_cur_data(39 downto 32);
                              when "101" => out_byte := rx_cur_data(47 downto 40);
                              when "110" => out_byte := rx_cur_data(55 downto 48);
                              when others => out_byte := rx_cur_data(63 downto 56);
                           end case;
                           xu_miso_i <= out_byte(7);
                           shift_out <= out_byte(6 downto 0) & '0';
                        else
                           -- cache miss (priming fetch for a brand new
                           -- word didn't land in time -- shouldn't happen
                           -- given the opcode byte's full 8-cycle lead
                           -- time, but fail safe rather than serve X)
                           xu_miso_i <= '0';
                           shift_out <= (others => '0');
                        end if;

                        -- shared advance/lookahead/exhaustion logic (see
                        -- rx_cur_data's declaration comment) -- duplicated
                        -- here and in s_stream_out's own bit_count=0
                        -- branch for the same zero-latency reason the RCRU
                        -- fix above duplicates its own logic.
                        reg_erxrdpt <= reg_erxrdpt + 1;
                        if reg_erxrdpt(2 downto 0) = "000" and rx_nxt_pending = '0'
                           and not (rx_nxt_valid = '1' and rx_nxt_tag = reg_erxrdpt(15 downto 3) + 1)
                           and fg_pending = mr_none then
                           fg_pending <= mr_stream_prefetch;
                           rx_fetch_addr <= (reg_erxrdpt(15 downto 3) + 1) & "000";
                           rx_fetch_is_nxt <= '1';
                           rx_nxt_pending <= '1';
                        end if;
                        if reg_erxrdpt(2 downto 0) = "111" then
                           if rx_nxt_valid = '1' and rx_nxt_tag = reg_erxrdpt(15 downto 3) + 1 then
                              rx_cur_data <= rx_nxt_data;
                              rx_cur_tag <= rx_nxt_tag;
                              rx_cur_valid <= '1';
                              rx_nxt_valid <= '0';
                           else
                              rx_cur_valid <= '0';
                           end if;
                        end if;
                     elsif in_byte = OP_SETPKTDEC then
                        -- real effect: one more frame considered
                        -- delivered/processed by firmware -- pktcnt_local
                        -- (ESTAT<7:0>) is derived as reg_erxhead_ddr minus
                        -- reg_pkt_delivered, so incrementing the delivered
                        -- count here decrements the locally-presented
                        -- PKTCNT by 1, matching the real chip's PKTDEC
                        -- action (Register 9-1 ECON1 bit 8).
                        reg_pkt_delivered <= reg_pkt_delivered + 1;
                        spi_state <= s_ignore;
                     else
                        -- unimplemented (setpktdec's real effect, etc) --
                        -- consume and ignore rather than hang.
                        spi_state <= s_ignore;
                     end if;
                  else
                     -- speculative RRXDATA prefetch: fires exactly once
                     -- per transaction, on the very first real bit (the
                     -- only cycle where spi_state=s_opcode and
                     -- bit_count=0 -- reliable single-shot condition,
                     -- since s_opcode never revisits bit_count=0 within
                     -- the same 8-cycle byte). Speculative because the
                     -- opcode isn't known yet; harmlessly unused if it
                     -- turns out not to be RRXDATA (see rx_cur_data's
                     -- declaration comment for the full tradeoff). Only
                     -- fires when the mailbox isn't already busy with a
                     -- real foreground register write, to never clobber
                     -- one.
                     if bit_count = 0 and fg_pending = mr_none and rx_primed = '0' then
                        -- Always fetch fresh, unconditionally (never skip
                        -- because rx_cur already appears to cover this
                        -- word) -- real bug caught in simulation
                        -- (tb_shim_stream.vhd, 2026-08-29): a prior
                        -- WGPDATA (or, on real hardware, the ARM daemon
                        -- writing a new packet into a reused ring slot)
                        -- can change the underlying DDR3 word after it
                        -- was cached, with nothing to invalidate a stale
                        -- copy otherwise. rx_primed (not fg_pending alone)
                        -- gates this to fire exactly once per CS-low
                        -- transaction -- see its declaration comment for
                        -- why bit_count=0 alone isn't a reliable
                        -- once-per-transaction signal (a second real bug,
                        -- also caught in simulation before hardware).
                        fg_pending <= mr_stream_prefetch;
                        rx_fetch_addr <= reg_erxrdpt(15 downto 3) & "000";
                        rx_fetch_is_nxt <= '0';
                        rx_primed <= '1';
                        -- nxt could equally hold a stale word from an
                        -- unrelated earlier transaction with a
                        -- coincidentally-matching tag -- drop it too, and
                        -- any in-flight lookahead fetch targeting it (its
                        -- result will land with rx_fetch_is_nxt='0' once
                        -- this fetch overwrites that flag, so it can only
                        -- ever land in rx_cur now, never silently validate
                        -- a stale rx_nxt afterward).
                        rx_nxt_valid <= '0';
                        rx_nxt_pending <= '0';
                     end if;
                     bit_count <= bit_count + 1;
                  end if;

               when s_addr =>
                  if bit_count = 7 then
                     cur_addr <= in_byte;
                     bit_count <= 0;
                     word_count <= 0;
                     if cur_opcode = OP_RCRU then
                        spi_state <= s_data_out;
                        -- REAL BUG fixed here (found via
                        -- tb_shim_real_master.vhd, 2026-08-27): the same
                        -- zero-turnaround-latency issue as the CS/first-
                        -- bit fix above, but on the read side -- the real
                        -- master starts sampling MISO the cycle right
                        -- after this one, so the first response bit must
                        -- already be valid entering that cycle. Computing
                        -- it only once inside s_data_out's own bit_count=0
                        -- branch (the old code) drives it one cycle too
                        -- late -- confirmed: readback came back rotated
                        -- (0x1229 instead of 0x2552). Fix: compute and
                        -- drive the first response bit now, using in_byte
                        -- (the address just latched -- cur_addr itself
                        -- isn't visible until next cycle), and start
                        -- s_data_out at bit_count=1 so its own bit_count=0
                        -- branch doesn't recompute the same byte a second
                        -- time. Byte-to-byte transitions within
                        -- s_data_out need no equivalent fix -- normal
                        -- register timing already lines them up correctly
                        -- (verified by trace, not just assumed).
                        bit_count <= 1;
                        case in_byte is
                           when ADDR_EUDAST => out_byte := reg_eudast(7 downto 0);
                           when ADDR_ESTAT =>
                              -- real firmware's primary RX gate (see
                              -- reg_pkt_delivered's declaration comment) --
                              -- this is the LSB (PKTCNT<7:0>); bit12
                              -- (clkrdy) lives in the MSB, served below.
                              out_byte := reg_erxhead_ddr(7 downto 0) - reg_pkt_delivered(7 downto 0);
                           when ADDR_ECON1 => out_byte := "000000" & econ1_txrts & econ1_rxen;
                           when ADDR_ECON2 => out_byte := x"00";
                           when ADDR_MAADR3 =>
                              if mac_addr_fetched = '1' then cur_mac := reg_mac_addr;
                              else cur_mac := PLACEHOLDER_MAC; end if;
                              -- ENC424J600 stores the MAC fully byte-
                              -- reversed across MAADR1H(canonical byte1)
                              -- .. MAADR3L(canonical byte6) -- DS39935C
                              -- Table 3-7. Wire byte 0 = canonical byte 6
                              -- = cur_mac[5] (0-indexed).
                              out_byte := cur_mac(47 downto 40);
                           when ADDR_ERXFCON => out_byte := reg_erxfcon(7 downto 0);
                           when ADDR_MACON1 => out_byte := reg_macon1(7 downto 0);
                           when ADDR_EIDLED => out_byte := reg_eidled(7 downto 0);
                           when ADDR_EGPWRPT => out_byte := reg_egpwrpt(7 downto 0);
                           when ADDR_ERXRDPT => out_byte := reg_erxrdpt(7 downto 0);
                           when others => out_byte := x"00";
                        end case;
                        xu_miso_i <= out_byte(7);
                        shift_out <= out_byte(6 downto 0) & '0';
                     else
                        spi_state <= s_data_in;
                     end if;
                  else
                     bit_count <= bit_count + 1;
                  end if;

               when s_data_in =>
                  if bit_count = 7 then
                     bit_count <= 0;
                     if word_count = 0 then
                        cur_word(15 downto 8) <= in_byte;  -- LSB byte arrives first
                        word_count <= 1;
                     else
                        -- full 16-bit word complete: cur_word(15:8)=LSB
                        -- (from first byte), in_byte=MSB (second byte)
                        word_count <= 0;
                        case cur_addr is
                           when ADDR_EUDAST =>
                              if cur_opcode = OP_WCRU then
                                 reg_eudast <= in_byte & cur_word(15 downto 8);
                              end if;
                           when ADDR_ECON2 =>
                              if cur_opcode = OP_BFSU then
                                 if cur_word(12) = '1' then  -- ETHRST, mask bit 4 of LSB byte (bit 12 overall)
                                    reg_eudast <= (others => '0');  -- real reset side effect
                                 end if;
                              end if;
                           when ADDR_ECON1 =>
                              if cur_opcode = OP_BFSU then
                                 if cur_word(8) = '1' then  -- RXEN, bit 0 of LSB byte
                                    econ1_rxen <= '1';
                                    fg_pending <= mr_rxen;
                                 end if;
                                 if cur_word(9) = '1' then  -- TXRTS, bit 1 of LSB byte
                                    econ1_txrts <= '1';
                                    fg_pending <= mr_txrts_req_set;
                                 end if;
                              elsif cur_opcode = OP_BFCU then
                                 if cur_word(8) = '1' then
                                    econ1_rxen <= '0';
                                 end if;
                              end if;
                           when ADDR_ERXFCON =>
                              if cur_opcode = OP_WCRU then
                                 reg_erxfcon <= in_byte & cur_word(15 downto 8);
                              end if;
                           when ADDR_MACON1 =>
                              if cur_opcode = OP_WCRU then
                                 reg_macon1 <= in_byte & cur_word(15 downto 8);
                              elsif cur_opcode = OP_BFSU then
                                 reg_macon1 <= reg_macon1 or (in_byte & cur_word(15 downto 8));
                              elsif cur_opcode = OP_BFCU then
                                 reg_macon1 <= reg_macon1 and not (in_byte & cur_word(15 downto 8));
                              end if;
                           when ADDR_EIDLED =>
                              if cur_opcode = OP_WCRU then
                                 reg_eidled <= in_byte & cur_word(15 downto 8);
                              end if;
                           when ADDR_EGPWRPT =>
                              if cur_opcode = OP_WCRU then
                                 reg_egpwrpt <= in_byte & cur_word(15 downto 8);
                              end if;
                           when ADDR_ERXRDPT =>
                              if cur_opcode = OP_WCRU then
                                 reg_erxrdpt <= in_byte & cur_word(15 downto 8);
                                 -- Real, confirmed-on-hardware bug fix
                                 -- (2026-08-30): a WCRU here means
                                 -- firmware is starting a fresh read at
                                 -- a new position (werxrdpt, once per
                                 -- frame in pktin) -- any word cached
                                 -- from a *previous* RRXDATA session
                                 -- must not be reused, even if its tag
                                 -- happens to coincidentally match the
                                 -- new erxrdpt's word address. Without
                                 -- this, a stale rx_cur_data get served
                                 -- for the new frame's header, landing
                                 -- firmware's read squarely inside the
                                 -- PREVIOUS frame's payload instead --
                                 -- confirmed via real hardware traces
                                 -- showing broadcast-MAC/EtherType-
                                 -- looking bytes (ff ff ff ff 08 00)
                                 -- where the header's small next_ptr/
                                 -- framelen values should have been.
                                 rx_cur_valid <= '0';
                                 rx_nxt_valid <= '0';
                                 rx_nxt_pending <= '0';
                              end if;
                           when ADDR_ETXST =>
                              if cur_opcode = OP_WCRU then
                                 fg_wdata <= x"000000000000" & in_byte & cur_word(15 downto 8);
                                 fg_pending <= mr_etxst;
                              end if;
                           when ADDR_ETXLEN =>
                              if cur_opcode = OP_WCRU then
                                 fg_wdata <= x"000000000000" & in_byte & cur_word(15 downto 8);
                                 fg_pending <= mr_etxlen;
                              end if;
                           when ADDR_ERXST =>
                              if cur_opcode = OP_WCRU then
                                 fg_wdata <= x"000000000000" & in_byte & cur_word(15 downto 8);
                                 fg_pending <= mr_erxst;
                              end if;
                           when ADDR_ERXTAIL =>
                              if cur_opcode = OP_WCRU then
                                 fg_wdata <= x"000000000000" & in_byte & cur_word(15 downto 8);
                                 fg_pending <= mr_erxtail;
                              end if;
                           when others =>
                              null;  -- unimplemented register write: ignored
                        end case;
                     end if;
                  else
                     bit_count <= bit_count + 1;
                  end if;

               when s_data_out =>
                  if bit_count = 0 then
                     -- compute the byte to send once, drive its MSB and
                     -- load the remaining 7 bits into shift_out in the
                     -- same cycle (real Mode 0,0 falling-edge output
                     -- timing lands here, same as every other bit)
                     case cur_addr is
                        when ADDR_EUDAST =>
                           if word_count = 0 then out_byte := reg_eudast(7 downto 0);
                           else out_byte := reg_eudast(15 downto 8); end if;
                        when ADDR_ESTAT =>
                           -- bit 12 (clkrdy) always set; PKTCNT<7:0> is
                           -- derived, real firmware's primary RX gate --
                           -- see reg_pkt_delivered's declaration comment.
                           estat_val := x"10" & (reg_erxhead_ddr(7 downto 0) - reg_pkt_delivered(7 downto 0));
                           if word_count = 0 then out_byte := estat_val(7 downto 0);
                           else out_byte := estat_val(15 downto 8); end if;
                        when ADDR_ECON1 =>
                           if word_count = 0 then out_byte := "000000" & econ1_txrts & econ1_rxen;
                           else out_byte := x"00"; end if;
                        when ADDR_ECON2 =>
                           out_byte := x"00";
                        when ADDR_MAADR3 =>
                           if mac_addr_fetched = '1' then cur_mac := reg_mac_addr;
                           else cur_mac := PLACEHOLDER_MAC; end if;
                           -- full reversal -- see the fast-path comment
                           -- above (DS39935C Table 3-7).
                           case word_count is
                              when 0 => out_byte := cur_mac(47 downto 40);
                              when 1 => out_byte := cur_mac(39 downto 32);
                              when 2 => out_byte := cur_mac(31 downto 24);
                              when 3 => out_byte := cur_mac(23 downto 16);
                              when 4 => out_byte := cur_mac(15 downto 8);
                              when others => out_byte := cur_mac(7 downto 0);
                           end case;
                        when ADDR_ERXFCON => if word_count = 0 then out_byte := reg_erxfcon(7 downto 0); else out_byte := reg_erxfcon(15 downto 8); end if;
                        when ADDR_MACON1  => if word_count = 0 then out_byte := reg_macon1(7 downto 0); else out_byte := reg_macon1(15 downto 8); end if;
                        when ADDR_EIDLED  => if word_count = 0 then out_byte := reg_eidled(7 downto 0); else out_byte := reg_eidled(15 downto 8); end if;
                        when ADDR_EGPWRPT => if word_count = 0 then out_byte := reg_egpwrpt(7 downto 0); else out_byte := reg_egpwrpt(15 downto 8); end if;
                        when ADDR_ERXRDPT => if word_count = 0 then out_byte := reg_erxrdpt(7 downto 0); else out_byte := reg_erxrdpt(15 downto 8); end if;
                        when others => out_byte := x"00";
                     end case;
                     xu_miso_i <= out_byte(7);
                     shift_out <= out_byte(6 downto 0) & '0';
                  else
                     xu_miso_i <= shift_out(7);
                     shift_out <= shift_out(6 downto 0) & '0';
                  end if;
                  if bit_count = 7 then
                     bit_count <= 0;
                     -- advance to the next byte within the current word
                     -- (every register needs word_count 0->1 to correctly
                     -- serve its second, MSB byte -- REAL BUG fixed here:
                     -- this used to only advance for ADDR_MAADR3, so every
                     -- other register's RCRU response repeated its LSB
                     -- byte twice instead of sending LSB then MSB, which
                     -- is exactly why chkeudast's readback never matched
                     -- and initenc always failed). MAADR3 advances through
                     -- all 6 real bytes instead of capping at 3 (see
                     -- word_count's own declaration comment).
                     if (cur_addr = ADDR_MAADR3 and word_count < 5)
                        or (cur_addr /= ADDR_MAADR3 and word_count < 1) then
                        word_count <= word_count + 1;
                     end if;
                  else
                     bit_count <= bit_count + 1;
                  end if;

               when s_stream_in =>
                  -- WGPDATA: write each completed byte to DDR3 at
                  -- reg_egpwrpt, auto-incrementing. No response expected
                  -- (xu_miso_i left don't-care, matching s_ignore).
                  if bit_count = 7 then
                     bit_count <= 0;
                     fg_pending <= mr_stream_write;
                     stream_write_addr <= reg_egpwrpt;
                     stream_write_data <= in_byte;
                     reg_egpwrpt <= reg_egpwrpt + 1;
                  else
                     bit_count <= bit_count + 1;
                  end if;

               when s_stream_out =>
                  -- RRXDATA: serve the current byte from the word cache
                  -- (see rx_cur_data's declaration comment), then run the
                  -- shared advance/lookahead/exhaustion logic -- same
                  -- duplicated block as the OP_RRXDATA byte0 case above,
                  -- for the same zero-latency reason.
                  if bit_count = 0 then
                     if rx_cur_valid = '1' and rx_cur_tag = reg_erxrdpt(15 downto 3) then
                        case reg_erxrdpt(2 downto 0) is
                           when "000" => out_byte := rx_cur_data(7 downto 0);
                           when "001" => out_byte := rx_cur_data(15 downto 8);
                           when "010" => out_byte := rx_cur_data(23 downto 16);
                           when "011" => out_byte := rx_cur_data(31 downto 24);
                           when "100" => out_byte := rx_cur_data(39 downto 32);
                           when "101" => out_byte := rx_cur_data(47 downto 40);
                           when "110" => out_byte := rx_cur_data(55 downto 48);
                           when others => out_byte := rx_cur_data(63 downto 56);
                        end case;
                        xu_miso_i <= out_byte(7);
                        shift_out <= out_byte(6 downto 0) & '0';
                     else
                        -- cache miss (nxt lookahead didn't land in time --
                        -- rare edge case now, see declaration comment)
                        xu_miso_i <= '0';
                        shift_out <= (others => '0');
                     end if;

                     reg_erxrdpt <= reg_erxrdpt + 1;
                     if reg_erxrdpt(2 downto 0) = "000" and rx_nxt_pending = '0'
                        and not (rx_nxt_valid = '1' and rx_nxt_tag = reg_erxrdpt(15 downto 3) + 1)
                        and fg_pending = mr_none then
                        fg_pending <= mr_stream_prefetch;
                        rx_fetch_addr <= (reg_erxrdpt(15 downto 3) + 1) & "000";
                        rx_fetch_is_nxt <= '1';
                        rx_nxt_pending <= '1';
                     end if;
                     if reg_erxrdpt(2 downto 0) = "111" then
                        if rx_nxt_valid = '1' and rx_nxt_tag = reg_erxrdpt(15 downto 3) + 1 then
                           rx_cur_data <= rx_nxt_data;
                           rx_cur_tag <= rx_nxt_tag;
                           rx_cur_valid <= '1';
                           rx_nxt_valid <= '0';
                        else
                           rx_cur_valid <= '0';
                        end if;
                     end if;
                  else
                     xu_miso_i <= shift_out(7);
                     shift_out <= shift_out(6 downto 0) & '0';
                  end if;
                  if bit_count = 7 then
                     bit_count <= 0;
                  else
                     bit_count <= bit_count + 1;
                  end if;

               when s_ignore =>
                  xu_miso_i <= '0';

            end case;
         end if;

         ----------------------------------------------------------------
         -- DDR3 mailbox sequencer: services fg_pending (foreground,
         -- priority) and a throttled background TXRTS_DONE poll. Single
         -- outstanding request, per the CDC discipline.
         ----------------------------------------------------------------
         case mbox_state is

            when m_idle =>
               if fg_pending /= mr_none then
                  mbox_active <= fg_pending;
                  fg_pending <= mr_none;
                  req_valid_i <= '1';
                  req_rw_i <= '1';
                  req_be_i <= x"FF";
                  case fg_pending is
                     when mr_rxen            => req_addr_i <= DDR_RXEN;      req_wdata_i <= x"0000000000000001";
                     when mr_txrts_req_set   => req_addr_i <= DDR_TXRTS_REQ; req_wdata_i <= x"0000000000000001";
                     when mr_txrts_req_clear => req_addr_i <= DDR_TXRTS_REQ; req_wdata_i <= x"0000000000000000";
                     when mr_etxst           => req_addr_i <= DDR_ETXST;     req_wdata_i <= fg_wdata;
                     when mr_etxlen          => req_addr_i <= DDR_ETXLEN;    req_wdata_i <= fg_wdata;
                     when mr_erxst           => req_addr_i <= DDR_ERXST;     req_wdata_i <= fg_wdata;
                     when mr_erxtail         => req_addr_i <= DDR_ERXTAIL;   req_wdata_i <= fg_wdata;
                     when mr_stream_write =>
                        -- single-byte write at an arbitrary DDR3 byte
                        -- offset -- req_addr's low 3 bits select the lane
                        -- via req_be (not the word address, per
                        -- xu_ddr_mailbox.vhd's own convention); replicate
                        -- the byte across all 8 lanes so whichever one
                        -- req_be selects is always correct.
                        req_addr_i <= stream_write_addr;
                        case stream_write_addr(2 downto 0) is
                           when "000" => req_be_i <= "00000001";
                           when "001" => req_be_i <= "00000010";
                           when "010" => req_be_i <= "00000100";
                           when "011" => req_be_i <= "00001000";
                           when "100" => req_be_i <= "00010000";
                           when "101" => req_be_i <= "00100000";
                           when "110" => req_be_i <= "01000000";
                           when others => req_be_i <= "10000000";
                        end case;
                        req_wdata_i <= stream_write_data & stream_write_data & stream_write_data & stream_write_data
                                     & stream_write_data & stream_write_data & stream_write_data & stream_write_data;
                     when mr_stream_prefetch =>
                        req_addr_i <= rx_fetch_addr;
                        req_rw_i <= '0';
                     when others             => null;
                  end case;
                  mbox_state <= m_issue;
                  -- REAL BUG fixed here (found 2026-08-29, real hardware --
                  -- xmitxx's ECON1 spin loop never terminating, TXRTS
                  -- stuck set forever, first real exercise of the TX-
                  -- complete handshake under real traffic). A first
                  -- attempt at this fix removed this reset unconditionally
                  -- for ALL foreground activity, which caused a separate,
                  -- unexplained real regression (deployed and confirmed on
                  -- hardware: the main system stopped reaching its own
                  -- boot prompt entirely -- bisected by reverting that
                  -- change, root mechanism still not understood). This
                  -- version is deliberately narrower: only skip the reset
                  -- for mr_stream_prefetch specifically -- the ONLY
                  -- foreground activity a plain, no-B0SEL-prefix RCRU
                  -- transaction (recon1's real template, and every other
                  -- local-register RCRU/WCRU/BFSU read/write) ever
                  -- triggers is this same speculative, opcode-unaware
                  -- prefetch (see its own declaration comment) -- it
                  -- fires on the first bit of literally every SPI
                  -- transaction, RRXDATA or not, and is the sole reason a
                  -- tight loop of otherwise-local ECON1 reads was
                  -- resetting this timer every ~20 cycles. Every OTHER
                  -- foreground request type (explicit register writes,
                  -- real stream writes) still resets bg_counter exactly as
                  -- before, unchanged from the original, working design --
                  -- minimizing the surface of this change relative to the
                  -- reverted first attempt.
                  if fg_pending /= mr_stream_prefetch then
                     bg_counter <= 0;
                  end if;
                  -- used to reset bg_counter to 0 on EVERY foreground
                  -- request, including the speculative RRXDATA-priming
                  -- fetch that fires on the first bit of every SPI
                  -- transaction regardless of actual opcode (see its own
                  -- declaration comment) -- so a plain RCRU read (recon1,
                  -- no B0SEL prefix, same as chkeudast/reidled) ALSO
                  -- triggers it and resets the timer. Firmware's ECON1
                  -- poll loop issues a fresh RCRU transaction every ~20
                  -- cycles with no delay, so bg_counter was being reset
                  -- far faster than it could ever reach BG_POLL_PERIOD --
                  -- permanently starving the TXRTS_DONE background poll,
                  -- so the daemon's real TXRTS_DONE write (confirmed
                  -- separately to actually happen) was simply never
                  -- observed. Fix: don't reset bg_counter here at all --
                  -- just let it hold (VHDL: unassigned in a branch retains
                  -- its value) during foreground activity and resume
                  -- counting from where it left off once idle, instead of
                  -- restarting from 0 every single transaction.
               elsif econ1_txrts = '1' then
                  if bg_counter = BG_POLL_PERIOD then
                     bg_counter <= 0;
                     mbox_active <= mr_txrts_done_poll;
                     req_valid_i <= '1';
                     req_rw_i <= '0';
                     req_addr_i <= DDR_TXRTS_DONE;
                     mbox_state <= m_issue;
                  else
                     bg_counter <= bg_counter + 1;
                  end if;
               elsif mac_valid_local = '0' then
                  -- REAL BUG fixed here (found via tb_shim_loopback.vhd,
                  -- 2026-08-28): this used to sit AFTER the econ1_rxen
                  -- branch below, so once RXEN was enabled (which happens
                  -- early and stays on for the rest of the session), the
                  -- ERXHEAD poll's permanent priority meant this branch
                  -- never got a turn at all -- the shim never actually
                  -- picked up a real daemon-published MAC in practice.
                  -- Not gated on RXEN itself: real firmware reads MAADR
                  -- (initenc) well before RXEN is ever enabled. Runs from
                  -- reset until the daemon publishes a real MAC (see the
                  -- boot-ordering fix in reg_mac_addr's declaration
                  -- comment).
                  if bg_counter = BG_POLL_PERIOD then
                     bg_counter <= 0;
                     mbox_active <= mr_mac_valid_poll;
                     req_valid_i <= '1';
                     req_rw_i <= '0';
                     req_addr_i <= DDR_MAC_VALID;
                     mbox_state <= m_issue;
                  else
                     bg_counter <= bg_counter + 1;
                  end if;
               elsif mac_addr_fetched = '0' then
                  -- MAC_VALID just turned '1' -- one final read of the
                  -- real MAC_ADDR, then never poll either again (both are
                  -- write-once at daemon startup), clearing the way for
                  -- ERXHEAD polling below to take over exclusively.
                  if bg_counter = BG_POLL_PERIOD then
                     bg_counter <= 0;
                     mbox_active <= mr_mac_addr_poll;
                     req_valid_i <= '1';
                     req_rw_i <= '0';
                     req_addr_i <= DDR_MAC_ADDR;
                     mbox_state <= m_issue;
                  else
                     bg_counter <= bg_counter + 1;
                  end if;
               elsif econ1_rxen = '1' then
                  -- background ERXHEAD poll (same throttle discipline as
                  -- TXRTS_DONE above) -- gives real firmware's ESTAT<7:0>
                  -- read (its primary RX gate, checked before anything
                  -- else) a chance to see frames the daemon has enqueued.
                  if bg_counter = BG_POLL_PERIOD then
                     bg_counter <= 0;
                     mbox_active <= mr_erxhead_poll;
                     req_valid_i <= '1';
                     req_rw_i <= '0';
                     req_addr_i <= DDR_ERXHEAD;
                     mbox_state <= m_issue;
                  else
                     bg_counter <= bg_counter + 1;
                  end if;
               else
                  bg_counter <= 0;
               end if;

            when m_issue =>
               if req_ack = '1' then
                  mbox_state <= m_wait_ack_drop;
                  req_valid_i <= '0';
                  if mbox_active = mr_txrts_done_poll and resp_rdata(0) = '1' then
                     econ1_txrts <= '0';
                     fg_pending <= mr_txrts_req_clear;
                  end if;
                  if mbox_active = mr_stream_prefetch then
                     -- full aligned 64-bit word lands here, whole -- see
                     -- rx_cur_data's declaration comment. rx_fetch_addr's
                     -- low 3 bits are always "000" (word-aligned fetch),
                     -- so no byte-lane selection is needed here (unlike
                     -- the old per-byte design).
                     --
                     -- Real, confirmed-on-hardware bug fix (2026-08-30):
                     -- this used to accept the completed fetch
                     -- unconditionally. The speculative prefetch (see
                     -- its own declaration comment, "fires on the first
                     -- bit of literally every SPI transaction") is
                     -- requested using whatever reg_erxrdpt held *at
                     -- that moment* -- for a WCRU-to-ADDR_ERXRDPT
                     -- transaction (werxrdpt, once per frame in pktin),
                     -- that's the OLD position, since the opcode byte
                     -- (and so this speculative fetch) is shifted in
                     -- before the new erxrdpt value is ever written.
                     -- If that in-flight fetch completes *after* the
                     -- WCRU has already updated reg_erxrdpt and (this
                     -- file's own earlier fix) cleared rx_cur_valid, it
                     -- would land here and silently set rx_cur_valid
                     -- back to '1' with data for the OLD address again
                     -- -- real hardware evidence: firmware's own DBG
                     -- pktin flen: trace showed a small, fixed set of
                     -- wrong values repeating in lockstep with the RX
                     -- ring's real 6 positions, exactly matching "always
                     -- landing on whatever address was current right
                     -- before the last werxrdpt." Fix: only accept the
                     -- result if the address it was actually fetched
                     -- for still matches what's currently needed --
                     -- otherwise the erxrdpt moved on while this fetch
                     -- was in flight, and the data is simply stale now.
                     if rx_fetch_is_nxt = '1' then
                        if rx_fetch_addr(15 downto 3) = reg_erxrdpt(15 downto 3) + 1 then
                           rx_nxt_data <= resp_rdata;
                           rx_nxt_tag <= rx_fetch_addr(15 downto 3);
                           rx_nxt_valid <= '1';
                        end if;
                        rx_nxt_pending <= '0';
                     else
                        if rx_fetch_addr(15 downto 3) = reg_erxrdpt(15 downto 3) then
                           rx_cur_data <= resp_rdata;
                           rx_cur_tag <= rx_fetch_addr(15 downto 3);
                           rx_cur_valid <= '1';
                        end if;
                     end if;
                  end if;
                  if mbox_active = mr_erxhead_poll then
                     reg_erxhead_ddr <= resp_rdata(15 downto 0);
                  end if;
                  if mbox_active = mr_mac_valid_poll then
                     mac_valid_local <= resp_rdata(0);
                  end if;
                  if mbox_active = mr_mac_addr_poll then
                     reg_mac_addr <= resp_rdata(47 downto 0);
                     mac_addr_fetched <= '1';
                  end if;
               end if;

            when m_wait_ack_drop =>
               if req_ack = '0' then
                  mbox_state <= m_idle;
                  mbox_active <= mr_none;
               end if;

         end case;

      end if;
   end process;

end implementation;
