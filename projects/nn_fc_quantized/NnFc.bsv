import FIFO::*;
import FIFOF::*;
import Vector::*;

import FloatingPoint::*;
import QuantizedMath::*;


// INT16 is used only as the common transport container between runtime-selected
// quantizers, PE inputs, and result forwarding. Each PE executes the selected
// width through the matching QuantizedMath MAC module and accumulator type.
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
	FIFO#(Tuple3#(Bit#(8), Bit#(8), Bit#(16))) macInt4MetadataQ <- mkFIFO1;
	FIFO#(Tuple3#(Bit#(8), Bit#(8), Bit#(16))) macInt8MetadataQ <- mkFIFO1;
	FIFO#(Tuple3#(Bit#(8), Bit#(8), Bit#(16))) macInt16MetadataQ <- mkFIFO1;

	Int4MacIfc macInt4 <- mkInt4Mac;
	Int8MacIfc macInt8 <- mkInt8Mac;
	Int16MacIfc macInt16 <- mkInt16Mac;

	Reg#(Bit#(8)) curOutputIdx <- mkReg(zeroExtend(peIdx));
	Reg#(Bit#(12)) curMacIdx <- mkReg(0);

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Issue one signed MAC operation through the Host-selected QuantizedMath module
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

		let metadata = tuple3(inputIdx, curOutputIdx, zeroExtend(curMacIdx));
		if ( width == 4 ) begin
			QInt4Accumulator accumulatorInt4 = truncate(accumulator);
			macInt4.put(truncate(inputValue), truncate(weight), accumulatorInt4);
			macInt4MetadataQ.enq(metadata);
		end else if ( width == 8 ) begin
			QInt8Accumulator accumulatorInt8 = truncate(accumulator);
			macInt8.put(truncate(inputValue), truncate(weight), accumulatorInt8);
			macInt8MetadataQ.enq(metadata);
		end else begin
			macInt16.put(inputValue, weight, accumulator);
			macInt16MetadataQ.enq(metadata);
		end

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
	rule receiveMacInt4;
		let accumulator <- macInt4.get;
		macInt4MetadataQ.deq;
		let metadata = macInt4MetadataQ.first;

		if ( tpl_3(metadata) + 1 == fromInteger(valueOf(InputDim)) ) begin
			let result = requantizeInt4(accumulator, 1, 7, 0);
			outputQ.enq(tuple4(
				signExtend(result),
				tpl_1(metadata),
				tpl_2(metadata),
				4
			));
		end else begin
			partialSumQ.enq(signExtend(accumulator));
		end
	endrule

	rule receiveMacInt8;
		let accumulator <- macInt8.get;
		macInt8MetadataQ.deq;
		let metadata = macInt8MetadataQ.first;

		if ( tpl_3(metadata) + 1 == fromInteger(valueOf(InputDim)) ) begin
			let result = requantizeInt8(accumulator, 1, 11, 0);
			outputQ.enq(tuple4(
				signExtend(result),
				tpl_1(metadata),
				tpl_2(metadata),
				8
			));
		end else begin
			partialSumQ.enq(signExtend(accumulator));
		end
	endrule

	rule receiveMacInt16;
		let accumulator <- macInt16.get;
		macInt16MetadataQ.deq;
		let metadata = macInt16MetadataQ.first;

		if ( tpl_3(metadata) + 1 == fromInteger(valueOf(InputDim)) ) begin
			let result = requantizeInt16(accumulator, 1, 18, 0);
			outputQ.enq(tuple4(
				result,
				tpl_1(metadata),
				tpl_2(metadata),
				16
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

	FloatToInt4Ifc inputQuantizerInt4 <- mkFloatToInt4;
	FloatToInt8Ifc inputQuantizerInt8 <- mkFloatToInt8;
	FloatToInt16Ifc inputQuantizerInt16 <- mkFloatToInt16;
	FloatToInt4Ifc weightQuantizerInt4 <- mkFloatToInt4;
	FloatToInt8Ifc weightQuantizerInt8 <- mkFloatToInt8;
	FloatToInt16Ifc weightQuantizerInt16 <- mkFloatToInt16;

	Int4ToFloatIfc outputDequantizerInt4 <- mkInt4ToFloat;
	Int8ToFloatIfc outputDequantizerInt8 <- mkInt8ToFloat;
	Int16ToFloatIfc outputDequantizerInt16 <- mkInt16ToFloat;

	FIFO#(Bit#(8)) inputMetadataInt4Q <-
		mkSizedFIFO(valueOf(QuantizedMetadataQueueDepth));
	FIFO#(Bit#(8)) inputMetadataInt8Q <-
		mkSizedFIFO(valueOf(QuantizedMetadataQueueDepth));
	FIFO#(Bit#(8)) inputMetadataInt16Q <-
		mkSizedFIFO(valueOf(QuantizedMetadataQueueDepth));

	FIFO#(Tuple2#(Bit#(8), Bit#(8))) outputMetadataInt4Q <-
		mkSizedFIFO(valueOf(QuantizedMetadataQueueDepth));
	FIFO#(Tuple2#(Bit#(8), Bit#(8))) outputMetadataInt8Q <-
		mkSizedFIFO(valueOf(QuantizedMetadataQueueDepth));
	FIFO#(Tuple2#(Bit#(8), Bit#(8))) outputMetadataInt16Q <-
		mkSizedFIFO(valueOf(QuantizedMetadataQueueDepth));

	FIFOF#(Tuple3#(Float, Bit#(8), Bit#(8))) outputQ <- mkFIFOF;

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Relay the selected width from its dedicated quantization pipeline
	//------------------------------------------------------------------------------------
	rule relayQuantizedInputInt4;
		let value <- inputQuantizerInt4.get;
		inputMetadataInt4Q.deq;
		dataInQs[0].enq(tuple3(signExtend(value), inputMetadataInt4Q.first, 4));
	endrule

	rule relayQuantizedInputInt8;
		let value <- inputQuantizerInt8.get;
		inputMetadataInt8Q.deq;
		dataInQs[0].enq(tuple3(signExtend(value), inputMetadataInt8Q.first, 8));
	endrule

	rule relayQuantizedInputInt16;
		let value <- inputQuantizerInt16.get;
		inputMetadataInt16Q.deq;
		dataInQs[0].enq(tuple3(value, inputMetadataInt16Q.first, 16));
	endrule

	rule relayQuantizedWeightInt4;
		let weight <- weightQuantizerInt4.get;
		weightInQs[0].enq(signExtend(weight));
	endrule

	rule relayQuantizedWeightInt8;
		let weight <- weightQuantizerInt8.get;
		weightInQs[0].enq(signExtend(weight));
	endrule

	rule relayQuantizedWeightInt16;
		let weight <- weightQuantizerInt16.get;
		weightInQs[0].enq(weight);
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
	// Dequantize completed FC outputs through the selected conversion module
	//------------------------------------------------------------------------------------
	rule startOutputDequantizationInt4 ( tpl_4(resultOutQs[0].first) == 4 );
		resultOutQs[0].deq;
		let data = resultOutQs[0].first;
		outputDequantizerInt4.put(truncate(tpl_1(data)), getOutputScale(4), 0);
		outputMetadataInt4Q.enq(tuple2(tpl_2(data), tpl_3(data)));
	endrule

	rule startOutputDequantizationInt8 ( tpl_4(resultOutQs[0].first) == 8 );
		resultOutQs[0].deq;
		let data = resultOutQs[0].first;
		outputDequantizerInt8.put(truncate(tpl_1(data)), getOutputScale(8), 0);
		outputMetadataInt8Q.enq(tuple2(tpl_2(data), tpl_3(data)));
	endrule

	rule startOutputDequantizationInt16 ( tpl_4(resultOutQs[0].first) == 16 );
		resultOutQs[0].deq;
		let data = resultOutQs[0].first;
		outputDequantizerInt16.put(tpl_1(data), getOutputScale(16), 0);
		outputMetadataInt16Q.enq(tuple2(tpl_2(data), tpl_3(data)));
	endrule

	rule finishOutputDequantizationInt4;
		let value <- outputDequantizerInt4.get;
		outputMetadataInt4Q.deq;
		let metadata = outputMetadataInt4Q.first;
		outputQ.enq(tuple3(value, tpl_1(metadata), tpl_2(metadata)));
	endrule

	rule finishOutputDequantizationInt8;
		let value <- outputDequantizerInt8.get;
		outputMetadataInt8Q.deq;
		let metadata = outputMetadataInt8Q.first;
		outputQ.enq(tuple3(value, tpl_1(metadata), tpl_2(metadata)));
	endrule

	rule finishOutputDequantizationInt16;
		let value <- outputDequantizerInt16.get;
		outputMetadataInt16Q.deq;
		let metadata = outputMetadataInt16Q.first;
		outputQ.enq(tuple3(value, tpl_1(metadata), tpl_2(metadata)));
	endrule

	method Action setWidth(Bit#(5) width);
		if ( isSupportedQuantizedWidth(width) ) begin
			quantizedWidth <= width;
		end
	endmethod

	method Action dataIn(Float value, Bit#(8) inputIdx);
		let width = quantizedWidth;
		if ( width == 4 ) begin
			inputQuantizerInt4.put(value, getQuantizationInverseScale(4), 0);
			inputMetadataInt4Q.enq(inputIdx);
		end else if ( width == 8 ) begin
			inputQuantizerInt8.put(value, getQuantizationInverseScale(8), 0);
			inputMetadataInt8Q.enq(inputIdx);
		end else begin
			inputQuantizerInt16.put(value, getQuantizationInverseScale(16), 0);
			inputMetadataInt16Q.enq(inputIdx);
		end
	endmethod

	method Action weightIn(Float weight);
		let width = quantizedWidth;
		if ( width == 4 ) begin
			weightQuantizerInt4.put(weight, getQuantizationInverseScale(4), 0);
		end else if ( width == 8 ) begin
			weightQuantizerInt8.put(weight, getQuantizationInverseScale(8), 0);
		end else begin
			weightQuantizerInt16.put(weight, getQuantizationInverseScale(16), 0);
		end
	endmethod

	method ActionValue#(Tuple3#(Float, Bit#(8), Bit#(8))) dataOut;
		outputQ.deq;
		return outputQ.first;
	endmethod
endmodule
