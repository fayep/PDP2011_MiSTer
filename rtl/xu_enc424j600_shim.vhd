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
   constant DDR_ERXTAIL     : std_logic_vector(15 downto 0) := x"6038";

   -- hardcoded placeholder MAC (real DEC OUI 08-00-2B, never the
   -- zero/garbage pattern) -- see MAC-handling note above.
   -- byte order in this vector matches the SPI wire order sent by
   -- ADDR_MAADR3 below: index0=08,1=00,2=2B,3=AA,4=AA,5=AA
   constant PLACEHOLDER_MAC : std_logic_vector(47 downto 0) := x"AAAAAA2B0008";

   ----------------------------------------------------------------------
   -- SPI byte/word shift engine
   ----------------------------------------------------------------------
   type spi_state_type is (
      s_opcode, s_addr, s_data_in, s_data_out, s_ignore
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
   -- mailbox request queue (foreground SPI ops + background TXRTS_DONE
   -- poll share the one mailbox port; one process, one driver, per the
   -- header note above)
   ----------------------------------------------------------------------
   type mbox_req_type is (mr_none, mr_rxen, mr_txrts_req_set, mr_txrts_req_clear,
                           mr_etxst, mr_etxlen, mr_erxst, mr_erxtail,
                           mr_txrts_done_poll);
   signal fg_pending : mbox_req_type := mr_none;
   signal fg_wdata : std_logic_vector(63 downto 0) := (others => '0');

   type mbox_state_type is (m_idle, m_issue, m_wait_ack_drop);
   signal mbox_state : mbox_state_type := m_idle;
   signal mbox_active : mbox_req_type := mr_none;

   signal req_valid_i : std_logic := '0';
   signal req_addr_i : std_logic_vector(15 downto 0) := (others => '0');
   signal req_wdata_i : std_logic_vector(63 downto 0) := (others => '0');
   signal req_rw_i : std_logic := '0';

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
   req_be <= x"FF";
   req_rw <= req_rw_i;

   process(cpuclk, reset)
      variable estat_val : std_logic_vector(15 downto 0);
      variable in_byte : std_logic_vector(7 downto 0);
      variable out_byte : std_logic_vector(7 downto 0);
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

         fg_pending <= mr_none;
         fg_wdata <= (others => '0');
         mbox_state <= m_idle;
         mbox_active <= mr_none;
         req_valid_i <= '0';
         req_addr_i <= (others => '0');
         req_wdata_i <= (others => '0');
         req_rw_i <= '0';
         bg_counter <= 0;

      elsif cpuclk'event and cpuclk = '1' then

         ----------------------------------------------------------------
         -- SPI shift engine
         ----------------------------------------------------------------
         if xu_cs = '1' then
            spi_state <= s_opcode;
            bit_count <= 0;
            word_count <= 0;
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
                        spi_state <= s_ignore;  -- 1-byte instruction, no-op
                     elsif in_byte = OP_RCRU or in_byte = OP_WCRU
                        or in_byte = OP_BFSU or in_byte = OP_BFCU then
                        spi_state <= s_addr;
                     else
                        -- unimplemented (wgpdata/rrxdata/setpktdec/etc) --
                        -- out of Phase 2's initial scope; consume and
                        -- ignore rather than hang.
                        spi_state <= s_ignore;
                     end if;
                  else
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
                           when ADDR_ESTAT => out_byte := x"00";  -- estat_val(7:0), bit12 lives in the high byte
                           when ADDR_ECON1 => out_byte := "000000" & econ1_txrts & econ1_rxen;
                           when ADDR_ECON2 => out_byte := x"00";
                           when ADDR_MAADR3 => out_byte := PLACEHOLDER_MAC(7 downto 0);
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
                           estat_val := x"1000";  -- bit 12 (clkrdy) always set
                           if word_count = 0 then out_byte := estat_val(7 downto 0);
                           else out_byte := estat_val(15 downto 8); end if;
                        when ADDR_ECON1 =>
                           if word_count = 0 then out_byte := "000000" & econ1_txrts & econ1_rxen;
                           else out_byte := x"00"; end if;
                        when ADDR_ECON2 =>
                           out_byte := x"00";
                        when ADDR_MAADR3 =>
                           case word_count is
                              when 0 => out_byte := PLACEHOLDER_MAC(7 downto 0);
                              when 1 => out_byte := PLACEHOLDER_MAC(15 downto 8);
                              when 2 => out_byte := PLACEHOLDER_MAC(23 downto 16);
                              when 3 => out_byte := PLACEHOLDER_MAC(31 downto 24);
                              when 4 => out_byte := PLACEHOLDER_MAC(39 downto 32);
                              when others => out_byte := PLACEHOLDER_MAC(47 downto 40);
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
                  case fg_pending is
                     when mr_rxen            => req_addr_i <= DDR_RXEN;      req_wdata_i <= x"0000000000000001";
                     when mr_txrts_req_set   => req_addr_i <= DDR_TXRTS_REQ; req_wdata_i <= x"0000000000000001";
                     when mr_txrts_req_clear => req_addr_i <= DDR_TXRTS_REQ; req_wdata_i <= x"0000000000000000";
                     when mr_etxst           => req_addr_i <= DDR_ETXST;     req_wdata_i <= fg_wdata;
                     when mr_etxlen          => req_addr_i <= DDR_ETXLEN;    req_wdata_i <= fg_wdata;
                     when mr_erxst           => req_addr_i <= DDR_ERXST;     req_wdata_i <= fg_wdata;
                     when mr_erxtail         => req_addr_i <= DDR_ERXTAIL;   req_wdata_i <= fg_wdata;
                     when others             => null;
                  end case;
                  mbox_state <= m_issue;
                  bg_counter <= 0;
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
