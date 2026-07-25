#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "ttyifc.h"
#include "nn_fc.h"


#ifndef QUANTIZED_WIDTH
#define QUANTIZED_WIDTH 8
#endif

#define INPUT_CNT 64
#define INPUT_DIM 1024
#define OUTPUT_DIM 64
#define RESULT_TOLERANCE 0.01f


typedef union FloatBit8 {
	float value;
	uint8_t bytes[4];
} FloatBit8;

typedef union FloatBit32 {
	float value;
	uint32_t bits;
} FloatBit32;


float getInputInverseScale() {
#if QUANTIZED_WIDTH == 4
	return 0.5f;
#elif QUANTIZED_WIDTH == 16
	return 1024.0f;
#else
	return 8.0f;
#endif
}

float getOutputScale() {
#if QUANTIZED_WIDTH == 4
	return 512.0f;
#elif QUANTIZED_WIDTH == 16
	return 0.25f;
#else
	return 32.0f;
#endif
}

int getRequantizationShift() {
#if QUANTIZED_WIDTH == 4
	return 7;
#elif QUANTIZED_WIDTH == 16
	return 18;
#else
	return 11;
#endif
}

int32_t getQuantizedMin() {
	return -(1 << (QUANTIZED_WIDTH - 1));
}

int32_t getQuantizedMax() {
	return (1 << (QUANTIZED_WIDTH - 1)) - 1;
}

int32_t saturateQuantized(int64_t value) {
	int32_t minValue = getQuantizedMin();
	int32_t maxValue = getQuantizedMax();

	if ( value > maxValue ) return maxValue;
	if ( value < minValue ) return minValue;
	return (int32_t)value;
}

int32_t quantizeValue(float value) {
	// SimpleFloat keeps the upper 17 fraction bits for this power-of-two scale
	// multiplication, so the C golden model clears the same six LSBs first.
	FloatBit32 simpleValue;
	simpleValue.value = value;
	if ( (simpleValue.bits & 0x7f800000u) != 0 ) {
		simpleValue.bits &= 0xffffffc0u;
	}

	double scaledValue =
		(double)simpleValue.value * (double)getInputInverseScale();
	int64_t roundedValue = (int64_t)llround(scaledValue);
	return saturateQuantized(roundedValue);
}

int64_t roundingRightShift(int64_t value, int shift) {
	if ( shift == 0 ) return value;

	bool negative = value < 0;
	uint64_t magnitude = negative ? (uint64_t)(-value) : (uint64_t)value;
	uint64_t roundingBias = (uint64_t)1 << (shift - 1);
	uint64_t roundedMagnitude = (magnitude + roundingBias) >> shift;
	return negative ? -(int64_t)roundedMagnitude : (int64_t)roundedMagnitude;
}

int32_t requantizeAccumulator(int64_t accumulator) {
	int64_t roundedValue = roundingRightShift(
		accumulator,
		getRequantizationShift()
	);
	return saturateQuantized(roundedValue);
}

void calculateFloatGolden(
	float* weights,
	float* inputs,
	float* answer
) {
	for ( int i = 0; i < INPUT_CNT; i ++ ) {
		for ( int j = 0; j < OUTPUT_DIM; j ++ ) {
			float sum = 0.0f;
			for ( int k = 0; k < INPUT_DIM; k ++ ) {
				sum += weights[j * INPUT_DIM + k] * inputs[i * INPUT_DIM + k];
			}
			answer[i * OUTPUT_DIM + j] = sum;
		}
	}
}

void calculateQuantizedGolden(
	float* weights,
	float* inputs,
	float* answer
) {
	int32_t* quantizedWeights =
		(int32_t*)malloc(sizeof(int32_t) * INPUT_DIM * OUTPUT_DIM);
	int32_t* quantizedInputs =
		(int32_t*)malloc(sizeof(int32_t) * INPUT_DIM * INPUT_CNT);

	if ( quantizedWeights == NULL || quantizedInputs == NULL ) {
		printf( "Failed to allocate quantized golden buffers.\n" );
		fflush( stdout );
		exit(1);
	}

	for ( int i = 0; i < INPUT_DIM * OUTPUT_DIM; i ++ ) {
		quantizedWeights[i] = quantizeValue(weights[i]);
	}
	for ( int i = 0; i < INPUT_DIM * INPUT_CNT; i ++ ) {
		quantizedInputs[i] = quantizeValue(inputs[i]);
	}

	for ( int i = 0; i < INPUT_CNT; i ++ ) {
		for ( int j = 0; j < OUTPUT_DIM; j ++ ) {
			int64_t accumulator = 0;
			for ( int k = 0; k < INPUT_DIM; k ++ ) {
				accumulator +=
					(int64_t)quantizedWeights[j * INPUT_DIM + k] *
					(int64_t)quantizedInputs[i * INPUT_DIM + k];
			}

			int32_t quantizedOutput = requantizeAccumulator(accumulator);
			answer[i * OUTPUT_DIM + j] =
				(float)quantizedOutput * getOutputScale();
		}
	}

	free(quantizedWeights);
	free(quantizedInputs);
}

void sendWeight(float data) {
	uart_send(0xff);

	FloatBit8 value;
	value.value = data;
	for ( int i = 0; i < 4; i ++ ) {
		uart_send(value.bytes[i]);
	}
}

void sendInput(float data, int inputIdx) {
	uart_send((uint8_t)(inputIdx & 0xff));

	FloatBit8 value;
	value.value = data;
	for ( int i = 0; i < 4; i ++ ) {
		uart_send(value.bytes[i]);
	}
}

FcResult receiveResult() {
	FcResult result;
	result.value = 0.0f;
	result.inputIdx = 0;
	result.outputIdx = 0;
	result.valid = false;

	uint32_t data = uart_recv();
	if ( data > 0xff ) return result;
	result.inputIdx = (int)data;
	result.valid = true;

	data = uart_recv();
	while ( data > 0xff ) data = uart_recv();
	result.outputIdx = (int)data;

	FloatBit8 value;
	for ( int i = 0; i < 4; i ++ ) {
		data = uart_recv();
		while ( data > 0xff ) data = uart_recv();
		value.bytes[i] = (uint8_t)data;
	}
	result.value = value.value;

	return result;
}

void* swmain(void* param) {
	(void)param;
	srand(1);

	printf( "---------------------------------------------------------------------\n" );
	printf( "[STEP 1] Generating signed FC weights and inputs\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	float* weights = (float*)malloc(sizeof(float) * INPUT_DIM * OUTPUT_DIM);
	float* inputs = (float*)malloc(sizeof(float) * INPUT_DIM * INPUT_CNT);
	float* answer = (float*)malloc(sizeof(float) * OUTPUT_DIM * INPUT_CNT);
	float* quantizedGolden =
		(float*)malloc(sizeof(float) * OUTPUT_DIM * INPUT_CNT);
	float* floatGolden = (float*)malloc(sizeof(float) * OUTPUT_DIM * INPUT_CNT);

	if ( weights == NULL || inputs == NULL || answer == NULL ||
	     quantizedGolden == NULL || floatGolden == NULL ) {
		printf( "Failed to allocate FC test buffers.\n" );
		fflush( stdout );
		exit(1);
	}

	for ( int i = 0; i < INPUT_DIM * OUTPUT_DIM; i ++ ) {
		weights[i] = 0.0f;
		if ( rand() % 4 == 0 ) {
			float magnitude = (float)(rand() % 10000) / 1000.0f;
			weights[i] = (rand() & 1) ? magnitude : -magnitude;
		}
	}
	for ( int i = 0; i < INPUT_DIM * INPUT_CNT; i ++ ) {
		inputs[i] = 0.0f;
		if ( rand() % 4 == 0 ) {
			float magnitude = (float)(rand() % 10000) / 1000.0f;
			inputs[i] = (rand() & 1) ? magnitude : -magnitude;
		}
	}
	for ( int i = 0; i < OUTPUT_DIM * INPUT_CNT; i ++ ) {
		answer[i] = 0.0f;
	}

	printf( "---------------------------------------------------------------------\n" );
	printf( "[STEP 2] Calculating Float and INT%d golden results\n", QUANTIZED_WIDTH );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	calculateFloatGolden(weights, inputs, floatGolden);
	calculateQuantizedGolden(weights, inputs, quantizedGolden);

	printf( "---------------------------------------------------------------------\n" );
	printf( "[STEP 3] Running the INT%d FPGA fully connected layer\n", QUANTIZED_WIDTH );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	nnFc(weights, inputs, INPUT_CNT, INPUT_DIM, OUTPUT_DIM, answer);

	printf( "---------------------------------------------------------------------\n" );
	printf( "[STEP 4] Comparing FPGA, quantized golden, and Float golden results\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	int mismatchCnt = 0;
	double hardwareDiffSum = 0.0;
	double quantizationDiffSum = 0.0;
	float hardwareDiffMax = 0.0f;
	float quantizationDiffMax = 0.0f;

	for ( int i = 0; i < INPUT_CNT * OUTPUT_DIM; i ++ ) {
		float hardwareDiff = fabsf(answer[i] - quantizedGolden[i]);
		float quantizationDiff = fabsf(quantizedGolden[i] - floatGolden[i]);

		if ( hardwareDiff > RESULT_TOLERANCE ) {
			if ( mismatchCnt < 16 ) {
				printf(
					"Mismatch at %d: FPGA=%f QuantizedGolden=%f Diff=%f\n",
					i,
					answer[i],
					quantizedGolden[i],
					hardwareDiff
				);
			}
			mismatchCnt ++;
		}

		if ( hardwareDiff > hardwareDiffMax ) hardwareDiffMax = hardwareDiff;
		if ( quantizationDiff > quantizationDiffMax ) {
			quantizationDiffMax = quantizationDiff;
		}
		hardwareDiffSum += hardwareDiff;
		quantizationDiffSum += quantizationDiff;
	}

	int resultCnt = INPUT_CNT * OUTPUT_DIM;
	printf( "Quantized Width              : INT%d\n", QUANTIZED_WIDTH );
	printf( "Input/Weight Scale           : %.10f\n", 1.0f / getInputInverseScale() );
	printf( "Output Scale                 : %.10f\n", getOutputScale() );
	printf( "FPGA Mismatch Count          : %d\n", mismatchCnt );
	printf( "FPGA Average Difference      : %.10f\n", hardwareDiffSum / resultCnt );
	printf( "FPGA Maximum Difference      : %.10f\n", hardwareDiffMax );
	printf( "Quantization Average Error   : %.10f\n", quantizationDiffSum / resultCnt );
	printf( "Quantization Maximum Error   : %.10f\n", quantizationDiffMax );
	printf( "Result                       : %s\n", mismatchCnt == 0 ? "PASS" : "FAIL" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	free(weights);
	free(inputs);
	free(answer);
	free(quantizedGolden);
	free(floatGolden);

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
