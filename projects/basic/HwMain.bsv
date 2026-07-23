import FIFO::*;
import Vector::*;

import FloatingPoint::*;
import Sdram::*;

import SimpleMac::*;

typedef 6 BasicSdramWordCount;

Bit#(24) sdramSingleBase = 0;
Bit#(24) sdramBurstBase = 16;
Bit#(24) sdramWordCnt = fromInteger(valueOf(BasicSdramWordCount));
Bit#(3) sdramLastWordIdx = fromInteger(valueOf(BasicSdramWordCount) - 1);

typedef enum {
	RECEIVE_INPUT,
	WRITE_SINGLE_SDRAM,
	READ_SINGLE_SDRAM,
	WRITE_BURST_SDRAM,
	REQUEST_BURST_READ,
	READ_BURST_SDRAM,
	START_MAC,
	WAIT_MAC,
	SEND_OUTPUT
} BasicState deriving (Bits, Eq);

interface HwMainIfc;
	method ActionValue#(Bit#(8)) serial_tx;
	method Action serial_rx(Bit#(8) data);
endinterface

function Bit#(32) insertByte(Bit#(32) word, Bit#(2) byteIdx, Bit#(8) data);
	Vector#(4, Bit#(8)) bytes = unpack(word);
	bytes[byteIdx] = data;
	return pack(bytes);
endfunction

function Bit#(16) selectSdramWord(Bit#(3) wordIdx, Bit#(32) a, Bit#(32) b, Bit#(32) c);
	Bit#(16) word = 0;
	case ( wordIdx )
		0: word = truncate(a);
		1: word = truncate(a >> 16);
		2: word = truncate(b);
		3: word = truncate(b >> 16);
		4: word = truncate(c);
		5: word = truncate(c >> 16);
	endcase
	return word;
endfunction

function Bit#(8) selectOutputByte(
	Bit#(5) byteCnt,
	Bit#(32) singleA,
	Bit#(32) singleB,
	Bit#(32) singleC,
	Bit#(32) burstA,
	Bit#(32) burstB,
	Bit#(32) burstC,
	Bit#(32) result
);
	Bit#(32) word = 0;
	case ( byteCnt[4:2] )
		0: word = singleA;
		1: word = singleB;
		2: word = singleC;
		3: word = burstA;
		4: word = burstB;
		5: word = burstC;
		6: word = result;
	endcase
	Vector#(4, Bit#(8)) bytes = unpack(word);
	return bytes[byteCnt[1:0]];
endfunction

module mkHwMain#(Ulx3sSdramUserIfc mem) (HwMainIfc);
	FIFO#(Bit#(8)) serialRxQ <- mkFIFO;
	FIFO#(Bit#(8)) serialTxQ <- mkFIFO;
	SimpleMacIfc mac <- mkSimpleMac;

	Reg#(BasicState) state <- mkReg(RECEIVE_INPUT);
	Reg#(Bit#(4)) inputByteCnt <- mkReg(0);
	Reg#(Bit#(3)) singleWriteCnt <- mkReg(0);
	Reg#(Bit#(3)) singleReadReqCnt <- mkReg(0);
	Reg#(Bit#(3)) singleReadRespCnt <- mkReg(0);
	Reg#(Bit#(3)) burstWriteCnt <- mkReg(0);
	Reg#(Bit#(3)) burstReadRespCnt <- mkReg(0);
	Reg#(Bit#(5)) outputByteCnt <- mkReg(0);

	Reg#(Bit#(32)) inputA <- mkReg(0);
	Reg#(Bit#(32)) inputB <- mkReg(0);
	Reg#(Bit#(32)) inputC <- mkReg(0);
	Reg#(Bit#(32)) singleReadA <- mkReg(0);
	Reg#(Bit#(32)) singleReadB <- mkReg(0);
	Reg#(Bit#(32)) singleReadC <- mkReg(0);
	Reg#(Bit#(32)) burstReadA <- mkReg(0);
	Reg#(Bit#(32)) burstReadB <- mkReg(0);
	Reg#(Bit#(32)) burstReadC <- mkReg(0);
	Reg#(Bit#(32)) macResult <- mkReg(0);

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Receive three little-endian 32-bit floating-point values from UART
	//------------------------------------------------------------------------------------
	rule receiveInput ( state == RECEIVE_INPUT );
		let data = serialRxQ.first;
		serialRxQ.deq;

		Bit#(2) byteIdx = truncate(inputByteCnt);
		if ( inputByteCnt < 4 ) begin
			inputA <= insertByte(inputA, byteIdx, data);
		end else if ( inputByteCnt < 8 ) begin
			inputB <= insertByte(inputB, byteIdx, data);
		end else begin
			inputC <= insertByte(inputC, byteIdx, data);
		end

		if ( inputByteCnt == 11 ) begin
			inputByteCnt <= 0;
			singleWriteCnt <= 0;
			state <= WRITE_SINGLE_SDRAM;
		end else begin
			inputByteCnt <= inputByteCnt + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 2]
	// Exercise six BL1 writes and reads through the single-word request path
	//------------------------------------------------------------------------------------
	rule writeSingleSdram ( state == WRITE_SINGLE_SDRAM );
		let word = selectSdramWord(singleWriteCnt, inputA, inputB, inputC);
		mem.req(sdramSingleBase + zeroExtend(singleWriteCnt), word, True, 1);

		if ( singleWriteCnt == sdramLastWordIdx ) begin
			singleWriteCnt <= 0;
			singleReadReqCnt <= 0;
			singleReadRespCnt <= 0;
			singleReadA <= 0;
			singleReadB <= 0;
			singleReadC <= 0;
			state <= READ_SINGLE_SDRAM;
		end else begin
			singleWriteCnt <= singleWriteCnt + 1;
		end
	endrule

	rule requestSingleSdramRead (
		state == READ_SINGLE_SDRAM &&
		singleReadReqCnt < fromInteger(valueOf(BasicSdramWordCount))
	);
		mem.req(sdramSingleBase + zeroExtend(singleReadReqCnt), ?, False, 1);
		singleReadReqCnt <= singleReadReqCnt + 1;
	endrule

	rule receiveSingleSdramRead ( state == READ_SINGLE_SDRAM );
		let word <- mem.readResp;

		case ( singleReadRespCnt )
			0: singleReadA <= {singleReadA[31:16], word};
			1: singleReadA <= {word, singleReadA[15:0]};
			2: singleReadB <= {singleReadB[31:16], word};
			3: singleReadB <= {word, singleReadB[15:0]};
			4: singleReadC <= {singleReadC[31:16], word};
			5: singleReadC <= {word, singleReadC[15:0]};
		endcase

		if ( singleReadRespCnt == sdramLastWordIdx ) begin
			singleReadRespCnt <= 0;
			burstWriteCnt <= 0;
			burstReadA <= 0;
			burstReadB <= 0;
			burstReadC <= 0;
			state <= WRITE_BURST_SDRAM;
		end else begin
			singleReadRespCnt <= singleReadRespCnt + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 3]
	// Exercise one runtime-length six-word SDRAM burst write and burst read
	//------------------------------------------------------------------------------------
	rule writeBurstSdram ( state == WRITE_BURST_SDRAM );
		let word = selectSdramWord(burstWriteCnt, inputA, inputB, inputC);

		if ( burstWriteCnt == 0 ) begin
			// The first word travels with req(); the remaining words use the write stream.
			mem.req(sdramBurstBase, word, True, sdramWordCnt);
		end else begin
			mem.writeBurstData(word);
		end

		if ( burstWriteCnt == sdramLastWordIdx ) begin
			burstWriteCnt <= 0;
			state <= REQUEST_BURST_READ;
		end else begin
			burstWriteCnt <= burstWriteCnt + 1;
		end
	endrule

	rule requestBurstSdramRead ( state == REQUEST_BURST_READ );
		mem.req(sdramBurstBase, ?, False, sdramWordCnt);
		burstReadRespCnt <= 0;
		state <= READ_BURST_SDRAM;
	endrule

	rule receiveBurstSdramRead ( state == READ_BURST_SDRAM );
		let word <- mem.readResp;

		case ( burstReadRespCnt )
			0: burstReadA <= {burstReadA[31:16], word};
			1: burstReadA <= {word, burstReadA[15:0]};
			2: burstReadB <= {burstReadB[31:16], word};
			3: burstReadB <= {word, burstReadB[15:0]};
			4: burstReadC <= {burstReadC[31:16], word};
			5: burstReadC <= {word, burstReadC[15:0]};
		endcase

		if ( burstReadRespCnt == sdramLastWordIdx ) begin
			burstReadRespCnt <= 0;
			state <= START_MAC;
		end else begin
			burstReadRespCnt <= burstReadRespCnt + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 4]
	// Calculate A x B + C from the burst read-back values
	//------------------------------------------------------------------------------------
	rule startMac ( state == START_MAC );
		mac.put(unpack(burstReadA), unpack(burstReadB), unpack(burstReadC));
		state <= WAIT_MAC;
	endrule

	rule receiveMac ( state == WAIT_MAC );
		let result <- mac.get;
		macResult <= pack(result);
		outputByteCnt <= 0;
		state <= SEND_OUTPUT;
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 5]
	// Return BL1 read-back, burst read-back, and the MAC result
	//------------------------------------------------------------------------------------
	rule sendOutput ( state == SEND_OUTPUT );
		let data = selectOutputByte(
			outputByteCnt,
			singleReadA,
			singleReadB,
			singleReadC,
			burstReadA,
			burstReadB,
			burstReadC,
			macResult
		);
		serialTxQ.enq(data);

		if ( outputByteCnt == 27 ) begin
			outputByteCnt <= 0;
			inputA <= 0;
			inputB <= 0;
			inputC <= 0;
			singleReadA <= 0;
			singleReadB <= 0;
			singleReadC <= 0;
			burstReadA <= 0;
			burstReadB <= 0;
			burstReadC <= 0;
			state <= RECEIVE_INPUT;
		end else begin
			outputByteCnt <= outputByteCnt + 1;
		end
	endrule

	method ActionValue#(Bit#(8)) serial_tx;
		let data = serialTxQ.first;
		serialTxQ.deq;
		return data;
	endmethod

	method Action serial_rx(Bit#(8) data);
		serialRxQ.enq(data);
	endmethod
endmodule
