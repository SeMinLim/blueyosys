#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

#include "ttyifc.h"
#include "nn_fc.h"


#define INPUT_CNT 64
#define INPUT_DIM 1024
#define OUTPUT_DIM 64
#define RESULT_TOLERANCE 1.0f


typedef union FloatBit8 {
	float f;
	uint8_t c[4];
} FloatBit8;


void send_weight(float data) {
	uart_send(0xff);

	FloatBit8 b;
	b.f = data;
	for ( int i = 0; i < 4; i ++ ) {
		uart_send(b.c[i]);
	}
}

void send_input(float value, int input_idx) {
	uart_send(input_idx & 0xff);

	FloatBit8 b;
	b.f = value;
	for ( int i = 0; i < 4; i ++ ) {
		uart_send(b.c[i]);
	}
}

FC_Result recv_result() {
	FC_Result r;
	r.value = 0.0f;
	r.input_idx = 0;
	r.output_idx = 0;
	r.valid = false;

	uint32_t res = uart_recv();
	if ( res > 0xff ) return r;
	r.input_idx = res;
	r.valid = true;

	res = uart_recv();
	while ( res > 0xff ) res = uart_recv();
	r.output_idx = res;

	FloatBit8 b;
	for ( int i = 0; i < 4; i ++ ) {
		res = uart_recv();
		while ( res > 0xff ) res = uart_recv();
		b.c[i] = res;
	}
	r.value = b.f;

	return r;
}


void* swmain(void* param) {
	(void)param;
	srand(time(NULL));

	int weightValueCnt = INPUT_DIM * OUTPUT_DIM;
	int inputValueCnt = INPUT_DIM * INPUT_CNT;
	int resultCnt = INPUT_CNT * OUTPUT_DIM;

	printf( "---------------------------------------------------------------------\n" );
	printf( "[STEP 1] Generating FP32 FC weights and inputs\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	float* weights = (float*)malloc(sizeof(float) * weightValueCnt);
	float* inputs = (float*)malloc(sizeof(float) * inputValueCnt);
	float* answer = (float*)malloc(sizeof(float) * resultCnt);
	float* answerGolden = (float*)malloc(sizeof(float) * resultCnt);

	if ( weights == NULL || inputs == NULL || answer == NULL || answerGolden == NULL ) {
		printf( "Failed to allocate FC test buffers.\n" );
		fflush( stdout );
		exit(1);
	}

	for ( int i = 0; i < weightValueCnt; i ++ ) {
		weights[i] = 0.0f;
		if ( rand() % 4 == 0 ) {
			weights[i] = ((float)(rand() % 10000)) / 1000.0f;
		}
	}
	for ( int i = 0; i < inputValueCnt; i ++ ) {
		inputs[i] = 0.0f;
		if ( rand() % 4 == 0 ) {
			inputs[i] = ((float)(rand() % 10000)) / 1000.0f;
		}
	}
	for ( int i = 0; i < resultCnt; i ++ ) {
		answer[i] = 0.0f;
		answerGolden[i] = 0.0f;
	}

	printf( "---------------------------------------------------------------------\n" );
	printf( "[STEP 2] Calculating floating-point golden results\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	for ( int i = 0; i < INPUT_CNT; i ++ ) {
		for ( int j = 0; j < OUTPUT_DIM; j ++ ) {
			for ( int k = 0; k < INPUT_DIM; k ++ ) {
				answerGolden[i * OUTPUT_DIM + j] +=
					weights[j * INPUT_DIM + k] * inputs[i * INPUT_DIM + k];
			}
		}
	}

	printf( "---------------------------------------------------------------------\n" );
	printf( "[STEP 3] Sending FP32 data and running the FPGA FC layer\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	nn_fc(weights, inputs, INPUT_CNT, INPUT_DIM, OUTPUT_DIM, answer);

	printf( "---------------------------------------------------------------------\n" );
	printf( "[STEP 4] Comparing FPGA and floating-point golden results\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	int mismatchCnt = 0;
	double differenceSum = 0.0;
	float differenceMax = 0.0f;

	for ( int i = 0; i < resultCnt; i ++ ) {
		float difference = fabsf(answer[i] - answerGolden[i]);
		if ( difference > RESULT_TOLERANCE ) {
			if ( mismatchCnt < 16 ) {
				printf(
					"Mismatch at %d: FPGA=%f Golden=%f Difference=%f\n",
					i,
					answer[i],
					answerGolden[i],
					difference
				);
			}
			mismatchCnt ++;
		}

		if ( difference > differenceMax ) differenceMax = difference;
		differenceSum += difference;
	}

	printf( "Floating-Point Configuration : FP32\n" );
	printf( "FPGA Verification            : %s (%d mismatches)\n",
		mismatchCnt == 0 ? "PASS" : "FAIL",
		mismatchCnt
	);
	printf( "FPGA Difference              : Average %.6f, Maximum %.6f\n",
		differenceSum / resultCnt,
		differenceMax
	);
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	free(weights);
	free(inputs);
	free(answer);
	free(answerGolden);

	exit(mismatchCnt == 0 ? 0 : 1);
	return NULL;
}

int main(int argc, char** argv) {
	char defaultTty[] = "/dev/ttyUSB0";
	char* ttyPath = defaultTty;
	if ( argc > 1 ) ttyPath = argv[1];

	int ret = open_tty(ttyPath);
	if ( ret != 0 ) return ret;

	swmain(NULL);
	return 0;
}
