#ifndef __NN_FC_QUANTIZED_H__
#define __NN_FC_QUANTIZED_H__


typedef struct FcResult {
	float value;
	int inputIdx;
	int outputIdx;
	bool valid;
} FcResult;

void nnFc(
	float* matrix,
	float* input,
	int inputCnt,
	int inputDim,
	int outputDim,
	float* answer
);


#endif
