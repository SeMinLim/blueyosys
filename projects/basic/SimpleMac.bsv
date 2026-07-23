package SimpleMac;

import FIFO::*;
import FloatingPoint::*;
import SimpleFloat::*;

interface SimpleMacIfc;
	method Action put(Float a, Float b, Float c);
	method ActionValue#(Float) get;
endinterface

module mkSimpleMac(SimpleMacIfc);
	FloatTwoOp mult <- mkFloatMult;
	FloatTwoOp add <- mkFloatAdd;
	FIFO#(Float) addendQ <- mkFIFO;

	rule relayProduct;
		let product <- mult.get;
		let addend = addendQ.first;
		addendQ.deq;
		add.put(product, addend);
	endrule

	method Action put(Float a, Float b, Float c);
		mult.put(a, b);
		addendQ.enq(c);
	endmethod

	method ActionValue#(Float) get;
		let result <- add.get;
		return result;
	endmethod
endmodule

endpackage: SimpleMac
