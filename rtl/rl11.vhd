
--
-- Copyright (c) 2008-2021 Sytse van Slooten
--
-- Permission is hereby granted to any person obtaining a copy of these VHDL source files and
-- other language source files and associated documentation files ("the materials") to use
-- these materials solely for personal, non-commercial purposes.
-- You are also granted permission to make changes to the materials, on the condition that this
-- copyright notice is retained unchanged.
--
-- The materials are distributed in the hope that they will be useful, but WITHOUT ANY WARRANTY;
-- without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
--

-- $Revision$

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity rl11 is
   port(
      base_addr : in std_logic_vector(17 downto 0);
      ivec : in std_logic_vector(8 downto 0);

      br : out std_logic;
      bg : in std_logic;
      int_vector : out std_logic_vector(8 downto 0);

      npr : out std_logic;
      npg : in std_logic;

      bus_addr_match : out std_logic;
      bus_addr : in std_logic_vector(17 downto 0);
      bus_dati : out std_logic_vector(15 downto 0);
      bus_dato : in std_logic_vector(15 downto 0);
      bus_control_dati : in std_logic;
      bus_control_dato : in std_logic;
      bus_control_datob : in std_logic;

      bus_master_addr : out std_logic_vector(17 downto 0);
      bus_master_dati : in std_logic_vector(15 downto 0);
      bus_master_dato : out std_logic_vector(15 downto 0);
      bus_master_control_dati : out std_logic;
      bus_master_control_dato : out std_logic;
      bus_master_nxm : in std_logic;

      -- native hps_io block-transfer protocol (replaces the sdspi.vhd
      -- fake-SD-over-SPI emulation layer -- Phase 3 of the disk-transport
      -- plan, same pattern as rh11.vhd/rk11.vhd's Phase 1/2). sd_* live in
      -- the clk_100mhz domain (hps_io's own domain); RL11's own DMA/
      -- busmaster logic lives in cpuclk (clk/nclk below), bridged via a
      -- Gray-coded 2-bit request/done toggle pair per direction plus a
      -- dual-clock sector buffer -- see the "sd_* <-> busmaster bridge"
      -- section below. sd_addr already packs two real 128-word sectors
      -- per 256-word hps_io block (sd_half picks the half) -- that
      -- addressing math is untouched by this phase, only the transport
      -- backing it changed.
      sd_lba : out std_logic_vector(31 downto 0);
      sd_rd : out std_logic;
      sd_wr : out std_logic;
      sd_ack : in std_logic;
      sd_buff_addr : in std_logic_vector(8 downto 0);
      sd_buff_dout : in std_logic_vector(15 downto 0);
      sd_buff_din : out std_logic_vector(15 downto 0);
      sd_buff_wr : in std_logic;
      clk_100mhz : in std_logic;

      have_rl : in integer range 0 to 1;
      img_mounted : in integer range 0 to 1 := 1;                    -- is a disk image actually mounted; a real RL01/RL02
                                                                      -- drive always exists once the controller is wired up,
                                                                      -- so "no medium" is reported via csr_drdy (RLCS DRDY,
                                                                      -- bit 00) instead of hiding the controller itself
      reset : in std_logic;
      clk50mhz : in std_logic;
      nclk : in std_logic;
      clk : in std_logic;

      -- Passive event tap for tracecap.vhd (Faye: "I think you'll need
      -- to use READ+GO as the trigger" -- matches pdp11dis/rldma.py's
      -- own philosophy of replaying the real hardware trigger rather
      -- than snooping completion: RLDA/RLBA(+ext)/RLMP are already
      -- loaded and stable the instant GO+READ commits, since software
      -- always writes them first, so no latching through the multi-
      -- cycle busmaster state machine is needed at all). Pulses once
      -- when sdcard_read_start actually commits (rl11.vhd's own
      -- "when "110"|"001"" READ/WCHK branch), not on every RLCS write --
      -- e.g. SEEK/GET STATUS never pulse this.
      trace_disk_valid : out std_logic;
      trace_disk_dar   : out std_logic_vector(15 downto 0);  -- raw RLDA -- convert with the
                                                              -- same GET_DA formula rldma.py uses
      trace_disk_dest  : out std_logic_vector(17 downto 0);  -- csr_ba & bar & '0', the untouched
                                                              -- starting destination address
      trace_disk_wc    : out std_logic_vector(12 downto 0);  -- wcp, already-positive word count

      -- mmu.vhd's live KERNEL D-space AND I-space PAR5/PAR6 copies
      -- (same nclk domain as this entity). Sampled and stamped onto
      -- trace_disk_par5/6 / trace_disk_kipar5/6 at the SAME trigger
      -- moment as dar/dest/wc -- becomes part of the SAME held-stable
      -- transaction snapshot, so it crosses into tracecap's clock
      -- domain the same safe way dar/dest/wc already do. No event, no
      -- filtering: every disk event just gets whatever these currently
      -- hold. trace_kipar5/6 are the pair that actually matters for
      -- RSTS's real overlay mechanism -- see mmu.vhd's port comment.
      trace_kdpar5     : in  std_logic_vector(15 downto 0);
      trace_kdpar6     : in  std_logic_vector(15 downto 0);
      trace_disk_par5  : out std_logic_vector(15 downto 0);
      trace_disk_par6  : out std_logic_vector(15 downto 0);
      trace_kipar5       : in  std_logic_vector(15 downto 0);
      trace_kipar6       : in  std_logic_vector(15 downto 0);
      trace_disk_kipar5  : out std_logic_vector(15 downto 0);
      trace_disk_kipar6  : out std_logic_vector(15 downto 0)
   );
end rl11;

architecture implementation of rl11 is


-- regular bus interface

signal base_addr_match : std_logic;
signal interrupt_trigger : std_logic := '0';
signal int_owed : std_logic := '0';        -- latched interrupt-pending: set by a
                                            -- completion (CRDY 0->1) or by IE being armed
                                            -- on an already-ready controller; gated by IE,
                                            -- cleared only when the interrupt is granted.
signal csr_crdy_d : std_logic := '1';       -- CRDY delayed one cycle, for edge detect
signal csr_ie_d : std_logic := '0';         -- IE delayed one cycle, for edge detect
type interrupt_state_type is (
   i_idle,
   i_req,
   i_wait
);
signal interrupt_state : interrupt_state_type := i_idle;

-- rl11 registers

signal csr_err : std_logic;
signal csr_de : std_logic;
signal csr_nxm : std_logic;
signal csr_e : std_logic_vector(2 downto 0);
signal csr_ds : std_logic_vector(1 downto 0);
signal csr_crdy : std_logic;
signal csr_ie : std_logic;
signal csr_ba : std_logic_vector(17 downto 16);
signal csr_fc : std_logic_vector(2 downto 0);
signal csr_drdy : std_logic;
signal have_media : std_logic;                                        -- img_mounted, as a std_logic

-- explicit initial values (defense in depth): the reset branch above
-- already covers these every reset, but Cyclone V FPGA power-up state
-- is not reliably zero for a signal that never had one, and this is
-- exactly what real hardware showed for bar -- see the reset branch's
-- comment.
signal bar : std_logic_vector(15 downto 1) := (others => '0');

-- dar subfields : read/write

subtype dnhs_subtype is std_logic;
type dnhs_type is array(3 downto 0) of dnhs_subtype;
signal dnhs : dnhs_type;
subtype dnca_subtype is std_logic_vector(8 downto 0);
type dnca_type is array(3 downto 0) of dnca_subtype;
signal dnca : dnca_type;

signal dar : std_logic_vector(15 downto 0) := (others => '0');

-- mpr subfields : get status
signal gs_vc : std_logic;          -- volume changed

signal mpr : std_logic_vector(15 downto 0) := (others => '0');

-- mpr subfield; wc is only writeable field, but it is not readable
signal wcp : std_logic_vector(12 downto 0) := (others => '0');               -- positive value of wc

-- others

signal start : std_logic;
signal write_start : std_logic;
signal update_mpr : std_logic;


signal hs_offset : std_logic_vector(17 downto 0);
signal ca_offset : std_logic_vector(17 downto 0);
signal dn_offset : std_logic_vector(17 downto 0);
signal sd_index : unsigned(17 downto 0);        -- linear real-sector number
signal sd_half : std_logic;                     -- which 128-word half of the SD block this real sector lives in
signal sd_addr : std_logic_vector(17 downto 0);

signal work_bar : std_logic_vector(17 downto 1);

-- sd_* transfer-buffer interface signals (formerly the sdspi component's
-- port contract -- same names/semantics, now fulfilled by the "sd_* <->
-- busmaster bridge" below instead of a real sdspi.vhd instance)

signal sdcard_xfer_addr : integer range 0 to 255;
signal sdcard_xfer_read : std_logic;
signal sdcard_xfer_out : std_logic_vector(15 downto 0);
signal sdcard_xfer_write : std_logic;
signal sdcard_xfer_in : std_logic_vector(15 downto 0);

signal sdcard_idle : std_logic;
signal sdcard_read_start : std_logic;
signal sdcard_read_ack : std_logic;
signal sdcard_read_done : std_logic;
signal sdcard_write_start : std_logic;
signal sdcard_write_ack : std_logic;
signal sdcard_write_done : std_logic;
signal sdcard_error : std_logic;                       -- no real SD-protocol errors possible
                                                          -- any more (hps_io's virtual disk has no
                                                          -- CRC/card-fault concept) -- tied to '0'

-- dual-clock sector buffer: same proven idiom rh11.vhd/rk11.vhd's Phase
-- 1/2 rewrites used (plain VHDL array, one port per clock domain --
-- Quartus infers M10K dual-clock dual-port block RAM from exactly this
-- shape). rsector is filled by hps_io (clk_100mhz, via sd_buff_wr) and
-- drained by the busmaster (clk); wsector is filled by the busmaster
-- (clk) and drained by hps_io (clk_100mhz, via sd_buff_addr/din). One
-- 256-word buffer per hps_io block, same as RH11/RK11 -- RL11's own
-- sub-block (128-word) packing math (sd_half) is unchanged, it just
-- addresses into the same 256-word buffer at offset 0 or 128.
type rl11_sector_buf_t is array(0 to 255) of std_logic_vector(15 downto 0);
signal rsector : rl11_sector_buf_t;
signal wsector : rl11_sector_buf_t;

-- sd_* <-> busmaster CDC bridge: a Gray-coded 2-bit request/done toggle
-- pair per direction, 2-FF synchronized each way -- see rh11.vhd's Phase 1
-- comment on why Gray coding (not a naive multi-bit synchronizer) is
-- required here. Sequence used: 00 -> 01 -> 11 -> 10 -> 00 ...
signal read_req_gray   : std_logic_vector(1 downto 0) := "00";  -- cpuclk domain
signal read_req_gray_r1, read_req_gray_r2 : std_logic_vector(1 downto 0) := "00"; -- synced into clk_100mhz
signal read_done_gray  : std_logic_vector(1 downto 0) := "00";  -- clk_100mhz domain
signal read_done_gray_r1, read_done_gray_r2 : std_logic_vector(1 downto 0) := "00"; -- synced into cpuclk

signal write_req_gray  : std_logic_vector(1 downto 0) := "00";  -- cpuclk domain
signal write_req_gray_r1, write_req_gray_r2 : std_logic_vector(1 downto 0) := "00"; -- synced into clk_100mhz
signal write_done_gray : std_logic_vector(1 downto 0) := "00";  -- clk_100mhz domain
signal write_done_gray_r1, write_done_gray_r2 : std_logic_vector(1 downto 0) := "00"; -- synced into cpuclk

signal sd_lba_r : std_logic_vector(31 downto 0);  -- latched into clk_100mhz domain
                                                    -- when a request edge is seen; sd_addr
                                                    -- (source side) is already held stable
                                                    -- for the whole transfer by construction
signal sd_half_r : std_logic;                      -- sd_half latched alongside sd_lba_r --
                                                     -- see the write-preread comment below

type xfer_state_t is (
   xfer_idle,
   xfer_read_wait,
   xfer_read_done_hold,
   xfer_write_wait,
   xfer_write_done_hold
);
signal xfer_state : xfer_state_t := xfer_idle;

-- RL11-specific vs. rh11.vhd/rk11.vhd's bridge: a WRITE only ever stages
-- ONE 128-word real-sector half into wsector (busmaster_write's own
-- sectorcounter caps every pass at 128 words -- see its own comment),
-- but hps_io's sd_wr always commits the WHOLE 256-word block. Unlike
-- RH11/RK11 (whose real sector already IS a full 256-word block, so the
-- controller always fills the entire buffer), naively sd_wr-ing wsector
-- here would write the untouched sibling half as stale/undefined
-- garbage, corrupting the sector packed alongside the one actually being
-- written -- found via tb_rl11_dma.vhd's write-then-read-sibling check,
-- not assumed. Fixed with a transparent read-modify-write entirely at
-- this bridge layer (rl11.vhd's busmaster logic above is completely
-- unaware of it, same as sdspi.vhd's old single-buffer design made this
-- work for free): before committing a write, first sd_rd the SAME block
-- into rsector, then copy just the OTHER half of rsector into wsector
-- (sd_half_r picks which half is "other"), THEN sd_wr the now-complete
-- wsector.
type sd_state_t is (
   sd_idle,
   sd_read_req,
   sd_read_xfer,
   sd_write_preread_req,
   sd_write_preread_xfer,
   sd_write_req,
   sd_write_xfer
);
signal sd_state : sd_state_t := sd_idle;

-- busmaster controller

signal nxm : std_logic;
signal sectorcounter : std_logic_vector(8 downto 0);            -- counter within sector

type busmaster_state_t is (
   busmaster_idle,
   busmaster_read,
   busmaster_readh,
   busmaster_readh2,
   busmaster_read1,
   busmaster_read_done,
   busmaster_write1,
   busmaster_write,
   busmaster_writen,
   busmaster_write_wait,
   busmaster_write_done,
   busmaster_wait
);
signal busmaster_state : busmaster_state_t := busmaster_idle;

begin

-- sd_* <-> busmaster bridge
--
-- Replaces the "sd1: sdspi port map(...)" black box. Fulfils the exact
-- same signal contract the busmaster/register-file logic below already
-- expects (sdcard_idle/read_start/read_ack/read_done/write_start/
-- write_ack/write_done/xfer_*), so none of that logic -- including the
-- sd_half packed-addressing math -- needed to change; only what backs
-- those signals did. See rh11.vhd's Phase 1 rewrite for the full
-- rationale; this is the same pattern verbatim.

   sdcard_error <= '0';

-- cpuclk-domain half: drives sdcard_idle/read_done/write_done, consumes
-- sdcard_read_start/read_ack/write_start/write_ack. Kicks off a transfer
-- by toggling the Gray request code; waits for the synchronized Gray done
-- code to change before declaring done.

   process(clk, reset)
   begin
      if clk = '1' and clk'event then
         if reset = '1' then
            xfer_state <= xfer_idle;
            sdcard_read_done <= '0';
            sdcard_write_done <= '0';
            read_req_gray <= "00";
            write_req_gray <= "00";
            read_done_gray_r1 <= "00";
            read_done_gray_r2 <= "00";
            write_done_gray_r1 <= "00";
            write_done_gray_r2 <= "00";
         else
            -- 2-FF synchronizers for the two done-side Gray codes
            read_done_gray_r1 <= read_done_gray;
            read_done_gray_r2 <= read_done_gray_r1;
            write_done_gray_r1 <= write_done_gray;
            write_done_gray_r2 <= write_done_gray_r1;

            case xfer_state is
               when xfer_idle =>
                  sdcard_read_done <= '0';
                  sdcard_write_done <= '0';
                  if sdcard_read_start = '1' then
                     sd_lba_r <= "00000000000000" & sd_addr;   -- stable well before this point
                     case read_req_gray is
                        when "00" => read_req_gray <= "01";
                        when "01" => read_req_gray <= "11";
                        when "11" => read_req_gray <= "10";
                        when others => read_req_gray <= "00";
                     end case;
                     xfer_state <= xfer_read_wait;
                  elsif sdcard_write_start = '1' then
                     sd_lba_r <= "00000000000000" & sd_addr;
                     sd_half_r <= sd_half;
                     case write_req_gray is
                        when "00" => write_req_gray <= "01";
                        when "01" => write_req_gray <= "11";
                        when "11" => write_req_gray <= "10";
                        when others => write_req_gray <= "00";
                     end case;
                     xfer_state <= xfer_write_wait;
                  end if;

               when xfer_read_wait =>
                  if read_done_gray_r2 = read_req_gray then
                     sdcard_read_done <= '1';
                     xfer_state <= xfer_read_done_hold;
                  end if;

               when xfer_read_done_hold =>
                  if sdcard_read_ack = '1' then
                     sdcard_read_done <= '0';
                     xfer_state <= xfer_idle;
                  end if;

               when xfer_write_wait =>
                  if write_done_gray_r2 = write_req_gray then
                     sdcard_write_done <= '1';
                     xfer_state <= xfer_write_done_hold;
                  end if;

               when xfer_write_done_hold =>
                  if sdcard_write_ack = '1' then
                     sdcard_write_done <= '0';
                     xfer_state <= xfer_idle;
                  end if;

               when others =>
                  xfer_state <= xfer_idle;
            end case;
         end if;
      end if;
   end process;

   sdcard_idle <= '1' when xfer_state = xfer_idle else '0';

-- clk_100mhz-domain half: watches the synchronized Gray request codes,
-- drives sd_lba/sd_rd/sd_wr, waits for sd_ack's standard hps_io
-- rise-then-fall sequence, then toggles the Gray done code back.

   process(clk_100mhz, reset)
   begin
      if clk_100mhz = '1' and clk_100mhz'event then
         if reset = '1' then
            sd_state <= sd_idle;
            sd_rd <= '0';
            sd_wr <= '0';
            sd_lba <= (others => '0');
            read_req_gray_r1 <= "00";
            read_req_gray_r2 <= "00";
            write_req_gray_r1 <= "00";
            write_req_gray_r2 <= "00";
            read_done_gray <= "00";
            write_done_gray <= "00";
         else
            -- 2-FF synchronizers for the two request-side Gray codes
            read_req_gray_r1 <= read_req_gray;
            read_req_gray_r2 <= read_req_gray_r1;
            write_req_gray_r1 <= write_req_gray;
            write_req_gray_r2 <= write_req_gray_r1;

            case sd_state is
               when sd_idle =>
                  if read_req_gray_r2 /= read_done_gray then
                     sd_lba <= sd_lba_r;
                     sd_rd <= '1';
                     sd_state <= sd_read_req;
                  elsif write_req_gray_r2 /= write_done_gray then
                     -- read-modify-write: fetch the current on-disk block
                     -- first (see the sd_state_t declaration comment) --
                     -- do NOT sd_wr yet.
                     sd_lba <= sd_lba_r;
                     sd_rd <= '1';
                     sd_state <= sd_write_preread_req;
                  end if;

               when sd_read_req =>
                  if sd_ack = '1' then
                     sd_rd <= '0';
                     sd_state <= sd_read_xfer;
                  end if;

               when sd_read_xfer =>
                  if sd_ack = '0' then
                     read_done_gray <= read_req_gray_r2;
                     sd_state <= sd_idle;
                  end if;

               when sd_write_preread_req =>
                  if sd_ack = '1' then
                     sd_rd <= '0';
                     sd_state <= sd_write_preread_xfer;
                  end if;

               when sd_write_preread_xfer =>
                  -- rsector now holds a fresh read of the whole on-disk
                  -- block (both halves); wsector holds the controller's
                  -- own freshly-staged half. No array-to-array copy here
                  -- -- see the sd_buff_din mux below, which picks whichever
                  -- of the two already has the right data for each half,
                  -- so wsector is never written from this (clk_100mhz)
                  -- domain -- it stays single-driver (cpuclk-only),
                  -- exactly matching the dual-clock-RAM port template.
                  if sd_ack = '0' then
                     sd_lba <= sd_lba_r;
                     sd_wr <= '1';
                     sd_state <= sd_write_req;
                  end if;

               when sd_write_req =>
                  if sd_ack = '1' then
                     sd_wr <= '0';
                     sd_state <= sd_write_xfer;
                  end if;

               when sd_write_xfer =>
                  if sd_ack = '0' then
                     write_done_gray <= write_req_gray_r2;
                     sd_state <= sd_idle;
                  end if;

               when others =>
                  sd_state <= sd_idle;
            end case;
         end if;
      end if;
   end process;

-- dual-clock sector buffer access. rsector's write port (hps_io fills it
-- during a read) and wsector's read port (hps_io drains it during a
-- write) live in clk_100mhz; the other two ports live in clk, matching
-- what the busmaster process below already expects from
-- sdcard_xfer_out/in/read/write/addr.

   process(clk_100mhz)
   begin
      if clk_100mhz = '1' and clk_100mhz'event then
         if sd_buff_wr = '1' then
            rsector(conv_integer(sd_buff_addr)) <= sd_buff_dout;
         end if;
         -- write-commit read-modify-write mux: sd_buff_addr(7) is '0' for
         -- the low half (0-127) and '1' for the high half (128-255).
         -- wsector holds the controller's freshly-staged half (the one
         -- sd_half_r names); rsector holds the just-prereread sibling
         -- half straight off disk -- see the sd_state_t declaration
         -- comment above. During a plain read, sd_buff_din isn't
         -- consumed, so this mux is harmless then.
         if sd_half_r = sd_buff_addr(7) then
            sd_buff_din <= wsector(conv_integer(sd_buff_addr));
         else
            sd_buff_din <= rsector(conv_integer(sd_buff_addr));
         end if;
      end if;
   end process;

   process(clk)
   begin
      if clk = '1' and clk'event then
         sdcard_xfer_out <= rsector(sdcard_xfer_addr);
         if sdcard_xfer_write = '1' then
            wsector(sdcard_xfer_addr) <= sdcard_xfer_in;
         end if;
      end if;
   end process;


-- regular bus interface

   base_addr_match <= '1' when base_addr(17 downto 3) = bus_addr(17 downto 3) and have_rl = 1 else '0';
   bus_addr_match <= base_addr_match;

   have_media <= '1' when img_mounted = 1 else '0';

-- specific logic for the device

   csr_drdy <= have_media;             -- drive ready reflects whether a disk is actually mounted
   csr_de <= '0';                      -- the drive has no errors

   csr_err <= '0' when csr_e = "000" and csr_nxm = '0' and csr_de = '0' else '1';


-- regular bus interface : handle register contents and dependent logic

   process(nclk, reset)
   begin
      if nclk = '1' and nclk'event then
         if reset = '1' then

            -- unconditional, not gated behind "if have_rl = 1" -- have_rl
            -- is a static always-1 generic here so this makes no logical
            -- difference, but rh11.vhd/rk11.vhd's equivalent registers
            -- reset unconditionally and this block should match that
            -- shape rather than being a structural outlier. Real hardware
            -- was observed with bar reading back a stuck-nonzero value
            -- (0x1000) immediately after a genuine cold reset, before any
            -- software ran -- GHDL simulation (which applies its initial
            -- reset uniformly) never reproduced this, consistent with
            -- this codebase's own existing caution just below about
            -- Cyclone V FPGA power-up state not being reliably zero for
            -- every signal without an explicit initial value.
            csr_fc <= "000";
            csr_ba <= "00";
            csr_ie <= '0';
            csr_crdy <= '1';
            csr_ds <= "00";
            csr_e <= "000";
            csr_nxm <= '0';

            bar <= "000000000000000";
            dar <= "0000000000000000";
            mpr <= "0000000000000000";
            wcp <= "0000000000000";

            dnhs(conv_integer(3)) <= '0';
            dnhs(conv_integer(2)) <= '0';
            dnhs(conv_integer(1)) <= '0';
            dnhs(conv_integer(0)) <= '0';
            dnca(conv_integer(3)) <= (others => '0');
            dnca(conv_integer(2)) <= (others => '0');
            dnca(conv_integer(1)) <= (others => '0');
            dnca(conv_integer(0)) <= (others => '0');

            start <= '0';

            write_start <= '0';
            sdcard_read_start <= '0';       -- was never reset -- 'U' in sim (blocks the
                                             -- idle/read-start guard forever); real hardware
                                             -- apparently gets away with it only by luck of
                                             -- Cyclone V's LUT-FF power-up-to-0 convention
                                             -- (same bug found and fixed in rk11.vhd)

            gs_vc <= '1';
            update_mpr <= '0';

            br <= '0';
            interrupt_trigger <= '0';
            int_owed <= '0';
            csr_crdy_d <= '1';
            csr_ie_d <= '0';
            interrupt_state <= i_idle;

         else

            trace_disk_valid <= '0';  -- one-cycle pulse default; the READ/WCHK
                                       -- branch below overrides it for its cycle

            if have_rl = 1 then

               case interrupt_state is

                  when i_idle =>

                     br <= '0';
                     if csr_ie = '1' and int_owed = '1' then
                        if interrupt_trigger = '0' then
                           interrupt_state <= i_req;
                           br <= '1';
                           interrupt_trigger <= '1';
                        end if;
                     else
                        interrupt_trigger <= '0';
                     end if;

                  when i_req =>
                     if bg = '1' then
                        int_vector <= ivec;
                        br <= '0';
                        interrupt_state <= i_wait;
                     end if;

                  when i_wait =>
                     if bg = '0' then
                        interrupt_state <= i_idle;
                        int_owed <= '0';                                      -- interrupt granted: clear the pending latch
                     end if;

                  when others =>
                     interrupt_state <= i_idle;

               end case;

               -- Latch an interrupt request into int_owed: on CRDY 0->1 (command/seek
               -- complete) regardless of IE, or on IE being armed while CRDY is already
               -- set (the classic "enable interrupts on a ready controller" probe).
               -- After the case so a completion coincident with a grant is not lost.
               csr_crdy_d <= csr_crdy;
               csr_ie_d <= csr_ie;
               if (csr_crdy = '1' and csr_crdy_d = '0')
                  or (csr_ie = '1' and csr_ie_d = '0' and csr_crdy = '1') then
                  int_owed <= '1';
               end if;

            else
               br <= '0';
            end if;


            if have_rl = 1 then

               if base_addr_match = '1' and bus_control_dati = '1' then
                  case bus_addr(2 downto 1) is
                     when "00" =>
                        bus_dati <= csr_err & csr_de & csr_nxm & csr_e & csr_ds & csr_crdy & csr_ie & csr_ba & csr_fc & csr_drdy;
                     when "01" =>
                        bus_dati <= bar & '0';
                     when "10" =>
                        bus_dati <= dar;
                     when "11" =>

                        case csr_fc is
                           when "010" =>                                  -- get status
                              bus_dati(15 downto 14) <= "00";                      -- write data error, current in head error; not applicable
                              bus_dati(13) <= '0';                                 -- means write protect is off
                              bus_dati(12 downto 10) <= "000";                     -- seek time out, spin error, write gate error; not applicable
                              bus_dati(9) <= '0';                                  -- gs_vc; disabled because it prevents (at least) V7 from booting
                              bus_dati(8) <= '0';                                  -- drive select error, not applicable
                              bus_dati(7) <= '1';                                  -- 0 means rl01, 1 means rl02
                              bus_dati(6) <= dnhs(conv_integer(csr_ds));           -- current head
                              bus_dati(5) <= '0';                                  -- cover open
--                              if sd_state = sd_idle then                           -- idle is the only state the cpu should ever be able to witness, unless the card interface is recovering from an error. All busy states are passed through while the cpu is stopped.
                              bus_dati(4 downto 0) <= "11101";                     -- heads out, brush home, locked
--                              else
--                                 bus_dati(4 downto 0) <= "00000";                  -- load cartridge
--                              end if;

                           when "100" =>                                  -- read header
                              bus_dati <= dnca(conv_integer(csr_ds)) & dnhs(conv_integer(csr_ds)) & dar(5 downto 0);                   -- 2nd and 3rd read should give zeros and crc, respectively. Is anyone interested? Unix doesn't seem to be.

                           when others =>
                              bus_dati <= (others => '0');
                        end case;
                     when others =>
                        bus_dati <= (others => '0');
                  end case;
               end if;

               if base_addr_match = '1' and bus_control_dato = '1' then

                  if bus_control_datob = '0' or (bus_control_datob = '1' and bus_addr(0) = '0') then
                     case bus_addr(2 downto 1) is
                        when "00" =>
                           csr_fc <= bus_dato(3 downto 1);
                           csr_ba <= bus_dato(5 downto 4);
                           csr_ie <= bus_dato(6);
                           csr_crdy <= bus_dato(7);
                        when "01" =>
                           bar(7 downto 1) <= bus_dato(7 downto 1);
                        when "10" =>
                           dar(7 downto 0) <= bus_dato(7 downto 0);
                        when "11" =>
                           mpr(7 downto 0) <= bus_dato(7 downto 0);
                           update_mpr <= '1';
                        when others =>
                           null;
                     end case;
                  end if;

                  if bus_control_datob = '0' or (bus_control_datob = '1' and bus_addr(0) = '1') then
                     case bus_addr(2 downto 1) is
                        when "00" =>
                           csr_e <= "000";
                           csr_nxm <= '0';
                           csr_ds <= bus_dato(9 downto 8);
                        when "01" =>
                           bar(15 downto 8) <= bus_dato(15 downto 8);
                        when "10" =>
                           dar(15 downto 8) <= bus_dato(15 downto 8);
                        when "11" =>
                           mpr(15 downto 8) <= bus_dato(15 downto 8);
                           update_mpr <= '1';
                        when others =>
                           null;
                     end case;
                  end if;

               end if;

               if update_mpr = '1' then
                  wcp <= (not mpr(12 downto 0)) + 1;
                  update_mpr <= '0';
               end if;

               if csr_crdy = '0' and start = '0' then
                  if have_media = '1' or csr_fc = "000" then          -- no-op always allowed, like
                                                                       -- RH11's RIP/RK11's control-reset exemption
                     start <= '1';
                  else
                     csr_e <= "001";                                  -- operation incomplete: no medium
                     csr_crdy <= '1';
                  end if;
               end if;

               if start = '1' then
                  case csr_fc is

                     when "000" =>                                  -- no-op
                        csr_crdy <= '1';
                        start <= '0';

--                      when "001" =>                                        -- write check... we're not doing any of that, really.
--                         csr_e <= "000";                                            -- make sure error bits are clear
--                         csr_nxm <= '0';
--                         csr_crdy <= '1';
--                         start <= '0';

                     when "010" =>                                        -- get status
                        if dar(1) = '0' then                                       -- check if go bit is set
                           csr_e <= "001";                                         -- if not, signal error. zrlg checks this, thats why
                        end if;
                        if dar(3) = '1' then                                       -- reset error
                           gs_vc <= '0';                                           -- reset volume changed
                        end if;
                        csr_crdy <= '1';
                        start <= '0';

                     when "011" =>                                        -- seek
                        if dar(2) = '1' then
                           dnca(conv_integer(csr_ds)) <= dnca(conv_integer(csr_ds)) + dar(15 downto 7);
                        else
                           dnca(conv_integer(csr_ds)) <= dnca(conv_integer(csr_ds)) - dar(15 downto 7);
                        end if;
                        dnhs(conv_integer(csr_ds)) <= dar(4);
                        csr_crdy <= '1';
                        start <= '0';

                     when "100" =>                                        -- read header
                        if unsigned(dar(5 downto 0)) < unsigned'("100111") then             -- don't increment beyond 047=39.
                           dar(5 downto 0) <= dar(5 downto 0) + 1;
                        else
                           dar(5 downto 0) <= "000000";                   -- set to 0 on track overrun, does that make sense?
                        end if;
                        csr_crdy <= '1';
                        start <= '0';

                     when "110" | "001" =>                                     -- read or write check
                        if dnca(conv_integer(csr_ds)) = dar(15 downto 7)
                        and dnhs(conv_integer(csr_ds)) = dar(6) then
                           if sdcard_idle = '1' and sdcard_read_start = '0' and sdcard_read_done = '0' then
                              if unsigned(dar(5 downto 0)) >= unsigned'("101000") then
                                 csr_e <= "101";
                                 csr_crdy <= '1';
                                 start <= '0';
                              else
                                 sdcard_read_start <= '1';
                                 trace_disk_valid <= '1';
                                 trace_disk_dar  <= dar;
                                 trace_disk_dest <= csr_ba & bar & '0';
                                 trace_disk_wc   <= wcp;
                                 trace_disk_par5 <= trace_kdpar5;
                                 trace_disk_par6 <= trace_kdpar6;
                                 trace_disk_kipar5 <= trace_kipar5;
                                 trace_disk_kipar6 <= trace_kipar6;
                              end if;
                           elsif sdcard_read_ack = '1' and sdcard_read_done = '0' and sdcard_read_start = '1' then
                              sdcard_read_start <= '0';

                              if nxm = '0' and sdcard_error = '0' then
                                 csr_ba <= work_bar(17 downto 16);
                                 bar <= work_bar(15 downto 1);
                                 if unsigned(dar(5 downto 0)) < unsigned'("100111") then             -- don't increment beyond 047=39.
                                    dar(5 downto 0) <= dar(5 downto 0) + 1;
                                 else
                                    dar(5 downto 0) <= "101000";                -- acc. manual, should be set to 050/40. on track overrun
                                 end if;

                                 if unsigned(wcp) > unsigned'("0000010000000") then                  -- check if we need to do another sector, and setup for the next round if so
                                    wcp <= unsigned(wcp) - 128;
                                    if dar(5 downto 0) = "101000" then
                                       start <= '0';
                                       csr_e <= "101";                                -- overrun, hnf
                                       csr_crdy <= '1';
                                    end if;
                                 else
                                    csr_crdy <= '1';
                                    start <= '0';
                                 end if;

                              else

                                 csr_ba <= work_bar(17 downto 16);
                                 bar <= work_bar(15 downto 1);
                                 start <= '0';
                                 if nxm = '1' then
                                    csr_e <= "000";
                                    csr_nxm <= '1';
                                 end if;
                                 if sdcard_error = '1' then
                                    csr_e <= "011";
                                 end if;
                                 csr_crdy <= '1';
                              end if;
                           end if;
                        else
                           csr_e <= "101";
                           csr_crdy <= '1';
                           start <= '0';
                        end if;


                     when "101" =>                                        -- write
                        if dnca(conv_integer(csr_ds)) = dar(15 downto 7)
                        and dnhs(conv_integer(csr_ds)) = dar(6) then
                           if sdcard_idle = '1' and write_start = '0' then
                              if unsigned(dar(5 downto 0)) >= unsigned'("101000") then
                                 csr_e <= "101";
                                 csr_crdy <= '1';
                                 start <= '0';
                              else
                                 write_start <= '1';
                              end if;
                           elsif sdcard_write_ack = '1' and sdcard_write_done = '0' and write_start = '1' then
                              write_start <= '0';

                              if nxm = '0' and sdcard_error = '0' then
                                 csr_ba <= work_bar(17 downto 16);
                                 bar <= work_bar(15 downto 1);
                                 if unsigned(dar(5 downto 0)) < unsigned'("100111") then             -- don't increment beyond 047=39.
                                    dar(5 downto 0) <= dar(5 downto 0) + 1;
                                 else
                                    dar(5 downto 0) <= "101000";                -- acc. manual, should be set to 050/40. on track overrun
                                 end if;

                                 if unsigned(wcp) > unsigned'("0000010000000") then                  -- check if we need to do more
                                    wcp <= unsigned(wcp) - 128;
                                    if dar(5 downto 0) = "101000" then
                                       start <= '0';
                                       csr_e <= "101";                                -- overrun, hnf
                                       csr_crdy <= '1';
                                    end if;
                                 else
                                    csr_crdy <= '1';
                                    start <= '0';
                                 end if;

                              else

                                 csr_ba <= work_bar(17 downto 16);
                                 bar <= work_bar(15 downto 1);
                                 start <= '0';
                                 if nxm = '1' then
                                    csr_e <= "000";
                                    csr_nxm <= '1';
                                 end if;
                                 if sdcard_error = '1' then
                                    csr_e <= "011";
                                 end if;
                                 csr_crdy <= '1';
                              end if;

                           end if;
                        else
                           csr_e <= "101";
                           csr_crdy <= '1';
                           start <= '0';
                        end if;

                     when others =>                                        -- catchall
                        csr_crdy <= '1';
                        start <= '0';

                  end case;
               end if;

            end if;
         end if;
      end if;
   end process;

-- compose read address

   hs_offset <= "000000000000101000" when dnhs(conv_integer(csr_ds)) = '1' else "000000000000000000";                  -- track# * 40
   ca_offset <= ("00000" & dnca(conv_integer(csr_ds)) & "0000") + ("000" & dnca(conv_integer(csr_ds)) & "000000");     -- cyl#  * 2 * 40
   dn_offset <= (('0' & csr_ds & "0000000000000") + ('0' & csr_ds & "000000000000000"));                               -- disk * 512 * 2 * 40

   -- real RL02 sectors are 128 (16-bit) words -- RL02 Technical
   -- Description ("16 bit words per sector: 128"; "this track contains
   -- 40 sectors of 128 words each") -- half of a 512-byte SD block.
   -- sd_index is the linear real-sector number (dn/hs/ca_offset's
   -- strides are all even and 40 sectors/track is even, so a pair
   -- never straddles a drive/head/cylinder boundary); sd_addr packs
   -- two real sectors per SD block (index>>1), sd_half picks which
   -- half of that block this real sector's data lives in -- see
   -- sdcard_xfer_addr's read-side init below. rk11.vhd had (and
   -- reverted) the same pattern for RK05, which turned out to
   -- genuinely be 256 words/sector, not 128 -- see exp/badrk256b.
   sd_index <= unsigned(dn_offset + hs_offset + ca_offset + ("000000000000" & dar(5 downto 0)));
   sd_addr <= '0' & std_logic_vector(sd_index(17 downto 1));
   sd_half <= sd_index(0);

-- busmaster

   process(clk, reset)
   begin
      if clk = '1' and clk'event then
         if reset = '1' then
            busmaster_state <= busmaster_idle;
            npr <= '0';
            sdcard_read_ack <= '0';
            sdcard_write_start <= '0';
            nxm <= '0';
         else

            if have_rl = 1 then

               case busmaster_state is

                  when busmaster_idle =>
                     nxm <= '0';
                     if write_start = '1' then
                        npr <= '1';
                        if npg = '1' then
                           busmaster_state <= busmaster_write1;
                           work_bar <= csr_ba & bar(15 downto 1);
                           if unsigned(wcp) >= unsigned'("0000000010000000") then
                              sectorcounter <= "010000000";
                           elsif wcp = "0000000000000000" then
                              sectorcounter <= "000000000";
                           else
                              sectorcounter <= '0' & wcp(7 downto 0);
                           end if;

                           sdcard_xfer_addr <= 0;
                        end if;
                     elsif sdcard_read_done = '1' then
                        npr <= '1';
                        if npg = '1' then
                           work_bar <= csr_ba & bar(15 downto 1);
                           busmaster_state <= busmaster_read1;
                           if unsigned(wcp) >= unsigned'("0000000010000000") then
                              sectorcounter <= "010000000";
                           else
                              sectorcounter <= '0' & wcp(7 downto 0);
                           end if;

                           if sd_half = '0' then                      -- which real-sector half of the SD block
                              sdcard_xfer_addr <= 0;
                           else
                              sdcard_xfer_addr <= 128;
                           end if;
                           sdcard_xfer_read <= '1';
                        end if;
                     end if;

                  when busmaster_read1 =>
                     busmaster_state <= busmaster_read;
                     bus_master_addr <= work_bar(17 downto 1) & '0';
                     bus_master_dato <= sdcard_xfer_out;
                     bus_master_control_dato <= '0';
                     sdcard_xfer_addr <= sdcard_xfer_addr + 1;


                  when busmaster_read =>
                     if sectorcounter /= "000000000" then
                        work_bar <= work_bar + 1;
                        if sdcard_xfer_addr /= 255 then      -- this state machine always runs one
                           sdcard_xfer_addr <= sdcard_xfer_addr + 1;   -- increment past the last real
                        end if;                              -- word transferred -- harmless starting
                                                               -- from address 0 (max reached is 129),
                                                               -- but a real overflow risk starting
                                                               -- from 128 (an odd real sector)
                        sectorcounter <= sectorcounter - 1;

                        bus_master_control_dati <= '0';
                        bus_master_control_dato <= '1';
                        bus_master_addr <= work_bar(17 downto 1) & '0';
                        bus_master_dato <= sdcard_xfer_out;
                     else
                        busmaster_state <= busmaster_read_done;
                        bus_master_control_dati <= '0';
                        bus_master_control_dato <= '0';
                     end if;

                     if bus_master_nxm = '1' then
                        nxm <= '1';
                        busmaster_state <= busmaster_read_done;
                     end if;


                  when busmaster_read_done =>
                     npr <= '0';
                     sdcard_xfer_read <= '0';
                     sdcard_read_ack <= '1';
                     bus_master_control_dati <= '0';
                     bus_master_control_dato <= '0';
                     if sdcard_read_ack = '1' and sdcard_read_done = '0' then
                        busmaster_state <= busmaster_idle;
                        sdcard_read_ack <= '0';
                     end if;


                  when busmaster_write1 =>
                     sdcard_xfer_write <= '0';
                     -- packed addressing: an odd real sector (sd_half='1')
                     -- lives in words 128-255 of the SD block, not 0-127.
                     -- Start one below the real target so busmaster_write's
                     -- first increment lands there -- mirrors the read
                     -- path's sd_half branch above. Before this fix, every
                     -- write here unconditionally started at 255 (wrapping
                     -- to 0), so writing an odd real sector corrupted the
                     -- EVEN sector sharing its SD block instead of the
                     -- intended odd one, leaving the real target with
                     -- stale data -- this is what corrupted RSTS/E pack
                     -- labels (e.g. LBN 1, an odd real sector) on real
                     -- hardware even though the source disk image was
                     -- verified correct. Writes are capped at 128
                     -- words/burst (see the sectorcounter setup above), so
                     -- starting at 127 can reach at most 255, never
                     -- overflowing.
                     if sd_half = '0' then
                        sdcard_xfer_addr <= 255;
                     else
                        sdcard_xfer_addr <= 127;
                     end if;
                     if sectorcounter /= "000000000" then
                        bus_master_addr <= work_bar(17 downto 1) & '0';
                        bus_master_control_dati <= '1';
                        work_bar <= work_bar + 1;
                        busmaster_state <= busmaster_write;
                     else
                        busmaster_state <= busmaster_writen;
                     end if;


                  when busmaster_write =>
                     sectorcounter <= sectorcounter - 1;
                     if sectorcounter /= "000000000" then
                        sdcard_xfer_in <= bus_master_dati;
                        sdcard_xfer_write <= '1';
                        -- mod 256, not a plain increment -- the EVEN-half
                        -- case (sd_half='0') starts this state at 255
                        -- (busmaster_write1 above), so its very first
                        -- increment here overflows "integer range 0 to
                        -- 255" the same way rh11.vhd's/rk11.vhd's write
                        -- paths did (see tb_rh11_write.vhd) -- the ODD-half
                        -- case (starting at 127) never needed this, but
                        -- mod 256 is a no-op for it either way.
                        sdcard_xfer_addr <= (sdcard_xfer_addr + 1) mod 256;

                        if sectorcounter /= "000000001" then
                           work_bar <= work_bar + 1;
                           bus_master_addr <= work_bar(17 downto 1) & '0';
                           bus_master_control_dati <= '1';
                        end if;
                     else
                        if sdcard_xfer_addr = 255 then
                           busmaster_state <= busmaster_write_wait;
                        else
                           busmaster_state <= busmaster_writen;
                        end if;
                        npr <= '0';
                        bus_master_control_dati <= '0';
                     end if;


                  when busmaster_writen =>
                     npr <= '0';
                     if sdcard_xfer_addr = 255 then
                        busmaster_state <= busmaster_write_wait;
                     else
                        sdcard_xfer_in <= (others => '0');
                        sdcard_xfer_addr <= sdcard_xfer_addr + 1;
                        sdcard_xfer_write <= '1';
                     end if;


                  when busmaster_write_wait =>
                     sdcard_write_start <= '1';
                     sdcard_xfer_write <= '0';
                     if sdcard_write_done = '1' then
                        busmaster_state <= busmaster_write_done;
                        sdcard_write_start <= '0';
                     end if;


                  when busmaster_write_done =>
                     sdcard_write_ack <= '1';
                     if sdcard_write_ack = '1' and sdcard_write_done = '0' then
                        busmaster_state <= busmaster_idle;
                        sdcard_write_ack <= '0';
                     end if;

                  when others =>

               end case;

            end if;

         end if;
      end if;
   end process;

end implementation;


