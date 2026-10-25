//
// Copyright (c) 2008-2021 Sytse van Slooten
//
// Permission is hereby granted to any person obtaining a copy of these VHDL source files and
// other language source files and associated documentation files ("the materials") to use
// these materials solely for personal, non-commercial purposes.
// You are also granted permission to make changes to the materials, on the condition that this
// copyright notice is retained unchanged.
//
// The materials are distributed in the hope that they will be useful, but WITHOUT ANY WARRANTY;
// without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//
// MiSTer port by Ramón Martínez <rampa@encomix.org>
// 
// $Revision$
`default_nettype none
module emu
(
	//Master input clock
	input         CLK_50M,

	//Async reset from top-level module.
	//Can be used as initial reset.
	input         RESET,

	//Must be passed to hps_io module
	inout  [48:0] HPS_BUS,

	//Base video clock. Usually equals to CLK_SYS.
	output        CLK_VIDEO,

	//Multiple resolutions are supported using different CE_PIXEL rates.
	//Must be based on CLK_VIDEO
	output        CE_PIXEL,

	//Video aspect ratio for HDMI. Most retro systems have ratio 4:3.
	//if VIDEO_ARX[12] or VIDEO_ARY[12] is set then [11:0] contains scaled size instead of aspect ratio.
	output [12:0] VIDEO_ARX,
	output [12:0] VIDEO_ARY,

	output  [7:0] VGA_R,
	output  [7:0] VGA_G,
	output  [7:0] VGA_B,
	output        VGA_HS,
	output        VGA_VS,
	output        VGA_DE,    // = ~(VBlank | HBlank)
	output        VGA_F1,
	output [1:0]  VGA_SL,
	output        VGA_SCALER, // Force VGA scaler
	output        VGA_DISABLE, // analog out is off

	input  [11:0] HDMI_WIDTH,
	input  [11:0] HDMI_HEIGHT,
	output        HDMI_FREEZE,

`ifdef MISTER_FB
	// Use framebuffer in DDRAM
	// FB_FORMAT:
	//    [2:0] : 011=8bpp(palette) 100=16bpp 101=24bpp 110=32bpp
	//    [3]   : 0=16bits 565 1=16bits 1555
	//    [4]   : 0=RGB  1=BGR (for 16/24/32 modes)
	//
	// FB_STRIDE either 0 (rounded to 256 bytes) or multiple of pixel size (in bytes)
	output        FB_EN,
	output  [4:0] FB_FORMAT,
	output [11:0] FB_WIDTH,
	output [11:0] FB_HEIGHT,
	output [31:0] FB_BASE,
	output [13:0] FB_STRIDE,
	input         FB_VBL,
	input         FB_LL,
	output        FB_FORCE_BLANK,

`ifdef MISTER_FB_PALETTE
	// Palette control for 8bit modes.
	// Ignored for other video modes.
	output        FB_PAL_CLK,
	output  [7:0] FB_PAL_ADDR,
	output [23:0] FB_PAL_DOUT,
	input  [23:0] FB_PAL_DIN,
	output        FB_PAL_WR,
`endif
`endif

	output        LED_USER,  // 1 - ON, 0 - OFF.

	// b[1]: 0 - LED status is system status OR'd with b[0]
	//       1 - LED status is controled solely by b[0]
	// hint: supply 2'b00 to let the system control the LED.
	output  [1:0] LED_POWER,
	output  [1:0] LED_DISK,

	// I/O board button press simulation (active high)
	// b[1]: user button
	// b[0]: osd button
	output  [1:0] BUTTONS,

	input         CLK_AUDIO, // 24.576 MHz
	output [15:0] AUDIO_L,
	output [15:0] AUDIO_R,
	output        AUDIO_S,   // 1 - signed audio samples, 0 - unsigned
	output  [1:0] AUDIO_MIX, // 0 - no mix, 1 - 25%, 2 - 50%, 3 - 100% (mono)

	//ADC
	inout   [3:0] ADC_BUS,

	//SD-SPI
	output        SD_SCK,
	output        SD_MOSI,
	input         SD_MISO,
	output        SD_CS,
	input         SD_CD,

	//High latency DDR3 RAM interface
	//Use for non-critical time purposes
	output        DDRAM_CLK,
	input         DDRAM_BUSY,
	output  [7:0] DDRAM_BURSTCNT,
	output [28:0] DDRAM_ADDR,
	input  [63:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [63:0] DDRAM_DIN,
	output  [7:0] DDRAM_BE,
	output        DDRAM_WE,

	//SDRAM interface with lower latency
	output        SDRAM_CLK,
	output        SDRAM_CKE,
	output [12:0] SDRAM_A,
	output  [1:0] SDRAM_BA,
	inout  [15:0] SDRAM_DQ,
	output        SDRAM_DQML,
	output        SDRAM_DQMH,
	output        SDRAM_nCS,
	output        SDRAM_nCAS,
	output        SDRAM_nRAS,
	output        SDRAM_nWE,

`ifdef MISTER_DUAL_SDRAM
	//Secondary SDRAM
	//Set all output SDRAM_* wires to Z ASAP if SDRAM2_EN is 0
	input         SDRAM2_EN,
	output        SDRAM2_CLK,
	output [12:0] SDRAM2_A,
	output  [1:0] SDRAM2_BA,
	inout  [15:0] SDRAM2_DQ,
	output        SDRAM2_nCS,
	output        SDRAM2_nCAS,
	output        SDRAM2_nRAS,
	output        SDRAM2_nWE,
`endif

	input         UART_CTS,
	output        UART_RTS,
	input         UART_RXD,
	output        UART_TXD,
	output        UART_DTR,
	input         UART_DSR,

	// Open-drain User port.
	// 0 - D+/RX
	// 1 - D-/TX
	// 2..6 - USR2..USR6
	// Set USER_OUT to 1 to read from USER_IN.
	input   [6:0] USER_IN,
	output  [6:0] USER_OUT,

	input         OSD_STATUS
);


///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
assign AUDIO_MIX = 0;

assign BUTTONS = 0;

assign USER_OUT[1] = 1'b1; //7'b11ZZZ1Z;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v" 
localparam CONF_STR = {
	"PDP2011;UART19200;",
	"-;",
	"S0,DSKIMG,Mount RK disk;",
	"S1,DSKIMG,Mount RL disk;",
	"S2,DSKIMG,Mount RM/RP (RH) disk;",
	"S3,TAP,Mount TM11 tape;",
	"-;",
	"O[7:5],PDP-11 Model,20,34,44,45,70,94;",
	"-;",
	"O[1],External Ethernet,No,Yes;",
	"O[27:25],Host network,Off,eth0,eth1,macvlan,tap0;",
	"O[2],Console,Virtual VT100,Serial 19200 baud;",
	"H0O[17],Line 1 (176500),Serial port,TU58 DECtape II;",
	"O[18],Line clock,60 Hz,50 Hz;",
	"O[28],Tape controller,TM11 (MT),TS11 (MS);",
	"O[24:22],Boot device,Auto,TM11 tape,RK11,RL11,RH70 (RP/RM);",
	"O[16],Video,Terminal,Front panel;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"P1,Virtual VT100;",
	"P1-;",
	"P1O[9:8],Color,Green,Blue,White,Amber;",
	"P1O[10],Terminal type,VT100,VT105;",
	"P1O[11],Cursor type,Underline,Block;",
	"P1O[12],Cursor blink,Off,On;",
   "P1-;",
	"P1O[13],VT screen saver,Off,On;",
	"P1O[14],VT test E,Off,On;",
	"P1O[15],VT test F,Off,On;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"V,v",`BUILD_DATE 
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire         ps2k_c;
wire         ps2k_d;
wire         vt_ps2c, vt_ps2d;     // the VT's PS/2 stream, cut while the front panel has the keyboard
wire  [40:0] panel_sw;             // on-screen panel knobs & switches from the keyboard (paneldriver type 4)
wire  [21:0] pv_sw;                // the same switches as panel_view draws them (1 = up)
wire   [6:0] pv_ctl;
wire   [2:0] pv_knob_a;            // ADDRESS knob position
wire   [1:0] pv_knob_d;            // DATA knob position
wire [21:0] gamma_bus;


wire [31:0] sd_lba[4];
wire  [3:0] sd_rd;
wire  [3:0] sd_wr;
wire  [3:0] sd_ack;
wire [7:0]sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din[4];
wire        sd_buff_wr;
wire  [3:0] img_mounted;
wire  [3:0] img_readonly;
wire  [63:0]img_size;

wire  [7:0] uart_mode;



hps_io #(.CONF_STR(CONF_STR),.WIDE(1),.VDNUM(4),.PS2DIV(3125)) hps_io
(
   
	.clk_sys(clk_100mhz),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
   .gamma_bus(gamma_bus),
	.buttons(buttons),
	.status(status),
	.status_menumask({15'd0, status[2]}),   // H0: line 1 is on the UART only with the VT console
	
	.sd_lba(sd_lba),
   .sd_rd(sd_rd),
   .sd_wr(sd_wr),
   .sd_ack(sd_ack),
   .sd_buff_addr(sd_buff_addr),
   .sd_buff_dout(sd_buff_dout),
   .sd_buff_din(sd_buff_din),
   .sd_buff_wr(sd_buff_wr),
   .img_mounted(img_mounted),
   .img_readonly(img_readonly),
   .img_size(img_size),
	
	.uart_mode(uart_mode),
	
	.ps2_key(ps2_key),
	.ps2_kbd_clk_out(ps2k_c),
	.ps2_kbd_data_out(ps2k_d)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire cpuclk;
wire clk_100mhz,clk_50mhz,clk_ram,pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_100mhz),
	.outclk_1(clk_ram),
	.outclk_2(clk_50mhz),
	.locked(pll_locked)
);


// Power-on reset: the whole core stays in reset until the PLL has been
// locked for 65536 clk_100mhz cycles (~655 us), so nothing depends on
// register power-up values or on clocks that were not yet stable. pll_locked
// is asynchronous; it is synchronised before use.
reg  [1:0] lock_s  = 2'b00;
reg [15:0] por_cnt = 16'd0;
always @(posedge clk_100mhz) begin
	lock_s <= {lock_s[0], pll_locked};
	if (!lock_s[1]) por_cnt <= 16'd0;
	else if (~&por_cnt) por_cnt <= por_cnt + 1'd1;
end
wire por = ~&por_cnt;

wire reset = RESET | status[0] | buttons[1] | por;
// One register stage before mister_top: the combinational path por_cnt ->
// reset -> the DRAM state machine's I/O-cell registers had little margin
// (0.47 ns in 32fd0e7) and failed once more logic shared the area.
reg  reset_q = 1'b1;
always @(posedge clk_100mhz) reset_q <= reset;

///////////////////////// DISKS /////////////////////////////////////////

wire sdcard_sclk;
wire sdcard_mosi;
wire sdcard_cs;
wire vsdmiso;


reg vsd_sel_rk = 0;
reg vsd_sel_rl = 0;
reg vsd_sel_rh = 0;
reg vsd_sel_tm = 0;
reg rl_is_rl01 = 0;
reg tape_mount_tgl = 0;

always @(posedge clk_100mhz) begin
	if(img_mounted[0]) vsd_sel_rk <= |img_size;
	if(img_mounted[1]) vsd_sel_rl <= |img_size;
	if(img_mounted[1]) rl_is_rl01 <= |img_size && img_size <= 64'd5242880;   // RL01 size: as MiSTer_pdp2011's diskcompat
	if(img_mounted[2]) vsd_sel_rh <= |img_size;
	if(img_mounted[3]) vsd_sel_tm <= |img_size;
	if(img_mounted[3]) tape_mount_tgl <= ~tape_mount_tgl;
	if(RESET) begin
   	vsd_sel_rk <= 0;
		vsd_sel_rl <= 0;
		vsd_sel_rh <= 0;
		vsd_sel_tm <= 0;
	end
end

// RK: rk11 talks to hps_io slot 0 directly through rtl/mister_blkdev.vhd.
wire rk_sd_rd, rk_sd_wr;
assign sd_rd[0] = rk_sd_rd & vsd_sel_rk;
assign sd_wr[0] = rk_sd_wr & vsd_sel_rk;

// RL: rl11 talks to hps_io slot 1 directly through rtl/mister_blkdev.vhd
// (no SPI SD-card emulation). Requests only while an image is mounted.
wire rl_sd_rd, rl_sd_wr;
assign sd_rd[1] = rl_sd_rd & vsd_sel_rl;
assign sd_wr[1] = rl_sd_wr & vsd_sel_rl;

// RH: rh11 talks to hps_io slot 2 directly through rtl/mister_blkdev.vhd.
wire rh_sd_rd, rh_sd_wr;
assign sd_rd[2] = rh_sd_rd & vsd_sel_rh;
assign sd_wr[2] = rh_sd_wr & vsd_sel_rh;

// TM11: tm11 talks to hps_io slot 3 directly through rtl/mister_blkdev.vhd.
wire tm_sd_rd, tm_sd_wr;
assign sd_rd[3] = tm_sd_rd & vsd_sel_tm;
assign sd_wr[3] = tm_sd_wr & vsd_sel_tm;

int have_rk;
int have_rl;
int have_rh;
int have_tm;
int tm_img_mounted;
int rk_img_mounted;
int rl_img_mounted;
int rl_rl01;
int rh_img_mounted;
int boot_sel;

// Controllers are always present on the bus, as real cards are; only the
// drive behind each one goes online/offline with its image (img_mounted).
assign have_rk = 1;
assign have_rl = 1;
assign have_rh = 1;
assign have_tm = 1;  // controller presence is a build-time choice, not tied to
                      // mount state -- see tm11's img_mounted for "no tape"
assign tm_img_mounted = vsd_sel_tm ? 1 : 0;
assign rk_img_mounted = vsd_sel_rk ? 1 : 0;
assign boot_sel = status[24:22];   // 0 auto, 1 mt, 2 rk, 3 rl, 4 rh (5-7 = auto); 19-21 avoided: old configs have bit 21 set
assign rl_img_mounted = vsd_sel_rl ? 1 : 0;
assign rl_rl01 = rl_is_rl01 ? 1 : 0;
assign rh_img_mounted = vsd_sel_rh ? 1 : 0;

//
wire [3:0]rk_sddebug = 4'd0;   // RK: no SPI activity bits since mister_blkdev
//
wire [3:0]rh_sddebug = 4'd0;   // RH: no SPI activity bits since mister_blkdev
//
wire [3:0]rl_sddebug = 4'd0;   // RL: no SPI activity bits since mister_blkdev
//
wire [3:0]tm_sddebug = 4'd0;   // TM: no SPI activity bits since mister_blkdev
//
//

// (The original "real SD" pass-through of RH's SPI to the SD_* pins was never
// completed -- its MISO path was not connected and status[4:3] unused -- and
// went with RH's SPI interface. The SD_* pins stay tri-stated, as set above.)

/////////////////////////////// LEDS ////////////////////////////////////////
wire greenled;
wire[3:0] sddebug;

assign sddebug     = rk_sddebug | rl_sddebug |rh_sddebug;
assign LED_POWER={1'b1,greenled};
assign LED_DISK=sddebug[0] | sddebug[2];
assign LED_USER=sddebug[1] | sddebug[3];
/////////////////////////////// External Ethernet////////////////////////////
// The XU (DEUNA) runs for the I/O board's ENC424J600 (O[1]) or for host
// networking through Main (O[27:25]); host networking takes precedence.
wire xu_host = status[27:25] != 3'd0;
int have_xu;
assign have_xu = (status[1] | xu_host)? 1 : 0;

wire xu_cs; 
wire xu_mosi;
wire xu_sclk;
wire xu_miso;

assign USER_OUT[0] = xu_mosi;
assign xu_miso = USER_IN[1];
assign USER_OUT[6] = xu_sclk;
assign USER_OUT[3] = xu_cs;

// host networking: frames between the XU's frame port and Main's DDR3 rings
// (rtl/xufp.vhd, rtl/xu_ddr_bridge.vhd, Main support/pdp2011/xu_net.cpp)
wire [99:0] fp_i;
wire [85:0] fp_o;
assign fp_i[99] = xu_host;
assign DDRAM_CLK = clk_100mhz;

xu_ddr_bridge xu_ddr_bridge
(
	.clk(clk_100mhz),
	.reset(reset_q),
	.enable(xu_host),
	.b_tx_addr(fp_i[9:0]),
	.b_tx_q(fp_o[15:0]),
	.b_rx_addr(fp_i[19:10]),
	.b_rx_d(fp_i[35:20]),
	.b_rx_we(fp_i[36]),
	.tx_req_t(fp_o[16]),
	.tx_len(fp_o[27:17]),
	.tx_ack_t(fp_i[37]),
	.rx_rdy_t(fp_i[38]),
	.rx_len(fp_i[49:39]),
	.rx_rel_t(fp_o[28]),
	.pub_t(fp_o[29]),
	.guest_mac(fp_o[77:30]),
	.guest_mode(fp_o[85:78]),
	.host_mac(fp_i[97:50]),
	.host_valid(fp_i[98]),
	.ddr_busy(DDRAM_BUSY),
	.ddr_burstcnt(DDRAM_BURSTCNT),
	.ddr_addr(DDRAM_ADDR),
	.ddr_dout(DDRAM_DOUT),
	.ddr_dout_ready(DDRAM_DOUT_READY),
	.ddr_rd(DDRAM_RD),
	.ddr_din(DDRAM_DIN),
	.ddr_be(DDRAM_BE),
	.ddr_we(DDRAM_WE)
);
////////////////////////////// The Machine //////////////////////////////////

int modelcode;

assign modelcode = (status[7:5]== 0)? 20: //,20,34,44,45,70,94
                   (status[7:5]== 1)? 34:
						 (status[7:5]== 2)? 44:
						 (status[7:5]== 3)? 45:
						 (status[7:5]== 4)? 70:
						 94;

// SDRAM_CLK = ~clk_100mhz through a DDIO output (fixed pin delay)
altddio_out #(.extend_oe_disable("OFF"),.intended_device_family("Cyclone V"),.invert_output("OFF"),
  .lpm_hint("UNUSED"),.lpm_type("altddio_out"),.oe_reg("UNREGISTERED"),.power_up_high("OFF"),.width(1))
sdramclk_ddr (.datain_h(1'b0),.datain_l(1'b1),.outclock(clk_100mhz),.dataout(SDRAM_CLK),
  .aclr(1'b0),.aset(1'b0),.oe(1'b1),.outclocken(1'b1),.sclr(1'b0),.sset(1'b0));
assign SDRAM_CKE=1'b1;

mister_top mister_top
(
   .reset(reset_q),
   .clk_100(clk_100mhz),
	.clk_50 (clk_50mhz),
   .modelcode    (modelcode),
	.serial_console (status[2]),
	.line_50hz      (status[18]),
	.tape_ts        (status[28]),
	.kl1_silo_off   (status[17] & ~status[2]),  // TU58 on line 1: DL11 without the receive silo
	
   .tx1  (UART_TXD),
   .rx1  (UART_RXD),
	.rts1 (UART_RTS),
	.cts1 (UART_CTS),
	
	.have_xu  (have_xu),
	.xu_cs    (xu_cs),
	.xu_sclk  (xu_sclk),
	.xu_mosi  (xu_mosi),
	.xu_miso  (xu_miso),
	.fp_bclk  (clk_100mhz),
	.fp_i     (fp_i),
	.fp_o     (fp_o),
	
   .have_rl (have_rl),
   .rl_sd_lba      (sd_lba[1]),
   .rl_sd_rd       (rl_sd_rd),
   .rl_sd_wr       (rl_sd_wr),
   .rl_sd_ack      (sd_ack[1]),
   .rl_sd_buff_din (sd_buff_din[1]),
   .sd_buff_addr   (sd_buff_addr),
   .sd_buff_dout   (sd_buff_dout),
   .sd_buff_wr     (sd_buff_wr),
	
   .have_rk  (have_rk),
   .rk_sd_lba      (sd_lba[0]),
   .rk_sd_rd       (rk_sd_rd),
   .rk_sd_wr       (rk_sd_wr),
   .rk_sd_ack      (sd_ack[0]),
   .rk_sd_buff_din (sd_buff_din[0]),
	
   .have_rh (have_rh),
   .rh_sd_lba      (sd_lba[2]),
   .rh_sd_rd       (rh_sd_rd),
   .rh_sd_wr       (rh_sd_wr),
   .rh_sd_ack      (sd_ack[2]),
   .rh_sd_buff_din (sd_buff_din[2]),

   .have_tm (have_tm),
   .tm_img_mounted (tm_img_mounted),
   .rk_img_mounted (rk_img_mounted),
   .rl_img_mounted (rl_img_mounted),
   .rl_rl01        (rl_rl01),
   .rh_img_mounted (rh_img_mounted),
   .boot_sel       (boot_sel),         // OSD boot device -> register at 165776 for the low rom
   .tm_media_change (tape_mount_tgl),
   .tm_sd_lba      (sd_lba[3]),
   .tm_sd_rd       (tm_sd_rd),
   .tm_sd_wr       (tm_sd_wr),
   .tm_sd_ack      (sd_ack[3]),
   .tm_sd_buff_din (sd_buff_din[3]),
	
	.dram_addr (SDRAM_A),
	.dram_dq   (SDRAM_DQ),
   .dram_ba_1 (SDRAM_BA[1]),
   .dram_ba_0 (SDRAM_BA[0]),
   .dram_udqm (SDRAM_DQMH),
   .dram_ldqm (SDRAM_DQML),
   .dram_ras_n(SDRAM_nRAS),
   .dram_cas_n(SDRAM_nCAS),
   .dram_we_n (SDRAM_nWE),
   .dram_cs_n (SDRAM_nCS),
	
	.greenled (greenled),
	.panel_lamps (panel_lamps),
	
	.ps2k_c(vt_ps2c),
	.ps2k_d(vt_ps2d),
	.panel_sw (panel_sw),
	
	.vttype(vttype),
   .vga_hsync(vga_hsync),
   .vga_vsync(vga_vsync),
   .vga_hblank(vga_hblank),
   .vga_vblank(vga_vblank),
   .vga_saver(vga_saver),
   .ce_pix(ce_pix_vt),
   .vga_fb(vga_fb),
   .vga_ht(vga_ht),
   .vga_cursor_block(status[11]),
   .vga_cursor_blink(status[12]),
   .teste(status[14]),
   .vt_saver(status[13]),
   .testf(status[15]),
   .have_act(have_act)
);



//////////////////////////////////////////////////////////////////

wire ce_pix_vt;
wire [7:0] video;
wire vga_vsync;
wire vga_hsync;
wire vga_vblank;
wire vga_saver;
wire vga_hblank;
wire vga_fb;
wire vga_ht;
wire [1:0] have_act;
wire [7:0] vttype;
wire [1:0] color;
wire [7:0] vga_red;
wire [7:0] vga_green;
wire [7:0] vga_blue;


assign vttype  = status[10] ? 105 : 100; 
assign have_act = 2'd2;   // VT screen saver: only keyboard activity wakes the screen (1 = keyboard or serial)
assign color=status[9:8];


always @(posedge clk_100mhz) begin
  case(color)
     2'b00: begin
	           vga_red   = 8'b0;
				  vga_green =vga_fb? 8'b11111111 : vga_ht ? 8'b01111111 : 8'b0;
				  vga_blue  = 8'b0;
			   end
     2'b01: begin
	           vga_red   = 8'b0;
				  vga_green =vga_fb? 8'b11111111 : vga_ht ? 8'b01111111 : 8'b0;
				  vga_blue  =vga_fb? 8'b11111111 : vga_ht ? 8'b01111111 : 8'b0;
			   end
     2'b10: begin
	           vga_red   = vga_fb? 8'b11111111 : vga_ht ? 8'b01111111 : 8'b0;
				  vga_green = vga_fb? 8'b11111111 : vga_ht ? 8'b01111111 : 8'b0;
				  vga_blue  = vga_fb? 8'b11111111 : vga_ht ? 8'b01111111 : 8'b0;
			   end
     2'b11: begin
	           vga_red   = vga_fb? 8'b11111111 : vga_ht ? 8'b01111111 : 8'b0;
				  vga_green = vga_fb? 8'b10111111 : vga_ht ? 8'b01011111 : 8'b0;
				  vga_blue  = 8'b0;
			   end
  endcase
end

assign CLK_VIDEO = clk_100mhz;

//////////////////////////////////////////////////////////////////
// On-screen front panel (notes/front-panel-plan.md). The panel drawn on
// clk_100 with the VT's exact timing; lamps from the CPU's console loom
// through paneldriver type 4 (step 2); switches still at their defaults.
// OSD "Video" picks the terminal or the panel, PrintScreen flips it.

wire [51:0] panel_lamps;       // paneldriver (type 4) lamps, already on clk_100

wire        pv_ce, pv_hs, pv_vs, pv_hb, pv_vb;
wire  [7:0] pv_r, pv_g, pv_b;

panel_view panel_view
(
	.clk    (clk_100mhz),
	.reset  (1'b0),                // free-running video timing: keep it off the reset net (fanout into the DRAM FSM)
	.addr_l (panel_lamps[51:30]),
	.data_l (panel_lamps[29:14]),
	.stat_l (panel_lamps[13:2]),
	.par_l  (panel_lamps[1:0]),        // PARITY HIGH, LOW
	.sw     (pv_sw),
	.ctl    (pv_ctl),               // LOAD EXAM DEP CONT ENABLE INST START, 1 = up
	.knob_a (pv_knob_a),
	.knob_d (pv_knob_d),
	.ce_pix (pv_ce),
	.hsync  (pv_hs),
	.vsync  (pv_vs),
	.hblank (pv_hb),
	.vblank (pv_vb),
	.r      (pv_r),
	.g      (pv_g),
	.b      (pv_b)
);

// PrintScreen (sent by Main as E0 12 E0 7C; Win+PrintScreen stays Main's
// screenshot) flips the view; the OSD item sets where it starts.
reg  pv_flip = 1'b0;
reg  ps2_key_t = 1'b0;
always @(posedge clk_100mhz) begin
	ps2_key_t <= ps2_key[10];
	if (ps2_key[10] != ps2_key_t && ps2_key[9] && ps2_key[8] && ps2_key[7:0] == 8'h7C)
		pv_flip <= ~pv_flip;
end
wire panel_on = status[16] ^ pv_flip;

// ---- front panel from the keyboard, while the panel view is on screen ----
//   0-9 toggle switches 0-9, Shift+0-9 switches 10-19, - and = switches 20, 21;
//   l LOAD ADRS, x EXAM, d DEP, c CONT, s START (held while the key is down,
//   paneldriver debounces and pulses them); / toggles ENABLE/HALT;
//   [ ] turn the ADDRESS knob (from PROG PHY), ; ' the DATA knob.
// Toggles act on a key's first make only (PS/2 repeats makes while held).
reg [21:0] psw_sr = 22'd0;
reg        psw_halt = 1'b0;
reg  [2:0] knob_a = 3'd0;           // ADDRESS knob: 0 PROG PHY, 1 CONS PHY, 2 KERNEL D, 3 SUPER D, 4 USER D, 5 USER I, 6 SUPER I, 7 KERNEL I
reg  [1:0] knob_d = 2'd0;           // DATA knob: 0 DATA PATHS, 1 uADRS, 2 DISPLAY REG, 3 BUS REG (paneldriver's order)
reg  [3:0] kn_down = 4'd0;          // [ ] ; ' currently down
reg  [4:0] psw_fn = 5'd0;           // held: 0 LOAD ADRS, 1 EXAM, 2 DEP, 3 CONT, 4 START
reg [11:0] pk_down = 12'd0;         // 0-9, -, = currently down
reg        pk_sl = 1'b0, pk_sr = 1'b0, pk_slash = 1'b0;
reg        pk_t = 1'b0;
function automatic [3:0] pk_idx(input [7:0] c);      // set-2 make code -> 0-9, 10 '-', 11 '=', 15 other
	case (c)
		8'h45: pk_idx = 4'd0;  8'h16: pk_idx = 4'd1;  8'h1E: pk_idx = 4'd2;  8'h26: pk_idx = 4'd3;
		8'h25: pk_idx = 4'd4;  8'h2E: pk_idx = 4'd5;  8'h36: pk_idx = 4'd6;  8'h3D: pk_idx = 4'd7;
		8'h3E: pk_idx = 4'd8;  8'h46: pk_idx = 4'd9;  8'h4E: pk_idx = 4'd10; 8'h55: pk_idx = 4'd11;
		default: pk_idx = 4'd15;
	endcase
endfunction
wire [3:0] pk_k = pk_idx(ps2_key[7:0]);
always @(posedge clk_100mhz) begin
	pk_t <= ps2_key[10];
	if (ps2_key[10] != pk_t && !ps2_key[8]) begin                 // a new key event, not an E0 (extended) key
		if (ps2_key[7:0] == 8'h12) pk_sl <= ps2_key[9];           // left shift
		if (ps2_key[7:0] == 8'h59) pk_sr <= ps2_key[9];           // right shift
		if (pk_k != 4'd15) begin
			pk_down[pk_k] <= ps2_key[9];
			if (ps2_key[9] && !pk_down[pk_k] && panel_on) begin
				if (pk_k >= 4'd10)        psw_sr[pk_k + 5'd10] <= ~psw_sr[pk_k + 5'd10];   // - = : 20, 21
				else if (pk_sl || pk_sr)  psw_sr[pk_k + 5'd10] <= ~psw_sr[pk_k + 5'd10];   // shift 0-9: 10-19
				else                      psw_sr[pk_k]         <= ~psw_sr[pk_k];           // 0-9
			end
		end
		case (ps2_key[7:0])
			8'h4B: psw_fn[0] <= ps2_key[9] & panel_on;   // l  LOAD ADRS
			8'h22: psw_fn[1] <= ps2_key[9] & panel_on;   // x  EXAM
			8'h23: psw_fn[2] <= ps2_key[9] & panel_on;   // d  DEP
			8'h21: psw_fn[3] <= ps2_key[9] & panel_on;   // c  CONT
			8'h1B: psw_fn[4] <= ps2_key[9] & panel_on;   // s  START
			8'h54: begin if (ps2_key[9] && !kn_down[0] && panel_on) knob_a <= knob_a - 3'd1; kn_down[0] <= ps2_key[9]; end   // [
			8'h5B: begin if (ps2_key[9] && !kn_down[1] && panel_on) knob_a <= knob_a + 3'd1; kn_down[1] <= ps2_key[9]; end   // ]
			8'h4C: begin if (ps2_key[9] && !kn_down[2] && panel_on) knob_d <= knob_d - 2'd1; kn_down[2] <= ps2_key[9]; end   // ;
			8'h52: begin if (ps2_key[9] && !kn_down[3] && panel_on) knob_d <= knob_d + 2'd1; kn_down[3] <= ps2_key[9]; end   // '
			8'h4A: begin                                  // /  ENABLE/HALT
				if (ps2_key[9] && !pk_slash && panel_on) psw_halt <= ~psw_halt;
				pk_slash <= ps2_key[9];
			end
			default: ;
		endcase
	end
	if (!panel_on) psw_fn <= 5'd0;
end
// paneldriver type 4 raw words: 3 = {start, inst, halt, cont, dep, exam, load, test}, 2/1 = switch register
assign pv_sw  = psw_sr;
assign pv_ctl = {psw_fn[0], psw_fn[1], psw_fn[2], psw_fn[3], ~psw_halt, 1'b0, psw_fn[4]};
assign pv_knob_a = knob_a;
assign pv_knob_d = knob_d;
assign panel_sw = {knob_d, knob_a, 4'b0000, psw_fn[4], 1'b0, psw_halt, psw_fn[3], psw_fn[2], psw_fn[1], psw_fn[0], 1'b0,
                        2'b00, psw_sr[21:12], psw_sr[11:0]};

// While the panel is on screen the keyboard drives it, not the VT. The VT's
// PS/2 stream is cut or restored only after ~5 ms of line idle, so a byte or
// a multi-byte key sequence is never split.
reg [19:0] ps2_idle = 20'd0;
reg        vt_kbd_off = 1'b0;
always @(posedge clk_100mhz) begin
	if (!ps2k_c) ps2_idle <= 20'd0;
	else if (!ps2_idle[19]) ps2_idle <= ps2_idle + 20'd1;
	if (ps2_idle[19]) vt_kbd_off <= panel_on;
end
assign vt_ps2c = vt_kbd_off ? 1'b1 : ps2k_c;
assign vt_ps2d = vt_kbd_off ? 1'b1 : ps2k_d;

// VT screen saver (OSD, keyboard wakes it): the panel view blanks with it.
reg [1:0] saver_s;
always @(posedge clk_100mhz) saver_s <= {saver_s[0], vga_saver};
wire [7:0] pv_r_s = saver_s[1] ? 8'd0 : pv_r;
wire [7:0] pv_g_s = saver_s[1] ? 8'd0 : pv_g;
wire [7:0] pv_b_s = saver_s[1] ? 8'd0 : pv_b;
wire ce_pix = panel_on ? pv_ce : ce_pix_vt;

video_mixer video_mixer
(
        .*,
        .freeze_sync(),
        .scandoubler(1'b0),
        .hq2x(),
        .R(panel_on ? pv_r_s : vga_red),
        .G(panel_on ? pv_g_s : vga_green),
		  .B(panel_on ? pv_b_s : vga_blue),
        .HSync(panel_on ? pv_hs : vga_hsync),
        .VSync(panel_on ? pv_vs : vga_vsync),
        .HBlank(panel_on ? pv_hb : vga_hblank),
        .VBlank(panel_on ? pv_vb : vga_vblank)
);

endmodule
