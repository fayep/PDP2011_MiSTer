
--
-- Copyright (c) 2008-2025 Sytse van Slooten
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

entity rk11 is
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
      -- fake-SD-over-SPI emulation layer -- Phase 2 of the disk-transport
      -- plan, same pattern as rh11.vhd's Phase 1). sd_* live in the
      -- clk_100mhz domain (hps_io's own domain); RK11's own DMA/busmaster
      -- logic lives in cpuclk (clk/nclk below), bridged via a Gray-coded
      -- 2-bit request/done toggle pair per direction plus a dual-clock
      -- sector buffer -- see the "sd_* <-> busmaster bridge" section below.
      sd_lba : out std_logic_vector(31 downto 0);
      sd_rd : out std_logic;
      sd_wr : out std_logic;
      sd_ack : in std_logic;
      sd_buff_addr : in std_logic_vector(8 downto 0);
      sd_buff_dout : in std_logic_vector(15 downto 0);
      sd_buff_din : out std_logic_vector(15 downto 0);
      sd_buff_wr : in std_logic;
      clk_100mhz : in std_logic;

      have_rk : in integer range 0 to 1;
      have_rk_num : in integer range 1 to 8;
      img_mounted : in integer range 0 to 1 := 1;          -- is a disk image actually mounted; a real RK11
                                                            -- always has the controller present (that's have_rk,
                                                            -- a build-time choice) but reports "no pack" via DRY
                                                            -- (RKDS bit 07 per EK-RK11D-OP-001), not by vanishing
                                                            -- from the bus
      reset : in std_logic;
      clk50mhz : in std_logic;
      nclk : in std_logic;
      clk : in std_logic
   );
end rk11;

architecture implementation of rk11 is


-- regular bus interface

signal base_addr_match : std_logic;
signal interrupt_trigger : std_logic := '0';
signal int_owed : std_logic := '0';        -- latched interrupt-pending: set by a
                                            -- completion (RDY 0->1) or by IDE armed on an
                                            -- already-ready controller; gated by IDE,
                                            -- cleared only when the interrupt is granted.
signal rkcs_rdy_d : std_logic := '1';       -- RDY delayed one cycle, for edge detect
signal rkcs_ide_d : std_logic := '0';       -- IDE delayed one cycle, for edge detect
type interrupt_state_type is (
   i_idle,
   i_req,
   i_wait
);
signal interrupt_state : interrupt_state_type := i_idle;

-- rk11 registers - rkds - 777400

signal rkds_dri : std_logic_vector(2 downto 0);            -- drive ident - set to interrupting drive
signal rkds_dpl : std_logic;                               -- drive power loss
signal rkds_rk05 : std_logic;                              -- identify the drive as rk05
signal rkds_dru : std_logic;                               -- drive unsafe
signal rkds_sin : std_logic;                               -- seek incomplete
signal rkds_sok : std_logic;                               -- sector counter ok
signal have_media : std_logic;                             -- img_mounted, as a std_logic
signal rkds_dry : std_logic;                               -- drive ready
signal rkds_rwsrdy : std_logic;                            -- read/write/seek ready
signal rkds_wps : std_logic;                               -- write protected if 1
signal rkds_scsa : std_logic;                              -- disk address = sector counter
signal rkds_sc : std_logic_vector(3 downto 0);             -- sector counter
signal rkds : std_logic_vector(15 downto 0);

-- rk11 registers - rker - 777402

signal rker_wce : std_logic;                               -- write check error
signal rker_cse : std_logic;                               -- checksum error
signal rker_nxs : std_logic;                               -- nx sector
signal rker_nxc : std_logic;                               -- nx cylinder
signal rker_nxd : std_logic;                               -- nx disk
signal rker_te : std_logic;                                -- timing error
signal rker_dlt : std_logic;                               -- data late
signal rker_nxm : std_logic;                               -- nxm
signal rker_pge : std_logic;                               -- programming error
signal rker_ske : std_logic;                               -- seek error
signal rker_wlo : std_logic;                               -- write lockout
signal rker_ovr : std_logic;                               -- overrun
signal rker_dre : std_logic;                               -- drive error
signal rker : std_logic_vector(15 downto 0);

-- rk11 registers - rkcs - 777404

signal rkcs_err : std_logic;                               -- error
signal rkcs_he : std_logic;                                -- hard error
signal rkcs_scp : std_logic;                               -- search complete
signal rkcs_iba : std_logic;                               -- inhibit increment rkba
signal rkcs_fmt : std_logic;                               -- format
signal rkcs_exb : std_logic;                               -- extra bit, unused?
signal rkcs_sse : std_logic;                               -- stop on soft error
signal rkcs_rdy : std_logic;                               -- ready
signal rkcs_ide : std_logic;                               -- interrupt on done enable
signal rkcs_mex : std_logic_vector(1 downto 0);            -- bit 18, 17 of address
signal rkcs_fu : std_logic_vector(2 downto 0);             -- function code
signal rkcs_go : std_logic;                                -- go
signal rkcs : std_logic_vector(15 downto 0);

-- rk11 registers - rkwc - 777406

signal rkwc : std_logic_vector(15 downto 0);

-- rk11 registers - rkba - 777410

signal rkba : std_logic_vector(15 downto 0);

-- rk11 registers - rkda - 777412

signal rkda_dr : std_logic_vector(2 downto 0);
signal rkda_cy : std_logic_vector(7 downto 0);
signal rkda_hd : std_logic;
signal rkda_sc : std_logic_vector(3 downto 0);
signal rkda : std_logic_vector(15 downto 0);

-- rk11 registers - rkdb - 777416

signal rkdb : std_logic_vector(15 downto 0);


-- others

signal start : std_logic;
signal update_rkwc : std_logic;
signal wcp : std_logic_vector(15 downto 0);            -- word count, positive



signal hs_offset : std_logic_vector(16 downto 0);
signal ca_offset : std_logic_vector(16 downto 0);
signal dn_offset : std_logic_vector(16 downto 0);
signal sd_addr : std_logic_vector(23 downto 0);

signal work_bar : std_logic_vector(17 downto 1);

signal rkclock : integer range 0 to 4095;
subtype rksi_st is integer range 0 to 3;
type rksi_t is array(7 downto 0) of rksi_st;
signal rksi : rksi_t;
signal scpset : std_logic;

signal rkdelay : integer range 0 to 240000;
signal rkcs_godelay : integer range 0 to 10000;

signal write_start : std_logic;
signal wrkdb : std_logic_vector(15 downto 0);

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

-- dual-clock sector buffer: same proven idiom rh11.vhd's Phase 1 rewrite
-- used (plain VHDL array, one port per clock domain -- Quartus infers
-- M10K dual-clock dual-port block RAM from exactly this shape). rsector
-- is filled by hps_io (clk_100mhz, via sd_buff_wr) and drained by the
-- busmaster (clk); wsector is filled by the busmaster (clk) and drained
-- by hps_io (clk_100mhz, via sd_buff_addr/din). RK11's real sector is
-- already exactly 256 words = 512 bytes = one hps_io block -- confirmed
-- distinct from RL11's 128-word/256-byte case, no sub-block packing
-- needed here (see the disk-transport plan's own note on this).
type rk11_sector_buf_t is array(0 to 255) of std_logic_vector(15 downto 0);
signal rsector : rk11_sector_buf_t;
signal wsector : rk11_sector_buf_t;

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

type xfer_state_t is (
   xfer_idle,
   xfer_read_wait,
   xfer_read_done_hold,
   xfer_write_wait,
   xfer_write_done_hold
);
signal xfer_state : xfer_state_t := xfer_idle;

type sd_state_t is (
   sd_idle,
   sd_read_req,
   sd_read_xfer,
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

   have_media <= '1' when img_mounted = 1 else '0';

-- sd_* <-> busmaster bridge
--
-- Replaces the "sd1: sdspi port map(...)" black box. Fulfils the exact
-- same signal contract the busmaster/register-file logic below already
-- expects (sdcard_idle/read_start/read_ack/read_done/write_start/
-- write_ack/write_done/xfer_*), so none of that logic needed to change --
-- only what backs those signals did. See rh11.vhd's Phase 1 rewrite for
-- the full rationale; this is the same pattern verbatim.

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
                     sd_lba_r <= "00000000" & sd_addr;   -- stable well before this point
                     case read_req_gray is
                        when "00" => read_req_gray <= "01";
                        when "01" => read_req_gray <= "11";
                        when "11" => read_req_gray <= "10";
                        when others => read_req_gray <= "00";
                     end case;
                     xfer_state <= xfer_read_wait;
                  elsif sdcard_write_start = '1' then
                     sd_lba_r <= "00000000" & sd_addr;
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
                     sd_lba <= sd_lba_r;
                     sd_wr <= '1';
                     sd_state <= sd_write_req;
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
         sd_buff_din <= wsector(conv_integer(sd_buff_addr));
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

   base_addr_match <= '1' when base_addr(17 downto 4) = bus_addr(17 downto 4) and have_rk = 1 else '0';
   bus_addr_match <= base_addr_match;


-- specific logic for the device

   rkcs <= rkcs_err & rkcs_he & rkcs_scp & '0' & rkcs_iba & rkcs_fmt & rkcs_exb & rkcs_sse & rkcs_rdy & rkcs_ide & rkcs_mex & rkcs_fu & rkcs_go;
   rkds <= rkds_dri & rkds_dpl & rkds_rk05 & rkds_dru & rkds_sin & rkds_sok & rkds_dry & rkds_rwsrdy & rkds_wps & rkds_scsa & rkds_sc;
   rkda <= rkda_dr & rkda_cy & rkda_hd & rkda_sc;
   rker <= rker_dre & rker_ovr & rker_wlo & rker_ske & rker_pge & rker_nxm & rker_dlt & rker_te & rker_nxd & rker_nxc & rker_nxs & "000" & rker_cse & rker_wce;

   rkcs_err <= '1' when
      rker_wce = '1'
      or rker_cse = '1'
      or rker_nxs = '1'
      or rker_nxc = '1'
      or rker_nxd = '1'
      or rker_te = '1'
      or rker_dlt = '1'
      or rker_nxm = '1'
      or rker_pge = '1'
      or rker_ske = '1'
      or rker_wlo = '1'
      or rker_ovr = '1'
      or rker_dre = '1'
      else '0';

   rkcs_he <= '1' when
      rker_nxs = '1'
      or rker_nxc = '1'
      or rker_nxd = '1'
      or rker_te = '1'
      or rker_dlt = '1'
      or rker_nxm = '1'
      or rker_pge = '1'
      or rker_ske = '1'
      or rker_wlo = '1'
      or rker_ovr = '1'
      or rker_dre = '1'
      else '0';

   rkds_rwsrdy <= '1' when conv_integer(rkda_dr) < have_rk_num and rksi(conv_integer(rkda_dr)) = 0 and sdcard_idle = '1'
      else '0';
   rkds_dry <= '1' when conv_integer(rkda_dr) < have_rk_num and have_media = '1' else '0';

-- regular bus interface : handle register contents and dependent logic

   process(nclk, reset)
   begin
      if nclk = '1' and nclk'event then
         if reset = '1' then

            br <= '0';
            interrupt_trigger <= '0';
            int_owed <= '0';
            rkcs_rdy_d <= '1';
            rkcs_ide_d <= '0';
            interrupt_state <= i_idle;
            scpset <= '0';

            rksi(7) <= 0;
            rksi(6) <= 0;
            rksi(5) <= 0;
            rksi(4) <= 0;
            rksi(3) <= 0;
            rksi(2) <= 0;
            rksi(1) <= 0;
            rksi(0) <= 0;

            rkds_dri <= "000";                             -- drive ident
            rkds_dpl <= '0';                               -- not drive power loss
            rkds_rk05 <= '1';                              -- identify the drive as rk05
            rkds_dru <= '0';                               -- not drive unsafe
            rkds_sin <= '0';                               -- not seek incomplete
            rkds_sok <= '1';                               -- sector counter ok
--            rkds_dry <= '1';                               -- drive ready
            rkds_wps <= '0';                               -- not write protected
            rkds_scsa <= '1';                              -- disk address = sector counter
            rkds_sc <= "0000";                             -- sector counter

            rker_wce <= '0';
            rker_cse <= '0';
            rker_nxs <= '0';
            rker_nxc <= '0';
            rker_nxd <= '0';
            rker_te <= '0';
            rker_dlt <= '0';
            rker_nxm <= '0';
            rker_pge <= '0';
            rker_ske <= '0';
            rker_wlo <= '0';
            rker_ovr <= '0';
            rker_dre <= '0';

            rkba <= (others => '0');

            rkcs_scp <= '0';
            rkcs_iba <= '0';
            rkcs_fmt <= '0';
            rkcs_exb <= '0';
            rkcs_sse <= '0';
            rkcs_rdy <= '1';
            rkcs_ide <= '0';
            rkcs_mex <= "00";
            rkcs_fu <= "000";
            rkcs_go <= '0';

            rkda_dr <= (others => '0');
            rkda_cy <= (others => '0');
            rkda_hd <= '0';
            rkda_sc <= (others => '0');

            rkdb <= (others => '0');

            start <= '0';
            -- sdcard_read_start has no explicit reset value on real
            -- silicon (an FPGA flip-flop powers up at '0' regardless),
            -- but GHDL simulates the true VHDL 'U' default -- without
            -- this, "sdcard_idle='1' and sdcard_read_start='0'" (the
            -- read-start gate) never evaluates true, deadlocking every
            -- read forever. Found via tb_rk11_dma.vhd (Phase 2); rh11.vhd
            -- already did this correctly for its own sdcard_read_start.
            sdcard_read_start <= '0';

            rkwc <= (others => '0');
            update_rkwc <= '1';

            rkclock <= 0;

            rkdelay <= 0;
            rkcs_godelay <= 30;

         else

            if have_rk = 1 then
               case interrupt_state is

                  when i_idle =>

                     br <= '0';
                     if rkcs_ide = '1' and scpset = '1' then
                        interrupt_state <= i_req;
                        br <= '1';
                        scpset <= '0';
                     end if;

                     if rkcs_ide = '1' and int_owed = '1' then
                        if interrupt_trigger = '0' then
                           interrupt_state <= i_req;
                           br <= '1';
                           interrupt_trigger <= '1';
                        end if;
                     else
                        interrupt_trigger <= '0';
                     end if;

                  when i_req =>
                     if rkcs_ide = '1' then
                        if bg = '1' then
                           int_vector <= ivec;
                           br <= '0';
                           interrupt_state <= i_wait;
                        end if;
                     else
                        interrupt_trigger <= '0';
                        interrupt_state <= i_idle;
                     end if;

                  when i_wait =>
                     if bg = '0' then
                        interrupt_state <= i_idle;
                        int_owed <= '0';                                      -- interrupt granted: clear the pending latch
                        interrupt_trigger <= '0';                             -- and the in-flight guard, unconditionally --
                                                                                -- see notes/rsts-v10-rh70-hang.md 2026-09-16 /
                                                                                -- rh11.vhd's matching comment: leaving this to
                                                                                -- i_idle's else-branch left a 1-cycle race
                                                                                -- where a coincident RDY/IDE-rearm event
                                                                                -- re-latches int_owed on this exact edge while
                                                                                -- interrupt_trigger is still stuck '1',
                                                                                -- permanently eating every later interrupt.
                     end if;

                  when others =>
                     interrupt_state <= i_idle;

               end case;

               -- Latch an interrupt request into int_owed: on RDY 0->1 (function
               -- complete) regardless of IDE, or on IDE armed while RDY is already set
               -- (the "enable interrupts on a ready controller" probe).  After the case
               -- so a completion coincident with a grant is not lost.
               rkcs_rdy_d <= rkcs_rdy;
               rkcs_ide_d <= rkcs_ide;
               if (rkcs_rdy = '1' and rkcs_rdy_d = '0')
                  or (rkcs_ide = '1' and rkcs_ide_d = '0' and rkcs_rdy = '1') then
                  int_owed <= '1';
               end if;
            else
               br <= '0';
            end if;

            if have_rk = 1 then
               if rkclock = 4095 then
                  rkclock <= 0;
               else
                  rkclock <= rkclock + 1;
               end if;
               if rkclock = 0 then
                  if rkds_sc(3 downto 0) = "1011" then
                     rkds_sc <= "0000";
                  else
                     rkds_sc <= rkds_sc + "0001";
                  end if;

                  if have_rk_num = 8 and rksi(7) > 1 then
                     rksi(7) <= rksi(7) - 1;
                  end if;
                  if have_rk_num >= 7 and rksi(6) > 1 then
                     rksi(6) <= rksi(6) - 1;
                  end if;
                  if have_rk_num >= 6 and rksi(5) > 1 then
                     rksi(5) <= rksi(5) - 1;
                  end if;
                  if have_rk_num >= 5 and rksi(4) > 1 then
                     rksi(4) <= rksi(4) - 1;
                  end if;
                  if have_rk_num >= 4 and rksi(3) > 1 then
                     rksi(3) <= rksi(3) - 1;
                  end if;
                  if have_rk_num >= 3 and rksi(2) > 1 then
                     rksi(2) <= rksi(2) - 1;
                  end if;
                  if have_rk_num >= 2 and rksi(1) > 1 then
                     rksi(1) <= rksi(1) - 1;
                  end if;
                  if rksi(0) > 1 then
                     rksi(0) <= rksi(0) - 1;
                  end if;
               end if;

               if rkds_sc = rkda_sc then
                  rkds_scsa <= '1';
               else
                  rkds_scsa <= '0';
               end if;

               if base_addr_match = '1' and bus_control_dati = '1' then

                  case bus_addr(3 downto 1) is
                     when "000" =>
                        bus_dati <= rkds;

                     when "001" =>
                        bus_dati <= rker;

                     when "010" =>
                        bus_dati <= rkcs;

                     when "011" =>
                        bus_dati <= (not wcp) + 1;

                     when "100" =>
                        bus_dati <= rkba;

                     when "101" =>
                        bus_dati <= rkda;

                     when "111" =>
                        bus_dati <= rkdb;

                     when others =>
                        bus_dati <= (others => '0');

                  end case;
               end if;

               if base_addr_match = '1' and bus_control_dato = '1' then

                  if bus_control_datob = '0' or (bus_control_datob = '1' and bus_addr(0) = '0') then

                     case bus_addr(3 downto 1) is
                        when "000" =>
                        when "001" =>
                        when "010" =>
                           rkcs_go <= bus_dato(0);
                           if bus_dato(0) = '1' then
                              rkcs_rdy <= '0';
                           end if;
                           rkcs_fu <= bus_dato(3 downto 1);
                           rkcs_mex <= bus_dato(5 downto 4);
                           rkcs_ide <= bus_dato(6);
                           if bus_dato(6) = '1' and bus_dato(0) = '0' and rkcs_rdy = '1' then
                              interrupt_trigger <= '1';                    -- setting ide, not setting go, but rdy = 1 -> interrupt
                           end if;

                        when "011" =>
                           rkwc(7 downto 0) <= bus_dato(7 downto 0);
                           update_rkwc <= '1';

                        when "100" =>
                           rkba(7 downto 0) <= bus_dato(7 downto 0);

                        when "101" =>
                           rkda_cy(2 downto 0) <= bus_dato(7 downto 5);
                           rkda_hd <= bus_dato(4);
                           rkda_sc <= bus_dato(3 downto 0);

                        when others =>
                           null;

                     end case;
                  end if;

                  if bus_control_datob = '0' or (bus_control_datob = '1' and bus_addr(0) = '1') then

                     case bus_addr(3 downto 1) is
                        when "000" =>
                        when "001" =>
                        when "010" =>
                           rkcs_sse <= bus_dato(8);
                           rkcs_exb <= bus_dato(9);
                           rkcs_fmt <= bus_dato(10);
                           rkcs_iba <= bus_dato(11);

                        when "011" =>
                           rkwc(15 downto 8) <= bus_dato(15 downto 8);
                           update_rkwc <= '1';

                        when "100" =>
                           rkba(15 downto 8) <= bus_dato(15 downto 8);

                        when "101" =>
                           rkda_dr <= bus_dato(15 downto 13);
                           rkda_cy(7 downto 3) <= bus_dato(12 downto 8);

                        when others =>
                           null;

                     end case;
                  end if;

               end if;

               if update_rkwc = '1' then
                  wcp <= (not rkwc) + 1;
                  update_rkwc <= '0';
               end if;

               if rkcs_go = '1' and start = '0' then
--                  rkcs_rdy <= '0';
                  rksi(conv_integer(rkda_dr)) <= 3;
                  if rkcs_godelay = 0 then
                     rkcs_go <= '0';
                     rkcs_godelay <= 180;
                  else
                     rkcs_godelay <= rkcs_godelay - 1;
                  end if;
               end if;

               if rkcs_rdy = '0' and start = '0' and rkcs_go = '0' then
                  if conv_integer(rkda_dr) < have_rk_num
                  and (have_media = '1' or rkcs_fu = "000") then          -- control reset always allowed, like
                                                                           -- RH11's RIP/pack-ack exemption
                     start <= '1';
                     rkdelay <= 120;
                     rkcs_scp <= '0';
                     rkds_dri <= "000";                                    -- drive ident of interrupting drive
                  else
                     rker_nxd <= '1';
                     rkcs_rdy <= '1';
                  end if;
               end if;

               if start = '1' then
                  case rkcs_fu is

                     when "000" =>                                      -- control reset
                        rkcs_rdy <= '1';
                        rkcs_ide <= '0';                                -- control reset clears ide

                        rkcs_iba <= '0';
                        rkcs_exb <= '0';
                        rkcs_fmt <= '0';
                        rkcs_sse <= '0';
                        rkcs_mex <= "00";

                        rkwc <= (others => '0');
                        update_rkwc <= '1';

                        rkba <= (others => '0');

                        rkda_dr <= (others => '0');
                        rkda_cy <= (others => '0');
                        rkda_hd <= '0';
                        rkda_sc <= (others => '0');

                        rkdb <= (others => '0');

                        start <= '0';

                        rker_wce <= '0';
                        rker_cse <= '0';
                        rker_nxs <= '0';
                        rker_nxc <= '0';
                        rker_nxd <= '0';
                        rker_te <= '0';
                        rker_dlt <= '0';
                        rker_nxm <= '0';
                        rker_pge <= '0';
                        rker_ske <= '0';
                        rker_wlo <= '0';
                        rker_ovr <= '0';
                        rker_dre <= '0';


                     when "001" =>                                  -- write
                        if rkdelay /= 0 then
                           rkdelay <= rkdelay - 1;
                        else
                           rksi(conv_integer(rkda_dr)) <= 0;
                           if sdcard_idle = '1' and write_start = '0' then
                              if unsigned(rkda_cy) > unsigned'("11001010") then      -- o"000" thru "o"312"
                                 rker_nxc <= '1';
                                 rkcs_rdy <= '1';
                                 rkdb <= wrkdb;
                                 start <= '0';
                              elsif rkda_sc(3 downto 2) = "11" then
                                 rker_nxs <= '1';
                                 rkcs_rdy <= '1';
                                 rkdb <= wrkdb;
                                 start <= '0';
                              else
                                 write_start <= '1';
                              end if;
                           elsif sdcard_write_ack = '1' and sdcard_write_done = '0' and write_start = '1' then
                              write_start <= '0';

                              if nxm = '0' and sdcard_error = '0' then
                                 rkcs_mex <= work_bar(17 downto 16);
                                 rkba <= work_bar(15 downto 1) & '0';
                                 if unsigned(rkda_sc(3 downto 0)) < unsigned'("1011") then             -- don't increment beyond 047=39.
                                    rkda_sc(3 downto 0) <= rkda_sc(3 downto 0) + 1;
                                 else
                                    rkda_sc(3 downto 0) <= "0000";
                                    if rkda_hd = '0' then
                                       rkda_hd <= '1';
                                    else
                                       if unsigned(rkda_cy) = unsigned'("11001010") and rkcs_fmt /= '1' and unsigned(wcp) > unsigned'("0000000100000000") then      -- o"000" thru "o"312"
                                          rker_ovr <= '1';
                                          rkcs_rdy <= '1';
                                          rkdb <= wrkdb;
                                          start <= '0';
                                       else
                                          rkda_cy <= rkda_cy + 1;
                                          rkda_hd <= '0';
                                       end if;
                                    end if;
                                 end if;

                                 if unsigned(wcp) > unsigned'("0000000100000000") then               -- check if we need to do another sector, and setup for the next round if so
                                    wcp <= unsigned(wcp) - unsigned'("0000000100000000");
                                 else
                                    wcp <= (others => '0');
                                    start <= '0';
                                    rkcs_rdy <= '1';
                                    rkdb <= wrkdb;
                                 end if;

                              else

                                 rkcs_mex <= work_bar(17 downto 16);
                                 rkba <= work_bar(15 downto 1) & '0';
                                 rkdb <= wrkdb;
                                 rkcs_rdy <= '1';
                                 if nxm = '1' then
                                    rker_nxm <= '1';
                                 end if;
                                 if sdcard_error = '1' then
                                    rker_dre <= '1';
                                 end if;
                              end if;

                           end if;
                        end if;


                     when "010" | "011" =>                                  -- read, write check
                        if rkdelay /= 0 then
                           rkdelay <= rkdelay - 1;
                        else
                           rksi(conv_integer(rkda_dr)) <= 0;
                           if sdcard_idle = '1' and sdcard_read_start = '0' and sdcard_read_done = '0' then
                              if unsigned(rkda_cy) > unsigned'("11001010") then      -- o"000" thru "o"312"
                                 rker_nxc <= '1';
                                 rkcs_rdy <= '1';
                                 rkdb <= wrkdb;
                                 start <= '0';
                              elsif rkda_sc(3 downto 2) = "11" then
                                 rker_nxs <= '1';
                                 rkcs_rdy <= '1';
                                 rkdb <= wrkdb;
                                 start <= '0';
                              elsif rkcs_fu /= "010" and (rkcs_fmt = '1' or rkcs_exb = '1') then
                                 rker_pge <= '1';
                                 rkcs_rdy <= '1';
                                 rkdb <= wrkdb;
                                 start <= '0';
                              else
                                 sdcard_read_start <= '1';
                              end if;
                           elsif sdcard_read_ack = '1' and sdcard_read_done = '0' and sdcard_read_start = '1' then
                              sdcard_read_start <= '0';

                              if nxm = '0' and sdcard_error = '0' then
                                 rkcs_mex <= work_bar(17 downto 16);
                                 rkba <= work_bar(15 downto 1) & '0';
                                 if unsigned(rkda_sc(3 downto 0)) < unsigned'("1011") then             -- don't increment beyond 11.
                                    rkda_sc(3 downto 0) <= rkda_sc(3 downto 0) + 1;
                                 else
                                    rkda_sc(3 downto 0) <= "0000";
                                    if rkda_hd = '0' then
                                       rkda_hd <= '1';
                                    else
                                       if unsigned(rkda_cy) = unsigned'("11001010") and rkcs_fmt /= '1' and unsigned(wcp) > unsigned'("0000000100000000") then      -- o"000" thru "o"312"
                                          rker_ovr <= '1';
                                          rkcs_rdy <= '1';
                                          rkdb <= wrkdb;
                                          start <= '0';
                                       else
                                          rkda_cy <= rkda_cy + 1;
                                          rkda_hd <= '0';
                                       end if;
                                    end if;
                                 end if;

                                 if rkcs_fmt = '1' then
                                    if unsigned(wcp) > unsigned'("0000000000000001") then               -- check if we need to do another header, and setup for the next round if so
                                       wcp <= unsigned(wcp) - unsigned'("0000000000000001");
                                    else
                                       wcp <= (others => '0');
                                       start <= '0';
                                       rkcs_rdy <= '1';
                                       rkdb <= wrkdb;
                                    end if;
                                 else
                                    if unsigned(wcp) > unsigned'("0000000100000000") then               -- check if we need to do another sector, and setup for the next round if so
                                       wcp <= unsigned(wcp) - unsigned'("0000000100000000");
                                    else
                                       wcp <= (others => '0');
                                       start <= '0';
                                       rkcs_rdy <= '1';
                                       rkdb <= wrkdb;
                                    end if;
                                 end if;

                              else

                                 rkcs_mex <= work_bar(17 downto 16);
                                 rkba <= work_bar(15 downto 1) & '0';
                                 rkdb <= wrkdb;
                                 rkcs_rdy <= '1';
                                 if nxm = '1' then
                                    rker_nxm <= '1';
                                 end if;
                                 if sdcard_error = '1' then
                                    rker_dre <= '1';
                                 end if;
                              end if;

                           end if;
                        end if;

                     when "100" =>                                  -- seek
                        if rkdelay = 0 then
                           if rkcs_fmt = '1' or rkcs_exb = '1' then
                              rker_pge <= '1';
                              rkcs_rdy <= '1';
                              start <= '0';
                           elsif unsigned(rkda_cy) > unsigned'("11001010") then      -- o"000" thru "o"312"
                              rker_nxc <= '1';
                              rkcs_rdy <= '1';
                              start <= '0';
                           else
                              rksi(conv_integer(rkda_dr)) <= 3;
                              rkcs_rdy <= '1';
                              start <= '0';
                           end if;
                        else
                           rkdelay <= rkdelay - 1;
                        end if;

                     when "101" =>                                  -- read check
                        if rkdelay = 0 then
                           if unsigned(rkda_sc(3 downto 0)) < unsigned'("1011") then             -- don't increment beyond 11.
                              rkda_sc(3 downto 0) <= rkda_sc(3 downto 0) + 1;
                           else
                              rkda_sc(3 downto 0) <= "0000";
                              if rkda_hd = '0' then
                                 rkda_hd <= '1';
                              else
                                 if unsigned(rkda_cy) = unsigned'("11001010") and rkcs_fmt /= '1' and unsigned(wcp) > unsigned'("0000000100000000") then      -- o"000" thru "o"312"
                                    rker_ovr <= '1';
                                    rkcs_rdy <= '1';
                                    start <= '0';
                                 else
                                    rkda_cy <= rkda_cy + 1;
                                    rkda_hd <= '0';
                                 end if;
                              end if;
                           end if;

                           if unsigned(wcp) > unsigned'("0000000100000000") then               -- check if we need to do another sector, and setup for the next round if so
                              wcp <= unsigned(wcp) - unsigned'("0000000100000000");
                           else
                              wcp <= (others => '0');
                              start <= '0';
                              rkcs_rdy <= '1';
                           end if;
                        else
                           rkdelay <= rkdelay - 1;
                        end if;

                     when "110" =>                                  -- drive reset
                        if rkdelay = 0 then
                           if rkcs_fmt = '1' or rkcs_exb = '1' then
                              rker_pge <= '1';
                              rkcs_rdy <= '1';
                              start <= '0';
                           else
                              rksi(conv_integer(rkda_dr)) <= 3;
                              rkcs_rdy <= '1';
                              start <= '0';
                           end if;
                        else
                           rkdelay <= rkdelay - 1;
                        end if;

                     when others =>                                 -- catchall
                        rkcs_rdy <= '1';
                        start <= '0';

                  end case;

               else

                  if rkcs_rdy = '1' then
                     if have_rk_num = 8 and rksi(7) = 1 then
                        rksi(7) <= 0;
                        if rkcs_ide = '1' then
                           rkds_dri <= "111";
                           rkcs_scp <= '1';
                           scpset <= '1';
                        end if;
                     elsif have_rk_num >= 7 and rksi(6) = 1 then
                        rksi(6) <= 0;
                        if rkcs_ide = '1' then
                           rkds_dri <= "110";
                           rkcs_scp <= '1';
                           scpset <= '1';
                        end if;
                     elsif have_rk_num >= 6 and rksi(5) = 1 then
                        rksi(5) <= 0;
                        if rkcs_ide = '1' then
                           rkds_dri <= "101";
                           rkcs_scp <= '1';
                           scpset <= '1';
                        end if;
                     elsif have_rk_num >= 5 and rksi(4) = 1 then
                        rksi(4) <= 0;
                        if rkcs_ide = '1' then
                           rkds_dri <= "100";
                           rkcs_scp <= '1';
                           scpset <= '1';
                        end if;
                     elsif have_rk_num >= 4 and rksi(3) = 1 then
                        rksi(3) <= 0;
                        if rkcs_ide = '1' then
                           rkds_dri <= "011";
                           rkcs_scp <= '1';
                           scpset <= '1';
                        end if;
                     elsif have_rk_num >= 3 and rksi(2) = 1 then
                        rksi(2) <= 0;
                        if rkcs_ide = '1' then
                           rkds_dri <= "010";
                           rkcs_scp <= '1';
                           scpset <= '1';
                        end if;
                     elsif have_rk_num >= 2 and rksi(1) = 1 then
                        rksi(1) <= 0;
                        if rkcs_ide = '1' then
                           rkds_dri <= "001";
                           rkcs_scp <= '1';
                           scpset <= '1';
                        end if;
                     elsif rksi(0) = 1 then
                        rksi(0) <= 0;
                        if rkcs_ide = '1' then
                           rkds_dri <= "000";
                           rkcs_scp <= '1';
                           scpset <= '1';
                        end if;
                     end if;
                  end if;
               end if;

            end if;

         end if;
      end if;
   end process;

-- compose read address

   hs_offset <= "00000000000001100" when rkda_hd = '1' else "00000000000000000";             -- head/surface * 12
   ca_offset <= ("00000" & unsigned(rkda_cy) & "0000") + ("000000" & unsigned(rkda_cy) & "000");            -- cyl * 16 + cyl * 8 == cyl * 24
   dn_offset <= ("00" & unsigned(rkda_dr) & "000000000000") + ("000" & unsigned(rkda_dr) & "00000000000");     -- (disk * 16 + disk * 8) << 8

   sd_addr <= "0000000" & unsigned(dn_offset) + unsigned(hs_offset) + unsigned(ca_offset) + unsigned(rkda_sc);

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

            if have_rk = 1 then

               case busmaster_state is

                  when busmaster_idle =>
                     nxm <= '0';
                     if write_start = '1' then
                        npr <= '1';
                        if npg = '1' then
                           busmaster_state <= busmaster_write1;
                           work_bar <= rkcs_mex & rkba(15 downto 1);
                           if rkcs_fmt = '1' then                        -- write format
                              -- rk does not need special write fmt processing
                           end if;
                           if unsigned(wcp) >= unsigned'("0000000100000000") then
                              sectorcounter <= "100000000";
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
                           work_bar <= rkcs_mex & rkba(15 downto 1);
                           if rkcs_fmt = '1' then                        -- read header/data, write check header/data
                              busmaster_state <= busmaster_readh;
                           else
                              busmaster_state <= busmaster_read1;
                           end if;
                           if unsigned(wcp) >= unsigned'("0000000100000000") then
                              sectorcounter <= "100000000";
                           else
                              sectorcounter <= '0' & wcp(7 downto 0);
                           end if;

                           sdcard_xfer_addr <= 0;
                           sdcard_xfer_read <= '1';
                        end if;
                     end if;


                  when busmaster_readh =>
                     bus_master_addr <= work_bar(17 downto 1) & '0';
                     bus_master_dato <= "000" & rkda_cy & "00000";
                     bus_master_control_dato <= '1';
                     if rkcs_iba = '0' then
                        work_bar <= work_bar + 1;
                     end if;
                     busmaster_state <= busmaster_read_done;


                  when busmaster_readh2 =>
                     bus_master_addr <= work_bar(17 downto 1) & '0';
                     bus_master_dato <= x"1111";               -- FIXME, what is the header format?
                     bus_master_control_dato <= '1';
                     if rkcs_iba = '0' then
                        work_bar <= work_bar + 1;
                     end if;
                     busmaster_state <= busmaster_read_done;


                  when busmaster_read1 =>
                     busmaster_state <= busmaster_read;
                     bus_master_addr <= work_bar(17 downto 1) & '0';
                     bus_master_dato <= sdcard_xfer_out;
                     bus_master_control_dato <= '0';
                     -- mod 256, not a plain increment -- sdcard_xfer_addr
                     -- is "integer range 0 to 255"; a full 256-word sector
                     -- pushes the final increment to 256, which wraps for
                     -- free in real hardware's binary arithmetic but is a
                     -- real GHDL bounds-check failure (found via
                     -- tb_rk11_dma.vhd, Phase 2). rh11.vhd's own read path
                     -- already does this -- see rh11.vhd:1637.
                     sdcard_xfer_addr <= (sdcard_xfer_addr + 1) mod 256;


                  when busmaster_read =>
                     if sectorcounter /= "000000000" then
                        if rkcs_iba = '0' then
                           work_bar <= work_bar + 1;
                        end if;
                        sdcard_xfer_addr <= (sdcard_xfer_addr + 1) mod 256;
                        sectorcounter <= sectorcounter - 1;

                        bus_master_control_dati <= '0';
                        bus_master_control_dato <= '1';
                        bus_master_addr <= work_bar(17 downto 1) & '0';
                        bus_master_dato <= sdcard_xfer_out;
                        wrkdb <= sdcard_xfer_out;
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
                     sdcard_xfer_addr <= 255;
                     if sectorcounter /= "000000000" then
                        bus_master_addr <= work_bar(17 downto 1) & '0';
                        bus_master_control_dati <= '1';
                        if rkcs_iba = '0' then
                           work_bar <= work_bar + 1;
                        end if;
                        busmaster_state <= busmaster_write;
                     else
                        busmaster_state <= busmaster_writen;
                     end if;


                  when busmaster_write =>
                     sectorcounter <= sectorcounter - 1;
                     if sectorcounter /= "000000000" then
                        wrkdb <= (others => '0');
                        sdcard_xfer_in <= bus_master_dati;
                        sdcard_xfer_write <= '1';
                        -- mod 256, not a plain increment -- same overflow
                        -- class as the read path's fix above (this state
                        -- starts at 255 via busmaster_write1; a full-block
                        -- write's first increment here would overflow the
                        -- "integer range 0 to 255" type). See rh11.vhd's
                        -- matching fix (tb_rh11_write.vhd).
                        sdcard_xfer_addr <= (sdcard_xfer_addr + 1) mod 256;

                        if sectorcounter /= "000000001" then
                           if rkcs_iba = '0' then
                              work_bar <= work_bar + 1;
                           end if;
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

