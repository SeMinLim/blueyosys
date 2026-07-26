#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "ttyifc.h"
#include "nn_fc.h"


#define INPUT_CNT 64
#define INPUT_DIM 1024
#define OUTPUT_DIM 64
#define RESULT_TOLERANCE 0.01f


// Select the quantized datapath that the Host sends to the FPGA.
const int quantizedWidth = 8;


typedef union FloatBit8 {
	float value;
	uint8_t bytes[4];
} FloatBit8;

bool isValidQuantizedWidth(int width) {
	return width == 4 || width == 8 || width == 16;
}

float getInputInverseScale(int width) {
	if ( width == 4 ) return 0.5f;
	if ( width == 16 ) return 1024.0f;
	return 8.0f;
}

float getOutputScale(int width) {
	if ( width == 4 ) return 512.0f;
	if ( width == 16 ) return 0.25f;
	return 32.0f;
}

int getRequantizationShift(int width) {
	if ( width == 4 ) return 7;
	if ( width == 16 ) return 18;
	return 11;
}

int32_t getQuantizedMin(int width) {
	return -(1 << (width - 1));
}

int32_t getQuantizedMax(int width) {
	return (1 << (width - 1)) - 1;
}

int32_t saturateQuantized(int64_t value, int width) {
	int32_t minValue = getQuantizedMin(width);
	int32_t maxValue = getQuantizedMax(width);

	if ( value > maxValue ) return maxValue;
	if ( value < minValue ) return minValue;
	return (int32_t)value;
}

int getTestQuantizedMagnitudeMax(int width) {
	if ( width == 4 ) return 5;
	if ( width == 16 ) return 10240;
	return 80;
}

int32_t quantizeValue(float value, int width) {
	double scaledValue = (double)value * (double)getInputInverseScale(width);
	int64_t roundedValue = (int64_t)llround(scaledValue);
	return saturateQuantized(roundedValue, width);
}

int64_t roundingRightShift(int64_t value, int shift) {
	if ( shift == 0 ) return value;

	bool negative = value < 0;
	uint64_t magnitude = negative ? (uint64_t)(-value) : (uint64_t)value;
	uint64_t roundingBias = (uint64_t)1 << (shift - 1);
	uint64_t roundedMagnitude = (magnitude + roundingBias) >> shift;
	return negative ? -(int64_t)roundedMagnitude : (int64_t)roundedMagnitude;
}

int32_t requantizeAccumulator(int64_t accumulator, int width) {
	int64_t roundedValue = roundingRightShift(
		accumulator,
		getRequantizationShift(width)
	);
	return saturateQuantized(roundedValue, width);
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
	float* answer,
	int width
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
		quantizedWeights[i] = quantizeValue(weights[i], width);
	}
	for ( int i = 0; i < INPUT_DIM * INPUT_CNT; i ++ ) {
		quantizedInputs[i] = quantizeValue(inputs[i], width);
	}

	for ( int i = 0; i < INPUT_CNT; i ++ ) {
		for ( int j = 0; j < OUTPUT_DIM; j ++ ) {
			int64_t accumulator = 0;
			for ( int k = 0; k < INPUT_DIM; k ++ ) {
				accumulator +=
					(int64_t)quantizedWeights[j * INPUT_DIM + k] *
					(int64_t)quantizedInputs[i * INPUT_DIM + k];
			}

			int32_t quantizedOutput = requantizeAccumulator(accumulator, width);
			answer[i * OUTPUT_DIM + j] =
				(float)quantizedOutput * getOutputScale(width);
		}
	}

	free(quantizedWeights);
	free(quantizedInputs);
}

void sendQuantizedWidth(int width) {
	uart_send((uint8_t)width);
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

	if ( !isValidQuantizedWidth(quantizedWidth) ) {
		printf( "Quantized width must be 4, 8, or 16.\n" );
		fflush( stdout );
		exit(1);
	}

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

	float inputScale = 1.0f / getInputInverseScale(quantizedWidth);
	int quantizedMagnitudeMax = getTestQuantizedMagnitudeMax(quantizedWidth);

	for ( int i = 0; i < INPUT_DIM * OUTPUT_DIM; i ++ ) {
		weights[i] = 0.0f;
		if ( rand() % 4 == 0 ) {
			int quantizedValue =
				(rand() % (2 * quantizedMagnitudeMax + 1)) - quantizedMagnitudeMax;
			weights[i] = (float)quantizedValue * inputScale;
		}
	}
	for ( int i = 0; i < INPUT_DIM * INPUT_CNT; i ++ ) {
		inputs[i] = 0.0f;
		if ( rand() % 4 == 0 ) {
			int quantizedValue =
				(rand() % (2 * quantizedMagnitudeMax + 1)) - quantizedMagnitudeMax;
			inputs[i] = (float)quantizedValue * inputScale;
		}
	}
	for ( int i = 0; i < OUTPUT_DIM * INPUT_CNT; i ++ ) {
		answer[i] = 0.0f;
	}

	printf( "---------------------------------------------------------------------\n" );
	printf( "[STEP 2] Calculating Float and INT%d golden results\n", quantizedWidth );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	calculateFloatGolden(weights, inputs, floatGolden);
	calculateQuantizedGolden(weights, inputs, quantizedGolden, quantizedWidth);

	printf( "---------------------------------------------------------------------\n" );
	printf( "[STEP 3] Sending runtime INT%d width and running the FPGA FC layer\n",
		quantizedWidth
	);
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	sendQuantizedWidth(quantizedWidth);
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
	printf( "Quantized Width              : INT%d\n", quantizedWidth );
	printf( "Input/Weight Scale           : %.10f\n",
		1.0f / getInputInverseScale(quantizedWidth)
	);
	printf( "Output Scale                 : %.10f\n", getOutputScale(quantizedWidth) );
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
