// Live host-CPU R7/IR/PSW/run plus console ADDR/DATA for the OSD
// front-panel banner. Claimed on EXT_BUS command 0x50 (UIO_PDP_PANEL).
// ARM discards the command beat, then reads R7, PSW, IR, flags,
// DATA (cons_shfr), ADDR (consoleaddr[15:0]).
//   flags[0] = module present
//   flags[1] = IR (*PC) word is valid
//   flags[2] = last examine was NXM
//   flags[3] = DATA/ADDR words follow
//   flags[15] = cons_run
module panel_dbg
(
	input             clk_sys,
	inout      [35:0] EXT_BUS,
	input      [15:0] r7,
	input      [15:0] ir,
	input      [15:0] psw,
	input             run,
	input      [15:0] data,
	input      [15:0] addr,
	input             nxm
);

wire [15:0] io_din    = EXT_BUS[31:16];
wire        io_strobe = EXT_BUS[33];
wire        io_enable = EXT_BUS[34];

reg  [15:0] io_dout;
reg         claimed;
assign EXT_BUS[15:0] = io_dout;
assign EXT_BUS[32]   = io_enable & claimed;

localparam [15:0] CMD = 16'h0050;

reg [15:0] r7_s1,  r7_s2;
reg [15:0] ir_s1,  ir_s2;
reg [15:0] psw_s1, psw_s2;
reg [15:0] data_s1, data_s2;
reg [15:0] addr_s1, addr_s2;
reg        run_s1, run_s2;
reg        nxm_s1, nxm_s2;

always @(posedge clk_sys) begin
	r7_s1   <= r7;    r7_s2   <= r7_s1;
	ir_s1   <= ir;    ir_s2   <= ir_s1;
	psw_s1  <= psw;   psw_s2  <= psw_s1;
	data_s1 <= data;  data_s2 <= data_s1;
	addr_s1 <= addr;  addr_s2 <= addr_s1;
	run_s1  <= run;   run_s2  <= run_s1;
	nxm_s1  <= nxm;   nxm_s2  <= nxm_s1;
end

reg [3:0] cnt;
wire [15:0] flags = {run_s2, 11'd0, 1'b1, nxm_s2, 1'b1, 1'b1};

always @(posedge clk_sys) begin
	if (~io_enable) begin
		cnt     <= 0;
		claimed <= 0;
		io_dout <= 0;
	end
	else if (io_strobe) begin
		if (cnt != 4'd15)
			cnt <= cnt + 1'd1;

		if (cnt == 0) begin
			if (io_din == CMD) begin
				claimed <= 1;
				io_dout <= flags;
			end
		end
		else if (claimed) begin
			case (cnt)
				4'd1: io_dout <= r7_s2;
				4'd2: io_dout <= psw_s2;
				4'd3: io_dout <= ir_s2;
				4'd4: io_dout <= flags;
				4'd5: io_dout <= data_s2;
				4'd6: io_dout <= addr_s2;
				default: io_dout <= flags;
			endcase
		end
	end
end

endmodule
