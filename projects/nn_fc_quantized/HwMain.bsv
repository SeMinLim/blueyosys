import FIFO::*;

import Sdram::*;

import NnFc::*;


typedef 64 InputCnt;
typedef 64 OutputDim;

typedef enum {
	COMPUTE_IDLE,
	COMPUTE_REQUEST_INPUT,
	COMPUTE_WAIT_INPUT,
	COMPUTE_REQUEST_WEIGHTS,
	COMPUTE_STREAM_WEIGHTS,
	COMPUTE_DONE
} ComputeState deriving (Eq, Bits);

typedef struct {
	Bool isWeight;
	Bit#(16) data;
} PackedWrite deriving (Eq, Bits);


Bit#(24) inputBaseAddress = 24'h010000;

function Bool isSupportedQuantizedWidth(Bit#(8) width);
	return width == 4 || width == 8 || width == 16;
endfunction

function Bit#(11) getGroupCnt(Bit#(5) width);
	if ( width == 4 ) begin
		return 256;
	end else if ( width == 8 ) begin
		return 512;
	end else begin
		return 1024;
	end
endfunction

function Bit#(17) getExpectedWeightWordCnt(Bit#(5) width);
	Bit#(17) groupCnt = zeroExtend(getGroupCnt(width));
	return groupCnt << 6;
endfunction

function Bit#(17) getExpectedInputWordCnt(Bit#(5) width);
	Bit#(17) groupCnt = zeroExtend(getGroupCnt(width));
	return groupCnt << 6;
endfunction

function Bit#(24) getWeightGroupAddress(Bit#(11) groupIdx);
	Bit#(24) groupIdxExt = zeroExtend(groupIdx);
	return groupIdxExt << 6;
endfunction


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
	Reg#(Bit#(5)) quantizedWidth <- mkReg(8);
	Reg#(Maybe#(Bit#(8))) dataDst <- mkReg(tagged Invalid);
	Reg#(Bit#(16)) dataBuffer <- mkReg(0);
	Reg#(Bit#(1)) dataBufferCnt <- mkReg(0);
	FIFO#(PackedWrite) memWriteQ <- mkFIFO;

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Receive runtime width followed by packed 16-bit weight and input words
	//------------------------------------------------------------------------------------
	rule receiveQuantizedWidth ( !widthConfigured );
		let width = serialRxQ.first;
		serialRxQ.deq;

		if ( isSupportedQuantizedWidth(width) ) begin
			quantizedWidth <= truncate(width);
			nn.setWidth(truncate(width));
			widthConfigured <= True;
			$write( "Configured runtime INT%d packed FC datapath\n", width );
		end else begin
			$write( "Unsupported quantized width %d\n", width );
		end
	endrule

	rule receiveDataDst ( widthConfigured && !isValid(dataDst) );
		let data = serialRxQ.first;
		serialRxQ.deq;
		dataDst <= tagged Valid data;
	endrule

	rule receivePackedWord ( widthConfigured && isValid(dataDst) );
		let data = serialRxQ.first;
		serialRxQ.deq;

		Bit#(16) nextData = (dataBuffer >> 8) | (zeroExtend(data) << 8);
		dataBuffer <= nextData;

		if ( dataBufferCnt == 1 ) begin
			let destination = fromMaybe(?, dataDst);
			dataBufferCnt <= 0;
			dataDst <= tagged Invalid;
			memWriteQ.enq(PackedWrite{
				isWeight: destination == 8'hff,
				data: nextData
			});
		end else begin
			dataBufferCnt <= dataBufferCnt + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 2]
	// Store group-major packed weights and input-major packed inputs in SDRAM
	//------------------------------------------------------------------------------------
	Reg#(Bit#(24)) weightWriteAddr <- mkReg(0);
	Reg#(Bit#(24)) inputWriteAddr <- mkReg(inputBaseAddress);
	Reg#(Bit#(17)) weightWriteCnt <- mkReg(0);
	Reg#(Bit#(17)) inputWriteCnt <- mkReg(0);
	Reg#(Bool) dataWriteDone <- mkReg(False);

	rule processMemWrite;
		memWriteQ.deq;
		let writeData = memWriteQ.first;

		if ( writeData.isWeight ) begin
			mem.req(weightWriteAddr, writeData.data, True, 1);
			weightWriteAddr <= weightWriteAddr + 1;
			weightWriteCnt <= weightWriteCnt + 1;
		end else begin
			mem.req(inputWriteAddr, writeData.data, True, 1);
			inputWriteAddr <= inputWriteAddr + 1;
			inputWriteCnt <= inputWriteCnt + 1;
		end
	endrule

	rule markDataReady (
		!dataWriteDone &&
		weightWriteCnt == getExpectedWeightWordCnt(quantizedWidth) &&
		inputWriteCnt == getExpectedInputWordCnt(quantizedWidth)
	);
		dataWriteDone <= True;
		$write(
			"Stored %d packed weight words and %d packed input words\n",
			weightWriteCnt,
			inputWriteCnt
		);
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 3]
	// Reuse one packed input word across a 64-word group-major SDRAM burst
	//------------------------------------------------------------------------------------
	Reg#(ComputeState) computeState <- mkReg(COMPUTE_IDLE);
	Reg#(Bit#(8)) computeInputIdx <- mkReg(0);
	Reg#(Bit#(11)) computeGroupIdx <- mkReg(0);
	Reg#(Bit#(8)) computeOutputIdx <- mkReg(0);
	Reg#(Bit#(24)) inputReadAddr <- mkReg(inputBaseAddress);
	Reg#(Bit#(16)) inputWordBuffer <- mkReg(0);

	rule startCompute ( dataWriteDone && computeState == COMPUTE_IDLE );
		computeInputIdx <= 0;
		computeGroupIdx <= 0;
		computeOutputIdx <= 0;
		inputReadAddr <= inputBaseAddress;
		computeState <= COMPUTE_REQUEST_INPUT;
	endrule

	rule requestInputWord ( computeState == COMPUTE_REQUEST_INPUT );
		mem.req(inputReadAddr, ?, False, 1);
		computeState <= COMPUTE_WAIT_INPUT;
	endrule

	rule receiveInputWord ( computeState == COMPUTE_WAIT_INPUT );
		let data <- mem.readResp;
		inputWordBuffer <= data;
		computeState <= COMPUTE_REQUEST_WEIGHTS;
	endrule

	rule requestWeightBurst ( computeState == COMPUTE_REQUEST_WEIGHTS );
		mem.req(
			getWeightGroupAddress(computeGroupIdx),
			?,
			False,
			fromInteger(valueOf(OutputDim))
		);
		computeOutputIdx <= 0;
		computeState <= COMPUTE_STREAM_WEIGHTS;
	endrule

	rule streamWeightBurst ( computeState == COMPUTE_STREAM_WEIGHTS );
		let weightWord <- mem.readResp;
		Bool firstGroup = computeGroupIdx == 0;
		Bool lastGroup = computeGroupIdx + 1 == getGroupCnt(quantizedWidth);

		nn.putPacked(
			inputWordBuffer,
			weightWord,
			computeInputIdx,
			truncate(computeOutputIdx),
			firstGroup,
			lastGroup
		);

		if ( computeOutputIdx + 1 == fromInteger(valueOf(OutputDim)) ) begin
			inputReadAddr <= inputReadAddr + 1;
			if ( lastGroup ) begin
				computeGroupIdx <= 0;
				if ( computeInputIdx + 1 == fromInteger(valueOf(InputCnt)) ) begin
					computeState <= COMPUTE_DONE;
					$write( "Finished issuing all packed FC operations\n" );
				end else begin
					computeInputIdx <= computeInputIdx + 1;
					computeState <= COMPUTE_REQUEST_INPUT;
				end
			end else begin
				computeGroupIdx <= computeGroupIdx + 1;
				computeState <= COMPUTE_REQUEST_INPUT;
			end
		end else begin
			computeOutputIdx <= computeOutputIdx + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 4]
	// Preserve nn_fc cycle reporting and six-byte result serialization
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
