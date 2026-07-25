import FIFO::*;
import FIFOF::*;
import Vector::*;

import FloatingPoint::*;
import QuantizedMath::*;


`ifdef NN_FC_QINT4
typedef QInt4 QuantizedValue;
typedef QInt4Accumulator QuantizedAccumulator;
`elsif NN_FC_QINT16
typedef QInt16 QuantizedValue;
typedef QInt16Accumulator QuantizedAccumulator;
`else
typedef QInt8 QuantizedValue;
typedef QInt8Accumulator QuantizedAccumulator;
`endif

typedef 4 PeWaysLog;
typedef TExp#(PeWaysLog) PeWays;
typedef 1024 InputDim;
typedef 64 OutputDim;
typedef 8 QuantizedMetadataQueueDepth;


function Float getQuantizationInverseScale();
`ifdef NN_FC_QINT4
	return 0.5;
`elsif NN_FC_QINT16
	return 1024.0;
`else
	return 8.0;
`endif
endfunction

function Float getOutputScale();
`ifdef NN_FC_QINT4
	return 512.0;
`elsif NN_FC_QINT16
	return 0.25;
`else
	return 32.0;
`endif
endfunction

function QuantizedValue requantizeAccumulator(QuantizedAccumulator accumulator);
`ifdef NN_FC_QINT4
	return requantizeInt4(accumulator, 1, 7, 0);
`elsif NN_FC_QINT16
	return requantizeInt16(accumulator, 1, 18, 0);
`else
	return requantizeInt8(accumulator, 1, 11, 0);
`endif
endfunction


interface MacPeIfc;
	method Action putInput(QuantizedValue value, Bit#(8) inputIdx);
	method Action putWeight(QuantizedValue weight);
	method ActionValue#(Tuple3#(QuantizedValue, Bit#(8), Bit#(8))) resultGet;
	method Bool resultExist;
endinterface

module mkMacPe#(Bit#(PeWaysLog) peIdx) (MacPeIfc);
	FIFO#(QuantizedValue) weightQ <- mkFIFO;
	FIFO#(Tuple2#(QuantizedValue, Bit#(8))) inputQ <- mkFIFO;
	FIFOF#(Tuple3#(QuantizedValue, Bit#(8), Bit#(8))) outputQ <- mkFIFOF;

	FIFO#(QuantizedAccumulator) partialSumQ <- mkFIFO;
	FIFO#(Tuple3#(Bit#(8), Bit#(8), Bit#(16))) macMetadataQ <- mkFIFO1;

`ifdef NN_FC_QINT4
	Int4MacIfc mac <- mkInt4Mac;
`elsif NN_FC_QINT16
	Int16MacIfc mac <- mkInt16Mac;
`else
	Int8MacIfc mac <- mkInt8Mac;
`endif

	Reg#(Bit#(8)) curOutputIdx <- mkReg(zeroExtend(peIdx));
	Reg#(Bit#(12)) curMacIdx <- mkReg(0);

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Issue one signed quantized MAC operation
	//------------------------------------------------------------------------------------
	rule processMac;
		inputQ.deq;
		weightQ.deq;

		let inputValue = tpl_1(inputQ.first);
		let inputIdx = tpl_2(inputQ.first);
		let weight = weightQ.first;

		QuantizedAccumulator accumulator = 0;
		if ( curMacIdx != 0 ) begin
			partialSumQ.deq;
			accumulator = partialSumQ.first;
		end

		mac.put(inputValue, weight, accumulator);
		macMetadataQ.enq(tuple3(inputIdx, curOutputIdx, zeroExtend(curMacIdx)));

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
			let result = requantizeAccumulator(accumulator);
			outputQ.enq(tuple3(result, tpl_1(metadata), tpl_2(metadata)));
		end else begin
			partialSumQ.enq(accumulator);
		end
	endrule

	method Action putInput(QuantizedValue value, Bit#(8) inputIdx);
		inputQ.enq(tuple2(value, inputIdx));
	endmethod

	method Action putWeight(QuantizedValue weight);
		weightQ.enq(weight);
	endmethod

	method ActionValue#(Tuple3#(QuantizedValue, Bit#(8), Bit#(8))) resultGet;
		outputQ.deq;
		return outputQ.first;
	endmethod

	method Bool resultExist;
		return outputQ.notEmpty;
	endmethod
endmodule


interface NnFcIfc;
	method Action dataIn(Float value, Bit#(8) inputIdx);
	method Action weightIn(Float weight);
	method ActionValue#(Tuple3#(Float, Bit#(8), Bit#(8))) dataOut;
endinterface

(* synthesize *)
module mkNnFc(NnFcIfc);
	Vector#(PeWays, MacPeIfc) pes;
	Vector#(PeWays, FIFO#(QuantizedValue)) weightInQs <- replicateM(mkFIFO1);
	Vector#(PeWays, FIFO#(Tuple2#(QuantizedValue, Bit#(8)))) dataInQs <- replicateM(mkFIFO1);
	Vector#(PeWays, FIFO#(Tuple3#(QuantizedValue, Bit#(8), Bit#(8)))) resultOutQs <-
		replicateM(mkFIFO1);

`ifdef NN_FC_QINT4
	FloatToInt4Ifc inputQuantizer <- mkFloatToInt4;
	FloatToInt4Ifc weightQuantizer <- mkFloatToInt4;
	Int4ToFloatIfc outputDequantizer <- mkInt4ToFloat;
`elsif NN_FC_QINT16
	FloatToInt16Ifc inputQuantizer <- mkFloatToInt16;
	FloatToInt16Ifc weightQuantizer <- mkFloatToInt16;
	Int16ToFloatIfc outputDequantizer <- mkInt16ToFloat;
`else
	FloatToInt8Ifc inputQuantizer <- mkFloatToInt8;
	FloatToInt8Ifc weightQuantizer <- mkFloatToInt8;
	Int8ToFloatIfc outputDequantizer <- mkInt8ToFloat;
`endif

	FIFO#(Bit#(8)) inputMetadataQ <-
		mkSizedFIFO(valueOf(QuantizedMetadataQueueDepth));
	FIFO#(Tuple2#(Bit#(8), Bit#(8))) outputMetadataQ <-
		mkSizedFIFO(valueOf(QuantizedMetadataQueueDepth));
	FIFOF#(Tuple3#(Float, Bit#(8), Bit#(8))) outputQ <- mkFIFOF;

	//------------------------------------------------------------------------------------
	// [STAGE 1]
	// Quantize each input and weight once before PE distribution
	//------------------------------------------------------------------------------------
	rule relayQuantizedInput;
		let value <- inputQuantizer.get;
		inputMetadataQ.deq;
		dataInQs[0].enq(tuple2(value, inputMetadataQ.first));
	endrule

	rule relayQuantizedWeight;
		let weight <- weightQuantizer.get;
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
			pes[i].putInput(tpl_1(data), tpl_2(data));
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
		outputDequantizer.put(tpl_1(data), getOutputScale(), 0);
		outputMetadataQ.enq(tuple2(tpl_2(data), tpl_3(data)));
	endrule

	rule finishOutputDequantization;
		let value <- outputDequantizer.get;
		outputMetadataQ.deq;
		let metadata = outputMetadataQ.first;
		outputQ.enq(tuple3(value, tpl_1(metadata), tpl_2(metadata)));
	endrule

	method Action dataIn(Float value, Bit#(8) inputIdx);
		inputQuantizer.put(value, getQuantizationInverseScale(), 0);
		inputMetadataQ.enq(inputIdx);
	endmethod

	method Action weightIn(Float weight);
		weightQuantizer.put(weight, getQuantizationInverseScale(), 0);
	endmethod

	method ActionValue#(Tuple3#(Float, Bit#(8), Bit#(8))) dataOut;
		outputQ.deq;
		return outputQ.first;
	endmethod
endmodule
