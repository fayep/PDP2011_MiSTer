--
-- Copyright (c) 2008-2026 Sytse van Slooten
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

-- sd_bridge.vhd -- shared sd_* <-> busmaster bridge, extracted 2026-09-13
-- from rh11.vhd's Phase 1 rewrite (rk11.vhd's own copy was byte-for-byte
-- identical modulo comment wording -- confirmed via diff before
-- extracting, not assumed).
--
-- Bridges hps_io's native block-transfer protocol (sd_lba/sd_rd/sd_wr/
-- sd_ack/sd_buff_*, clk_100mhz domain) to a controller's own DMA/
-- busmaster logic (cpuclk domain: sdcard_idle/read_start/read_ack/
-- read_done/write_start/write_ack/write_done/xfer_addr/xfer_read/
-- xfer_write/xfer_in/xfer_out). A Gray-coded 2-bit request/done toggle
-- pair per direction crosses the two domains; a 256x16 dual-clock
-- sector buffer (rsector for reads, wsector for writes) carries the
-- actual data.
--
-- Direct, unconditional read/write only -- no read-modify-write, no
-- partial-sector merge. rl11.vhd's own bridge genuinely needs both (its
-- 128-word real sectors get packed two-per-512-byte SD block, and a
-- short write must preread the sibling half before committing), so it
-- keeps its own copy of this pattern rather than sharing this entity --
-- forcing that complexity in here would cost rh11/rk11 either
-- correctness risk or an unwanted extra SD read on every write for no
-- benefit. See rl11.vhd's own bridge section for that version.

library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.STD_LOGIC_ARITH.ALL;
use IEEE.STD_LOGIC_UNSIGNED.ALL;

entity sd_bridge is
   port(
      clk : in std_logic;                                  -- controller/cpuclk domain
      clk_100mhz : in std_logic;                            -- hps_io domain
      reset : in std_logic;

      -- hps_io native block-transfer protocol
      sd_lba : out std_logic_vector(31 downto 0);
      sd_rd : out std_logic;
      sd_wr : out std_logic;
      sd_ack : in std_logic;
      sd_buff_addr : in std_logic_vector(8 downto 0);
      sd_buff_dout : in std_logic_vector(15 downto 0);
      sd_buff_din : out std_logic_vector(15 downto 0);
      sd_buff_wr : in std_logic;

      -- controller-side contract (matches what each controller's own
      -- busmaster/register-file logic already expects, unchanged)
      sd_addr : in std_logic_vector(23 downto 0);           -- block address, cpuclk domain,
                                                              -- stable for the whole transfer
      sdcard_idle : out std_logic;
      sdcard_read_start : in std_logic;
      sdcard_read_ack : in std_logic;
      sdcard_read_done : out std_logic;
      sdcard_write_start : in std_logic;
      sdcard_write_ack : in std_logic;
      sdcard_write_done : out std_logic;

      sdcard_xfer_addr : in integer range 0 to 255;
      sdcard_xfer_out : out std_logic_vector(15 downto 0);
      sdcard_xfer_write : in std_logic;
      sdcard_xfer_in : in std_logic_vector(15 downto 0)
   );
end sd_bridge;

architecture implementation of sd_bridge is

type sector_buf_t is array(0 to 255) of std_logic_vector(15 downto 0);
signal rsector : sector_buf_t;
signal wsector : sector_buf_t;

signal read_req_gray   : std_logic_vector(1 downto 0) := "00";  -- cpuclk domain
signal read_req_gray_r1, read_req_gray_r2 : std_logic_vector(1 downto 0) := "00"; -- synced into clk_100mhz
signal read_done_gray  : std_logic_vector(1 downto 0) := "00";  -- clk_100mhz domain
signal read_done_gray_r1, read_done_gray_r2 : std_logic_vector(1 downto 0) := "00"; -- synced into cpuclk

signal write_req_gray  : std_logic_vector(1 downto 0) := "00";  -- cpuclk domain
signal write_req_gray_r1, write_req_gray_r2 : std_logic_vector(1 downto 0) := "00"; -- synced into clk_100mhz
signal write_done_gray : std_logic_vector(1 downto 0) := "00";  -- clk_100mhz domain
signal write_done_gray_r1, write_done_gray_r2 : std_logic_vector(1 downto 0) := "00"; -- synced into cpuclk

signal sd_lba_r : std_logic_vector(31 downto 0);  -- latched into clk_100mhz domain
                                                   -- for the whole transfer by construction
                                                   -- (sd_addr doesn't change until the
                                                   -- read/write round-trip completes)

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

begin

-- cpuclk-domain half: drives sdcard_idle/read_done/write_done, consumes
-- sdcard_read_start/read_ack/write_start/write_ack -- i.e. everything the
-- controller's own busmaster process already knows how to drive/observe.
-- Kicks off a transfer by toggling the Gray request code; waits for the
-- synchronized Gray done code to change before declaring done.

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
-- rise-then-fall sequence (block transfer happens while ack is high),
-- then toggles the Gray done code back.

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
-- what the controller's own busmaster process expects from
-- sdcard_xfer_out/in/write/addr.

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

end implementation;
