#include "nn_fc.h"


extern void send_weight(float data);
extern void send_input(float value, int input_idx);
extern FC_Result recv_result();


void nn_fc(
	float* matrix,
	float* input,
	int input_cnt,
	int input_dim,
	int output_dim,
	float* answer
) {
	int pe_ways = 16;

	// Phase 1
	// Send all FC weights to FPGA SDRAM
	for ( int i = 0; i < output_dim / pe_ways; i ++ ) {
		for ( int j = 0; j < input_dim; j ++ ) {
			for ( int k = 0; k < pe_ways; k ++ ) {
				send_weight(matrix[(i * pe_ways + k) * input_dim + j]);
			}
		}
	}

	// Phase 2
	// Stream input vectors and collect available results
	int done_cnt = 0;
	for ( int i = 0; i < input_cnt; i ++ ) {
		for ( int j = 0; j < output_dim / pe_ways; j ++ ) {
			for ( int k = 0; k < input_dim; k ++ ) {
				send_input(input[i * input_dim + k], i);
			}

			FC_Result res = recv_result();
			while ( res.valid ) {
				int idx = res.input_idx * output_dim + res.output_idx;
				answer[idx] = res.value;
				done_cnt ++;
				res = recv_result();
			}
		}
	}

	printf( "Finished sending all FP32 data\n" );
	fflush( stdout );

	// Phase 3
	// Drain all remaining FC results
	while ( done_cnt < output_dim * input_cnt ) {
		FC_Result res = recv_result();
		if ( !res.valid ) continue;

		int idx = res.input_idx * output_dim + res.output_idx;
		answer[idx] = res.value;
		done_cnt ++;
	}
}
