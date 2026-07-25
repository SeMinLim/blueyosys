ROOTDIR := $(abspath ../..)
PROJECT_NAME := nn_fc_quantized
QUANTIZED_WIDTH ?= 8

ifeq ($(QUANTIZED_WIDTH),4)
QUANTIZED_DEFINE := NN_FC_QINT4
else ifeq ($(QUANTIZED_WIDTH),8)
QUANTIZED_DEFINE := NN_FC_QINT8
else ifeq ($(QUANTIZED_WIDTH),16)
QUANTIZED_DEFINE := NN_FC_QINT16
else
$(error QUANTIZED_WIDTH must be 4, 8, or 16)
endif

BSCFLAGS_COMMON := -show-schedule -show-range-conflict -aggressive-conditions \
	-D $(QUANTIZED_DEFINE)
BSIM_CXXFLAGS := -Xc++ -I$(ROOTDIR)/lib/cpp \
	-Xc++ -DQUANTIZED_WIDTH=$(QUANTIZED_WIDTH)

include $(ROOTDIR)/build.mk
