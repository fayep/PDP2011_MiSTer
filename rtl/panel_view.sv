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
// Layout (x 0-639, y 0-479): 22 columns, 26 px apart, in the 11/70's colour
// groups of three (bit 21 on the left). ADDRESS lamps (22), DATA lamps (16,
// bits 15-0 under address bits 15-0), status lamps, the switch register
// (22 paddles, up = 1) and the 7 control switches. Lamps are incandescent
// circles: lit amber, unlit dark.
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
	input      [11:0] stat_l,       // status lamps
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

// ---- geometry ----------------------------------------------------------------
localparam X0    = 10'd144;     // first picture column
localparam LEFT  = 10'd33;      // x of column 0's left edge
localparam PITCH = 5'd26;       // column pitch
localparam Y_ADR = 10'd96;      // lamp row centres
localparam Y_DAT = 10'd156;
localparam Y_STA = 10'd216;
localparam Y_SW  = 10'd330;     // switch paddle centre
localparam Y_CTL = 10'd430;     // control switch centre

wire [9:0] x = col - X0;
wire [9:0] y = row;
wire       pic = (col >= X0) && (col < X0 + 10'd640) && (row < 10'd480);

// column index (0..21, 31 = outside) and position within the column, from x
reg  [4:0] ci;
reg  [4:0] cx;             // 0..25
always @(posedge clk) if (adv) begin
	if (col == X0 + LEFT - 10'd1) begin ci <= 0; cx <= 0; end
	else if (ci != 5'd31) begin
		if (cx == PITCH - 5'd1) begin
			cx <= 0;
			ci <= (ci == 5'd21) ? 5'd31 : ci + 5'd1;
		end else cx <= cx + 5'd1;
	end
	if (col == 10'd0) ci <= 5'd31;
end

// bit number for this column (column 0 = bit 21), colour group (3 bits each from bit 0)
wire [4:0] bitn  = 5'd21 - ci;
wire       incol = (ci != 5'd31);
wire [2:0] grp   = (bitn >= 5'd21) ? 3'd7 : (bitn >= 5'd18) ? 3'd6 : (bitn >= 5'd15) ? 3'd5 :
                   (bitn >= 5'd12) ? 3'd4 : (bitn >= 5'd9)  ? 3'd3 : (bitn >= 5'd6)  ? 3'd2 :
                   (bitn >= 5'd3)  ? 3'd1 : 3'd0;

// ---- the lamps and switches, latched once per frame (no half-updated frames) ----
reg [21:0] fa; reg [15:0] fd; reg [11:0] fs; reg [21:0] fsw; reg [6:0] fct; reg [2:0] fka; reg [1:0] fkd;
always @(posedge clk) if (adv && col == 10'd0 && row == 10'd480) begin
	fa <= addr_l; fd <= data_l; fs <= stat_l; fsw <= sw; fct <= ctl; fka <= knob_a; fkd <= knob_d;
end

// ---- stage 1 (clock after the pixel advances): distances, squares, lamp bits ----
// col/row/ci/cx hold for 4 clocks per pixel, so each stage gets one clock.
wire signed [6:0] dx = $signed({2'b0, cx}) - 7'sd13;
function automatic [7:0] sq(input signed [6:0] v);
	reg [6:0] a;
	begin a = v[6] ? -v : v; sq = a * a; end
endfunction
function automatic signed [10:0] dyof(input [9:0] yy, input [9:0] yc);
	dyof = $signed({1'b0, yy}) - $signed({1'b0, yc});
endfunction
wire signed [10:0] dy_adr = dyof(y, Y_ADR);
wire signed [10:0] dy_dat = dyof(y, Y_DAT);
wire signed [10:0] dy_sta = dyof(y, Y_STA);
wire signed [10:0] dy_sw  = dyof(y, Y_SW);
wire signed [10:0] dy_ctl = dyof(y, Y_CTL);

reg        s1_pic, s1_incol, s1_strip, s1_band;
reg        s1_nadr, s1_ndat, s1_nsta, s1_nsw, s1_nctl;
reg  [7:0] s1_r2a, s1_r2d, s1_r2s;
reg        s1_la, s1_ld, s1_ls, s1_sw, s1_ct, s1_ctlp;
reg        s1_swup, s1_swdn, s1_ctup, s1_ctdn;
reg        s1_nknb, s1_lk;                // knob position lamps: ADDRESS in columns 9-16, DATA in 18-21
reg  [7:0] s1_r2k;

always @(posedge clk) if (div == 2'd2) begin
	s1_pic   <= pic;
	s1_incol <= incol;
	s1_strip <= (y == Y_ADR + 10'd14) || (y == Y_DAT + 10'd14);
	s1_band  <= grp[0];
	s1_nadr  <= (dy_adr > -11'sd10) && (dy_adr < 11'sd10);
	s1_ndat  <= (dy_dat > -11'sd10) && (dy_dat < 11'sd10) && (bitn < 5'd16);
	s1_nsta  <= (dy_sta > -11'sd10) && (dy_sta < 11'sd10) && (bitn < 5'd12);
	s1_nsw   <= (dy_sw > -11'sd34) && (dy_sw < 11'sd34) && (cx >= 5'd5) && (cx <= 5'd20);
	s1_nctl  <= (ci <= 5'd6) && (dy_ctl > -11'sd20) && (dy_ctl < 11'sd20) && (cx >= 5'd6) && (cx <= 5'd19);
	s1_r2a   <= sq(dx) + sq(dy_adr[6:0]);
	s1_r2d   <= sq(dx) + sq(dy_dat[6:0]);
	s1_r2s   <= sq(dx) + sq(dy_sta[6:0]);
	s1_la    <= fa[bitn];
	s1_ld    <= fd[bitn[3:0]];
	s1_ls    <= fs[(bitn < 5'd12) ? bitn[3:0] : 4'd0];
	s1_sw    <= fsw[bitn];
	s1_ct    <= fct[3'd6 - ci[2:0]];
	s1_ctlp  <= (ci == 5'd4 || ci == 5'd5);          // ENABLE/HALT, S INST: latching
	s1_swup  <= dy_sw < -11'sd14;
	s1_swdn  <= dy_sw >  11'sd14;
	s1_ctup  <= dy_ctl < -11'sd8;
	s1_ctdn  <= dy_ctl >  11'sd8;
	s1_nknb  <= ((ci >= 5'd9 && ci <= 5'd16) || (ci >= 5'd18 && ci <= 5'd21)) && (dy_ctl > -11'sd10) && (dy_ctl < 11'sd10);
	s1_r2k   <= sq(dx) + sq(dy_ctl[6:0]);
	s1_lk    <= (ci <= 5'd16) ? (ci - 5'd9 == {2'b00, fka}) : (ci - 5'd18 == {3'b000, fkd});
end

// ---- colours -------------------------------------------------------------------
localparam [23:0] C_BG    = 24'h141018;     // panel black
localparam [23:0] C_PURP  = 24'h5a2a6e;     // 11/70 purple group
localparam [23:0] C_MAG   = 24'hb0305e;     // 11/70 magenta group
localparam [23:0] C_LIT   = 24'hffb838;     // lit lamp
localparam [23:0] C_GLOW  = 24'h7a4a18;     // lit lamp halo
localparam [23:0] C_OFF   = 24'h3a2614;     // unlit lamp
localparam [23:0] C_RIM   = 24'h4a4a50;     // lamp bezel
localparam [23:0] C_LEVER = 24'he8e0d0;     // switch lever end

function automatic [23:0] lamp(input on, input [7:0] r2);
	lamp = (r2 <= 8'd36)  ? (on ? C_LIT : C_OFF) :
	       (r2 <= 8'd56)  ? (on ? C_GLOW : C_OFF) :
	       (r2 <= 8'd72)  ? C_RIM : C_BG;
endfunction

// ---- stage 2: the pixel colour ----------------------------------------------------
reg [23:0] s2_px;
reg        s2_pic;
always @(posedge clk) if (div == 2'd3) begin
	s2_pic <= s1_pic;
	s2_px  <= C_BG;
	if (s1_incol) begin
		if (s1_strip) s2_px <= s1_band ? C_MAG : C_PURP;
		if (s1_nadr) s2_px <= lamp(s1_la, s1_r2a);
		else if (s1_ndat) s2_px <= lamp(s1_ld, s1_r2d);
		else if (s1_nsta) s2_px <= lamp(s1_ls, s1_r2s);
		else if (s1_nsw) begin
			// switch paddle in its group colour; the lever end shows the position
			s2_px <= ( s1_sw && s1_swup) || (!s1_sw && s1_swdn) ? C_LEVER : (s1_band ? C_MAG : C_PURP);
		end
		else if (s1_nknb) s2_px <= lamp(s1_lk, s1_r2k);
		else if (s1_nctl) begin
			s2_px <= ( s1_ct && s1_ctup) || (!s1_ct && s1_ctdn) ? C_LEVER : (s1_ctlp ? C_PURP : C_MAG);
		end
	end
end

// ---- outputs: once per pixel; sync/blank exactly as the VT, picture from stage 2 ----
always @(posedge clk) begin
	ce_pix <= div[1];
	if (adv) begin
		hsync  <= !(col < 10'd96);
		vsync  <= !(row >= 10'd489 && row < 10'd491);
		hblank <= (col < 10'd96) || (row >= 10'd491);
		vblank <= 1'b0;
		{r, g, b} <= s2_pic ? s2_px : 24'h000000;
	end
end

endmodule
