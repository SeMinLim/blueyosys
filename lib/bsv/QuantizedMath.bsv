package QuantizedMath;

import FIFO::*;

import FloatingPoint::*;
import SimpleFloat::*;


// Quantized operand, product, and accumulator types.
typedef Int#(4) QInt4;
typedef Int#(8) QInt8;
typedef Int#(16) QInt16;

typedef Int#(8) QInt4Product;
typedef Int#(16) QInt8Product;
typedef Int#(32) QInt16Product;

typedef Int#(32) QInt4Accumulator;
typedef Int#(32) QInt8Accumulator;
typedef Int#(64) QInt16Accumulator;

// Integer datapaths are device-independent. Float conversion modules use the
// selected SimpleFloat backend for scale multiplication.
typedef Int#(32) QuantizedScaleMultiplier;
typedef Bit#(6) QuantizedShift;
typedef 8 QuantizedFloatQueueDepth;


interface Int4MultiplyIfc;
	method Action put(QInt4 a, QInt4 b);
	method ActionValue#(QInt4Product) get;
endinterface

interface Int8MultiplyIfc;
	method Action put(QInt8 a, QInt8 b);
	method ActionValue#(QInt8Product) get;
endinterface

interface Int16MultiplyIfc;
	method Action put(QInt16 a, QInt16 b);
	method ActionValue#(QInt16Product) get;
endinterface

interface Int4MacIfc;
	method Action put(QInt4 a, QInt4 b, QInt4Accumulator accumulator);
	method ActionValue#(QInt4Accumulator) get;
endinterface

interface Int8MacIfc;
	method Action put(QInt8 a, QInt8 b, QInt8Accumulator accumulator);
	method ActionValue#(QInt8Accumulator) get;
endinterface

interface Int16MacIfc;
	method Action put(QInt16 a, QInt16 b, QInt16Accumulator accumulator);
	method ActionValue#(QInt16Accumulator) get;
endinterface

interface FloatToInt4Ifc;
	// Quantization: q = saturate(round(value * inverseScale) + zeroPoint).
	method Action put(Float value, Float inverseScale, QInt4 zeroPoint);
	method ActionValue#(QInt4) get;
endinterface

interface FloatToInt8Ifc;
	// Quantization: q = saturate(round(value * inverseScale) + zeroPoint).
	method Action put(Float value, Float inverseScale, QInt8 zeroPoint);
	method ActionValue#(QInt8) get;
endinterface

interface FloatToInt16Ifc;
	// Quantization: q = saturate(round(value * inverseScale) + zeroPoint).
	method Action put(Float value, Float inverseScale, QInt16 zeroPoint);
	method ActionValue#(QInt16) get;
endinterface

interface Int4ToFloatIfc;
	// Dequantization: value = (q - zeroPoint) * scale.
	method Action put(QInt4 value, Float scale, QInt4 zeroPoint);
	method ActionValue#(Float) get;
endinterface

interface Int8ToFloatIfc;
	// Dequantization: value = (q - zeroPoint) * scale.
	method Action put(QInt8 value, Float scale, QInt8 zeroPoint);
	method ActionValue#(Float) get;
endinterface

interface Int16ToFloatIfc;
	// Dequantization: value = (q - zeroPoint) * scale.
	method Action put(QInt16 value, Float scale, QInt16 zeroPoint);
	method ActionValue#(Float) get;
endinterface


//------------------------------------------------------------------------------------
// Signed multiply and MAC functions
//------------------------------------------------------------------------------------
function QInt4Product multiplyInt4(QInt4 a, QInt4 b);
	QInt4Product aExt = signExtend(a);
	QInt4Product bExt = signExtend(b);
	return aExt * bExt;
endfunction

function QInt8Product multiplyInt8(QInt8 a, QInt8 b);
	QInt8Product aExt = signExtend(a);
	QInt8Product bExt = signExtend(b);
	return aExt * bExt;
endfunction

function QInt16Product multiplyInt16(QInt16 a, QInt16 b);
	QInt16Product aExt = signExtend(a);
	QInt16Product bExt = signExtend(b);
	return aExt * bExt;
endfunction

function QInt4Accumulator macInt4(
	QInt4 a,
	QInt4 b,
	QInt4Accumulator accumulator
);
	QInt4Accumulator product = signExtend(multiplyInt4(a, b));
	return accumulator + product;
endfunction

function QInt8Accumulator macInt8(
	QInt8 a,
	QInt8 b,
	QInt8Accumulator accumulator
);
	QInt8Accumulator product = signExtend(multiplyInt8(a, b));
	return accumulator + product;
endfunction

function QInt16Accumulator macInt16(
	QInt16 a,
	QInt16 b,
	QInt16Accumulator accumulator
);
	QInt16Accumulator product = signExtend(multiplyInt16(a, b));
	return accumulator + product;
endfunction


//------------------------------------------------------------------------------------
// Saturating arithmetic
//------------------------------------------------------------------------------------
function QInt4 saturatingAddInt4(QInt4 a, QInt4 b);
	Int#(5) sum = signExtend(a) + signExtend(b);
	Int#(5) maxValue = fromInteger(7);
	Int#(5) minValue = fromInteger(-8);

	if ( sum > maxValue ) begin
		return fromInteger(7);
	end else if ( sum < minValue ) begin
		return fromInteger(-8);
	end else begin
		return truncate(sum);
	end
endfunction

function QInt8 saturatingAddInt8(QInt8 a, QInt8 b);
	Int#(9) sum = signExtend(a) + signExtend(b);
	Int#(9) maxValue = fromInteger(127);
	Int#(9) minValue = fromInteger(-128);

	if ( sum > maxValue ) begin
		return fromInteger(127);
	end else if ( sum < minValue ) begin
		return fromInteger(-128);
	end else begin
		return truncate(sum);
	end
endfunction

function QInt16 saturatingAddInt16(QInt16 a, QInt16 b);
	Int#(17) sum = signExtend(a) + signExtend(b);
	Int#(17) maxValue = fromInteger(32767);
	Int#(17) minValue = fromInteger(-32768);

	if ( sum > maxValue ) begin
		return fromInteger(32767);
	end else if ( sum < minValue ) begin
		return fromInteger(-32768);
	end else begin
		return truncate(sum);
	end
endfunction

function QInt4 saturateToInt4(Int#(96) value);
	if ( value > fromInteger(7) ) begin
		return fromInteger(7);
	end else if ( value < fromInteger(-8) ) begin
		return fromInteger(-8);
	end else begin
		return truncate(value);
	end
endfunction

function QInt8 saturateToInt8(Int#(96) value);
	if ( value > fromInteger(127) ) begin
		return fromInteger(127);
	end else if ( value < fromInteger(-128) ) begin
		return fromInteger(-128);
	end else begin
		return truncate(value);
	end
endfunction

function QInt16 saturateToInt16(Int#(96) value);
	if ( value > fromInteger(32767) ) begin
		return fromInteger(32767);
	end else if ( value < fromInteger(-32768) ) begin
		return fromInteger(-32768);
	end else begin
		return truncate(value);
	end
endfunction


//------------------------------------------------------------------------------------
// Signed rounding shifts and requantization
//------------------------------------------------------------------------------------
// Rounding mode is round-to-nearest with ties away from zero.
function Int#(32) roundingRightShift32(Int#(32) value, Bit#(5) shift);
	Int#(33) valueExt = signExtend(value);
	Bool negative = valueExt < 0;
	Int#(33) magnitudeSigned = negative ? -valueExt : valueExt;
	UInt#(33) magnitude = unpack(pack(magnitudeSigned));
	UInt#(33) roundedMagnitude = magnitude;

	if ( shift != 0 ) begin
		UInt#(33) roundingBias = 1;
		roundingBias = roundingBias << (shift - 1);
		roundedMagnitude = (magnitude + roundingBias) >> shift;
	end

	Int#(33) roundedValue = unpack(pack(roundedMagnitude));
	if ( negative ) roundedValue = -roundedValue;
	return truncate(roundedValue);
endfunction

function Int#(64) roundingRightShift64(Int#(64) value, QuantizedShift shift);
	Int#(65) valueExt = signExtend(value);
	Bool negative = valueExt < 0;
	Int#(65) magnitudeSigned = negative ? -valueExt : valueExt;
	UInt#(65) magnitude = unpack(pack(magnitudeSigned));
	UInt#(65) roundedMagnitude = magnitude;

	if ( shift != 0 ) begin
		UInt#(65) roundingBias = 1;
		roundingBias = roundingBias << (shift - 1);
		roundedMagnitude = (magnitude + roundingBias) >> shift;
	end

	Int#(65) roundedValue = unpack(pack(roundedMagnitude));
	if ( negative ) roundedValue = -roundedValue;
	return truncate(roundedValue);
endfunction

function Int#(96) roundingRightShift96(Int#(96) value, QuantizedShift shift);
	Int#(97) valueExt = signExtend(value);
	Bool negative = valueExt < 0;
	Int#(97) magnitudeSigned = negative ? -valueExt : valueExt;
	UInt#(97) magnitude = unpack(pack(magnitudeSigned));
	UInt#(97) roundedMagnitude = magnitude;

	if ( shift != 0 ) begin
		UInt#(97) roundingBias = 1;
		roundingBias = roundingBias << (shift - 1);
		roundedMagnitude = (magnitude + roundingBias) >> shift;
	end

	Int#(97) roundedValue = unpack(pack(roundedMagnitude));
	if ( negative ) roundedValue = -roundedValue;
	return truncate(roundedValue);
endfunction

// multiplier / 2^shift represents the accumulator-to-output scale ratio.
function QInt4 requantizeInt4(
	QInt4Accumulator accumulator,
	QuantizedScaleMultiplier multiplier,
	QuantizedShift shift,
	QInt4 zeroPoint
);
	Int#(64) accumulatorExt = signExtend(accumulator);
	Int#(64) multiplierExt = signExtend(multiplier);
	Int#(64) scaledValue = accumulatorExt * multiplierExt;
	Int#(64) roundedValue = roundingRightShift64(scaledValue, shift);
	Int#(96) roundedValueExt = signExtend(roundedValue);
	Int#(96) zeroPointExt = signExtend(zeroPoint);
	return saturateToInt4(roundedValueExt + zeroPointExt);
endfunction

function QInt8 requantizeInt8(
	QInt8Accumulator accumulator,
	QuantizedScaleMultiplier multiplier,
	QuantizedShift shift,
	QInt8 zeroPoint
);
	Int#(64) accumulatorExt = signExtend(accumulator);
	Int#(64) multiplierExt = signExtend(multiplier);
	Int#(64) scaledValue = accumulatorExt * multiplierExt;
	Int#(64) roundedValue = roundingRightShift64(scaledValue, shift);
	Int#(96) roundedValueExt = signExtend(roundedValue);
	Int#(96) zeroPointExt = signExtend(zeroPoint);
	return saturateToInt8(roundedValueExt + zeroPointExt);
endfunction

function QInt16 requantizeInt16(
	QInt16Accumulator accumulator,
	QuantizedScaleMultiplier multiplier,
	QuantizedShift shift,
	QInt16 zeroPoint
);
	Int#(96) accumulatorExt = signExtend(accumulator);
	Int#(96) multiplierExt = signExtend(multiplier);
	Int#(96) scaledValue = accumulatorExt * multiplierExt;
	Int#(96) roundedValue = roundingRightShift96(scaledValue, shift);
	Int#(96) zeroPointExt = signExtend(zeroPoint);
	return saturateToInt16(roundedValue + zeroPointExt);
endfunction


//------------------------------------------------------------------------------------
// Float and quantized-integer conversion helpers
//------------------------------------------------------------------------------------
function Int#(32) roundFloatToInt32(Float value);
	Bit#(32) valueBits = pack(value);
	Bool negative = valueBits[31] == 1;
	Bit#(8) exponent = valueBits[30:23];
	Bit#(23) fraction = valueBits[22:0];
	Int#(32) result = 0;

	if ( exponent == 8'hff ) begin
		if ( fraction == 0 ) begin
			result = negative ? unpack(32'h80000000) : unpack(32'h7fffffff);
		end
	end else if ( exponent < fromInteger(126) ) begin
		result = 0;
	end else if ( exponent >= fromInteger(158) ) begin
		result = negative ? unpack(32'h80000000) : unpack(32'h7fffffff);
	end else begin
		Bit#(32) significandBits = zeroExtend({1'b1, fraction});
		UInt#(32) significand = unpack(significandBits);
		UInt#(32) magnitude = 0;

		if ( exponent <= fromInteger(150) ) begin
			Bit#(5) rightShift = truncate(fromInteger(150) - exponent);
			if ( rightShift == 0 ) begin
				magnitude = significand;
			end else begin
				UInt#(32) roundingBias = 1;
				roundingBias = roundingBias << (rightShift - 1);
				magnitude = (significand + roundingBias) >> rightShift;
			end
		end else begin
			Bit#(3) leftShift = truncate(exponent - fromInteger(150));
			magnitude = significand << leftShift;
		end

		Int#(33) magnitudeExt = unpack(zeroExtend(pack(magnitude)));
		Int#(33) signedValue = negative ? -magnitudeExt : magnitudeExt;
		result = truncate(signedValue);
	end

	return result;
endfunction

function Float int32ToFloat(Int#(32) value);
	Bit#(32) valueBits = pack(value);
	Bool negative = value < 0;
	Bit#(32) magnitude = negative ? (~valueBits + 1) : valueBits;
	Bit#(8) exponent = 0;
	Bit#(23) fraction = 0;

	if ( magnitude != 0 ) begin
		Bit#(5) mostSignificantIdx = 0;
		for ( Integer i = 0; i < 32; i = i + 1 ) begin
			if ( magnitude[i] == 1 ) begin
				mostSignificantIdx = fromInteger(i);
			end
		end

		Bit#(5) normalizeShift = fromInteger(31) - mostSignificantIdx;
		Bit#(64) normalized = zeroExtend(magnitude) << normalizeShift;
		Bit#(25) significand = zeroExtend(normalized[31:8]);
		Bool roundUp = normalized[7] == 1 &&
			(normalized[6:0] != 0 || normalized[8] == 1);

		exponent = zeroExtend(mostSignificantIdx) + fromInteger(127);
		if ( roundUp ) begin
			significand = significand + 1;
		end

		if ( significand[24] == 1 ) begin
			exponent = exponent + 1;
			fraction = 0;
		end else begin
			fraction = significand[22:0];
		end
	end

	Bit#(32) resultBits = {pack(negative), exponent, fraction};
	return unpack(resultBits);
endfunction


//------------------------------------------------------------------------------------
// Streaming signed multipliers
//------------------------------------------------------------------------------------
module mkInt4Multiply(Int4MultiplyIfc);
	FIFO#(Tuple2#(QInt4, QInt4)) inputQ <- mkFIFO;
	FIFO#(QInt4Product) outputQ <- mkFIFO;

	rule processMultiply;
		inputQ.deq;
		let a = tpl_1(inputQ.first);
		let b = tpl_2(inputQ.first);
		outputQ.enq(multiplyInt4(a, b));
	endrule

	method Action put(QInt4 a, QInt4 b);
		inputQ.enq(tuple2(a, b));
	endmethod

	method ActionValue#(QInt4Product) get;
		outputQ.deq;
		return outputQ.first;
	endmethod
endmodule

module mkInt8Multiply(Int8MultiplyIfc);
	FIFO#(Tuple2#(QInt8, QInt8)) inputQ <- mkFIFO;
	FIFO#(QInt8Product) outputQ <- mkFIFO;

	rule processMultiply;
		inputQ.deq;
		let a = tpl_1(inputQ.first);
		let b = tpl_2(inputQ.first);
		outputQ.enq(multiplyInt8(a, b));
	endrule

	method Action put(QInt8 a, QInt8 b);
		inputQ.enq(tuple2(a, b));
	endmethod

	method ActionValue#(QInt8Product) get;
		outputQ.deq;
		return outputQ.first;
	endmethod
endmodule

module mkInt16Multiply(Int16MultiplyIfc);
	FIFO#(Tuple2#(QInt16, QInt16)) inputQ <- mkFIFO;
	FIFO#(QInt16Product) outputQ <- mkFIFO;

	rule processMultiply;
		inputQ.deq;
		let a = tpl_1(inputQ.first);
		let b = tpl_2(inputQ.first);
		outputQ.enq(multiplyInt16(a, b));
	endrule

	method Action put(QInt16 a, QInt16 b);
		inputQ.enq(tuple2(a, b));
	endmethod

	method ActionValue#(QInt16Product) get;
		outputQ.deq;
		return outputQ.first;
	endmethod
endmodule


//------------------------------------------------------------------------------------
// Two-stage signed MAC pipelines
//------------------------------------------------------------------------------------
module mkInt4Mac(Int4MacIfc);
	FIFO#(Tuple3#(QInt4, QInt4, QInt4Accumulator)) inputQ <- mkFIFO;
	FIFO#(Tuple2#(QInt4Product, QInt4Accumulator)) productQ <- mkFIFO;
	FIFO#(QInt4Accumulator) outputQ <- mkFIFO;

	rule processMultiply;
		inputQ.deq;
		let a = tpl_1(inputQ.first);
		let b = tpl_2(inputQ.first);
		let accumulator = tpl_3(inputQ.first);
		productQ.enq(tuple2(multiplyInt4(a, b), accumulator));
	endrule

	rule processAccumulate;
		productQ.deq;
		QInt4Accumulator product = signExtend(tpl_1(productQ.first));
		let accumulator = tpl_2(productQ.first);
		outputQ.enq(accumulator + product);
	endrule

	method Action put(QInt4 a, QInt4 b, QInt4Accumulator accumulator);
		inputQ.enq(tuple3(a, b, accumulator));
	endmethod

	method ActionValue#(QInt4Accumulator) get;
		outputQ.deq;
		return outputQ.first;
	endmethod
endmodule

module mkInt8Mac(Int8MacIfc);
	FIFO#(Tuple3#(QInt8, QInt8, QInt8Accumulator)) inputQ <- mkFIFO;
	FIFO#(Tuple2#(QInt8Product, QInt8Accumulator)) productQ <- mkFIFO;
	FIFO#(QInt8Accumulator) outputQ <- mkFIFO;

	rule processMultiply;
		inputQ.deq;
		let a = tpl_1(inputQ.first);
		let b = tpl_2(inputQ.first);
		let accumulator = tpl_3(inputQ.first);
		productQ.enq(tuple2(multiplyInt8(a, b), accumulator));
	endrule

	rule processAccumulate;
		productQ.deq;
		QInt8Accumulator product = signExtend(tpl_1(productQ.first));
		let accumulator = tpl_2(productQ.first);
		outputQ.enq(accumulator + product);
	endrule

	method Action put(QInt8 a, QInt8 b, QInt8Accumulator accumulator);
		inputQ.enq(tuple3(a, b, accumulator));
	endmethod

	method ActionValue#(QInt8Accumulator) get;
		outputQ.deq;
		return outputQ.first;
	endmethod
endmodule

module mkInt16Mac(Int16MacIfc);
	FIFO#(Tuple3#(QInt16, QInt16, QInt16Accumulator)) inputQ <- mkFIFO;
	FIFO#(Tuple2#(QInt16Product, QInt16Accumulator)) productQ <- mkFIFO;
	FIFO#(QInt16Accumulator) outputQ <- mkFIFO;

	rule processMultiply;
		inputQ.deq;
		let a = tpl_1(inputQ.first);
		let b = tpl_2(inputQ.first);
		let accumulator = tpl_3(inputQ.first);
		productQ.enq(tuple2(multiplyInt16(a, b), accumulator));
	endrule

	rule processAccumulate;
		productQ.deq;
		QInt16Accumulator product = signExtend(tpl_1(productQ.first));
		let accumulator = tpl_2(productQ.first);
		outputQ.enq(accumulator + product);
	endrule

	method Action put(QInt16 a, QInt16 b, QInt16Accumulator accumulator);
		inputQ.enq(tuple3(a, b, accumulator));
	endmethod

	method ActionValue#(QInt16Accumulator) get;
		outputQ.deq;
		return outputQ.first;
	endmethod
endmodule


//------------------------------------------------------------------------------------
// Float-to-quantized conversion pipelines
//------------------------------------------------------------------------------------
module mkFloatToInt4(FloatToInt4Ifc);
	FloatTwoOp scaleMultiplier <- mkFloatMult;
	FIFO#(QInt4) zeroPointQ <- mkSizedFIFO(valueOf(QuantizedFloatQueueDepth));
	FIFO#(QInt4) outputQ <- mkFIFO;

	rule processResult;
		let scaledValue <- scaleMultiplier.get;
		zeroPointQ.deq;
		Int#(64) roundedValue = signExtend(roundFloatToInt32(scaledValue));
		Int#(64) zeroPoint = signExtend(zeroPointQ.first);
		Int#(96) adjustedValue = signExtend(roundedValue + zeroPoint);
		outputQ.enq(saturateToInt4(adjustedValue));
	endrule

	method Action put(Float value, Float inverseScale, QInt4 zeroPoint);
		scaleMultiplier.put(value, inverseScale);
		zeroPointQ.enq(zeroPoint);
	endmethod

	method ActionValue#(QInt4) get;
		outputQ.deq;
		return outputQ.first;
	endmethod
endmodule

module mkFloatToInt8(FloatToInt8Ifc);
	FloatTwoOp scaleMultiplier <- mkFloatMult;
	FIFO#(QInt8) zeroPointQ <- mkSizedFIFO(valueOf(QuantizedFloatQueueDepth));
	FIFO#(QInt8) outputQ <- mkFIFO;

	rule processResult;
		let scaledValue <- scaleMultiplier.get;
		zeroPointQ.deq;
		Int#(64) roundedValue = signExtend(roundFloatToInt32(scaledValue));
		Int#(64) zeroPoint = signExtend(zeroPointQ.first);
		Int#(96) adjustedValue = signExtend(roundedValue + zeroPoint);
		outputQ.enq(saturateToInt8(adjustedValue));
	endrule

	method Action put(Float value, Float inverseScale, QInt8 zeroPoint);
		scaleMultiplier.put(value, inverseScale);
		zeroPointQ.enq(zeroPoint);
	endmethod

	method ActionValue#(QInt8) get;
		outputQ.deq;
		return outputQ.first;
	endmethod
endmodule

module mkFloatToInt16(FloatToInt16Ifc);
	FloatTwoOp scaleMultiplier <- mkFloatMult;
	FIFO#(QInt16) zeroPointQ <- mkSizedFIFO(valueOf(QuantizedFloatQueueDepth));
	FIFO#(QInt16) outputQ <- mkFIFO;

	rule processResult;
		let scaledValue <- scaleMultiplier.get;
		zeroPointQ.deq;
		Int#(64) roundedValue = signExtend(roundFloatToInt32(scaledValue));
		Int#(64) zeroPoint = signExtend(zeroPointQ.first);
		Int#(96) adjustedValue = signExtend(roundedValue + zeroPoint);
		outputQ.enq(saturateToInt16(adjustedValue));
	endrule

	method Action put(Float value, Float inverseScale, QInt16 zeroPoint);
		scaleMultiplier.put(value, inverseScale);
		zeroPointQ.enq(zeroPoint);
	endmethod

	method ActionValue#(QInt16) get;
		outputQ.deq;
		return outputQ.first;
	endmethod
endmodule


//------------------------------------------------------------------------------------
// Quantized-to-Float conversion pipelines
//------------------------------------------------------------------------------------
module mkInt4ToFloat(Int4ToFloatIfc);
	FloatTwoOp scaleMultiplier <- mkFloatMult;

	method Action put(QInt4 value, Float scale, QInt4 zeroPoint);
		Int#(32) valueExt = signExtend(value);
		Int#(32) zeroPointExt = signExtend(zeroPoint);
		Float centeredValue = int32ToFloat(valueExt - zeroPointExt);
		scaleMultiplier.put(centeredValue, scale);
	endmethod

	method ActionValue#(Float) get;
		let result <- scaleMultiplier.get;
		return result;
	endmethod
endmodule

module mkInt8ToFloat(Int8ToFloatIfc);
	FloatTwoOp scaleMultiplier <- mkFloatMult;

	method Action put(QInt8 value, Float scale, QInt8 zeroPoint);
		Int#(32) valueExt = signExtend(value);
		Int#(32) zeroPointExt = signExtend(zeroPoint);
		Float centeredValue = int32ToFloat(valueExt - zeroPointExt);
		scaleMultiplier.put(centeredValue, scale);
	endmethod

	method ActionValue#(Float) get;
		let result <- scaleMultiplier.get;
		return result;
	endmethod
endmodule

module mkInt16ToFloat(Int16ToFloatIfc);
	FloatTwoOp scaleMultiplier <- mkFloatMult;

	method Action put(QInt16 value, Float scale, QInt16 zeroPoint);
		Int#(32) valueExt = signExtend(value);
		Int#(32) zeroPointExt = signExtend(zeroPoint);
		Float centeredValue = int32ToFloat(valueExt - zeroPointExt);
		scaleMultiplier.put(centeredValue, scale);
	endmethod

	method ActionValue#(Float) get;
		let result <- scaleMultiplier.get;
		return result;
	endmethod
endmodule

endpackage: QuantizedMath
