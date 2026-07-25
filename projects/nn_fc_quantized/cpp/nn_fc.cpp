#include <stdio.h>

#include "nn_fc.h"


extern void sendWeight(float data);
extern void sendInput(float value, int inputIdx);
extern FcResult receiveResult();


void nnFc(
	float* matrix,
	float* input,
	int inputCnt,
	int inputDim,
	int outputDim,
	float* answer
) {
	int peWays = 16;

	// Phase 1
	// Send all FC weights to FPGA SDRAM
	for ( int i = 0; i < outputDim / peWays; i ++ ) {
		for ( int j = 0; j < inputDim; j ++ ) {
			for ( int k = 0; k < peWays; k ++ ) {
				sendWeight(matrix[(i * peWays + k) * inputDim + j]);
			}
		}
	}

	// Phase 2
	// Stream input vectors and collect available results
	int doneCnt = 0;
	for ( int i = 0; i < inputCnt; i ++ ) {
		for ( int j = 0; j < outputDim / peWays; j ++ ) {
			for ( int k = 0; k < inputDim; k ++ ) {
				sendInput(input[i * inputDim + k], i);
			}

			FcResult result = receiveResult();
			while ( result.valid ) {
				int idx = result.inputIdx * outputDim + result.outputIdx;
				answer[idx] = result.value;
				doneCnt ++;
				printf(
					"Writing %f to mem %d <%d,%d> (%d)\n",
					result.value,
					idx,
					result.inputIdx,
					result.outputIdx,
					doneCnt
				);
				fflush( stdout );
				result = receiveResult();
			}
		}
	}

	printf( "Finished sending all data\n" );
	fflush( stdout );

	// Phase 3
	// Drain all remaining FC results
	while ( doneCnt < outputDim * inputCnt ) {
		FcResult result = receiveResult();
		if ( !result.valid ) continue;

		int idx = result.inputIdx * outputDim + result.outputIdx;
		answer[idx] = result.value;
		doneCnt ++;
	}
}
