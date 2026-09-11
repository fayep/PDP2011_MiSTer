// Streams the tracecap.vhd event ring buffer out to the ARM side over
// the SPI/UIO bridge, mirroring panel_dbg.sv's EXT_BUS command 0x50
// idiom. Claimed on EXT_BUS command 0x51 (UIO_PDP_TRACE). Deliberately
// independent of the PDP-11's own physical/UNIBUS address space --
// Faye: "keep this somewhat isolated from the PDP, like a BMC or
// Supervisor board".
//
// Read protocol (ARM side, mirrors panel.cpp's spi_uio_cmd_cont style --
// send CMD, then read words with repeated spi_w(0) calls):
//   word 0: flags -- bit0=module present, bit1=overflowed (sticky ring
//           wrap flag from tracecap.vhd)
//   word 1: wr_ptr -- current write position (== number of valid
//           entries, UNLESS bit1/overflowed is set, in which case the
//           buffer is full and every one of DEPTH entries is valid,
//           oldest-first starting at this same wr_ptr position)
//   word 2: reserved (always 0)
//   word 3+: one event per 12 words, in order:
//     w+0: {kind[3:0], id[3:0], 8'd0}
//     w+1: {10'd0, a[21:16]}       (a's high bits)
//     w+2: a[15:0]                 (a's low word)
//     w+3: {10'd0, b[21:16]}       (b's high bits)
//     w+4: b[15:0]                 (b's low word)
//     w+5: c[15:0]
//     w+6: d[63:48]                (disk events: KDPAR5, held-stable transaction snapshot)
//     w+7: d[47:32]                (disk events: KDPAR6, held-stable transaction snapshot)
//     w+8: d[31:16]                (disk events: KIPAR5 -- the pair RSTS's real overlay
//                                   mechanism actually uses, see tracecap_pkg.vhd)
//     w+9: d[15:0]                 (disk events: KIPAR6)
// Reading past wr_ptr entries (when not overflowed) returns whatever
// stale/undefined content is in that ring slot -- the ARM-side drain
// script's job is to stop at wr_ptr, not this module's.
module tracecap_dbg
(
	input             clk_sys,
	inout      [35:0] EXT_BUS,

	input             overflowed,
	input      [13:0] wr_ptr,     // must match tracecap.vhd's DEPTH_LOG2 (14)

	output reg [13:0] rd_addr,
	input      [3:0]  rd_kind,
	input      [3:0]  rd_id,
	input      [21:0] rd_a,
	input      [21:0] rd_b,
	input      [15:0] rd_c,
	input      [63:0] rd_d
);

wire [15:0] io_din    = EXT_BUS[31:16];
wire        io_strobe = EXT_BUS[33];
wire        io_enable = EXT_BUS[34];

reg  [15:0] io_dout;
reg         claimed;
// Tri-state when not claimed -- see panel_dbg.sv's matching fix; both
// modules share the one EXT_BUS wire, exactly one may drive real values
// at a time (hps_io.sv:189 selects on EXT_BUS[32]).
assign EXT_BUS[15:0] = claimed ? io_dout : 16'bz;
assign EXT_BUS[32]   = claimed ? (io_enable & claimed) : 1'bz;

localparam [15:0] CMD = 16'h0051;

// 3 header words + DEPTH(16384)*12 words/event = 196611 max -> needs 18 bits
reg [17:0] cnt;
reg [3:0]  word_in_event;

wire [15:0] flags = {14'd0, overflowed, 1'b1};

always @(posedge clk_sys) begin
	if (~io_enable) begin
		cnt           <= 0;
		word_in_event <= 0;
		claimed       <= 0;
		io_dout       <= 0;
		rd_addr       <= 0;
	end
	else if (io_strobe) begin
		if (cnt == 0) begin
			if (io_din == CMD) begin
				claimed       <= 1;
				io_dout       <= flags;
				rd_addr       <= 0;
				word_in_event <= 0;
			end
			cnt <= cnt + 1'd1;
		end
		else if (claimed) begin
			case (cnt)
				18'd1: io_dout <= {2'd0, wr_ptr};
				18'd2: io_dout <= 16'd0;
				default: begin
					case (word_in_event)
						4'd0: io_dout <= {rd_kind, rd_id, 8'd0};
						4'd1: io_dout <= {10'd0, rd_a[21:16]};
						4'd2: io_dout <= rd_a[15:0];
						4'd3: io_dout <= {10'd0, rd_b[21:16]};
						4'd4: io_dout <= rd_b[15:0];
						4'd5: io_dout <= rd_c;
						4'd6: io_dout <= rd_d[63:48];
						4'd7: io_dout <= rd_d[47:32];
						4'd8: io_dout <= rd_d[31:16];
						4'd9: io_dout <= rd_d[15:0];
					endcase
					if (word_in_event == 4'd9) begin
						word_in_event <= 0;
						rd_addr <= rd_addr + 1'd1;
					end
					else begin
						word_in_event <= word_in_event + 1'd1;
					end
				end
			endcase
			cnt <= cnt + 1'd1;
		end
	end
end

endmodule
