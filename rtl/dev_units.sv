// dev_units.sv -- per-unit "present" and "read-only" bits for the RK and RL controllers, set by
// MiSTer_pdp2011 from a device manifest (.inf) over UIO 0x5C. Lets an unmapped unit report
// "drive not present" and a protected unit report "write-protected", instead of serving zeros.
//
// UIO 0x5C, two words after the command:
//   word 1: RL  [3:0] present(0..3), [7:4] read-only(0..3)
//   word 2: RK  [7:0] present(0..7), [15:8] read-only(0..7)
// Defaults (before any write, and for a plain single .dsk) are "all present, none read-only",
// so the controllers behave exactly as before until a manifest says otherwise.
module dev_units
(
	input             clk_sys,
	inout      [35:0] EXT_BUS,

	output reg  [3:0] rl_present = 4'hF,
	output reg  [3:0] rl_ro      = 4'h0,
	output reg  [7:0] rk_present = 8'hFF,
	output reg  [7:0] rk_ro      = 8'h00
);

wire [15:0] io_din    = EXT_BUS[31:16];
wire        io_strobe = EXT_BUS[33];
wire        io_enable = EXT_BUS[34];

reg  [15:0] io_dout = 16'd0;
reg         claimed = 1'b0;
assign EXT_BUS[15:0] = claimed ? io_dout : 16'bz;
assign EXT_BUS[32]   = claimed ? (io_enable & claimed) : 1'bz;

localparam [15:0] CMD = 16'h005C;

reg [1:0] cnt = 2'd0;

always @(posedge clk_sys) begin
	if (~io_enable) begin
		cnt     <= 0;
		claimed <= 0;
		io_dout <= 0;
	end
	else if (io_strobe) begin
		if (cnt != 2'd3) cnt <= cnt + 2'd1;
		if (cnt == 0) begin
			if (io_din == CMD) begin claimed <= 1; io_dout <= 16'd1; end
		end
		else if (claimed) begin
			case (cnt)
				2'd1: begin rl_present <= io_din[3:0]; rl_ro <= io_din[7:4]; io_dout <= io_din; end
				2'd2: begin rk_present <= io_din[7:0]; rk_ro <= io_din[15:8]; io_dout <= io_din; end
				default: io_dout <= 16'd0;
			endcase
		end
	end
end

endmodule
