#include <stdio.h>

#include "nn_fc.h"


extern void sendWeight(uint16_t data);
extern void sendInput(uint16_t data, int inputIdx);
extern FcResult receiveResult();


void nnFc(
	const uint16_t* packedWeights,
	const uint16_t* packedInputs,
	int inputCnt,
	int groupCnt,
	int outputDim,
	int32_t* answer
) {
	int weightWordCnt = groupCnt * outputDim;

	// Phase 1
	// Send group-major packed weights to FPGA SDRAM
	for ( int i = 0; i < weightWordCnt; i ++ ) {
		sendWeight(packedWeights[i]);
	}

	// Phase 2
	// Send input-major packed input vectors to FPGA SDRAM
	for ( int i = 0; i < inputCnt; i ++ ) {
		for ( int j = 0; j < groupCnt; j ++ ) {
			sendInput(packedInputs[i * groupCnt + j], i);
		}
	}

	printf( "Finished sending all packed data\n" );
	fflush( stdout );

	// Phase 3
	// Receive signed quantized FC results
	int doneCnt = 0;
	while ( doneCnt < outputDim * inputCnt ) {
		FcResult result = receiveResult();
		if ( !result.valid ) continue;

		int idx = result.inputIdx * outputDim + result.outputIdx;
		answer[idx] = result.value;
		doneCnt ++;
	}
}
