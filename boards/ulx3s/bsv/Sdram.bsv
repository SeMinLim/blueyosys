package Sdram;

import BRAMFIFO::*;
import FIFO::*;
import FIFOF::*;
import Vector::*;


// Command and address outputs are registered. Write beat 0 is driven in the
// following state so it is sampled with the corresponding WRITE command.

import "BDPI" function Action bdpiWriteSdram(Bit#(32) addr, Bit#(32) data);
import "BDPI" function ActionValue#(Bit#(32)) bdpiReadSdram(Bit#(32) addr);

typedef 512 SdramPageWords;
typedef 10 SdramStreamCountWidth;

typedef enum {
	SDRAM_SINGLE_READ,
	SDRAM_SINGLE_WRITE,
	SDRAM_BURST_READ,
	SDRAM_BURST_WRITE
} SdramRequestKind deriving (Eq, Bits);

typedef struct {
	SdramRequestKind kind;
	Bit#(24) address;
	Bit#(24) wordCnt;
	Bit#(16) data;
} SdramRequest deriving (Eq, Bits);

function Bit#(2) extract_bank_address(Bit#(24) data);
	return data[10:9];
endfunction

function Bool requestIsRead(SdramRequestKind kind);
	return kind == SDRAM_SINGLE_READ || kind == SDRAM_BURST_READ;
endfunction

function Bool requestUsesWriteStream(SdramRequestKind kind);
	return kind == SDRAM_BURST_WRITE;
endfunction

function Bit#(SdramStreamCountWidth) getPageWordCnt(
	Bit#(24) address,
	Bit#(24) wordCnt
);
	Bit#(SdramStreamCountWidth) pageWordCnt =
		fromInteger(valueOf(SdramPageWords)) - zeroExtend(address[8:0]);
	Bit#(24) pageWordCntExt = zeroExtend(pageWordCnt);
	return (wordCnt < pageWordCntExt)?truncate(wordCnt):pageWordCnt;
endfunction

function Bit#(24) getBurstAddress(
	Bit#(24) baseAddress,
	Bit#(SdramStreamCountWidth) beatCnt
);
	return baseAddress + zeroExtend(beatCnt);
endfunction

(* always_enabled, always_ready *)
interface Ulx3sSdramPinsIfc;
	//output sdram_csn,       // chip select
	(* prefix = "", result = "sdram_csn" *)
	method Bit#(1) sdram_csn();
	interface Clock sdram_clk;

	//output sdram_rasn,      // SDRAM RAS
	(* prefix = "", result = "sdram_rasn" *)
	method Bit#(1) sdram_rasn();

	//output sdram_casn,      // SDRAM CAS
	(* prefix = "", result = "sdram_casn" *)
	method Bit#(1) sdram_casn();

	//output sdram_wen,       // SDRAM write-enable
	(* prefix = "", result = "sdram_wen" *)
	method Bit#(1) sdram_wen();

	//output [12:0] sdram_a,  // SDRAM address bus
	(* prefix = "", result = "sdram_a" *)
	method Bit#(13) sdram_a();

	//output [1:0] sdram_ba,  // SDRAM bank-address
	(* prefix = "", result = "sdram_ba" *)
	method Bit#(2) sdram_ba();

	//output [1:0] sdram_dqm, // byte select
	(* prefix = "", result = "sdram_dqm" *)
	method Bit#(2) sdram_dqm();

	//inout [15:0] sdram_d,   // data bus to/from SDRAM
	(* prefix = "XX_sdram_d_XX" *)
	interface Inout#(Bit#(16)) sdram_d;
endinterface

interface Ulx3sSdramUserIfc;
	// wordCnt == 1 selects a single-word request. A larger count selects a
	// runtime-length full-page burst that is split automatically at page boundaries.
	// For a burst write, data is the first word and writeBurstData supplies the rest.
	method Action req(
		Bit#(24) addr,
		Bit#(16) data,
		Bool write,
		Bit#(24) wordCnt
	);

	// Additional burst-write words are consumed in request order. A page segment
	// starts only after enough data has been buffered for one word per SDRAM clock.
	method Action writeBurstData(Bit#(16) data);

	// A read request returns exactly wordCnt consecutive words through this method.
	method ActionValue#(Bit#(16)) readResp;
endinterface

interface Ulx3sSdramIfc;
`ifndef BSIM
	(* prefix="" *)
	interface Ulx3sSdramPinsIfc pins;
`endif
	interface Ulx3sSdramUserIfc user;
endinterface


typedef enum {
	IDLE,
	REFRESH1,
	REFRESH2,
	CONFIG,
	RDWR,
	READBURST,
	WRITEBURST,
	WRITETERMINATE,
	WAIT
} ControllerState deriving (Eq, Bits);

Bit#(4) command_NOP = 4'b1000;
Bit#(4) command_PRECHARGE = 4'b0001;
Bit#(4) command_AUTOREFRESH = 4'b0100;
Bit#(4) command_MODESET = 4'b0000;
Bit#(4) command_BURST_TERMINATE = 4'b0011;
Bit#(4) command_READ = 4'b0110;
Bit#(4) command_WRITE = 4'b0010;
Bit#(4) command_ACTIVATE = 4'b0101;

Bit#(4) delay_tRP = 3;
Bit#(4) delay_tMRD = 2;
Bit#(4) delay_tRCD = 3;
Bit#(4) delay_tRC = 9;
Bit#(4) delay_CL = 3;
Bit#(4) delay_tWR = 2;

// Mode-register fields: A9 write-burst mode, A6:A4 CAS latency,
// A3 sequential burst type, and A2:A0 full-page burst length.
Bit#(13) addr_MODE_FULL_PAGE = 13'b000_0_00_011_0_111;


module mkUlx3sSdram#(Clock sdram_clk, Integer clock_mhz) (Ulx3sSdramIfc);
	Clock curclk <- exposeCurrentClock;

	// A native x16 full-page segment contains at most 512 words. BRAM-backed
	// FIFOs reserve one complete segment so an active burst is never backpressured.
	FIFOF#(Bit#(16)) readRespQ <-
		mkSizedBRAMFIFOF(valueOf(SdramPageWords));
	FIFOF#(Bit#(16)) writeDataQ <-
		mkSizedBRAMFIFOF(valueOf(SdramPageWords));
	FIFOF#(SdramRequest) reqQ <- mkFIFOF;

	Integer init_cycles = 100 * clock_mhz;
	Integer rf_cycles = clock_mhz * 78 / 10;

	Reg#(Bit#(4)) command_out <- mkReg(command_NOP);
	// 11 during init, 00 after
	Reg#(Bit#(2)) dqm <- mkReg(2'b11);
	Reg#(Bit#(13)) addr_out <- mkReg(0);

	Reg#(ControllerState) state <- mkReg(IDLE);
	Reg#(ControllerState) state_next <- mkReg(IDLE);

`ifndef BSIM
	Inout16Ifc xx_inout16_XX <- mkInout16(curclk);
`endif

	Reg#(Bit#(16)) counter <- mkReg(0);
	// wait for chip to finish command
	Reg#(Bit#(4)) delay <- mkReg(0);

	Reg#(Bool) requestOn <- mkReg(False);
	Reg#(SdramRequestKind) curRequestKind <- mkReg(SDRAM_SINGLE_READ);
	Reg#(Bit#(24)) curAddress <- mkReg(0);
	Reg#(Bit#(24)) curWordCnt <- mkReg(0);
	Reg#(Bit#(16)) curFirstWriteData <- mkReg(0);
	Reg#(Bool) firstWriteDataOn <- mkReg(False);

	Reg#(Bit#(SdramStreamCountWidth)) segmentWordCnt <- mkReg(0);
	Reg#(Bit#(SdramStreamCountWidth)) segmentBeatCnt <- mkReg(0);
	Reg#(Bit#(SdramStreamCountWidth)) readTerminateCnt <- mkReg(0);
	Reg#(Bit#(4)) readLatencyCnt <- mkReg(0);

	// Producer and consumer counters expose exact FIFO occupancy without adding a
	// combinational count path through the BRAM-backed FIFOs.
	Reg#(Bit#(SdramStreamCountWidth)) readRespUp <- mkReg(0);
	Reg#(Bit#(SdramStreamCountWidth)) readRespDn <- mkReg(0);
	Reg#(Bit#(SdramStreamCountWidth)) writeDataUp <- mkReg(0);
	Reg#(Bit#(SdramStreamCountWidth)) writeDataDn <- mkReg(0);

	Reg#(Bit#(4)) open_bank <- mkReg(0);
	Reg#(Vector#(4, Bit#(13))) open_rows <- mkReg(replicate(0));

	// wait for SDRAM chip to init
	rule init ( dqm != 0 && state == IDLE );
		if ( counter + 1 >= fromInteger(init_cycles) ) begin
			counter <= 0;
			state <= REFRESH1;
		end else begin
			counter <= counter + 1;
		end
	endrule

	rule controllerFSM ( state != IDLE || dqm == 0 );
		// SDRAM commands are one-cycle strobes. During a native full-page burst,
		// NOP lets the SDRAM advance its internal column counter automatically.
		Bit#(4) nextCommand = command_NOP;

		// wait until we have to refresh again
		if ( state == REFRESH2 ) begin
			counter <= 0;
		end else begin
			counter <= counter + 1;
		end

		case ( state )
			IDLE: begin
				if ( counter >= fromInteger(rf_cycles) ) begin
					state <= REFRESH1;
				end else if ( !requestOn && reqQ.notEmpty ) begin
					let request = reqQ.first;
					reqQ.deq;

					curRequestKind <= request.kind;
					curAddress <= request.address;
					curWordCnt <= request.wordCnt;
					curFirstWriteData <= request.data;
					firstWriteDataOn <= request.kind == SDRAM_BURST_WRITE;
					requestOn <= True;
				end else if ( requestOn ) begin
					// Native full-page bursts cannot cross a page. Split a longer
					// linear request at each 512-word bank-row page boundary.
					Bit#(SdramStreamCountWidth) nextSegmentWordCnt =
						getPageWordCnt(curAddress, curWordCnt);
					Bit#(SdramStreamCountWidth) readWordsUsed =
						readRespUp - readRespDn;
					Bit#(SdramStreamCountWidth) writeWordsAvailable =
						writeDataUp - writeDataDn;
					Bit#(SdramStreamCountWidth) writeWordsRequired =
						nextSegmentWordCnt;
					if ( firstWriteDataOn ) begin
						writeWordsRequired = writeWordsRequired - 1;
					end
					Bit#(11) readWordsRequired = zeroExtend(readWordsUsed) +
						zeroExtend(nextSegmentWordCnt);

					Bool readSpaceReady = !requestIsRead(curRequestKind) ||
						(readWordsRequired <= fromInteger(valueOf(SdramPageWords)));
					Bool writeDataReady = !requestUsesWriteStream(curRequestKind) ||
						(writeWordsAvailable >= writeWordsRequired);

					if ( readSpaceReady && writeDataReady ) begin
						// Refresh before a long segment when starting it would cross the
						// nominal refresh interval. The active burst itself cannot pause.
						Bit#(16) transferCycleBudget =
							zeroExtend(nextSegmentWordCnt) +
							zeroExtend(delay_CL) + 8;

						if ( counter + transferCycleBudget >= fromInteger(rf_cycles) ) begin
							state <= REFRESH1;
						end else begin
							segmentWordCnt <= nextSegmentWordCnt;
							segmentBeatCnt <= 0;
							state <= RDWR;
						end
					end
				end
			end
			RDWR: begin
				Bit#(2) bank = extract_bank_address(curAddress);
				Bit#(13) row = curAddress[23:11];
				Bit#(9) col = curAddress[8:0];
				Bool isRead = requestIsRead(curRequestKind);

				if ( open_bank[bank] == 0 ) begin
					nextCommand = command_ACTIVATE;
					addr_out <= row;
					open_bank[bank] <= 1;
					open_rows[bank] <= row;
					delay <= delay_tRCD - 2;
					state_next <= RDWR;
					state <= WAIT;
				end else if ( open_rows[bank] != row ) begin
					nextCommand = command_PRECHARGE;
					addr_out[10] <= 0;
					open_bank[bank] <= 0;
					delay <= delay_tRP - 2;
					state_next <= RDWR;
					state <= WAIT;
				end else begin
					nextCommand = isRead ? command_READ : command_WRITE;
					addr_out <= {0, col};
					segmentBeatCnt <= 0;

					if ( isRead ) begin
						// BURST TERMINATE is issued segmentWordCnt cycles after READ.
						// With CL3 this is two clocks before the last requested data beat.
						readTerminateCnt <= segmentWordCnt;
						readLatencyCnt <= delay_CL;
						state <= READBURST;
					end else begin
						// Beat 0 is driven in WRITEBURST one cycle after command_out is
						// registered, so the WRITE command and first data word align.
						state <= WRITEBURST;
					end
				end
			end
			READBURST: begin
				// Full-page READ does not self-terminate. Issue BURST TERMINATE
				// early enough that the final pipelined data word still arrives.
				if ( readTerminateCnt != 0 ) begin
					if ( readTerminateCnt == 1 ) begin
						nextCommand = command_BURST_TERMINATE;
					end
					readTerminateCnt <= readTerminateCnt - 1;
				end

				if ( readLatencyCnt != 0 ) begin
					readLatencyCnt <= readLatencyCnt - 1;
				end else begin
					Bit#(16) data = 0;
`ifndef BSIM
					data = xx_inout16_XX.read;
`else
					let readData <- bdpiReadSdram(
						zeroExtend(getBurstAddress(curAddress, segmentBeatCnt))
					);
					data = truncate(readData);
`endif
					readRespQ.enq(data);
					readRespUp <= readRespUp + 1;

					if ( segmentBeatCnt + 1 == segmentWordCnt ) begin
						Bit#(24) completedWordCnt = zeroExtend(segmentWordCnt);
						curAddress <= curAddress + completedWordCnt;
						curWordCnt <= curWordCnt - completedWordCnt;
						if ( curWordCnt == completedWordCnt ) begin
							requestOn <= False;
						end
						state <= IDLE;
					end else begin
						segmentBeatCnt <= segmentBeatCnt + 1;
					end
				end
			end
			WRITEBURST: begin
				// Full-page WRITE accepts one word per clock after the initial
				// command. No additional WRITE command is issued inside a segment.
				Bit#(16) data = curFirstWriteData;
				if ( firstWriteDataOn ) begin
					firstWriteDataOn <= False;
				end else if ( requestUsesWriteStream(curRequestKind) ) begin
					data = writeDataQ.first;
					writeDataQ.deq;
					writeDataDn <= writeDataDn + 1;
				end

`ifndef BSIM
				xx_inout16_XX.write(data);
`else
				bdpiWriteSdram(
					zeroExtend(getBurstAddress(curAddress, segmentBeatCnt)),
					zeroExtend(data)
				);
`endif
				if ( segmentBeatCnt + 1 == segmentWordCnt ) begin
					// Data coincident with BURST TERMINATE is ignored by SDRAM, so
					// terminate one clock after driving the final requested word.
					nextCommand = command_BURST_TERMINATE;
					state <= WRITETERMINATE;
				end else begin
					segmentBeatCnt <= segmentBeatCnt + 1;
				end
			end
			WRITETERMINATE: begin
				Bit#(24) completedWordCnt = zeroExtend(segmentWordCnt);
				curAddress <= curAddress + completedWordCnt;
				curWordCnt <= curWordCnt - completedWordCnt;
				if ( curWordCnt == completedWordCnt ) begin
					requestOn <= False;
				end

				// Preserve tWR before a later page transition can precharge this bank.
				delay <= delay_tWR;
				state_next <= IDLE;
				state <= WAIT;
			end
			REFRESH1: begin
				nextCommand = command_PRECHARGE;
				delay <= delay_tRP - 2;
				addr_out[10] <= 1;
				open_bank <= 0;
				if ( dqm != 0 ) begin
					state_next <= CONFIG;
				end else begin
					state_next <= REFRESH2;
				end
				state <= WAIT;
			end
			REFRESH2: begin
				nextCommand = command_AUTOREFRESH;
				dqm <= 0;
				delay <= delay_tRC - 2;

				if ( dqm != 0 ) begin
					state_next <= REFRESH2;
				end else begin
					state_next <= IDLE;
				end
				state <= WAIT;
			end
			CONFIG: begin
				// Full-page sequential mode supports a runtime word count. Every
				// shorter transfer is explicitly stopped with BURST TERMINATE.
				nextCommand = command_MODESET;
				addr_out <= addr_MODE_FULL_PAGE;
				delay <= delay_tMRD - 2;
				state_next <= REFRESH2;
				state <= WAIT;
			end
			WAIT: begin
				if ( delay != 0 ) begin
					delay <= delay - 1;
				end else begin
					state <= state_next;
				end
			end
		endcase

		command_out <= nextCommand;
	endrule


`ifndef BSIM
	interface Ulx3sSdramPinsIfc pins;
		interface sdram_clk = sdram_clk;
		method Bit#(1) sdram_csn();
			return command_out[3];
		endmethod
		method Bit#(1) sdram_wen();
			return command_out[2];
		endmethod
		method Bit#(1) sdram_rasn();
			return command_out[1];
		endmethod
		method Bit#(1) sdram_casn();
			return command_out[0];
		endmethod
		method Bit#(2) sdram_dqm();
			return dqm;
		endmethod
		method Bit#(13) sdram_a();
			return addr_out;
		endmethod
		method Bit#(2) sdram_ba();
			Bit#(2) bank = extract_bank_address(curAddress);

			// command_out reflects the command currently visible to SDRAM, while
			// state may already be WAIT because command registers update together.
			if ( command_out == command_MODESET ) begin
				return 0;
			end else begin
				return bank;
			end
		endmethod
		interface sdram_d = xx_inout16_XX.inout_pins;
	endinterface
`endif

	interface Ulx3sSdramUserIfc user;
		method Action req(
			Bit#(24) addr,
			Bit#(16) data,
			Bool write,
			Bit#(24) wordCnt
		);
			if ( wordCnt != 0 ) begin
				SdramRequestKind kind = write
					? ((wordCnt == 1) ? SDRAM_SINGLE_WRITE : SDRAM_BURST_WRITE)
					: ((wordCnt == 1) ? SDRAM_SINGLE_READ : SDRAM_BURST_READ);
				reqQ.enq(SdramRequest{
					kind: kind,
					address: addr,
					wordCnt: wordCnt,
					data: data
				});
			end
		endmethod
		method Action writeBurstData(Bit#(16) data);
			writeDataQ.enq(data);
			writeDataUp <= writeDataUp + 1;
		endmethod
		method ActionValue#(Bit#(16)) readResp;
			readRespQ.deq;
			readRespDn <= readRespDn + 1;
			return readRespQ.first;
		endmethod
	endinterface
endmodule

interface Inout16Ifc;
	interface Inout#(Bit#(16)) inout_pins;

	method Action write(Bit#(16) data);
	method Bit#(16) read;
endinterface

import "BVI" inout16 =
module mkInout16#(Clock curclk) (Inout16Ifc);
	default_clock no_clock;
	default_reset no_reset;
	
	input_clock (clk) = curclk;

	ifc_inout inout_pins(inout_pins);

	method write(write_data) enable(write_req) clocked_by(curclk);
	method read_data read;

	schedule (
		write, read
	) CF (
		write, read
	);
endmodule

endpackage: Sdram
