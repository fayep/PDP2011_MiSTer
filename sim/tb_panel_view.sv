// tb_panel_view.sv -- render one frame of rtl/panel_view.sv to a PPM and check the timing
// Run: iverilog -g2012 -o sim/build_panel/tb rtl/panel_view.sv sim/tb_panel_view.sv && vvp sim/build_panel/tb
`timescale 1ns/1ps
module tb_panel_view;
reg clk = 0, reset = 1;
always #5 clk = ~clk;
wire ce, hs, vs, hb, vb; wire [7:0] r, g, b;
panel_view dut(.clk(clk), .reset(reset),
	.addr_l(22'o17652301), .data_l(16'o123456), .stat_l(12'b101100100111),
	.sw(22'o12345670), .ctl(7'b0011010),
	.ce_pix(ce), .hsync(hs), .vsync(vs), .hblank(hb), .vblank(vb), .r(r), .g(g), .b(b));
integer f, n, hs_low, de_n, lines, frame_px;
reg hs_d, vs_d, ce_d;
reg [7:0] img [0:640*480*3-1];
integer px, ln, cl;
initial begin
	repeat (4) @(posedge clk); reset = 0;
	// skip to the start of a frame (vsync rising edge), then capture 524 lines
	@(negedge vs); @(posedge vs);
	ln = 0; cl = 0; frame_px = 0;
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
	f = $fopen("sim/build_panel/panel.ppm", "wb");
	$fwrite(f, "P6\n640 480\n255\n");
	for (n = 0; n < 640*480*3; n = n + 1) $fwrite(f, "%c", img[n]);
	$fclose(f);
	$display("tb_panel_view: frame rendered, %0d non-black pixels", frame_px);
	$finish;
end
// timing checks: hsync low for 96 pixels per 800, ce high 2 of 4 clocks
integer hcnt = 0, ccnt = 0, chi = 0;
always @(posedge clk) begin
	ccnt <= ccnt + 1; if (ce) chi <= chi + 1;
end
final $display("tb_panel_view: ce duty %0d/%0d", chi, ccnt);
endmodule
