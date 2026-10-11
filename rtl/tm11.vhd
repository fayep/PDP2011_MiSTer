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

--
-- tm11.vhd - TM11/TU10 magtape controller, read-only, single unit.
--
-- CSR 172520, vector 224, BR5.  Media is a SIMH .tap container presented as a
-- virtual sd_card on hps_io slot 3 (see pdp2011.sv / mister_top.vhd).  The .tap
-- byte stream is walked here over 512-byte sdspi blocks:
--
--    <32-bit LE record length L> <L data bytes, padded to even> <32-bit LE L again>
--    L == 0            -> tape mark  (sets MTS EOF)
--    L(31) == 1        -> end of medium / erase gap / error marker -> MTS BTE (bad
--                         tape), as SIMH: the tape does not move, so a driver
--                         spacing on toward EOT would otherwise never stop
--
-- Register / bit layout follows SIMH pdp11_tm.c (FNC_*, MTC_*, STA_*).
--
-- Limitations of this first cut:
--   * read-only: WRITE / WREOF / WREXT set MTS ILL and do not move tape
--   * odd-length records DMA ceil(L/2) words (one pad byte written to memory);
--     MTBRC / MTCMA residuals still reflect the true byte count L
--   * mounting a .tap re-homes to BOT (media_change edge); no core reset needed
--

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity tm11 is
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

      sd_lba : out std_logic_vector(31 downto 0);                -- hps_io disk slot (clk_sys), see mister_blkdev.vhd
      sd_rd : out std_logic;
      sd_wr : out std_logic;
      sd_ack : in std_logic;
      sd_buff_addr : in std_logic_vector(7 downto 0);
      sd_buff_dout : in std_logic_vector(15 downto 0);
      sd_buff_din : out std_logic_vector(15 downto 0);
      sd_buff_wr : in std_logic;
      clk_sys : in std_logic;

      have_tm : in integer range 0 to 1;
      ts_mode : in std_logic := '0';                            -- '1': the same drive as a TS11 (OSD), see the TS11 section
      media_change : in std_logic := '0';                       -- toggles when a .tap is (un)mounted -> re-home to BOT
      img_mounted : in integer range 0 to 1 := 1;               -- is a tape image actually mounted; a real TM11
                                                                 -- always has the controller present (that's
                                                                 -- have_tm, a build-time choice) but reports "no
                                                                 -- tape" via MTS SELR/TUR (bits 06/00 per the TM11
                                                                 -- manual, DEC-11-HTMAA-D-D pp.4-2,4-5-4-6), not by
                                                                 -- vanishing from the bus
      reset : in std_logic;
      clk50mhz : in std_logic;
      nclk : in std_logic;
      clk : in std_logic
   );
end tm11;

architecture implementation of tm11 is

component mister_blkdev is
   port(
      sdcard_addr : in std_logic_vector(23 downto 0);

      sdcard_idle : out std_logic;
      sdcard_read_start : in std_logic;
      sdcard_read_ack : in std_logic;
      sdcard_read_done : out std_logic;
      sdcard_write_start : in std_logic;
      sdcard_write_ack : in std_logic;
      sdcard_write_done : out std_logic;
      sdcard_error : out std_logic;

      sdcard_xfer_addr : in integer range 0 to 255;
      sdcard_xfer_read : in std_logic;
      sdcard_xfer_out : out std_logic_vector(15 downto 0);
      sdcard_xfer_write : in std_logic;
      sdcard_xfer_in : in std_logic_vector(15 downto 0);

      enable : in integer range 0 to 1 := 0;
      controller_clk : in std_logic;
      reset : in std_logic;

      sd_lba : out std_logic_vector(31 downto 0);
      sd_rd : out std_logic;
      sd_wr : out std_logic;
      sd_ack : in std_logic;
      sd_buff_addr : in std_logic_vector(7 downto 0);
      sd_buff_dout : in std_logic_vector(15 downto 0);
      sd_buff_din : out std_logic_vector(15 downto 0);
      sd_buff_wr : in std_logic;
      clk_sys : in std_logic
   );
end component;

-- regular bus interface

signal base_addr_match : std_logic;
signal interrupt_trigger : std_logic := '0';
type interrupt_state_type is (
   i_idle,
   i_req,
   i_wait
);
signal interrupt_state : interrupt_state_type := i_idle;

-- function codes (MTC bits 3:1), per SIMH pdp11_tm.c
constant fnc_unload : std_logic_vector(2 downto 0) := "000";
constant fnc_read   : std_logic_vector(2 downto 0) := "001";
constant fnc_write  : std_logic_vector(2 downto 0) := "010";
constant fnc_wreof  : std_logic_vector(2 downto 0) := "011";
constant fnc_spacef : std_logic_vector(2 downto 0) := "100";
constant fnc_spacer : std_logic_vector(2 downto 0) := "101";
constant fnc_wrext  : std_logic_vector(2 downto 0) := "110";
constant fnc_rewind : std_logic_vector(2 downto 0) := "111";

-- MTC - command register - 172522
signal mtc_den : std_logic_vector(1 downto 0);            -- bits 14:13 density (readback only)
signal mtc_lpar : std_logic;                              -- bit 11 parity select (readback only)
signal mtc_unit : std_logic_vector(2 downto 0);           -- bits 10:8 unit select (readback only)
signal mtc_rdy : std_logic;                               -- bit 7 controller ready (DONE)
signal mtc_ie : std_logic;                                -- bit 6 interrupt enable
signal mtc_ema : std_logic_vector(1 downto 0);            -- bits 5:4 extended memory address (bus addr 17:16)
signal mtc_fnc : std_logic_vector(2 downto 0);            -- bits 3:1 function
signal mtc_go : std_logic;                                -- bit 0 go
signal mtc_err : std_logic;                               -- bit 15 = summary of MTS error bits
signal mtc : std_logic_vector(15 downto 0);

-- MTS - status register - 172520
signal mts_ill : std_logic;                               -- bit 15 illegal command
signal mts_eof : std_logic;                               -- bit 14 end of file (tape mark)
signal mts_crc : std_logic;                               -- bit 13 crc error
signal mts_par : std_logic;                               -- bit 12 parity error
signal mts_dlt : std_logic;                               -- bit 11 data late
signal mts_eot : std_logic;                               -- bit 10 end of tape
signal mts_rle : std_logic;                               -- bit 9 record length error
signal mts_bad : std_logic;                               -- bit 8 bad tape error
signal mts_nxm : std_logic;                               -- bit 7 non-existent memory
signal have_media : std_logic;                            -- img_mounted, as a std_logic
signal mts_onl : std_logic;                               -- bit 6 online
signal mts_bot : std_logic;                               -- bit 5 beginning of tape
signal mts_7tk : std_logic;                               -- bit 4 7-track (0 = 9-track)
signal mts_sdn : std_logic;                               -- bit 3 settle down
signal mts_wlk : std_logic;                               -- bit 2 write locked (always 1, read-only media)
signal mts_rew : std_logic;                               -- bit 1 rewinding
signal mts_tur : std_logic;                               -- bit 0 unit ready
signal mts : std_logic_vector(15 downto 0);

-- MTBRC - byte record counter - 172524 (2's complement)
signal mtbrc : std_logic_vector(15 downto 0);

-- MTCMA - current memory address - 172526 (low 16 bits; high 2 in MTC EMA)
signal mtcma : std_logic_vector(15 downto 0);

-- MTD - data buffer - 172530 (cosmetic here)
signal mtd : std_logic_vector(15 downto 0);

-- nclk <-> engine handshake
signal cmd_req : std_logic;                               -- nclk -> engine : start latched command
signal cmd_done : std_logic;                              -- engine -> nclk : command complete, results valid

-- latched at cmd_req (nclk -> engine)
signal lat_op : std_logic_vector(1 downto 0) := "00";     -- "00" tape function lat_fnc, "01" dma read, "10" dma write
signal lat_dma_addr : std_logic_vector(17 downto 0);      -- dma: first word address
signal lat_dma_cnt : integer range 0 to 8 := 0;           -- dma: words
type dma_buf_t is array(0 to 7) of std_logic_vector(15 downto 0);
signal dmawb : dma_buf_t;                                 -- nclk -> engine: words to write
signal dmarb : dma_buf_t;                                 -- engine -> nclk: words read
signal dma_idx : integer range 0 to 8 := 0;
signal dma_work : std_logic_vector(17 downto 0);
signal lat_fnc : std_logic_vector(2 downto 0);
signal lat_brc : std_logic_vector(15 downto 0);
signal lat_cma : std_logic_vector(15 downto 0);
signal lat_ema : std_logic_vector(1 downto 0);

-- published at cmd_done (engine -> nclk)
signal res_brc : std_logic_vector(15 downto 0);
signal res_cma : std_logic_vector(15 downto 0);
signal res_ema : std_logic_vector(1 downto 0);
signal res_eof : std_logic;
signal res_eot : std_logic;
signal res_bad : std_logic;
signal res_bot : std_logic;
signal res_rle : std_logic;
signal res_nxm : std_logic;
signal res_ill : std_logic;
signal res_rib : std_logic;                               -- a reverse space ran into BOT (TS11 reports it, RIB)

-- sdspi interface
signal sd_addr : std_logic_vector(23 downto 0);
signal sdcard_xfer_addr : integer range 0 to 255;
signal sdcard_xfer_read : std_logic := '0';
signal sdcard_xfer_out : std_logic_vector(15 downto 0);
signal sdcard_xfer_write : std_logic := '0';
signal sdcard_xfer_in : std_logic_vector(15 downto 0);
signal sdcard_idle : std_logic;
signal sdcard_read_start : std_logic := '0';
signal sdcard_read_ack : std_logic := '0';
signal sdcard_read_done : std_logic;
signal sdcard_write_start : std_logic;
signal sdcard_write_ack : std_logic;
signal sdcard_write_done : std_logic;
signal sdcard_error : std_logic;

-- tape engine
type engine_state_t is (
   eng_idle,
   -- block loader subroutine: ensure buf holds block for need_pos, then -> ld_ret
   eng_ld_check, eng_ld_req, eng_ld_wait, eng_ld_ack,
   -- header / trailer 4-byte reader: fills reclen, then -> rd_ret
   eng_hd_blk, eng_hd_a, eng_hd_b, eng_hd_c, eng_hd_eval,
   -- read record -> memory
   eng_rd_init, eng_rd_blk, eng_rd_acq, eng_rd_gnt,
   eng_rd_sa, eng_rd_w1, eng_rd_w2, eng_rd_w3, eng_rd_fin,
   -- space forward / reverse
   eng_sf_init, eng_sf_eval,
   eng_sr_init, eng_sr_chk, eng_sr_eval,
   -- rewind / unload / illegal
   eng_rew, eng_illegal,
   -- dma word read / write (TS11 packets)
   eng_dr_acq, eng_dr_gnt, eng_dr_a, eng_dr_b,
   eng_dw_acq, eng_dw_gnt, eng_dw_a, eng_dw_b,
   eng_finish
);
signal engine_state : engine_state_t := eng_idle;
signal ld_ret : engine_state_t;                           -- return target for eng_ld_*
signal rd_ret : engine_state_t;                           -- return target for eng_hd_*

signal tape_pos : std_logic_vector(31 downto 0) := (others => '0');  -- byte offset into .tap
signal need_pos : std_logic_vector(31 downto 0);
signal buf_lba : std_logic_vector(22 downto 0);
signal buf_valid : std_logic;

signal mc_e : std_logic_vector(2 downto 0) := "000";     -- media_change synced into clk domain
signal mc_n : std_logic_vector(2 downto 0) := "000";     -- media_change synced into nclk domain


signal reclen : std_logic_vector(31 downto 0);            -- current record length from .tap
signal reclen_pad : std_logic_vector(31 downto 0);        -- reclen rounded up to even
signal hd_pos : std_logic_vector(31 downto 0);            -- walking pointer for the 4-byte reader
signal hd_widx : std_logic;                               -- which of the 2 header words

signal xfer_bytes : std_logic_vector(16 downto 0);        -- min(reclen, req) actually transferred
signal words_left : std_logic_vector(15 downto 0);
signal payload_pos : std_logic_vector(31 downto 0);
signal cma_work : std_logic_vector(17 downto 0);          -- {ema, cma} working address
signal sp_count : std_logic_vector(15 downto 0);          -- space fwd/rev record counter (2's complement)

-- TS11 personality (ts_mode = '1'): same drive and .tap engine, TS11 registers and packets.
-- TSBA/TSDB 172520 (read: bus address; word write: command packet address -> fetch and run),
-- TSSR 172522 (read: status; word write: subsystem reset). Behaviour follows SIMH pdp11_ts.c.
-- Read-only like the TM11: write and format are refused (write lock). Read reverse is not
-- implemented yet (function reject, as an illegal mode).
constant TS_ACK   : std_logic_vector(15 downto 0) := 16o"100000";
constant TS_MILL  : std_logic_vector(15 downto 0) := 16o"000400";
constant TS_MNEF  : std_logic_vector(15 downto 0) := 16o"001000";
constant TS_CEND  : std_logic_vector(15 downto 0) := 16o"000020";
constant TS_CFAIL : std_logic_vector(15 downto 0) := 16o"000021";
constant TS_CERR  : std_logic_vector(15 downto 0) := 16o"000022";
constant TS_CATN  : std_logic_vector(15 downto 0) := 16o"000023";
constant XS0_TMK  : std_logic_vector(15 downto 0) := 16o"100000";
constant XS0_RLS  : std_logic_vector(15 downto 0) := 16o"040000";
constant XS0_LET  : std_logic_vector(15 downto 0) := 16o"020000";
constant XS0_RLL  : std_logic_vector(15 downto 0) := 16o"010000";
constant XS0_WLE  : std_logic_vector(15 downto 0) := 16o"004000";
constant XS0_NEF  : std_logic_vector(15 downto 0) := 16o"002000";
constant XS0_ILC  : std_logic_vector(15 downto 0) := 16o"001000";
constant XS0_ILA  : std_logic_vector(15 downto 0) := 16o"000400";
constant XS0_MOT  : std_logic_vector(15 downto 0) := 16o"000200";
constant XS0_BOT  : std_logic_vector(15 downto 0) := 16o"000002";
constant XS3_OPI  : std_logic_vector(15 downto 0) := 16o"000100";
constant XS3_RIB  : std_logic_vector(15 downto 0) := 16o"000001";
constant TSF_READ : std_logic_vector(4 downto 0) := "00001";
constant TSF_WCHR : std_logic_vector(4 downto 0) := "00100";
constant TSF_WRIT : std_logic_vector(4 downto 0) := "00101";
constant TSF_WSSM : std_logic_vector(4 downto 0) := "00110";
constant TSF_POS  : std_logic_vector(4 downto 0) := "01000";
constant TSF_FMT  : std_logic_vector(4 downto 0) := "01001";
constant TSF_CTL  : std_logic_vector(4 downto 0) := "01010";
constant TSF_INIT : std_logic_vector(4 downto 0) := "01011";
constant TSF_GSTA : std_logic_vector(4 downto 0) := "01111";
type ts_state_t is (ts_idle, ts_rew_wait, ts_fetch, ts_decode, ts_wchr_wait, ts_op_wait, ts_op_next, ts_end, ts_msg_wait);
signal ts_state : ts_state_t := ts_idle;
type ts_op_t is (op_readf, op_spacef, op_spacer, op_skipf, op_skipr, op_rew, op_rewunl);
signal ts_op : ts_op_t := op_rew;
signal tsba : std_logic_vector(17 downto 0);              -- last memory address
signal ts_sc, ts_rmr, ts_nxm, ts_nba, ts_ssr : std_logic;
signal ts_tc : std_logic_vector(2 downto 0);
signal tssr : std_logic_vector(15 downto 0);
signal cmdhdr, cmdadl, cmdadh, cmdlnt : std_logic_vector(15 downto 0);    -- command packet
signal wchadl, wchadh, wchlnt, wchopt, wchxopt : std_logic_vector(15 downto 0); -- characteristics
signal msgrfc, xs0f, xs1, xs2, xs3, xs4 : std_logic_vector(15 downto 0); -- message packet status
signal ts_bot : std_logic;                                -- at true BOT (rewound/mounted)
signal ts_vck : std_logic;                                -- volume check (set by reset, CVC clears)
signal ts_int : std_logic;                                -- interrupt pending
signal ts_rst_rew : std_logic;                            -- rewind owed after a TSSR-write reset
signal ts_skipn : std_logic_vector(15 downto 0);          -- skip tape marks: marks still to pass
signal ts_tmkprv : std_logic;                             -- skip: the last thing passed was a tape mark
signal e_tc : std_logic_vector(2 downto 0);               -- end of command: termination class,
signal e_xs0 : std_logic_vector(15 downto 0);             -- XS0 bits to add,
signal e_msg : std_logic_vector(15 downto 0);             -- message header (0: no message packet)
signal ts_msgn : integer range 0 to 8;
signal ts_msga : std_logic_vector(17 downto 0);
signal ts_wchn : integer range 0 to 8;

begin

   have_media <= '1' when img_mounted = 1 else '0';

   -- read-only drive: the write handshake is never used, but must be low
   -- (mister_blkdev starts a request only with both acks low)
   sdcard_write_start <= '0';
   sdcard_write_ack <= '0';
   sdcard_xfer_in <= (others => '0');

   sd1: mister_blkdev port map(
      sdcard_addr => sd_addr,

      sdcard_idle => sdcard_idle,
      sdcard_read_start => sdcard_read_start,
      sdcard_read_ack => sdcard_read_ack,
      sdcard_read_done => sdcard_read_done,
      sdcard_write_start => sdcard_write_start,
      sdcard_write_ack => sdcard_write_ack,
      sdcard_write_done => sdcard_write_done,
      sdcard_error => sdcard_error,

      sdcard_xfer_addr => sdcard_xfer_addr,
      sdcard_xfer_read => sdcard_xfer_read,
      sdcard_xfer_out => sdcard_xfer_out,
      sdcard_xfer_in => sdcard_xfer_in,
      sdcard_xfer_write => sdcard_xfer_write,

      enable => have_tm,
      controller_clk => clk,
      reset => reset,

      sd_lba => sd_lba,
      sd_rd => sd_rd,
      sd_wr => sd_wr,
      sd_ack => sd_ack,
      sd_buff_addr => sd_buff_addr,
      sd_buff_dout => sd_buff_dout,
      sd_buff_din => sd_buff_din,
      sd_buff_wr => sd_buff_wr,
      clk_sys => clk_sys
   );

-- regular bus interface

   base_addr_match <= '1' when base_addr(17 downto 4) = bus_addr(17 downto 4) and have_tm = 1 else '0';
   bus_addr_match <= base_addr_match;

-- register assembly

   mtc_err <= mts_ill or mts_crc or mts_par or mts_dlt or mts_eot or mts_rle or mts_bad or mts_nxm;
   mtc <= mtc_err & mtc_den & '0' & mtc_lpar & mtc_unit & mtc_rdy & mtc_ie & mtc_ema & mtc_fnc & mtc_go;
   mts <= mts_ill & mts_eof & mts_crc & mts_par & mts_dlt & mts_eot & mts_rle & mts_bad
        & mts_nxm & (mts_onl and have_media) & mts_bot & mts_7tk & mts_sdn & mts_wlk & mts_rew & (mts_tur and have_media);

   -- TSSR: SC . . RMR NXM NBA A17 A16 SSR OFL . . TC2 TC1 TC0 .
   tssr <= ts_sc & "00" & ts_rmr & ts_nxm & ts_nba & tsba(17 downto 16) & ts_ssr & (not have_media)
           & "00" & ts_tc & '0';

   sd_addr <= '0' & need_pos(31 downto 9);
   reclen_pad <= reclen when reclen(0) = '0' else reclen + 1;


-- regular bus interface : registers, command dispatch, interrupts

   process(nclk, reset)
      variable w : std_logic_vector(15 downto 0);
      variable fnc : std_logic_vector(4 downto 0);
      variable md : integer range 0 to 15;
      variable vck : std_logic;
      variable modok : boolean;
      variable rfc : std_logic_vector(15 downto 0);
      variable tc : std_logic_vector(2 downto 0);
      variable x0 : std_logic_vector(15 downto 0);
      variable a18 : std_logic_vector(17 downto 0);
      variable n : integer range 0 to 8;
      variable bytes : std_logic_vector(15 downto 0);
   begin
      if nclk = '1' and nclk'event then
         if reset = '1' then

            if have_tm = 1 then
               mtc_den <= "00";
               mtc_lpar <= '0';
               mtc_unit <= "000";
               mtc_rdy <= '1';
               mtc_ie <= '0';
               mtc_ema <= "00";
               mtc_fnc <= "000";
               mtc_go <= '0';

               mts_ill <= '0'; mts_eof <= '0'; mts_crc <= '0'; mts_par <= '0';
               mts_dlt <= '0'; mts_eot <= '0'; mts_rle <= '0'; mts_bad <= '0';
               mts_nxm <= '0'; mts_onl <= '1'; mts_bot <= '1'; mts_7tk <= '0';
               mts_sdn <= '0'; mts_wlk <= '1'; mts_rew <= '0'; mts_tur <= '1';

               mtbrc <= (others => '0');
               mtcma <= (others => '0');
               mtd <= (others => '0');

               cmd_req <= '0';
               lat_fnc <= "000";
               lat_brc <= (others => '0');
               lat_cma <= (others => '0');
               lat_ema <= "00";

               br <= '0';
               interrupt_trigger <= '0';
               interrupt_state <= i_idle;
               mc_n <= "000";

               lat_op <= "00";
               ts_state <= ts_idle;                            -- TS11 reset (bus INIT); the engine
               tsba <= (others => '0');                        -- rewinds on the same reset
               ts_sc <= '0'; ts_rmr <= '0'; ts_nxm <= '0'; ts_nba <= '1'; ts_ssr <= '1';
               ts_tc <= "000";
               cmdhdr <= (others => '0'); cmdadl <= (others => '0'); cmdadh <= (others => '0'); cmdlnt <= (others => '0');
               wchadl <= (others => '0'); wchadh <= (others => '0'); wchlnt <= (others => '0');
               wchopt <= (others => '0'); wchxopt <= (others => '0');
               msgrfc <= (others => '0'); xs0f <= (others => '0'); xs1 <= (others => '0');
               xs2 <= (others => '0'); xs3 <= (others => '0'); xs4 <= (others => '0');
               ts_bot <= have_media; ts_vck <= '1'; ts_int <= '0'; ts_rst_rew <= '0';
            end if;

         else

            if have_tm = 1 then

-- interrupt state machine (identical to rl11)

               case interrupt_state is
                  when i_idle =>
                     br <= '0';
                     if ts_mode = '1' then                           -- TS11: a pending request, until granted
                        if ts_int = '1' then
                           interrupt_state <= i_req;
                           br <= '1';
                        end if;
                     elsif mtc_ie = '1' and mtc_rdy = '1' then
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
                        ts_int <= '0';
                        interrupt_state <= i_wait;
                     end if;

                  when i_wait =>
                     if bg = '0' then
                        interrupt_state <= i_idle;
                     end if;

                  when others =>
                     interrupt_state <= i_idle;
               end case;

               if ts_mode = '0' then

-- register reads

               if base_addr_match = '1' and bus_control_dati = '1' then
                  case bus_addr(3 downto 1) is
                     when "000" => bus_dati <= mts;
                     when "001" => bus_dati <= mtc;
                     when "010" => bus_dati <= mtbrc;
                     when "011" => bus_dati <= mtcma;
                     when "100" => bus_dati <= mtd;
                     when others => bus_dati <= (others => '0');
                  end case;
               end if;

-- register writes

               if base_addr_match = '1' and bus_control_dato = '1' and mtc_rdy = '1' then
                  case bus_addr(3 downto 1) is

                     when "001" =>                                     -- MTC
                        w := mtc;
                        if bus_control_datob = '0' then
                           w := bus_dato;
                        elsif bus_addr(0) = '0' then
                           w(7 downto 0) := bus_dato(7 downto 0);
                        else
                           w(15 downto 8) := bus_dato(15 downto 8);
                        end if;

                        mtc_den <= w(14 downto 13);
                        mtc_lpar <= w(11);
                        mtc_unit <= w(10 downto 8);
                        mtc_ie <= w(6);
                        mtc_ema <= w(5 downto 4);
                        mtc_fnc <= w(3 downto 1);

                        if w(12) = '1' then                            -- INIT / power clear
                           mts_ill <= '0'; mts_eof <= '0'; mts_crc <= '0'; mts_par <= '0';
                           mts_dlt <= '0'; mts_eot <= '0'; mts_rle <= '0'; mts_bad <= '0';
                           mts_nxm <= '0';
                           mtc_ie <= '0';
                        end if;

                        if w(0) = '1' and w(12) = '0' then             -- GO
                           lat_op <= "00";
                           lat_fnc <= w(3 downto 1);
                           lat_brc <= mtbrc;
                           lat_cma <= mtcma;
                           lat_ema <= w(5 downto 4);
                           -- clear volatile status for the new operation
                           mts_ill <= '0'; mts_eof <= '0'; mts_crc <= '0'; mts_par <= '0';
                           mts_dlt <= '0'; mts_eot <= '0'; mts_rle <= '0'; mts_bad <= '0';
                           mts_nxm <= '0'; mts_tur <= '0';
                           mtc_rdy <= '0';
                           cmd_req <= '1';
                        end if;

                     when "010" =>                                     -- MTBRC
                        w := mtbrc;
                        if bus_control_datob = '0' then
                           w := bus_dato;
                        elsif bus_addr(0) = '0' then
                           w(7 downto 0) := bus_dato(7 downto 0);
                        else
                           w(15 downto 8) := bus_dato(15 downto 8);
                        end if;
                        mtbrc <= w;

                     when "011" =>                                     -- MTCMA
                        w := mtcma;
                        if bus_control_datob = '0' then
                           w := bus_dato;
                        elsif bus_addr(0) = '0' then
                           w(7 downto 0) := bus_dato(7 downto 0);
                        else
                           w(15 downto 8) := bus_dato(15 downto 8);
                        end if;
                        mtcma <= w(15 downto 1) & '0';

                     when "100" =>                                     -- MTD
                        mtd <= bus_dato;

                     when others =>
                        null;
                  end case;
               end if;

-- collect engine results

               if cmd_req = '1' and cmd_done = '1' then
                  mtbrc <= res_brc;
                  mtcma <= res_cma;
                  mtc_ema <= res_ema;
                  mts_eof <= res_eof;
                  mts_eot <= res_eot;
                  mts_bad <= res_bad;
                  mts_bot <= res_bot;
                  mts_rle <= res_rle;
                  mts_nxm <= res_nxm;
                  mts_ill <= res_ill;
                  mts_tur <= '1';
                  mtc_rdy <= '1';
                  cmd_req <= '0';
               end if;

-- media (un)mount : re-home to BOT, drop any pending command

               mc_n <= mc_n(1 downto 0) & media_change;
               if mc_n(2) /= mc_n(1) then
                  mts_bot <= '1'; mts_tur <= '1';
                  mts_ill <= '0'; mts_eof <= '0'; mts_crc <= '0'; mts_par <= '0';
                  mts_dlt <= '0'; mts_eot <= '0'; mts_rle <= '0'; mts_bad <= '0';
                  mts_nxm <= '0';
                  mtc_rdy <= '1';
                  cmd_req <= '0';
               end if;

               else
-- ===== TS11 personality ===========================================================
-- Registers: 172520 read TSBA (bus address), word write TSDB (command packet address);
-- 172522 read TSSR, word write = subsystem reset. A command: fetch the 4-word packet by
-- DMA, check it as SIMH ts_svc does, run it on the tape engine, then end it: XS0 updated,
-- the message packet written to the characteristics' buffer (unless NBA), TSSR's TC,
-- SSR and SC set, and an interrupt if the packet asked for one.

               if base_addr_match = '1' and bus_control_dati = '1' then
                  case bus_addr(3 downto 1) is
                     when "000" => bus_dati <= tsba(15 downto 0);
                     when "001" => bus_dati <= tssr;
                     when others => bus_dati <= (others => '0');
                  end case;
               end if;

               if base_addr_match = '1' and bus_control_dato = '1' and bus_control_datob = '0' then
                  case bus_addr(3 downto 1) is
                     when "000" =>                                     -- TSDB: start a command
                        if ts_ssr = '0' or ts_state /= ts_idle or cmd_req = '1' or cmd_done = '1' then
                           ts_rmr <= '1';                              -- not ready: register modification refused
                        else
                           a18 := bus_dato(1 downto 0) & bus_dato(15 downto 2) & "00";
                           tsba <= a18;
                           ts_ssr <= '0'; ts_sc <= '0'; ts_rmr <= '0'; ts_nxm <= '0'; ts_tc <= "000";
                           xs0f <= (others => '0');
                           msgrfc <= (others => '0'); xs1 <= (others => '0'); xs2 <= (others => '0');
                           xs3 <= (others => '0'); xs4 <= (others => '0');
                           ts_int <= '0';
                           lat_op <= "01"; lat_dma_addr <= a18; lat_dma_cnt <= 4;
                           cmd_req <= '1';
                           ts_state <= ts_fetch;
                        end if;
                     when "001" =>                                     -- TSSR write: subsystem reset
                        ts_state <= ts_idle;
                        tsba <= (others => '0');
                        ts_sc <= '0'; ts_rmr <= '0'; ts_nxm <= '0'; ts_nba <= '1'; ts_ssr <= '1';
                        ts_tc <= "000";
                        cmdhdr <= (others => '0'); cmdadl <= (others => '0'); cmdadh <= (others => '0'); cmdlnt <= (others => '0');
                        wchadl <= (others => '0'); wchadh <= (others => '0'); wchlnt <= (others => '0');
                        wchopt <= (others => '0'); wchxopt <= (others => '0');
                        msgrfc <= (others => '0'); xs0f <= (others => '0'); xs1 <= (others => '0');
                        xs2 <= (others => '0'); xs3 <= (others => '0'); xs4 <= (others => '0');
                        ts_bot <= have_media; ts_vck <= '1'; ts_int <= '0';
                        ts_rst_rew <= '1';                             -- SIMH ts_reset rewinds
                     when others =>
                        null;
                  end case;
               end if;

               case ts_state is

                  when ts_idle =>
                     if ts_rst_rew = '1' and cmd_req = '0' and cmd_done = '0' then
                        ts_rst_rew <= '0';
                        lat_op <= "00"; lat_fnc <= fnc_rewind; lat_brc <= (others => '0');
                        cmd_req <= '1';
                        ts_state <= ts_rew_wait;
                     end if;

                  when ts_rew_wait =>
                     if cmd_done = '1' then
                        cmd_req <= '0';
                        ts_state <= ts_idle;
                     end if;

                  when ts_fetch =>                                     -- command packet fetched?
                     if cmd_done = '1' then
                        cmd_req <= '0';
                        if res_nxm = '1' then
                           ts_nxm <= '1';
                           e_tc <= "101"; e_xs0 <= (others => '0'); e_msg <= TS_ACK or TS_MNEF or TS_CFAIL;
                           ts_state <= ts_end;
                        else
                           cmdhdr <= dmarb(0); cmdadl <= dmarb(1); cmdadh <= dmarb(2); cmdlnt <= dmarb(3);
                           tsba <= tsba + 8;
                           ts_state <= ts_decode;
                        end if;
                     end if;

                  when ts_decode =>
                     if cmd_done = '0' then
                        fnc := cmdhdr(4 downto 0);
                        md := conv_integer(cmdhdr(11 downto 8));
                        vck := ts_vck;
                        if cmdhdr(14) = '1' then                       -- CVC: clear volume check
                           vck := '0';
                           ts_vck <= '0';
                        end if;
                        case fnc is                                    -- SIMH fnc_mod: modes per function
                           when TSF_READ => modok := md < 4;
                           when TSF_WCHR | TSF_WSSM | TSF_INIT | TSF_GSTA => modok := md < 1;
                           when TSF_WRIT => modok := md < 2;
                           when TSF_POS | TSF_CTL => modok := md < 5;
                           when TSF_FMT => modok := md < 3;
                           when others => modok := false;
                        end case;
                        e_xs0 <= (others => '0');
                        e_msg <= TS_ACK or TS_CEND;
                        e_tc <= "000";
                        if cmdhdr(15) = '0' then                       -- no ACK: just hand the buffer back
                           ts_vck <= ts_vck;                           -- (SIMH returns before CVC)
                           ts_ssr <= '1';
                           if cmdhdr(7) = '1' then
                              ts_int <= '1';
                           end if;
                           ts_state <= ts_idle;
                        elsif fnc /= TSF_WCHR and ts_nba = '1' then   -- no message buffer yet
                           ts_vck <= ts_vck;                           -- (SIMH returns before CVC)
                           e_tc <= "011"; e_msg <= (others => '0');
                           ts_state <= ts_end;
                        elsif cmdhdr(6 downto 5) /= "00" or not modok then
                           e_tc <= "011"; e_xs0 <= XS0_ILC; e_msg <= TS_ACK or TS_MILL or TS_CFAIL;
                           ts_state <= ts_end;
                        elsif (fnc = TSF_READ or fnc = TSF_WRIT or fnc = TSF_POS or fnc = TSF_FMT or fnc = TSF_CTL)
                              and (vck = '1' or have_media = '0') then  -- motion: volume check or no tape
                           e_tc <= "011"; e_xs0 <= XS0_NEF; e_msg <= TS_ACK or TS_MNEF or TS_CFAIL;
                           ts_state <= ts_end;
                        elsif fnc = TSF_WRIT or fnc = TSF_FMT then     -- read-only drive: write locked
                           e_tc <= "011"; e_xs0 <= XS0_WLE or XS0_NEF; e_msg <= TS_ACK or TS_MNEF or TS_CFAIL;
                           ts_state <= ts_end;
                        elsif ((fnc = TSF_READ and md = 1) or (fnc = TSF_POS and (md = 1 or md = 3)))
                              and ts_bot = '1' then                    -- reverse at BOT
                           e_tc <= "011"; e_xs0 <= XS0_NEF; e_msg <= TS_ACK or TS_MNEF or TS_CFAIL;
                           ts_state <= ts_end;
                        elsif (fnc = TSF_READ or fnc = TSF_WSSM) and cmdadh(15 downto 2) /= "00000000000000" then
                           e_tc <= "011"; e_xs0 <= XS0_ILA; e_msg <= TS_ACK or TS_MILL or TS_CFAIL;
                           ts_state <= ts_end;
                        else
                           case fnc is
                              when TSF_INIT | TSF_WSSM | TSF_GSTA =>
                                 ts_state <= ts_end;
                              when TSF_WCHR =>
                                 if cmdadh(15 downto 2) /= "00000000000000" or cmdadl(0) = '1' or cmdlnt < 6 then
                                    ts_nba <= '1';
                                    e_tc <= "011"; e_xs0 <= XS0_ILA; e_msg <= (others => '0');
                                    ts_state <= ts_end;
                                 else
                                    if cmdlnt >= 10 then n := 5; else n := conv_integer(cmdlnt(3 downto 1)); end if;
                                    ts_wchn <= n;
                                    lat_op <= "01"; lat_dma_addr <= cmdadh(1 downto 0) & cmdadl; lat_dma_cnt <= n;
                                    cmd_req <= '1';
                                    ts_state <= ts_wchr_wait;
                                 end if;
                              when TSF_CTL =>
                                 case md is
                                    when 0 =>                          -- message buffer release
                                       ts_ssr <= '1';
                                       if wchopt(4) = '1' then
                                          ts_int <= '1';
                                       end if;
                                       ts_state <= ts_idle;
                                    when 1 | 4 =>                      -- rewind and unload / rewind
                                       if md = 1 then ts_op <= op_rewunl; else ts_op <= op_rew; end if;
                                       lat_op <= "00"; lat_fnc <= fnc_rewind; lat_brc <= (others => '0');
                                       cmd_req <= '1';
                                       ts_state <= ts_op_wait;
                                    when 2 =>                          -- clean: nothing to do
                                       ts_state <= ts_end;
                                    when others =>
                                       e_tc <= "011"; e_xs0 <= XS0_ILC; e_msg <= TS_ACK or TS_MILL or TS_CFAIL;
                                       ts_state <= ts_end;
                                 end case;
                              when TSF_READ =>
                                 if md = 0 then                        -- read forward
                                    ts_op <= op_readf;
                                    lat_op <= "00"; lat_fnc <= fnc_read;
                                    lat_brc <= x"0000" - cmdlnt;       -- engine counts up from -length
                                    lat_cma <= cmdadl(15 downto 1) & '0'; lat_ema <= cmdadh(1 downto 0);
                                    cmd_req <= '1';
                                    ts_state <= ts_op_wait;
                                 else                                  -- read reverse / reread: not yet
                                    e_tc <= "011"; e_xs0 <= XS0_ILC; e_msg <= TS_ACK or TS_MILL or TS_CFAIL;
                                    ts_state <= ts_end;
                                 end if;
                              when TSF_POS =>
                                 lat_op <= "00"; lat_brc <= x"0000" - cmdadl;
                                 case md is
                                    when 0 => ts_op <= op_spacef; lat_fnc <= fnc_spacef;
                                    when 1 => ts_op <= op_spacer; lat_fnc <= fnc_spacer;
                                    when 2 => ts_op <= op_skipf; lat_fnc <= fnc_spacef; lat_brc <= (others => '0');
                                              ts_skipn <= cmdadl; ts_tmkprv <= ts_bot and wchopt(6);
                                    when 3 => ts_op <= op_skipr; lat_fnc <= fnc_spacer; lat_brc <= (others => '0');
                                              ts_skipn <= cmdadl; ts_tmkprv <= '0';
                                    when others => ts_op <= op_rew; lat_fnc <= fnc_rewind;
                                 end case;
                                 cmd_req <= '1';
                                 ts_state <= ts_op_wait;
                              when others =>
                                 e_tc <= "011"; e_xs0 <= XS0_ILC; e_msg <= TS_ACK or TS_MILL or TS_CFAIL;
                                 ts_state <= ts_end;
                           end case;
                        end if;
                     end if;

                  when ts_wchr_wait =>                                 -- characteristics fetched?
                     if cmd_done = '1' then
                        cmd_req <= '0';
                        a18 := cmdadh(1 downto 0) & cmdadl;
                        tsba <= a18 + (ts_wchn * 2);
                        if res_nxm = '1' then
                           ts_nba <= '1'; ts_nxm <= '1';
                           e_tc <= "101"; e_msg <= (others => '0');
                           ts_state <= ts_end;
                        else
                           wchadl <= dmarb(0); wchadh <= dmarb(1); wchlnt <= dmarb(2);
                           if ts_wchn > 3 then wchopt <= dmarb(3); end if;
                           if ts_wchn > 4 then wchxopt <= dmarb(4); end if;
                           if dmarb(2) < 14 or dmarb(1)(15 downto 6) /= "0000000000" or dmarb(0)(0) = '1' then
                              ts_nba <= '1';
                              e_tc <= "011"; e_msg <= (others => '0');
                           else
                              xs2 <= xs2 or 16o"000201";                -- extended features, 1
                              ts_nba <= '0';
                              e_tc <= "000"; e_msg <= TS_ACK or TS_CEND;
                           end if;
                           ts_state <= ts_end;
                        end if;
                     end if;

                  when ts_op_wait =>                                   -- a tape operation finished
                     if cmd_done = '1' then
                        cmd_req <= '0';
                        tc := "000"; x0 := (others => '0');
                        rfc := x"0000" - res_brc;                     -- records/marks still to go
                        case ts_op is
                           when op_readf =>
                              bytes := res_brc - lat_brc;
                              if res_eof = '1' then
                                 x0 := XS0_TMK or XS0_RLS or XS0_MOT; tc := "010";
                                 ts_bot <= '0'; msgrfc <= cmdlnt;
                              elsif res_bad = '1' then
                                 xs3 <= xs3 or XS3_OPI; x0 := XS0_RLS; tc := "110";
                                 msgrfc <= cmdlnt;
                              else
                                 ts_bot <= '0';
                                 tsba <= (cmdadh(1 downto 0) & cmdadl) + bytes;
                                 msgrfc <= cmdlnt - bytes;
                                 x0 := XS0_MOT;
                                 if res_nxm = '1' then
                                    ts_nxm <= '1'; x0 := x0 or XS0_RLS; tc := "100";
                                 elsif cmdlnt /= bytes then            -- record shorter than the buffer
                                    x0 := x0 or XS0_RLS; tc := "010";
                                 elsif res_rle = '1' then              -- record longer than the buffer
                                    x0 := x0 or XS0_RLL; tc := "010";
                                 end if;
                              end if;
                           when op_spacef =>
                              msgrfc <= rfc;
                              if res_brc /= lat_brc then
                                 x0 := XS0_MOT; ts_bot <= '0';
                              end if;
                              if res_eof = '1' then
                                 x0 := x0 or XS0_TMK or XS0_RLS; tc := "010";
                              elsif res_bad = '1' then
                                 xs3 <= xs3 or XS3_OPI; x0 := x0 or XS0_RLS; tc := "110";
                              end if;
                           when op_spacer =>
                              msgrfc <= rfc;
                              if res_brc /= lat_brc and res_rib = '0' then
                                 x0 := XS0_MOT;
                              end if;
                              ts_bot <= '0';
                              if res_rib = '1' then                    -- spaced into BOT
                                 xs3 <= xs3 or XS3_RIB; ts_bot <= '1';
                                 x0 := x0 or XS0_BOT or XS0_RLS; tc := "010";
                              elsif res_eof = '1' then
                                 x0 := x0 or XS0_MOT or XS0_TMK or XS0_RLS; tc := "010";
                              end if;
                           when op_skipf | op_skipr =>
                              msgrfc <= ts_skipn;
                              if res_rib = '1' then
                                 xs3 <= xs3 or XS3_RIB; ts_bot <= '1';
                                 x0 := XS0_BOT or XS0_RLS; tc := "010";
                              elsif res_bad = '1' then
                                 xs3 <= xs3 or XS3_OPI; x0 := XS0_RLS; tc := "110";
                              else
                                 x0 := XS0_MOT; ts_bot <= '0';
                                 if res_eof = '1' then                 -- passed a tape mark
                                    w := ts_skipn - 1;
                                    msgrfc <= w;
                                    if res_brc = x"0001" and ts_tmkprv = '1' and wchopt(7) = '1' then
                                       x0 := x0 or XS0_TMK or XS0_LET;    -- double tape mark: logical end
                                       if w /= x"0000" then x0 := x0 or XS0_RLS; end if;
                                       tc := "010";
                                    elsif w /= x"0000" then           -- more marks to pass
                                       ts_skipn <= w;
                                       ts_tmkprv <= '1';
                                       xs0f <= xs0f or XS0_MOT;
                                       ts_state <= ts_op_next;
                                    end if;
                                 else                                  -- 65536 records, no mark: go on
                                    ts_tmkprv <= '0';
                                    xs0f <= xs0f or XS0_MOT;
                                    ts_state <= ts_op_next;
                                 end if;
                              end if;
                           when op_rew =>
                              x0 := XS0_MOT; ts_bot <= '1';
                              if cmdhdr(4 downto 0) = TSF_CTL then
                                 x0 := x0 or XS0_BOT;
                              end if;
                           when op_rewunl =>
                              if ts_bot = '0' then x0 := XS0_MOT; end if;
                              ts_bot <= '1';
                        end case;
                        if not ((ts_op = op_skipf or ts_op = op_skipr) and res_rib = '0' and res_bad = '0'
                                and (res_eof = '0' or (ts_skipn /= x"0001"
                                     and not (res_brc = x"0001" and ts_tmkprv = '1' and wchopt(7) = '1')))) then
                           e_tc <= tc; e_xs0 <= x0;
                           case tc is                                  -- SIMH ts_cmpendcmd message
                              when "000" | "010" => e_msg <= TS_ACK or TS_CEND;
                              when "001" => e_msg <= TS_ACK or TS_CATN;
                              when "011" => e_msg <= TS_ACK or TS_CFAIL;
                              when others => e_msg <= TS_ACK or TS_CERR;
                           end case;
                           ts_state <= ts_end;
                        end if;
                     end if;

                  when ts_op_next =>                                   -- skip: next leg once the engine is idle
                     if cmd_done = '0' then
                        lat_brc <= (others => '0');
                        cmd_req <= '1';
                        ts_state <= ts_op_wait;
                     end if;

                  when ts_end =>                                       -- SIMH ts_endcmd
                     if cmd_done = '0' then
                        x0 := (xs0f or e_xs0) and not 16o"000177";      -- dynamic bits rebuilt below
                        x0(3) := '1';                                  -- PET: 1600 bpi
                        if have_media = '1' then
                           x0(6) := '1';                               -- ONL
                           x0(2) := '1';                               -- WLK: read-only drive
                           if ts_bot = '1' then x0(1) := '1'; end if;  -- BOT
                        end if;
                        x0(5) := cmdhdr(7);                            -- IE
                        x0(4) := ts_vck;                               -- VCK
                        xs0f <= x0;
                        w := xs4;
                        if wchxopt(5) = '1' then w := w or 16o"100000"; end if;
                        xs4 <= w;
                        if e_msg /= x"0000" and ts_nba = '0' then
                           if wchlnt(15 downto 4) /= x"000" then n := 8; else n := conv_integer(wchlnt(3 downto 1)); end if;
                           dmawb(0) <= e_msg; dmawb(1) <= wchlnt - 4; dmawb(2) <= msgrfc; dmawb(3) <= x0;
                           dmawb(4) <= xs1; dmawb(5) <= xs2; dmawb(6) <= xs3; dmawb(7) <= w;
                           ts_msgn <= n;
                           a18 := wchadh(1 downto 0) & wchadl;
                           ts_msga <= a18;
                           lat_op <= "10"; lat_dma_addr <= a18; lat_dma_cnt <= n;
                           cmd_req <= '1';
                           ts_state <= ts_msg_wait;
                        else
                           ts_tc <= e_tc; ts_ssr <= '1';
                           if e_tc /= "000" then ts_sc <= '1'; end if;
                           if cmdhdr(7) = '1' then ts_int <= '1'; end if;
                           ts_state <= ts_idle;
                        end if;
                     end if;

                  when ts_msg_wait =>                                  -- message packet written?
                     if cmd_done = '1' then
                        cmd_req <= '0';
                        tsba <= ts_msga + (ts_msgn * 2);
                        tc := e_tc;
                        if res_nxm = '1' then
                           ts_nxm <= '1'; tc := "100";
                        end if;
                        ts_tc <= tc; ts_ssr <= '1';
                        if tc /= "000" then ts_sc <= '1'; end if;
                        if cmdhdr(7) = '1' then ts_int <= '1'; end if;
                        ts_state <= ts_idle;
                     end if;

                  when others =>
                     ts_state <= ts_idle;
               end case;

-- media (un)mount: back to BOT, any command dropped, ready
               mc_n <= mc_n(1 downto 0) & media_change;
               if mc_n(2) /= mc_n(1) then
                  cmd_req <= '0';
                  ts_state <= ts_idle;
                  ts_ssr <= '1';
                  ts_bot <= '1';
               end if;
               end if;

            else
               br <= '0';
            end if;
         end if;
      end if;
   end process;

-- tape engine + NPR busmaster

   process(clk, reset)
      variable nxt_idx : std_logic_vector(7 downto 0);
      variable xb : std_logic_vector(16 downto 0);
      variable wl : std_logic_vector(15 downto 0);
   begin
      if clk = '1' and clk'event then
         if reset = '1' then

            engine_state <= eng_idle;
            npr <= '0';
            bus_master_control_dati <= '0';
            bus_master_control_dato <= '0';
            sdcard_read_start <= '0';
            sdcard_read_ack <= '0';
            sdcard_xfer_write <= '0';
            sdcard_xfer_read <= '0';
            cmd_done <= '0';
            buf_valid <= '0';
            tape_pos <= (others => '0');
            need_pos <= (others => '0');
            mc_e <= "000";

         else
            if have_tm = 1 then

               mc_e <= mc_e(1 downto 0) & media_change;

               case engine_state is

                  when eng_idle =>
                     npr <= '0';
                     bus_master_control_dato <= '0';
                     bus_master_control_dati <= '0';
                     if cmd_req = '1' and cmd_done = '0' then
                        res_brc <= lat_brc;
                        res_cma <= lat_cma;
                        res_ema <= lat_ema;
                        res_eof <= '0'; res_eot <= '0'; res_bot <= '0'; res_bad <= '0';
                        res_rle <= '0'; res_nxm <= '0'; res_ill <= '0'; res_rib <= '0';

                        if lat_op = "01" then                          -- dma word read (TS11 packets)
                           dma_idx <= 0;
                           dma_work <= lat_dma_addr;
                           engine_state <= eng_dr_acq;
                        elsif lat_op = "10" then                       -- dma word write
                           dma_idx <= 0;
                           dma_work <= lat_dma_addr;
                           engine_state <= eng_dw_acq;
                        elsif have_media = '0' then                       -- no tape mounted: every real
                           engine_state <= eng_illegal;                -- tape operation is illegal, same
                                                                        -- as write/wreof/wrext below
                        else
                        case lat_fnc is
                           when fnc_read =>
                              hd_pos <= tape_pos;
                              hd_widx <= '0';
                              rd_ret <= eng_rd_init;
                              engine_state <= eng_hd_blk;
                           when fnc_spacef =>
                              engine_state <= eng_sf_init;
                           when fnc_spacer =>
                              engine_state <= eng_sr_init;
                           when fnc_rewind | fnc_unload =>
                              engine_state <= eng_rew;
                           when others =>                             -- write / wreof / wrext
                              engine_state <= eng_illegal;
                        end case;
                        end if;
                     end if;

-- --- block loader subroutine --------------------------------------------------
-- ensure the sdspi buffer holds the 512-byte block containing need_pos, then
-- branch to ld_ret.

                  when eng_ld_check =>
                     if buf_valid = '1' and buf_lba = need_pos(31 downto 9) then
                        engine_state <= ld_ret;
                     else
                        engine_state <= eng_ld_req;
                     end if;

                  when eng_ld_req =>
                     if sdcard_idle = '1' and sdcard_read_done = '0' and sdcard_read_start = '0' then
                        sdcard_read_start <= '1';
                        engine_state <= eng_ld_wait;
                     end if;

                  when eng_ld_wait =>
                     if sdcard_read_done = '1' then
                        buf_lba <= need_pos(31 downto 9);
                        buf_valid <= '1';
                        sdcard_read_start <= '0';
                        sdcard_read_ack <= '1';
                        engine_state <= eng_ld_ack;
                     end if;

                  when eng_ld_ack =>
                     if sdcard_read_done = '0' then
                        sdcard_read_ack <= '0';
                        engine_state <= ld_ret;
                     end if;

-- --- 4-byte record-length reader --------------------------------------------
-- reads the two 16-bit words at hd_pos and hd_pos+2 into reclen (LE), each with
-- its own block-ensure, then branches to rd_ret.  headers are always even, but
-- may straddle a 512-byte block boundary.

                  when eng_hd_blk =>
                     need_pos <= hd_pos;
                     ld_ret <= eng_hd_a;
                     engine_state <= eng_ld_check;

                  when eng_hd_a =>
                     sdcard_xfer_addr <= conv_integer(hd_pos(8 downto 1));
                     engine_state <= eng_hd_b;

                  when eng_hd_b =>                                     -- xfer_out latency
                     engine_state <= eng_hd_c;

                  when eng_hd_c =>
                     if hd_widx = '0' then
                        reclen(15 downto 0) <= sdcard_xfer_out;
                        hd_widx <= '1';
                        hd_pos <= hd_pos + 2;
                        engine_state <= eng_hd_blk;
                     else
                        reclen(31 downto 16) <= sdcard_xfer_out;
                        engine_state <= eng_hd_eval;
                     end if;

                  when eng_hd_eval =>
                     engine_state <= rd_ret;

-- --- read record into memory ------------------------------------------------

                  when eng_rd_init =>
                     if reclen = x"00000000" then                     -- tape mark
                        res_eof <= '1';
                        tape_pos <= tape_pos + 4;
                        engine_state <= eng_finish;
                     elsif reclen(31) = '1' then                      -- EOM / gap / error
                        res_bad <= '1';
                        engine_state <= eng_finish;
                     else
                        -- req = -(MTBRC), 1..65536, as unsigned(16 downto 0)
                        xb := ('1' & x"0000") - ('0' & lat_brc);
                        if reclen(31 downto 17) /= "000000000000000"
                        or reclen(16 downto 0) > xb then
                           res_rle <= '1';                                   -- driver under-ran; xb (= req) stands
                        else
                           xb := reclen(16 downto 0);
                        end if;
                        wl := xb(16 downto 1) + ("000000000000000" & xb(0));   -- ceil(xb/2)
                        xfer_bytes <= xb;
                        words_left <= wl;
                        payload_pos <= tape_pos + 4;
                        cma_work <= lat_ema & lat_cma;
                        engine_state <= eng_rd_blk;
                     end if;

                  when eng_rd_blk =>
                     if words_left = x"0000" then
                        engine_state <= eng_rd_fin;
                     else
                        need_pos <= payload_pos;
                        ld_ret <= eng_rd_acq;
                        engine_state <= eng_ld_check;
                     end if;

                  when eng_rd_acq =>
                     npr <= '1';
                     engine_state <= eng_rd_gnt;

                  when eng_rd_gnt =>
                     if npg = '1' then
                        engine_state <= eng_rd_sa;
                     end if;

                  when eng_rd_sa =>
                     sdcard_xfer_addr <= conv_integer(payload_pos(8 downto 1));
                     engine_state <= eng_rd_w1;

                  when eng_rd_w1 =>                                    -- xfer_out latency
                     engine_state <= eng_rd_w2;

                  when eng_rd_w2 =>
                     bus_master_addr <= cma_work(17 downto 1) & '0';
                     bus_master_dato <= sdcard_xfer_out;
                     bus_master_control_dati <= '0';
                     bus_master_control_dato <= '1';
                     engine_state <= eng_rd_w3;

                  when eng_rd_w3 =>
                     bus_master_control_dato <= '0';
                     if bus_master_nxm = '1' then
                        res_nxm <= '1';
                        npr <= '0';
                        res_cma <= cma_work(15 downto 0);
                        res_ema <= cma_work(17 downto 16);
                        engine_state <= eng_rd_fin;
                     else
                        cma_work <= cma_work + 2;
                        words_left <= words_left - 1;
                        nxt_idx := payload_pos(8 downto 1);
                        payload_pos <= payload_pos + 2;
                        if words_left = x"0001" then
                           npr <= '0';
                           engine_state <= eng_rd_fin;
                        elsif nxt_idx = x"ff" then                     -- next word is in the following block
                           npr <= '0';
                           engine_state <= eng_rd_blk;
                        else
                           engine_state <= eng_rd_sa;                  -- payload_pos advances this edge
                        end if;
                     end if;

                  when eng_rd_fin =>
                     npr <= '0';
                     bus_master_control_dato <= '0';
                     -- MTBRC counts up by the bytes actually transferred; MTCMA is the
                     -- byte address after the transfer.  cma_work advanced 2 per word, so
                     -- for an odd xfer it is 1 past true - accepted (see header note).
                     res_brc <= lat_brc + xfer_bytes(15 downto 0);
                     if res_nxm = '0' then
                        res_cma <= cma_work(15 downto 0);
                        res_ema <= cma_work(17 downto 16);
                     end if;
                     tape_pos <= tape_pos + reclen_pad + 8;
                     engine_state <= eng_finish;

-- --- space forward ---------------------------------------------------------

                  when eng_sf_init =>
                     sp_count <= lat_brc;
                     hd_pos <= tape_pos;
                     hd_widx <= '0';
                     rd_ret <= eng_sf_eval;
                     engine_state <= eng_hd_blk;

                  when eng_sf_eval =>
                     if reclen = x"00000000" then
                        tape_pos <= tape_pos + 4;
                        res_eof <= '1';
                        res_brc <= sp_count + 1;                      -- the tape mark counts, as SIMH
                        engine_state <= eng_finish;
                     elsif reclen(31) = '1' then                      -- EOM: bad tape, as SIMH
                        res_bad <= '1';
                        res_brc <= sp_count + 1;
                        engine_state <= eng_finish;
                     else
                        tape_pos <= tape_pos + reclen_pad + 8;
                        sp_count <= sp_count + 1;
                        res_brc <= sp_count + 1;
                        if (sp_count + 1) = x"0000" then
                           engine_state <= eng_finish;
                        else
                           hd_pos <= tape_pos + reclen_pad + 8;
                           hd_widx <= '0';
                           rd_ret <= eng_sf_eval;
                           engine_state <= eng_hd_blk;
                        end if;
                     end if;

-- --- space reverse -------------------------------------------------------
-- reads the trailing length word that sits 4 bytes before tape_pos, then steps
-- back over  [len4][payload padded][len4].

                  when eng_sr_init =>
                     sp_count <= lat_brc;
                     engine_state <= eng_sr_chk;

                  when eng_sr_chk =>
                     if tape_pos = x"00000000" then
                        res_bot <= '1';
                        res_rib <= '1';
                        res_brc <= sp_count + 1;                      -- the attempt counts, as SIMH
                        engine_state <= eng_finish;
                     else
                        hd_pos <= tape_pos - 4;
                        hd_widx <= '0';
                        rd_ret <= eng_sr_eval;
                        engine_state <= eng_hd_blk;
                     end if;

                  when eng_sr_eval =>
                     if reclen = x"00000000" then
                        tape_pos <= tape_pos - 4;
                        res_eof <= '1';
                        res_brc <= sp_count + 1;
                        engine_state <= eng_finish;
                     elsif (reclen_pad + 8) > tape_pos then
                        tape_pos <= (others => '0');
                        res_bot <= '1';
                        res_rib <= '1';
                        res_brc <= sp_count + 1;
                        engine_state <= eng_finish;
                     else
                        tape_pos <= tape_pos - (reclen_pad + 8);
                        sp_count <= sp_count + 1;
                        res_brc <= sp_count + 1;
                        if (sp_count + 1) = x"0000" then
                           if (tape_pos - (reclen_pad + 8)) = x"00000000" then
                              res_bot <= '1';
                           end if;
                           engine_state <= eng_finish;
                        else
                           engine_state <= eng_sr_chk;
                        end if;
                     end if;

-- --- rewind / unload / illegal -------------------------------------------

                  when eng_rew =>
                     tape_pos <= (others => '0');
                     buf_valid <= '0';
                     res_bot <= '1';
                     res_brc <= lat_brc;
                     engine_state <= eng_finish;

                  when eng_illegal =>
                     res_ill <= '1';
                     res_brc <= lat_brc;
                     res_cma <= lat_cma;
                     res_ema <= lat_ema;
                     engine_state <= eng_finish;

-- --- dma word read / write (TS11 command, characteristics and message packets) --
-- lat_dma_cnt words at lat_dma_addr, read into dmarb or written from dmawb; a
-- non-existent address stops the transfer with res_nxm.

                  when eng_dr_acq =>
                     npr <= '1';
                     engine_state <= eng_dr_gnt;

                  when eng_dr_gnt =>
                     if npg = '1' then
                        engine_state <= eng_dr_a;
                     end if;

                  when eng_dr_a =>
                     if dma_idx = lat_dma_cnt then
                        npr <= '0';
                        engine_state <= eng_finish;
                     else
                        bus_master_addr <= dma_work(17 downto 1) & '0';
                        bus_master_control_dato <= '0';
                        bus_master_control_dati <= '1';
                        engine_state <= eng_dr_b;
                     end if;

                  when eng_dr_b =>                                     -- the word is on bus_master_dati now
                     bus_master_control_dati <= '0';
                     if bus_master_nxm = '1' then
                        res_nxm <= '1';
                        npr <= '0';
                        engine_state <= eng_finish;
                     else
                        dmarb(dma_idx) <= bus_master_dati;
                        dma_idx <= dma_idx + 1;
                        dma_work <= dma_work + 2;
                        engine_state <= eng_dr_a;
                     end if;

                  when eng_dw_acq =>
                     npr <= '1';
                     engine_state <= eng_dw_gnt;

                  when eng_dw_gnt =>
                     if npg = '1' then
                        engine_state <= eng_dw_a;
                     end if;

                  when eng_dw_a =>
                     if dma_idx = lat_dma_cnt then
                        npr <= '0';
                        engine_state <= eng_finish;
                     else
                        bus_master_addr <= dma_work(17 downto 1) & '0';
                        bus_master_dato <= dmawb(dma_idx);
                        bus_master_control_dati <= '0';
                        bus_master_control_dato <= '1';
                        engine_state <= eng_dw_b;
                     end if;

                  when eng_dw_b =>
                     bus_master_control_dato <= '0';
                     if bus_master_nxm = '1' then
                        res_nxm <= '1';
                        npr <= '0';
                        engine_state <= eng_finish;
                     else
                        dma_idx <= dma_idx + 1;
                        dma_work <= dma_work + 2;
                        engine_state <= eng_dw_a;
                     end if;

-- --- completion handshake ----------------------------------------------

                  when eng_finish =>
                     npr <= '0';
                     if tape_pos = x"00000000" then
                        res_bot <= '1';
                     end if;
                     cmd_done <= '1';
                     if cmd_req = '0' then
                        cmd_done <= '0';
                        engine_state <= eng_idle;
                     end if;

                  when others =>
                     engine_state <= eng_idle;

               end case;

-- media (un)mount : abort to idle and re-home the byte cursor to BOT

               if mc_e(2) /= mc_e(1) then
                  tape_pos <= (others => '0');
                  buf_valid <= '0';
                  npr <= '0';
                  bus_master_control_dato <= '0';
                  bus_master_control_dati <= '0';
                  cmd_done <= '0';
                  engine_state <= eng_idle;
               end if;

            end if;
         end if;
      end if;
   end process;

end implementation;
