
--
-- mister_blkdev: a disk controller's block device, served by MiSTer's
-- hps_io sd_* protocol directly.
--
-- Drop-in for sdspi.vhd on the controller side: the same block address,
-- the same four-phase start/done/ack handshakes and the same 256-word
-- read (rsector) and write (wsector) buffers behind sdcard_xfer_*, with
-- the same meaning -- so a controller switches over by changing only its
-- port map. On the other side, instead of bit-banging an SPI SD card for
-- sys/sd_card.sv to decode, it talks to one hps_io disk slot: sd_lba,
-- sd_rd/sd_wr until sd_ack, then the HPS fills rsector (sd_buff_wr) or
-- drains wsector (sd_buff_addr -> sd_buff_din) while sd_ack is high.
--
-- Clocks: the controller side runs on controller_clk (cpuclk), the HPS
-- side on clk_sys (hps_io's clock, clk_100mhz). The buffers are
-- dual-clock RAMs, each written by one side and read by the other, and
-- only ever touched by one side at a time -- the handshake guarantees it.
-- The handshake lines cross through two-flop synchronisers in each
-- direction. sdcard_addr is sampled on clk_sys once a synchronised start
-- is seen; the controller holds it stable for the whole operation.
--
-- Blocks are 512 bytes (hps_io BLKSZ 2, WIDE 1: 256 16-bit words).
--

library ieee;
use ieee.std_logic_1164.all;
use ieee.std_logic_arith.all;
use ieee.std_logic_unsigned.all;

entity mister_blkdev is
   port(
-- controller side (controller_clk), as sdspi.vhd
      sdcard_addr : in std_logic_vector(23 downto 0);           -- block number

      sdcard_idle : out std_logic;
      sdcard_read_start : in std_logic;
      sdcard_read_ack : in std_logic;
      sdcard_read_done : out std_logic;
      sdcard_write_start : in std_logic;
      sdcard_write_ack : in std_logic;
      sdcard_write_done : out std_logic;
      sdcard_error : out std_logic;                              -- hps_io has no error path: always '0'

      sdcard_xfer_addr : in integer range 0 to 255;
      sdcard_xfer_read : in std_logic;
      sdcard_xfer_out : out std_logic_vector(15 downto 0);       -- rsector(sdcard_xfer_addr), one clock later
      sdcard_xfer_write : in std_logic;
      sdcard_xfer_in : in std_logic_vector(15 downto 0);         -- -> wsector(sdcard_xfer_addr)

      enable : in integer range 0 to 1 := 0;
      controller_clk : in std_logic;
      reset : in std_logic;

-- hps_io side (clk_sys): one disk slot
      sd_lba : out std_logic_vector(31 downto 0);
      sd_rd : out std_logic;
      sd_wr : out std_logic;
      sd_ack : in std_logic;
      sd_buff_addr : in std_logic_vector(7 downto 0);            -- word address within the block
      sd_buff_dout : in std_logic_vector(15 downto 0);
      sd_buff_din : out std_logic_vector(15 downto 0);
      sd_buff_wr : in std_logic;
      clk_sys : in std_logic
   );
end mister_blkdev;

architecture implementation of mister_blkdev is

type buffer_type is array(0 to 255) of std_logic_vector(15 downto 0);
signal rsector : buffer_type;                                    -- written by hps_io, read by the controller
signal wsector : buffer_type;                                    -- written by the controller, read by hps_io

-- controller_clk -> clk_sys
signal read_start_m, read_start_s : std_logic := '0';
signal read_ack_m, read_ack_s : std_logic := '0';
signal write_start_m, write_start_s : std_logic := '0';
signal write_ack_m, write_ack_s : std_logic := '0';
signal reset_m, reset_s : std_logic := '1';

-- clk_sys -> controller_clk
signal idle : std_logic := '0';
signal read_done : std_logic := '0';
signal write_done : std_logic := '0';
signal idle_m, idle_s : std_logic := '0';
signal read_done_m, read_done_s : std_logic := '0';
signal write_done_m, write_done_s : std_logic := '0';

type hps_state_t is (
   hps_quiesce,                                                  -- after reset: let any HPS transfer in flight finish
   hps_idle,
   hps_read_req,                                                 -- sd_rd held until sd_ack
   hps_read_xfer,                                                -- HPS fills rsector while sd_ack
   hps_write_req,                                                -- sd_wr held until sd_ack
   hps_write_xfer                                                -- HPS drains wsector while sd_ack
);
signal hps_state : hps_state_t := hps_quiesce;

signal rd_r, wr_r : std_logic := '0';                           -- sd_rd/sd_wr, defined from power-up
signal lba_r : std_logic_vector(31 downto 0) := (others => '0');

begin

   sdcard_error <= '0';
   sd_rd <= rd_r;
   sd_wr <= wr_r;
   sd_lba <= lba_r;

-- controller side

   process(controller_clk)
   begin
      if controller_clk = '1' and controller_clk'event then
         if enable = 1 then
            sdcard_xfer_out <= rsector(sdcard_xfer_addr);
            if sdcard_xfer_write = '1' then
               wsector(sdcard_xfer_addr) <= sdcard_xfer_in;
            end if;

            idle_m <= idle;             idle_s <= idle_m;
            read_done_m <= read_done;   read_done_s <= read_done_m;
            write_done_m <= write_done; write_done_s <= write_done_m;

            if reset = '1' then
               sdcard_idle <= '0';
               sdcard_read_done <= '0';
               sdcard_write_done <= '0';
            else
               sdcard_idle <= idle_s;
               sdcard_read_done <= read_done_s;
               sdcard_write_done <= write_done_s;
            end if;
         end if;
      end if;
   end process;

-- hps_io side

   process(clk_sys)
   begin
      if clk_sys = '1' and clk_sys'event then
         if sd_ack = '1' and sd_buff_wr = '1' and hps_state = hps_read_xfer then
            rsector(conv_integer(sd_buff_addr)) <= sd_buff_dout;
         end if;
         sd_buff_din <= wsector(conv_integer(sd_buff_addr));    -- registered, like sd_card.sv's buffer RAM

         read_start_m <= sdcard_read_start;    read_start_s <= read_start_m;
         read_ack_m <= sdcard_read_ack;        read_ack_s <= read_ack_m;
         write_start_m <= sdcard_write_start;  write_start_s <= write_start_m;
         write_ack_m <= sdcard_write_ack;      write_ack_s <= write_ack_m;
         reset_m <= reset;                     reset_s <= reset_m;

         if reset_s = '1' or enable = 0 then
            idle <= '0';
            read_done <= '0';
            write_done <= '0';
            rd_r <= '0';
            wr_r <= '0';
            hps_state <= hps_quiesce;
         else
            case hps_state is

               when hps_quiesce =>
                  if sd_ack = '0' then
                     hps_state <= hps_idle;
                  end if;

               when hps_idle =>                                  -- as sdspi's sd_idle
                  idle <= '1';
                  if read_ack_s = '1' then
                     read_done <= '0';
                  end if;
                  if write_ack_s = '1' then
                     write_done <= '0';
                  end if;
                  if read_done = '0' and write_done = '0' and read_ack_s = '0' and write_ack_s = '0' then
                     if read_start_s = '1' then
                        idle <= '0';
                        lba_r <= x"00" & sdcard_addr;
                        rd_r <= '1';
                        hps_state <= hps_read_req;
                     elsif write_start_s = '1' then
                        idle <= '0';
                        lba_r <= x"00" & sdcard_addr;
                        wr_r <= '1';
                        hps_state <= hps_write_req;
                     end if;
                  end if;

               when hps_read_req =>
                  if sd_ack = '1' then
                     rd_r <= '0';
                     hps_state <= hps_read_xfer;
                  end if;

               when hps_read_xfer =>
                  if sd_ack = '0' then
                     read_done <= '1';
                     hps_state <= hps_idle;
                  end if;

               when hps_write_req =>
                  if sd_ack = '1' then
                     wr_r <= '0';
                     hps_state <= hps_write_xfer;
                  end if;

               when hps_write_xfer =>
                  if sd_ack = '0' then
                     write_done <= '1';
                     hps_state <= hps_idle;
                  end if;

            end case;
         end if;
      end if;
   end process;

end implementation;
