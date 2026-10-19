//
// panel_view.sv -- on-screen PDP-11/70 front panel (notes/front-panel-plan.md, step 1)
//
// Draws the panel on clk_100 with exactly the virtual VT's video timing
// (rtl/vga.vhd): 800 x 524 at a 25 MHz pixel rate, HSYNC low in columns
// 0-95, picture in columns 144-783 and rows 0-479, VSYNC low in rows
// 489-490, HBLANK in the sync columns and in rows 491-523, VBLANK unused,
// and the pixel enable shaped like the VT's (high 2 of every 4 clk_100
// cycles). So the MiSTer scaler sees the same mode in both views.
//
// The picture is tools/panel/mkpanel.py's artwork, in rtl/panel_art.hex: runs
// of (colour, object), in raster order, at most 128 pixels, never across a
// line. Each run word is colour[19:16] kind[15:14] n[13:7] length-1[6:0]. The
// colour is the panel with every lamp off; the object says which live thing
// the pixel belongs to (a lamp's core or glow ring, a paddle's light end in
// its up or down position, a knob pointer), and a lit object's pixels take
// its lit colour instead. mkpanel.py documents the objects; its render() is
// this module's reference (sim/tb_panel_view.sv compares a frame with it).
//
// Inputs are levels on clk_100 (paneldriver type 4 via mister_top), latched
// once per frame at the start of vertical blanking.
//
module panel_view
(
	input             clk,          // clk_100
	input             reset,

	input      [21:0] addr_l,       // ADDRESS lamps
	input      [15:0] data_l,       // DATA lamps
	input      [11:0] stat_l,       // status lamps: run pause master user super kernel data 16 18 22 adrserr parerr
	input       [1:0] par_l,        // PARITY HIGH, LOW
	input      [21:0] sw,           // switch register (1 = up)
	input       [6:0] ctl,          // LOAD ADRS, EXAM, DEP, CONT, ENABLE/HALT, S INST, START (1 = up)
	input       [2:0] knob_a,       // ADDRESS knob position (0 PROG PHY ... 7 KERNEL I)
	input       [1:0] knob_d,       // DATA knob position

	output reg        ce_pix,
	output reg        hsync,
	output reg        vsync,
	output reg        hblank,
	output reg        vblank,
	output reg  [7:0] r,
	output reg  [7:0] g,
	output reg  [7:0] b
);

// ---- timing: as rtl/vga.vhd ------------------------------------------------
reg  [1:0] div;
reg  [9:0] col;            // 0..799
reg  [9:0] row;            // 0..523
wire       adv = (div == 2'd1);

always @(posedge clk) begin
	if (reset) begin
		div <= 0; col <= 0; row <= 0;
	end else begin
		div <= div + 2'd1;
		if (adv) begin
			if (col < 10'd799) col <= col + 10'd1;
			else begin
				col <= 0;
				row <= (row < 10'd523) ? row + 10'd1 : 10'd0;
			end
		end
	end
end

localparam X0 = 10'd144;        // first picture column

// ---- the lamps and switches, latched once per frame (no half-updated frames) ----
// as object vectors: lamps (kinds 1 and 2) by n, paddle ends and pointers (kind 3) by n
wire [11:0] stat_lr = {stat_l[2], stat_l[3], stat_l[4], stat_l[5], stat_l[6], stat_l[7],
                       stat_l[8], stat_l[9], stat_l[10], stat_l[11], stat_l[1], stat_l[0]};   // left to right, from bit 0
wire  [6:0] ctl_lr  = {ctl[0], ctl[1], ctl[2], ctl[3], ctl[4], ctl[5], ctl[6]};                // LOAD ADRS in bit 0
reg  [63:0] lamps;                // 0-21 ADDRESS, 22-37 DATA, 38-49 status, 50 PAR HIGH, 51 LOW, 52-59 knob A, 60-63 knob D
reg  [63:0] ends;                 // 0-21 switch up, 22-28 control up, 32-53 switch down, 54-60 control down
reg  [11:0] ptrs;                 // 0-7 ADDRESS knob, 8-11 DATA knob
always @(posedge clk) if (adv && col == 10'd0 && row == 10'd480) begin
	lamps <= {4'b0001 << knob_d, 8'b00000001 << knob_a, par_l[0], par_l[1], stat_lr, data_l, addr_l};
	ends  <= {3'b000, ~ctl_lr, ~sw, 3'b000, ctl_lr, sw};
	ptrs  <= {4'b0001 << knob_d, 8'b00000001 << knob_a};
end

// ---- the artwork ROM ------------------------------------------------------------
localparam ART_WORDS = 28672;     // 56 x 512 words; mkpanel.py checks that the runs fit
reg [19:0] art [0:ART_WORDS-1];
initial $readmemh("rtl/panel_art.hex", art);
reg [14:0] ra;                    // next run's address
reg [19:0] rq;                    // art[ra], one clock later
always @(posedge clk) rq <= art[ra];

wire pic = (col >= X0) && (col < X0 + 10'd640) && (row < 10'd480);

// ---- stage 1 (clock after the pixel advances): this pixel's run --------------------
// col/row hold for 4 clocks per pixel, so each stage gets one clock and the
// ROM has three to answer before the next pixel wants the next run.
reg  [6:0] rem;                   // pixels left in the current run after this one
reg [12:0] cur;                   // current run: colour, kind, n
reg        s1_pic;
reg [12:0] s1_px;
always @(posedge clk) if (div == 2'd2) begin
	s1_pic <= pic;
	if (row == 10'd480) begin    // vertical blanking: back to the first run
		ra <= 0; rem <= 0;
	end else if (pic) begin
		if (rem == 0) begin
			cur <= rq[19:7]; s1_px <= rq[19:7];
			rem <= rq[6:0];
			ra <= ra + 15'd1;
		end else begin
			s1_px <= cur;
			rem <= rem - 7'd1;
		end
	end
end

// ---- stage 2: lit or not ------------------------------------------------------------
wire [3:0] c1 = s1_px[12:9];
wire [1:0] k1 = s1_px[8:7];
wire [6:0] n1 = s1_px[6:0];
reg  [3:0] s2_ci;
reg        s2_pic;
always @(posedge clk) if (div == 2'd3) begin
	s2_pic <= s1_pic;
	case (k1)
		2'd1: s2_ci <= lamps[n1[5:0]] ? 4'd12 : c1;               // lamp core
		2'd2: s2_ci <= lamps[n1[5:0]] ? 4'd13 : c1;               // lamp glow ring
		2'd3: if (n1[6]) s2_ci <= ptrs[n1[3:0]] ? 4'd4 : c1;     // knob pointer
		      else       s2_ci <= ends[n1[5:0]] ? 4'd14 : c1;     // paddle light end
		default: s2_ci <= c1;
	endcase
end

// ---- stage 3: the palette (tools/panel/mkpanel.py PAL) ---------------------------------
reg [23:0] s3_px;
reg        s3_pic;
always @(posedge clk) if (div == 2'd0) begin
	s3_pic <= s2_pic;
	case (s2_ci)
		4'd0:  s3_px <= 24'hc8c1ae;   // beige surround
		4'd1:  s3_px <= 24'h9e9786;   // beige shadow
		4'd2:  s3_px <= 24'h1a181c;   // panel black
		4'd3:  s3_px <= 24'h0c0b0d;   // lamp well
		4'd4:  s3_px <= 24'heeece6;   // label white
		4'd5:  s3_px <= 24'h9a98a0;   // grey
		4'd6:  s3_px <= 24'h4c4a50;   // dark grey
		4'd7:  s3_px <= 24'hc8223a;   // red
		4'd8:  s3_px <= 24'h881426;   // red dark
		4'd9:  s3_px <= 24'h7c1e7e;   // purple
		4'd10: s3_px <= 24'h501252;   // purple dark
		4'd11: s3_px <= 24'h2c2016;   // lamp off
		4'd12: s3_px <= 24'hffb430;   // lamp lit
		4'd13: s3_px <= 24'hb86216;   // lamp glow
		4'd14: s3_px <= 24'hf4e8d0;   // paddle light end
		4'd15: s3_px <= 24'h302e34;   // knob body
	endcase
end

// ---- outputs: once per pixel; sync/blank exactly as the VT, picture from stage 2 ----
always @(posedge clk) begin
	ce_pix <= div[1];
	if (adv) begin
		hsync  <= !(col < 10'd96);
		vsync  <= !(row >= 10'd489 && row < 10'd491);
		hblank <= (col < 10'd96) || (row >= 10'd491);
		vblank <= 1'b0;
		{r, g, b} <= s3_pic ? s3_px : 24'h000000;
	end
end

endmodule
