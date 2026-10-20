// tb_panel_view.sv -- render one frame of rtl/panel_view.sv to a PPM and check the timing
// Run from the repository root (the ROM is rtl/panel_art.hex):
//   mkdir -p sim/build_panel
//   iverilog -g2012 -o sim/build_panel/tb rtl/panel_view.sv sim/tb_panel_view.sv
//   vvp sim/build_panel/tb $(cat state.txt)
// with the live state as plusargs (hex): +addr= +data= +stat= +par= +sw= +ctl= +ka= +kd=,
// as tools/panel/mkpanel.py --state N --state-out state.txt writes them; then
//   mkpanel.py FONTDIR --state N --check sim/build_panel/panel.ppm
// compares the frame with the artwork's own rendering of that state.
`timescale 1ns/1ps
module tb_panel_view;
reg clk = 0, reset = 1;
always #5 clk = ~clk;
reg [21:0] addr_l = 0, sw = 0; reg [15:0] data_l = 0; reg [11:0] stat_l = 0;
reg [1:0] par_l = 0, knob_d = 0; reg [6:0] ctl = 0; reg [2:0] knob_a = 0;
wire ce, hs, vs, hb, vb; wire [7:0] r, g, b;
panel_view dut(.clk(clk), .reset(reset),
	.addr_l(addr_l), .data_l(data_l), .stat_l(stat_l), .par_l(par_l),
	.sw(sw), .ctl(ctl), .knob_a(knob_a), .knob_d(knob_d),
	.ce_pix(ce), .hsync(hs), .vsync(vs), .hblank(hb), .vblank(vb), .r(r), .g(g), .b(b));
integer f, n, frame, frame_px;
reg ce_d;
reg [7:0] img [0:640*480*3-1];
integer px, ln;
initial begin
	if ($value$plusargs("addr=%h", addr_l)) ; if ($value$plusargs("data=%h", data_l)) ;
	if ($value$plusargs("stat=%h", stat_l)) ; if ($value$plusargs("par=%h", par_l)) ;
	if ($value$plusargs("sw=%h", sw)) ;       if ($value$plusargs("ctl=%h", ctl)) ;
	if ($value$plusargs("ka=%h", knob_a)) ;   if ($value$plusargs("kd=%h", knob_d)) ;
	repeat (4) @(posedge clk); reset = 0;
	// capture the second whole frame (the first starts before the state is latched)
	for (frame = 0; frame < 2; frame = frame + 1) begin
		@(negedge vs); @(posedge vs);
		ln = 0; frame_px = 0;
		// sample once per pixel: on the clk after ce rises
		while (ln < 524) begin
			@(posedge clk); ce_d <= ce;
			if (ce && !ce_d) begin
				// column/row from the DUT counters, one pixel late (outputs are registered)
				if (dut.row < 480 && dut.col >= 145 && dut.col < 785) begin
					px = (dut.row * 640 + (dut.col - 145)) * 3;
					img[px] = r; img[px+1] = g; img[px+2] = b;
					if (r|g|b) frame_px = frame_px + 1;
				end
				if (dut.col == 799) ln = ln + 1;
			end
		end
	end
	f = $fopen("sim/build_panel/panel.ppm", "wb");
	$fwrite(f, "P6\n640 480\n255\n");
	for (n = 0; n < 640*480*3; n = n + 1) $fwrite(f, "%c", img[n]);
	$fclose(f);
	$display("tb_panel_view: frame rendered, %0d non-black pixels", frame_px);
	$finish;
end
// timing checks: ce high 2 of 4 clocks
integer ccnt = 0, chi = 0;
always @(posedge clk) begin
	ccnt <= ccnt + 1; if (ce) chi <= chi + 1;
end
final $display("tb_panel_view: ce duty %0d/%0d", chi, ccnt);
endmodule
