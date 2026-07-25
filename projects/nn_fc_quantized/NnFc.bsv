import FIFO::*;
import FIFOF::*;
import Vector::*;

import FloatingPoint::*;
import QuantizedMath::*;


typedef QInt16 QuantizedValue;
typedef QInt16Accumulator QuantizedAccumulator;

typedef 4 PeWaysLog;
typedef TExp#(PeWaysLog) PeWays;
typedef 1024 InputDim;
typedef 64 OutputDim;
typedef 8 QuantizedMetadataQueueDepth;


function Bool isSupportedQuantizedWidth(Bit#(5) width);
	return width == 4 || width == 8 || width == 16;
endfunction

function Float getQuantizationInverseScale(Bit#(5) width);
	if ( width == 4 ) begin
		return 0.5;
	end else if ( width == 16 ) begin
		return 1024.0;
	end else begin
		return 8.0;
	end
endfunction

function Float getOutputScale(Bit#(5) width);
	if ( width == 4 ) begin
		return 512.0;
	end else if ( width == 16 ) begin
		return 0.25;
	end else begin
		return 32.0;
	end
endfunction

function QuantizedValue saturateQuantizedValue(
	QuantizedValue value,
	Bit#(5) width
);
	Int#(96) valueExt = signExtend(value);

	if ( width == 4 ) begin
		return signExtend(saturateToInt4(valueExt));
	end else if ( width == 8 ) begin
		return signExtend(saturateToInt8(valueExt));
	end else begin
		return saturateToInt16(valueExt);
	end
endfunction

function QuantizedValue requantizeAccumulator(
	QuantizedAccumulator accumulator,
	Bit#(5) width
);
	if ( width == 4 ) begin
		QInt4Accumulator accumulatorInt4 = truncate(accumulator);
		return signExtend(requantizeInt4(accumulatorInt4, 1, 7, 0));
	end else if ( width == 8 ) begin
		QInt8Accumulator accumulatorInt8 = truncate(accumulator);
		return signExtend(requantizeInt8(accumulatorInt8, 1, 11, 0));
	end else begin
		return requantizeInt16(accumulator, 1, 18, 0);
	end
endfunction


interface MacPeIfc;
	method Action putInput(
		QuantizedValue value,
		Bit#(8) inputIdx,
		Bit#(5) width
	);
	method Action putWeight(QuantizedValue weight);
	method ActionValue#(Tuple4#(
		QuantizedValue,
		Bit#(8),
		Bit#(8),
		Bit#(5)
	)) resultGet;
	method Bool resultExist;
endinterface

module mkMacPe#(Bit#(PeWaysLog) peIdx) (MacPeIfc);
	FIFO#(QuantizedValue) weightQ <- mkFIFO;
	FIFO#(Tuple3#(QuantizedValue, Bit#(8), Bit#(5))) inputQ <- mkFIFO;
	FIFOF#(Tuple4#(QuantizedValue, Bit#(8), Bit#(8), Bit#(5))) outputQ <- mkFIFOF;

	FIFO#(QuantizedAccumulator) partialSumQ <- mkFIFO;
	FIFO#(Tuple4#(Bit#(8), Bit#(8), Bit#(16), Bit#(5))) macMetadataQ <- mkFIFO1;
	Int16MacIfc mac <- mkInt16Mac;

	Reg#(Bit#(8)) curOutputIdx <- mkReg(zeroExtend(peIdx));
	Reg#(Bit#(12)) curMacIdx <- mkReg(0);

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Issue one signed quantized MAC operation through the common INT16 datapath
	//------------------------------------------------------------------------------------
	rule processMac;
		inputQ.deq;
		weightQ.deq;

		let inputData = inputQ.first;
		let inputValue = tpl_1(inputData);
		let inputIdx = tpl_2(inputData);
		let width = tpl_3(inputData);
		let weight = weightQ.first;

		QuantizedAccumulator accumulator = 0;
		if ( curMacIdx != 0 ) begin
			partialSumQ.deq;
			accumulator = partialSumQ.first;
		end

		mac.put(inputValue, weight, accumulator);
		macMetadataQ.enq(tuple4(
			inputIdx,
			curOutputIdx,
			zeroExtend(curMacIdx),
			width
		));

		if ( curMacIdx + 1 >= fromInteger(valueOf(InputDim)) ) begin
			curMacIdx <= 0;
			let nextOutputIdx = curOutputIdx + fromInteger(valueOf(PeWays));
			if ( nextOutputIdx >= fromInteger(valueOf(OutputDim)) ) begin
				curOutputIdx <= zeroExtend(peIdx);
			end else begin
				curOutputIdx <= nextOutputIdx;
			end
		end else begin
			curMacIdx <= curMacIdx + 1;
		end
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 2]
	// Feed partial sums back or requantize a completed dot product
	//------------------------------------------------------------------------------------
	rule receiveMac;
		let accumulator <- mac.get;
		macMetadataQ.deq;
		let metadata = macMetadataQ.first;

		if ( tpl_3(metadata) + 1 == fromInteger(valueOf(InputDim)) ) begin
			let result = requantizeAccumulator(accumulator, tpl_4(metadata));
			outputQ.enq(tuple4(
				result,
				tpl_1(metadata),
				tpl_2(metadata),
				tpl_4(metadata)
			));
		end else begin
			partialSumQ.enq(accumulator);
		end
	endrule

	method Action putInput(
		QuantizedValue value,
		Bit#(8) inputIdx,
		Bit#(5) width
	);
		inputQ.enq(tuple3(value, inputIdx, width));
	endmethod

	method Action putWeight(QuantizedValue weight);
		weightQ.enq(weight);
	endmethod

	method ActionValue#(Tuple4#(
		QuantizedValue,
		Bit#(8),
		Bit#(8),
		Bit#(5)
	)) resultGet;
		outputQ.deq;
		return outputQ.first;
	endmethod

	method Bool resultExist;
		return outputQ.notEmpty;
	endmethod
endmodule


interface NnFcIfc;
	method Action setWidth(Bit#(5) width);
	method Action dataIn(Float value, Bit#(8) inputIdx);
	method Action weightIn(Float weight);
	method ActionValue#(Tuple3#(Float, Bit#(8), Bit#(8))) dataOut;
endinterface

(* synthesize *)
module mkNnFc(NnFcIfc);
	Vector#(PeWays, MacPeIfc) pes;
	Vector#(PeWays, FIFO#(QuantizedValue)) weightInQs <- replicateM(mkFIFO1);
	Vector#(PeWays, FIFO#(Tuple3#(QuantizedValue, Bit#(8), Bit#(5)))) dataInQs <-
		replicateM(mkFIFO1);
	Vector#(PeWays, FIFO#(Tuple4#(
		QuantizedValue,
		Bit#(8),
		Bit#(8),
		Bit#(5)
	))) resultOutQs <- replicateM(mkFIFO1);

	Reg#(Bit#(5)) quantizedWidth <- mkReg(8);

	FloatToInt16Ifc inputQuantizer <- mkFloatToInt16;
	FloatToInt16Ifc weightQuantizer <- mkFloatToInt16;
	Int16ToFloatIfc outputDequantizer <- mkInt16ToFloat;

	FIFO#(Tuple2#(Bit#(8), Bit#(5))) inputMetadataQ <-
		mkSizedFIFO(valueOf(QuantizedMetadataQueueDepth));
	FIFO#(Bit#(5)) weightMetadataQ <-
		mkSizedFIFO(valueOf(QuantizedMetadataQueueDepth));
	FIFO#(Tuple2#(Bit#(8), Bit#(8))) outputMetadataQ <-
		mkSizedFIFO(valueOf(QuantizedMetadataQueueDepth));
	FIFOF#(Tuple3#(Float, Bit#(8), Bit#(8))) outputQ <- mkFIFOF;

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Quantize each input and weight according to the Host-selected runtime width
	//------------------------------------------------------------------------------------
	rule relayQuantizedInput;
		let rawValue <- inputQuantizer.get;
		inputMetadataQ.deq;
		let metadata = inputMetadataQ.first;
		let value = saturateQuantizedValue(rawValue, tpl_2(metadata));
		dataInQs[0].enq(tuple3(value, tpl_1(metadata), tpl_2(metadata)));
	endrule

	rule relayQuantizedWeight;
		let rawWeight <- weightQuantizer.get;
		weightMetadataQ.deq;
		let width = weightMetadataQ.first;
		weightInQs[0].enq(saturateQuantizedValue(rawWeight, width));
	endrule

	//------------------------------------------------------------------------------------
	// [STAGE 2]
	// Forward quantized operands and results through the 16-PE array
	//------------------------------------------------------------------------------------
	for ( Integer i = 0; i < valueOf(PeWays); i = i + 1 ) begin
		pes[i] <- mkMacPe(fromInteger(i));

		Reg#(Bit#(16)) weightInIdx <- mkReg(0);

		rule forwardWeights;
			weightInQs[i].deq;
			let weight = weightInQs[i].first;

			if ( i < valueOf(PeWays) - 1 ) begin
				weightInQs[i + 1].enq(weight);
			end

			weightInIdx <= weightInIdx + 1;
			Bit#(PeWaysLog) target = truncate(weightInIdx);
			if ( target == fromInteger(i) ) begin
				pes[i].putWeight(weight);
			end
		endrule

		rule forwardInput;
			dataInQs[i].deq;
			let data = dataInQs[i].first;

			if ( i < valueOf(PeWays) - 1 ) begin
				dataInQs[i + 1].enq(data);
			end
			pes[i].putInput(tpl_1(data), tpl_2(data), tpl_3(data));
		endrule

		rule forwardResult;
			if ( pes[i].resultExist ) begin
				let data <- pes[i].resultGet;
				resultOutQs[i].enq(data);
			end else if ( i < valueOf(PeWays) - 1 ) begin
				resultOutQs[i + 1].deq;
				resultOutQs[i].enq(resultOutQs[i + 1].first);
			end
		endrule
	end

	//------------------------------------------------------------------------------------
	// [STAGE 3]
	// Dequantize completed FC outputs back to the original Float interface
	//------------------------------------------------------------------------------------
	rule startOutputDequantization;
		resultOutQs[0].deq;
		let data = resultOutQs[0].first;
		outputDequantizer.put(tpl_1(data), getOutputScale(tpl_4(data)), 0);
		outputMetadataQ.enq(tuple2(tpl_2(data), tpl_3(data)));
	endrule

	rule finishOutputDequantization;
		let value <- outputDequantizer.get;
		outputMetadataQ.deq;
		let metadata = outputMetadataQ.first;
		outputQ.enq(tuple3(value, tpl_1(metadata), tpl_2(metadata)));
	endrule

	method Action setWidth(Bit#(5) width);
		if ( isSupportedQuantizedWidth(width) ) begin
			quantizedWidth <= width;
		end
	endmethod

	method Action dataIn(Float value, Bit#(8) inputIdx);
		let width = quantizedWidth;
		inputQuantizer.put(value, getQuantizationInverseScale(width), 0);
		inputMetadataQ.enq(tuple2(inputIdx, width));
	endmethod

	method Action weightIn(Float weight);
		let width = quantizedWidth;
		weightQuantizer.put(weight, getQuantizationInverseScale(width), 0);
		weightMetadataQ.enq(width);
	endmethod

	method ActionValue#(Tuple3#(Float, Bit#(8), Bit#(8))) dataOut;
		outputQ.deq;
		return outputQ.first;
	endmethod
endmodule
