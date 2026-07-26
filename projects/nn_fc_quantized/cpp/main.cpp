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


// Select the quantized datapath that the Host sends to the FPGA.
const int quantizedWidth = 8;


typedef union IntBit8 {
	int32_t value;
	uint8_t bytes[4];
} IntBit8;

bool isValidQuantizedWidth(int width) {
	return width == 4 || width == 8 || width == 16;
}

int getLaneCnt(int width) {
	return 16 / width;
}

int getGroupCnt(int width) {
	return INPUT_DIM / getLaneCnt(width);
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

uint16_t packQuantizedWord(const int32_t* values, int baseIdx, int width) {
	int laneCnt = getLaneCnt(width);
	uint32_t laneMask = ((uint32_t)1 << width) - 1;
	uint16_t packedWord = 0;

	for ( int i = 0; i < laneCnt; i ++ ) {
		uint16_t lane = (uint16_t)((uint32_t)values[baseIdx + i] & laneMask);
		packedWord |= (uint16_t)(lane << (i * width));
	}

	return packedWord;
}

void quantizeValues(
	const float* values,
	int32_t* quantizedValues,
	int valueCnt,
	int width
) {
	for ( int i = 0; i < valueCnt; i ++ ) {
		quantizedValues[i] = quantizeValue(values[i], width);
	}
}

void packWeights(
	const int32_t* quantizedWeights,
	uint16_t* packedWeights,
	int width
) {
	int laneCnt = getLaneCnt(width);
	int groupCnt = getGroupCnt(width);

	// Group-major layout: weightPack[groupIdx][outputIdx]
	for ( int i = 0; i < groupCnt; i ++ ) {
		for ( int j = 0; j < OUTPUT_DIM; j ++ ) {
			int sourceIdx = j * INPUT_DIM + i * laneCnt;
			int targetIdx = i * OUTPUT_DIM + j;
			packedWeights[targetIdx] = packQuantizedWord(
				quantizedWeights,
				sourceIdx,
				width
			);
		}
	}
}

void packInputs(
	const int32_t* quantizedInputs,
	uint16_t* packedInputs,
	int width
) {
	int laneCnt = getLaneCnt(width);
	int groupCnt = getGroupCnt(width);

	// Input-major layout: inputPack[inputIdx][groupIdx]
	for ( int i = 0; i < INPUT_CNT; i ++ ) {
		for ( int j = 0; j < groupCnt; j ++ ) {
			int sourceIdx = i * INPUT_DIM + j * laneCnt;
			int targetIdx = i * groupCnt + j;
			packedInputs[targetIdx] = packQuantizedWord(
				quantizedInputs,
				sourceIdx,
				width
			);
		}
	}
}

void calculateFloatGolden(
	const float* weights,
	const float* inputs,
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
	const int32_t* quantizedWeights,
	const int32_t* quantizedInputs,
	int32_t* answer,
	int width
) {
	for ( int i = 0; i < INPUT_CNT; i ++ ) {
		for ( int j = 0; j < OUTPUT_DIM; j ++ ) {
			int64_t accumulator = 0;
			for ( int k = 0; k < INPUT_DIM; k ++ ) {
				accumulator +=
					(int64_t)quantizedWeights[j * INPUT_DIM + k] *
					(int64_t)quantizedInputs[i * INPUT_DIM + k];
			}
			answer[i * OUTPUT_DIM + j] = requantizeAccumulator(accumulator, width);
		}
	}
}

void sendQuantizedWidth(int width) {
	uart_send((uint8_t)width);
}

void sendWeight(uint16_t data) {
	uart_send(0xff);
	uart_send((uint8_t)(data & 0xff));
	uart_send((uint8_t)(data >> 8));
}

void sendInput(uint16_t data, int inputIdx) {
	uart_send((uint8_t)(inputIdx & 0xff));
	uart_send((uint8_t)(data & 0xff));
	uart_send((uint8_t)(data >> 8));
}

FcResult receiveResult() {
	FcResult result;
	result.value = 0;
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

	IntBit8 value;
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

	int laneCnt = getLaneCnt(quantizedWidth);
	int groupCnt = getGroupCnt(quantizedWidth);
	int weightValueCnt = INPUT_DIM * OUTPUT_DIM;
	int inputValueCnt = INPUT_DIM * INPUT_CNT;
	int resultCnt = INPUT_CNT * OUTPUT_DIM;
	int weightWordCnt = groupCnt * OUTPUT_DIM;
	int inputWordCnt = groupCnt * INPUT_CNT;

	printf( "---------------------------------------------------------------------\n" );
	printf( "[STEP 1] Generating signed FC weights and inputs\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	float* weights = (float*)malloc(sizeof(float) * weightValueCnt);
	float* inputs = (float*)malloc(sizeof(float) * inputValueCnt);
	float* floatGolden = (float*)malloc(sizeof(float) * resultCnt);
	int32_t* quantizedWeights = (int32_t*)malloc(sizeof(int32_t) * weightValueCnt);
	int32_t* quantizedInputs = (int32_t*)malloc(sizeof(int32_t) * inputValueCnt);
	int32_t* quantizedGolden = (int32_t*)malloc(sizeof(int32_t) * resultCnt);
	int32_t* hardwareResult = (int32_t*)malloc(sizeof(int32_t) * resultCnt);
	uint16_t* packedWeights = (uint16_t*)malloc(sizeof(uint16_t) * weightWordCnt);
	uint16_t* packedInputs = (uint16_t*)malloc(sizeof(uint16_t) * inputWordCnt);

	if ( weights == NULL || inputs == NULL || floatGolden == NULL ||
	     quantizedWeights == NULL || quantizedInputs == NULL ||
	     quantizedGolden == NULL || hardwareResult == NULL ||
	     packedWeights == NULL || packedInputs == NULL ) {
		printf( "Failed to allocate FC test buffers.\n" );
		fflush( stdout );
		exit(1);
	}

	for ( int i = 0; i < weightValueCnt; i ++ ) {
		weights[i] = 0.0f;
		if ( rand() % 4 == 0 ) {
			weights[i] = (float)((rand() % 20001) - 10000) / 1000.0f;
		}
	}
	for ( int i = 0; i < inputValueCnt; i ++ ) {
		inputs[i] = 0.0f;
		if ( rand() % 4 == 0 ) {
			inputs[i] = (float)((rand() % 20001) - 10000) / 1000.0f;
		}
	}
	for ( int i = 0; i < resultCnt; i ++ ) {
		hardwareResult[i] = 0;
	}

	printf( "---------------------------------------------------------------------\n" );
	printf( "[STEP 2] Quantizing, packing, and calculating golden results\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	quantizeValues(weights, quantizedWeights, weightValueCnt, quantizedWidth);
	quantizeValues(inputs, quantizedInputs, inputValueCnt, quantizedWidth);
	packWeights(quantizedWeights, packedWeights, quantizedWidth);
	packInputs(quantizedInputs, packedInputs, quantizedWidth);
	calculateFloatGolden(weights, inputs, floatGolden);
	calculateQuantizedGolden(
		quantizedWeights,
		quantizedInputs,
		quantizedGolden,
		quantizedWidth
	);

	printf( "---------------------------------------------------------------------\n" );
	printf( "[STEP 3] Sending packed INT%d data and running the FPGA FC layer\n",
		quantizedWidth
	);
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	sendQuantizedWidth(quantizedWidth);
	nnFc(
		packedWeights,
		packedInputs,
		INPUT_CNT,
		groupCnt,
		OUTPUT_DIM,
		hardwareResult
	);

	printf( "---------------------------------------------------------------------\n" );
	printf( "[STEP 4] Comparing FPGA, quantized golden, and Float golden results\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	int mismatchCnt = 0;
	double hardwareDiffSum = 0.0;
	double quantizationDiffSum = 0.0;
	float hardwareDiffMax = 0.0f;
	float quantizationDiffMax = 0.0f;
	float outputScale = getOutputScale(quantizedWidth);

	for ( int i = 0; i < resultCnt; i ++ ) {
		float hardwareValue = (float)hardwareResult[i] * outputScale;
		float quantizedGoldenValue = (float)quantizedGolden[i] * outputScale;
		float hardwareDiff = fabsf(hardwareValue - quantizedGoldenValue);
		float quantizationDiff = fabsf(quantizedGoldenValue - floatGolden[i]);

		if ( hardwareResult[i] != quantizedGolden[i] ) {
			if ( mismatchCnt < 16 ) {
				printf(
					"Mismatch at %d: FPGA=%d QuantizedGolden=%d Diff=%f\n",
					i,
					hardwareResult[i],
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

	size_t floatWeightBytes = sizeof(float) * weightValueCnt;
	size_t floatInputBytes = sizeof(float) * inputValueCnt;
	size_t packedWeightBytes = sizeof(uint16_t) * weightWordCnt;
	size_t packedInputBytes = sizeof(uint16_t) * inputWordCnt;
	size_t floatUartBytes = 5 * (weightValueCnt + inputValueCnt);
	size_t packedUartBytes = 1 + 3 * (weightWordCnt + inputWordCnt);
	double payloadReduction =
		(double)(floatWeightBytes + floatInputBytes) /
		(double)(packedWeightBytes + packedInputBytes);
	double uartReduction = (double)floatUartBytes / (double)packedUartBytes;
	int64_t scalarMacCnt = (int64_t)INPUT_CNT * OUTPUT_DIM * INPUT_DIM;
	int64_t packedOperationCnt = scalarMacCnt / laneCnt;

	printf( "Quantized Width              : INT%d\n", quantizedWidth );
	printf( "Packed Lanes per Word        : %d\n", laneCnt );
	printf( "Input Groups per Vector      : %d\n", groupCnt );
	printf( "Equivalent Scalar MACs       : %ld\n", (long)scalarMacCnt );
	printf( "Packed Operations            : %ld\n", (long)packedOperationCnt );
	printf( "FP32 Weight Payload          : %zu bytes\n", floatWeightBytes );
	printf( "Packed Weight Payload        : %zu bytes\n", packedWeightBytes );
	printf( "FP32 Input Payload           : %zu bytes\n", floatInputBytes );
	printf( "Packed Input Payload         : %zu bytes\n", packedInputBytes );
	printf( "Payload Reduction            : %.2fx\n", payloadReduction );
	printf( "FP32 UART Transfer           : %zu bytes\n", floatUartBytes );
	printf( "Packed UART Transfer         : %zu bytes\n", packedUartBytes );
	printf( "UART Transfer Reduction      : %.2fx\n", uartReduction );
	printf( "Input/Weight Scale           : %.10f\n",
		1.0f / getInputInverseScale(quantizedWidth)
	);
	printf( "Output Scale                 : %.10f\n", outputScale );
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
	free(floatGolden);
	free(quantizedWeights);
	free(quantizedInputs);
	free(quantizedGolden);
	free(hardwareResult);
	free(packedWeights);
	free(packedInputs);

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
