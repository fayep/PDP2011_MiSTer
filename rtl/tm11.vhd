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
--    L(31) == 1        -> end of medium / erase gap / error marker -> treated as EOT
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

      sdcard_cs : out std_logic;
      sdcard_mosi : out std_logic;
      sdcard_sclk : out std_logic;
      sdcard_miso : in std_logic;
      sdcard_debug : out std_logic_vector(3 downto 0);

      have_tm : in integer range 0 to 1;
      media_change : in std_logic := '0';                       -- toggles when a .tap is (un)mounted -> re-home to BOT
      reset : in std_logic;
      clk50mhz : in std_logic;
      nclk : in std_logic;
      clk : in std_logic
   );
end tm11;

architecture implementation of tm11 is

component sdspi is
   port(
      sdcard_cs : out std_logic;
      sdcard_mosi : out std_logic;
      sdcard_sclk : out std_logic;
      sdcard_miso : in std_logic := '0';
      sdcard_debug : out std_logic_vector(3 downto 0);

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
      clk50mhz : in std_logic
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
signal res_bot : std_logic;
signal res_rle : std_logic;
signal res_nxm : std_logic;
signal res_ill : std_logic;

-- sdspi interface
signal sd_addr : std_logic_vector(23 downto 0);
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

begin

   sd1: sdspi port map(
      sdcard_cs => sdcard_cs,
      sdcard_mosi => sdcard_mosi,
      sdcard_sclk => sdcard_sclk,
      sdcard_miso => sdcard_miso,
      sdcard_debug => sdcard_debug,

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
      clk50mhz => clk50mhz
   );

-- regular bus interface

   base_addr_match <= '1' when base_addr(17 downto 4) = bus_addr(17 downto 4) and have_tm = 1 else '0';
   bus_addr_match <= base_addr_match;

-- register assembly

   mtc_err <= mts_ill or mts_crc or mts_par or mts_dlt or mts_eot or mts_rle or mts_bad or mts_nxm;
   mtc <= mtc_err & mtc_den & '0' & mtc_lpar & mtc_unit & mtc_rdy & mtc_ie & mtc_ema & mtc_fnc & mtc_go;
   mts <= mts_ill & mts_eof & mts_crc & mts_par & mts_dlt & mts_eot & mts_rle & mts_bad
        & mts_nxm & mts_onl & mts_bot & mts_7tk & mts_sdn & mts_wlk & mts_rew & mts_tur;

   sd_addr <= '0' & need_pos(31 downto 9);
   reclen_pad <= reclen when reclen(0) = '0' else reclen + 1;


-- regular bus interface : registers, command dispatch, interrupts

   process(nclk, reset)
      variable w : std_logic_vector(15 downto 0);
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
            end if;

         else

            if have_tm = 1 then

-- interrupt state machine (identical to rl11)

               case interrupt_state is
                  when i_idle =>
                     br <= '0';
                     if mtc_ie = '1' and mtc_rdy = '1' then
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
                     end if;

                  when others =>
                     interrupt_state <= i_idle;
               end case;

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
                        res_eof <= '0'; res_eot <= '0'; res_bot <= '0';
                        res_rle <= '0'; res_nxm <= '0'; res_ill <= '0';

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
                        res_eot <= '1';
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
                        engine_state <= eng_finish;
                     elsif reclen(31) = '1' then
                        res_eot <= '1';
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
                        engine_state <= eng_finish;
                     elsif (reclen_pad + 8) > tape_pos then
                        tape_pos <= (others => '0');
                        res_bot <= '1';
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
