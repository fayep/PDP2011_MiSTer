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
// Inputs are levels; in step 1 pdp2011.sv feeds a demo pattern, later
// steps the CPU's console loom (paneldriver).
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

// distance from the column centre and from a row centre
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
wire near_adr = (dy_adr > -11'sd10) && (dy_adr < 11'sd10);
wire near_dat = (dy_dat > -11'sd10) && (dy_dat < 11'sd10);
wire near_sta = (dy_sta > -11'sd10) && (dy_sta < 11'sd10);
wire [7:0] r2_adr = sq(dx) + sq(dy_adr[6:0]);
wire [7:0] r2_dat = sq(dx) + sq(dy_dat[6:0]);
wire [7:0] r2_sta = sq(dx) + sq(dy_sta[6:0]);

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

wire [23:0] band = grp[0] ? C_MAG : C_PURP;

reg [23:0] px;
always @(*) begin
	px = C_BG;
	if (incol) begin
		// thin colour strip under each lamp row and behind the switches
		if ((y == Y_ADR + 10'd14) || (y == Y_DAT + 10'd14)) px = band;
		if (near_adr) px = lamp(addr_l[bitn], r2_adr);
		else if (near_dat && bitn < 5'd16) px = lamp(data_l[bitn], r2_dat);
		else if (near_sta && bitn < 5'd12) px = lamp(stat_l[bitn], r2_sta);
		else if ((dy_sw > -11'sd34) && (dy_sw < 11'sd34) && (cx >= 5'd5) && (cx <= 5'd20)) begin
			// switch paddle in its group colour; the lever end shows the position
			px = band;
			if (sw[bitn]  && (dy_sw < -11'sd14)) px = C_LEVER;
			if (!sw[bitn] && (dy_sw >  11'sd14)) px = C_LEVER;
		end
		else if (ci <= 5'd6 && (dy_ctl > -11'sd20) && (dy_ctl < 11'sd20) && (cx >= 5'd6) && (cx <= 5'd19)) begin
			px = (ci == 5'd4 || ci == 5'd5) ? C_PURP : C_MAG;   // ENABLE/HALT, S INST: latching
			if (ctl[3'd6 - ci[2:0]]  && (dy_ctl < -11'sd8)) px = C_LEVER;
			if (!ctl[3'd6 - ci[2:0]] && (dy_ctl >  11'sd8)) px = C_LEVER;
		end
	end
end

// ---- outputs: registered once per pixel, sync/blank exactly as the VT -----
always @(posedge clk) begin
	ce_pix <= div[1];
	if (adv) begin
		hsync  <= !(col < 10'd96);
		vsync  <= !(row >= 10'd489 && row < 10'd491);
		hblank <= (col < 10'd96) || (row >= 10'd491);
		vblank <= 1'b0;
		{r, g, b} <= pic ? px : 24'h000000;
	end
end

endmodule
