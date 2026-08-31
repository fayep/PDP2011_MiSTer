--
-- xu_enc424j600_shim.vhd -- Phase 2: real SPI decoder standing in for a
-- physical ENC424J600 chip, replacing rtl/xu_test_stub.vhd.
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
   -- offset table). RXEN/TXRTS_REQ/ETXLEN/ERXST/ERXTAIL are all shim-sole-
   -- writer and all needed together by the daemon -- packed into one
   -- DDR_XU_STATUS word (see support/xu/xu_ddr3.h for the byte layout,
   -- must match exactly) instead of five separate one-shot fields, so a
   -- single atomic write covers all of them with no ordering question
   -- between them. ETXST is dropped: this firmware always writes it as 0
   -- before every transmit (xmitst), so the daemon just assumes 0.
   constant DDR_XU_STATUS   : std_logic_vector(15 downto 0) := x"6000";
   constant DDR_TXRTS_DONE  : std_logic_vector(15 downto 0) := x"6010";
   constant DDR_ERXHEAD     : std_logic_vector(15 downto 0) := x"6030";
   constant DDR_MAC_ADDR    : std_logic_vector(15 downto 0) := x"6040";
   constant DDR_MAC_VALID   : std_logic_vector(15 downto 0) := x"6048";

   -- Real chip behavior (DS39935C S9.2): the RX region is a true circular
   -- buffer -- the address generator wraps transparently, even mid-word,
   -- at the region's physical end, with no firmware awareness needed.
   -- Half-closed [RX_BUF_START, RX_BUF_END) = [0x4800, 0x6000): 0x4800
   -- is the first valid byte, 0x6000 is one past the last. A WCRU of
   -- ERXRDPT outside that window (0x0000, 0x6000, live-log 0x8115) is
   -- rx_miss, not a seek. Wrapping 0x5FFF -> 0x4800 is unconditional.
   constant RX_BUF_START : std_logic_vector(15 downto 0) := x"4800";
   constant RX_BUF_END   : std_logic_vector(15 downto 0) := x"6000"; -- one past the last valid RX byte

   -- next byte position, wrapping RX_BUF_END-1 -> RX_BUF_START
   function rx_next_addr(cur : std_logic_vector(15 downto 0)) return std_logic_vector is
   begin
      if cur = RX_BUF_END - 1 then
         return RX_BUF_START;
      else
         return cur + 1;
      end if;
   end function;

   -- next word-aligned byte address after cur's own word (cur must
   -- already be 8-byte aligned), wrapping the same boundary. Used by the
   -- two-bank RX cache's seek/readahead logic below -- everything there
   -- works in raw byte addresses, no word-index shifting anywhere.
   function rx_next_word_addr(cur : std_logic_vector(15 downto 0)) return std_logic_vector is
   begin
      if cur = RX_BUF_END - 8 then
         return RX_BUF_START;
      else
         return cur + 8;
      end if;
   end function;

   -- Forward circular distance from from_addr to to_addr within the RX
   -- ring (both must be real addresses in [RX_BUF_START, RX_BUF_END)).
   -- Mirrors support/xu/xu.cpp's own free_space computation on the write
   -- side -- same ring, same wraparound, measuring the read side's
   -- safety margin instead of the write side's.
   function rx_fwd_dist(from_addr, to_addr : std_logic_vector(15 downto 0)) return std_logic_vector is
   begin
      if to_addr >= from_addr then
         return to_addr - from_addr;
      else
         return (RX_BUF_END - RX_BUF_START) - (from_addr - to_addr);
      end if;
   end function;

   -- selects one byte lane out of an 8-byte RX cache bank word.
   function rx_byte_lane(data : std_logic_vector(63 downto 0); lane : std_logic_vector(2 downto 0)) return std_logic_vector is
   begin
      case lane is
         when "000" => return data(7 downto 0);
         when "001" => return data(15 downto 8);
         when "010" => return data(23 downto 16);
         when "011" => return data(31 downto 24);
         when "100" => return data(39 downto 32);
         when "101" => return data(47 downto 40);
         when "110" => return data(55 downto 48);
         when others => return data(63 downto 56);
      end case;
   end function;

   -- builds a bank tag from a real (already 8-byte-aligned) address and
   -- one of the RXB_* states.
   function rx_make_tag(addr : std_logic_vector(15 downto 0); state : std_logic_vector(2 downto 0)) return std_logic_vector is
   begin
      return (addr and x"FFF8") or ("0000000000000" & state);
   end function;

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

   -- rx_miss: sticky, our own private extension (bit 2 of ECON1 -- no
   -- real ENC424J600 meaning, unused by real hardware). Set whenever the
   -- two-bank RX cache serves its documented cache-miss fallback (all
   -- zero bytes -- readahead hasn't landed yet). Real hardware evidence
   -- (2026-08-31): firmware's own address-range sanity check on dnpp
   -- caught SOME corrupted reads but missed others where garbage bytes
   -- happened to look like a valid ring address (dnpp=0x5267 with
   -- flen=0x1279, impossible for a real frame, sailed straight through
   -- an address-range check) -- inferring validity from content is
   -- fundamentally unreliable. This is the real signal instead: the shim
   -- itself knows definitively when it served a miss, so it says so
   -- directly. Stays set until firmware explicitly clears it (BFCU,
   -- matching RXEN's own clear pattern) -- deliberately sticky so a miss
   -- occurring mid-copy (e.g. during getfr's long payload read, not just
   -- pktin's own short header reads) is never missed by checking once
   -- and moving on.
   signal rx_miss : std_logic := '0';
   -- Toggles on every ETHRST so the daemon can restart its write pointer
   -- at ERXST. Firmware chip-reset (xrxreset/initenc) would otherwise
   -- leave the daemon writing into the old ring position. Published in
   -- XU_STATUS_OFF bit 2 (see xu_ddr3.h).
   signal rstseq : std_logic := '0';

   ----------------------------------------------------------------------
   -- RX packet-count tracking (ESTAT<7:0>, real firmware's primary RX
   -- gate -- roms/xubrt45.mac reads this FIRST, before anything else, to
   -- decide whether a frame is even waiting; see conversation, 2026-08-28).
   -- DDR_ERXHEAD is the daemon's own monotonic count of frames enqueued
   -- in bits 15:0, plus rx_wrpos (first unwritten RX byte) in bits 47:32.
   -- PKTCNT is derived locally from the count. wrpos is the readahead
   -- bound: after catch-up, ERXTAIL sits two bytes behind ERXRDPT so a
   -- tail-only bound wraps the full ring and prefetches unwritten DDR
   -- (live log: seek to 0x51d8 HIT a stale bank, dnpp=0x1060). Count-only
   -- writes leave wrpos 0 and keep the old ERXTAIL bound.
   ----------------------------------------------------------------------
   signal reg_erxhead_ddr  : std_logic_vector(15 downto 0) := (others => '0');
   signal reg_pkt_delivered : std_logic_vector(15 downto 0) := (others => '0');
   -- Daemon write pointer (XU_ERXHEAD_OFF bits 47:32). 0 means unpublished
   -- (old daemon / tests) -- readahead then uses ERXTAIL.
   signal reg_rx_wrpos : std_logic_vector(15 downto 0) := (others => '0');

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
   type mbox_req_type is (mr_none, mr_status,
                           mr_txrts_done_poll, mr_stream_write, mr_stream_prefetch,
                           mr_erxhead_poll, mr_mac_valid_poll, mr_mac_addr_poll);
   signal fg_pending : mbox_req_type := mr_none;
   signal fg_wdata : std_logic_vector(63 downto 0) := (others => '0');

   -- RXEN/TXRTS_REQ/ETXLEN/ERXST/ERXTAIL are all shim-sole-writer and all
   -- needed together by the daemon (see xu_ddr3.h's XU_STATUS_OFF layout
   -- comment, which this must match exactly). Rather than staging a
   -- combined value that several different write sites would each need
   -- to partially update without clobbering the others, each field keeps
   -- its own persistent local register (econ1_rxen/econ1_txrts already
   -- existed for firmware's own ECON1 readback; reg_etxlen/reg_erxst/
   -- reg_erxtail are the same idea for the other three) and the
   -- composite word is always rebuilt fresh, from all five, at the
   -- moment it's actually published (see the promotion block near
   -- mbox_state). dirty_status just means "republish the current values"
   -- -- it carries no data of its own, so any site that changes one of
   -- the five local registers (including the TXRTS_DONE-driven auto-
   -- clear of econ1_txrts) only has to set this one flag, unconditionally,
   -- to guarantee the change reaches DDR3 -- see the fg_pending single-
   -- hand-off-slot note below for why this has to latch and retry rather
   -- than write fg_pending directly.
   signal reg_etxlen  : std_logic_vector(15 downto 0) := (others => '0');
   signal reg_erxst   : std_logic_vector(15 downto 0) := (others => '0');
   signal reg_erxtail : std_logic_vector(15 downto 0) := (others => '0');

   -- fg_pending is a single hand-off slot, not a queue: a request set
   -- into it can be silently lost if something else overwrites it before
   -- the mailbox picks it up. dirty_status latches "a republish is
   -- needed" and stays set (retried every cycle by the promotion block
   -- near mbox_state) until the hand-off actually succeeds, so it can
   -- never be lost to fg_pending being busy at the wrong instant. Set
   -- unconditionally by any of the five fields' write sites -- never
   -- gated there.
   signal dirty_status : std_logic := '0';

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
   -- in the plan's own Phase 2 open items). Two-bank RX word cache,
   -- decoupled entirely from SPI transaction boundaries -- session
   -- history (2026-08-30) found that a "fetch fresh once per CS-session"
   -- trigger keeps racing itself: two transactions reading the same
   -- already-cached word (e.g. pktin's dnpp then dpkth, moments apart)
   -- would each discard perfectly good data and re-fetch, and the second
   -- fetch often hadn't landed by the time its first byte was due,
   -- serving zero instead of real data. Real hardware evidence: dnpp
   -- read correctly while dpkth (same word, next CS-session) read back
   -- zero, every time.
   --
   -- Each bank's tag holds its real 8-byte-aligned byte address, with
   -- the guaranteed-zero low 3 bits of any such address (RX_BUF_START/
   -- RX_BUF_END are both multiples of 8) reused as a 3-value state:
   --   001 = empty    -- available for a fresh fetch
   --   010 = pending  -- fetch issued, not yet landed
   --   011 = valid    -- real data, safe to serve
   -- Mask with x"FFF8" to recover the real address.
   --
   -- What drives this now is not per-transaction timing but two things:
   --   seek     -- ADDR_ERXRDPT WCRU always refetches (never HIT a VALID
   --              bank). Live log frame 63 was a HIT of a stale occupant
   --              at 0x51d8. Applied last in the process so it wins over
   --              same-cycle prefetch completion.
   --   readahead -- runs every cycle, independent of any CS-session:
   --              once the current bank is valid, if the next word is
   --              still within the written region (rx_fwd_dist against
   --              reg_rx_wrpos when the daemon has published it, else
   --              reg_erxtail) and the other bank is empty, prefetch
   --              into it proactively. Wrap (next word < current) also
   --              prefetches, but must not re-PENDING a bank that is
   --              already PENDING/VALID for the wrap target -- that
   --              hammered the wrap word every cycle and never let a
   --              completed fetch stay VALID.
   -- banksel names which bank is currently being served; advancing past
   -- a bank's last byte marks it empty again and flips banksel to the
   -- other one, which readahead should already have filled.
   constant RXB_EMPTY     : std_logic_vector(2 downto 0) := "001";
   constant RXB_PENDING   : std_logic_vector(2 downto 0) := "010";
   constant RXB_VALID     : std_logic_vector(2 downto 0) := "011";
   constant RXB_EMPTY_TAG : std_logic_vector(15 downto 0) := x"0001";

   signal bank_a_data : std_logic_vector(63 downto 0) := (others => '0');
   signal bank_a_tag  : std_logic_vector(15 downto 0) := RXB_EMPTY_TAG;
   signal bank_b_data : std_logic_vector(63 downto 0) := (others => '0');
   signal bank_b_tag  : std_logic_vector(15 downto 0) := RXB_EMPTY_TAG;
   signal banksel     : std_logic := '0';  -- '0' = bank A current, '1' = bank B

   -- Rollback shadow for the confirmed xubl.vhd cmd_recv off-by-one (see
   -- CS-deassert handler below): cmd_recv always shifts exactly one bit
   -- past rl before actually stopping. For any RRXDATA read (rl is
   -- always byte-aligned in this firmware), that extra bit lands exactly
   -- on a fresh byte's bit_count=0 -- which is prospectively served and
   -- mutates reg_erxrdpt (and possibly frees/flips a bank) for a byte
   -- that xubl never really needed. Snapshot pre-mutation state every
   -- time that branch fires; if CS deasserts with bit_count=1 (the
   -- signature of exactly one phantom bit), restore it -- xubl.vhd
   -- itself stays untouched, per the design's own constraint.
   signal rx_shadow_erxrdpt    : std_logic_vector(15 downto 0) := (others => '0');
   signal rx_shadow_bank_a_tag : std_logic_vector(15 downto 0) := RXB_EMPTY_TAG;
   signal rx_shadow_bank_b_tag : std_logic_vector(15 downto 0) := RXB_EMPTY_TAG;
   signal rx_shadow_banksel    : std_logic := '0';

   signal rx_fetch_addr       : std_logic_vector(15 downto 0) := (others => '0');
   signal fetch_target_is_b   : std_logic := '0';
   -- true from the moment a bank's fetch is actually handed to
   -- fg_pending until the mailbox completion lands it -- prevents the
   -- continuous dispatcher below from issuing a second request for the
   -- same still-in-flight bank.
   signal rx_fetch_outstanding : std_logic := '0';

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
      variable cur_bank_data : std_logic_vector(63 downto 0);
      variable cur_bank_tag  : std_logic_vector(15 downto 0);
      variable rx_next_word_v : std_logic_vector(15 downto 0);
      variable rx_bound_v     : std_logic_vector(15 downto 0);
      variable new_erxrdpt    : std_logic_vector(15 downto 0);
      variable seek_this_cycle : boolean;
      variable seek_addr_v     : std_logic_vector(15 downto 0);
      variable discard_fetch   : boolean;
      variable ethrst_this_cycle : boolean;
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
         rx_miss <= '0';
         rstseq <= '0';
         reg_erxhead_ddr <= (others => '0');
         reg_rx_wrpos <= (others => '0');
         reg_pkt_delivered <= (others => '0');
         reg_mac_addr <= (others => '0');
         mac_valid_local <= '0';
         mac_addr_fetched <= '0';

         fg_pending <= mr_none;
         fg_wdata <= (others => '0');
         reg_etxlen <= (others => '0');
         reg_erxst <= (others => '0');
         reg_erxtail <= (others => '0');
         dirty_status <= '0';
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
         bank_a_data <= (others => '0');
         bank_a_tag <= RXB_EMPTY_TAG;
         bank_b_data <= (others => '0');
         bank_b_tag <= RXB_EMPTY_TAG;
         banksel <= '0';
         rx_fetch_addr <= (others => '0');
         fetch_target_is_b <= '0';
         rx_fetch_outstanding <= '0';
         rx_shadow_erxrdpt <= (others => '0');
         rx_shadow_bank_a_tag <= RXB_EMPTY_TAG;
         rx_shadow_bank_b_tag <= RXB_EMPTY_TAG;
         rx_shadow_banksel <= '0';

      elsif cpuclk'event and cpuclk = '1' then

         seek_this_cycle := false;
         discard_fetch := false;
         ethrst_this_cycle := false;

         ----------------------------------------------------------------
         -- SPI shift engine
         ----------------------------------------------------------------
         if xu_cs = '1' then
            spi_state <= s_opcode;
            bit_count <= 0;
            word_count <= 0;
            if spi_state = s_stream_out and bit_count /= 0 then
               -- xubl overshoots the requested rl by a handful of extra
               -- cpuclk cycles (its own cmd_xmit/cmd_recv each have a
               -- confirmed one-extra-bit pattern; the combined overshoot
               -- is not a fixed count). A byte-aligned RRXDATA response
               -- (always true in this firmware) only ever ends cleanly
               -- at bit_count=0 -- CS deasserting mid-byte (bit_count/=0)
               -- always means the in-progress byte-serve mutation
               -- (reg_erxrdpt advance, possible bank free/flip) was for a
               -- byte xubl never actually needed. Undo it.
               reg_erxrdpt <= rx_shadow_erxrdpt;
               bank_a_tag <= rx_shadow_bank_a_tag;
               bank_b_tag <= rx_shadow_bank_b_tag;
               banksel <= rx_shadow_banksel;
            end if;
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
                        -- bit now, served from whichever bank banksel
                        -- currently names. Kept fresh continuously by the
                        -- seek/readahead logic elsewhere (see the two-bank
                        -- cache's own declaration comment), not fetched
                        -- here at all.
                        spi_state <= s_stream_out;
                        bit_count <= 1;
                        if banksel = '0' then
                           cur_bank_data := bank_a_data;
                           cur_bank_tag := bank_a_tag;
                        else
                           cur_bank_data := bank_b_data;
                           cur_bank_tag := bank_b_tag;
                        end if;
                        if cur_bank_tag(2 downto 0) = RXB_VALID
                           and (cur_bank_tag and x"FFF8") = (reg_erxrdpt and x"FFF8") then
                           out_byte := rx_byte_lane(cur_bank_data, reg_erxrdpt(2 downto 0));
                           xu_miso_i <= out_byte(7);
                           shift_out <= out_byte(6 downto 0) & '0';
                        else
                           -- cache miss -- readahead hasn't landed yet.
                           -- Should be rare: readahead starts the moment
                           -- the previous bank goes valid, giving it a
                           -- full word-time head start rather than one
                           -- opcode byte's worth.
                           xu_miso_i <= '0';
                           shift_out <= (others => '0');
                           rx_miss <= '1';
                        end if;

                        rx_shadow_erxrdpt <= reg_erxrdpt;
                        rx_shadow_bank_a_tag <= bank_a_tag;
                        rx_shadow_bank_b_tag <= bank_b_tag;
                        rx_shadow_banksel <= banksel;
                        reg_erxrdpt <= rx_next_addr(reg_erxrdpt);
                        if reg_erxrdpt(2 downto 0) = "111" then
                           -- this bank is now fully consumed -- free it
                           -- and flip to the other one, which readahead
                           -- should already have filled.
                           if banksel = '0' then
                              bank_a_tag <= RXB_EMPTY_TAG;
                           else
                              bank_b_tag <= RXB_EMPTY_TAG;
                           end if;
                           banksel <= not banksel;
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
                     -- No per-transaction speculative prefetch anymore --
                     -- the two-bank cache is kept fresh continuously by
                     -- the seek (ADDR_ERXRDPT WCRU handler) and readahead
                     -- (runs every cycle, see the cache's own declaration
                     -- comment) logic elsewhere, independent of SPI
                     -- transaction boundaries entirely.
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
                           when ADDR_ECON1 => out_byte := "00000" & rx_miss & econ1_txrts & econ1_rxen;
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
                                    ethrst_this_cycle := true;
                                 end if;
                              end if;
                           when ADDR_ECON1 =>
                              if cur_opcode = OP_BFSU then
                                 if cur_word(8) = '1' then  -- RXEN, bit 0 of LSB byte
                                    econ1_rxen <= '1';
                                    dirty_status <= '1';
                                 end if;
                                 if cur_word(9) = '1' then  -- TXRTS, bit 1 of LSB byte
                                    econ1_txrts <= '1';
                                    dirty_status <= '1';
                                 end if;
                              elsif cur_opcode = OP_BFCU then
                                 if cur_word(8) = '1' then
                                    -- RXEN's DDR3 mirror must be kept in
                                    -- sync on both set and clear -- the
                                    -- daemon's own RXEN gate (xu_poll_rx())
                                    -- reads only the DDR3 copy, never the
                                    -- local econ1_rxen flip-flop.
                                    econ1_rxen <= '0';
                                    dirty_status <= '1';
                                 end if;
                                 if cur_word(10) = '1' then  -- rx_miss clear, bit 2 of LSB byte
                                    rx_miss <= '0';
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
                                 new_erxrdpt := in_byte & cur_word(15 downto 8);
                                 -- Live log: firmware frame 63 seeked to
                                 -- 0x51d8 and the cache HIT a stale word
                                 -- (previous occupant), serving dnpp=0x1060.
                                 -- Never HIT on seek -- always refetch.
                                 -- Applied at end of this process so it
                                 -- wins over a same-cycle prefetch
                                 -- completion.
                                 --
                                 -- ERXRDPT is the RX window pointer.
                                 -- Valid range is half-closed
                                 -- [RX_BUF_START, RX_BUF_END) =
                                 -- [0x4800, 0x6000). 0x0000, 0x6000,
                                 -- and the live-log 0x8115 are all
                                 -- outside it -- rx_miss, leave the
                                 -- pointer where it is.
                                 if new_erxrdpt >= RX_BUF_START
                                    and new_erxrdpt < RX_BUF_END then
                                    reg_erxrdpt <= new_erxrdpt;
                                    seek_this_cycle := true;
                                    seek_addr_v := new_erxrdpt;
                                    discard_fetch := true;
                                 else
                                    rx_miss <= '1';
                                 end if;
                              end if;
                           -- ETXST: no case here at all -- firmware only
                           -- ever writes it (xmitst), never reads it back,
                           -- and always writes 0 (see xu_ddr3.h's
                           -- XU_STATUS_OFF comment), so it needs neither
                           -- local storage nor a DDR3 publish; falls
                           -- through to "when others" below, matching
                           -- every other unimplemented register write.
                           when ADDR_ETXLEN =>
                              if cur_opcode = OP_WCRU then
                                 reg_etxlen <= in_byte & cur_word(15 downto 8);
                                 dirty_status <= '1';
                              end if;
                           when ADDR_ERXST =>
                              if cur_opcode = OP_WCRU then
                                 reg_erxst <= in_byte & cur_word(15 downto 8);
                                 dirty_status <= '1';
                              end if;
                           when ADDR_ERXTAIL =>
                              if cur_opcode = OP_WCRU then
                                 reg_erxtail <= in_byte & cur_word(15 downto 8);
                                 dirty_status <= '1';
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
                           if word_count = 0 then out_byte := "00000" & rx_miss & econ1_txrts & econ1_rxen;
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
                  -- RRXDATA: serve the current byte from whichever bank
                  -- banksel names, then advance -- same duplicated shape
                  -- as the OP_RRXDATA byte0 case above, for the same
                  -- zero-latency reason. No fetch triggered here at all;
                  -- the two-bank cache is kept fresh by seek/readahead
                  -- running elsewhere.
                  if bit_count = 0 then
                     if banksel = '0' then
                        cur_bank_data := bank_a_data;
                        cur_bank_tag := bank_a_tag;
                     else
                        cur_bank_data := bank_b_data;
                        cur_bank_tag := bank_b_tag;
                     end if;
                     if cur_bank_tag(2 downto 0) = RXB_VALID
                        and (cur_bank_tag and x"FFF8") = (reg_erxrdpt and x"FFF8") then
                        out_byte := rx_byte_lane(cur_bank_data, reg_erxrdpt(2 downto 0));
                        xu_miso_i <= out_byte(7);
                        shift_out <= out_byte(6 downto 0) & '0';
                     else
                        -- cache miss (readahead didn't land in time --
                        -- rare edge case, see the cache's own declaration
                        -- comment)
                        xu_miso_i <= '0';
                        shift_out <= (others => '0');
                        rx_miss <= '1';
                     end if;

                     rx_shadow_erxrdpt <= reg_erxrdpt;
                     rx_shadow_bank_a_tag <= bank_a_tag;
                     rx_shadow_bank_b_tag <= bank_b_tag;
                     rx_shadow_banksel <= banksel;
                     reg_erxrdpt <= rx_next_addr(reg_erxrdpt);
                     if reg_erxrdpt(2 downto 0) = "111" then
                        if banksel = '0' then
                           bank_a_tag <= RXB_EMPTY_TAG;
                        else
                           bank_b_tag <= RXB_EMPTY_TAG;
                        end if;
                        banksel <= not banksel;
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
         -- Two-bank RX cache readahead trigger. Runs every cycle,
         -- independent of SPI transaction boundaries -- see the banks'
         -- own declaration comment for why. Once the current bank is
         -- valid, mark the OTHER bank pending for the next word, as long
         -- as it's still within the written region (rx_wrpos when the
         -- daemon has published it, else ERXTAIL). Only touches a bank's
         -- own tag, not fg_pending -- the actual DDR3 fetch is issued
         -- below, merged into the same priority chain as every other
         -- fg_pending consumer so they can never silently clobber each
         -- other.
         ----------------------------------------------------------------
         if banksel = '0' then
            cur_bank_tag := bank_a_tag;
         else
            cur_bank_tag := bank_b_tag;
         end if;
         if cur_bank_tag(2 downto 0) = RXB_VALID then
            rx_next_word_v := rx_next_word_addr(cur_bank_tag and x"FFF8");
            if reg_rx_wrpos >= RX_BUF_START and reg_rx_wrpos < RX_BUF_END then
               rx_bound_v := reg_rx_wrpos;
            else
               rx_bound_v := reg_erxtail;
            end if;
            if rx_fwd_dist(reg_erxrdpt, rx_next_word_v) < rx_fwd_dist(reg_erxrdpt, rx_bound_v) then
               -- Wrap (next < current) must refetch if the other bank
               -- still holds a previous-lap occupant (wrong address) or
               -- is empty. Do not re-PENDING a bank that is already
               -- PENDING/VALID for the wrap target -- that assignment
               -- ran every cycle and wiped a just-landed VALID word, so
               -- on real DDR latency the wrap bank never stayed ready.
               if rx_next_word_v < (cur_bank_tag and x"FFF8") then
                  if banksel = '0' then
                     if not ((bank_b_tag(2 downto 0) = RXB_PENDING
                              or bank_b_tag(2 downto 0) = RXB_VALID)
                             and (bank_b_tag and x"FFF8") = rx_next_word_v) then
                        bank_b_tag <= rx_make_tag(rx_next_word_v, RXB_PENDING);
                     end if;
                  else
                     if not ((bank_a_tag(2 downto 0) = RXB_PENDING
                              or bank_a_tag(2 downto 0) = RXB_VALID)
                             and (bank_a_tag and x"FFF8") = rx_next_word_v) then
                        bank_a_tag <= rx_make_tag(rx_next_word_v, RXB_PENDING);
                     end if;
                  end if;
               elsif banksel = '0' and bank_b_tag(2 downto 0) = RXB_EMPTY then
                  bank_b_tag <= rx_make_tag(rx_next_word_v, RXB_PENDING);
               elsif banksel = '1' and bank_a_tag(2 downto 0) = RXB_EMPTY then
                  bank_a_tag <= rx_make_tag(rx_next_word_v, RXB_PENDING);
               end if;
            end if;
         end if;

         ----------------------------------------------------------------
         -- Promote exactly one pending fg_pending request, once the
         -- hand-off slot is actually free. Runs every cycle -- this is
         -- what turns a dirty_status/pending-bank latch into a real
         -- retry: it just keeps re-checking fg_pending = mr_none until
         -- it finally succeeds. All three branches here read the SAME
         -- pre-cycle fg_pending value, so they must be one mutually
         -- exclusive if/elsif chain, not separate independent ifs --
         -- two independent "if fg_pending = mr_none then ..." blocks in
         -- the same cycle would silently let the later one overwrite
         -- the earlier one's assignment. Fixed priority order below is
         -- fine -- status publishes and RX fetches are both rare/
         -- moderate-frequency, not so pathologically bursty relative to
         -- each other that either would starve.
         ----------------------------------------------------------------
         if fg_pending = mr_none then
            if dirty_status = '1' then
               -- Composite word built fresh from the five current local
               -- registers, matching xu_ddr3.h's XU_STATUS_OFF layout
               -- exactly: byte0 = RXEN|TXRTS_REQ<<1, byte1 = 0, bytes
               -- 2-3 = ETXLEN, bytes 4-5 = ERXST, bytes 6-7 = ERXTAIL.
               fg_pending <= mr_status;
               fg_wdata <= reg_erxtail & reg_erxst & reg_etxlen
                          & x"00" & "00000" & rstseq & econ1_txrts & econ1_rxen;
               dirty_status <= '0';
            elsif rx_fetch_outstanding = '0' and bank_a_tag(2 downto 0) = RXB_PENDING then
               fg_pending <= mr_stream_prefetch;
               rx_fetch_addr <= bank_a_tag and x"FFF8";
               fetch_target_is_b <= '0';
               rx_fetch_outstanding <= '1';
            elsif rx_fetch_outstanding = '0' and bank_b_tag(2 downto 0) = RXB_PENDING then
               fg_pending <= mr_stream_prefetch;
               rx_fetch_addr <= bank_b_tag and x"FFF8";
               fetch_target_is_b <= '1';
               rx_fetch_outstanding <= '1';
            end if;
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
                     when mr_status => req_addr_i <= DDR_XU_STATUS; req_wdata_i <= fg_wdata;
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
                     -- Same real hazard the rest of this file's
                     -- dirty_status redesign closed: writing fg_pending
                     -- directly here (the original code) could silently
                     -- lose this clear if fg_pending was already busy at
                     -- this exact instant. dirty_status latches and
                     -- retries instead.
                     econ1_txrts <= '0';
                     dirty_status <= '1';
                  end if;
                  if mbox_active = mr_stream_prefetch then
                     -- Full aligned 64-bit word lands here, whole -- see
                     -- the two-bank cache's own declaration comment.
                     -- rx_fetch_addr is always word-aligned (the
                     -- dispatcher only ever issues fetches for a bank's
                     -- own tag address, masked), so no byte-lane
                     -- selection is needed.
                     --
                     -- Only accept into the target bank if its tag still
                     -- matches what was actually requested and is still
                     -- pending -- if a seek (or readahead choosing a new
                     -- target) reassigned that bank to a different
                     -- address while this fetch was in flight, the
                     -- result is simply stale now and gets discarded.
                     -- Same staleness-guard principle the earlier
                     -- single-buffer design needed (real, confirmed-on-
                     -- hardware bug, 2026-08-30: an unconditional accept
                     -- there let an in-flight fetch land against a
                     -- position firmware had already moved past, serving
                     -- data for the wrong address), just re-derived here
                     -- as an explicit tag check instead of an implicit
                     -- "does reg_erxrdpt still match" one.
                     rx_fetch_outstanding <= '0';
                     if not discard_fetch then
                        if fetch_target_is_b = '0' then
                           if bank_a_tag(2 downto 0) = RXB_PENDING and (bank_a_tag and x"FFF8") = rx_fetch_addr then
                              bank_a_data <= resp_rdata;
                              bank_a_tag <= rx_make_tag(rx_fetch_addr, RXB_VALID);
                           end if;
                        else
                           if bank_b_tag(2 downto 0) = RXB_PENDING and (bank_b_tag and x"FFF8") = rx_fetch_addr then
                              bank_b_data <= resp_rdata;
                              bank_b_tag <= rx_make_tag(rx_fetch_addr, RXB_VALID);
                           end if;
                        end if;
                     end if;
                  end if;
                  if mbox_active = mr_erxhead_poll then
                     reg_erxhead_ddr <= resp_rdata(15 downto 0);
                     reg_rx_wrpos <= resp_rdata(47 downto 32);
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

         ----------------------------------------------------------------
         -- Applied last so these win over same-cycle mailbox completion
         -- tag writes (VHDL last-assignment-wins).
         ----------------------------------------------------------------
         if ethrst_this_cycle then
            bank_a_tag <= RXB_EMPTY_TAG;
            bank_b_tag <= RXB_EMPTY_TAG;
            banksel <= '0';
            rx_fetch_outstanding <= '0';
            rx_miss <= '0';
            econ1_rxen <= '0';
            econ1_txrts <= '0';
            reg_pkt_delivered <= (others => '0');
            reg_erxhead_ddr <= (others => '0');
            reg_rx_wrpos <= (others => '0');
            rstseq <= not rstseq;
            dirty_status <= '1';
         elsif seek_this_cycle then
            bank_a_tag <= rx_make_tag(seek_addr_v, RXB_PENDING);
            bank_b_tag <= RXB_EMPTY_TAG;
            banksel <= '0';
         elsif reg_erxrdpt >= RX_BUF_START
            and reg_erxrdpt < RX_BUF_END
            -- At the write cursor there is no written word to fetch.
            -- Catch-up leaves ERXRDPT on the next header before the
            -- daemon publishes it; unstick must not fill that bank from
            -- stale DDR (same 0x51d8 HIT as unbounded readahead).
            and not (reg_rx_wrpos >= RX_BUF_START
                     and reg_rx_wrpos < RX_BUF_END
                     and (reg_erxrdpt and x"FFF8") = (reg_rx_wrpos and x"FFF8")) then
            -- Unstick: if the current bank isn't holding (and isn't
            -- already fetching) erxrdpt's word, start a fetch. Recovers
            -- the "VALID for the wrong address, nothing PENDING" wedge.
            if banksel = '0' then
               cur_bank_tag := bank_a_tag;
            else
               cur_bank_tag := bank_b_tag;
            end if;
            if not (cur_bank_tag(2 downto 0) = RXB_VALID
                    and (cur_bank_tag and x"FFF8") = (reg_erxrdpt and x"FFF8"))
               and not (cur_bank_tag(2 downto 0) = RXB_PENDING
                    and (cur_bank_tag and x"FFF8") = (reg_erxrdpt and x"FFF8")) then
               if banksel = '0' then
                  bank_a_tag <= rx_make_tag(reg_erxrdpt, RXB_PENDING);
               else
                  bank_b_tag <= rx_make_tag(reg_erxrdpt, RXB_PENDING);
               end if;
            end if;
         end if;

      end if;
   end process;

end implementation;
