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
	input  [126:0] DDRAM_DOUT,
	input         DDRAM_DOUT_READY,
	output        DDRAM_RD,
	output [126:0] DDRAM_DIN,
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
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;  
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
	"O[2],Console,Virtual VT100,Serial 19200 baud;",
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
	"P2,Front panel;",
	"P2O[16],CPU,Run,Halt;",
	"P2T[17],Continue;",
	"P2T[18],Start;",
	"P2T[19],Load address;",
	"P2T[20],Examine;",
	"P2T[37],Deposit;",
	"P2-;",
	"P2O[39],Auto-boot,Off,On;",
	"P2O[38],SR 17600000,0,1;",
	"P2O[36],SR 100000,0,1;",
	"P2O[35:33],SR 070000,0,1,2,3,4,5,6,7;",
	"P2O[32:30],SR 007000,0,1,2,3,4,5,6,7;",
	"P2O[29:27],SR 000700,0,1,2,3,4,5,6,7;",
	"P2O[26:24],SR 000070,0,1,2,3,4,5,6,7;",
	"P2O[23:21],SR 000007,0,1,2,3,4,5,6,7;",
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
wire [21:0] gamma_bus;


wire [31:0] sd_lba[4];
reg   [3:0] sd_rd;
reg   [3:0] sd_wr;
wire  [3:0] sd_ack;
wire [7:0]sd_buff_addr;
wire [15:0] sd_buff_dout;
wire [15:0] sd_buff_din[4];
wire        sd_buff_wr;
wire  [3:0] img_mounted;
wire  [3:0] img_readonly;
wire  [63:0]img_size;

wire  [7:0] uart_mode;



wire [35:0] ext_bus;
wire [15:0] dbg_r7, dbg_ir, dbg_psw, dbg_data, dbg_addr;

// tracecap.vhd/tracecap_dbg.sv event-trace taps -- see rtl/tracecap_pkg.vhd
wire        trace_rl_valid;
wire [15:0] trace_rl_dar;
wire [17:0] trace_rl_dest;
wire [12:0] trace_rl_wc;
wire [15:0] trace_rl_par5, trace_rl_par6;
wire [15:0] trace_rl_kipar5, trace_rl_kipar6;
wire        trace_rh_valid;
wire [15:0] trace_rh_dar;
wire [21:0] trace_rh_dest;
wire [15:0] trace_rh_wc;
wire [15:0] trace_rh_par5, trace_rh_par6;
wire [15:0] trace_rh_kipar5, trace_rh_kipar6;
wire        dbg_run, dbg_nxm;

// PC-compare breakpoint (see rtl/brk_compare.vhd / rtl/brk_dbg.sv)
wire [15:0] brk_cfg_addr;
wire        brk_cfg_enabled;

hps_io #(.CONF_STR(CONF_STR),.WIDE(1),.VDNUM(4),.PS2DIV(3125)) hps_io
(
   
	.clk_sys(clk_100mhz),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(ext_bus),
   .gamma_bus(gamma_bus),
	.buttons(buttons),
	.status(status),
	
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


wire reset = RESET | status[0] | buttons[1]; //| !pll_locked;

///////////////////////// DISKS /////////////////////////////////////////

wire sdcard_sclk;
wire sdcard_mosi;
wire sdcard_cs;
wire vsdmiso;


reg vsd_sel_rk = 0;
reg vsd_sel_rl = 0;
reg vsd_sel_rh = 0;
reg vsd_sel_tm = 0;
reg tape_mount_tgl = 0;

always @(posedge clk_100mhz) begin
	if(img_mounted[0]) vsd_sel_rk <= |img_size;
	if(img_mounted[1]) vsd_sel_rl <= |img_size;
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

// RK11/RL11/RH11 all talk hps_io's native sd_lba/sd_rd/sd_wr/sd_ack/
// sd_buff_* protocol directly now (see rk11.vhd/rl11.vhd/rh11.vhd and
// mister_top.vhd's rk_sd_*/rl_sd_*/rh_sd_* ports, wired straight to
// sd_lba[0]/[1]/[2] etc. in the mister_top instantiation below) -- Phase
// 3 of the disk-transport plan (RL11), same pattern as RH11's Phase 1
// and RK11's Phase 2. No sd_card SPI-emulation instance needed any more
// for any of the three, unlike tm below (not yet migrated).

sd_card #(.WIDE(1)) sd_card_tm
(
	.clk_sys     (clk_100mhz),
	.clk_spi     (clk_100mhz),
	.reset       (reset),

	.sdhc(1),

	.sd_lba      (sd_lba[3]),
	.sd_rd       (sd_rd[3]),
	.sd_wr       (sd_wr[3]),
	.sd_ack      (sd_ack[3]),

	.sd_buff_addr(sd_buff_addr),
	.sd_buff_din (sd_buff_din[3]),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_wr  (sd_buff_wr),


	.sck         (tm_sclk),
	.ss          (tm_cs | ~vsd_sel_tm),
	.mosi        (tm_mosi),
	.miso        (tm_miso)

);

int have_rk;
int rk_img_mounted;
int have_rl;
int rl_img_mounted;
int have_rh;
int have_tm;
int rh_img_mounted;
int tm_img_mounted;

assign have_rk = 1;  // controller presence is a build-time choice, not tied to
                      // mount state -- see rk11's img_mounted for "no medium"
assign rk_img_mounted = vsd_sel_rk ? 1 : 0;
assign have_rl = 1;  // controller presence is a build-time choice, not tied to
                      // mount state -- see rl11's img_mounted for "no medium"
assign rl_img_mounted = vsd_sel_rl ? 1 : 0;
assign have_rh = 1;  // controller presence is a build-time choice, not tied to
                      // mount state -- see rh11's img_mounted for "no medium"
assign rh_img_mounted = vsd_sel_rh ? 1 : 0;
assign have_tm = 1;  // controller presence is a build-time choice, not tied to
                      // mount state -- see tm11's img_mounted for "no tape"
assign tm_img_mounted = vsd_sel_tm ? 1 : 0;

//
wire tm_sclk;
wire tm_cs;
wire tm_mosi;
wire tm_miso;
wire [3:0]tm_sddebug;
//
//

/////////////////////////////// LEDS ////////////////////////////////////////
wire greenled;
wire[3:0] sddebug;

// rh11/rk11/rl11 no longer have an sddebug nibble (no SPI bit-banging left to blink an LED for)
assign sddebug     = 4'b0;
assign LED_POWER={1'b1,greenled};
assign LED_DISK=sddebug[0] | sddebug[2];
assign LED_USER=sddebug[1] | sddebug[3];
/////////////////////////////// External Ethernet////////////////////////////
int have_xu;
assign have_xu = status[1]? 1 : 0;

wire xu_cs; 
wire xu_mosi;
wire xu_sclk;
wire xu_miso;

assign USER_OUT[0] = xu_mosi;
assign xu_miso = USER_IN[1];
assign USER_OUT[6] = xu_sclk;
assign USER_OUT[3] = xu_cs;
////////////////////////////// The Machine //////////////////////////////////

int modelcode;

assign modelcode = (status[7:5]== 0)? 20: //,20,34,44,45,70,94
                   (status[7:5]== 1)? 34:
						 (status[7:5]== 2)? 44:
						 (status[7:5]== 3)? 45:
						 (status[7:5]== 4)? 70:
						 94;

assign SDRAM_CLK=~clk_100mhz;
assign SDRAM_CKE=1'b1;

mister_top mister_top
(
   .reset(reset),
   .clk_100(clk_100mhz),
	.clk_50 (clk_50mhz),
   .modelcode    (modelcode),
	.serial_console (status[2]),
	
   .tx1  (UART_TXD),
   .rx1  (UART_RXD),
	.rts1 (UART_RTS),
	.cts1 (UART_CTS),
	
	.have_xu  (have_xu),
	.xu_cs    (xu_cs),
	.xu_sclk  (xu_sclk),
	.xu_mosi  (xu_mosi),
	.xu_miso  (xu_miso),
	
   .have_rl (have_rl),
   .rl_img_mounted (rl_img_mounted),
   .rl_sd_lba       (sd_lba[1]),
   .rl_sd_rd        (sd_rd[1]),
   .rl_sd_wr        (sd_wr[1]),
   .rl_sd_ack       (sd_ack[1]),
   .rl_sd_buff_addr (sd_buff_addr),
   .rl_sd_buff_dout (sd_buff_dout),
   .rl_sd_buff_din  (sd_buff_din[1]),
   .rl_sd_buff_wr   (sd_buff_wr),

   .have_rk  (have_rk),
   .rk_img_mounted (rk_img_mounted),
   .rk_sd_lba       (sd_lba[0]),
   .rk_sd_rd        (sd_rd[0]),
   .rk_sd_wr        (sd_wr[0]),
   .rk_sd_ack       (sd_ack[0]),
   .rk_sd_buff_addr (sd_buff_addr),
   .rk_sd_buff_dout (sd_buff_dout),
   .rk_sd_buff_din  (sd_buff_din[0]),
   .rk_sd_buff_wr   (sd_buff_wr),

   .have_rh (have_rh),
   .rh_img_mounted (rh_img_mounted),
   .rh_sd_lba       (sd_lba[2]),
   .rh_sd_rd        (sd_rd[2]),
   .rh_sd_wr        (sd_wr[2]),
   .rh_sd_ack       (sd_ack[2]),
   .rh_sd_buff_addr (sd_buff_addr),
   .rh_sd_buff_dout (sd_buff_dout),
   .rh_sd_buff_din  (sd_buff_din[2]),
   .rh_sd_buff_wr   (sd_buff_wr),

   .have_tm (have_tm),
   .tm_img_mounted (tm_img_mounted),
   .tm_media_change (tape_mount_tgl),
   .tm_sdcard_cs   (tm_cs),
   .tm_sdcard_miso (tm_miso),
   .tm_sdcard_mosi (tm_mosi),
   .tm_sdcard_sclk (tm_sclk),
   .tm_sdcard_debug(tm_sddebug),
	
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
	
	.ps2k_c(ps2k_c),
	.ps2k_d(ps2k_d),
	
	.vttype(vttype),
   .vga_hsync(vga_hsync),
   .vga_vsync(vga_vsync),
   .vga_hblank(vga_hblank),
   .vga_vblank(vga_vblank),
   .ce_pix(ce_pix),
   .vga_fb(vga_fb),
   .vga_ht(vga_ht),
   .vga_cursor_block(status[11]),
   .vga_cursor_blink(status[12]),
   .teste(status[14]),
   .testf(status[15]),
   .have_act(have_act),

   .osd_halt (status[16]),
   .osd_autoboot(status[39]),
   .osd_cont (status[17]),
   .osd_start(status[18]),
   .osd_load (status[19]),
   .osd_exa  (status[20]),
   .osd_dep  (status[37]),
   .osd_sr22 (status[38]),
   .osd_sr   ({status[36], status[35:33], status[32:30],
               status[29:27], status[26:24], status[23:21]}),
   .osd_status(OSD_STATUS),
   .dbg_r7   (dbg_r7),
   .dbg_ir   (dbg_ir),
   .dbg_psw  (dbg_psw),
   .dbg_run  (dbg_run),
   .dbg_data (dbg_data),
   .dbg_addr (dbg_addr),
   .dbg_nxm  (dbg_nxm),

   .trace_rl_valid (trace_rl_valid),
   .trace_rl_dar   (trace_rl_dar),
   .trace_rl_dest  (trace_rl_dest),
   .trace_rl_wc    (trace_rl_wc),
   .trace_rl_par5  (trace_rl_par5),
   .trace_rl_par6  (trace_rl_par6),
   .trace_rl_kipar5 (trace_rl_kipar5),
   .trace_rl_kipar6 (trace_rl_kipar6),
   .trace_rh_valid (trace_rh_valid),
   .trace_rh_dar   (trace_rh_dar),
   .trace_rh_dest  (trace_rh_dest),
   .trace_rh_wc    (trace_rh_wc),
   .trace_rh_par5  (trace_rh_par5),
   .trace_rh_par6  (trace_rh_par6),
   .trace_rh_kipar5 (trace_rh_kipar5),
   .trace_rh_kipar6 (trace_rh_kipar6),

   .brk_cfg_addr    (brk_cfg_addr),
   .brk_cfg_enabled (brk_cfg_enabled)
);

panel_dbg panel_dbg
(
	.clk_sys (clk_100mhz),
	.EXT_BUS (ext_bus),
	.r7      (dbg_r7),
	.ir      (dbg_ir),
	.psw     (dbg_psw),
	.run     (dbg_run),
	.data    (dbg_data),
	.addr    (dbg_addr),
	.nxm     (dbg_nxm)
);

// Generic event-trace capture (Faye: "I kinda want to make the same
// class of artifact from the FPGA now" -- mirrors pdp11dis/diskmem.py,
// captured directly in hardware instead of parsed from a SIMH log).
// Source index: 0=RL0 disk (READ+GO trigger), 1=RH0 disk (same),
// 2/3=reserved/unused. kind: 0001=disk (tracecap_pkg.TRACE_KIND_DISK).
//
// No standalone PAR-write event kind: PAR5/6 change far too often, even
// scoped to just those two kernel D-space registers with real dedup, to
// log as their own events without drowning every disk event (confirmed
// on real hardware: 16222 of 16384 entries were PAR-write events, zero
// disk events survived). Instead, rl11.vhd/rh11.vhd sample mmu.vhd's
// live KERNEL D-space PAR5/PAR6 copies and stamp them onto their OWN
// disk event's `d` field at the same READ+GO trigger moment as
// dar/dest/wc -- no separate event, no filtering, every disk event just
// gets whatever those two registers currently hold.
wire        trace_overflowed;
wire [13:0] trace_wr_ptr;    // must match tracecap.vhd's DEPTH_LOG2 (14)
wire [13:0] trace_rd_addr;
wire [3:0]  trace_rd_kind;
wire [3:0]  trace_rd_id;
wire [21:0] trace_rd_a;
wire [21:0] trace_rd_b;
wire [15:0] trace_rd_c;
wire [63:0] trace_rd_d;

tracecap tracecap
(
	.clk   (clk_100mhz),
	.reset (reset),

	.src_valid  ({1'b0, 1'b0, trace_rh_valid, trace_rl_valid}),
	.src_kind_v ({4'b0000, 4'b0000, 4'b0001, 4'b0001}),
	.src_id_v   ({4'd0, 4'd0, 4'd1, 4'd0}),
	.src_a_v    ({22'd0,
	              22'd0,
	              {6'd0, trace_rh_dar},
	              {6'd0, trace_rl_dar}}),
	.src_b_v    ({22'd0,
	              22'd0,
	              trace_rh_dest,
	              {4'd0, trace_rl_dest}}),
	.src_c_v    ({16'd0,
	              16'd0,
	              trace_rh_wc,
	              {3'd0, trace_rl_wc}}),
	.src_d_v    ({64'd0,
	              64'd0,
	              {trace_rh_par5, trace_rh_par6, trace_rh_kipar5, trace_rh_kipar6},
	              {trace_rl_par5, trace_rl_par6, trace_rl_kipar5, trace_rl_kipar6}}),

	.overflowed (trace_overflowed),

	.rd_addr (trace_rd_addr),
	.rd_kind (trace_rd_kind),
	.rd_id   (trace_rd_id),
	.rd_a    (trace_rd_a),
	.rd_b    (trace_rd_b),
	.rd_c    (trace_rd_c),
	.rd_d    (trace_rd_d),
	.wr_ptr  (trace_wr_ptr)
);

tracecap_dbg tracecap_dbg
(
	.clk_sys (clk_100mhz),
	.EXT_BUS (ext_bus),

	.overflowed (trace_overflowed),
	.wr_ptr     (trace_wr_ptr),

	.rd_addr (trace_rd_addr),
	.rd_kind (trace_rd_kind),
	.rd_id   (trace_rd_id),
	.rd_a    (trace_rd_a),
	.rd_b    (trace_rd_b),
	.rd_c    (trace_rd_c),
	.rd_d    (trace_rd_d)
);

brk_dbg brk_dbg
(
	.clk_sys (clk_100mhz),
	.EXT_BUS (ext_bus),

	.brk_cfg_addr    (brk_cfg_addr),
	.brk_cfg_enabled (brk_cfg_enabled)
);



//////////////////////////////////////////////////////////////////

wire ce_pix;
wire [7:0] video;
wire vga_vsync;
wire vga_hsync;
wire vga_vblank;
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
assign have_act = status[13];
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

video_mixer video_mixer
(
        .*,
        .freeze_sync(),
        .scandoubler(1'b0),
        .hq2x(),
        .R(vga_red),
        .G(vga_green),
		  .B(vga_blue),
        .HSync(vga_hsync),
        .VSync(vga_vsync),
        .HBlank(vga_hblank),
        .VBlank(vga_vblank)
);

endmodule
