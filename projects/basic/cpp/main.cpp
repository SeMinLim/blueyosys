#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "ttyifc.h"

typedef union FloatData {
	float value;
	uint32_t bits;
	uint8_t bytes[4];
} FloatData;

void sendFloat( float value ) {
	FloatData data;
	data.value = value;

	for ( int i = 0; i < 4; i ++ ) {
		uart_send(data.bytes[i]);
	}
}

uint8_t receiveByte() {
	uint32_t data = uart_recv();
	while ( data > 0xff ) {
		data = uart_recv();
	}
	return (uint8_t)data;
}

FloatData receiveFloat() {
	FloatData data;
	data.bits = 0;

	for ( int i = 0; i < 4; i ++ ) {
		data.bytes[i] = receiveByte();
	}
	return data;
}

bool runTest( int testIdx, float a, float b, float c ) {
	FloatData inputA;
	FloatData inputB;
	FloatData inputC;
	inputA.value = a;
	inputB.value = b;
	inputC.value = c;

	sendFloat(a);
	sendFloat(b);
	sendFloat(c);

	FloatData singleReadA = receiveFloat();
	FloatData singleReadB = receiveFloat();
	FloatData singleReadC = receiveFloat();
	FloatData burstReadA = receiveFloat();
	FloatData burstReadB = receiveFloat();
	FloatData burstReadC = receiveFloat();
	FloatData result = receiveFloat();
	float expected = (a * b) + c;

	bool singleSdramPass =
		(singleReadA.bits == inputA.bits) &&
		(singleReadB.bits == inputB.bits) &&
		(singleReadC.bits == inputC.bits);
	bool burstSdramPass =
		(burstReadA.bits == inputA.bits) &&
		(burstReadB.bits == inputB.bits) &&
		(burstReadC.bits == inputC.bits);
	bool macPass = fabsf(result.value - expected) <= 0.001f;
	bool pass = singleSdramPass && burstSdramPass && macPass;

	printf( "Test %d: A=%f B=%f C=%f\n", testIdx, a, b, c );
	printf( "SDRAM BL1 Read-back   : %s\n", singleSdramPass ? "PASS" : "FAIL" );
	printf( "SDRAM Burst Read-back : %s\n", burstSdramPass ? "PASS" : "FAIL" );
	printf( "MAC Result            : %f (Expected %f)\n", result.value, expected );
	printf( "Result                : %s\n", pass ? "PASS" : "FAIL" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	return pass;
}

void* swmain( void* param ) {
	(void)param;

	printf( "---------------------------------------------------------------------\n" );
	printf( "[STEP 1] Starting UART, SDRAM BL1, SDRAM burst, and MAC tests\n" );
	printf( "---------------------------------------------------------------------\n" );
	fflush( stdout );

	bool pass = true;
	pass = runTest(1, 1.5f, 2.0f, 0.25f) && pass;
	pass = runTest(2, -2.0f, 4.0f, 1.0f) && pass;
	pass = runTest(3, 0.5f, -8.0f, 2.0f) && pass;

	printf( "[STEP 2] Basic project test %s\n", pass ? "PASSED" : "FAILED" );
	fflush( stdout );
	exit(pass ? 0 : 1);
	return NULL;
}

int main( int argc, char** argv ) {
	char defaultTty[] = "/dev/ttyUSB0";
	char* ttyPath = defaultTty;
	if ( argc > 1 ) ttyPath = argv[1];

	int ret = open_tty(ttyPath);
	if ( ret != 0 ) return ret;

	swmain(NULL);
	return 0;
}
