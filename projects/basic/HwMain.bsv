import FIFO::*;
import Vector::*;

import FloatingPoint::*;
import Sdram::*;

import SimpleMac::*;

typedef enum {
	RECEIVE_INPUT,
	WRITE_SDRAM,
	READ_SDRAM,
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
	Bit#(4) byteCnt,
	Bit#(32) a,
	Bit#(32) b,
	Bit#(32) c,
	Bit#(32) result
);
	Bit#(32) word = 0;
	case ( byteCnt[3:2] )
		0: word = a;
		1: word = b;
		2: word = c;
		3: word = result;
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
	Reg#(Bit#(3)) sdramWriteCnt <- mkReg(0);
	Reg#(Bit#(3)) sdramReadReqCnt <- mkReg(0);
	Reg#(Bit#(3)) sdramReadRespCnt <- mkReg(0);
	Reg#(Bit#(4)) outputByteCnt <- mkReg(0);

	Reg#(Bit#(32)) inputA <- mkReg(0);
	Reg#(Bit#(32)) inputB <- mkReg(0);
	Reg#(Bit#(32)) inputC <- mkReg(0);
	Reg#(Bit#(32)) readA <- mkReg(0);
	Reg#(Bit#(32)) readB <- mkReg(0);
	Reg#(Bit#(32)) readC <- mkReg(0);
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
			sdramWriteCnt <= 0;
			state <= WRITE_SDRAM;
		end else begin
			inputByteCnt <= inputByteCnt + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 2]
	// Write A, B, and C to six consecutive 16-bit SDRAM words
	//------------------------------------------------------------------------------------
	rule writeSdram ( state == WRITE_SDRAM );
		let word = selectSdramWord(sdramWriteCnt, inputA, inputB, inputC);
		mem.req(zeroExtend(sdramWriteCnt), word, True, 1);

		if ( sdramWriteCnt == 5 ) begin
			sdramWriteCnt <= 0;
			sdramReadReqCnt <= 0;
			sdramReadRespCnt <= 0;
			readA <= 0;
			readB <= 0;
			readC <= 0;
			state <= READ_SDRAM;
		end else begin
			sdramWriteCnt <= sdramWriteCnt + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 3]
	// Read the same six SDRAM words and reconstruct A, B, and C
	//------------------------------------------------------------------------------------
	rule requestSdramRead ( state == READ_SDRAM && sdramReadReqCnt < 6 );
		mem.req(zeroExtend(sdramReadReqCnt), ?, False, 1);
		sdramReadReqCnt <= sdramReadReqCnt + 1;
	endrule

	rule receiveSdramRead ( state == READ_SDRAM );
		let word <- mem.readResp;

		case ( sdramReadRespCnt )
			0: readA <= {readA[31:16], word};
			1: readA <= {word, readA[15:0]};
			2: readB <= {readB[31:16], word};
			3: readB <= {word, readB[15:0]};
			4: readC <= {readC[31:16], word};
			5: readC <= {word, readC[15:0]};
		endcase

		if ( sdramReadRespCnt == 5 ) begin
			sdramReadRespCnt <= 0;
			state <= START_MAC;
		end else begin
			sdramReadRespCnt <= sdramReadRespCnt + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 4]
	// Calculate A x B + C with the SimpleFloat multiplier and adder pipelines
	//------------------------------------------------------------------------------------
	rule startMac ( state == START_MAC );
		mac.put(unpack(readA), unpack(readB), unpack(readC));
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
	// Return SDRAM read-back A, B, C, followed by the MAC result
	//------------------------------------------------------------------------------------
	rule sendOutput ( state == SEND_OUTPUT );
		let data = selectOutputByte(outputByteCnt, readA, readB, readC, macResult);
		serialTxQ.enq(data);

		if ( outputByteCnt == 15 ) begin
			outputByteCnt <= 0;
			inputA <= 0;
			inputB <= 0;
			inputC <= 0;
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
