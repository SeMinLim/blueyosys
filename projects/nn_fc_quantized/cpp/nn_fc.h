#ifndef __NN_FC_QUANTIZED_H__
#define __NN_FC_QUANTIZED_H__

#include <stdint.h>


typedef struct FcResult {
	int32_t value;
	int inputIdx;
	int outputIdx;
	bool valid;
} FcResult;

void nnFc(
	const uint16_t* packedWeights,
	const uint16_t* packedInputs,
	int inputCnt,
	int groupCnt,
	int outputDim,
	int32_t* answer
);


#endif
