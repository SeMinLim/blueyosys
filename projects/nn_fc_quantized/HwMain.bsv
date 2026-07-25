import FIFO::*;

import Sdram::*;

import NnFc::*;


interface HwMainIfc;
	method ActionValue#(Bit#(8)) serial_tx;
	method Action serial_rx(Bit#(8) data);
endinterface

module mkHwMain#(Ulx3sSdramUserIfc mem) (HwMainIfc);
	Reg#(Bit#(32)) cycleCount <- mkReg(0);
	rule incCycleCount;
		cycleCount <= cycleCount + 1;
	endrule

	FIFO#(Bit#(8)) serialRxQ <- mkFIFO;
	FIFO#(Bit#(8)) serialTxQ <- mkFIFO;

	NnFcIfc nn <- mkNnFc;

	Reg#(Bool) widthConfigured <- mkReg(False);
	Reg#(Maybe#(Bit#(8))) inputDst <- mkReg(tagged Invalid);
	Reg#(Bit#(32)) inputBuffer <- mkReg(0);
	Reg#(Bit#(2)) inputBufferCnt <- mkReg(0);
	Reg#(Bool) memWriteDone <- mkReg(False);
	FIFO#(Bit#(32)) memWriteQ <- mkFIFO;

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Receive the runtime quantized width before the original nn_fc UART stream
	//------------------------------------------------------------------------------------
	rule receiveQuantizedWidth ( !widthConfigured );
		let width = serialRxQ.first;
		serialRxQ.deq;

		if ( width == 4 || width == 8 || width == 16 ) begin
			nn.setWidth(truncate(width));
			widthConfigured <= True;
			$write( "Configured runtime INT%d FC datapath\n", width );
		end else begin
			$write( "Unsupported quantized width %d\n", width );
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 2]
	// Receive the original nn_fc UART stream of Float weights and inputs
	//------------------------------------------------------------------------------------
	rule receiveInputDst ( widthConfigured && !isValid(inputDst) );
		let data = serialRxQ.first;
		serialRxQ.deq;
		inputDst <= tagged Valid data;
	endrule

	rule receiveInputFloat ( widthConfigured && isValid(inputDst) );
		let data = serialRxQ.first;
		serialRxQ.deq;

		Bit#(32) nextValue = (inputBuffer >> 8) | (zeroExtend(data) << 24);
		inputBuffer <= nextValue;

		if ( inputBufferCnt == 3 ) begin
			inputBufferCnt <= 0;
			inputDst <= tagged Invalid;
			let id = fromMaybe(?, inputDst);

			if ( id != 8'hff ) begin
				nn.dataIn(unpack(nextValue), id);
				memWriteDone <= True;
			end else begin
				memWriteQ.enq(nextValue);
			end
		end else begin
			inputBufferCnt <= inputBufferCnt + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 3]
	// Store Float weights in SDRAM and stream them back to the quantized FC core
	//------------------------------------------------------------------------------------
	Reg#(Maybe#(Bit#(16))) memWriteBuffer <- mkReg(tagged Invalid);
	Reg#(Bit#(24)) memWriteAddr <- mkReg(0);

	rule processMemWrite;
		if ( isValid(memWriteBuffer) ) begin
			memWriteBuffer <= tagged Invalid;
			mem.req(memWriteAddr, fromMaybe(?, memWriteBuffer), True, 1);
		end else begin
			memWriteQ.deq;
			let data = memWriteQ.first;
			mem.req(memWriteAddr, truncate(data), True, 1);
			memWriteBuffer <= tagged Valid truncate(data >> 16);
		end
		memWriteAddr <= memWriteAddr + 1;
	endrule

	Reg#(Bit#(24)) memReadAddr <- mkReg(0);
	(* descending_urgency = "processMemWrite, processMemRead" *)
	rule processMemRead ( memWriteDone );
		if ( memReadAddr + 1 == memWriteAddr ) begin
			memReadAddr <= 0;
		end else begin
			memReadAddr <= memReadAddr + 1;
		end
		mem.req(memReadAddr, ?, False, 1);
	endrule

	Reg#(Maybe#(Bit#(16))) memReadBuffer <- mkReg(tagged Invalid);
	rule processMemReadResponse;
		let data <- mem.readResp;
		if ( isValid(memReadBuffer) ) begin
			nn.weightIn(unpack({data, fromMaybe(?, memReadBuffer)}));
			memReadBuffer <= tagged Invalid;
		end else begin
			memReadBuffer <= tagged Valid data;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 4]
	// Preserve the nn_fc result format: input index, output index, and Float value
	//------------------------------------------------------------------------------------
	Reg#(Bit#(40)) outputBuffer <- mkReg(0);
	Reg#(Bit#(3)) outputBufferCnt <- mkReg(0);
	Reg#(Bit#(32)) resultDataCnt <- mkReg(0);
	Reg#(Bit#(32)) lastCycle <- mkReg(0);
	Reg#(Bit#(32)) lastEmitted <- mkReg(0);

	rule serializeOutput;
		if ( outputBufferCnt > 0 ) begin
			outputBufferCnt <= outputBufferCnt - 1;
			serialTxQ.enq(truncate(outputBuffer));
			outputBuffer <= outputBuffer >> 8;
		end else begin
			if ( resultDataCnt == 0 ) begin
				lastCycle <= cycleCount;
				lastEmitted <= resultDataCnt;
			end else if ( ((resultDataCnt + 1) & 32'hff) == 0 ) begin
				$write(
					"Emitting %d elements over %d cycles\n",
					resultDataCnt - lastEmitted,
					cycleCount - lastCycle
				);
				lastCycle <= cycleCount;
				lastEmitted <= resultDataCnt;
			end

			resultDataCnt <= resultDataCnt + 1;
			let result <- nn.dataOut;
			serialTxQ.enq(tpl_2(result));
			outputBuffer <= {pack(tpl_1(result)), tpl_3(result)};
			outputBufferCnt <= 5;
		end
	endrule

	method ActionValue#(Bit#(8)) serial_tx;
		serialTxQ.deq;
		return serialTxQ.first;
	endmethod

	method Action serial_rx(Bit#(8) data);
		serialRxQ.enq(data);
	endmethod
endmodule
