// brk_dbg.sv -- lets the ARM side set a PC-compare breakpoint (see
// rtl/brk_compare.vhd). Claimed on EXT_BUS command 0x52 (UIO_PDP_BRK).
// Mirrors panel_dbg.sv/tracecap_dbg.sv's EXT_BUS idiom, but this one is
// a WRITE, not a stream-out: spi_w() is a genuine bidirectional
// transfer (the ARM's argument becomes io_din on the SAME cycle it
// reads back io_dout -- see spi.h's spi_w()), so the write protocol is
// just "send the CMD, then send the payload words" the same way a read
// protocol sends the CMD then reads the payload words.
//
// Protocol (ARM side): spi_uio_cmd_cont(UIO_PDP_BRK) [returns flags],
// then spi_w(enable) [bit0 = 1 to arm the breakpoint, 0 to disable],
// then spi_w(addr) [16-bit target PC value]. Return values of the
// payload words are the just-received value echoed back, for cheap
// confirmation -- not required, the write takes effect regardless.
//
// Motivation: this session's tracecap PAR5/6-stamp investigation found
// live ODT peek shows KDPAR5/KDPAR6 genuinely non-zero, but a full
// disk-event trace shows every event's stamped value as zero, with no
// way to build a small, controlled test case -- only "hope a disk
// event happens to coincide with the interesting moment in RSTS's
// MAPCOPY_PARAM". A PC-compare breakpoint lets real-hardware
// investigation halt exactly inside a routine instead.
module brk_dbg
(
	input             clk_sys,
	inout      [35:0] EXT_BUS,

	output reg [15:0] brk_cfg_addr,
	output reg        brk_cfg_enabled
);

wire [15:0] io_din    = EXT_BUS[31:16];
wire        io_strobe = EXT_BUS[33];
wire        io_enable = EXT_BUS[34];

reg  [15:0] io_dout;
reg         claimed;
// Tri-state when not claimed -- see panel_dbg.sv's matching fix; all
// EXT_BUS-claiming modules share the one wire, exactly one may drive
// real values at a time (hps_io.sv:189 selects on EXT_BUS[32]).
assign EXT_BUS[15:0] = claimed ? io_dout : 16'bz;
assign EXT_BUS[32]   = claimed ? (io_enable & claimed) : 1'bz;

localparam [15:0] CMD = 16'h0052;

reg [1:0] cnt;

wire [15:0] flags = {14'd0, brk_cfg_enabled, 1'b1};

always @(posedge clk_sys) begin
	if (~io_enable) begin
		cnt     <= 0;
		claimed <= 0;
		io_dout <= 0;
	end
	else if (io_strobe) begin
		if (cnt == 0) begin
			if (io_din == CMD) begin
				claimed <= 1;
				io_dout <= flags;
			end
			cnt <= cnt + 2'd1;
		end
		else if (claimed) begin
			case (cnt)
				2'd1: begin
					brk_cfg_enabled <= io_din[0];
					io_dout <= io_din;
				end
				2'd2: begin
					brk_cfg_addr <= io_din;
					io_dout <= io_din;
				end
				default: io_dout <= 16'd0;
			endcase
			if (cnt < 2'd2) cnt <= cnt + 2'd1;
		end
	end
end

endmodule
